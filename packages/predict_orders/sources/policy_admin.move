// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Delayed-execution policy storage, setters, bounds, and history event moved
/// out of Predict (`protocol_config`, `config_constants`, `config_events`) for
/// the companion package port. Not yet ported. Per the split design the policy
/// lives in the companion's shared `OrderDesk`; its setters take the desk and
/// Predict's `&AdminCap`, check the desk watermark, and refuse while Predict is
/// frozen through the public `protocol_config::frozen`.
///
/// The 800 ms launch delay (`default_delay_ms`) now lives here with the rest of
/// the policy defaults. Predict keeps two compiled ceilings as public macros
/// that the companion's bounds should reuse: `constants::max_svi_max_age_ms!()`
/// (admission refuses a larger SVI age) and
/// `constants::deadline_expiry_margin_ms!()` (admission refuses a deadline
/// closer than this to expiry).
module deepbook_predict_orders::policy_admin;

// ===== Moved from protocol_config: policy error codes =====
const EPolicyNotInitialized: u64 = 10;
const EPolicyAlreadyInitialized: u64 = 11;
const EInvalidDelayedExecutionTiming: u64 = 12;
const EInvalidDelayedExecutionLimits: u64 = 13;
const EUnsupportedPythChannel: u64 = 18;

// ===== Moved from protocol_config: policy storage key and reads =====
/// Dynamic-field key on `ProtocolConfig` for the `DelayedExecutionPolicy`. The
/// policy arrived after deploy, so it lives off the struct layout. It is absent
/// until `init_delayed_execution_policy` runs, and every queue flow that reads it
/// aborts `EPolicyNotInitialized` until then.
public struct DelayedExecutionPolicyKey() has copy, drop, store;

/// Return the delayed-execution policy, or `none` before
/// `init_delayed_execution_policy` runs. For SDK and devInspect reads.
public fun delayed_execution_policy(config: &ProtocolConfig): Option<DelayedExecutionPolicy> {
    if (!config.id.exists_(DelayedExecutionPolicyKey())) return option::none();
    let policy: &DelayedExecutionPolicy = config.id.borrow(DelayedExecutionPolicyKey());
    option::some(*policy)
}

/// Return the delayed-execution policy. Aborts `EPolicyNotInitialized` before
/// `init_delayed_execution_policy` runs.
public(package) fun policy(config: &ProtocolConfig): &DelayedExecutionPolicy {
    assert!(config.id.exists_(DelayedExecutionPolicyKey()), EPolicyNotInitialized);
    config.id.borrow(DelayedExecutionPolicyKey())
}

// ===== Moved from protocol_config: policy admin entrypoints =====
/// Write the delayed-execution policy with its compiled defaults. Admin-only and
/// version-gated; aborts if the policy already exists. Not gated on an open LP
/// valuation, so a stalled flush cannot block it. Until it runs, enqueue,
/// commit, and resolve abort `EPolicyNotInitialized`.
public fun init_delayed_execution_policy(
    config: &mut ProtocolConfig,
    _admin_cap: &AdminCap,
    clock: &Clock,
) {
    config.assert_version();
    assert!(!config.id.exists_(DelayedExecutionPolicyKey()), EPolicyAlreadyInitialized);
    let policy = delayed_execution_config::new();
    config.id.add(DelayedExecutionPolicyKey(), policy);
    config_events::emit_delayed_execution_policy_updated(&policy, clock.timestamp_ms());
}

/// Set every delayed-execution timing field and the Pyth channel in one call, so
/// the relational order `pyth_price_buffer_ms < stuck_threshold_ms <=
/// gap_wait_ms < stall_timeout_ms` is checked on the final state and an admin
/// never passes through an invalid intermediate one. Each value must also sit in
/// its `config_constants` bound, the channel must be a fixed-rate Lazer channel
/// (`EUnsupportedPythChannel`), the buffer must be `0` or exactly one tick of it,
/// and the stuck threshold at least one tick (`EInvalidDelayedExecutionTiming`).
///
/// Waiting orders keep the τ, deadline, and channel stored at enqueue, so a new
/// delay, stall timeout, or channel only reaches new orders. Commit reads the
/// buffer and gap wait when it runs, so they also apply to waiting cohorts.
/// Admin-only and version-gated; not gated on an open LP valuation.
public fun set_delayed_execution_timing(
    config: &mut ProtocolConfig,
    _admin_cap: &AdminCap,
    delay_ms: u64,
    stall_timeout_ms: u64,
    stuck_threshold_ms: u64,
    gap_wait_ms: u64,
    pyth_price_buffer_ms: u64,
    pyth_channel: u8,
    svi_max_age_ms: u64,
    clock: &Clock,
) {
    config.assert_version();
    let mut policy = *config.policy();
    policy.set_timing(
        delay_ms,
        stall_timeout_ms,
        stuck_threshold_ms,
        gap_wait_ms,
        pyth_price_buffer_ms,
        pyth_channel,
        svi_max_age_ms,
    );
    assert_delayed_execution_timing(&policy);
    config.store_policy(policy, clock);
}

