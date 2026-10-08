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
    CLEANUP_BATCH, POOL_VAULT_ID, PROTOCOL_CONFIG_ID, addFlushOperatorTx, address, bareFlushTx,
    bindFeedsToUnderlyingTx, cleanupQueueTx, clockTimestampMs, combineExecutionReceipts,
    commitAndResolveTx, createAccountTx, createExpiryMarketTx, createMarketQueueTx, depositToAccountTx,
    deriveAccountWrapperId, deriveMarketQueueId, enableOrderFlowTx, execute, executeAndWait,
    finalizeUsdcCurrencyRegistrationTx, keeperTrySettleTx, lockCapitalTx, mintLifecycleCapTx,
    mintPoolValuationCapTx, mintRangeTicks, readPredictEconomicState, readSettlementProgress,
    rebalanceExpiryCashTx, refreshOracleAndEnqueueMintTxs, settleStepTx,
    refreshOracleAndEnqueueRedeemOpenTxs, refreshOracleAndFlushTxs,
    registerUnderlyingAndCreateFeedsTx, requestSupplyTx, requestWithdrawTx,
    seedOracleTx, setBlockScholesSignerTx, setCadenceConfigTx,
    setSimulationEconomicPolicyTx, setTemplateExpiryFeeConfigTx,
    type ExecutionReceipt, updatePythTrustedSignerTx,
} from "../../devtools/ts/runtime.js";

const CONFIG_PATH = fileURLToPath(new URL("../data/scenario_config.json", import.meta.url));
const ORDER_SEQUENCE_MASK = (1n << 40n) - 1n;
// `order.move` packs the quantity into the order id as a 32-bit lot count at bit 100.
const ORDER_QUANTITY_LOTS_OFFSET = 100n;
const U32_MASK = (1n << 32n) - 1n;
const POSITION_LOT_SIZE = 10_000n;
// Commit once the order's τ has passed, then resolve a bounded batch: resolve visits at most
// this many records, finished ones included.
const FILL_DELAY_MS = 150;
const RESOLVE_BATCH = 50n;
// `queue::settle_step` runs one bounded phase per call. The scenario's walk needs two (refund
// the waiting order, then pay the Open records), so more calls than this means no progress.
const MAX_SETTLE_STEPS = 10;
// `order_queue::reason_deadline()`.
const REASON_DEADLINE = 5;
// A payout the market could not make, which the queue reports instead of aborting. The scenario
// never creates it, so it fails the run rather than reaching parity as an unmodeled event.
const DRIFT_EVENTS = new Set(["OpenRecordPayoutSkipped"]);
interface ScenarioConfig {
    schema_version: number;
    capital: { manager_seed: string; vault_seed: string };
    market: Record<string, string | number> & { cadence_id: number };
    protocol: Record<string, string>;
}
// Scenario order refs mapped to the queue record that holds each position, and position order
// ids mapped back to their ref. An early sell moves the position into the sell's own record.
interface Aliases {
    recordIds: Map<string, string>;
    recordRefs: Map<string, string>;
    orderRefs: Map<string, string>;
}
interface RunContext {
    aliases: Aliases;
    settlementPrice: bigint | null;
}
interface RowExecution {
    receipt: ExecutionReceipt;
    // The committed tick a queued row priced at (its τ), or null to use the receipt's Clock.
    pricingTimestampMs: number | null;
}

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
const sleep = (ms: number) => new Promise((resolve) => setTimeout(resolve, ms));
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
function orderQuantity(orderId: string): string {
    return (((BigInt(orderId) >> ORDER_QUANTITY_LOTS_OFFSET) & U32_MASK) * POSITION_LOT_SIZE).toString();
}
function aliasFor(map: Map<string, string>, key: string, event: string): string {
    const ref = map.get(key);
    if (!ref) throw new Error(`${event} ${key} has no scenario alias`);
    return ref;
}

