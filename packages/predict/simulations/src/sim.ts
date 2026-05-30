import { existsSync, unlinkSync } from "fs";
import { spawnSync } from "child_process";
import { fileURLToPath } from "url";

import {
  ECONOMIC_SCHEMA_VERSION,
  LOCAL_DATA_PATH,
  LOCAL_TRACE_PATH,
  LOCAL_TRACE_SCHEMA_VERSION,
  PYTHON_DATA_PATH,
  SCENARIO_PATH,
  STATE_PATH,
  type EconomicDataFile,
  type EconomicRecord,
  type LocalTraceFile,
  type LocalTraceStep,
  type MintRow,
  type OracleRefreshData,
  type ScenarioRow,
  type SimState,
  loadScenario,
  readJson,
  scenarioQuantityScale,
  ts,
  writeJson,
} from "./shared.js";
import {
  POOL_VAULT_ID,
  PROTOCOL_CONFIG_ID,
  address,
  createExpiryMarketTx,
  createManagerTx,
  createMarketOracleCapTx,
  createPythSourceTx,
  depositToManagerTx,
  deriveManagerId,
  execute,
  executeAndWait,
  finalizeDusdcCurrencyRegistrationTx,
  refreshOracleAndMintTx,
  refreshOracleAndRedeemTx,
  refreshOracleAndSupplyWithExpiryValuationTx,
  refreshOracleAndWithdrawWithExpiryValuationTx,
  setMarketOracleBasisBoundsTx,
  supplyTx,
  type ExecutionReceipt,
} from "./runtime.js";

const DUSDC_DECIMALS = 1_000_000n;
const DEFAULT_VAULT_SEED = 500_000n * DUSDC_DECIMALS;
const DEFAULT_MANAGER_SEED = 500_000n * DUSDC_DECIMALS;
const DEFAULT_INITIAL_EXPIRY_ALLOCATION = 50_000n * DUSDC_DECIMALS;
const EXPIRY_MS = BigInt(Date.now()) + 400n * 24n * 60n * 60n * 1000n;
const FLOAT_SCALING = 1_000_000_000n;
const SCENARIO_CONFIG_PATH = fileURLToPath(new URL("../data/scenario_config.json", import.meta.url));
const ORACLE_MIN_STRIKE = 25_000n * FLOAT_SCALING;
const ORACLE_TICK_SIZE = 1n * FLOAT_SCALING;
const ORACLE_MAX_STRIKE = ORACLE_MIN_STRIKE + 100_000n * ORACLE_TICK_SIZE;
const NEG_INF_STRIKE = 0n;
const POS_INF_STRIKE = (1n << 64n) - 1n;
const ORDER_SEQUENCE_MASK = (1n << 40n) - 1n;

interface SimulationCapital {
  vaultSeed: bigint;
  managerSeed: bigint;
  initialExpiryAllocation: bigint;
  initialTotalPlpSupply: bigint;
}

interface EconomicState {
  managerBalance: bigint;
  expiryLpCash: bigint;
  expiryFeeBalance: bigint;
  expiryUnresolvedTradingFees: bigint;
  vaultIdleBalance: bigint;
  vaultTotalAllocated: bigint;
  vaultTotalPlpSupply: bigint;
  openOrderCount: bigint;
  openOrderQuantity: bigint;
  liquidatedOrderCount: bigint;
}

interface AliasState {
  orderIdsByRef: Map<string, string>;
  orderRefsById: Map<string, string>;
  lpCoinIdsByRef: Map<string, string>;
}

function parseArgs() {
  let maxRows: number | undefined;
  const args = process.argv.slice(2);
  for (let i = 0; i < args.length; i++) {
    if (args[i] !== "--max-rows") {
      throw new Error(`Unsupported sim argument ${args[i]}`);
    }
    const value = args[i + 1];
    if (value === undefined || !/^[1-9][0-9]*$/.test(value)) {
      throw new Error("--max-rows requires a positive integer");
    }
    maxRows = parseInt(value, 10);
    i += 1;
  }
  return { maxRows };
}

function initialEconomicState(capital: SimulationCapital): EconomicState {
  return {
    managerBalance: capital.managerSeed,
    expiryLpCash: capital.initialExpiryAllocation,
    expiryFeeBalance: 0n,
    expiryUnresolvedTradingFees: 0n,
    vaultIdleBalance: capital.vaultSeed - capital.initialExpiryAllocation,
    vaultTotalAllocated: capital.initialExpiryAllocation,
    vaultTotalPlpSupply: capital.initialTotalPlpSupply,
    openOrderCount: 0n,
    openOrderQuantity: 0n,
    liquidatedOrderCount: 0n,
  };
}

