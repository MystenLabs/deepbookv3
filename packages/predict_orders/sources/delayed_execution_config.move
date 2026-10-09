// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Admin-tunable policy for delayed execution: the timing, capacity, fee, and
/// settlement-batch settings that queued mints and early sells run under.
///
/// A leaf module, so `queue_events` can embed the policy and `desk` can store
/// it. It owns the struct, its launch defaults, the field getters, and the
/// package setters with every bound: each field's own range, the relational
/// timing rules, and the per-account cap against the capacities. Predict caps
/// what admission accepts on its side (`constants::max_svi_max_age_ms` and the
/// deadline margin), and these bounds stay inside it.
module deepbook_predict_orders::delayed_execution_config;

use deepbook_predict::{constants, order};
use deepbook_predict_math::lazer_price;

const EInvalidDelayMs: u64 = 0;
const EInvalidStallTimeoutMs: u64 = 1;
const EInvalidStuckThresholdMs: u64 = 2;
const EInvalidGapWaitMs: u64 = 3;
const EInvalidPythPriceBufferMs: u64 = 4;
const EInvalidSviMaxAgeMs: u64 = 5;
const EInvalidMintCapacity: u64 = 6;
const EInvalidSellCapacity: u64 = 7;
const EInvalidPerAccountCap: u64 = 8;
const EInvalidMinSellQuantity: u64 = 9;
const EInvalidOrderFee: u64 = 10;
const EInvalidSettleRefundBatch: u64 = 11;
const EInvalidSettlePayoutBatch: u64 = 12;
const EUnsupportedPythChannel: u64 = 13;
const EInvalidTiming: u64 = 14;
const EInvalidLimits: u64 = 15;

/// Delayed-execution settings, stored in the shared `OrderDesk`. Times are
/// milliseconds and USDC amounts are base units.
public struct DelayedExecutionPolicy has copy, drop, store {
    /// Latest τ may fall after placement. τ rounds down to the policy channel's
    /// tick at or before `t₀ + delay_ms`.
    delay_ms: u64,
    /// Sets each order's deadline: `max(min(τ + stall_timeout_ms, expiry), last
    /// deadline)`. At or past it the order is refunded, never filled.
    stall_timeout_ms: u64,
    /// Placement refuses new orders while an uncommitted cohort is this far past
    /// its τ with nothing newer committed, or while two or more uncommitted
    /// cohorts are each this far past their τ.
    stuck_threshold_ms: u64,
    /// Commit accepts a backup tick for a cohort only once now is this far past
    /// its τ.
    gap_wait_ms: u64,
    /// Switches the backup tick on or off. `0` accepts only the update stamped
    /// exactly τ. Above `0`, once now is `gap_wait_ms` past τ, a cohort also
    /// accepts its single backup: the update stamped one tick of its own stored
    /// channel after τ. The value is not a window: the setter keeps it at `0` or
    /// one tick of the policy channel.
    pyth_price_buffer_ms: u64,
    /// Pyth Lazer channel new orders are priced on: `2` (`fixed_rate@50ms`) or
    /// `3` (`fixed_rate@200ms`). Its tick period is τ's grid. Each order stores
    /// the channel it was placed under.
    pyth_channel: u8,
    /// Oldest Block Scholes SVI a placement accepts into an order's volatility
    /// snapshot.
    svi_max_age_ms: u64,
    /// Most unfinished queued mints per market.
    mint_capacity: u64,
    /// Most unfinished queued sells per market.
    sell_capacity: u64,
    /// Most unfinished queued orders per account per market.
    per_account_cap: u64,
    /// Flat fee charged at placement. Kept on a fill and on limit or admission
    /// refunds; returned on every other refund.
    order_fee: u64,
    /// Smallest early-sell close quantity.
    min_sell_quantity: u64,
    /// Most records one `settle_step` call visits while refunding leftover
    /// orders.
    settle_refund_batch: u64,
    /// Most records one `settle_step` call visits while paying Open records.
    settle_payout_batch: u64,
}

// === Defaults and bounds ===

/// Latest τ may fall after placement, in ms. 800 ms on the 200 ms channel puts
/// τ 600 to 800 ms after the order, the launch setting.
macro fun default_delay_ms(): u64 { 800 }

macro fun max_delay_ms(): u64 { 5_000 }

/// Time after τ until a waiting order's deadline refund, in ms.
macro fun default_stall_timeout_ms(): u64 { 5_000 }

macro fun min_stall_timeout_ms(): u64 { 2_000 }

macro fun max_stall_timeout_ms(): u64 { 10_000 }

/// How long an uncommitted cohort may sit past its τ before new orders are
/// refused, in ms. The timing check also requires at least one channel tick.
macro fun default_stuck_threshold_ms(): u64 { 1_500 }

macro fun min_stuck_threshold_ms(): u64 { 50 }

macro fun max_stuck_threshold_ms(): u64 { 10_000 }

/// How long past τ commit waits before it accepts a backup tick, in ms.
macro fun default_gap_wait_ms(): u64 { 2_000 }

