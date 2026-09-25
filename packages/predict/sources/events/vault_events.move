// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Pool-vault events for expiry cash and profit, fee incentives, and the
/// queued LP request lifecycle. A flush records the frozen pool mark used by fills.
module deepbook_predict::vault_events;

use sui::event;

/// Emitted when expiry-local cash returns to pool idle during the terminal sweep.
public struct ExpiryCashReceived has copy, drop, store {
    pool_vault_id: ID,
    expiry_market_id: ID,
    settlement_price: u64,
    amount: u64,
}

/// Emitted when an active expiry's cash is rebalanced toward target: a top-up from
/// idle (`to_expiry = true`) or a surplus-sweep back to idle (`to_expiry = false`).
/// On a sweep, any carried protocol cut a prior settled sweep could not cover can
/// also be realized from the returned idle into the reserve; that sub-effect is
/// reported as the `protocol_profit_realized` delta.
public struct ExpiryCashRebalanced has copy, drop, store {
    pool_vault_id: ID,
    expiry_market_id: ID,
    amount: u64,
    to_expiry: bool,
    target_cash: u64,
    protocol_profit_realized: u64,
}

/// Emitted when a terminal expiry's profit is materialized: the LP cut stays in idle
/// and the protocol cut is realized into the protocol reserve up to available idle, any
/// remainder carried in `pending_protocol_profit_after` for a later sweep to realize.
public struct ExpiryProfitMaterialized has copy, drop, store {
    pool_vault_id: ID,
    expiry_market_id: ID,
    lp_profit: u64,
    protocol_profit: u64,
    protocol_reserve_balance_after: u64,
    profit_basis_after: u64,
    pending_protocol_profit_after: u64,
}

/// Emitted by the settled-expiry sweep: always on an expiry's first settled sweep, even
/// one that returns no cash, and again on any later sweep that returns more. Reports the
/// pool's lifetime net cash result on the expiry, `received_from_expiry - sent_to_expiry`,
/// as a sign flag and magnitude; each emission carries lifetime totals, so the latest per
/// `expiry_market_id` supersedes earlier ones. The figure is gross: before the protocol/LP
/// split, before netting against other expiries' carried losses (which
/// `ExpiryProfitMaterialized` reports), and including the sponsor fee subsidies mints
/// moved into expiry cash. Subtract the expiry's `OrderMinted.fee_incentive_subsidy` total
/// to isolate the trading result. Cash still held for unredeemed winning payouts counts
/// as paid out.
public struct ExpiryPnl has copy, drop, store {
    pool_vault_id: ID,
    expiry_market_id: ID,
    propbook_underlying_id: u32,
    /// Start of the market's cadence period (`expiry` minus the cadence period), in
    /// milliseconds. The market's creation transaction may land before it.
    period_start_ms: u64,
    expiry: u64,
    settlement_price: u64,
    sent_to_expiry: u64,
    received_from_expiry: u64,
    /// True when `received_from_expiry >= sent_to_expiry`; break-even reports a zero profit.
    in_profit: bool,
    /// Absolute difference between `received_from_expiry` and `sent_to_expiry`.
    amount: u64,
}

/// Emitted when an LP queues a supply request: `amount` USDC is escrowed and a fill
/// will be delivered to `recipient` (the account's receive address) at a later flush.
/// `min_plp_out` is a price floor: the frozen mark must mint at least this much for the
/// whole `amount` before the request fills, but a fill capped by pool capacity delivers
/// proportionally less at that same price. `index` is the queue handle used to cancel.
public struct SupplyRequested has copy, drop, store {
    pool_vault_id: ID,
    account_id: ID,
    recipient: address,
    index: u64,
    amount: u64,
    min_plp_out: u64,
    requests_pending_after: u64,
}

/// Emitted when an LP queues a withdraw request: `amount` PLP shares are escrowed and
/// USDC will be delivered to `recipient` at a later flush. `min_usdc_out` is a price
/// floor: the frozen mark must pay at least this much for the whole `amount` before the
/// request fills, but a fill limited by available idle pays proportionally less at that
/// same price.
public struct WithdrawRequested has copy, drop, store {
    pool_vault_id: ID,
    account_id: ID,
    recipient: address,
    index: u64,
    amount: u64,
    min_usdc_out: u64,
    requests_pending_after: u64,
}

