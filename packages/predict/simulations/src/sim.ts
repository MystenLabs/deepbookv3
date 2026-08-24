import { existsSync, rmSync } from "node:fs";
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";

import {
    ECONOMIC_SCHEMA_VERSION, LOCAL_DATA_PARTIAL_PATH, LOCAL_DATA_PATH,
    LOCAL_TRACE_PARTIAL_PATH, LOCAL_TRACE_PATH, LOCAL_TRACE_SCHEMA_VERSION,
    PYTHON_DATA_PATH, STATE_PATH, type EconomicDataFile, type EconomicRecord,
    type LocalTraceFile, type LocalTraceStep, type OracleRefreshData,
    type ScenarioActionName, type ScenarioRow, type SimState, loadScenario,
    readJson, REQUIRED_ACTIONS, scenarioQuantityScale, ts, validateCompleteScenario,
    writeJson,
} from "./shared.js";
import {
    POOL_VAULT_ID, PROTOCOL_CONFIG_ID, address, bareFlushTx, binaryRangeTicks,
    bindFeedsToUnderlyingTx, clockTimestampMs, createAccountTx, createExpiryMarketTx,
    depositToAccountTx, deriveAccountWrapperId, execute, executeAndWait,
    finalizeDusdcCurrencyRegistrationTx, keeperSettleTx, lockCapitalTx,
    mintLifecycleCapTx, readPredictEconomicState,
    rebalanceExpiryCashTx, redeemSettledTx, refreshOracleAndFlushTxs,
    refreshOracleAndMintTxs, refreshOracleAndRedeemTxs,
    registerUnderlyingAndCreateFeedsTx, requestSupplyTx, requestWithdrawTx,
    seedOracleTx, setBlockScholesSignerTx, setCadenceConfigTx,
    setSimulationEconomicPolicyTx, setTemplateExpiryFeeConfigTx,
    type ExecutionReceipt, updatePythTrustedSignerTx,
} from "../../devtools/ts/runtime.js";

const CONFIG_PATH = fileURLToPath(new URL("../data/scenario_config.json", import.meta.url));
const ORDER_SEQUENCE_MASK = (1n << 40n) - 1n;
interface ScenarioConfig {
    schema_version: number;
    capital: { manager_seed: string; vault_seed: string };
    market: Record<string, string | number> & { cadence_id: number };
    protocol: Record<string, string>;
}
interface Aliases { orderIds: Map<string, string>; orderRefs: Map<string, string> }

function parseArgs(): { scenario: string; maxRows?: number } {
    let scenario: string | undefined;
    let maxRows: number | undefined;
    const args = process.argv.slice(2);
    for (let i = 0; i < args.length; i += 1) {
        const value = args[i + 1];
        if (args[i] === "--scenario" && value && !value.startsWith("--")) {
            scenario = value; i += 1;
        } else if (args[i] === "--max-rows" && value && /^[1-9][0-9]*$/.test(value)) {
            maxRows = Number(value); i += 1;
        } else throw new Error(`invalid simulation argument ${args[i]}`);
    }
    if (!scenario) throw new Error("--scenario is required");
    return { scenario, maxRows };
}

