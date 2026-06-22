import { existsSync, unlinkSync } from "fs";
import { spawnSync } from "child_process";
import { fileURLToPath } from "url";

import {
    ECONOMIC_SCHEMA_VERSION,
    LOCAL_DATA_PATH,
    LOCAL_TRACE_PATH,
    LOCAL_TRACE_SCHEMA_VERSION,
    PYTHON_DATA_PATH,
    SCENARIO_PATH as DEFAULT_SCENARIO_PATH,
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
    bindFeedsToUnderlyingTx,
    createAccountTx,
    createExpiryMarketTx,
    depositToAccountTx,
    deriveAccountWrapperId,
    execute,
    executeAndWait,
    finalizeDusdcCurrencyRegistrationTx,
    MIN_BOOTSTRAP_LIQUIDITY,
    lockCapitalTx,
    mintLifecycleCapTx,
    rebalanceExpiryCashTx,
    refreshOracleAndFlushTx,
    refreshOracleAndMintTx,
    refreshOracleAndRedeemTx,
    registerUnderlyingAndCreateFeedsTx,
    requestSupplyTx,
    requestWithdrawTx,
    seedOracleTx,
    setCadenceConfigTx,
    setTemplateExpiryFeeConfigTx,
    setTemplateTerminalFloorIndexTx,
    type ExecutionReceipt,
    updatePythTrustedSignerTx,
} from "./runtime.js";

const DUSDC_DECIMALS = 1_000_000n;
const DEFAULT_VAULT_SEED = 500_000n * DUSDC_DECIMALS;
const DEFAULT_MANAGER_SEED = 500_000n * DUSDC_DECIMALS;
const EXPIRY_CASH_FLOOR = 10_000n * DUSDC_DECIMALS;
const FLOAT_SCALING = 1_000_000_000n;
const DEFAULT_EXPIRY_FEE_WINDOW_MS = 24n * 60n * 60n * 1000n;
const DEFAULT_SIM_TERMINAL_FLOOR_INDEX = FLOAT_SCALING;
const SIM_CADENCE_ONE_MONTH = 5;
const SIM_CADENCE_WINDOW_SIZE = 1n;
const DEFAULT_MAX_EXPIRY_ALLOCATION = 250_000n * DUSDC_DECIMALS;
const SCENARIO_CONFIG_PATH = fileURLToPath(
    new URL("../data/scenario_config.json", import.meta.url),
);
// Absolute-tick strike domain (range_codec / constants.move): `raw_strike =
// tick * tick_size`, no centered grid. The harness tick size is $1 (1e9-scaled).
// A strike is encoded as a tick; the only validity bound is the finite tick
// domain `1..POS_INF_TICK - 1`.
const ORACLE_TICK_SIZE = 1n * FLOAT_SCALING;
const TICK_BITS = 24n;
const POS_INF_TICK = (1n << TICK_BITS) - 1n;
const ORDER_SEQUENCE_MASK = (1n << 40n) - 1n;

interface SimulationCapital {
    vaultSeed: bigint;
    managerSeed: bigint;
    initialTotalPlpSupply: bigint;
}

interface EconomicState {
    managerBalance: bigint;
    expiryCashBalance: bigint;
    expiryUnresolvedTradingFees: bigint;
    vaultIdleBalance: bigint;
    vaultProtocolReserveBalance: bigint;
    profitBasisDebits: bigint;
    profitBasisCredits: bigint;
    vaultTotalPlpSupply: bigint;
    openOrderCount: bigint;
    openOrderQuantity: bigint;
    liquidatedOrderCount: bigint;
}

interface AliasState {
    orderIdsByRef: Map<string, string>;
    orderRefsById: Map<string, string>;
    // LP requests are now keyed by their queue index (the cancel handle returned by
    // request_supply / request_withdraw), not a returned PLP coin object — the async
    // flush delivers fills to the account via the balance accumulator, so no PLP coin
    // is created in the request tx.
    lpRequestIndexByRef: Map<string, bigint>;
    // Supply DUSDC amount per lp_ref, recorded at the supply row. A withdraw row
    // fully unwinds its referenced supply, so this is the PLP-share amount it targets
    // (PLP is ~1:1 with DUSDC near the bootstrap mark).
    lpAmountByRef: Map<string, bigint>;
    // PLP shares the account has materialized (settle-able) and not yet withdrawn.
    // Seeded with the bootstrap supply (minted 1:1 at setup). Under the batched-flush
    // cadence, scenario supplies are NOT credited here until/unless a flush mints them,
    // so withdraws draw against the bootstrap PLP — a deliberately conservative bound
    // that never over-withdraws (actual settled PLP is always >= this).
    availableSettledPlp: bigint;
}