function oracleFor(row: ScenarioRow): OracleRefreshData | null {
    if (row.action === "mint") return row;
    if (row.action === "redeem_open") return row.oracleRefresh;
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
        const { lowerTick, higherTick } = mintRangeTicks(row.strike, row.isUp, tickSize, row.higherStrike);
        return { ...oracle, order_ref: row.orderRef, lower_tick: lowerTick.toString(), higher_tick: higherTick.toString(), quantity: row.quantity.toString(), max_probability: row.maxProbability?.toString() ?? null, commit_spot: row.commitSpot?.toString() ?? null };
    }
    if (row.action === "redeem_open") return { ...oracle, order_ref: row.orderRef, close_quantity: row.closeQuantity.toString(), replacement_order_ref: row.replacementOrderRef, commit_spot: row.commitSpot.toString() };
    if (row.action === "request_supply") return { amount: row.amount.toString(), min_output: row.minOutput.toString(), lp_ref: row.lpRef };
    if (row.action === "request_withdraw") return { shares: row.shares.toString(), min_output: row.minOutput.toString(), lp_ref: row.lpRef };
    if (row.action === "settle") return { settlement_price: row.settlementPrice.toString() };
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

// Normalize one row's events, in emission order, into canonical updates. Aliases move with the
// events: an enqueue names its record, a fill names the position it leaves, and a sell moves its
// ref to the sell's record.
function normalizeUpdates(row: ScenarioRow, receipt: ExecutionReceipt, aliases: Aliases): Record<string, unknown>[] {
    const updates: Record<string, unknown>[] = [];
    for (const event of receipt.events) {
        const name = eventName(event);
        const value = eventJson(event);
        if (DRIFT_EVENTS.has(name)) throw new Error(`unexpected queue drift event ${name}: ${JSON.stringify(value)}`);
        if (name === "OrderEnqueued") {
            if (row.action !== "mint" && row.action !== "redeem_open") throw new Error(`OrderEnqueued in a ${row.action} row`);
            const recordId = decimal(value.record_id);
            const source = optionDecimal(value.source_record_id);
            if (source !== null) aliases.recordRefs.delete(source);
            aliases.recordIds.set(row.orderRef, recordId); aliases.recordRefs.set(recordId, row.orderRef);
            updates.push({ type: "order_enqueued", order_ref: row.orderRef, record_id: recordId, kind: decimal(value.kind), quantity: decimal(value.request.quantity), budget: decimal(value.budget), order_fee: decimal(value.order_fee), cash_need: decimal(value.cash_need), source_record_id: source });
        } else if (name === "OrderMinted") {
            const id = decimal(value.order_id);
            if (row.action !== "mint") throw new Error(`OrderMinted ${id} in a ${row.action} row`);
            aliases.orderRefs.set(id, row.orderRef);
            updates.push({ type: "order_minted", order_ref: row.orderRef, order_sequence: orderSequence(id), lower_tick: decimal(value.lower_tick), higher_tick: decimal(value.higher_tick), entry_probability: decimal(value.entry_probability), quantity: decimal(value.quantity), premium: decimal(value.premium), trading_fee: decimal(value.trading_fee), fee_incentive_subsidy: decimal(value.fee_incentive_subsidy), builder_fee: decimal(value.builder_fee), penalty_fee: decimal(value.penalty_fee), referral_fee: decimal(value.referral_fee), inventory_impact_charge: decimal(value.inventory_impact_charge), onchain_timestamp_ms: decimal(value.onchain_timestamp_ms), ...sourceTimestamps(value) });
        } else if (name === "LiveOrderRedeemed") {
            const id = decimal(value.order_id);
            const ref = aliasFor(aliases.orderRefs, id, name);
            aliases.orderRefs.delete(id);
            const replacement = optionDecimal(value.replacement_order_id);
            const replacementRef = replacement !== null && row.action === "redeem_open"
                ? row.replacementOrderRef ?? row.orderRef
                : null;
            if (replacement !== null) {
                if (replacementRef === null) throw new Error(`LiveOrderRedeemed replacement ${replacement} outside a redeem_open row`);
                aliases.orderRefs.set(replacement, replacementRef);
            }
            updates.push({ type: "live_order_redeemed", order_ref: ref, order_sequence: orderSequence(id), quantity_closed: decimal(value.quantity_closed), remaining_quantity: decimal(value.remaining_quantity), replacement_order_ref: replacementRef, replacement_order_sequence: replacement === null ? null : orderSequence(replacement), redeem_amount: decimal(value.redeem_amount), trading_fee: decimal(value.trading_fee), builder_fee: decimal(value.builder_fee), penalty_fee: decimal(value.penalty_fee), inventory_impact_rebate: decimal(value.inventory_impact_rebate), onchain_timestamp_ms: decimal(value.onchain_timestamp_ms), ...sourceTimestamps(value) });
        } else if (name === "QueuedOrderFilled") {
            const recordId = decimal(value.record_id);
            const ref = aliasFor(aliases.recordRefs, recordId, name);
            const positionId = decimal(value.position.order_id);
            // A partial sell's remainder stays in the sell's record under its replacement ref.
            const holder = positionId === "0" ? ref : aliases.orderRefs.get(positionId) ?? ref;
            if (holder !== ref) {
                aliases.recordIds.delete(ref);
                aliases.recordIds.set(holder, recordId); aliases.recordRefs.set(recordId, holder);
            }
            updates.push({ type: "queued_order_filled", order_ref: ref, record_id: recordId, kind: decimal(value.kind), quantity: decimal(value.quantity), amount: decimal(value.amount), trading_fee: decimal(value.trading_fee), builder_fee: decimal(value.builder_fee), referral_fee: decimal(value.referral_fee), order_fee: decimal(value.order_fee), subsidy_used: decimal(value.subsidy_used), inventory_impact: decimal(value.inventory_impact), position_quantity: orderQuantity(positionId), tau_ms: decimal(value.tau_ms), tick_ms: decimal(value.tick_ms), onchain_timestamp_ms: decimal(value.onchain_timestamp_ms) });
        } else if (name === "QueuedOrderRefunded") {
            const recordId = decimal(value.record_id);
            updates.push({ type: "queued_order_refunded", order_ref: aliasFor(aliases.recordRefs, recordId, name), record_id: recordId, kind: decimal(value.kind), reason: decimal(value.reason), escrow_returned: decimal(value.escrow_returned), order_fee_returned: decimal(value.order_fee_returned), subsidy_returned: decimal(value.subsidy_returned), position_returned: boolean(value.position_returned), onchain_timestamp_ms: decimal(value.onchain_timestamp_ms) });
        } else if (name === "OpenRecordSettled") {
            const recordId = decimal(value.record_id);
            const id = decimal(value.order_id);
            updates.push({ type: "open_record_settled", order_ref: aliasFor(aliases.recordRefs, recordId, name), record_id: recordId, order_sequence: orderSequence(id), payout: decimal(value.payout), onchain_timestamp_ms: decimal(value.onchain_timestamp_ms) });
        } else if (name === "MarketPayoutsCompleted") {
            updates.push({ type: "market_payouts_completed", onchain_timestamp_ms: decimal(value.onchain_timestamp_ms) });
        } else if (name === "QueuedOrdersCleaned") {
            if (!Array.isArray(value.record_ids)) throw new Error(`QueuedOrdersCleaned record_ids is not an array`);
            updates.push({ type: "queued_orders_cleaned", record_ids: value.record_ids.map(decimal), onchain_timestamp_ms: decimal(value.onchain_timestamp_ms) });
        } else if (name === "SupplyRequested") {
            updates.push({ type: "supply_requested", lp_ref: row.action === "request_supply" ? row.lpRef : "", index: decimal(value.index), amount: decimal(value.amount), min_output: decimal(value.min_plp_out), requests_pending_after: decimal(value.requests_pending_after) });
        } else if (name === "WithdrawRequested") {
            updates.push({ type: "withdraw_requested", lp_ref: row.action === "request_withdraw" ? row.lpRef : "", index: decimal(value.index), amount: decimal(value.amount), min_output: decimal(value.min_usdc_out), requests_pending_after: decimal(value.requests_pending_after) });
        } else if (name === "RequestCancelled") {
            updates.push({ type: "request_cancelled", index: decimal(value.index), amount: decimal(value.amount), is_supply: boolean(value.is_supply), reason: decimal(value.reason), requests_pending_after: decimal(value.requests_pending_after) });
        } else if (name === "SupplyFilled") {
            updates.push({ type: "supply_filled", index: decimal(value.index), usdc_amount: decimal(value.usdc_amount), shares_minted: decimal(value.shares_minted), fee_usdc: decimal(value.fee_usdc), usdc_remaining: decimal(value.usdc_remaining), requests_pending_after: decimal(value.requests_pending_after) });
        } else if (name === "WithdrawFilled") {
            updates.push({ type: "withdraw_filled", index: decimal(value.index), shares_burned: decimal(value.shares_burned), usdc_amount: decimal(value.usdc_amount), fee_usdc: decimal(value.fee_usdc), shares_remaining: decimal(value.shares_remaining), requests_pending_after: decimal(value.requests_pending_after) });
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
        }
    }
    return updates;
}

