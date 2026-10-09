// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// The `OrderDesk` and its delayed-execution policy on a real shared Predict
/// `ProtocolConfig`: the desk `init` shares at publish, the timing, limits, and
/// order-fee setters, and the version floor. Defaults and bounds are the spec's
/// literals, never read back from `delayed_execution_config`. Each setter is
/// checked for its gates, every single-value bound on both sides, the relational
/// timing order, the per-account cap against the smaller capacity, and the
/// complete post-state it stores and emits.
#[test_only]
module deepbook_predict_orders::delayed_execution_policy_tests;

use deepbook_predict::{
    constants,
    flow_test_helpers::{Self as helpers, Fixture},
    protocol_config::ProtocolConfig,
    test_constants
};
use deepbook_predict_orders::{
    delayed_execution_config,
    desk::{Self, OrderDesk},
    order_flow::OrderFlow,
    queue_events
};
use std::{bcs, unit_test::assert_eq};
use sui::{event, test_scenario::{most_recent_id_shared, return_shared}};

const EVENT_TIMESTAMP_MS: u64 = 1_750_000_000_000;
const ONE_EVENT: u64 = 1;
const THREE_EVENTS: u64 = 3;
const LAUNCH_VERSION: u64 = 1;

// Spec defaults.
const DEFAULT_DELAY_MS: u64 = 800;
const DEFAULT_STALL_TIMEOUT_MS: u64 = 5_000;
const DEFAULT_STUCK_THRESHOLD_MS: u64 = 1_500;
const DEFAULT_GAP_WAIT_MS: u64 = 2_000;
const DEFAULT_PYTH_PRICE_BUFFER_MS: u64 = 0;
const DEFAULT_SVI_MAX_AGE_MS: u64 = 60_000;
const DEFAULT_MINT_CAPACITY: u64 = 100;
const DEFAULT_SELL_CAPACITY: u64 = 100;
const DEFAULT_PER_ACCOUNT_CAP: u64 = 5;
/// 0.02 USDC.
const DEFAULT_ORDER_FEE: u64 = 20_000;
const DEFAULT_SETTLE_REFUND_BATCH: u64 = 450;
const DEFAULT_SETTLE_PAYOUT_BATCH: u64 = 900;

// Pyth Lazer channel ids and their tick periods.
const CHANNEL_REAL_TIME: u8 = 1;
const CHANNEL_FIXED_RATE_50MS: u8 = 2;
const CHANNEL_FIXED_RATE_200MS: u8 = 3;
const CHANNEL_UNKNOWN: u8 = 4;
const TICK_50MS: u64 = 50;
const TICK_200MS: u64 = 200;

// Single-value bounds.
const MAX_DELAY_MS: u64 = 5_000;
const MIN_STALL_TIMEOUT_MS: u64 = 2_000;
const MAX_STALL_TIMEOUT_MS: u64 = 10_000;
/// One tick of the 50 ms channel, the fastest supported.
const MIN_STUCK_THRESHOLD_MS: u64 = 50;
const MAX_STUCK_THRESHOLD_MS: u64 = 10_000;
const MIN_GAP_WAIT_MS: u64 = 50;
const MAX_GAP_WAIT_MS: u64 = 10_000;
/// One tick of the 200 ms channel, the slowest supported.
const MAX_PYTH_PRICE_BUFFER_MS: u64 = 200;
const MIN_SVI_MAX_AGE_MS: u64 = 1;
const MAX_SVI_MAX_AGE_MS: u64 = 120_000;
const MIN_CAPACITY: u64 = 1;
const MAX_CAPACITY: u64 = 300;
/// 1 USDC.
const MAX_ORDER_FEE: u64 = 1_000_000;
const MIN_SETTLE_BATCH: u64 = 1;
/// One child per drained record, 450 per call.
const MAX_SETTLE_REFUND_BATCH: u64 = 450;
/// One child per visited record, 900 per call.
const MAX_SETTLE_PAYOUT_BATCH: u64 = 900;
/// 2^32 - 1: the widest lot count the packed order id's 32-bit quantity field holds.
const MAX_ORDER_QUANTITY_LOTS: u64 = 4_294_967_295;

// Non-default values the happy paths write, all different from the defaults
// and from each other so a swapped getter or field shows.
const CUSTOM_DELAY_MS: u64 = 1_200;
const CUSTOM_STALL_TIMEOUT_MS: u64 = 4_000;
const CUSTOM_STUCK_THRESHOLD_MS: u64 = 1_000;
const CUSTOM_GAP_WAIT_MS: u64 = 1_500;
const CUSTOM_SVI_MAX_AGE_MS: u64 = 30_000;
const CUSTOM_MINT_CAPACITY: u64 = 120;
const CUSTOM_SELL_CAPACITY: u64 = 80;
const CUSTOM_PER_ACCOUNT_CAP: u64 = 7;
const CUSTOM_MIN_SELL_LOTS: u64 = 3;
const CUSTOM_SETTLE_REFUND_BATCH: u64 = 400;
const CUSTOM_SETTLE_PAYOUT_BATCH: u64 = 800;
const CUSTOM_ORDER_FEE: u64 = 50_000;

// Capacities that differ, for the per-account cap against the smaller one.
const SMALL_CAPACITY: u64 = 10;
const LARGE_CAPACITY: u64 = 20;