function initialAliases(): AliasState {
  return {
    orderIdsByRef: new Map(),
    orderRefsById: new Map(),
    lpCoinIdsByRef: new Map(),
  };
}

function alignStrikeToGrid(strike: bigint): bigint {
  const relative = strike - ORACLE_MIN_STRIKE;
  const tickIndex = relative / ORACLE_TICK_SIZE;
  const snapped = ORACLE_MIN_STRIKE + tickIndex * ORACLE_TICK_SIZE;
  if (snapped < ORACLE_MIN_STRIKE) return ORACLE_MIN_STRIKE;
  if (snapped > ORACLE_MAX_STRIKE) return ORACLE_MAX_STRIKE;
  return snapped;
}

function binaryRangeBounds(strike: bigint, isUp: boolean): { lower: bigint; higher: bigint } {
  return isUp
    ? { lower: strike, higher: POS_INF_STRIKE }
    : { lower: NEG_INF_STRIKE, higher: strike };
}

function direction(row: MintRow): "UP" | "DN" {
  return row.isUp ? "UP" : "DN";
}

function scaledUsd(value: bigint): string {
  return (Number(value) / 1e9).toFixed(0);
}

function formatLeverage(leverage: bigint): string {
  const whole = leverage / FLOAT_SCALING;
  const fraction = leverage % FLOAT_SCALING;
  if (fraction === 0n) return `${whole}x`;
  if (fraction === FLOAT_SCALING / 2n) return `${whole}.5x`;
  return `${Number(leverage) / Number(FLOAT_SCALING)}x`;
}

function signedValue(magnitude: bigint, isNegative: boolean): string {
  if (magnitude === 0n) return "0";
  return isNegative ? `-${magnitude}` : magnitude.toString();
}

function decimal(value: unknown): string {
  if (typeof value === "string") return value;
  if (typeof value === "number") return String(value);
  if (typeof value === "bigint") return value.toString();
  throw new Error(`Expected decimal-compatible value, got ${JSON.stringify(value)}`);
}

function booleanField(value: unknown): boolean {
  if (typeof value === "boolean") return value;
  if (typeof value === "string") return value === "true";
  return Boolean(value);
}

function signedI64(value: any): string {
  const fields = value?.fields ?? value ?? {};
  const magnitude = BigInt(decimal(fields.magnitude ?? fields.value ?? 0));
  const isNegative = booleanField(
    fields.is_negative ?? fields.isNegative ?? fields.negative ?? false,
  );
  return signedValue(magnitude, isNegative);
}

function orderSequence(orderId: string): string {
  return (BigInt(orderId) & ORDER_SEQUENCE_MASK).toString();
}

function optionDecimal(value: any): string | null {
  if (value === null || value === undefined) return null;
  if (Array.isArray(value)) return value.length === 0 ? null : decimal(value[0]);
  if (typeof value === "string" || typeof value === "number" || typeof value === "bigint") {
    return decimal(value);
  }
  const fields = value.fields ?? value;
  if (Array.isArray(fields.vec)) return fields.vec.length === 0 ? null : decimal(fields.vec[0]);
  if (Array.isArray(fields)) return fields.length === 0 ? null : decimal(fields[0]);
  if (fields.some !== undefined) return decimal(fields.some);
  if (fields.value !== undefined) return decimal(fields.value);
  return null;
}

function eventName(event: any): string {
  return String(event.type ?? "").split("::").pop() ?? "";
}

function findEvent(events: any[], name: string): any | undefined {
  return events.find((event) => eventName(event) === name || String(event.type ?? "").includes(name));
}

function sviInput(row: MintRow | OracleRefreshData) {
  return {
    a: row.a.toString(),
    b: row.b.toString(),
    rho: signedValue(row.rho, row.rhoNegative),
    m: signedValue(row.m, row.mNegative),
    sigma: row.sigma.toString(),
  };
}

function mintInput(row: MintRow): Record<string, string> {
  const strike = alignStrikeToGrid(row.strike);
  const { lower, higher } = binaryRangeBounds(strike, row.isUp);
  return {
    order_ref: row.orderRef,
    lower_strike: lower.toString(),
    higher_strike: higher.toString(),
    quantity: row.quantity.toString(),
    leverage: row.leverage.toString(),
  };
}