function integer(value: unknown, path: string): bigint {
    if (typeof value !== "string" || !/^\d+$/.test(value)) {
        throw new Error(`${path} must be an unsigned integer string`);
    }
    return BigInt(value);
}
function eventName(event: any): string { return String(event.type ?? "").split("::").at(-1) ?? "" }
function eventJson(event: any): any { return event.parsedJson ?? {} }
function eventsNamed(receipt: ExecutionReceipt, name: string): any[] {
    return receipt.events.filter((event: any) => eventName(event) === name);
}
function onlyEvent(receipt: ExecutionReceipt, name: string): any {
    const matches = eventsNamed(receipt, name);
    if (matches.length !== 1) throw new Error(`${name}: expected one event, found ${matches.length}`);
    return matches[0];
}
function decimal(value: any): string {
    if (typeof value === "bigint") return value.toString();
    if (typeof value === "number" && Number.isSafeInteger(value)) return String(value);
    if (typeof value === "string" && /^\d+$/.test(value)) return value;
    throw new Error(`expected unsigned integer event field, got ${JSON.stringify(value)}`);
}
function boolean(value: any): boolean {
    if (typeof value !== "boolean") throw new Error(`expected boolean event field, got ${JSON.stringify(value)}`);
    return value;
}
function optionDecimal(value: any): string | null {
    if (value === null || value === undefined) return null;
    if (Array.isArray(value)) return value.length === 0 ? null : decimal(value[0]);
    if (Array.isArray(value.vec)) return value.vec.length === 0 ? null : decimal(value.vec[0]);
    return decimal(value);
}
function orderSequence(orderId: string): string { return (BigInt(orderId) & ORDER_SEQUENCE_MASK).toString() }

function oracleFor(row: ScenarioRow): OracleRefreshData | null {
    if (row.action === "mint") return row;
    if (row.action === "redeem_live") return row.oracleRefresh;
    if (row.action === "flush") return row.oracleRefresh;
    return null;
}
function oracleInput(value: OracleRefreshData | null): Record<string, unknown> {
    if (!value) return {};
    return {
        spot: value.spot.toString(), forward: value.forward.toString(),
        a: value.a.toString(), a_negative: value.aNegative, b: value.b.toString(),
        rho: value.rho.toString(), rho_negative: value.rhoNegative,
        m: value.m.toString(), m_negative: value.mNegative,
        sigma: value.sigma.toString(), risk_free_rate: value.riskFreeRate.toString(),
    };
}
function rowInput(row: ScenarioRow, tickSize: bigint): Record<string, unknown> {
    const oracle = oracleInput(oracleFor(row));
    if (row.action === "mint") {
        const { lowerTick, higherTick } = binaryRangeTicks(row.strike, row.isUp, tickSize);
        return { ...oracle, order_ref: row.orderRef, lower_tick: lowerTick.toString(), higher_tick: higherTick.toString(), quantity: row.quantity.toString() };
    }
    if (row.action === "redeem_live") return { ...oracle, order_ref: row.orderRef, close_quantity: row.closeQuantity.toString(), replacement_order_ref: row.replacementOrderRef };
    if (row.action === "request_supply") return { amount: row.amount.toString(), min_output: row.minOutput.toString(), lp_ref: row.lpRef };
    if (row.action === "request_withdraw") return { shares: row.shares.toString(), min_output: row.minOutput.toString(), lp_ref: row.lpRef };
    if (row.action === "settle") return { settlement_price: row.settlementPrice.toString() };
    if (row.action === "redeem_settled") return { order_ref: row.orderRef, permissionless: row.permissionless };
    return oracle;
}
function sourceTimestamps(value: any): Record<string, string> {
    return {
        pyth_spot_source_timestamp_ms: decimal(value.pyth_spot_source_timestamp_ms),
        block_scholes_spot_source_timestamp_ms: decimal(value.block_scholes_spot_source_timestamp_ms),
        block_scholes_forward_source_timestamp_ms: decimal(value.block_scholes_forward_source_timestamp_ms),
        block_scholes_svi_source_timestamp_ms: decimal(value.block_scholes_svi_source_timestamp_ms),
    };
}