/// Set the queue capacities, the per-account cap, the minimum early sell, and
/// the two `try_settle` batch sizes. Each value must sit in its
/// `config_constants` bound, and the per-account cap may not exceed the smaller
/// capacity (`EInvalidDelayedExecutionLimits`). Lowering a capacity below the
/// current pending count only blocks new orders. Admin-only and version-gated;
/// not gated on an open LP valuation.
public fun set_delayed_execution_limits(
    config: &mut ProtocolConfig,
    _admin_cap: &AdminCap,
    mint_capacity: u64,
    sell_capacity: u64,
    per_account_cap: u64,
    min_sell_quantity: u64,
    settle_refund_batch: u64,
    settle_payout_batch: u64,
    clock: &Clock,
) {
    config.assert_version();
    let mut policy = *config.policy();
    policy.set_limits(
        mint_capacity,
        sell_capacity,
        per_account_cap,
        min_sell_quantity,
        settle_refund_batch,
        settle_payout_batch,
    );
    assert!(per_account_cap <= mint_capacity.min(sell_capacity), EInvalidDelayedExecutionLimits);
    config.store_policy(policy, clock);
}

/// Set the flat fee charged per queued order, in USDC base units, up to the
/// `config_constants` cap of 1 USDC. Applies to orders placed after the call;
/// waiting orders keep the fee they paid. Admin-only and version-gated; not
/// gated on an open LP valuation.
public fun set_order_fee(
    config: &mut ProtocolConfig,
    _admin_cap: &AdminCap,
    order_fee: u64,
    clock: &Clock,
) {
    config.assert_version();
    let mut policy = *config.policy();
    policy.set_order_fee(order_fee);
    config.store_policy(policy, clock);
}

// ===== Moved from protocol_config: policy validation and storage =====
/// Abort unless the timing fields fit the policy channel and each other: the
/// buffer is `0` or exactly one tick, so a backup tick can only be the next
/// update after τ; the stuck threshold spans at least one tick; and `buffer <
/// stuck <= gap < stall`, where `gap < stall` leaves commit room to take a
/// backup tick before the deadline refund. The channel check comes first
/// because the tick size is only defined for a supported channel.
fun assert_delayed_execution_timing(policy: &DelayedExecutionPolicy) {
    let channel = policy.pyth_channel();
    assert!(delayed_execution_config::is_supported_channel(channel), EUnsupportedPythChannel);
    let tick_ms = delayed_execution_config::channel_tick_ms(channel);
    let buffer_ms = policy.pyth_price_buffer_ms();
    let stuck_ms = policy.stuck_threshold_ms();
    let gap_ms = policy.gap_wait_ms();
    assert!(buffer_ms == 0 || buffer_ms == tick_ms, EInvalidDelayedExecutionTiming);
    assert!(stuck_ms >= tick_ms, EInvalidDelayedExecutionTiming);
    assert!(
        buffer_ms < stuck_ms && stuck_ms <= gap_ms && gap_ms < policy.stall_timeout_ms(),
        EInvalidDelayedExecutionTiming,
    );
}

/// Replace the stored policy with a fully validated one and emit its complete
/// post-state.
fun store_policy(config: &mut ProtocolConfig, policy: DelayedExecutionPolicy, clock: &Clock) {
    let stored: &mut DelayedExecutionPolicy = config.id.borrow_mut(DelayedExecutionPolicyKey());
    *stored = policy;
    config_events::emit_delayed_execution_policy_updated(&policy, clock.timestamp_ms());
}

// ===== Moved from config_events: policy history event =====
/// Emitted by every delayed-execution policy write (initialization and each
/// setter) with the complete post-state.
public struct DelayedExecutionPolicyUpdated has copy, drop, store {
    policy: DelayedExecutionPolicy,
    onchain_timestamp_ms: u64,
}

public(package) fun emit_delayed_execution_policy_updated(
    policy: &DelayedExecutionPolicy,
    onchain_timestamp_ms: u64,
) {
    event::emit(DelayedExecutionPolicyUpdated { policy: *policy, onchain_timestamp_ms });
}