function rowInput(row: ScenarioRow): Record<string, unknown> {
  if (row.action === "oracle_mint_ptb") {
    return {
      spot: row.spot.toString(),
      forward: row.forward.toString(),
      svi: sviInput(row),
      ...mintInput(row),
    };
  }
  if (row.action === "redeem") {
    return {
      ...oracleRefreshInput(row),
      order_ref: row.orderRef,
      close_quantity: row.closeQuantity.toString(),
      replacement_order_ref: row.replacementOrderRef,
    };
  }
  if (row.action === "supply") {
    return { ...oracleRefreshInput(row), amount: row.amount.toString(), lp_ref: row.lpRef };
  }
  return { ...oracleRefreshInput(row), lp_ref: row.lpRef };
}

function oracleRefreshInput(row: ScenarioRow): Record<string, unknown> {
  if (row.action === "oracle_mint_ptb") return {};
  return {
    spot: row.oracleRefresh.spot.toString(),
    forward: row.oracleRefresh.forward.toString(),
    svi: sviInput(row.oracleRefresh),
  };
}

function normalizePricesUpdated(event: any): Record<string, unknown> {
  const json = event.parsedJson ?? {};
  return {
    type: "oracle_prices_updated",
    spot: decimal(json.spot),
    forward: decimal(json.forward),
    basis: decimal(json.basis),
  };
}

function normalizeSviUpdated(event: any): Record<string, unknown> {
  const json = event.parsedJson ?? {};
  return {
    type: "oracle_svi_updated",
    a: decimal(json.a),
    b: decimal(json.b),
    rho: signedI64(json.rho),
    m: signedI64(json.m),
    sigma: decimal(json.sigma),
  };
}

function normalizeOrderMinted(event: any, row: ScenarioRow): Record<string, unknown> {
  const json = event.parsedJson ?? {};
  const orderRef = row.action === "oracle_mint_ptb" ? row.orderRef : null;
  return {
    type: "order_minted",
    order_ref: orderRef,
    order_sequence: orderSequence(decimal(json.order_id)),
    lower_strike: decimal(json.lower_strike),
    higher_strike: decimal(json.higher_strike),
    leverage: decimal(json.leverage),
    entry_probability: decimal(json.entry_probability),
    quantity: decimal(json.quantity),
    contribution: decimal(json.contribution),
    trading_fee: decimal(json.trading_fee),
    builder_fee: decimal(json.builder_fee),
    floor_seed_amount: decimal(json.floor_seed_amount),
  };
}

function normalizeOrderLiquidated(event: any, aliases: AliasState): Record<string, unknown> {
  const json = event.parsedJson ?? {};
  const orderId = decimal(json.order_id);
  return {
    type: "order_liquidated",
    order_ref: aliases.orderRefsById.get(orderId) ?? null,
    order_sequence: orderSequence(orderId),
    quantity: decimal(json.quantity),
    gross_value: decimal(json.gross_value),
    floor_amount: decimal(json.floor_amount),
    liquidation_ltv: decimal(json.liquidation_ltv),
  };
}

function normalizeLiveOrderRedeemed(event: any, row: ScenarioRow): Record<string, unknown> {
  const json = event.parsedJson ?? {};
  const replacementOrderId = optionDecimal(json.replacement_order_id);
  const replacementRef =
    row.action === "redeem" && replacementOrderId !== null
      ? row.replacementOrderRef ?? row.orderRef
      : null;
  return {
    type: "live_order_redeemed",
    order_ref: row.action === "redeem" ? row.orderRef : null,
    order_sequence: orderSequence(decimal(json.order_id)),
    quantity_closed: decimal(json.quantity_closed),
    remaining_quantity: decimal(json.remaining_quantity),
    replacement_order_ref: replacementRef,
    replacement_order_sequence: replacementOrderId === null ? null : orderSequence(replacementOrderId),
    redeem_amount: decimal(json.redeem_amount),
    trading_fee: decimal(json.trading_fee),
    builder_fee: decimal(json.builder_fee),
  };
}

function normalizeLiquidatedOrderRedeemed(event: any, row: ScenarioRow): Record<string, unknown> {
  const json = event.parsedJson ?? {};
  return {
    type: "liquidated_order_redeemed",
    order_ref: row.action === "redeem" ? row.orderRef : null,
    order_sequence: orderSequence(decimal(json.order_id)),
    quantity_closed: decimal(json.quantity_closed),
  };
}

function normalizeSettledOrderRedeemed(event: any, row: ScenarioRow): Record<string, unknown> {
  const json = event.parsedJson ?? {};
  return {
    type: "settled_order_redeemed",
    order_ref: row.action === "redeem" ? row.orderRef : null,
    order_sequence: orderSequence(decimal(json.order_id)),
    quantity_closed: decimal(json.quantity_closed),
    settlement_price: decimal(json.settlement_price),
    payout_amount: decimal(json.payout_amount),
  };
}

