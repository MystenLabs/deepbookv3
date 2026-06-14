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
    createExpiryMarketTx,
    createManagerTx,
    depositToManagerTx,
    deriveManagerId,
    execute,
    executeAndWait,
    finalizeDusdcCurrencyRegistrationTx,
    mintLifecycleCapTx,
    rebalanceExpiryCashTx,
    refreshOracleAndFlushTx,
    refreshOracleAndMintTx,
    refreshOracleAndRedeemTx,
    registerPythFeedAndCreateFeedsTx,
    requestSupplyTx,
    requestWithdrawTx,
    seedOracleTx,
    setTemplateExpiryFeeConfigTx,
    type ExecutionReceipt,
    updatePythTrustedSignerTx,
} from "./runtime.js";

const DUSDC_DECIMALS = 1_000_000n;
const DEFAULT_VAULT_SEED = 500_000n * DUSDC_DECIMALS;
const DEFAULT_MANAGER_SEED = 500_000n * DUSDC_DECIMALS;
const EXPIRY_CASH_FLOOR = 50_000n * DUSDC_DECIMALS;
const EXPIRY_MS = BigInt(Date.now()) + 400n * 24n * 60n * 60n * 1000n;
const FLOAT_SCALING = 1_000_000_000n;
const DEFAULT_EXPIRY_FEE_WINDOW_MS = 24n * 60n * 60n * 1000n;
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
    // flush delivers fills to the manager via the balance accumulator, so no PLP coin
    // is created in the request tx.
    lpRequestIndexByRef: Map<string, bigint>;
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