/// The timing setter's inputs, in its parameter order.
public struct Timing has copy, drop {
    delay_ms: u64,
    stall_timeout_ms: u64,
    stuck_threshold_ms: u64,
    gap_wait_ms: u64,
    pyth_price_buffer_ms: u64,
    pyth_channel: u8,
    svi_max_age_ms: u64,
}

/// The limits setter's inputs, in its parameter order.
public struct Limits has copy, drop {
    mint_capacity: u64,
    sell_capacity: u64,
    per_account_cap: u64,
    min_sell_quantity: u64,
    settle_refund_batch: u64,
    settle_payout_batch: u64,
}

/// Field-for-field mirror of `DelayedExecutionPolicy`, for its BCS layout.
public struct ExpectedPolicy has copy, drop {
    delay_ms: u64,
    stall_timeout_ms: u64,
    stuck_threshold_ms: u64,
    gap_wait_ms: u64,
    pyth_price_buffer_ms: u64,
    pyth_channel: u8,
    svi_max_age_ms: u64,
    mint_capacity: u64,
    sell_capacity: u64,
    per_account_cap: u64,
    order_fee: u64,
    min_sell_quantity: u64,
    settle_refund_batch: u64,
    settle_payout_batch: u64,
}

/// Field-for-field mirror of `queue_events::DelayedExecutionPolicyUpdated`.
public struct ExpectedPolicyUpdated has copy, drop {
    desk_id: ID,
    policy: ExpectedPolicy,
    onchain_timestamp_ms: u64,
}

// === Creation ===

/// `init` shares the desk at the spec defaults and the launch floor. It emits
/// no policy event, having no `Clock` to stamp one with, and needs no
/// allowlisting: Predict's witness gate binds at admission, not here.
#[test]
fun init_shares_the_desk_at_the_spec_defaults() {
    let mut fx = helpers::setup_market_default();
    let config = take_config(&mut fx);
    assert!(!config.is_order_flow<OrderFlow>());
    return_shared(config);
    desk::init_for_testing(fx.scenario_mut().ctx());
    assert!(event::events_by_type<queue_events::DelayedExecutionPolicyUpdated>().is_empty());
    fx.scenario_mut().next_tx(test_constants::admin());
    let desk_id = most_recent_id_shared<OrderDesk>().destroy_some();
    let desk = fx.scenario_mut().take_shared_by_id<OrderDesk>(desk_id);
    assert_eq!(desk.id(), desk_id);
    assert_eq!(desk.version_watermark(), LAUNCH_VERSION);
    assert_policy(&desk, default_timing(), default_limits(), DEFAULT_ORDER_FEE);
    return_shared(desk);
    fx.finish();
}

// === Gates ===

#[test, expected_failure(abort_code = desk::EProtocolFrozen)]
fun set_timing_while_frozen_aborts() {
    let (mut fx, mut desk, mut config) = new_desk();
    freeze_predict(&mut fx, &mut config);
    set_timing(&mut fx, &mut desk, &config, default_timing());
    abort 999
}

#[test, expected_failure(abort_code = desk::EProtocolFrozen)]
fun set_limits_while_frozen_aborts() {
    let (mut fx, mut desk, mut config) = new_desk();
    freeze_predict(&mut fx, &mut config);
    set_limits(&mut fx, &mut desk, &config, default_limits());
    abort 999
}

#[test, expected_failure(abort_code = desk::EProtocolFrozen)]
fun set_order_fee_while_frozen_aborts() {
    let (mut fx, mut desk, mut config) = new_desk();
    freeze_predict(&mut fx, &mut config);
    set_order_fee(&mut fx, &mut desk, &config, DEFAULT_ORDER_FEE);
    abort 999
}

/// The floor starts at the launch version, so bumping it in the launch
/// version has nothing to retire. `EPackageVersionDisabled` needs a later
/// companion version to raise the floor, which no unit test can build.
#[test, expected_failure(abort_code = desk::EVersionWatermarkNotAdvanced)]
fun bumping_the_floor_at_the_launch_version_aborts() {
    let (mut fx, mut desk, config) = new_desk();
    let (admin_cap, _, _) = fx.admin_parts();
    desk.bump_version_watermark(admin_cap);
    return_shared(config);
    abort 999
}

/// None of the setters is gated on an open LP valuation, so a stalled flush
/// cannot trap them, and removing the witness stops fills, not policy changes.
/// Pinned positively, since a uniform valuation gate would leave every
/// negative test green.
#[test]
fun setters_run_during_open_valuation_and_with_the_witness_removed() {
    let (mut fx, expiry_id, _) = helpers::setup_live_market(
        test_constants::default_expiry_ms(),
        test_constants::default_live_price(),
    );
    fx.cutover();
    fx.set_clock_for_testing(EVENT_TIMESTAMP_MS);
    let mut market = fx.take_market_bundle(expiry_id);
    {
        let (admin_cap, clock, ctx) = fx.admin_parts();
        helpers::config_mut(&mut market).set_order_flow<OrderFlow>(admin_cap, true, clock);
        desk::init_for_testing(ctx);
    };
    helpers::return_market_bundle(market);
    fx.scenario_mut().next_tx(test_constants::admin());
    let desk_id = most_recent_id_shared<OrderDesk>().destroy_some();
    let mut desk = fx.scenario_mut().take_shared_by_id<OrderDesk>(desk_id);
    let mut market = fx.take_market_bundle(expiry_id);
    helpers::begin_val(&mut market);
    {
        let (admin_cap, clock, _) = fx.admin_parts();
        helpers::config_mut(&mut market).set_order_flow<OrderFlow>(admin_cap, false, clock);
    };

    set_timing(&mut fx, &mut desk, helpers::config(&market), custom_timing());
    set_limits(&mut fx, &mut desk, helpers::config(&market), custom_limits());
    set_order_fee(&mut fx, &mut desk, helpers::config(&market), CUSTOM_ORDER_FEE);

    assert!(helpers::config(&market).valuation_in_progress());
    assert_policy(&desk, custom_timing(), custom_limits(), CUSTOM_ORDER_FEE);
    // Three setters, the last carrying every custom value.
    assert_last_policy_event(
        THREE_EVENTS,
        desk_id,
        custom_timing(),
        custom_limits(),
        CUSTOM_ORDER_FEE,
    );
    return_shared(desk);
    helpers::return_market_bundle(market);
    fx.finish();
}