function normalizeSupplyExecuted(event: any, row: ScenarioRow): Record<string, unknown> {
  const json = event.parsedJson ?? {};
  return {
    type: "pool_supply",
    lp_ref: row.action === "supply" ? row.lpRef : null,
    payment: decimal(json.payment),
    shares_minted: decimal(json.shares_minted),
    pool_value_before: decimal(json.pool_value_before),
    total_supply_after: decimal(json.total_supply_after),
    idle_balance_after: decimal(json.idle_balance_after),
    total_allocated_after: decimal(json.total_allocated_after),
  };
}

function normalizeWithdrawExecuted(event: any, row: ScenarioRow): Record<string, unknown> {
  const json = event.parsedJson ?? {};
  return {
    type: "pool_withdraw",
    lp_ref: row.action === "withdraw" ? row.lpRef : null,
    shares_burned: decimal(json.shares_burned),
    payout: decimal(json.payout),
    pool_value_before: decimal(json.pool_value_before),
    total_supply_after: decimal(json.total_supply_after),
    idle_balance_after: decimal(json.idle_balance_after),
    total_allocated_after: decimal(json.total_allocated_after),
  };
}

function normalizeUpdates(row: ScenarioRow, receipt: ExecutionReceipt, aliases: AliasState): Record<string, unknown>[] {
  const updates: Record<string, unknown>[] = [];
  for (const event of receipt.events) {
    const name = eventName(event);
    if (name === "BlockScholesPricesUpdated") updates.push(normalizePricesUpdated(event));
    else if (name === "BlockScholesSVIUpdated") updates.push(normalizeSviUpdated(event));
    else if (name === "OrderLiquidated") updates.push(normalizeOrderLiquidated(event, aliases));
    else if (name === "OrderMinted") updates.push(normalizeOrderMinted(event, row));
    else if (name === "LiveOrderRedeemed") updates.push(normalizeLiveOrderRedeemed(event, row));
    else if (name === "LiquidatedOrderRedeemed") updates.push(normalizeLiquidatedOrderRedeemed(event, row));
    else if (name === "SettledOrderRedeemed") updates.push(normalizeSettledOrderRedeemed(event, row));
    else if (name === "SupplyExecuted") updates.push(normalizeSupplyExecuted(event, row));
    else if (name === "WithdrawExecuted") updates.push(normalizeWithdrawExecuted(event, row));
  }
  return updates;
}

function applyUpdate(state: EconomicState, update: Record<string, unknown>) {
  if (update.type === "order_minted") {
    const contribution = BigInt(decimal(update.contribution));
    const tradingFee = BigInt(decimal(update.trading_fee));
    const builderFee = BigInt(decimal(update.builder_fee));
    const quantity = BigInt(decimal(update.quantity));
    state.managerBalance -= contribution + tradingFee + builderFee;
    state.expiryLpCash += contribution;
    state.expiryFeeBalance += tradingFee;
    state.expiryUnresolvedTradingFees += tradingFee;
    state.openOrderCount += 1n;
    state.openOrderQuantity += quantity;
  } else if (update.type === "order_liquidated") {
    const quantity = BigInt(decimal(update.quantity));
    state.openOrderCount -= 1n;
    state.openOrderQuantity -= quantity;
    state.liquidatedOrderCount += 1n;
  } else if (update.type === "live_order_redeemed") {
    const redeemAmount = BigInt(decimal(update.redeem_amount));
    const tradingFee = BigInt(decimal(update.trading_fee));
    const builderFee = BigInt(decimal(update.builder_fee));
    const quantityClosed = BigInt(decimal(update.quantity_closed));
    const remainingQuantity = BigInt(decimal(update.remaining_quantity));
    state.managerBalance += redeemAmount - tradingFee - builderFee;
    state.expiryLpCash -= redeemAmount;
    state.expiryFeeBalance += tradingFee;
    state.expiryUnresolvedTradingFees += tradingFee;
    state.openOrderQuantity -= quantityClosed;
    if (remainingQuantity === 0n) state.openOrderCount -= 1n;
  } else if (update.type === "liquidated_order_redeemed") {
    state.liquidatedOrderCount -= 1n;
  } else if (update.type === "settled_order_redeemed") {
    const payout = BigInt(decimal(update.payout_amount));
    const quantityClosed = BigInt(decimal(update.quantity_closed));
    state.managerBalance += payout;
    state.expiryLpCash -= payout;
    state.openOrderCount -= 1n;
    state.openOrderQuantity -= quantityClosed;
  } else if (update.type === "pool_supply") {
    state.vaultIdleBalance = BigInt(decimal(update.idle_balance_after));
    state.vaultTotalAllocated = BigInt(decimal(update.total_allocated_after));
    state.vaultTotalPlpSupply = BigInt(decimal(update.total_supply_after));
  } else if (update.type === "pool_withdraw") {
    state.vaultIdleBalance = BigInt(decimal(update.idle_balance_after));
    state.vaultTotalAllocated = BigInt(decimal(update.total_allocated_after));
    state.vaultTotalPlpSupply = BigInt(decimal(update.total_supply_after));
  }
}