// The canonical mint input now mirrors the packed range key (two u24 ticks) the
// contract takes at the entrypoint. `lower_tick`/`higher_tick` are the display
// form; `range_key` is the source of truth (lower | higher << TICK_BITS).
function mintInput(row: MintRow): Record<string, string> {
    const strike = alignStrikeToTick(row.strike);
    const { lowerTick, higherTick } = binaryRangeTicks(strike, row.isUp);
    return {
        order_ref: row.orderRef,
        range_key: (lowerTick | (higherTick << TICK_BITS)).toString(),
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

// propbook `pyth_feed::PythFeedUpdated`: the global Pyth spot tick. Timestamps are
// localnet-clock-derived, so they are intentionally excluded from the parity diff.
function normalizePythFeedUpdated(event: any): Record<string, unknown> {
    const json = event.parsedJson ?? {};
    return {
        type: "pyth_feed_updated",
        spot: decimal(json.spot),
    };
}

// propbook `block_scholes_feed::BlockScholesSurfaceUpdated`: this expiry's surface
// (spot + forward + SVI). Replaces the old in-package BlockScholesPricesUpdated +
// BlockScholesSVIUpdated pair. `basis` is no longer an event field; consumers
// derive it as forward/spot. Timestamps are localnet-clock-derived → not diffed.
function normalizeBlockScholesSurfaceUpdated(event: any): Record<string, unknown> {
    const json = event.parsedJson ?? {};
    return {
        type: "block_scholes_surface_updated",
        spot: decimal(json.spot),
        forward: decimal(json.forward),
        a: decimal(json.svi_a),
        b: decimal(json.svi_b),
        rho: signedI64(json.svi_rho),
        m: signedI64(json.svi_m),
        sigma: decimal(json.svi_sigma),
    };
}

function normalizeOrderMinted(event: any, row: ScenarioRow): Record<string, unknown> {
    const json = event.parsedJson ?? {};
    const orderRef = row.action === "oracle_mint_ptb" ? row.orderRef : null;
    return {
        type: "order_minted",
        order_ref: orderRef,
        order_sequence: orderSequence(decimal(json.order_id)),
        range_key: decimal(json.range_key),
        lower_strike: decimal(json.lower_strike),
        higher_strike: decimal(json.higher_strike),
        leverage: decimal(json.leverage),
        entry_probability: decimal(json.entry_probability),
        quantity: decimal(json.quantity),
        contribution: decimal(json.net_premium),
        trading_fee: decimal(json.trading_fee),
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

// === Async LP request/flush events (replace the deleted sync SupplyExecuted /
// WithdrawExecuted). A supply/withdraw is now a two-phase flow: a request row
// escrows funds (SupplyRequested / WithdrawRequested), and a later flush drains the
// queues at one frozen mark, emitting PoolValued + FlushExecuted plus per-request
// SupplyFilled / WithdrawFilled / SupplyRefunded / WithdrawRefunded. The `index`
// queue handle replaces the old returned PLP coin object as the request alias key.

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

function normalizeSupplyRefunded(event: any): Record<string, unknown> {
    const json = event.parsedJson ?? {};
    return {
        type: "supply_refunded",
        index: decimal(json.index),
        dusdc_amount: decimal(json.dusdc_amount),
    };
}

function normalizeWithdrawRefunded(event: any): Record<string, unknown> {
    const json = event.parsedJson ?? {};
    return {
        type: "withdraw_refunded",
        index: decimal(json.index),
        plp_amount: decimal(json.plp_amount),
    };
}

function normalizePoolValued(event: any): Record<string, unknown> {
    const json = event.parsedJson ?? {};
    return {
        type: "pool_valued",
        pool_nav: decimal(json.pool_nav),
        idle_balance: decimal(json.idle_balance),
        active_market_nav: decimal(json.active_market_nav),
        market_count: decimal(json.market_count),
    };
}

function normalizeFlushExecuted(event: any): Record<string, unknown> {
    const json = event.parsedJson ?? {};
    return {
        type: "flush_executed",
        pool_value: decimal(json.pool_value),
        total_supply: decimal(json.total_supply),
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
        const name = eventName(event);
        if (name === "PythFeedUpdated") updates.push(normalizePythFeedUpdated(event));
        else if (name === "BlockScholesSurfaceUpdated")
            updates.push(normalizeBlockScholesSurfaceUpdated(event));
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
        else if (name === "SupplyRefunded") updates.push(normalizeSupplyRefunded(event));
        else if (name === "WithdrawRefunded") updates.push(normalizeWithdrawRefunded(event));
        else if (name === "PoolValued") updates.push(normalizePoolValued(event));
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
        const builderFee = BigInt(decimal(update.builder_fee));
        const penaltyFee = BigInt(decimal(update.penalty_fee));
        const quantity = BigInt(decimal(update.quantity));
        state.managerBalance -= contribution + tradingFee + builderFee + penaltyFee;
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
    // vault/manager balances (the request queue holds them); they move balances only
    // at the flush. They carry no state delta here.
    // TODO(sim-parity): the async request -> flush split changes WHEN PLP supply and
    // manager balances move relative to the old synchronous supply/withdraw. The
    // manager-side credit of a supply fill / withdraw payout now lands via the
    // balance accumulator (send_funds) and is absorbed lazily on the manager's next
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

    // Admin-approve the Pyth feed AND create the two propbook feeds (Pyth spot +
    // Block Scholes surface). Both feed objects are shared; capture their IDs.
    result = await executeAndWait(
        registerPythFeedAndCreateFeedsTx(1, ORACLE_TICK_SIZE),
        "register_pyth_feed_and_create_feeds",
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

    await executeAndWait(
        setTemplateExpiryFeeConfigTx(protocolConfigId, expiryFeeWindowMs, expiryFeeMaxMultiplier),
        "set_template_expiry_fee_config",
    );
    console.log(
        `[${ts()}]   Expiry fee ramp: window_ms=${expiryFeeWindowMs} max_multiplier=${expiryFeeMaxMultiplier}`,
    );

    await executeAndWait(updatePythTrustedSignerTx(), "update_pyth_trusted_signer");
    console.log(`[${ts()}]   Pyth trusted signer configured`);

    // Seed the Block Scholes surface + Pyth spot for the market's expiry so pricing
    // (mint admission, flush NAV valuation) has a fresh surface to read. Market
    // creation reads NO spot now (absolute ticks), but the surface must exist before
    // the first priced op.
    await executeAndWait(
        await seedOracleTx({
            pythFeedId,
            bsFeedId,
            expiry: EXPIRY_MS,
            spot: seed.spot,
            forward: seed.forward,
            svi: seed.svi,
        }),
        "seed_oracle_surface",
    );
    console.log(
        `[${ts()}]   Oracle seeded: spot=${seed.spot} forward=${seed.forward} tick=$${scaledUsd(ORACLE_TICK_SIZE)}`,
    );

    result = await executeAndWait(
        createExpiryMarketTx({
            poolVaultId,
            protocolConfigId,
            pythFeedId,
            bsFeedId,
            lifecycleCapId,
            expiry: EXPIRY_MS,
        }),
        "create_expiry_market",
    );
    const expiryMarketChange = result.objectChanges.find(
        (change: any) => change.type === "created" && change.objectType.includes("ExpiryMarket"),
    );
    const expiryMarketId: string = expiryMarketChange.objectId;
    console.log(`[${ts()}]   ExpiryMarket: ${expiryMarketId}`);

    const managerId = deriveManagerId(address);
    await executeAndWait(createManagerTx(), "create_manager");
    console.log(`[${ts()}]   Manager: ${managerId}`);

    await executeAndWait(depositToManagerTx(managerId, capital.managerSeed), "deposit_to_manager");
    console.log(`[${ts()}]   Manager funded: ${capital.managerSeed / DUSDC_DECIMALS} DUSDC`);

    // TODO(sim-parity): vault bootstrap funding + expiry-cash-floor funding are now
    // async. The old path supplied the vault synchronously (returned PLP 1:1) then
    // ran a setup PLP sync to push the cash floor into the expiry. The new model is:
    //   1. request_supply(vaultSeed) routed through the manager, then a privileged
    //      flush (start_pool_valuation/value_expiry/finish_flush) that bootstrap-mints
    //      PLP 1:1 (total_supply==0 requires pool_value==0 — true before any market is
    //      funded), delivering the PLP to the manager via the accumulator.
    //   2. rebalance_expiry_cash(market) to push idle -> expiry up to the cash floor.
    // Both the ordering relative to market creation and the bootstrap-mark invariants
    // need a localnet run to confirm. Left unfunded here so the dependency on a
    // localnet-confirmed async bootstrap is explicit rather than guessed. The
    // single-active-market flush builder is `refreshOracleAndFlushTx`; the cash-floor
    // primitive is `rebalanceExpiryCashTx`.
    void rebalanceExpiryCashTx;
    void requestSupplyTx;
    void refreshOracleAndFlushTx;
    console.log(`[${ts()}]   (vault bootstrap funding deferred — see TODO(sim-parity))`);

    const state: SimState = {
        poolVaultId,
        protocolConfigId,
        expiryMarketId,
        pythFeedId,
        bsFeedId,
        managerId,
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
                    managerId: state.managerId,
                    pythFeedId: state.pythFeedId,
                    bsFeedId: state.bsFeedId,
                    expiry: EXPIRY_MS,
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
                    managerId: state.managerId,
                    pythFeedId: state.pythFeedId,
                    bsFeedId: state.bsFeedId,
                    expiry: EXPIRY_MS,
                    orderId,
                    closeQuantity: row.closeQuantity,
                    spot: row.oracleRefresh.spot,
                    forward: row.oracleRefresh.forward,
                    svi: row.oracleRefresh,
                }),
            "redeem",
        );
    }

    // TODO(sim-parity): supply/withdraw are now ASYNC. A row can only ENQUEUE a
    // request here (request_supply / request_withdraw); the economic effect (PLP
    // mint/burn, manager credit) happens at a later privileged flush
    // (start_pool_valuation -> value_expiry -> finish_flush), which is a separate
    // PTB and which the contract restricts to the operator AdminCap / lifecycle
    // cap. The single-PTB-per-row model and the inline oracle-refresh+sync that the
    // old SupplyExecuted/WithdrawExecuted events produced no longer exist. Two
    // unresolved questions block a faithful localnet mapping, each needing a real
    // run to confirm:
    //   1. Cadence: does each supply/withdraw row trigger its own flush (request +
    //      flush in adjacent txs), or do requests batch until a periodic flush? The
    //      generator emits no flush row, so the runner must synthesize flush txs.
    //   2. Withdraw escrow source: request_withdraw takes a Coin<PLP>, but the
    //      manager holds PLP fills as balance-accumulator credit (send_funds),
    //      absorbed lazily — there is no PLP coin object to escrow without first
    //      extracting it from the manager's BalanceManager.
    // Until a localnet run resolves both, this enqueues the request (verifiable
    // structurally) but does NOT drive the row's full economics. The Python mirror
    // (python_replay supply_update/withdraw_update) still models the OLD synchronous
    // semantics and must be reworked to the request->flush split in the same pass.
    if (row.action === "supply") {
        return execute(
            () =>
                requestSupplyTx({
                    poolVaultId: state.poolVaultId,
                    managerId: state.managerId,
                    amount: row.amount,
                }),
            "supply",
        );
    }

    // Withdraw needs a Coin<PLP> to escrow; see the TODO(sim-parity) above. The
    // alias index recorded at supply time is the cancel handle, not a PLP coin, so
    // this throws until the async PLP-extraction flow is confirmed on localnet.
    void requestWithdrawTx;
    throw new Error(
        `withdraw row ${row.step} (${row.lpRef}) needs the localnet-confirmed async ` +
            "PLP-escrow flow (see TODO(sim-parity) in executeRow); not runnable yet",
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

    for (const row of rows) {
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