function normalizeUpdates(row: ScenarioRow, receipt: ExecutionReceipt, aliases: Aliases): Record<string, unknown>[] {
    const updates: Record<string, unknown>[] = [];
    for (const event of receipt.events) {
        const name = eventName(event);
        const value = eventJson(event);
        if (name === "OrderMinted") {
            const id = decimal(value.order_id);
            const ref = row.action === "mint" ? row.orderRef : aliases.orderRefs.get(id);
            if (!ref) throw new Error(`OrderMinted ${id} has no scenario alias`);
            updates.push({ type: "order_minted", order_ref: ref, order_sequence: orderSequence(id), lower_tick: decimal(value.lower_tick), higher_tick: decimal(value.higher_tick), entry_probability: decimal(value.entry_probability), quantity: decimal(value.quantity), premium: decimal(value.premium), trading_fee: decimal(value.trading_fee), fee_incentive_subsidy: decimal(value.fee_incentive_subsidy), builder_fee: decimal(value.builder_fee), penalty_fee: decimal(value.penalty_fee), referral_fee: decimal(value.referral_fee), inventory_charge: decimal(value.inventory_charge), onchain_timestamp_ms: decimal(value.onchain_timestamp_ms), ...sourceTimestamps(value) });
        } else if (name === "LiveOrderRedeemed") {
            const id = decimal(value.order_id);
            const ref = aliases.orderRefs.get(id) ?? (row.action === "redeem_live" ? row.orderRef : null);
            if (!ref) throw new Error(`LiveOrderRedeemed ${id} has no scenario alias`);
            const replacement = optionDecimal(value.replacement_order_id);
            const replacementRef = replacement !== null && row.action === "redeem_live"
                ? row.replacementOrderRef ?? row.orderRef
                : null;
            updates.push({ type: "live_order_redeemed", order_ref: ref, order_sequence: orderSequence(id), quantity_closed: decimal(value.quantity_closed), remaining_quantity: decimal(value.remaining_quantity), replacement_order_ref: replacementRef, replacement_order_sequence: replacement === null ? null : orderSequence(replacement), redeem_amount: decimal(value.redeem_amount), trading_fee: decimal(value.trading_fee), builder_fee: decimal(value.builder_fee), penalty_fee: decimal(value.penalty_fee), inventory_charge: decimal(value.inventory_charge), onchain_timestamp_ms: decimal(value.onchain_timestamp_ms), ...sourceTimestamps(value) });
        } else if (name === "SupplyRequested") {
            updates.push({ type: "supply_requested", lp_ref: row.action === "request_supply" ? row.lpRef : "", index: decimal(value.index), amount: decimal(value.amount), min_output: decimal(value.min_plp_out), requests_pending_after: decimal(value.requests_pending_after) });
        } else if (name === "WithdrawRequested") {
            updates.push({ type: "withdraw_requested", lp_ref: row.action === "request_withdraw" ? row.lpRef : "", index: decimal(value.index), amount: decimal(value.amount), min_output: decimal(value.min_dusdc_out), requests_pending_after: decimal(value.requests_pending_after) });
        } else if (name === "RequestCancelled") {
            updates.push({ type: "request_cancelled", index: decimal(value.index), amount: decimal(value.amount), is_supply: boolean(value.is_supply), reason: decimal(value.reason), requests_pending_after: decimal(value.requests_pending_after) });
        } else if (name === "SupplyFilled") {
            updates.push({ type: "supply_filled", index: decimal(value.index), dusdc_amount: decimal(value.dusdc_amount), shares_minted: decimal(value.shares_minted), fee_dusdc: decimal(value.fee_dusdc), dusdc_remaining: decimal(value.dusdc_remaining), requests_pending_after: decimal(value.requests_pending_after) });
        } else if (name === "WithdrawFilled") {
            updates.push({ type: "withdraw_filled", index: decimal(value.index), shares_burned: decimal(value.shares_burned), dusdc_amount: decimal(value.dusdc_amount), fee_dusdc: decimal(value.fee_dusdc), shares_remaining: decimal(value.shares_remaining), requests_pending_after: decimal(value.requests_pending_after) });
        } else if (name === "FlushExecuted") {
            updates.push({ type: "flush_executed", pool_value: decimal(value.pool_value), total_supply: decimal(value.total_supply), supply_fee_rate: decimal(value.supply_fee_rate), withdraw_fee_rate: decimal(value.withdraw_fee_rate), active_market_nav: decimal(value.active_market_nav), market_count: decimal(value.market_count), idle_balance_before: decimal(value.idle_balance_before), supplies_filled: decimal(value.supplies_filled), withdrawals_filled: decimal(value.withdrawals_filled), requests_processed: decimal(value.requests_processed), idle_balance_after: decimal(value.idle_balance_after), total_supply_after: decimal(value.total_supply_after) });
        } else if (name === "ExpiryCashRebalanced") {
            updates.push({ type: "expiry_cash_rebalanced", amount: decimal(value.amount), to_expiry: boolean(value.to_expiry), target_cash: decimal(value.target_cash), protocol_profit_realized: decimal(value.protocol_profit_realized) });
        } else if (name === "MarketSettled") {
            updates.push({ type: "market_settled", settlement_price: decimal(value.settlement_price), settlement_source: decimal(value.settlement_source), onchain_timestamp_ms: decimal(value.onchain_timestamp_ms) });
        } else if (name === "ExpiryCashReceived") {
            updates.push({ type: "expiry_cash_received", settlement_price: decimal(value.settlement_price), amount: decimal(value.amount) });
        } else if (name === "ExpiryProfitMaterialized") {
            updates.push({ type: "expiry_profit_materialized", lp_profit: decimal(value.lp_profit), protocol_profit: decimal(value.protocol_profit), protocol_reserve_balance_after: decimal(value.protocol_reserve_balance_after), profit_basis_after: decimal(value.profit_basis_after), pending_protocol_profit_after: decimal(value.pending_protocol_profit_after) });
        } else if (name === "SettledOrderRedeemed") {
            const id = decimal(value.order_id);
            const ref = aliases.orderRefs.get(id) ?? (row.action === "redeem_settled" ? row.orderRef : null);
            if (!ref) throw new Error(`SettledOrderRedeemed ${id} has no scenario alias`);
            updates.push({ type: "settled_order_redeemed", order_ref: ref, order_sequence: orderSequence(id), payout_amount: decimal(value.payout_amount), onchain_timestamp_ms: decimal(value.onchain_timestamp_ms) });
        }
    }
    return updates;
}