function stateSnapshot(state: EconomicState): Record<string, string> {
  return {
    manager_balance: state.managerBalance.toString(),
    expiry_lp_cash: state.expiryLpCash.toString(),
    expiry_fee_balance: state.expiryFeeBalance.toString(),
    expiry_unresolved_trading_fees: state.expiryUnresolvedTradingFees.toString(),
    vault_idle_balance: state.vaultIdleBalance.toString(),
    vault_total_allocated: state.vaultTotalAllocated.toString(),
    vault_total_plp_supply: state.vaultTotalPlpSupply.toString(),
    open_order_count: state.openOrderCount.toString(),
    open_order_quantity: state.openOrderQuantity.toString(),
    liquidated_order_count: state.liquidatedOrderCount.toString(),
  };
}

function economicRecord(row: ScenarioRow, receipt: ExecutionReceipt, state: EconomicState, aliases: AliasState): EconomicRecord {
  const updates = normalizeUpdates(row, receipt, aliases);
  for (const update of updates) {
    applyUpdate(state, update);
  }

  return {
    step: row.step,
    action: row.action,
    input: rowInput(row),
    updates,
    state: stateSnapshot(state),
  };
}

function traceStep(row: ScenarioRow, receipt: ExecutionReceipt): LocalTraceStep {
  return {
    step: row.step,
    action: row.action,
    digest: receipt.digest,
    gas: receipt.gas,
    events: receipt.events.map((event: any) => ({
      type: eventName(event),
      full_type: String(event.type ?? ""),
      parsedJson: event.parsedJson ?? {},
    })),
  };
}

function eventOrderId(receipt: ExecutionReceipt, name: string): string | null {
  const event = findEvent(receipt.events, name);
  if (!event) return null;
  const json = event.parsedJson ?? {};
  return json.order_id === undefined ? null : decimal(json.order_id);
}

function createdPlpCoinId(receipt: ExecutionReceipt): string {
  const change = receipt.objectChanges.find(
    (objectChange: any) =>
      objectChange.type === "created" &&
      String(objectChange.objectType ?? "").includes("::coin::Coin") &&
      String(objectChange.objectType ?? "").includes("::plp::PLP"),
  );
  if (!change?.objectId) {
    throw new Error("Supply transaction did not create a PLP coin object");
  }
  return change.objectId;
}

function recordAliases(row: ScenarioRow, receipt: ExecutionReceipt, aliases: AliasState) {
  if (row.action === "oracle_mint_ptb") {
    const orderId = eventOrderId(receipt, "OrderMinted");
    if (!orderId) throw new Error(`Missing OrderMinted event for ${row.orderRef}`);
    aliases.orderIdsByRef.set(row.orderRef, orderId);
    aliases.orderRefsById.set(orderId, row.orderRef);
    return;
  }

  if (row.action === "redeem") {
    const liveRedeem = findEvent(receipt.events, "LiveOrderRedeemed");
    if (liveRedeem) {
      const oldOrderId = decimal(liveRedeem.parsedJson.order_id);
      aliases.orderRefsById.delete(oldOrderId);
      const replacementOrderId = optionDecimal(liveRedeem.parsedJson.replacement_order_id);
      if (replacementOrderId === null) {
        aliases.orderIdsByRef.delete(row.orderRef);
      } else {
        const replacementRef = row.replacementOrderRef ?? row.orderRef;
        aliases.orderIdsByRef.delete(row.orderRef);
        aliases.orderIdsByRef.set(replacementRef, replacementOrderId);
        aliases.orderRefsById.set(replacementOrderId, replacementRef);
      }
      return;
    }

    const closedOrderId =
      eventOrderId(receipt, "LiquidatedOrderRedeemed") ?? eventOrderId(receipt, "SettledOrderRedeemed");
    if (closedOrderId) {
      aliases.orderIdsByRef.delete(row.orderRef);
      aliases.orderRefsById.delete(closedOrderId);
    }
    return;
  }

  if (row.action === "supply") {
    aliases.lpCoinIdsByRef.set(row.lpRef, createdPlpCoinId(receipt));
  } else if (row.action === "withdraw") {
    aliases.lpCoinIdsByRef.delete(row.lpRef);
  }
}