/// Emitted when a still-pending request is cancelled and the escrow (`amount` of
/// USDC if `is_supply`, else PLP) is refunded straight into the requesting account.
/// Cancellation can be user-requested before flush or protocol-triggered when the
/// frozen mark makes the request non-executable or quotes below the request's own
/// minimum output.
public struct RequestCancelled has copy, drop, store {
    pool_vault_id: ID,
    account_id: ID,
    recipient: address,
    index: u64,
    amount: u64,
    is_supply: bool,
    /// 0=user, 1=non-executable frozen mark, 2=quote below the request's minimum output.
    reason: u8,
    requests_pending_after: u64,
}

/// Emitted when a queued LP request reaches the head during a flush, the frozen mark
/// output misses its request-time limit, and it has attempts left so it stays queued.
/// Only reachable when `ProtocolConfig` allows more than one attempt; at the default
/// of one, a miss refunds immediately and reports as `RequestCancelled`.
public struct RequestLimitMissed has copy, drop, store {
    pool_vault_id: ID,
    account_id: ID,
    recipient: address,
    index: u64,
    amount: u64,
    is_supply: bool,
    quoted_output: u64,
    min_output: u64,
    missed_flushes: u64,
    max_misses: u64,
}

/// Emitted when a supply request fills: `usdc_amount` joined pool idle and
/// `shares_minted` PLP were delivered to `recipient`. `account_id` is the
/// owning account (carried from the queued request so the fill is self-contained;
/// `recipient` is its receive address).
public struct SupplyFilled has copy, drop, store {
    pool_vault_id: ID,
    account_id: ID,
    recipient: address,
    index: u64,
    /// USDC actually taken into the pool, which is less than the request's escrow
    /// when the supply cap left only part of it room. Shares were priced on
    /// `usdc_amount - fee_usdc`.
    usdc_amount: u64,
    shares_minted: u64,
    /// Supply fee withheld from `usdc_amount` and retained by the pool.
    fee_usdc: u64,
    /// Escrow still queued at the head after a partial fill; `0` on a full fill, in
    /// which case the request is gone. `usdc_amount + usdc_remaining` is the amount
    /// the request carried into this flush.
    usdc_remaining: u64,
    requests_pending_after: u64,
}

/// Emitted when a withdraw request fills: `shares_burned` PLP were burned and
/// `usdc_amount` was delivered to `recipient` from pool idle. `account_id`
/// is the owning account (carried from the queued request).
public struct WithdrawFilled has copy, drop, store {
    pool_vault_id: ID,
    account_id: ID,
    recipient: address,
    index: u64,
    shares_burned: u64,
    /// Net USDC delivered to `recipient`. The gross marked value of
    /// `shares_burned` was `usdc_amount + fee_usdc`.
    usdc_amount: u64,
    /// Withdraw fee withheld from the payout and retained by the pool.
    fee_usdc: u64,
    /// Escrowed PLP still queued at the head after a partial fill; `0` on a full fill,
    /// in which case the request is gone. `shares_burned + shares_remaining` is the
    /// amount the request carried into this flush.
    shares_remaining: u64,
    requests_pending_after: u64,
}

/// Emitted once after a flush drains both queues. `pool_value / total_supply` is
/// the frozen mark used by every fill; its gross reconstructs as
/// `frozen_idle_balance + active_market_nav`. `idle_balance_before` is a LIVE
/// pre-drain read for drain telemetry and is deliberately not a mark input.
public struct FlushExecuted has copy, drop, store {
    pool_vault_id: ID,
    epoch: u64,
    /// LP-attributable pool NAV every fill was priced at: idle plus
    /// `active_market_nav`, excluding unrealized and pending protocol profit.
    pool_value: u64,
    /// PLP supply in the frozen pre-drain mark used to price every fill.
    total_supply: u64,
    /// Supply-leg fee rate in FLOAT_SCALING, frozen with the mark and charged on
    /// every supply fill in this flush.
    supply_fee_rate: u64,
    /// Withdraw-leg fee rate in FLOAT_SCALING, frozen alongside it.
    withdraw_fee_rate: u64,
    /// Sum of the marked NAV contributed by each active market; settled markets add zero.
    active_market_nav: u64,
    /// Number of active markets valued for this flush.
    market_count: u64,
    /// LIVE idle USDC read at finish time, immediately before the drain — NOT
    /// a mark input. It brackets the drain with `idle_balance_after`; because
    /// maintenance, settlement sweeps, and trading run mid-window, it can differ
    /// from `frozen_idle_balance` below. Drain telemetry, not the mark.
    idle_balance_before: u64,
    /// The mark's idle component: idle USDC FROZEN at the seal. `frozen_idle_balance
    /// + active_market_nav` reconstructs the priced mark's gross; every fill in the
    /// flush is priced from this, never from `idle_balance_before`.
    frozen_idle_balance: u64,
    supplies_filled: u64,
    withdrawals_filled: u64,
    requests_processed: u64,
    idle_balance_after: u64,
    /// PLP supply after the drain's completed mints and burns.
    total_supply_after: u64,
    /// Each queue's `next_index` at this flush's snapshot instant; the drain
    /// filled only requests indexed strictly below these.
    supply_request_cutoff: u64,
    withdraw_request_cutoff: u64,
    /// Clock instant the snapshot stage froze every market's pricer — the moment
    /// the mark prices the pool at. Fills execute later in the same flush; this
    /// is the timestamp they were priced as of.
    snapshot_timestamp_ms: u64,
}