macro fun min_gap_wait_ms(): u64 { 50 }

macro fun max_gap_wait_ms(): u64 { 10_000 }

/// Backup-tick switch, in ms: `0`, or exactly one tick of the policy channel.
macro fun default_pyth_price_buffer_ms(): u64 { 0 }

macro fun max_pyth_price_buffer_ms(): u64 { 200 }

/// The 200 ms fixed-rate channel.
macro fun default_pyth_channel(): u8 { lazer_price::channel_fixed_rate_200ms!() }

/// Oldest Block Scholes SVI a placement accepts, in ms. The ceiling is the one
/// Predict's admission enforces.
macro fun default_svi_max_age_ms(): u64 { 60_000 }

/// Unfinished queued mints per market. The 300 ceiling keeps a full 300 + 300
/// commit inside Sui's per-transaction object limit.
macro fun default_mint_capacity(): u64 { 100 }

macro fun max_capacity(): u64 { 300 }

macro fun default_sell_capacity(): u64 { 100 }

/// Unfinished queued orders per account per market. The limits setter also caps
/// it at the smaller capacity.
macro fun default_per_account_cap(): u64 { 5 }

/// Flat fee per queued order: 0.02 USDC by default, capped at 1 USDC.
macro fun default_order_fee(): u64 { 20_000 }

macro fun max_order_fee(): u64 { 1_000_000 }

/// Records one settlement refund call visits. Each refund loads one dynamic
/// child, the record, so 450 leaves room under Sui's 1,000 dynamic-object loads
/// per transaction for the queue, the market, Predict's ledger, and the deny
/// list's few USDC config objects, which load once per transaction. A larger
/// batch could exceed the limit on every call and leave the queue unable to
/// drain.
macro fun default_settle_refund_batch(): u64 { 450 }

macro fun max_settle_refund_batch(): u64 { 450 }

/// Records one settlement payout call visits, one dynamic child each.
macro fun default_settle_payout_batch(): u64 { 900 }

macro fun max_settle_payout_batch(): u64 { 900 }

// === Getters ===
// Public for SDK and devInspect reads of `desk::policy`.

public fun delay_ms(policy: &DelayedExecutionPolicy): u64 { policy.delay_ms }

public fun stall_timeout_ms(policy: &DelayedExecutionPolicy): u64 { policy.stall_timeout_ms }

public fun stuck_threshold_ms(policy: &DelayedExecutionPolicy): u64 { policy.stuck_threshold_ms }

public fun gap_wait_ms(policy: &DelayedExecutionPolicy): u64 { policy.gap_wait_ms }

public fun pyth_price_buffer_ms(policy: &DelayedExecutionPolicy): u64 {
    policy.pyth_price_buffer_ms
}

public fun pyth_channel(policy: &DelayedExecutionPolicy): u8 { policy.pyth_channel }

public fun svi_max_age_ms(policy: &DelayedExecutionPolicy): u64 { policy.svi_max_age_ms }

public fun mint_capacity(policy: &DelayedExecutionPolicy): u64 { policy.mint_capacity }

public fun sell_capacity(policy: &DelayedExecutionPolicy): u64 { policy.sell_capacity }

public fun per_account_cap(policy: &DelayedExecutionPolicy): u64 { policy.per_account_cap }

public fun order_fee(policy: &DelayedExecutionPolicy): u64 { policy.order_fee }

public fun min_sell_quantity(policy: &DelayedExecutionPolicy): u64 { policy.min_sell_quantity }

public fun settle_refund_batch(policy: &DelayedExecutionPolicy): u64 {
    policy.settle_refund_batch
}

public fun settle_payout_batch(policy: &DelayedExecutionPolicy): u64 {
    policy.settle_payout_batch
}

// === Public-Package Functions ===

/// Tick period of a supported channel, in ms. The caller guarantees `channel`
/// is supported.
public(package) fun channel_tick_ms(channel: u8): u64 {
    lazer_price::channel_tick_ms!(channel)
}

/// The launch policy.
public(package) fun new(): DelayedExecutionPolicy {
    DelayedExecutionPolicy {
        delay_ms: default_delay_ms!(),
        stall_timeout_ms: default_stall_timeout_ms!(),
        stuck_threshold_ms: default_stuck_threshold_ms!(),
        gap_wait_ms: default_gap_wait_ms!(),
        pyth_price_buffer_ms: default_pyth_price_buffer_ms!(),
        pyth_channel: default_pyth_channel!(),
        svi_max_age_ms: default_svi_max_age_ms!(),
        mint_capacity: default_mint_capacity!(),
        sell_capacity: default_sell_capacity!(),
        per_account_cap: default_per_account_cap!(),
        order_fee: default_order_fee!(),
        min_sell_quantity: constants::position_lot_size!(),
        settle_refund_batch: default_settle_refund_batch!(),
        settle_payout_batch: default_settle_payout_batch!(),
    }
}