// ===== Moved from config_constants: policy bound error codes =====
const EInvalidDelayMs: u64 = 28;
const EInvalidStallTimeoutMs: u64 = 29;
const EInvalidStuckThresholdMs: u64 = 30;
const EInvalidGapWaitMs: u64 = 31;
const EInvalidPythPriceBufferMs: u64 = 32;
const EInvalidSviMaxAgeMs: u64 = 33;
const EInvalidMintCapacity: u64 = 34;
const EInvalidSellCapacity: u64 = 35;
const EInvalidPerAccountCap: u64 = 36;
const EInvalidMinSellQuantity: u64 = 37;
const EInvalidOrderFee: u64 = 38;
const EInvalidSettleRefundBatch: u64 = 39;
const EInvalidSettlePayoutBatch: u64 = 40;

// === Delayed Execution ===
// Single-value bounds for `DelayedExecutionPolicy`. The relational rules between
// the timing fields and the Pyth channel's tick live in the `protocol_config`
// setters, which see every field at once.

/// Latest τ may fall after placement, in ms. τ rounds down to the policy
/// channel's tick at or before `t₀ + delay_ms`, so `0` prices on the tick at or
/// before placement. 800 ms on the 200 ms channel puts τ 600 to 800 ms after
/// the order, the launch setting.
public(package) macro fun default_delay_ms(): u64 { 800 }

public(package) macro fun min_delay_ms(): u64 { 0 }

public(package) macro fun max_delay_ms(): u64 { 5_000 }

public(package) fun assert_delay_ms(value: u64) {
    assert!(value >= min_delay_ms!() && value <= max_delay_ms!(), EInvalidDelayMs);
}

/// Time after τ until a waiting order's deadline refund, in ms.
public(package) macro fun default_stall_timeout_ms(): u64 { 5_000 }

public(package) macro fun min_stall_timeout_ms(): u64 { 2_000 }

public(package) macro fun max_stall_timeout_ms(): u64 { 10_000 }

public(package) fun assert_stall_timeout_ms(value: u64) {
    assert!(
        value >= min_stall_timeout_ms!() && value <= max_stall_timeout_ms!(),
        EInvalidStallTimeoutMs,
    );
}

/// How long an uncommitted cohort may sit past its τ before new orders are
/// refused, in ms. The setter also requires at least one tick of the channel.
public(package) macro fun default_stuck_threshold_ms(): u64 { 1_500 }

public(package) macro fun min_stuck_threshold_ms(): u64 { 50 }

public(package) macro fun max_stuck_threshold_ms(): u64 { 10_000 }

public(package) fun assert_stuck_threshold_ms(value: u64) {
    assert!(
        value >= min_stuck_threshold_ms!() && value <= max_stuck_threshold_ms!(),
        EInvalidStuckThresholdMs,
    );
}

/// How long past τ commit waits before it accepts a backup tick, in ms.
public(package) macro fun default_gap_wait_ms(): u64 { 2_000 }

public(package) macro fun min_gap_wait_ms(): u64 { 50 }

public(package) macro fun max_gap_wait_ms(): u64 { 10_000 }

public(package) fun assert_gap_wait_ms(value: u64) {
    assert!(value >= min_gap_wait_ms!() && value <= max_gap_wait_ms!(), EInvalidGapWaitMs);
}

/// Backup-tick switch, in ms. `0` accepts only the update stamped exactly τ.
/// Above `0` a cohort also accepts the update one tick of its own channel after
/// τ. The setter also requires `0` or exactly one channel tick.
public(package) macro fun default_pyth_price_buffer_ms(): u64 { 0 }

public(package) macro fun min_pyth_price_buffer_ms(): u64 { 0 }

public(package) macro fun max_pyth_price_buffer_ms(): u64 { 200 }

public(package) fun assert_pyth_price_buffer_ms(value: u64) {
    assert!(
        value >= min_pyth_price_buffer_ms!() && value <= max_pyth_price_buffer_ms!(),
        EInvalidPythPriceBufferMs,
    );
}

/// Pyth Lazer channel new orders are priced on: `3` is `fixed_rate@200ms`. The
/// setter accepts only the fixed-rate channels (`2` and `3`).
public(package) macro fun default_pyth_channel(): u8 { 3 }

/// Oldest Block Scholes SVI an enqueue accepts, in ms.
public(package) macro fun default_svi_max_age_ms(): u64 { 60_000 }