async function stateSnapshot(state: SimState): Promise<Record<string, string>> {
    const value = await readPredictEconomicState({ poolVaultId: state.poolVaultId, expiryMarketId: state.expiryMarketId, wrapperId: state.accountWrapperId });
    return {
        account_usdc_balance: value.accountUsdcBalance.toString(),
        account_plp_balance: value.accountPlpBalance.toString(),
        expiry_cash_balance: value.expiryCashBalance.toString(),
        inventory_impact_reserve: value.inventoryImpactReserve.toString(),
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
        waiting_cash_need: value.waitingCashNeed.toString(),
        pending_mints: value.pendingMints.toString(),
        pending_sells: value.pendingSells.toString(),
        payout_cursor: value.payoutCursor.toString(),
        queue_next_id: value.queueNextId.toString(),
    };
}
function traceStep(row: ScenarioRow, receipt: ExecutionReceipt, wallMs: number, timestampMs: number): LocalTraceStep {
    return { step: row.step, action: row.action, digest: receipt.digest, pricingTimestampMs: timestampMs, wallMs, gas: receipt.gas, events: receipt.events.map((event: any) => ({ type: eventName(event), full_type: String(event.type ?? ""), parsedJson: event.parsedJson ?? {} })) };
}
function oracleParams(value: OracleRefreshData) {
    return { spot: value.spot, forward: value.forward, svi: { a: value.a, aNegative: value.aNegative, b: value.b, rho: value.rho, rhoNegative: value.rhoNegative, m: value.m, mNegative: value.mNegative, sigma: value.sigma } };
}