function updateAliases(row: ScenarioRow, receipt: ExecutionReceipt, aliases: Aliases): void {
    if (row.action === "mint") {
        const id = decimal(eventJson(onlyEvent(receipt, "OrderMinted")).order_id);
        aliases.orderIds.set(row.orderRef, id); aliases.orderRefs.set(id, row.orderRef);
    } else if (row.action === "redeem_live") {
        const value = eventJson(onlyEvent(receipt, "LiveOrderRedeemed"));
        const old = aliases.orderIds.get(row.orderRef);
        if (old) { aliases.orderIds.delete(row.orderRef); aliases.orderRefs.delete(old) }
        const replacement = optionDecimal(value.replacement_order_id);
        if (replacement !== null) {
            const ref = row.replacementOrderRef ?? row.orderRef;
            aliases.orderIds.set(ref, replacement); aliases.orderRefs.set(replacement, ref);
        }
    } else if (row.action === "redeem_settled") {
        const id = aliases.orderIds.get(row.orderRef);
        if (id) { aliases.orderIds.delete(row.orderRef); aliases.orderRefs.delete(id) }
    }
}

async function stateSnapshot(state: SimState): Promise<Record<string, string>> {
    const value = await readPredictEconomicState({ poolVaultId: state.poolVaultId, expiryMarketId: state.expiryMarketId, wrapperId: state.accountWrapperId });
    return {
        account_dusdc_balance: value.accountDusdcBalance.toString(),
        account_plp_balance: value.accountPlpBalance.toString(),
        expiry_cash_balance: value.expiryCashBalance.toString(),
        payout_liability: value.payoutLiability.toString(), required_cash: value.requiredCash.toString(),
        fee_incentive_balance: value.feeIncentiveBalance.toString(),
        vault_idle_balance: value.vaultIdleBalance.toString(),
        vault_protocol_reserve_balance: value.vaultProtocolReserveBalance.toString(),
        vault_pending_protocol_profit: value.vaultPendingProtocolProfit.toString(),
        profit_basis_debits: value.profitBasisDebits.toString(),
        profit_basis_credits: value.profitBasisCredits.toString(),
        vault_total_plp_supply: value.vaultTotalPlpSupply.toString(),
        supply_requests_pending: value.supplyRequestsPending.toString(),
        withdraw_requests_pending: value.withdrawRequestsPending.toString(),
        is_settled: value.isSettled ? "1" : "0",
        active_market_count: value.activeMarketCount.toString(),
    };
}
function traceStep(row: ScenarioRow, receipt: ExecutionReceipt, wallMs: number, timestampMs: number): LocalTraceStep {
    return { step: row.step, action: row.action, digest: receipt.digest, pricingTimestampMs: timestampMs, wallMs, gas: receipt.gas, events: receipt.events.map((event: any) => ({ type: eventName(event), full_type: String(event.type ?? ""), parsedJson: event.parsedJson ?? {} })) };
}
function oracleParams(value: OracleRefreshData) {
    return { spot: value.spot, forward: value.forward, svi: { a: value.a, aNegative: value.aNegative, b: value.b, rho: value.rho, rhoNegative: value.rhoNegative, m: value.m, mNegative: value.mNegative, sigma: value.sigma } };
}