/// An in-flight full-pool valuation was discarded without draining any queue —
/// discard-and-restart of an in-flight flush on pool-valuation authority (there is no
/// permissionless discard). The counts distinguish an abandoned flush from one
/// that never progressed.
public struct FlushRestarted has copy, drop, store {
    pool_vault_id: ID,
    expected_market_count: u64,
    valued_market_count: u64,
}

/// Emitted once when the pool is bootstrapped via `plp::lock_capital`: `amount`
/// USDC is permanently locked as minimum liquidity and matching PLP is minted into
/// the book's locked balance (never withdrawable), so `total_supply` stays > 0.
public struct CapitalLocked has copy, drop, store {
    pool_vault_id: ID,
    amount: u64,
}

/// Emitted when a contributor adds USDC to pool idle liquidity without minting PLP
/// (`plp::add_usdc_to_plp`). The contribution raises every holder's share
/// of pool NAV; it carries no `idle_balance_after` because idle has no canonical
/// post-state event stream — `ExpiryCashRebalanced` also moves idle without reporting
/// it, so a balance-after here would be a second, drifting source for that fact.
public struct UsdcAddedToPlp has copy, drop, store {
    pool_vault_id: ID,
    contributor: address,
    amount: u64,
}

/// Emitted when a sponsor contributes USDC to the pool-level fee incentive reserve.
public struct FeeIncentivesSponsored has copy, drop, store {
    pool_vault_id: ID,
    sponsor: address,
    amount: u64,
    reserve_after: u64,
}

/// Emitted when admin withdraws USDC from the pool-level fee incentive reserve
/// (`plp::withdraw_fee_incentives`).
public struct FeeIncentivesWithdrawn has copy, drop, store {
    pool_vault_id: ID,
    amount: u64,
    reserve_after: u64,
}

/// Emitted when pool-level sponsor funds are allocated into an expiry's local
/// fee-incentive balance.
public struct FeeIncentivesAllocated has copy, drop, store {
    pool_vault_id: ID,
    expiry_market_id: ID,
    amount: u64,
    pool_reserve_after: u64,
    expiry_incentive_balance_after: u64,
    expiry_incentives_allocated_after: u64,
}

/// Emitted when a settled expiry returns unused local fee incentives to the
/// pool-level reserve.
public struct FeeIncentivesReturned has copy, drop, store {
    pool_vault_id: ID,
    expiry_market_id: ID,
    amount: u64,
    pool_reserve_after: u64,
}

// === Public-Package Functions ===

public(package) fun emit_expiry_cash_received(
    pool_vault_id: ID,
    expiry_market_id: ID,
    settlement_price: u64,
    amount: u64,
) {
    event::emit(ExpiryCashReceived {
        pool_vault_id,
        expiry_market_id,
        settlement_price,
        amount,
    });
}

public(package) fun emit_expiry_cash_rebalanced(
    pool_vault_id: ID,
    expiry_market_id: ID,
    amount: u64,
    to_expiry: bool,
    target_cash: u64,
    protocol_profit_realized: u64,
) {
    event::emit(ExpiryCashRebalanced {
        pool_vault_id,
        expiry_market_id,
        amount,
        to_expiry,
        target_cash,
        protocol_profit_realized,
    });
}