function parseArgs() {
    let maxRows: number | undefined;
    let skipPython = false;
    const args = process.argv.slice(2);
    for (let i = 0; i < args.length; i++) {
        if (args[i] === "--skip-python") {
            skipPython = true;
            continue;
        }
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
    return { maxRows, skipPython };
}

function scenarioPath(): string {
    const configured = process.env.SCENARIO_PATH?.trim();
    return configured && configured.length > 0 ? configured : DEFAULT_SCENARIO_PATH;
}

function initialEconomicState(capital: SimulationCapital): EconomicState {
    if (capital.vaultSeed < EXPIRY_CASH_FLOOR) {
        throw new Error("vault seed is below the setup expiry cash floor");
    }

    return {
        managerBalance: capital.managerSeed,
        expiryCashBalance: EXPIRY_CASH_FLOOR,
        expiryUnresolvedTradingFees: 0n,
        vaultIdleBalance: capital.vaultSeed - EXPIRY_CASH_FLOOR,
        vaultProtocolReserveBalance: 0n,
        profitBasisDebits: EXPIRY_CASH_FLOOR,
        profitBasisCredits: 0n,
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
        lpRequestIndexByRef: new Map(),
        lpAmountByRef: new Map(),
        availableSettledPlp: 0n,
    };
}

// Snap a raw strike DOWN to its tick boundary, then back to a raw strike. With the
// absolute-tick domain there is no grid to center; alignment is just flooring to a
// whole tick multiple. The tick must land in the finite domain `1..POS_INF_TICK-1`.
function alignStrikeToTick(strike: bigint): bigint {
    if (strike <= 0n) throw new Error("strike must be positive");
    const tick = strike / ORACLE_TICK_SIZE;
    if (tick <= 0n || tick >= POS_INF_TICK) {
        throw new Error(
            `strike tick ${tick} outside the finite tick domain (1..POS_INF_TICK-1); ` +
                "raise the oracle tick size to cover a higher strike",
        );
    }
    return tick * ORACLE_TICK_SIZE;
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
    return (
        String(event.type ?? "")
            .split("::")
            .pop() ?? ""
    );
}

function findEvent(events: any[], name: string): any | undefined {
    return events.find(
        (event) => eventName(event) === name || String(event.type ?? "").includes(name),
    );
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

// The canonical mint input is the `(lower_tick, higher_tick)` pair the contract
// takes at the entrypoint directly (there is no standalone packed range key; only
// the order ID packs the ticks).
function mintInput(row: MintRow): Record<string, string> {
    const strike = alignStrikeToTick(row.strike);
    const { lowerTick, higherTick } = binaryRangeTicks(strike, row.isUp);
    return {
        order_ref: row.orderRef,
        lower_tick: lowerTick.toString(),
        higher_tick: higherTick.toString(),
        quantity: row.quantity.toString(),
        leverage: row.leverage.toString(),
    };
}

// Ticks for a binary range. UP `(strike, +inf)` -> (strike/tick, POS_INF_TICK);
// DOWN `(-inf, strike)` -> (0 = neg-inf, strike/tick). Mirrors range_codec.
function binaryRangeTicks(strike: bigint, isUp: boolean): { lowerTick: bigint; higherTick: bigint } {
    const tick = strike / ORACLE_TICK_SIZE;
    return isUp
        ? { lowerTick: tick, higherTick: POS_INF_TICK }
        : { lowerTick: 0n, higherTick: tick };
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

function eventObservationValue(event: any): any {
    const json = event.parsedJson ?? {};
    const observation = json.observation?.fields ?? json.observation ?? {};
    return observation.value?.fields ?? observation.value ?? {};
}

function pow10(exp: bigint): bigint {
    return 10n ** exp;
}

function normalizedPythSpot(raw: any): string {
    if (booleanField(raw.price_is_negative ?? raw.priceIsNegative ?? false)) {
        throw new Error("simulation Pyth spot event was negative");
    }
    const magnitude = BigInt(decimal(raw.price_magnitude ?? raw.priceMagnitude));
    const exponentMagnitude = BigInt(decimal(raw.exponent_magnitude ?? raw.exponentMagnitude));
    const exponentIsNegative = booleanField(
        raw.exponent_is_negative ?? raw.exponentIsNegative ?? false,
    );
    if (!exponentIsNegative) return (magnitude * pow10(exponentMagnitude + 9n)).toString();
    if (exponentMagnitude > 9n) return (magnitude / pow10(exponentMagnitude - 9n)).toString();
    return (magnitude * pow10(9n - exponentMagnitude)).toString();
}

// propbook `ObservationRecorded<OracleRead<RawSpot>>`: the global Pyth spot.
// Timestamps are localnet-clock-derived, so they are intentionally excluded from
// the parity diff.
function normalizePythObservation(event: any): Record<string, unknown> {
    const raw = eventObservationValue(event);
    return {
        type: "pyth_feed_updated",
        spot: normalizedPythSpot(raw),
    };
}

// propbook `ObservationRecorded<OracleRead<RawSurface>>`: this expiry's surface
// (spot + forward + SVI). `basis` is not an event field; consumers derive it as
// forward/spot. Timestamps are localnet-clock-derived -> not diffed.
function normalizeBlockScholesObservation(event: any): Record<string, unknown> {
    const raw = eventObservationValue(event);
    const svi = raw.svi?.fields ?? raw.svi ?? {};
    return {
        type: "block_scholes_surface_updated",
        spot: decimal(raw.spot),
        forward: decimal(raw.forward),
        a: decimal(svi.a),
        b: decimal(svi.b),
        rho: signedI64(svi.rho),
        m: signedI64(svi.m),
        sigma: decimal(svi.sigma),
    };
}

function normalizeOrderMinted(event: any, row: ScenarioRow): Record<string, unknown> {
    const json = event.parsedJson ?? {};
    const orderRef = row.action === "oracle_mint_ptb" ? row.orderRef : null;
    return {
        type: "order_minted",
        order_ref: orderRef,
        order_sequence: orderSequence(decimal(json.order_id)),
        lower_tick: decimal(json.lower_tick),
        higher_tick: decimal(json.higher_tick),
        leverage: decimal(json.leverage),
        entry_probability: decimal(json.entry_probability),
        quantity: decimal(json.quantity),
        contribution: decimal(json.net_premium),
        trading_fee: decimal(json.trading_fee),
        fee_incentive_subsidy: decimal(json.fee_incentive_subsidy ?? 0),
        builder_fee: decimal(json.builder_fee),
        penalty_fee: decimal(json.penalty_fee),
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
            ? (row.replacementOrderRef ?? row.orderRef)
            : null;
    return {
        type: "live_order_redeemed",
        order_ref: row.action === "redeem" ? row.orderRef : null,
        order_sequence: orderSequence(decimal(json.order_id)),
        quantity_closed: decimal(json.quantity_closed),
        remaining_quantity: decimal(json.remaining_quantity),
        replacement_order_ref: replacementRef,
        replacement_order_sequence:
            replacementOrderId === null ? null : orderSequence(replacementOrderId),
        redeem_amount: decimal(json.redeem_amount),
        trading_fee: decimal(json.trading_fee),
        builder_fee: decimal(json.builder_fee),
        penalty_fee: decimal(json.penalty_fee),
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

// === Async LP request/flush events. A supply/withdraw is a two-phase flow: a request
// row escrows funds (SupplyRequested / WithdrawRequested), and a later flush drains the
// queues at one frozen mark, emitting per-request SupplyFilled / WithdrawFilled and a
// single FlushExecuted that carries the frozen valuation (the former PoolValued fields
// were folded into it). Cancels emit RequestCancelled, which the sim never triggers.
// The `index` queue handle is the request alias key (no PLP coin is returned).

function normalizeSupplyRequested(event: any, row: ScenarioRow): Record<string, unknown> {
    const json = event.parsedJson ?? {};
    return {
        type: "supply_requested",
        lp_ref: row.action === "supply" ? row.lpRef : null,
        index: decimal(json.index),
        amount: decimal(json.amount),
    };
}

function normalizeWithdrawRequested(event: any, row: ScenarioRow): Record<string, unknown> {
    const json = event.parsedJson ?? {};
    return {
        type: "withdraw_requested",
        lp_ref: row.action === "withdraw" ? row.lpRef : null,
        index: decimal(json.index),
        amount: decimal(json.amount),
    };
}

function normalizeSupplyFilled(event: any): Record<string, unknown> {
    const json = event.parsedJson ?? {};
    return {
        type: "supply_filled",
        index: decimal(json.index),
        dusdc_amount: decimal(json.dusdc_amount),
        shares_minted: decimal(json.shares_minted),
    };
}

function normalizeWithdrawFilled(event: any): Record<string, unknown> {
    const json = event.parsedJson ?? {};
    return {
        type: "withdraw_filled",
        index: decimal(json.index),
        shares_burned: decimal(json.shares_burned),
        dusdc_amount: decimal(json.dusdc_amount),
    };
}

// FlushExecuted now carries the frozen valuation the former PoolValued event held
// (pool_value, active_market_nav, market_count, idle_balance_before) plus the drain
// counts and post-drain idle. Only idle_balance_after feeds tracked state; the rest
// are observability/parity fields.
function normalizeFlushExecuted(event: any): Record<string, unknown> {
    const json = event.parsedJson ?? {};
    return {
        type: "flush_executed",
        pool_value: decimal(json.pool_value),
        total_supply: decimal(json.total_supply),
        active_market_nav: decimal(json.active_market_nav),
        market_count: decimal(json.market_count),
        idle_balance_before: decimal(json.idle_balance_before),
        supplies_filled: decimal(json.supplies_filled),
        withdrawals_filled: decimal(json.withdrawals_filled),
        requests_processed: decimal(json.requests_processed),
        idle_balance_after: decimal(json.idle_balance_after),
    };
}

function normalizeExpiryCashRebalanced(event: any): Record<string, unknown> {
    const json = event.parsedJson ?? {};
    return {
        type: "expiry_cash_rebalanced",
        amount: decimal(json.amount),
        to_expiry: booleanField(json.to_expiry),
        target_cash: decimal(json.target_cash),
        expiry_cash_after: decimal(json.expiry_cash_after),
        idle_balance_after: decimal(json.idle_balance_after),
        sent_to_expiry_after: decimal(json.sent_to_expiry_after),
        received_from_expiry_after: decimal(json.received_from_expiry_after),
    };
}

function normalizeExpiryCashReceived(event: any): Record<string, unknown> {
    const json = event.parsedJson ?? {};
    return {
        type: "expiry_cash_received",
        settlement_price: decimal(json.settlement_price),
        amount: decimal(json.amount),
        idle_balance_after: decimal(json.idle_balance_after),
        sent_to_expiry_after: decimal(json.sent_to_expiry_after),
        received_from_expiry_after: decimal(json.received_from_expiry_after),
    };
}

function normalizeExpiryProfitMaterialized(event: any): Record<string, unknown> {
    const json = event.parsedJson ?? {};
    return {
        type: "expiry_profit_materialized",
        expiry_market_id: json.expiry_market_id ?? null,
        lp_profit: decimal(json.lp_profit),
        protocol_profit: decimal(json.protocol_profit),
        idle_balance_after: decimal(json.idle_balance_after),
        protocol_reserve_balance_after: decimal(json.protocol_reserve_balance_after),
        profit_basis_after: decimal(json.profit_basis_after),
    };
}

function normalizeUpdates(
    row: ScenarioRow,
    receipt: ExecutionReceipt,
    aliases: AliasState,
): Record<string, unknown>[] {
    const updates: Record<string, unknown>[] = [];
    for (const event of receipt.events) {
        const fullType = String(event.type ?? "");
        const name = eventName(event);
        if (
            fullType.includes("::oracle_lane::ObservationRecorded") &&
            fullType.includes("::pyth_feed::RawSpot")
        )
            updates.push(normalizePythObservation(event));
        else if (
            fullType.includes("::oracle_lane::ObservationRecorded") &&
            fullType.includes("::block_scholes_feed::RawSurface")
        )
            updates.push(normalizeBlockScholesObservation(event));
        else if (name === "OrderLiquidated") updates.push(normalizeOrderLiquidated(event, aliases));
        else if (name === "OrderMinted") updates.push(normalizeOrderMinted(event, row));
        else if (name === "LiveOrderRedeemed") updates.push(normalizeLiveOrderRedeemed(event, row));
        else if (name === "LiquidatedOrderRedeemed")
            updates.push(normalizeLiquidatedOrderRedeemed(event, row));
        else if (name === "SettledOrderRedeemed")
            updates.push(normalizeSettledOrderRedeemed(event, row));
        else if (name === "SupplyRequested") updates.push(normalizeSupplyRequested(event, row));
        else if (name === "WithdrawRequested") updates.push(normalizeWithdrawRequested(event, row));
        else if (name === "SupplyFilled") updates.push(normalizeSupplyFilled(event));
        else if (name === "WithdrawFilled") updates.push(normalizeWithdrawFilled(event));
        else if (name === "FlushExecuted") updates.push(normalizeFlushExecuted(event));
        else if (name === "ExpiryCashRebalanced")
            updates.push(normalizeExpiryCashRebalanced(event));
        else if (name === "ExpiryCashReceived") updates.push(normalizeExpiryCashReceived(event));
        else if (name === "ExpiryProfitMaterialized")
            updates.push(normalizeExpiryProfitMaterialized(event));
    }
    return updates;
}

function applyUpdate(state: EconomicState, update: Record<string, unknown>) {
    if (update.type === "order_minted") {
        const contribution = BigInt(decimal(update.contribution));
        const tradingFee = BigInt(decimal(update.trading_fee));
        const feeIncentiveSubsidy = BigInt(decimal(update.fee_incentive_subsidy ?? 0));
        const builderFee = BigInt(decimal(update.builder_fee));
        const penaltyFee = BigInt(decimal(update.penalty_fee));
        const quantity = BigInt(decimal(update.quantity));
        state.managerBalance -=
            contribution + (tradingFee - feeIncentiveSubsidy) + builderFee + penaltyFee;
        state.expiryCashBalance += contribution + tradingFee + penaltyFee;
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
        const penaltyFee = BigInt(decimal(update.penalty_fee));
        const quantityClosed = BigInt(decimal(update.quantity_closed));
        const remainingQuantity = BigInt(decimal(update.remaining_quantity));
        state.managerBalance += redeemAmount - tradingFee - builderFee - penaltyFee;
        state.expiryCashBalance -= redeemAmount;
        state.expiryCashBalance += tradingFee + penaltyFee;
        state.expiryUnresolvedTradingFees += tradingFee;
        state.openOrderQuantity -= quantityClosed;
        if (remainingQuantity === 0n) state.openOrderCount -= 1n;
    } else if (update.type === "liquidated_order_redeemed") {
        state.liquidatedOrderCount -= 1n;
    } else if (update.type === "settled_order_redeemed") {
        const payout = BigInt(decimal(update.payout_amount));
        const quantityClosed = BigInt(decimal(update.quantity_closed));
        state.managerBalance += payout;
        state.expiryCashBalance -= payout;
        state.openOrderCount -= 1n;
        state.openOrderQuantity -= quantityClosed;
    } else if (update.type === "expiry_cash_rebalanced") {
        const amount = BigInt(decimal(update.amount));
        state.expiryCashBalance = BigInt(decimal(update.expiry_cash_after));
        state.vaultIdleBalance = BigInt(decimal(update.idle_balance_after));
        if (update.to_expiry === true) {
            state.profitBasisDebits += amount;
        } else {
            state.profitBasisCredits += amount;
        }
    } else if (update.type === "expiry_cash_received") {
        const amount = BigInt(decimal(update.amount));
        state.expiryCashBalance -= amount;
        state.vaultIdleBalance = BigInt(decimal(update.idle_balance_after));
        state.profitBasisCredits += amount;
    } else if (update.type === "expiry_profit_materialized") {
        const profitBasisAfter = BigInt(decimal(update.profit_basis_after));
        state.vaultIdleBalance = BigInt(decimal(update.idle_balance_after));
        state.vaultProtocolReserveBalance = BigInt(decimal(update.protocol_reserve_balance_after));
        state.profitBasisDebits = profitBasisAfter;
    } else if (update.type === "supply_filled") {
        // A supply fill mints PLP and joins its escrowed DUSDC into idle. PLP supply
        // grows by shares_minted; idle is reconciled by the FlushExecuted snapshot.
        state.vaultTotalPlpSupply += BigInt(decimal(update.shares_minted));
    } else if (update.type === "withdraw_filled") {
        // A withdraw fill burns PLP and pays DUSDC from idle. PLP supply shrinks by
        // shares_burned; idle is reconciled by the FlushExecuted snapshot.
        state.vaultTotalPlpSupply -= BigInt(decimal(update.shares_burned));
    } else if (update.type === "flush_executed") {
        // FlushExecuted carries the post-drain idle balance; trust it as the
        // authoritative idle after both queues drain at the frozen mark.
        state.vaultIdleBalance = BigInt(decimal(update.idle_balance_after));
    }
    // NOTE: supply_requested / withdraw_requested escrow funds OUTSIDE the tracked
    // vault/account balances (the request queue holds them); they move balances only
    // at the flush. They carry no state delta here.
    // TODO(sim-parity): the async request -> flush split changes WHEN PLP supply and
    // account balances move relative to the old synchronous supply/withdraw. The
    // account-side credit of a supply fill / withdraw payout now lands via the
    // balance accumulator (send_funds) and is absorbed lazily on the account's next
    // capital op, NOT in this tx. Confirm the exact manager_balance + PLP-supply
    // timing against a localnet run before trusting LP-row parity.
}

function stateSnapshot(state: EconomicState): Record<string, string> {
    return {
        manager_balance: state.managerBalance.toString(),
        expiry_cash_balance: state.expiryCashBalance.toString(),
        expiry_unresolved_trading_fees: state.expiryUnresolvedTradingFees.toString(),
        vault_idle_balance: state.vaultIdleBalance.toString(),
        vault_protocol_reserve_balance: state.vaultProtocolReserveBalance.toString(),
        profit_basis_debits: state.profitBasisDebits.toString(),
        profit_basis_credits: state.profitBasisCredits.toString(),
        vault_total_plp_supply: state.vaultTotalPlpSupply.toString(),
        open_order_count: state.openOrderCount.toString(),
        open_order_quantity: state.openOrderQuantity.toString(),
        liquidated_order_count: state.liquidatedOrderCount.toString(),
    };
}

function economicRecord(
    row: ScenarioRow,
    receipt: ExecutionReceipt,
    state: EconomicState,
    aliases: AliasState,
): EconomicRecord {
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

function traceStep(row: ScenarioRow, receipt: ExecutionReceipt, wallMs: number): LocalTraceStep {
    return {
        step: row.step,
        action: row.action,
        digest: receipt.digest,
        wallMs,
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

function requestIndex(receipt: ExecutionReceipt, name: string): bigint | null {
    const event = findEvent(receipt.events, name);
    if (!event) return null;
    const json = event.parsedJson ?? {};
    return json.index === undefined ? null : BigInt(decimal(json.index));
}

function eventDecimalField(receipt: ExecutionReceipt, name: string, field: string): string {
    const event = findEvent(receipt.events, name);
    if (!event) throw new Error(`Missing ${name} event`);
    const json = event.parsedJson ?? {};
    if (json[field] === undefined) throw new Error(`Missing ${name}.${field}`);
    return decimal(json[field]);
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
            eventOrderId(receipt, "LiquidatedOrderRedeemed") ??
            eventOrderId(receipt, "SettledOrderRedeemed");
        if (closedOrderId) {
            aliases.orderIdsByRef.delete(row.orderRef);
            aliases.orderRefsById.delete(closedOrderId);
        }
        return;
    }

    // A supply/withdraw row now ENQUEUES a request (the flush drains it later), so the
    // alias is the queue index, not a PLP coin object. The index is the cancel handle.
    if (row.action === "supply") {
        const index = requestIndex(receipt, "SupplyRequested");
        if (index === null) throw new Error(`Missing SupplyRequested event for ${row.lpRef}`);
        aliases.lpRequestIndexByRef.set(row.lpRef, index);
        aliases.lpAmountByRef.set(row.lpRef, row.amount);
    } else if (row.action === "withdraw") {
        const index = requestIndex(receipt, "WithdrawRequested");
        if (index === null) throw new Error(`Missing WithdrawRequested event for ${row.lpRef}`);
        aliases.lpRequestIndexByRef.set(row.lpRef, index);
    }
}

function mintContext(row: MintRow, alignedStrike: bigint): string {
    return `${row.action} csv_line=${row.lineNumber} ${direction(row)} strike=$${scaledUsd(alignedStrike)} quantity=${row.quantity} leverage=${formatLeverage(row.leverage)} ref=${row.orderRef}`;
}

function errorMessage(error: unknown): string {
    return error instanceof Error ? error.message : String(error);
}

// Row counts after which the runner synthesizes a privileged LP flush. Defaults to
// rows 300 and 999 (the chosen batched cadence); SIM_FLUSH_AFTER="a,b,..." overrides
// it for fast smoke runs.
function flushCheckpoints(): Set<number> {
    const raw = process.env.SIM_FLUSH_AFTER;
    if (raw) {
        return new Set(
            raw
                .split(",")
                .map((s) => Number(s.trim()))
                .filter((n) => Number.isInteger(n) && n > 0),
        );
    }
    return new Set([300, 999]);
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
    return {
        vaultSeed,
        managerSeed: capitalConfigValue(config, mode, "manager_seed", DEFAULT_MANAGER_SEED),
        initialTotalPlpSupply: vaultSeed,
    };
}

interface OracleSeedData {
    spot: bigint;
    forward: bigint;
    svi: {
        a: bigint;
        b: bigint;
        rho: bigint;
        rhoNegative: boolean;
        m: bigint;
        mNegative: boolean;
        sigma: bigint;
    };
}

// The first scenario row's full oracle snapshot (spot + forward + SVI). Used to
// seed the Block Scholes surface for the market's expiry before any mint. A mint
// row carries the SVI inline; every other action carries it under `oracleRefresh`.
function firstOracleData(row: ScenarioRow): OracleSeedData {
    const o = row.action === "oracle_mint_ptb" ? row : row.oracleRefresh;
    return {
        spot: o.spot,
        forward: o.forward,
        svi: {
            a: o.a,
            b: o.b,
            rho: o.rho,
            rhoNegative: o.rhoNegative,
            m: o.m,
            mNegative: o.mNegative,
            sigma: o.sigma,
        },
    };
}

async function setupSimulation(
    scenarioConfig: any,
    capital: SimulationCapital,
    seed: OracleSeedData,
): Promise<SimState> {
    console.log(`[${ts()}] --- Setup ---`);
    const expiryFeeMaxMultiplier = protocolConfigValue(
        scenarioConfig,
        "expiry_fee_max_multiplier",
        FLOAT_SCALING,
    );
    const expiryFeeWindowMs = protocolConfigValue(
        scenarioConfig,
        "expiry_fee_window_ms",
        DEFAULT_EXPIRY_FEE_WINDOW_MS,
    );
    const terminalFloorIndex = protocolConfigValue(
        scenarioConfig,
        "normal_terminal_floor_index",
        DEFAULT_SIM_TERMINAL_FLOOR_INDEX,
    );
    const maxExpiryAllocation = protocolConfigValue(
        scenarioConfig,
        "max_expiry_allocation",
        DEFAULT_MAX_EXPIRY_ALLOCATION,
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

    result = await executeAndWait(mintLifecycleCapTx(address), "mint_lifecycle_cap");
    const lifecycleCapChange = result.objectChanges.find(
        (change: any) => change.type === "created" && change.objectType.includes("MarketLifecycleCap"),
    );
    const lifecycleCapId: string = lifecycleCapChange.objectId;
    console.log(`[${ts()}]   LifecycleCap: ${lifecycleCapId}`);

    // Admin-approve the Propbook underlying AND create the two propbook feeds
    // (Pyth spot + Block Scholes surface). Both feed objects are shared; capture
    // their IDs.
    result = await executeAndWait(
        registerUnderlyingAndCreateFeedsTx(1),
        "register_underlying_and_create_feeds",
    );
    const pythFeedChange = result.objectChanges.find(
        (change: any) => change.type === "created" && change.objectType.includes("pyth_feed::PythFeed"),
    );
    const bsFeedChange = result.objectChanges.find(
        (change: any) =>
            change.type === "created" &&
            change.objectType.includes("block_scholes_feed::BlockScholesFeed"),
    );
    const pythFeedId: string = pythFeedChange.objectId;
    const bsFeedId: string = bsFeedChange.objectId;
    console.log(`[${ts()}]   PythFeed: ${pythFeedId}`);
    console.log(`[${ts()}]   BlockScholesFeed: ${bsFeedId}`);

    // Admin-bind both feeds to the canonical underlying so `create_expiry_market`
    // accepts the pair (separate tx: the feeds must already be shared).
    await executeAndWait(
        bindFeedsToUnderlyingTx({ pythFeedId, bsFeedId }),
        "bind_feeds_to_underlying",
    );
    console.log(`[${ts()}]   Feeds bound to underlying`);

    await executeAndWait(
        setTemplateExpiryFeeConfigTx(protocolConfigId, expiryFeeWindowMs, expiryFeeMaxMultiplier),
        "set_template_expiry_fee_config",
    );
    console.log(
        `[${ts()}]   Expiry fee ramp: window_ms=${expiryFeeWindowMs} max_multiplier=${expiryFeeMaxMultiplier}`,
    );

    await executeAndWait(
        setTemplateTerminalFloorIndexTx(protocolConfigId, terminalFloorIndex),
        "set_template_terminal_floor_index",
    );
    console.log(`[${ts()}]   Terminal floor index: ${terminalFloorIndex}`);

    await executeAndWait(
        setCadenceConfigTx({
            cadenceId: SIM_CADENCE_ONE_MONTH,
            tickSize: ORACLE_TICK_SIZE,
            maxExpiryAllocation,
            windowSize: SIM_CADENCE_WINDOW_SIZE,
        }),
        "set_cadence_config",
    );
    console.log(
        `[${ts()}]   Cadence configured: id=${SIM_CADENCE_ONE_MONTH} tick=$${scaledUsd(ORACLE_TICK_SIZE)} allocation=${maxExpiryAllocation / DUSDC_DECIMALS} DUSDC window=${SIM_CADENCE_WINDOW_SIZE}`,
    );

    await executeAndWait(updatePythTrustedSignerTx(), "update_pyth_trusted_signer");
    console.log(`[${ts()}]   Pyth trusted signer configured`);

    result = await executeAndWait(
        createExpiryMarketTx({
            poolVaultId,
            protocolConfigId,
            lifecycleCapId,
            cadenceId: SIM_CADENCE_ONE_MONTH,
        }),
        "create_expiry_market",
    );
    const expiryMarketChange = result.objectChanges.find(
        (change: any) => change.type === "created" && change.objectType.includes("ExpiryMarket"),
    );
    const expiryMarketId: string = expiryMarketChange.objectId;
    const expiryMsString = eventDecimalField(result, "MarketCreated", "expiry");
    const expiryMs = BigInt(expiryMsString);
    console.log(`[${ts()}]   ExpiryMarket: ${expiryMarketId} expiry=${expiryMsString}`);

    // Seed the Block Scholes surface + Pyth spot for the on-chain cadence-created
    // expiry so pricing (mint admission, flush NAV valuation) has a fresh surface.
    await executeAndWait(
        await seedOracleTx({
            pythFeedId,
            bsFeedId,
            expiry: expiryMs,
            spot: seed.spot,
            forward: seed.forward,
            svi: seed.svi,
        }),
        "seed_oracle_surface",
    );
    console.log(
        `[${ts()}]   Oracle seeded: expiry=${expiryMsString} spot=${seed.spot} forward=${seed.forward} tick=$${scaledUsd(ORACLE_TICK_SIZE)}`,
    );

    const accountWrapperId = deriveAccountWrapperId(address);
    await executeAndWait(createAccountTx(), "create_account");
    console.log(`[${ts()}]   Account: ${accountWrapperId}`);

    // Owner auth is minted per-call from the tx sender, so there are no capital caps:
    // deposit / request_supply / request_withdraw all consume a fresh `Auth` hot potato.
    await executeAndWait(
        depositToAccountTx(accountWrapperId, capital.managerSeed),
        "deposit_to_account",
    );
    console.log(`[${ts()}]   Account funded: ${capital.managerSeed / DUSDC_DECIMALS} DUSDC`);

    // Vault bootstrap (async): the market is already registered active (with 0 cash)
    // by create_expiry_market, so the bootstrap flush values it (NAV 0, no orders).
    //   0. lock_capital permanently locks the genesis minimum liquidity so
    //      total_supply > 0; request_supply aborts ENotBootstrapped until it has.
    //   1. request_supply(vaultSeed) deposits fresh DUSDC into the account and pulls
    //      it into queue escrow against the account.
    //   2. a privileged flush bootstrap-mints PLP ~1:1 (genesis total_supply ==
    //      pool_value == min liquidity) and joins the escrowed DUSDC into idle; the
    //      PLP is delivered to the account via the balance accumulator.
    //   3. rebalance_expiry_cash pushes idle -> expiry up to the cash floor so the
    //      market is mintable.
    await executeAndWait(lockCapitalTx(poolVaultId), "bootstrap_lock_capital");
    console.log(
        `[${ts()}]   Genesis liquidity locked: ${MIN_BOOTSTRAP_LIQUIDITY / DUSDC_DECIMALS} DUSDC`,
    );

    await executeAndWait(
        requestSupplyTx({
            poolVaultId,
            protocolConfigId,
            wrapperId: accountWrapperId,
            amount: capital.vaultSeed,
        }),
        "bootstrap_request_supply",
    );
    console.log(`[${ts()}]   Bootstrap supply queued: ${capital.vaultSeed / DUSDC_DECIMALS} DUSDC`);

    await executeAndWait(
        await refreshOracleAndFlushTx({
            poolVaultId,
            protocolConfigId,
            expiryMarketId,
            pythFeedId,
            bsFeedId,
            lifecycleCapId,
            expiry: expiryMs,
            spot: seed.spot,
            forward: seed.forward,
            svi: seed.svi,
        }),
        "bootstrap_flush",
    );
    console.log(`[${ts()}]   Bootstrap flush: PLP minted 1:1, idle funded`);

    await executeAndWait(
        rebalanceExpiryCashTx({ poolVaultId, protocolConfigId, expiryMarketId, pythFeedId }),
        "bootstrap_rebalance_expiry_cash",
    );
    console.log(`[${ts()}]   Expiry cash rebalanced toward floor`);

    const state: SimState = {
        poolVaultId,
        protocolConfigId,
        expiryMarketId,
        expiryMs: expiryMsString,
        pythFeedId,
        bsFeedId,
        accountWrapperId,
        lifecycleCapId,
    };

    writeJson(STATE_PATH, state);
    console.log(`[${ts()}]   State saved to ${STATE_PATH}`);

    return state;
}

async function executeRow(
    row: ScenarioRow,
    state: SimState,
    aliases: AliasState,
): Promise<ExecutionReceipt> {
    if (row.action === "oracle_mint_ptb") {
        const alignedStrike = alignStrikeToTick(row.strike);
        return execute(
            () =>
                refreshOracleAndMintTx({
                    expiryMarketId: state.expiryMarketId,
                    protocolConfigId: state.protocolConfigId,
                    wrapperId: state.accountWrapperId,
                    pythFeedId: state.pythFeedId,
                    bsFeedId: state.bsFeedId,
                    expiry: BigInt(state.expiryMs),
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
            () =>
                refreshOracleAndRedeemTx({
                    expiryMarketId: state.expiryMarketId,
                    protocolConfigId: state.protocolConfigId,
                    wrapperId: state.accountWrapperId,
                    pythFeedId: state.pythFeedId,
                    bsFeedId: state.bsFeedId,
                    expiry: BigInt(state.expiryMs),
                    orderId,
                    closeQuantity: row.closeQuantity,
                    spot: row.oracleRefresh.spot,
                    forward: row.oracleRefresh.forward,
                    svi: row.oracleRefresh,
                }),
            "redeem",
        );
    }

    // supply/withdraw are ASYNC: a row only ENQUEUES a request; the economic effect
    // (PLP mint/burn, account credit) lands at a later privileged flush
    // (start_pool_valuation -> value_expiry -> finish_flush), synthesized by the
    // runner at the batched checkpoints (see executeScenario). request_supply deposits
    // fresh DUSDC into the account and pulls it into escrow; request_withdraw pulls PLP
    // from account custody, auto-settling any flush-delivered PLP first (no separate
    // withdraw_settled step).
    if (row.action === "supply") {
        return execute(
            () =>
                requestSupplyTx({
                    poolVaultId: state.poolVaultId,
                    protocolConfigId: state.protocolConfigId,
                    wrapperId: state.accountWrapperId,
                    amount: row.amount,
                }),
            "supply",
        );
    }

    // Withdraw fully unwinds its referenced supply. Affordability against the
    // account's materialized PLP is pre-checked in executeScenario (skip-and-log when
    // the batched cadence hasn't minted enough yet), so by here the shares are known
    // available; decrement the running balance and enqueue the withdraw request, which
    // auto-settles delivered PLP into custody and pulls `shares`.
    const shares = aliases.lpAmountByRef.get(row.lpRef) ?? 0n;
    aliases.availableSettledPlp -= shares;
    return execute(
        () =>
            requestWithdrawTx({
                poolVaultId: state.poolVaultId,
                protocolConfigId: state.protocolConfigId,
                wrapperId: state.accountWrapperId,
                shares,
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
    runPython = true,
): Promise<void> {
    clearOutputArtifacts();
    if (runPython) {
        runPythonReplay(scenarioPath, maxRows);
    }

    const traceSteps: LocalTraceStep[] = [];
    const records: EconomicRecord[] = [];
    const economicState = initialEconomicState(capital);
    const aliases = initialAliases();
    const targetMints = rows.filter((row) => row.action === "oracle_mint_ptb").length;
    let successfulMints = 0;

    console.log(`\n[${ts()}] Loaded ${rows.length} executable tx rows (${targetMints} mints)`);
    console.log(`[${ts()}] --- Executing economic replay ---\n`);

    // Batched LP flush cadence: requests accumulate and are drained by a privileged
    // flush the runner synthesizes after the configured row counts (default rows 300
    // and 999; override with SIM_FLUSH_AFTER="a,b,..." for fast smoke runs). The
    // bootstrap supply minted PLP 1:1 at setup, so seed the account's withdrawable PLP
    // with it (a conservative lower bound — see AliasState.availableSettledPlp).
    aliases.availableSettledPlp = capital.vaultSeed;
    const flushAfter = flushCheckpoints();
    let skippedWithdraws = 0;

    const runFlush = async (afterRow: number, row: ScenarioRow) => {
        const oracle = firstOracleData(row);
        const startedAt = performance.now();
        // Use `execute` (not `executeAndWait`) so the receipt carries normalized gas;
        // the flush is recorded as a synthetic `flush` trace step at x = afterRow so
        // its gas (refresh + value_expiry + LP drain) shows on the gas chart alongside
        // the trade/pool txs. Refresh is bundled in, matching how mint/redeem gas is
        // measured.
        const receipt = await execute(
            () =>
                refreshOracleAndFlushTx({
                    poolVaultId: state.poolVaultId,
                    protocolConfigId: state.protocolConfigId,
                    expiryMarketId: state.expiryMarketId,
                    pythFeedId: state.pythFeedId,
                    bsFeedId: state.bsFeedId,
                    lifecycleCapId: state.lifecycleCapId,
                    expiry: BigInt(state.expiryMs),
                    spot: oracle.spot,
                    forward: oracle.forward,
                    svi: oracle.svi,
                }),
            `flush_after_row_${afterRow}`,
        );
        const wallMs = performance.now() - startedAt;
        traceSteps.push({
            step: afterRow,
            action: "flush",
            digest: receipt.digest,
            wallMs,
            gas: receipt.gas,
            events: receipt.events.map((event: any) => ({
                type: eventName(event),
                full_type: String(event.type ?? ""),
                parsedJson: event.parsedJson ?? {},
            })),
        });
        process.stdout.write(
            `[${ts()}]   -- flush after row ${afterRow} (drained LP queues, gas ${(receipt.gas.gasTotal / 1e9).toFixed(4)} SUI) --\n`,
        );
    };

    let processed = 0;
    for (const row of rows) {
        processed++;
        // Withdraw affordability under the batched cadence: a supply's PLP is not
        // minted until its flush, so a withdraw can reference PLP that does not exist
        // yet. Skip-and-log instead of aborting, so the run completes and reports how
        // many withdraws the cadence could actually service.
        if (row.action === "withdraw") {
            const shares = aliases.lpAmountByRef.get(row.lpRef) ?? 0n;
            if (shares === 0n || shares > aliases.availableSettledPlp) {
                skippedWithdraws++;
                process.stdout.write(
                    `[${ts()}]   [${row.step}] withdraw SKIPPED (${row.lpRef}: want ${shares} PLP, ${aliases.availableSettledPlp} materialized)\n`,
                );
                if (flushAfter.has(processed)) await runFlush(processed, row);
                continue;
            }
        }
        try {
            const startedAt = performance.now();
            const receipt = await executeRow(row, state, aliases);
            const wallMs = performance.now() - startedAt;
            const record = economicRecord(row, receipt, economicState, aliases);
            recordAliases(row, receipt, aliases);
            traceSteps.push(traceStep(row, receipt, wallMs));
            records.push(record);

            if (row.action === "oracle_mint_ptb") {
                successfulMints++;
                const alignedStrike = alignStrikeToTick(row.strike);
                process.stdout.write(
                    `[${ts()}]   [${row.step}] ${direction(row)} $${scaledUsd(alignedStrike)} qty=${row.quantity} leverage=${formatLeverage(row.leverage)} ref=${row.orderRef}\n`,
                );
            } else {
                process.stdout.write(`[${ts()}]   [${row.step}] ${row.action}\n`);
            }
        } catch (error) {
            if (row.action === "oracle_mint_ptb") {
                throw new Error(
                    `${mintContext(row, alignStrikeToTick(row.strike))} failed: ${errorMessage(error)}`,
                );
            }
            throw new Error(
                `${row.action} csv_line=${row.lineNumber} tx=${row.step} failed: ${errorMessage(error)}`,
            );
        }
        if (flushAfter.has(processed)) await runFlush(processed, row);
    }
    if (skippedWithdraws > 0) {
        console.log(
            `[${ts()}]   ${skippedWithdraws} withdraw row(s) skipped (batched cadence had not materialized enough PLP)`,
        );
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
    console.log(
        `[${ts()}]   ${traceSteps.length} txs, ${successfulMints}/${targetMints} successful mints`,
    );
    console.log(`[${ts()}]   Local trace: ${LOCAL_TRACE_PATH}`);
    console.log(`[${ts()}]   Local data:  ${LOCAL_DATA_PATH}`);
    if (runPython) {
        console.log(`[${ts()}]   Python data: ${PYTHON_DATA_PATH}`);
    }
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
    const scenario = scenarioPath();
    const scenarioConfig = readJson<any>(SCENARIO_CONFIG_PATH);
    const capital = simulationCapital(scenarioConfig, "normal");
    let rows = loadScenario(scenario);
    if (args.maxRows !== undefined) {
        console.log(`[${ts()}] Limiting to ${args.maxRows} tx rows`);
        rows = rows.slice(0, args.maxRows);
    }
    if (rows.length === 0) throw new Error("Scenario has no executable rows");

    const state = await setupSimulation(scenarioConfig, capital, firstOracleData(rows[0]));
    await executeScenario(rows, state, capital, scenario, args.maxRows, !args.skipPython);
}

main().catch((error) => {
    console.error("Simulation failed:", error);
    process.exit(1);
});