// Enqueue an order, then, unless the row leaves it uncommitted, commit `commitSpot` as the
// locally signed Lazer price for its τ on its channel and resolve in one PTB. Both calls are
// permissionless. The fill must land at τ itself and before the order's deadline, or the Python
// replay, which prices at τ, would model a different outcome. Either one fails the run here.
async function placeAndFill(
    state: SimState,
    enqueueTxs: () => Promise<any[]>,
    commitSpot: bigint | null,
    label: string,
): Promise<RowExecution> {
    const enqueue = await execute(enqueueTxs, label);
    const order = eventJson(onlyEvent(enqueue, "OrderEnqueued"));
    const recordId = BigInt(order.record_id);
    const tauMs = BigInt(order.timing.tau_ms);
    const pricingTimestampMs = Number(tauMs);
    if (commitSpot === null) return { receipt: enqueue, pricingTimestampMs };
    const waitMs = pricingTimestampMs + FILL_DELAY_MS - Date.now();
    if (waitMs > 0) await sleep(waitMs);
    const fill = await execute(() => commitAndResolveTx({
        expiryMarketId: state.expiryMarketId,
        protocolConfigId: state.protocolConfigId,
        prices: [{ tauMs, channel: Number(order.timing.pyth_channel), spot1e9: commitSpot }],
        maxOrders: RESOLVE_BATCH,
    }), `${label}_fill`);
    const ofRecord = (event: any) => BigInt(eventJson(event).record_id) === recordId;
    const committed = eventsNamed(fill, "CohortCommitted").find((event) => {
        const value = eventJson(event);
        return BigInt(value.first_record_id) <= recordId && recordId <= BigInt(value.last_record_id);
    });
    if (!committed || BigInt(eventJson(committed).tick_ms) !== tauMs) {
        throw new Error(`${label}: record ${recordId} was not committed at its τ ${tauMs}`);
    }
    const refund = eventsNamed(fill, "QueuedOrderRefunded").find(ofRecord);
    if (refund && Number(eventJson(refund).reason) === REASON_DEADLINE) {
        throw new Error(`${label}: record ${recordId} was resolved past its deadline`);
    }
    if (!refund && !eventsNamed(fill, "QueuedOrderFilled").some(ofRecord)) {
        throw new Error(`${label}: resolve did not finish record ${recordId}`);
    }
    return { receipt: combineExecutionReceipts([enqueue, fill]), pricingTimestampMs };
}