// === Happy paths: each setter writes its fields, keeps the rest, emits it all ===

#[test]
fun set_timing_writes_timing_and_keeps_other_fields() {
    let (mut fx, mut desk, config) = new_desk();
    set_timing(&mut fx, &mut desk, &config, custom_timing());
    assert_policy(&desk, custom_timing(), default_limits(), DEFAULT_ORDER_FEE);
    assert_last_policy_event(
        ONE_EVENT,
        desk.id(),
        custom_timing(),
        default_limits(),
        DEFAULT_ORDER_FEE,
    );
    finish(fx, desk, config);
}

#[test]
fun set_limits_writes_limits_and_keeps_other_fields() {
    let (mut fx, mut desk, config) = new_desk();
    set_limits(&mut fx, &mut desk, &config, custom_limits());
    assert_policy(&desk, default_timing(), custom_limits(), DEFAULT_ORDER_FEE);
    assert_last_policy_event(
        ONE_EVENT,
        desk.id(),
        default_timing(),
        custom_limits(),
        DEFAULT_ORDER_FEE,
    );
    finish(fx, desk, config);
}

#[test]
fun set_order_fee_writes_fee_and_keeps_other_fields() {
    let (mut fx, mut desk, config) = new_desk();
    set_order_fee(&mut fx, &mut desk, &config, CUSTOM_ORDER_FEE);
    assert_policy(&desk, default_timing(), default_limits(), CUSTOM_ORDER_FEE);
    assert_last_policy_event(
        ONE_EVENT,
        desk.id(),
        default_timing(),
        default_limits(),
        CUSTOM_ORDER_FEE,
    );
    finish(fx, desk, config);
}

// === Timing: delay ===

#[test]
fun delay_accepts_zero_and_max() {
    let (mut fx, mut desk, config) = new_desk();
    // No floor: 0 prices on the tick at or before placement.
    let mut timing = default_timing();
    timing.delay_ms = 0;
    assert_timing_accepted(&mut fx, &mut desk, &config, timing);
    timing.delay_ms = MAX_DELAY_MS;
    assert_timing_accepted(&mut fx, &mut desk, &config, timing);
    finish(fx, desk, config);
}

#[test, expected_failure(abort_code = delayed_execution_config::EInvalidDelayMs)]
fun delay_above_max_aborts() {
    let mut timing = default_timing();
    timing.delay_ms = MAX_DELAY_MS + 1;
    set_timing_on_new_desk(timing);
}

// === Timing: stall timeout ===

#[test]
fun stall_timeout_accepts_min_and_max() {
    let (mut fx, mut desk, config) = new_desk();
    // At the 2,000 floor the gap wait must drop below it: 1,500 <= 1,999 < 2,000.
    let mut timing = default_timing();
    timing.stall_timeout_ms = MIN_STALL_TIMEOUT_MS;
    timing.gap_wait_ms = MIN_STALL_TIMEOUT_MS - 1;
    assert_timing_accepted(&mut fx, &mut desk, &config, timing);
    timing.stall_timeout_ms = MAX_STALL_TIMEOUT_MS;
    assert_timing_accepted(&mut fx, &mut desk, &config, timing);
    finish(fx, desk, config);
}

#[test, expected_failure(abort_code = delayed_execution_config::EInvalidStallTimeoutMs)]
fun stall_timeout_below_min_aborts() {
    // The order still holds (1,500 <= 1,998 < 1,999), so only the bound fails.
    let mut timing = default_timing();
    timing.stall_timeout_ms = MIN_STALL_TIMEOUT_MS - 1;
    timing.gap_wait_ms = MIN_STALL_TIMEOUT_MS - 2;
    set_timing_on_new_desk(timing);
}

#[test, expected_failure(abort_code = delayed_execution_config::EInvalidStallTimeoutMs)]
fun stall_timeout_above_max_aborts() {
    let mut timing = default_timing();
    timing.stall_timeout_ms = MAX_STALL_TIMEOUT_MS + 1;
    set_timing_on_new_desk(timing);
}

// === Timing: stuck threshold and gap wait ===