async function executeRow(row: ScenarioRow, state: SimState, aliases: Aliases): Promise<ExecutionReceipt> {
    const common = { expiryMarketId: state.expiryMarketId, protocolConfigId: state.protocolConfigId, wrapperId: state.accountWrapperId, pythFeedId: state.pythFeedId, bsValueStoreId: state.bsValueStoreId, bsSviStoreId: state.bsSviStoreId };
    if (row.action === "mint") return execute(() => refreshOracleAndMintTxs({ ...common, expiry: BigInt(state.expiryMs), ...oracleParams(row), strike: row.strike, isUp: row.isUp, quantity: row.quantity, tickSize: BigInt(state.tickSize) }), `scenario_${row.step}_mint`);
    if (row.action === "redeem_live") {
        const orderId = aliases.orderIds.get(row.orderRef);
        if (!orderId) throw new Error(`unknown order_ref ${row.orderRef}`);
        return execute(() => refreshOracleAndRedeemTxs({ ...common, expiry: BigInt(state.expiryMs), ...oracleParams(row.oracleRefresh), orderId, closeQuantity: row.closeQuantity }), `scenario_${row.step}_redeem_live`);
    }
    if (row.action === "request_supply") return execute(() => requestSupplyTx({ poolVaultId: state.poolVaultId, protocolConfigId: state.protocolConfigId, wrapperId: state.accountWrapperId, amount: row.amount, minPlpOut: row.minOutput }), `scenario_${row.step}_request_supply`);
    if (row.action === "request_withdraw") return execute(() => requestWithdrawTx({ poolVaultId: state.poolVaultId, protocolConfigId: state.protocolConfigId, wrapperId: state.accountWrapperId, shares: row.shares, minDusdcOut: row.minOutput }), `scenario_${row.step}_request_withdraw`);
    if (row.action === "flush") {
        if (row.oracleRefresh === null) return execute(() => bareFlushTx({ poolVaultId: state.poolVaultId, protocolConfigId: state.protocolConfigId, lifecycleCapId: state.lifecycleCapId }), `scenario_${row.step}_flush_empty`);
        const oracle = row.oracleRefresh;
        return execute(() => refreshOracleAndFlushTxs({ ...common, poolVaultId: state.poolVaultId, lifecycleCapId: state.lifecycleCapId, expiry: BigInt(state.expiryMs), ...oracleParams(oracle) }), `scenario_${row.step}_flush`);
    }
    if (row.action === "rebalance_expiry_cash") return execute(() => rebalanceExpiryCashTx({ poolVaultId: state.poolVaultId, protocolConfigId: state.protocolConfigId, expiryMarketId: state.expiryMarketId }), `scenario_${row.step}_rebalance_expiry_cash`);
    if (row.action === "settle") {
        while ((await clockTimestampMs()) < BigInt(state.expiryMs)) await new Promise((resolve) => setTimeout(resolve, 100));
        return execute(() => keeperSettleTx({ pythFeedId: state.pythFeedId, bsValueStoreId: state.bsValueStoreId, expiryMs: BigInt(state.expiryMs), price: row.settlementPrice, marketId: state.expiryMarketId, poolVaultId: state.poolVaultId, protocolConfigId: state.protocolConfigId }), `scenario_${row.step}_settle`);
    }
    const orderId = aliases.orderIds.get(row.orderRef);
    if (!orderId) throw new Error(`unknown order_ref ${row.orderRef}`);
    return execute(() => redeemSettledTx({ expiryMarketId: state.expiryMarketId, protocolConfigId: state.protocolConfigId, wrapperId: state.accountWrapperId, orderId, permissionless: row.permissionless }), `scenario_${row.step}_redeem_settled`);
}

