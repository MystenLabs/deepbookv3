// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Admin-tunable policy for delayed execution: the timing, capacity, fee, and
/// settlement-batch settings that queued mints and early sells run under.
///
/// A leaf module, so `config_events` can embed the policy and `protocol_config`
/// can store it under its own UID without an import cycle. It owns the struct,
/// its defaults, the field getters, the package setters with their single-value
/// bounds, and the Pyth Lazer channel helpers. Relational checks between fields
/// live in the `protocol_config` setters, which see every field at once.
module deepbook_predict::delayed_execution_config;

use deepbook_predict::config_constants;

/// Delayed-execution settings, stored under `ProtocolConfig`'s UID once
/// `protocol_config::init_delayed_execution_policy` runs. Times are milliseconds
/// and USDC amounts are base units.
public struct DelayedExecutionPolicy has copy, drop, store {
    /// Latest τ may fall after placement. τ rounds down to the policy channel's
    /// tick at or before `t₀ + delay_ms`.
    delay_ms: u64,
    /// Sets each order's deadline: `max(min(τ + stall_timeout_ms, expiry), last
    /// deadline)`. At or past it the order is refunded, never filled.
    stall_timeout_ms: u64,
    /// Enqueue refuses new orders while an uncommitted cohort is this far past
    /// its τ with nothing newer committed, or while two or more uncommitted
    /// cohorts are each this far past their τ.
    stuck_threshold_ms: u64,
    /// Commit accepts a backup tick for a cohort only once now is this far past
    /// its τ.
    gap_wait_ms: u64,
    /// Switches the backup tick on or off. `0` accepts only the update stamped
    /// exactly τ. Above `0`, once now is `gap_wait_ms` past τ, a cohort also
    /// accepts its single backup: the update stamped one tick of its own stored
    /// channel after τ. The value is not a window. The setter keeps it at `0` or
    /// one tick of the policy channel.
    pyth_price_buffer_ms: u64,
    /// Pyth Lazer channel new orders are priced on: `2` (`fixed_rate@50ms`) or
    /// `3` (`fixed_rate@200ms`). Its tick period is τ's grid. Each order stores
    /// the channel it was placed under.
    pyth_channel: u8,
    /// Oldest Block Scholes SVI an enqueue accepts into an order's volatility
    /// snapshot.
    svi_max_age_ms: u64,
    /// Most unfinished queued mints per market.
    mint_capacity: u64,
    /// Most unfinished queued sells per market.
    sell_capacity: u64,
    /// Most unfinished queued orders per account per market.
    per_account_cap: u64,
    /// Flat fee charged at enqueue. Kept on a fill and on limit or admission
    /// refunds; returned on every other refund.
    order_fee: u64,
    /// Smallest early-sell close quantity.
    min_sell_quantity: u64,
    /// Most records one `try_settle` call visits while refunding leftover orders.
    settle_refund_batch: u64,
    /// Most records one `try_settle` call visits while paying Open records.
    settle_payout_batch: u64,
}

// === Channels ===

/// Pyth Lazer channel id of `fixed_rate@50ms`.
public(package) macro fun pyth_channel_fixed_rate_50ms(): u8 { 2 }

/// Pyth Lazer channel id of `fixed_rate@200ms`.
public(package) macro fun pyth_channel_fixed_rate_200ms(): u8 { 3 }

// === Getters ===
// Public for SDK and devInspect policy reads; the queue flows read them in-package.

public fun delay_ms(policy: &DelayedExecutionPolicy): u64 {
    policy.delay_ms
}

public fun stall_timeout_ms(policy: &DelayedExecutionPolicy): u64 {
    policy.stall_timeout_ms
}

public fun stuck_threshold_ms(policy: &DelayedExecutionPolicy): u64 {
    policy.stuck_threshold_ms
}

public fun gap_wait_ms(policy: &DelayedExecutionPolicy): u64 {
    policy.gap_wait_ms
}

public fun pyth_price_buffer_ms(policy: &DelayedExecutionPolicy): u64 {
    policy.pyth_price_buffer_ms
}

public fun pyth_channel(policy: &DelayedExecutionPolicy): u8 {
    policy.pyth_channel
}

public fun svi_max_age_ms(policy: &DelayedExecutionPolicy): u64 {
    policy.svi_max_age_ms
}

public fun mint_capacity(policy: &DelayedExecutionPolicy): u64 {
    policy.mint_capacity
}

public fun sell_capacity(policy: &DelayedExecutionPolicy): u64 {
    policy.sell_capacity
}