/// The floors are one 50 ms tick, reachable together on the 50 ms channel. The
/// single-value ceilings of 10,000 can never satisfy `gap < stall <= 10,000`,
/// so the widest valid stuck threshold and gap wait are 9,999.
#[test]
fun stuck_and_gap_accept_one_fast_tick_and_widest_order() {
    let (mut fx, mut desk, config) = new_desk();
    let mut timing = default_timing();
    timing.pyth_channel = CHANNEL_FIXED_RATE_50MS;
    timing.stuck_threshold_ms = MIN_STUCK_THRESHOLD_MS;
    timing.gap_wait_ms = MIN_GAP_WAIT_MS;
    assert_timing_accepted(&mut fx, &mut desk, &config, timing);

    timing.stuck_threshold_ms = MAX_STALL_TIMEOUT_MS - 1;
    timing.gap_wait_ms = MAX_STALL_TIMEOUT_MS - 1;
    timing.stall_timeout_ms = MAX_STALL_TIMEOUT_MS;
    assert_timing_accepted(&mut fx, &mut desk, &config, timing);
    finish(fx, desk, config);
}

#[test, expected_failure(abort_code = delayed_execution_config::EInvalidStuckThresholdMs)]
fun stuck_threshold_below_min_aborts() {
    // 49 also falls short of the 50 ms tick; the single-value bound fires first.
    let mut timing = default_timing();
    timing.pyth_channel = CHANNEL_FIXED_RATE_50MS;
    timing.stuck_threshold_ms = MIN_STUCK_THRESHOLD_MS - 1;
    set_timing_on_new_desk(timing);
}

#[test, expected_failure(abort_code = delayed_execution_config::EInvalidStuckThresholdMs)]
fun stuck_threshold_above_max_aborts() {
    let mut timing = default_timing();
    timing.stuck_threshold_ms = MAX_STUCK_THRESHOLD_MS + 1;
    set_timing_on_new_desk(timing);
}

#[test, expected_failure(abort_code = delayed_execution_config::EInvalidGapWaitMs)]
fun gap_wait_below_min_aborts() {
    // The stuck threshold sits on its own floor, so only the gap wait is out of bounds.
    let mut timing = default_timing();
    timing.pyth_channel = CHANNEL_FIXED_RATE_50MS;
    timing.stuck_threshold_ms = MIN_STUCK_THRESHOLD_MS;
    timing.gap_wait_ms = MIN_GAP_WAIT_MS - 1;
    set_timing_on_new_desk(timing);
}

#[test, expected_failure(abort_code = delayed_execution_config::EInvalidGapWaitMs)]
fun gap_wait_above_max_aborts() {
    let mut timing = default_timing();
    timing.gap_wait_ms = MAX_GAP_WAIT_MS + 1;
    set_timing_on_new_desk(timing);
}

// === Timing: Pyth price buffer and channel ===

#[test]
fun buffer_accepts_zero_and_one_tick_on_each_channel() {
    let (mut fx, mut desk, config) = new_desk();
    let mut timing = default_timing();
    timing.pyth_channel = CHANNEL_FIXED_RATE_50MS;
    timing.pyth_price_buffer_ms = TICK_50MS;
    assert_timing_accepted(&mut fx, &mut desk, &config, timing);

    // One 200 ms tick is also the single-value ceiling.
    timing.pyth_channel = CHANNEL_FIXED_RATE_200MS;
    timing.pyth_price_buffer_ms = MAX_PYTH_PRICE_BUFFER_MS;
    assert_timing_accepted(&mut fx, &mut desk, &config, timing);

    timing.pyth_price_buffer_ms = 0;
    assert_timing_accepted(&mut fx, &mut desk, &config, timing);
    finish(fx, desk, config);
}

#[test, expected_failure(abort_code = delayed_execution_config::EInvalidPythPriceBufferMs)]
fun buffer_above_max_aborts() {
    let mut timing = default_timing();
    timing.pyth_price_buffer_ms = MAX_PYTH_PRICE_BUFFER_MS + 1;
    set_timing_on_new_desk(timing);
}

#[test, expected_failure(abort_code = delayed_execution_config::EUnsupportedPythChannel)]
fun real_time_channel_aborts() {
    let mut timing = default_timing();
    timing.pyth_channel = CHANNEL_REAL_TIME;
    set_timing_on_new_desk(timing);
}

#[test, expected_failure(abort_code = delayed_execution_config::EUnsupportedPythChannel)]
fun unknown_channel_aborts() {
    let mut timing = default_timing();
    timing.pyth_channel = CHANNEL_UNKNOWN;
    set_timing_on_new_desk(timing);
}

// === Timing: SVI max age ===

#[test]
fun svi_max_age_accepts_min_and_max() {
    let (mut fx, mut desk, config) = new_desk();
    let mut timing = default_timing();
    timing.svi_max_age_ms = MIN_SVI_MAX_AGE_MS;
    assert_timing_accepted(&mut fx, &mut desk, &config, timing);
    // Predict's admission cap.
    timing.svi_max_age_ms = MAX_SVI_MAX_AGE_MS;
    assert_eq!(MAX_SVI_MAX_AGE_MS, constants::max_svi_max_age_ms!());
    assert_timing_accepted(&mut fx, &mut desk, &config, timing);
    finish(fx, desk, config);
}

#[test, expected_failure(abort_code = delayed_execution_config::EInvalidSviMaxAgeMs)]
fun svi_max_age_zero_aborts() {
    let mut timing = default_timing();
    timing.svi_max_age_ms = MIN_SVI_MAX_AGE_MS - 1;
    set_timing_on_new_desk(timing);
}

#[test, expected_failure(abort_code = delayed_execution_config::EInvalidSviMaxAgeMs)]
fun svi_max_age_above_max_aborts() {
    let mut timing = default_timing();
    timing.svi_max_age_ms = MAX_SVI_MAX_AGE_MS + 1;
    set_timing_on_new_desk(timing);
}