function createdObjectId(result: any, typeName: string): string {
    const change = result.objectChanges.find((candidate: any) => candidate.type === "created" && String(candidate.objectType).includes(typeName));
    if (!change?.objectId) throw new Error(`setup did not create ${typeName}`);
    return change.objectId;
}
async function alignCreation(periodMs: bigint): Promise<void> {
    const now = await clockTimestampMs();
    const remaining = periodMs - (now % periodMs);
    if (remaining < 50_000n) await new Promise((resolve) => setTimeout(resolve, Number(remaining + 100n)));
}

async function setup(config: ScenarioConfig, seed: OracleRefreshData): Promise<SimState> {
    console.log(`[${ts()}] setup current Predict topology`);
    await executeAndWait(finalizeDusdcCurrencyRegistrationTx(), "finalize_dusdc_currency_registration");
    const capResult = await executeAndWait(mintLifecycleCapTx(address), "mint_lifecycle_cap");
    const lifecycleCapId = createdObjectId(capResult, "MarketLifecycleCap");
    const feedResult = await executeAndWait(registerUnderlyingAndCreateFeedsTx(), "register_underlying_and_create_feeds");
    const pythFeedId = createdObjectId(feedResult, "pyth_feed::PythFeed");
    const bsValueStoreId = createdObjectId(feedResult, "BlockScholesValueStore");
    const bsSviStoreId = createdObjectId(feedResult, "BlockScholesSVIStore");
    await executeAndWait(bindFeedsToUnderlyingTx({ pythFeedId }), "bind_feeds_to_underlying");
    const policy = (key: string) => integer(config.protocol[key], `scenario config.protocol.${key}`);
    await executeAndWait(setSimulationEconomicPolicyTx({
        protocolConfigId: PROTOCOL_CONFIG_ID, baseFee: policy("base_fee"), minFee: policy("min_fee"),
        minEntryProbability: policy("min_entry_probability"), maxEntryProbability: policy("max_entry_probability"),
        backingBufferLambda: policy("backing_buffer_lambda"), inventorySkewRate: policy("inventory_skew_rate"),
        protocolReserveProfitShare: policy("protocol_reserve_profit_share"), plpSupplyFeeRate: policy("plp_supply_fee_rate"),
        plpWithdrawFeeRate: policy("plp_withdraw_fee_rate"), lpRequestLimitFlushAttempts: policy("lp_request_limit_flush_attempts"),
        maxLpPoolValue: policy("max_lp_pool_value"),
    }), "set_simulation_economic_policy");
    await executeAndWait(setTemplateExpiryFeeConfigTx(PROTOCOL_CONFIG_ID, policy("expiry_fee_window_ms"), policy("expiry_fee_max_multiplier")), "set_template_expiry_fee_config");
    const marketValue = (key: string) => integer(config.market[key], `scenario config.market.${key}`);
    const periodMs = marketValue("cadence_period_ms");
    const tickSize = marketValue("tick_size");
    const initialExpiryCash = marketValue("initial_expiry_cash");
    await executeAndWait(setCadenceConfigTx({ cadenceId: config.market.cadence_id, tickSize, admissionTickSize: marketValue("admission_tick_size"), maxExpiryAllocation: marketValue("max_expiry_allocation"), initialExpiryCash, windowSize: marketValue("cadence_window_size") }), "set_template_cadence_config");
    await executeAndWait(updatePythTrustedSignerTx(), "update_pyth_trusted_signer");
    await executeAndWait(setBlockScholesSignerTx(), "set_block_scholes_signer");
    const accountWrapperId = deriveAccountWrapperId(address);
    await executeAndWait(createAccountTx(), "create_account");
    await executeAndWait(depositToAccountTx(accountWrapperId, integer(config.capital.manager_seed, "scenario config.capital.manager_seed")), "fund_simulation_account");
    await executeAndWait(lockCapitalTx(POOL_VAULT_ID), "bootstrap_lock_capital");
    await executeAndWait(requestSupplyTx({ poolVaultId: POOL_VAULT_ID, protocolConfigId: PROTOCOL_CONFIG_ID, wrapperId: accountWrapperId, amount: integer(config.capital.vault_seed, "scenario config.capital.vault_seed") }), "bootstrap_request_supply");
    await executeAndWait(bareFlushTx({ poolVaultId: POOL_VAULT_ID, protocolConfigId: PROTOCOL_CONFIG_ID, lifecycleCapId }), "bootstrap_flush");
    await alignCreation(periodMs);
    const marketResult = await executeAndWait(createExpiryMarketTx({ poolVaultId: POOL_VAULT_ID, protocolConfigId: PROTOCOL_CONFIG_ID, lifecycleCapId, cadenceId: config.market.cadence_id }), "create_and_share_expiry_market");
    const expiryMarketId = createdObjectId(marketResult, "ExpiryMarket");
    const expiryMs = decimal(eventJson(onlyEvent(marketResult, "MarketCreated")).expiry);
    if (marketResult.clockTimestampMs === null) throw new Error("market creation did not record its Clock timestamp");
    const creationTimestampMs = BigInt(marketResult.clockTimestampMs);
    const expectedExpiry = ((creationTimestampMs / periodMs) + 1n) * periodMs;
    if (BigInt(expiryMs) !== expectedExpiry) throw new Error(`expected cadence expiry ${expectedExpiry}, got ${expiryMs}`);
    await executeAndWait(await seedOracleTx({ pythFeedId, bsValueStoreId, bsSviStoreId, expiry: BigInt(expiryMs), ...oracleParams(seed) }), "seed_oracle_surface");
    await executeAndWait(rebalanceExpiryCashTx({ poolVaultId: POOL_VAULT_ID, protocolConfigId: PROTOCOL_CONFIG_ID, expiryMarketId }), "bootstrap_rebalance_expiry_cash");
    const state: SimState = { poolVaultId: POOL_VAULT_ID, protocolConfigId: PROTOCOL_CONFIG_ID, expiryMarketId, expiryMs, pythFeedId, bsValueStoreId, bsSviStoreId, accountWrapperId, lifecycleCapId, initialExpiryCash: initialExpiryCash.toString(), tickSize: tickSize.toString() };
    writeJson(STATE_PATH, state);
    return state;
}