function mintContext(row: MintRow, alignedStrike: bigint): string {
  return `${row.action} csv_line=${row.lineNumber} ${direction(row)} strike=$${scaledUsd(alignedStrike)} quantity=${row.quantity} leverage=${formatLeverage(row.leverage)} ref=${row.orderRef}`;
}

function errorMessage(error: unknown): string {
  return error instanceof Error ? error.message : String(error);
}

function clearOutputArtifacts() {
  for (const path of [LOCAL_TRACE_PATH, LOCAL_DATA_PATH, PYTHON_DATA_PATH]) {
    if (existsSync(path)) unlinkSync(path);
  }
}

function protocolConfigValue(config: any, key: string, fallback: bigint): bigint {
  const value = config?.protocol?.[key];
  return value === undefined || value === null || value === "" ? fallback : BigInt(value);
}

function capitalConfigValue(config: any, mode: string, key: string, fallback: bigint): bigint {
  const value = config?.capital?.[mode]?.[key];
  return value === undefined || value === null || value === "" ? fallback : BigInt(value);
}

function simulationCapital(config: any, mode: "normal" | "long"): SimulationCapital {
  const vaultSeed = capitalConfigValue(config, mode, "vault_seed", DEFAULT_VAULT_SEED);
  const initialExpiryAllocation = capitalConfigValue(
    config,
    mode,
    "initial_expiry_allocation",
    DEFAULT_INITIAL_EXPIRY_ALLOCATION,
  );
  if (initialExpiryAllocation > vaultSeed) {
    throw new Error(`${mode} initial_expiry_allocation exceeds vault_seed`);
  }
  return {
    vaultSeed,
    managerSeed: capitalConfigValue(config, mode, "manager_seed", DEFAULT_MANAGER_SEED),
    initialExpiryAllocation,
    initialTotalPlpSupply: vaultSeed,
  };
}

async function setupSimulation(scenarioConfig: any, capital: SimulationCapital): Promise<SimState> {
  console.log(`[${ts()}] --- Setup ---`);
  const expiryFeeWindowMs = protocolConfigValue(scenarioConfig, "expiry_fee_window_ms", 0n);
  const expiryFeeMaxMultiplier = protocolConfigValue(
    scenarioConfig,
    "expiry_fee_max_multiplier",
    FLOAT_SCALING,
  );

  let result = await executeAndWait(
    finalizeDusdcCurrencyRegistrationTx(),
    "finalize_dusdc_currency_registration",
  );
  const dusdcCurrencyChange = result.objectChanges.find(
    (change: any) =>
      change.type === "created" &&
      change.objectType.includes("coin_registry::Currency") &&
      change.objectType.includes("dusdc::DUSDC"),
  );
  const dusdcCurrencyId: string = dusdcCurrencyChange.objectId;
  console.log(`[${ts()}]   DUSDC Currency: ${dusdcCurrencyId}`);

  const poolVaultId = POOL_VAULT_ID;
  const protocolConfigId = PROTOCOL_CONFIG_ID;
  console.log(`[${ts()}]   PoolVault: ${poolVaultId}`);
  console.log(`[${ts()}]   ProtocolConfig: ${protocolConfigId}`);

  result = await executeAndWait(createMarketOracleCapTx(address), "create_market_oracle_cap");
  const oracleCapChange = result.objectChanges.find(
    (change: any) => change.type === "created" && change.objectType.includes("MarketOracleCap"),
  );
  const oracleCapId: string = oracleCapChange.objectId;
  console.log(`[${ts()}]   OracleCap: ${oracleCapId}`);

  result = await executeAndWait(
    createPythSourceTx(1, expiryFeeWindowMs, expiryFeeMaxMultiplier),
    "create_pyth_source",
  );
  const pythSourceChange = result.objectChanges.find(
    (change: any) => change.type === "created" && change.objectType.includes("PythSource"),
  );
  const pythSourceId: string = pythSourceChange.objectId;
  console.log(`[${ts()}]   PythSource: ${pythSourceId}`);
  console.log(
    `[${ts()}]   PythSource fee ramp: window=${expiryFeeWindowMs}ms max_multiplier=${expiryFeeMaxMultiplier}`,
  );

  await executeAndWait(supplyTx(poolVaultId, protocolConfigId, capital.vaultSeed), "supply");
  console.log(`[${ts()}]   Vault funded: ${capital.vaultSeed / DUSDC_DECIMALS} DUSDC`);

  result = await executeAndWait(
    createExpiryMarketTx({
      poolVaultId,
      protocolConfigId,
      pythSourceId,
      oracleCapId,
      expiry: EXPIRY_MS,
      minStrike: ORACLE_MIN_STRIKE,
      tickSize: ORACLE_TICK_SIZE,
    }),
    "create_expiry_market",
    50_000_000_000n,
  );
  const oracleChange = result.objectChanges.find(
    (change: any) =>
      change.type === "created" &&
      change.objectType.includes("MarketOracle") &&
      !change.objectType.includes("Cap"),
  );
  const oracleId: string = oracleChange.objectId;
  const expiryMarketChange = result.objectChanges.find(
    (change: any) => change.type === "created" && change.objectType.includes("ExpiryMarket"),
  );
  const expiryMarketId: string = expiryMarketChange.objectId;
  console.log(`[${ts()}]   ExpiryMarket: ${expiryMarketId}`);
  console.log(`[${ts()}]   Oracle: ${oracleId}`);

  await executeAndWait(
    setMarketOracleBasisBoundsTx(
      oracleId,
      protocolConfigId,
      oracleCapId,
      100_000_000n,
      100_000_000n,
      900_000_000n,
      1_100_000_000n,
    ),
    "set_basis_bounds",
  );
  console.log(`[${ts()}]   Basis bounds widened for oracle`);

  const managerId = deriveManagerId(address);
  await executeAndWait(createManagerTx(), "create_manager");
  console.log(`[${ts()}]   Manager: ${managerId}`);

  await executeAndWait(depositToManagerTx(managerId, capital.managerSeed), "deposit_to_manager");
  console.log(`[${ts()}]   Manager funded: ${capital.managerSeed / DUSDC_DECIMALS} DUSDC`);

  const state: SimState = {
    poolVaultId,
    protocolConfigId,
    expiryMarketId,
    pythSourceId,
    oracleId,
    oracleCapId,
    managerId,
  };

  writeJson(STATE_PATH, state);
  console.log(`[${ts()}]   State saved to ${STATE_PATH}`);

  return state;
}