public(package) fun emit_expiry_profit_materialized(
    pool_vault_id: ID,
    expiry_market_id: ID,
    lp_profit: u64,
    protocol_profit: u64,
    protocol_reserve_balance_after: u64,
    profit_basis_after: u64,
    pending_protocol_profit_after: u64,
) {
    event::emit(ExpiryProfitMaterialized {
        pool_vault_id,
        expiry_market_id,
        lp_profit,
        protocol_profit,
        protocol_reserve_balance_after,
        profit_basis_after,
        pending_protocol_profit_after,
    });
}

public(package) fun emit_expiry_pnl(
    pool_vault_id: ID,
    expiry_market_id: ID,
    propbook_underlying_id: u32,
    period_start_ms: u64,
    expiry: u64,
    settlement_price: u64,
    sent_to_expiry: u64,
    received_from_expiry: u64,
) {
    let in_profit = received_from_expiry >= sent_to_expiry;
    let amount = received_from_expiry.diff(sent_to_expiry);
    event::emit(ExpiryPnl {
        pool_vault_id,
        expiry_market_id,
        propbook_underlying_id,
        period_start_ms,
        expiry,
        settlement_price,
        sent_to_expiry,
        received_from_expiry,
        in_profit,
        amount,
    });
}

public(package) fun emit_supply_requested(
    pool_vault_id: ID,
    account_id: ID,
    recipient: address,
    index: u64,
    amount: u64,
    min_plp_out: u64,
    requests_pending_after: u64,
) {
    event::emit(SupplyRequested {
        pool_vault_id,
        account_id,
        recipient,
        index,
        amount,
        min_plp_out,
        requests_pending_after,
    });
}

public(package) fun emit_withdraw_requested(
    pool_vault_id: ID,
    account_id: ID,
    recipient: address,
    index: u64,
    amount: u64,
    min_usdc_out: u64,
    requests_pending_after: u64,
) {
    event::emit(WithdrawRequested {
        pool_vault_id,
        account_id,
        recipient,
        index,
        amount,
        min_usdc_out,
        requests_pending_after,
    });
}

public(package) fun emit_request_cancelled(
    pool_vault_id: ID,
    account_id: ID,
    recipient: address,
    index: u64,
    amount: u64,
    is_supply: bool,
    reason: u8,
    requests_pending_after: u64,
) {
    event::emit(RequestCancelled {
        pool_vault_id,
        account_id,
        recipient,
        index,
        amount,
        is_supply,
        reason,
        requests_pending_after,
    });
}

public(package) fun emit_request_limit_missed(
    pool_vault_id: ID,
    account_id: ID,
    recipient: address,
    index: u64,
    amount: u64,
    is_supply: bool,
    quoted_output: u64,
    min_output: u64,
    missed_flushes: u64,
    max_misses: u64,
) {
    event::emit(RequestLimitMissed {
        pool_vault_id,
        account_id,
        recipient,
        index,
        amount,
        is_supply,
        quoted_output,
        min_output,
        missed_flushes,
        max_misses,
    });
}

public(package) fun emit_supply_filled(
    pool_vault_id: ID,
    account_id: ID,
    recipient: address,
    index: u64,
    usdc_amount: u64,
    shares_minted: u64,
    fee_usdc: u64,
    usdc_remaining: u64,
    requests_pending_after: u64,
) {
    event::emit(SupplyFilled {
        pool_vault_id,
        account_id,
        recipient,
        index,
        usdc_amount,
        shares_minted,
        fee_usdc,
        usdc_remaining,
        requests_pending_after,
    });
}

public(package) fun emit_withdraw_filled(
    pool_vault_id: ID,
    account_id: ID,
    recipient: address,
    index: u64,
    shares_burned: u64,
    usdc_amount: u64,
    fee_usdc: u64,
    shares_remaining: u64,
    requests_pending_after: u64,
) {
    event::emit(WithdrawFilled {
        pool_vault_id,
        account_id,
        recipient,
        index,
        shares_burned,
        usdc_amount,
        fee_usdc,
        shares_remaining,
        requests_pending_after,
    });
}

public(package) fun emit_flush_executed(
    pool_vault_id: ID,
    epoch: u64,
    pool_value: u64,
    total_supply: u64,
    supply_fee_rate: u64,
    withdraw_fee_rate: u64,
    active_market_nav: u64,
    market_count: u64,
    idle_balance_before: u64,
    frozen_idle_balance: u64,
    supplies_filled: u64,
    withdrawals_filled: u64,
    requests_processed: u64,
    idle_balance_after: u64,
    total_supply_after: u64,
    supply_request_cutoff: u64,
    withdraw_request_cutoff: u64,
    snapshot_timestamp_ms: u64,
) {
    event::emit(FlushExecuted {
        pool_vault_id,
        epoch,
        pool_value,
        total_supply,
        supply_fee_rate,
        withdraw_fee_rate,
        active_market_nav,
        market_count,
        idle_balance_before,
        frozen_idle_balance,
        supplies_filled,
        withdrawals_filled,
        requests_processed,
        idle_balance_after,
        total_supply_after,
        supply_request_cutoff,
        withdraw_request_cutoff,
        snapshot_timestamp_ms,
    });
}