// === Timing: relational order ===

#[test]
fun timing_order_boundaries_accepted() {
    let (mut fx, mut desk, config) = new_desk();
    // stuck == gap is allowed (<=).
    let mut timing = default_timing();
    timing.stuck_threshold_ms = DEFAULT_GAP_WAIT_MS;
    assert_timing_accepted(&mut fx, &mut desk, &config, timing);

    // A stuck threshold of exactly one 200 ms tick, with buffer 0 below it.
    timing.stuck_threshold_ms = TICK_200MS;
    assert_timing_accepted(&mut fx, &mut desk, &config, timing);

    // buffer one 50 ms tick, stuck one unit above it.
    timing.pyth_channel = CHANNEL_FIXED_RATE_50MS;
    timing.pyth_price_buffer_ms = TICK_50MS;
    timing.stuck_threshold_ms = TICK_50MS + 1;
    assert_timing_accepted(&mut fx, &mut desk, &config, timing);
    finish(fx, desk, config);
}

#[test, expected_failure(abort_code = delayed_execution_config::EInvalidTiming)]
fun buffer_equal_to_stuck_aborts() {
    // 50 is one tick and the stuck floor, but buffer < stuck fails.
    let mut timing = default_timing();
    timing.pyth_channel = CHANNEL_FIXED_RATE_50MS;
    timing.pyth_price_buffer_ms = TICK_50MS;
    timing.stuck_threshold_ms = TICK_50MS;
    set_timing_on_new_desk(timing);
}

#[test, expected_failure(abort_code = delayed_execution_config::EInvalidTiming)]
fun stuck_above_gap_aborts() {
    let mut timing = default_timing();
    timing.stuck_threshold_ms = DEFAULT_GAP_WAIT_MS + 1;
    set_timing_on_new_desk(timing);
}

#[test, expected_failure(abort_code = delayed_execution_config::EInvalidTiming)]
fun gap_equal_to_stall_aborts() {
    let mut timing = default_timing();
    timing.gap_wait_ms = DEFAULT_STALL_TIMEOUT_MS;
    set_timing_on_new_desk(timing);
}

#[test, expected_failure(abort_code = delayed_execution_config::EInvalidTiming)]
fun buffer_of_fast_tick_on_slow_channel_aborts() {
    // 50 ms is not a whole 200 ms tick.
    let mut timing = default_timing();
    timing.pyth_channel = CHANNEL_FIXED_RATE_200MS;
    timing.pyth_price_buffer_ms = TICK_50MS;
    set_timing_on_new_desk(timing);
}

#[test, expected_failure(abort_code = delayed_execution_config::EInvalidTiming)]
fun buffer_of_two_ticks_aborts() {
    // 100 ms is two 50 ms ticks; only 0 or exactly one tick is allowed.
    let mut timing = default_timing();
    timing.pyth_channel = CHANNEL_FIXED_RATE_50MS;
    timing.pyth_price_buffer_ms = 2 * TICK_50MS;
    set_timing_on_new_desk(timing);
}

#[test, expected_failure(abort_code = delayed_execution_config::EInvalidTiming)]
fun stuck_below_one_slow_tick_aborts() {
    // 199 clears the 50 ms floor and the order, but not one 200 ms tick.
    let mut timing = default_timing();
    timing.pyth_channel = CHANNEL_FIXED_RATE_200MS;
    timing.stuck_threshold_ms = TICK_200MS - 1;
    set_timing_on_new_desk(timing);
}

// === Limits: capacities and per-account cap ===

#[test]
fun capacities_accept_min_and_max() {
    let (mut fx, mut desk, config) = new_desk();
    let mut limits = default_limits();
    limits.mint_capacity = MIN_CAPACITY;
    limits.sell_capacity = MIN_CAPACITY;
    limits.per_account_cap = MIN_CAPACITY;
    assert_limits_accepted(&mut fx, &mut desk, &config, limits);

    limits.mint_capacity = MAX_CAPACITY;
    limits.sell_capacity = MAX_CAPACITY;
    limits.per_account_cap = MAX_CAPACITY;
    assert_limits_accepted(&mut fx, &mut desk, &config, limits);
    finish(fx, desk, config);
}

#[test, expected_failure(abort_code = delayed_execution_config::EInvalidMintCapacity)]
fun mint_capacity_zero_aborts() {
    let mut limits = default_limits();
    limits.mint_capacity = MIN_CAPACITY - 1;
    set_limits_on_new_desk(limits);
}

#[test, expected_failure(abort_code = delayed_execution_config::EInvalidMintCapacity)]
fun mint_capacity_above_max_aborts() {
    let mut limits = default_limits();
    limits.mint_capacity = MAX_CAPACITY + 1;
    set_limits_on_new_desk(limits);
}

#[test, expected_failure(abort_code = delayed_execution_config::EInvalidSellCapacity)]
fun sell_capacity_zero_aborts() {
    let mut limits = default_limits();
    limits.sell_capacity = MIN_CAPACITY - 1;
    set_limits_on_new_desk(limits);
}

#[test, expected_failure(abort_code = delayed_execution_config::EInvalidSellCapacity)]
fun sell_capacity_above_max_aborts() {
    let mut limits = default_limits();
    limits.sell_capacity = MAX_CAPACITY + 1;
    set_limits_on_new_desk(limits);
}