async function executeRow(row: ScenarioRow, state: SimState, aliases: AliasState): Promise<ExecutionReceipt> {
  if (row.action === "oracle_mint_ptb") {
    const alignedStrike = alignStrikeToGrid(row.strike);
    return execute(
      () => refreshOracleAndMintTx({
        expiryMarketId: state.expiryMarketId,
        protocolConfigId: state.protocolConfigId,
        managerId: state.managerId,
        oracleId: state.oracleId,
        oracleCapId: state.oracleCapId,
        pythSourceId: state.pythSourceId,
        strike: alignedStrike,
        isUp: row.isUp,
        quantity: row.quantity,
        leverage: row.leverage,
        spot: row.spot,
        forward: row.forward,
        svi: {
          a: row.a,
          b: row.b,
          rho: row.rho,
          rhoNegative: row.rhoNegative,
          m: row.m,
          mNegative: row.mNegative,
          sigma: row.sigma,
        },
      }),
      "oracle_mint_ptb",
    );
  }

  if (row.action === "redeem") {
    const orderId = aliases.orderIdsByRef.get(row.orderRef);
    if (!orderId) throw new Error(`Unknown order_ref ${row.orderRef}`);
    return execute(
      () => refreshOracleAndRedeemTx({
        expiryMarketId: state.expiryMarketId,
        protocolConfigId: state.protocolConfigId,
        managerId: state.managerId,
        oracleId: state.oracleId,
        oracleCapId: state.oracleCapId,
        pythSourceId: state.pythSourceId,
        orderId,
        closeQuantity: row.closeQuantity,
        spot: row.oracleRefresh.spot,
        forward: row.oracleRefresh.forward,
        svi: row.oracleRefresh,
      }),
      "redeem",
    );
  }

  if (row.action === "supply") {
    return execute(
      () => refreshOracleAndSupplyWithExpiryValuationTx({
        poolVaultId: state.poolVaultId,
        protocolConfigId: state.protocolConfigId,
        expiryMarketId: state.expiryMarketId,
        oracleId: state.oracleId,
        oracleCapId: state.oracleCapId,
        pythSourceId: state.pythSourceId,
        amount: row.amount,
        spot: row.oracleRefresh.spot,
        forward: row.oracleRefresh.forward,
        svi: row.oracleRefresh,
      }),
      "supply",
    );
  }

  const lpCoinId = aliases.lpCoinIdsByRef.get(row.lpRef);
  if (!lpCoinId) throw new Error(`Unknown lp_ref ${row.lpRef}`);
  return execute(
    () => refreshOracleAndWithdrawWithExpiryValuationTx({
      poolVaultId: state.poolVaultId,
      protocolConfigId: state.protocolConfigId,
      expiryMarketId: state.expiryMarketId,
      oracleId: state.oracleId,
      oracleCapId: state.oracleCapId,
      pythSourceId: state.pythSourceId,
      lpCoinId,
      spot: row.oracleRefresh.spot,
      forward: row.oracleRefresh.forward,
      svi: row.oracleRefresh,
    }),
    "withdraw",
  );
}