function clearArtifacts(): void {
    for (const path of [LOCAL_TRACE_PATH, LOCAL_DATA_PATH, LOCAL_TRACE_PARTIAL_PATH, LOCAL_DATA_PARTIAL_PATH, PYTHON_DATA_PATH]) if (existsSync(path)) rmSync(path);
}
function runPython(scenario: string, expiryMs: string, maxRows?: number): void {
    const script = fileURLToPath(new URL("../python_replay.py", import.meta.url));
    const args = [script, "--scenario", scenario, "--out", PYTHON_DATA_PATH, "--pricing-trace", LOCAL_TRACE_PATH, "--expiry-ms", expiryMs];
    if (maxRows !== undefined) args.push("--max-rows", String(maxRows));
    const result = spawnSync("python3", args, { stdio: "inherit", env: process.env });
    if (result.status !== 0) throw new Error(`python replay failed with exit code ${result.status}`);
}

async function replay(rows: ScenarioRow[], state: SimState, scenario: string, maxRows?: number): Promise<void> {
    clearArtifacts();
    const aliases: Aliases = { orderIds: new Map(), orderRefs: new Map() };
    const observed: ScenarioActionName[] = [];
    const records: EconomicRecord[] = [];
    const steps: LocalTraceStep[] = [];
    const data = (): EconomicDataFile => ({ schema_version: ECONOMIC_SCHEMA_VERSION, scenario: { quantity_scale: scenarioQuantityScale(), required_actions: REQUIRED_ACTIONS, observed_actions: observed }, records });
    const trace = (): LocalTraceFile => ({ schema_version: LOCAL_TRACE_SCHEMA_VERSION, steps });
    try {
        for (const row of rows) {
            const started = performance.now();
            const receipt = await executeRow(row, state, aliases);
            const step = traceStep(row, receipt, performance.now() - started, receipt.clockTimestampMs ?? 0);
            steps.push(step);
            if (receipt.clockTimestampMs === null) step.pricingTimestampMs = Number(await clockTimestampMs());
            const updates = normalizeUpdates(row, receipt, aliases);
            updateAliases(row, receipt, aliases);
            records.push({ step: row.step, action: row.action, input: rowInput(row, BigInt(state.tickSize)), updates, state: await stateSnapshot(state) });
            if (!observed.includes(row.action)) observed.push(row.action);
            console.log(`[${ts()}] [${row.step}/${rows.length}] ${row.action}`);
        }
    } catch (error) {
        if (steps.length > 0) writeJson(LOCAL_TRACE_PARTIAL_PATH, trace());
        if (records.length > 0) writeJson(LOCAL_DATA_PARTIAL_PATH, data());
        throw error;
    }
    const missing = REQUIRED_ACTIONS.filter((action) => !observed.includes(action));
    if (missing.length > 0) throw new Error(`scenario did not execute required actions: ${missing.join(",")}`);
    writeJson(LOCAL_TRACE_PATH, trace()); writeJson(LOCAL_DATA_PATH, data());
    runPython(scenario, state.expiryMs, maxRows);
}

async function main(): Promise<void> {
    const args = parseArgs();
    const config = readJson<ScenarioConfig>(CONFIG_PATH);
    if (config.schema_version !== 2) throw new Error(`unsupported scenario config schema ${config.schema_version}`);
    let rows = loadScenario(args.scenario);
    if (args.maxRows !== undefined) rows = rows.slice(0, args.maxRows);
    validateCompleteScenario(rows);
    const seed = rows.map(oracleFor).find((value): value is OracleRefreshData => value !== null);
    if (!seed) throw new Error("scenario has no oracle snapshot for setup");
    const state = await setup(config, seed);
    await replay(rows, state, args.scenario, args.maxRows);
    console.log(`[${ts()}] parity artifacts written for ${rows.length} explicit actions`);
}

main().catch((error) => { console.error("Simulation failed:", error); process.exitCode = 1 });