// `settle`: Predict's `try_settle` with the exact expiry observation. It settles from the oracle
// alone, so one call settles the market.
async function settleMarket(state: SimState, price: bigint, label: string): Promise<ExecutionReceipt> {
    const receipt = await execute(() => keeperTrySettleTx({ pythFeedId: state.pythFeedId, bsValueStoreId: state.bsValueStoreId, expiryMs: BigInt(state.expiryMs), price, marketId: state.expiryMarketId, protocolConfigId: state.protocolConfigId }), label);
    if (!(await readSettlementProgress(state.expiryMarketId)).settled) throw new Error(`${label}: try_settle did not settle the market`);
    return receipt;
}

// `settle_payout`: the queue's settlement walk, one `settle_step` per transaction until it
// completes, then `cleanup` of every record below `next_id`.
async function settleQueue(state: SimState, label: string): Promise<ExecutionReceipt> {
    const receipts: ExecutionReceipt[] = [];
    for (let call = 1; ; call += 1) {
        if (call > MAX_SETTLE_STEPS) throw new Error(`${label}: settle_step did not finish within ${MAX_SETTLE_STEPS} calls`);
        receipts.push(await execute(() => settleStepTx({ marketId: state.expiryMarketId, protocolConfigId: state.protocolConfigId }), `${label}_${call}`));
        const progress = await readSettlementProgress(state.expiryMarketId);
        if (!progress.payoutsCompleted) continue;
        if (progress.nextId > BigInt(CLEANUP_BATCH)) throw new Error(`${label}: ${progress.nextId} records exceed one cleanup batch`);
        const recordIds = Array.from({ length: Number(progress.nextId) }, (_, id) => BigInt(id));
        receipts.push(await execute(() => cleanupQueueTx({ marketId: state.expiryMarketId, recordIds }), `${label}_cleanup`));
        return combineExecutionReceipts(receipts);
    }
}

// Every trade row is queued in the order-flow companion: enqueue, then commit at τ and resolve
// (`placeAndFill`). `settle` is Predict's `try_settle`. `settle_payout` is the queue's walk:
// `settle_step` refunds the waiting orders and pays the Open records, then `cleanup` deletes the
// finished records. The next `rebalance_expiry_cash` sweeps the settled market.
async function executeRow(row: ScenarioRow, state: SimState, context: RunContext): Promise<RowExecution> {
    const common = { expiryMarketId: state.expiryMarketId, protocolConfigId: state.protocolConfigId, wrapperId: state.accountWrapperId, pythFeedId: state.pythFeedId, bsValueStoreId: state.bsValueStoreId, bsSviStoreId: state.bsSviStoreId };
    const clocked = (receipt: ExecutionReceipt): RowExecution => ({ receipt, pricingTimestampMs: null });
    if (row.action === "mint") {
        // A queued mint needs a finite all-in cap, and a fill never costs more than its quantity.
        return placeAndFill(state, () => refreshOracleAndEnqueueMintTxs({ ...common, expiry: BigInt(state.expiryMs), ...oracleParams(row), strike: row.strike, isUp: row.isUp, higherStrike: row.higherStrike, quantity: row.quantity, tickSize: BigInt(state.tickSize), maxCost: row.quantity, maxProbability: row.maxProbability }), row.commitSpot, `scenario_${row.step}_mint`);
    }
    if (row.action === "redeem_open") {
        const recordId = context.aliases.recordIds.get(row.orderRef);
        if (!recordId) throw new Error(`unknown order_ref ${row.orderRef}`);
        return placeAndFill(state, () => refreshOracleAndEnqueueRedeemOpenTxs({ ...common, expiry: BigInt(state.expiryMs), ...oracleParams(row.oracleRefresh), recordId: BigInt(recordId), closeQuantity: row.closeQuantity }), row.commitSpot, `scenario_${row.step}_redeem_open`);
    }
    if (row.action === "request_supply") return clocked(await execute(() => requestSupplyTx({ poolVaultId: state.poolVaultId, protocolConfigId: state.protocolConfigId, wrapperId: state.accountWrapperId, amount: row.amount, minPlpOut: row.minOutput }), `scenario_${row.step}_request_supply`));
    if (row.action === "request_withdraw") return clocked(await execute(() => requestWithdrawTx({ poolVaultId: state.poolVaultId, protocolConfigId: state.protocolConfigId, wrapperId: state.accountWrapperId, shares: row.shares, minUsdcOut: row.minOutput }), `scenario_${row.step}_request_withdraw`));
    if (row.action === "flush") {
        if (row.oracleRefresh === null) return clocked(await execute(() => bareFlushTx({ poolVaultId: state.poolVaultId, protocolConfigId: state.protocolConfigId, poolValuationCapId: state.poolValuationCapId }), `scenario_${row.step}_flush_empty`));
        const oracle = row.oracleRefresh;
        return clocked(await execute(() => refreshOracleAndFlushTxs({ ...common, poolVaultId: state.poolVaultId, poolValuationCapId: state.poolValuationCapId, expiry: BigInt(state.expiryMs), ...oracleParams(oracle) }), `scenario_${row.step}_flush`));
    }
    if (row.action === "rebalance_expiry_cash") return clocked(await execute(() => rebalanceExpiryCashTx({ poolVaultId: state.poolVaultId, protocolConfigId: state.protocolConfigId, expiryMarketId: state.expiryMarketId }), `scenario_${row.step}_rebalance_expiry_cash`));
    if (row.action === "settle") {
        while ((await clockTimestampMs()) < BigInt(state.expiryMs)) await sleep(100);
        context.settlementPrice = row.settlementPrice;
        return clocked(await settleMarket(state, row.settlementPrice, `scenario_${row.step}_settle`));
    }
    if (context.settlementPrice === null) throw new Error("settle_payout requires an earlier settle row");
    return clocked(await settleQueue(state, `scenario_${row.step}_settle_payout`));
}