async function executeScenario(
  rows: ScenarioRow[],
  state: SimState,
  capital: SimulationCapital,
  scenarioPath: string,
  maxRows?: number,
): Promise<void> {
  clearOutputArtifacts();
  runPythonReplay(scenarioPath, maxRows);

  const traceSteps: LocalTraceStep[] = [];
  const records: EconomicRecord[] = [];
  const economicState = initialEconomicState(capital);
  const aliases = initialAliases();
  const targetMints = rows.filter((row) => row.action === "oracle_mint_ptb").length;
  let successfulMints = 0;

  console.log(`\n[${ts()}] Loaded ${rows.length} executable tx rows (${targetMints} mints)`);
  console.log(`[${ts()}] --- Executing economic replay ---\n`);

  for (const row of rows) {
    try {
      const receipt = await executeRow(row, state, aliases);
      const record = economicRecord(row, receipt, economicState, aliases);
      recordAliases(row, receipt, aliases);
      traceSteps.push(traceStep(row, receipt));
      records.push(record);

      if (row.action === "oracle_mint_ptb") {
        successfulMints++;
        const alignedStrike = alignStrikeToGrid(row.strike);
        process.stdout.write(
          `[${ts()}]   [${row.step}] ${direction(row)} $${scaledUsd(alignedStrike)} qty=${row.quantity} leverage=${formatLeverage(row.leverage)} ref=${row.orderRef}\n`,
        );
      } else {
        process.stdout.write(`[${ts()}]   [${row.step}] ${row.action}\n`);
      }
    } catch (error) {
      if (row.action === "oracle_mint_ptb") {
        throw new Error(`${mintContext(row, alignStrikeToGrid(row.strike))} failed: ${errorMessage(error)}`);
      }
      throw new Error(`${row.action} csv_line=${row.lineNumber} tx=${row.step} failed: ${errorMessage(error)}`);
    }
  }

  const trace: LocalTraceFile = {
    schema_version: LOCAL_TRACE_SCHEMA_VERSION,
    steps: traceSteps,
  };
  const data: EconomicDataFile = {
    schema_version: ECONOMIC_SCHEMA_VERSION,
    scenario: {
      quantity_scale: scenarioQuantityScale(),
    },
    records,
  };

  writeJson(LOCAL_TRACE_PATH, trace);
  writeJson(LOCAL_DATA_PATH, data);

  console.log(`\n[${ts()}] --- Done ---`);
  console.log(`[${ts()}]   ${traceSteps.length} txs, ${successfulMints}/${targetMints} successful mints`);
  console.log(`[${ts()}]   Local trace: ${LOCAL_TRACE_PATH}`);
  console.log(`[${ts()}]   Local data:  ${LOCAL_DATA_PATH}`);
  console.log(`[${ts()}]   Python data: ${PYTHON_DATA_PATH}`);
}

function runPythonReplay(scenarioPath: string, maxRows?: number) {
  const script = fileURLToPath(new URL("../python_replay.py", import.meta.url));
  const args = [script, "--scenario", scenarioPath, "--out", PYTHON_DATA_PATH];
  if (maxRows !== undefined) {
    args.push("--max-rows", String(maxRows));
  }

  const result = spawnSync("python3", args, {
    stdio: "inherit",
    env: process.env,
  });
  if (result.status !== 0) {
    throw new Error(`python_replay.py failed with exit code ${result.status}`);
  }
}

async function main() {
  const args = parseArgs();
  const scenarioConfig = readJson<any>(SCENARIO_CONFIG_PATH);
  const capital = simulationCapital(scenarioConfig, "normal");
  let rows = loadScenario(SCENARIO_PATH);
  if (args.maxRows !== undefined) {
    console.log(`[${ts()}] Limiting to ${args.maxRows} tx rows`);
    rows = rows.slice(0, args.maxRows);
  }

  const state = await setupSimulation(scenarioConfig, capital);
  await executeScenario(rows, state, capital, SCENARIO_PATH, args.maxRows);
}

main().catch((error) => {
  console.error("Simulation failed:", error);
  process.exit(1);
});