#[test, expected_failure(abort_code = delayed_execution_config::EInvalidPerAccountCap)]
fun per_account_cap_zero_aborts() {
    let mut limits = default_limits();
    limits.per_account_cap = MIN_CAPACITY - 1;
    set_limits_on_new_desk(limits);
}

#[test, expected_failure(abort_code = delayed_execution_config::EInvalidPerAccountCap)]
fun per_account_cap_above_max_aborts() {
    // Both capacities at their ceiling, so the single-value bound is what fails.
    let mut limits = default_limits();
    limits.mint_capacity = MAX_CAPACITY;
    limits.sell_capacity = MAX_CAPACITY;
    limits.per_account_cap = MAX_CAPACITY + 1;
    set_limits_on_new_desk(limits);
}

#[test]
fun per_account_cap_equal_to_smaller_capacity_accepted() {
    let (mut fx, mut desk, config) = new_desk();
    let mut limits = default_limits();
    limits.mint_capacity = SMALL_CAPACITY;
    limits.sell_capacity = LARGE_CAPACITY;
    limits.per_account_cap = SMALL_CAPACITY;
    assert_limits_accepted(&mut fx, &mut desk, &config, limits);

    limits.mint_capacity = LARGE_CAPACITY;
    limits.sell_capacity = SMALL_CAPACITY;
    assert_limits_accepted(&mut fx, &mut desk, &config, limits);
    finish(fx, desk, config);
}

#[test, expected_failure(abort_code = delayed_execution_config::EInvalidLimits)]
fun per_account_cap_above_mint_capacity_aborts() {
    let mut limits = default_limits();
    limits.mint_capacity = SMALL_CAPACITY;
    limits.sell_capacity = LARGE_CAPACITY;
    limits.per_account_cap = SMALL_CAPACITY + 1;
    set_limits_on_new_desk(limits);
}

#[test, expected_failure(abort_code = delayed_execution_config::EInvalidLimits)]
fun per_account_cap_above_sell_capacity_aborts() {
    let mut limits = default_limits();
    limits.mint_capacity = LARGE_CAPACITY;
    limits.sell_capacity = SMALL_CAPACITY;
    limits.per_account_cap = SMALL_CAPACITY + 1;
    set_limits_on_new_desk(limits);
}

// === Limits: minimum sell quantity ===

#[test]
fun min_sell_quantity_accepts_one_lot_and_max_order() {
    let (mut fx, mut desk, config) = new_desk();
    let mut limits = default_limits();
    limits.min_sell_quantity = lot();
    assert_limits_accepted(&mut fx, &mut desk, &config, limits);
    limits.min_sell_quantity = MAX_ORDER_QUANTITY_LOTS * lot();
    assert_limits_accepted(&mut fx, &mut desk, &config, limits);
    finish(fx, desk, config);
}

#[test, expected_failure(abort_code = delayed_execution_config::EInvalidMinSellQuantity)]
fun min_sell_quantity_zero_aborts() {
    let mut limits = default_limits();
    limits.min_sell_quantity = 0;
    set_limits_on_new_desk(limits);
}

#[test, expected_failure(abort_code = delayed_execution_config::EInvalidMinSellQuantity)]
fun min_sell_quantity_not_whole_lots_aborts() {
    // One and a half lots.
    let mut limits = default_limits();
    limits.min_sell_quantity = lot() + lot() / 2;
    set_limits_on_new_desk(limits);
}

#[test, expected_failure(abort_code = delayed_execution_config::EInvalidMinSellQuantity)]
fun min_sell_quantity_above_max_order_aborts() {
    // Whole lots, but one lot more than an order can hold.
    let mut limits = default_limits();
    limits.min_sell_quantity = (MAX_ORDER_QUANTITY_LOTS + 1) * lot();
    set_limits_on_new_desk(limits);
}

// === Limits: settlement batches ===

#[test]
fun settle_batches_accept_min_and_max() {
    let (mut fx, mut desk, config) = new_desk();
    let mut limits = default_limits();
    limits.settle_refund_batch = MIN_SETTLE_BATCH;
    limits.settle_payout_batch = MIN_SETTLE_BATCH;
    assert_limits_accepted(&mut fx, &mut desk, &config, limits);
    limits.settle_refund_batch = MAX_SETTLE_REFUND_BATCH;
    limits.settle_payout_batch = MAX_SETTLE_PAYOUT_BATCH;
    assert_limits_accepted(&mut fx, &mut desk, &config, limits);
    finish(fx, desk, config);
}

#[test, expected_failure(abort_code = delayed_execution_config::EInvalidSettleRefundBatch)]
fun settle_refund_batch_zero_aborts() {
    let mut limits = default_limits();
    limits.settle_refund_batch = MIN_SETTLE_BATCH - 1;
    set_limits_on_new_desk(limits);
}

#[test, expected_failure(abort_code = delayed_execution_config::EInvalidSettleRefundBatch)]
fun settle_refund_batch_above_max_aborts() {
    let mut limits = default_limits();
    limits.settle_refund_batch = MAX_SETTLE_REFUND_BATCH + 1;
    set_limits_on_new_desk(limits);
}

#[test, expected_failure(abort_code = delayed_execution_config::EInvalidSettlePayoutBatch)]
fun settle_payout_batch_zero_aborts() {
    let mut limits = default_limits();
    limits.settle_payout_batch = MIN_SETTLE_BATCH - 1;
    set_limits_on_new_desk(limits);
}