public(package) macro fun min_svi_max_age_ms(): u64 { 1 }

public(package) macro fun max_svi_max_age_ms(): u64 { 120_000 }

public(package) fun assert_svi_max_age_ms(value: u64) {
    assert!(value >= min_svi_max_age_ms!() && value <= max_svi_max_age_ms!(), EInvalidSviMaxAgeMs);
}

/// Most unfinished queued mints one market holds. The 300 ceiling keeps a full
/// 300 + 300 commit inside Sui's per-transaction object limit.
public(package) macro fun default_mint_capacity(): u64 { 100 }

public(package) macro fun min_mint_capacity(): u64 { 1 }

public(package) macro fun max_mint_capacity(): u64 { 300 }

public(package) fun assert_mint_capacity(value: u64) {
    assert!(value >= min_mint_capacity!() && value <= max_mint_capacity!(), EInvalidMintCapacity);
}

/// Most unfinished queued sells one market holds.
public(package) macro fun default_sell_capacity(): u64 { 100 }

public(package) macro fun min_sell_capacity(): u64 { 1 }

public(package) macro fun max_sell_capacity(): u64 { 300 }

public(package) fun assert_sell_capacity(value: u64) {
    assert!(value >= min_sell_capacity!() && value <= max_sell_capacity!(), EInvalidSellCapacity);
}

/// Most unfinished queued orders one account holds in one market. The setter
/// also caps it at the smaller of the two capacities.
public(package) macro fun default_per_account_cap(): u64 { 5 }

public(package) macro fun min_per_account_cap(): u64 { 1 }

public(package) macro fun max_per_account_cap(): u64 { 300 }

public(package) fun assert_per_account_cap(value: u64) {
    assert!(
        value >= min_per_account_cap!() && value <= max_per_account_cap!(),
        EInvalidPerAccountCap,
    );
}

/// Flat fee per queued order, in USDC base units: 0.02 USDC by default, capped
/// at 1 USDC.
public(package) macro fun default_order_fee(): u64 { 20_000 }

public(package) macro fun min_order_fee(): u64 { 0 }

public(package) macro fun max_order_fee(): u64 { 1_000_000 }

public(package) fun assert_order_fee(value: u64) {
    assert!(value >= min_order_fee!() && value <= max_order_fee!(), EInvalidOrderFee);
}

/// Smallest early-sell close quantity. The default is one position lot, the
/// smallest quantity a mint can buy.
public(package) macro fun default_min_sell_quantity(): u64 {
    deepbook_predict::constants::position_lot_size!()
}

/// A positive whole number of lots no larger than an order's maximum quantity.
public(package) fun assert_min_sell_quantity(value: u64) {
    let lot = deepbook_predict::constants::position_lot_size!();
    assert!(
        value > 0
            && value % lot == 0
            && value / lot <= deepbook_predict::order::max_quantity_lots(),
        EInvalidMinSellQuantity,
    );
}

/// Most records one `try_settle` call visits while refunding leftover orders.
/// Each settlement refund skips pruning but still loads two dynamic children,
/// the order record and the account's per-account row.
public(package) macro fun default_settle_refund_batch(): u64 { 450 }

public(package) macro fun min_settle_refund_batch(): u64 { 1 }

/// Sized from Sui's 1,000 dynamic-object loads per transaction: 2 × 450 = 900
/// children, leaving 100 for the `OrderBook` and other fixed loads. A larger
/// batch could exceed the limit on every call and leave the market unable to
/// settle, which also blocks LP valuation.
public(package) macro fun max_settle_refund_batch(): u64 { 450 }

public(package) fun assert_settle_refund_batch(value: u64) {
    assert!(
        value >= min_settle_refund_batch!() && value <= max_settle_refund_batch!(),
        EInvalidSettleRefundBatch,
    );
}

/// Most records one `try_settle` call visits while paying Open records. Each
/// visit loads one dynamic child, the order record.
public(package) macro fun default_settle_payout_batch(): u64 { 900 }

public(package) macro fun min_settle_payout_batch(): u64 { 1 }

/// Sized from Sui's 1,000 dynamic-object loads per transaction: 1 × 900 = 900
/// children, leaving 100 for the `OrderBook` and other fixed loads, as the
/// refund batch does.
public(package) macro fun max_settle_payout_batch(): u64 { 900 }

public(package) fun assert_settle_payout_batch(value: u64) {
    assert!(
        value >= min_settle_payout_batch!() && value <= max_settle_payout_batch!(),
        EInvalidSettlePayoutBatch,
    );
}