function createdObjectId(result: any, typeName: string): string {
    const change = result.objectChanges.find((candidate: any) => candidate.type === "created" && String(candidate.objectType).includes(typeName));
    if (!change?.objectId) throw new Error(`setup did not create ${typeName}`);
    return change.objectId;
}
// Start the market early in its cadence period. Every queued trade row waits about a second for
// its τ, and the last enqueue must land before the cutoff, `max(no_trade_window_ms,
// stall_timeout_ms + 5 s)` before expiry, so a late start would leave too little of the period.
const MIN_MARKET_LIFETIME_MS = 55_000n;
async function alignCreation(periodMs: bigint): Promise<void> {
    const now = await clockTimestampMs();
    const remaining = periodMs - (now % periodMs);
    if (remaining < MIN_MARKET_LIFETIME_MS) await sleep(Number(remaining + 100n));
}

async function setup(config: ScenarioConfig, seed: OracleRefreshData): Promise<SimState> {
    console.log(`[${ts()}] setup current Predict topology`);
    await executeAndWait(finalizeUsdcCurrencyRegistrationTx(), "finalize_usdc_currency_registration");
    const capResult = await executeAndWait(mintLifecycleCapTx(address), "mint_lifecycle_cap");
    const lifecycleCapId = createdObjectId(capResult, "MarketLifecycleCap");
    const valuationCapResult = await executeAndWait(mintPoolValuationCapTx(address), "mint_pool_valuation_cap");
    const poolValuationCapId = createdObjectId(valuationCapResult, "PoolValuationCap");
    const feedResult = await executeAndWait(registerUnderlyingAndCreateFeedsTx(), "register_underlying_and_create_feeds");
    const pythFeedId = createdObjectId(feedResult, "pyth_feed::PythFeed");
    const bsValueStoreId = createdObjectId(feedResult, "BlockScholesValueStore");
    const bsSviStoreId = createdObjectId(feedResult, "BlockScholesSVIStore");
    await executeAndWait(bindFeedsToUnderlyingTx({ pythFeedId }), "bind_feeds_to_underlying");
    const policy = (key: string) => integer(config.protocol[key], `scenario config.protocol.${key}`);
    await executeAndWait(setSimulationEconomicPolicyTx({
        protocolConfigId: PROTOCOL_CONFIG_ID, baseFee: policy("base_fee"), minFee: policy("min_fee"),
        minEntryProbability: policy("min_entry_probability"), maxEntryProbability: policy("max_entry_probability"),
        backingBufferLambda: policy("backing_buffer_lambda"), inventoryImpactMaxRate: policy("inventory_impact_max_rate"),
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
    // Predict accepts the companion's admissions, commits, and fills only once its witness is
    // allowlisted. The companion's publish already shared the desk with the launch policy.
    await executeAndWait(enableOrderFlowTx(), "enable_order_flow");
    // `finish_flush` admits only allowlisted flush operators; this address sends every flush.
    await executeAndWait(addFlushOperatorTx(address), "add_flush_operator");
    await executeAndWait(lockCapitalTx(POOL_VAULT_ID), "bootstrap_lock_capital");
    await executeAndWait(requestSupplyTx({ poolVaultId: POOL_VAULT_ID, protocolConfigId: PROTOCOL_CONFIG_ID, wrapperId: accountWrapperId, amount: integer(config.capital.vault_seed, "scenario config.capital.vault_seed") }), "bootstrap_request_supply");
    await executeAndWait(bareFlushTx({ poolVaultId: POOL_VAULT_ID, protocolConfigId: PROTOCOL_CONFIG_ID, poolValuationCapId }), "bootstrap_flush");
    await alignCreation(periodMs);
    const marketResult = await executeAndWait(createExpiryMarketTx({ poolVaultId: POOL_VAULT_ID, protocolConfigId: PROTOCOL_CONFIG_ID, lifecycleCapId, cadenceId: config.market.cadence_id }), "create_and_share_expiry_market");
    const expiryMarketId = createdObjectId(marketResult, "ExpiryMarket");
    const queueResult = await executeAndWait(createMarketQueueTx(expiryMarketId), "create_market_queue");
    const marketQueueId = createdObjectId(queueResult, "queue::MarketQueue");
    if (marketQueueId !== deriveMarketQueueId(expiryMarketId)) throw new Error(`market queue ${marketQueueId} is not at its derived ID`);
    const expiryMs = decimal(eventJson(onlyEvent(marketResult, "MarketCreated")).expiry);
    if (marketResult.clockTimestampMs === null) throw new Error("market creation did not record its Clock timestamp");
    const creationTimestampMs = BigInt(marketResult.clockTimestampMs);
    const expectedExpiry = ((creationTimestampMs / periodMs) + 1n) * periodMs;
    if (BigInt(expiryMs) !== expectedExpiry) throw new Error(`expected cadence expiry ${expectedExpiry}, got ${expiryMs}`);
    await executeAndWait(await seedOracleTx({ pythFeedId, bsValueStoreId, bsSviStoreId, expiry: BigInt(expiryMs), ...oracleParams(seed) }), "seed_oracle_surface");
    await executeAndWait(rebalanceExpiryCashTx({ poolVaultId: POOL_VAULT_ID, protocolConfigId: PROTOCOL_CONFIG_ID, expiryMarketId }), "bootstrap_rebalance_expiry_cash");
    const state: SimState = { poolVaultId: POOL_VAULT_ID, protocolConfigId: PROTOCOL_CONFIG_ID, expiryMarketId, marketQueueId, expiryMs, pythFeedId, bsValueStoreId, bsSviStoreId, accountWrapperId, lifecycleCapId, poolValuationCapId, initialExpiryCash: initialExpiryCash.toString(), tickSize: tickSize.toString() };
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
    const context: RunContext = {
        aliases: { recordIds: new Map(), recordRefs: new Map(), orderRefs: new Map() },
        settlementPrice: null,
    };
    const observed: ScenarioActionName[] = [];
    const records: EconomicRecord[] = [];
    const steps: LocalTraceStep[] = [];
    const data = (): EconomicDataFile => ({ schema_version: ECONOMIC_SCHEMA_VERSION, scenario: { quantity_scale: scenarioQuantityScale(), required_actions: REQUIRED_ACTIONS, observed_actions: observed }, records });
    const trace = (): LocalTraceFile => ({ schema_version: LOCAL_TRACE_SCHEMA_VERSION, steps });
    try {
        for (const row of rows) {
            const started = performance.now();
            const { receipt, pricingTimestampMs } = await executeRow(row, state, context);
            const step = traceStep(row, receipt, performance.now() - started, receipt.clockTimestampMs ?? 0);
            steps.push(step);
            if (receipt.clockTimestampMs === null) step.pricingTimestampMs = Number(await clockTimestampMs());
            // A queued fill prices at its committed tick, the order's τ, not at the resolve's Clock.
            if (pricingTimestampMs !== null) step.pricingTimestampMs = pricingTimestampMs;
            if (row.action === "flush") {
                // The staged flush prices at the snapshot leg's clock, not the last
                // (finish) leg's; FlushExecuted carries that instant.
                const flushExecuted = receipt.events.find((event: any) => eventName(event) === "FlushExecuted");
                const snapshotMs = flushExecuted?.parsedJson?.snapshot_timestamp_ms;
                if (snapshotMs !== undefined) step.pricingTimestampMs = Number(snapshotMs);
            }
            const updates = normalizeUpdates(row, receipt, context.aliases);
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