#[test, expected_failure(abort_code = delayed_execution_config::EInvalidSettlePayoutBatch)]
fun settle_payout_batch_above_max_aborts() {
    let mut limits = default_limits();
    limits.settle_payout_batch = MAX_SETTLE_PAYOUT_BATCH + 1;
    set_limits_on_new_desk(limits);
}

// === Order fee ===

#[test]
fun order_fee_accepts_zero_and_cap() {
    let (mut fx, mut desk, config) = new_desk();
    set_order_fee(&mut fx, &mut desk, &config, 0);
    assert_eq!(desk.policy().order_fee(), 0);
    set_order_fee(&mut fx, &mut desk, &config, MAX_ORDER_FEE);
    assert_eq!(desk.policy().order_fee(), MAX_ORDER_FEE);
    finish(fx, desk, config);
}

#[test, expected_failure(abort_code = delayed_execution_config::EInvalidOrderFee)]
fun order_fee_above_cap_aborts() {
    let (mut fx, mut desk, config) = new_desk();
    set_order_fee(&mut fx, &mut desk, &config, MAX_ORDER_FEE + 1);
    abort 999
}

// === Helpers ===

/// Predict's default fixture past the cutover with `OrderFlow` allowlisted, in
/// an admin transaction with the event clock.
fun allowlisted_fixture(): Fixture {
    let mut fx = helpers::setup_market_default();
    fx.cutover();
    fx.set_clock_for_testing(EVENT_TIMESTAMP_MS);
    let mut config = take_config(&mut fx);
    {
        let (admin_cap, clock, _) = fx.admin_parts();
        config.set_order_flow<OrderFlow>(admin_cap, true, clock);
    };
    return_shared(config);
    fx.scenario_mut().next_tx(test_constants::admin());
    fx
}

/// A desk at the launch policy, taken with the config in a fresh admin
/// transaction, so the events read later are the setters' own.
fun new_desk(): (Fixture, OrderDesk, ProtocolConfig) {
    let mut fx = allowlisted_fixture();
    desk::init_for_testing(fx.scenario_mut().ctx());
    fx.scenario_mut().next_tx(test_constants::admin());
    let desk = fx.scenario_mut().take_shared<OrderDesk>();
    let config = take_config(&mut fx);
    (fx, desk, config)
}

fun take_config(fx: &mut Fixture): ProtocolConfig {
    let config_id = fx.config_id();
    fx.scenario_mut().take_shared_by_id<ProtocolConfig>(config_id)
}

fun freeze_predict(fx: &mut Fixture, config: &mut ProtocolConfig) {
    let (admin_cap, _, _) = fx.admin_parts();
    config.set_frozen(admin_cap, true);
}

fun finish(fx: Fixture, desk: OrderDesk, config: ProtocolConfig) {
    return_shared(desk);
    return_shared(config);
    fx.finish();
}

/// One position lot, the smallest quantity a mint can buy and the spec's
/// default minimum sell.
fun lot(): u64 {
    constants::position_lot_size!()
}

fun default_timing(): Timing {
    Timing {
        delay_ms: DEFAULT_DELAY_MS,
        stall_timeout_ms: DEFAULT_STALL_TIMEOUT_MS,
        stuck_threshold_ms: DEFAULT_STUCK_THRESHOLD_MS,
        gap_wait_ms: DEFAULT_GAP_WAIT_MS,
        pyth_price_buffer_ms: DEFAULT_PYTH_PRICE_BUFFER_MS,
        pyth_channel: CHANNEL_FIXED_RATE_200MS,
        svi_max_age_ms: DEFAULT_SVI_MAX_AGE_MS,
    }
}

/// Valid on the 50 ms channel: buffer one tick, 50 < 1,000 <= 1,500 < 4,000.
fun custom_timing(): Timing {
    Timing {
        delay_ms: CUSTOM_DELAY_MS,
        stall_timeout_ms: CUSTOM_STALL_TIMEOUT_MS,
        stuck_threshold_ms: CUSTOM_STUCK_THRESHOLD_MS,
        gap_wait_ms: CUSTOM_GAP_WAIT_MS,
        pyth_price_buffer_ms: TICK_50MS,
        pyth_channel: CHANNEL_FIXED_RATE_50MS,
        svi_max_age_ms: CUSTOM_SVI_MAX_AGE_MS,
    }
}

fun default_limits(): Limits {
    Limits {
        mint_capacity: DEFAULT_MINT_CAPACITY,
        sell_capacity: DEFAULT_SELL_CAPACITY,
        per_account_cap: DEFAULT_PER_ACCOUNT_CAP,
        min_sell_quantity: lot(),
        settle_refund_batch: DEFAULT_SETTLE_REFUND_BATCH,
        settle_payout_batch: DEFAULT_SETTLE_PAYOUT_BATCH,
    }
}

fun custom_limits(): Limits {
    Limits {
        mint_capacity: CUSTOM_MINT_CAPACITY,
        sell_capacity: CUSTOM_SELL_CAPACITY,
        per_account_cap: CUSTOM_PER_ACCOUNT_CAP,
        min_sell_quantity: CUSTOM_MIN_SELL_LOTS * lot(),
        settle_refund_batch: CUSTOM_SETTLE_REFUND_BATCH,
        settle_payout_batch: CUSTOM_SETTLE_PAYOUT_BATCH,
    }
}