/// Write every timing field after its own bound, then check the relational
/// order on the final state, so an admin never passes through an invalid
/// intermediate one: the channel is a fixed-rate Lazer channel
/// (`EUnsupportedPythChannel`), the buffer is `0` or exactly one tick of it,
/// the stuck threshold spans at least one tick, and `buffer < stuck <= gap <
/// stall`, where `gap < stall` leaves commit room to take a backup tick before
/// the deadline refund (`EInvalidTiming`).
public(package) fun set_timing(
    policy: &mut DelayedExecutionPolicy,
    delay_ms: u64,
    stall_timeout_ms: u64,
    stuck_threshold_ms: u64,
    gap_wait_ms: u64,
    pyth_price_buffer_ms: u64,
    pyth_channel: u8,
    svi_max_age_ms: u64,
) {
    assert!(delay_ms <= max_delay_ms!(), EInvalidDelayMs);
    assert!(
        stall_timeout_ms >= min_stall_timeout_ms!() && stall_timeout_ms <= max_stall_timeout_ms!(),
        EInvalidStallTimeoutMs,
    );
    assert!(
        stuck_threshold_ms >= min_stuck_threshold_ms!()
            && stuck_threshold_ms <= max_stuck_threshold_ms!(),
        EInvalidStuckThresholdMs,
    );
    assert!(
        gap_wait_ms >= min_gap_wait_ms!() && gap_wait_ms <= max_gap_wait_ms!(),
        EInvalidGapWaitMs,
    );
    assert!(pyth_price_buffer_ms <= max_pyth_price_buffer_ms!(), EInvalidPythPriceBufferMs);
    assert!(
        svi_max_age_ms > 0 && svi_max_age_ms <= constants::max_svi_max_age_ms!(),
        EInvalidSviMaxAgeMs,
    );
    assert!(
        pyth_channel == lazer_price::channel_fixed_rate_50ms!()
            || pyth_channel == lazer_price::channel_fixed_rate_200ms!(),
        EUnsupportedPythChannel,
    );
    let tick_ms = channel_tick_ms(pyth_channel);
    assert!(
        (pyth_price_buffer_ms == 0 || pyth_price_buffer_ms == tick_ms)
            && stuck_threshold_ms >= tick_ms
            && pyth_price_buffer_ms < stuck_threshold_ms
            && stuck_threshold_ms <= gap_wait_ms
            && gap_wait_ms < stall_timeout_ms,
        EInvalidTiming,
    );
    policy.delay_ms = delay_ms;
    policy.stall_timeout_ms = stall_timeout_ms;
    policy.stuck_threshold_ms = stuck_threshold_ms;
    policy.gap_wait_ms = gap_wait_ms;
    policy.pyth_price_buffer_ms = pyth_price_buffer_ms;
    policy.pyth_channel = pyth_channel;
    policy.svi_max_age_ms = svi_max_age_ms;
}

/// Write every capacity and batch field after its own bound. The per-account
/// cap may not exceed the smaller capacity (`EInvalidLimits`). The minimum sell
/// is a positive whole number of lots no larger than an order's maximum
/// quantity.
public(package) fun set_limits(
    policy: &mut DelayedExecutionPolicy,
    mint_capacity: u64,
    sell_capacity: u64,
    per_account_cap: u64,
    min_sell_quantity: u64,
    settle_refund_batch: u64,
    settle_payout_batch: u64,
) {
    assert!(mint_capacity > 0 && mint_capacity <= max_capacity!(), EInvalidMintCapacity);
    assert!(sell_capacity > 0 && sell_capacity <= max_capacity!(), EInvalidSellCapacity);
    assert!(per_account_cap > 0 && per_account_cap <= max_capacity!(), EInvalidPerAccountCap);
    let lot = constants::position_lot_size!();
    assert!(
        min_sell_quantity > 0
            && min_sell_quantity % lot == 0
            && min_sell_quantity / lot <= order::max_quantity_lots!(),
        EInvalidMinSellQuantity,
    );
    assert!(
        settle_refund_batch > 0 && settle_refund_batch <= max_settle_refund_batch!(),
        EInvalidSettleRefundBatch,
    );
    assert!(
        settle_payout_batch > 0 && settle_payout_batch <= max_settle_payout_batch!(),
        EInvalidSettlePayoutBatch,
    );
    assert!(per_account_cap <= mint_capacity.min(sell_capacity), EInvalidLimits);
    policy.mint_capacity = mint_capacity;
    policy.sell_capacity = sell_capacity;
    policy.per_account_cap = per_account_cap;
    policy.min_sell_quantity = min_sell_quantity;
    policy.settle_refund_batch = settle_refund_batch;
    policy.settle_payout_batch = settle_payout_batch;
}

/// Write the flat order fee, at most 1 USDC.
public(package) fun set_order_fee(policy: &mut DelayedExecutionPolicy, order_fee: u64) {
    assert!(order_fee <= max_order_fee!(), EInvalidOrderFee);
    policy.order_fee = order_fee;
}