public(package) fun emit_flush_restarted(
    pool_vault_id: ID,
    expected_market_count: u64,
    valued_market_count: u64,
) {
    event::emit(FlushRestarted {
        pool_vault_id,
        expected_market_count,
        valued_market_count,
    });
}

public(package) fun emit_capital_locked(pool_vault_id: ID, amount: u64) {
    event::emit(CapitalLocked { pool_vault_id, amount });
}

public(package) fun emit_usdc_added_to_plp(pool_vault_id: ID, contributor: address, amount: u64) {
    event::emit(UsdcAddedToPlp { pool_vault_id, contributor, amount });
}

public(package) fun emit_fee_incentives_sponsored(
    pool_vault_id: ID,
    sponsor: address,
    amount: u64,
    reserve_after: u64,
) {
    event::emit(FeeIncentivesSponsored {
        pool_vault_id,
        sponsor,
        amount,
        reserve_after,
    });
}

public(package) fun emit_fee_incentives_withdrawn(
    pool_vault_id: ID,
    amount: u64,
    reserve_after: u64,
) {
    event::emit(FeeIncentivesWithdrawn { pool_vault_id, amount, reserve_after });
}

public(package) fun emit_fee_incentives_allocated(
    pool_vault_id: ID,
    expiry_market_id: ID,
    amount: u64,
    pool_reserve_after: u64,
    expiry_incentive_balance_after: u64,
    expiry_incentives_allocated_after: u64,
) {
    event::emit(FeeIncentivesAllocated {
        pool_vault_id,
        expiry_market_id,
        amount,
        pool_reserve_after,
        expiry_incentive_balance_after,
        expiry_incentives_allocated_after,
    });
}

public(package) fun emit_fee_incentives_returned(
    pool_vault_id: ID,
    expiry_market_id: ID,
    amount: u64,
    pool_reserve_after: u64,
) {
    event::emit(FeeIncentivesReturned {
        pool_vault_id,
        expiry_market_id,
        amount,
        pool_reserve_after,
    });
}

// === Test-Only Functions ===

/// The frozen rate pair a flush actually charged. Exists because the withdraw leg's
/// config wiring cannot be reached behaviourally from a Move test — a unit-test
/// accumulator root carries no settlement funds, so a fill's PLP never reaches
/// account custody to be withdrawn (`lp_flow_tests` module doc) — and because with
/// two independent rates a swapped pair is otherwise invisible: each leg would still
/// charge a plausible rate.
#[test_only]
public fun flush_executed_fee_rates(event: &FlushExecuted): (u64, u64) {
    (event.supply_fee_rate, event.withdraw_fee_rate)
}

/// `(contributor, amount)` — exists so a test can assert the credited contributor is
/// the transaction sender. No balance assertion can see that field, and crediting the
/// wrong address would misattribute the whole incentive stream off-chain.
#[test_only]
public fun usdc_added_to_plp_fields(event: &UsdcAddedToPlp): (address, u64) {
    (event.contributor, event.amount)
}

/// `(live pre-drain idle, frozen mark idle)` — exists so a test can assert the
/// two diverge after a mid-window cash movement while the mark stays exact.
#[test_only]
public fun flush_executed_idle_figures(event: &FlushExecuted): (u64, u64) {
    (event.idle_balance_before, event.frozen_idle_balance)
}

/// The fill events' fields exist for off-chain consumers, which decode them rather
/// than calling Move. These readers exist only so tests can assert the fee reported
/// to those consumers is the fee actually charged: `fee_usdc` is where pool revenue
/// is attributed from, and a wrong value there is invisible to every balance
/// assertion, since the shares and cash moved are computed separately.
#[test_only]
public fun supply_filled_fee(event: &SupplyFilled): u64 {
    event.fee_usdc
}

#[test_only]
public fun withdraw_filled_fee(event: &WithdrawFilled): u64 {
    event.fee_usdc
}