fun set_timing(fx: &mut Fixture, desk: &mut OrderDesk, config: &ProtocolConfig, timing: Timing) {
    let (admin_cap, clock, _) = fx.admin_parts();
    desk.set_timing(
        admin_cap,
        config,
        timing.delay_ms,
        timing.stall_timeout_ms,
        timing.stuck_threshold_ms,
        timing.gap_wait_ms,
        timing.pyth_price_buffer_ms,
        timing.pyth_channel,
        timing.svi_max_age_ms,
        clock,
    );
}

fun set_limits(fx: &mut Fixture, desk: &mut OrderDesk, config: &ProtocolConfig, limits: Limits) {
    let (admin_cap, clock, _) = fx.admin_parts();
    desk.set_limits(
        admin_cap,
        config,
        limits.mint_capacity,
        limits.sell_capacity,
        limits.per_account_cap,
        limits.min_sell_quantity,
        limits.settle_refund_batch,
        limits.settle_payout_batch,
        clock,
    );
}

fun set_order_fee(fx: &mut Fixture, desk: &mut OrderDesk, config: &ProtocolConfig, fee: u64) {
    let (admin_cap, clock, _) = fx.admin_parts();
    desk.set_order_fee(admin_cap, config, fee, clock);
}

/// Set `timing` on a new desk; the caller expects it to abort.
fun set_timing_on_new_desk(timing: Timing) {
    let (mut fx, mut desk, config) = new_desk();
    set_timing(&mut fx, &mut desk, &config, timing);
    abort 999
}

/// Set `limits` on a new desk; the caller expects it to abort.
fun set_limits_on_new_desk(limits: Limits) {
    let (mut fx, mut desk, config) = new_desk();
    set_limits(&mut fx, &mut desk, &config, limits);
    abort 999
}

/// Set `timing` on top of the default limits and fee, and check every field.
fun assert_timing_accepted(
    fx: &mut Fixture,
    desk: &mut OrderDesk,
    config: &ProtocolConfig,
    timing: Timing,
) {
    set_timing(fx, desk, config, timing);
    assert_policy(desk, timing, default_limits(), DEFAULT_ORDER_FEE);
}

/// Set `limits` on top of the default timing and fee, and check every field.
fun assert_limits_accepted(
    fx: &mut Fixture,
    desk: &mut OrderDesk,
    config: &ProtocolConfig,
    limits: Limits,
) {
    set_limits(fx, desk, config, limits);
    assert_policy(desk, default_timing(), limits, DEFAULT_ORDER_FEE);
}

/// Every stored field, read through its public getter.
fun assert_policy(desk: &OrderDesk, timing: Timing, limits: Limits, order_fee: u64) {
    let policy = desk.policy();
    assert_eq!(policy.delay_ms(), timing.delay_ms);
    assert_eq!(policy.stall_timeout_ms(), timing.stall_timeout_ms);
    assert_eq!(policy.stuck_threshold_ms(), timing.stuck_threshold_ms);
    assert_eq!(policy.gap_wait_ms(), timing.gap_wait_ms);
    assert_eq!(policy.pyth_price_buffer_ms(), timing.pyth_price_buffer_ms);
    assert_eq!(policy.pyth_channel(), timing.pyth_channel);
    assert_eq!(policy.svi_max_age_ms(), timing.svi_max_age_ms);
    assert_eq!(policy.mint_capacity(), limits.mint_capacity);
    assert_eq!(policy.sell_capacity(), limits.sell_capacity);
    assert_eq!(policy.per_account_cap(), limits.per_account_cap);
    assert_eq!(policy.order_fee(), order_fee);
    assert_eq!(policy.min_sell_quantity(), limits.min_sell_quantity);
    assert_eq!(policy.settle_refund_batch(), limits.settle_refund_batch);
    assert_eq!(policy.settle_payout_batch(), limits.settle_payout_batch);
}

/// The transaction emitted `event_count` policy events and the last one carries
/// the desk and the complete post-state, byte for byte in field order.
fun assert_last_policy_event(
    event_count: u64,
    desk_id: ID,
    timing: Timing,
    limits: Limits,
    order_fee: u64,
) {
    let events = event::events_by_type<queue_events::DelayedExecutionPolicyUpdated>();
    assert_eq!(events.length(), event_count);
    let expected = ExpectedPolicyUpdated {
        desk_id,
        policy: ExpectedPolicy {
            delay_ms: timing.delay_ms,
            stall_timeout_ms: timing.stall_timeout_ms,
            stuck_threshold_ms: timing.stuck_threshold_ms,
            gap_wait_ms: timing.gap_wait_ms,
            pyth_price_buffer_ms: timing.pyth_price_buffer_ms,
            pyth_channel: timing.pyth_channel,
            svi_max_age_ms: timing.svi_max_age_ms,
            mint_capacity: limits.mint_capacity,
            sell_capacity: limits.sell_capacity,
            per_account_cap: limits.per_account_cap,
            order_fee,
            min_sell_quantity: limits.min_sell_quantity,
            settle_refund_batch: limits.settle_refund_batch,
            settle_payout_batch: limits.settle_payout_batch,
        },
        onchain_timestamp_ms: EVENT_TIMESTAMP_MS,
    };
    assert_eq!(bcs::to_bytes(&events[event_count - 1]), bcs::to_bytes(&expected));
}