public fun per_account_cap(policy: &DelayedExecutionPolicy): u64 {
    policy.per_account_cap
}

public fun order_fee(policy: &DelayedExecutionPolicy): u64 {
    policy.order_fee
}

public fun min_sell_quantity(policy: &DelayedExecutionPolicy): u64 {
    policy.min_sell_quantity
}

public fun settle_refund_batch(policy: &DelayedExecutionPolicy): u64 {
    policy.settle_refund_batch
}

public fun settle_payout_batch(policy: &DelayedExecutionPolicy): u64 {
    policy.settle_payout_batch
}

// === Public-Package Functions ===

/// Whether `channel` is a fixed-rate Pyth Lazer channel the queue can price on.
public(package) fun is_supported_channel(channel: u8): bool {
    channel == pyth_channel_fixed_rate_50ms!() || channel == pyth_channel_fixed_rate_200ms!()
}

/// Tick period of a supported channel, in ms. The caller guarantees `channel`
/// is supported.
public(package) fun channel_tick_ms(channel: u8): u64 {
    if (channel == pyth_channel_fixed_rate_50ms!()) 50 else 200
}

/// Create the policy from its compiled defaults.
public(package) fun new(): DelayedExecutionPolicy {
    DelayedExecutionPolicy {
        delay_ms: config_constants::default_delay_ms!(),
        stall_timeout_ms: config_constants::default_stall_timeout_ms!(),
        stuck_threshold_ms: config_constants::default_stuck_threshold_ms!(),
        gap_wait_ms: config_constants::default_gap_wait_ms!(),
        pyth_price_buffer_ms: config_constants::default_pyth_price_buffer_ms!(),
        pyth_channel: config_constants::default_pyth_channel!(),
        svi_max_age_ms: config_constants::default_svi_max_age_ms!(),
        mint_capacity: config_constants::default_mint_capacity!(),
        sell_capacity: config_constants::default_sell_capacity!(),
        per_account_cap: config_constants::default_per_account_cap!(),
        order_fee: config_constants::default_order_fee!(),
        min_sell_quantity: config_constants::default_min_sell_quantity!(),
        settle_refund_batch: config_constants::default_settle_refund_batch!(),
        settle_payout_batch: config_constants::default_settle_payout_batch!(),
    }
}

/// Write every timing field after its single-value bound. The caller owns the
/// channel check and the relational checks between these fields.
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
    config_constants::assert_delay_ms(delay_ms);
    config_constants::assert_stall_timeout_ms(stall_timeout_ms);
    config_constants::assert_stuck_threshold_ms(stuck_threshold_ms);
    config_constants::assert_gap_wait_ms(gap_wait_ms);
    config_constants::assert_pyth_price_buffer_ms(pyth_price_buffer_ms);
    config_constants::assert_svi_max_age_ms(svi_max_age_ms);
    policy.delay_ms = delay_ms;
    policy.stall_timeout_ms = stall_timeout_ms;
    policy.stuck_threshold_ms = stuck_threshold_ms;
    policy.gap_wait_ms = gap_wait_ms;
    policy.pyth_price_buffer_ms = pyth_price_buffer_ms;
    policy.pyth_channel = pyth_channel;
    policy.svi_max_age_ms = svi_max_age_ms;
}

/// Write every capacity and batch field after its single-value bound. The
/// caller owns the per-account cap's bound against the two capacities.
public(package) fun set_limits(
    policy: &mut DelayedExecutionPolicy,
    mint_capacity: u64,
    sell_capacity: u64,
    per_account_cap: u64,
    min_sell_quantity: u64,
    settle_refund_batch: u64,
    settle_payout_batch: u64,
) {
    config_constants::assert_mint_capacity(mint_capacity);
    config_constants::assert_sell_capacity(sell_capacity);
    config_constants::assert_per_account_cap(per_account_cap);
    config_constants::assert_min_sell_quantity(min_sell_quantity);
    config_constants::assert_settle_refund_batch(settle_refund_batch);
    config_constants::assert_settle_payout_batch(settle_payout_batch);
    policy.mint_capacity = mint_capacity;
    policy.sell_capacity = sell_capacity;
    policy.per_account_cap = per_account_cap;
    policy.min_sell_quantity = min_sell_quantity;
    policy.settle_refund_batch = settle_refund_batch;
    policy.settle_payout_batch = settle_payout_batch;
}

/// Write the flat order fee after its single-value bound.
public(package) fun set_order_fee(policy: &mut DelayedExecutionPolicy, order_fee: u64) {
    config_constants::assert_order_fee(order_fee);
    policy.order_fee = order_fee;
}
