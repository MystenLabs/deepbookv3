// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Delayed-execution policy admin flows on a real shared `ProtocolConfig`:
/// `init_delayed_execution_policy` and the timing, limits, and order-fee setters.
/// Defaults and bounds are the spec's literals (Contract spec, `DelayedExecutionPolicy`
/// row, and the 10-08 decided bounds), never read back from `config_constants`. Each
/// setter is checked for its gates, every single-value bound on both sides, the
/// relational timing order, the per-account cap against the smaller capacity, and
/// the complete post-state it stores and emits.
#[test_only]
module deepbook_predict::delayed_execution_policy_tests;

use deepbook_predict::{
    admin::{Self, AdminCap},
    config_constants,
    config_events,
    constants,
    protocol_config::{Self, ProtocolConfig},
    test_constants
};
use std::{bcs, unit_test::{assert_eq, destroy}};
use sui::{clock::{Self, Clock}, event, test_scenario::{Self as test, Scenario, return_shared}};

const EVENT_TIMESTAMP_MS: u64 = 1_750_000_000_000;
const ONE_EVENT: u64 = 1;
const TWO_EVENTS: u64 = 2;
const FOUR_EVENTS: u64 = 4;

// Spec defaults.
const DEFAULT_DELAY_MS: u64 = 1_000;
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

// Single-value bounds (decided 10-08, the plan's G5 floors, and the settle batch
// maxima sized to Sui's per-transaction object limit).
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
/// 2 children per refund × 450 = 900, leaving 100 of Sui's 1,000 per-transaction
/// dynamic-object loads for fixed overhead.
const MAX_SETTLE_REFUND_BATCH: u64 = 450;
/// 1 child per visited record × 900 = 900, the same 100 reserved.
const MAX_SETTLE_PAYOUT_BATCH: u64 = 900;
/// 2^32 - 1: the widest lot count the packed order id's 32-bit quantity field holds.
const MAX_ORDER_QUANTITY_LOTS: u64 = 4_294_967_295;

// Non-default values the happy paths write, all different from the defaults
// and from each other so a swapped getter or field shows.
const CUSTOM_DELAY_MS: u64 = 800;
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

/// Field-for-field mirror of `config_events::DelayedExecutionPolicyUpdated`.
public struct ExpectedDelayedExecutionPolicyUpdated has copy, drop {
    policy: ExpectedPolicy,
    onchain_timestamp_ms: u64,
}

// === Init ===

#[test]
fun policy_reads_none_before_init() {
    let (scenario, admin_cap, config_id, clock) = new_shared_config();
    let config = scenario.take_shared_by_id<ProtocolConfig>(config_id);

    assert!(config.delayed_execution_policy().is_none());

    finish(scenario, admin_cap, config, clock);
}

#[test]
fun init_writes_spec_defaults_and_emits_them() {
    let (scenario, admin_cap, config_id, clock) = new_shared_config();
    let mut config = scenario.take_shared_by_id<ProtocolConfig>(config_id);

    config.init_delayed_execution_policy(&admin_cap, &clock);

    assert_policy(&config, default_timing(), default_limits(), DEFAULT_ORDER_FEE);
    assert_last_policy_event(ONE_EVENT, default_timing(), default_limits(), DEFAULT_ORDER_FEE);

    finish(scenario, admin_cap, config, clock);
}

#[test, expected_failure(abort_code = protocol_config::EPolicyAlreadyInitialized)]
fun init_twice_aborts() {
    let (scenario, admin_cap, config_id, clock) = new_shared_config();
    let mut config = scenario.take_shared_by_id<ProtocolConfig>(config_id);
    config.init_delayed_execution_policy(&admin_cap, &clock);
    config.init_delayed_execution_policy(&admin_cap, &clock);
    abort 999
}

#[test, expected_failure(abort_code = protocol_config::EProtocolFrozen)]
fun init_while_frozen_aborts() {
    let (scenario, admin_cap, config_id, clock) = new_shared_config();
    let mut config = scenario.take_shared_by_id<ProtocolConfig>(config_id);
    config.set_frozen(&admin_cap, true);
    config.init_delayed_execution_policy(&admin_cap, &clock);
    abort 999
}

// === Setters before init ===

#[test, expected_failure(abort_code = protocol_config::EPolicyNotInitialized)]
fun set_timing_before_init_aborts() {
    let (scenario, admin_cap, config_id, clock) = new_shared_config();
    let mut config = scenario.take_shared_by_id<ProtocolConfig>(config_id);
    set_timing(&mut config, &admin_cap, default_timing(), &clock);
    abort 999
}

#[test, expected_failure(abort_code = protocol_config::EPolicyNotInitialized)]
fun set_limits_before_init_aborts() {
    let (scenario, admin_cap, config_id, clock) = new_shared_config();
    let mut config = scenario.take_shared_by_id<ProtocolConfig>(config_id);
    set_limits(&mut config, &admin_cap, default_limits(), &clock);
    abort 999
}

#[test, expected_failure(abort_code = protocol_config::EPolicyNotInitialized)]
fun set_order_fee_before_init_aborts() {
    let (scenario, admin_cap, config_id, clock) = new_shared_config();
    let mut config = scenario.take_shared_by_id<ProtocolConfig>(config_id);
    config.set_order_fee(&admin_cap, DEFAULT_ORDER_FEE, &clock);
    abort 999
}

// === Version and freeze gates ===

#[test, expected_failure(abort_code = protocol_config::EProtocolFrozen)]
fun set_timing_while_frozen_aborts() {
    let (scenario, admin_cap, config_id, clock) = new_shared_config();
    let mut config = initialized_config(&scenario, &admin_cap, config_id, &clock);
    config.set_frozen(&admin_cap, true);
    set_timing(&mut config, &admin_cap, default_timing(), &clock);
    abort 999
}

#[test, expected_failure(abort_code = protocol_config::EProtocolFrozen)]
fun set_limits_while_frozen_aborts() {
    let (scenario, admin_cap, config_id, clock) = new_shared_config();
    let mut config = initialized_config(&scenario, &admin_cap, config_id, &clock);
    config.set_frozen(&admin_cap, true);
    set_limits(&mut config, &admin_cap, default_limits(), &clock);
    abort 999
}

#[test, expected_failure(abort_code = protocol_config::EProtocolFrozen)]
fun set_order_fee_while_frozen_aborts() {
    let (scenario, admin_cap, config_id, clock) = new_shared_config();
    let mut config = initialized_config(&scenario, &admin_cap, config_id, &clock);
    config.set_frozen(&admin_cap, true);
    config.set_order_fee(&admin_cap, DEFAULT_ORDER_FEE, &clock);
    abort 999
}

#[test, expected_failure(abort_code = protocol_config::EPackageVersionDisabled)]
fun set_timing_below_version_floor_aborts() {
    let (scenario, admin_cap, config_id, clock) = new_shared_config();
    let mut config = initialized_config(&scenario, &admin_cap, config_id, &clock);
    // A later package raised the floor past this one.
    config.set_version_watermark_for_testing(constants::current_version!() + 1);
    set_timing(&mut config, &admin_cap, default_timing(), &clock);
    abort 999
}

/// None of the three setters is gated on an open LP valuation, so a stalled
/// flush cannot trap them. Pinned positively, since a uniform
/// `assert_not_valuation_in_progress` would leave every negative test green.
#[test]
fun setters_run_during_open_valuation() {
    let (scenario, admin_cap, config_id, clock) = new_shared_config();
    let mut config = initialized_config(&scenario, &admin_cap, config_id, &clock);
    config.begin_valuation();

    set_timing(&mut config, &admin_cap, custom_timing(), &clock);
    set_limits(&mut config, &admin_cap, custom_limits(), &clock);
    config.set_order_fee(&admin_cap, CUSTOM_ORDER_FEE, &clock);

    assert!(config.valuation_in_progress());
    assert_policy(&config, custom_timing(), custom_limits(), CUSTOM_ORDER_FEE);
    // init + three setters, the last carrying every custom value.
    assert_last_policy_event(FOUR_EVENTS, custom_timing(), custom_limits(), CUSTOM_ORDER_FEE);

    finish(scenario, admin_cap, config, clock);
}

// === Happy paths: each setter writes its fields, keeps the rest, emits it all ===

#[test]
fun set_timing_writes_timing_and_keeps_other_fields() {
    let (scenario, admin_cap, config_id, clock) = new_shared_config();
    let mut config = initialized_config(&scenario, &admin_cap, config_id, &clock);

    set_timing(&mut config, &admin_cap, custom_timing(), &clock);

    assert_policy(&config, custom_timing(), default_limits(), DEFAULT_ORDER_FEE);
    assert_last_policy_event(TWO_EVENTS, custom_timing(), default_limits(), DEFAULT_ORDER_FEE);

    finish(scenario, admin_cap, config, clock);
}

#[test]
fun set_limits_writes_limits_and_keeps_other_fields() {
    let (scenario, admin_cap, config_id, clock) = new_shared_config();
    let mut config = initialized_config(&scenario, &admin_cap, config_id, &clock);

    set_limits(&mut config, &admin_cap, custom_limits(), &clock);

    assert_policy(&config, default_timing(), custom_limits(), DEFAULT_ORDER_FEE);
    assert_last_policy_event(TWO_EVENTS, default_timing(), custom_limits(), DEFAULT_ORDER_FEE);

    finish(scenario, admin_cap, config, clock);
}

#[test]
fun set_order_fee_writes_fee_and_keeps_other_fields() {
    let (scenario, admin_cap, config_id, clock) = new_shared_config();
    let mut config = initialized_config(&scenario, &admin_cap, config_id, &clock);

    config.set_order_fee(&admin_cap, CUSTOM_ORDER_FEE, &clock);

    assert_policy(&config, default_timing(), default_limits(), CUSTOM_ORDER_FEE);
    assert_last_policy_event(TWO_EVENTS, default_timing(), default_limits(), CUSTOM_ORDER_FEE);

    finish(scenario, admin_cap, config, clock);
}

// === Timing: delay ===

#[test]
fun delay_accepts_zero_and_max() {
    let (scenario, admin_cap, config_id, clock) = new_shared_config();
    let mut config = initialized_config(&scenario, &admin_cap, config_id, &clock);

    // No floor: 0 prices on the tick at or before placement.
    let mut timing = default_timing();
    timing.delay_ms = 0;
    assert_timing_accepted(&mut config, &admin_cap, timing, &clock);
    timing.delay_ms = MAX_DELAY_MS;
    assert_timing_accepted(&mut config, &admin_cap, timing, &clock);

    finish(scenario, admin_cap, config, clock);
}

#[test, expected_failure(abort_code = config_constants::EInvalidDelayMs)]
fun delay_above_max_aborts() {
    let (scenario, admin_cap, config_id, clock) = new_shared_config();
    let mut config = initialized_config(&scenario, &admin_cap, config_id, &clock);
    let mut timing = default_timing();
    timing.delay_ms = MAX_DELAY_MS + 1;
    set_timing(&mut config, &admin_cap, timing, &clock);
    abort 999
}

// === Timing: stall timeout ===

#[test]
fun stall_timeout_accepts_min_and_max() {
    let (scenario, admin_cap, config_id, clock) = new_shared_config();
    let mut config = initialized_config(&scenario, &admin_cap, config_id, &clock);

    // At the 2,000 floor the gap wait must drop below it: 1,500 <= 1,999 < 2,000.
    let mut timing = default_timing();
    timing.stall_timeout_ms = MIN_STALL_TIMEOUT_MS;
    timing.gap_wait_ms = MIN_STALL_TIMEOUT_MS - 1;
    assert_timing_accepted(&mut config, &admin_cap, timing, &clock);
    timing.stall_timeout_ms = MAX_STALL_TIMEOUT_MS;
    assert_timing_accepted(&mut config, &admin_cap, timing, &clock);

    finish(scenario, admin_cap, config, clock);
}

#[test, expected_failure(abort_code = config_constants::EInvalidStallTimeoutMs)]
fun stall_timeout_below_min_aborts() {
    let (scenario, admin_cap, config_id, clock) = new_shared_config();
    let mut config = initialized_config(&scenario, &admin_cap, config_id, &clock);
    // The order still holds (1,500 <= 1,998 < 1,999), so only the bound fails.
    let mut timing = default_timing();
    timing.stall_timeout_ms = MIN_STALL_TIMEOUT_MS - 1;
    timing.gap_wait_ms = MIN_STALL_TIMEOUT_MS - 2;
    set_timing(&mut config, &admin_cap, timing, &clock);
    abort 999
}

#[test, expected_failure(abort_code = config_constants::EInvalidStallTimeoutMs)]
fun stall_timeout_above_max_aborts() {
    let (scenario, admin_cap, config_id, clock) = new_shared_config();
    let mut config = initialized_config(&scenario, &admin_cap, config_id, &clock);
    let mut timing = default_timing();
    timing.stall_timeout_ms = MAX_STALL_TIMEOUT_MS + 1;
    set_timing(&mut config, &admin_cap, timing, &clock);
    abort 999
}

// === Timing: stuck threshold and gap wait ===

/// The floors are one 50 ms tick, reachable together on the 50 ms channel. The
/// single-value ceilings of 10,000 can never satisfy `gap < stall <= 10,000`,
/// so the widest valid stuck threshold and gap wait are 9,999.
#[test]
fun stuck_and_gap_accept_one_fast_tick_and_widest_order() {
    let (scenario, admin_cap, config_id, clock) = new_shared_config();
    let mut config = initialized_config(&scenario, &admin_cap, config_id, &clock);

    let mut timing = default_timing();
    timing.pyth_channel = CHANNEL_FIXED_RATE_50MS;
    timing.stuck_threshold_ms = MIN_STUCK_THRESHOLD_MS;
    timing.gap_wait_ms = MIN_GAP_WAIT_MS;
    assert_timing_accepted(&mut config, &admin_cap, timing, &clock);

    timing.stuck_threshold_ms = MAX_STALL_TIMEOUT_MS - 1;
    timing.gap_wait_ms = MAX_STALL_TIMEOUT_MS - 1;
    timing.stall_timeout_ms = MAX_STALL_TIMEOUT_MS;
    assert_timing_accepted(&mut config, &admin_cap, timing, &clock);

    finish(scenario, admin_cap, config, clock);
}

#[test, expected_failure(abort_code = config_constants::EInvalidStuckThresholdMs)]
fun stuck_threshold_below_min_aborts() {
    let (scenario, admin_cap, config_id, clock) = new_shared_config();
    let mut config = initialized_config(&scenario, &admin_cap, config_id, &clock);
    // 49 also falls short of the 50 ms tick; the single-value bound fires first.
    let mut timing = default_timing();
    timing.pyth_channel = CHANNEL_FIXED_RATE_50MS;
    timing.stuck_threshold_ms = MIN_STUCK_THRESHOLD_MS - 1;
    set_timing(&mut config, &admin_cap, timing, &clock);
    abort 999
}

#[test, expected_failure(abort_code = config_constants::EInvalidStuckThresholdMs)]
fun stuck_threshold_above_max_aborts() {
    let (scenario, admin_cap, config_id, clock) = new_shared_config();
    let mut config = initialized_config(&scenario, &admin_cap, config_id, &clock);
    let mut timing = default_timing();
    timing.stuck_threshold_ms = MAX_STUCK_THRESHOLD_MS + 1;
    set_timing(&mut config, &admin_cap, timing, &clock);
    abort 999
}

#[test, expected_failure(abort_code = config_constants::EInvalidGapWaitMs)]
fun gap_wait_below_min_aborts() {
    let (scenario, admin_cap, config_id, clock) = new_shared_config();
    let mut config = initialized_config(&scenario, &admin_cap, config_id, &clock);
    // The stuck threshold sits on its own floor, so only the gap wait is out of bounds.
    let mut timing = default_timing();
    timing.pyth_channel = CHANNEL_FIXED_RATE_50MS;
    timing.stuck_threshold_ms = MIN_STUCK_THRESHOLD_MS;
    timing.gap_wait_ms = MIN_GAP_WAIT_MS - 1;
    set_timing(&mut config, &admin_cap, timing, &clock);
    abort 999
}

#[test, expected_failure(abort_code = config_constants::EInvalidGapWaitMs)]
fun gap_wait_above_max_aborts() {
    let (scenario, admin_cap, config_id, clock) = new_shared_config();
    let mut config = initialized_config(&scenario, &admin_cap, config_id, &clock);
    let mut timing = default_timing();
    timing.gap_wait_ms = MAX_GAP_WAIT_MS + 1;
    set_timing(&mut config, &admin_cap, timing, &clock);
    abort 999
}

// === Timing: Pyth price buffer and channel ===

#[test]
fun buffer_accepts_zero_and_one_tick_on_each_channel() {
    let (scenario, admin_cap, config_id, clock) = new_shared_config();
    let mut config = initialized_config(&scenario, &admin_cap, config_id, &clock);

    let mut timing = default_timing();
    timing.pyth_channel = CHANNEL_FIXED_RATE_50MS;
    timing.pyth_price_buffer_ms = TICK_50MS;
    assert_timing_accepted(&mut config, &admin_cap, timing, &clock);

    // One 200 ms tick is also the single-value ceiling.
    timing.pyth_channel = CHANNEL_FIXED_RATE_200MS;
    timing.pyth_price_buffer_ms = MAX_PYTH_PRICE_BUFFER_MS;
    assert_timing_accepted(&mut config, &admin_cap, timing, &clock);

    timing.pyth_price_buffer_ms = 0;
    assert_timing_accepted(&mut config, &admin_cap, timing, &clock);

    finish(scenario, admin_cap, config, clock);
}

#[test, expected_failure(abort_code = config_constants::EInvalidPythPriceBufferMs)]
fun buffer_above_max_aborts() {
    let (scenario, admin_cap, config_id, clock) = new_shared_config();
    let mut config = initialized_config(&scenario, &admin_cap, config_id, &clock);
    let mut timing = default_timing();
    timing.pyth_price_buffer_ms = MAX_PYTH_PRICE_BUFFER_MS + 1;
    set_timing(&mut config, &admin_cap, timing, &clock);
    abort 999
}

#[test, expected_failure(abort_code = protocol_config::EUnsupportedPythChannel)]
fun real_time_channel_aborts() {
    let (scenario, admin_cap, config_id, clock) = new_shared_config();
    let mut config = initialized_config(&scenario, &admin_cap, config_id, &clock);
    let mut timing = default_timing();
    timing.pyth_channel = CHANNEL_REAL_TIME;
    set_timing(&mut config, &admin_cap, timing, &clock);
    abort 999
}

#[test, expected_failure(abort_code = protocol_config::EUnsupportedPythChannel)]
fun unknown_channel_aborts() {
    let (scenario, admin_cap, config_id, clock) = new_shared_config();
    let mut config = initialized_config(&scenario, &admin_cap, config_id, &clock);
    let mut timing = default_timing();
    timing.pyth_channel = CHANNEL_UNKNOWN;
    set_timing(&mut config, &admin_cap, timing, &clock);
    abort 999
}

// === Timing: SVI max age ===

#[test]
fun svi_max_age_accepts_min_and_max() {
    let (scenario, admin_cap, config_id, clock) = new_shared_config();
    let mut config = initialized_config(&scenario, &admin_cap, config_id, &clock);

    let mut timing = default_timing();
    timing.svi_max_age_ms = MIN_SVI_MAX_AGE_MS;
    assert_timing_accepted(&mut config, &admin_cap, timing, &clock);
    timing.svi_max_age_ms = MAX_SVI_MAX_AGE_MS;
    assert_timing_accepted(&mut config, &admin_cap, timing, &clock);

    finish(scenario, admin_cap, config, clock);
}

#[test, expected_failure(abort_code = config_constants::EInvalidSviMaxAgeMs)]
fun svi_max_age_zero_aborts() {
    let (scenario, admin_cap, config_id, clock) = new_shared_config();
    let mut config = initialized_config(&scenario, &admin_cap, config_id, &clock);
    let mut timing = default_timing();
    timing.svi_max_age_ms = MIN_SVI_MAX_AGE_MS - 1;
    set_timing(&mut config, &admin_cap, timing, &clock);
    abort 999
}

#[test, expected_failure(abort_code = config_constants::EInvalidSviMaxAgeMs)]
fun svi_max_age_above_max_aborts() {
    let (scenario, admin_cap, config_id, clock) = new_shared_config();
    let mut config = initialized_config(&scenario, &admin_cap, config_id, &clock);
    let mut timing = default_timing();
    timing.svi_max_age_ms = MAX_SVI_MAX_AGE_MS + 1;
    set_timing(&mut config, &admin_cap, timing, &clock);
    abort 999
}

// === Timing: relational order ===

#[test]
fun timing_order_boundaries_accepted() {
    let (scenario, admin_cap, config_id, clock) = new_shared_config();
    let mut config = initialized_config(&scenario, &admin_cap, config_id, &clock);

    // stuck == gap is allowed (<=).
    let mut timing = default_timing();
    timing.stuck_threshold_ms = DEFAULT_GAP_WAIT_MS;
    assert_timing_accepted(&mut config, &admin_cap, timing, &clock);

    // A stuck threshold of exactly one 200 ms tick, with buffer 0 below it.
    timing.stuck_threshold_ms = TICK_200MS;
    assert_timing_accepted(&mut config, &admin_cap, timing, &clock);

    // buffer one 50 ms tick, stuck one unit above it.
    timing.pyth_channel = CHANNEL_FIXED_RATE_50MS;
    timing.pyth_price_buffer_ms = TICK_50MS;
    timing.stuck_threshold_ms = TICK_50MS + 1;
    assert_timing_accepted(&mut config, &admin_cap, timing, &clock);

    finish(scenario, admin_cap, config, clock);
}

#[test, expected_failure(abort_code = protocol_config::EInvalidDelayedExecutionTiming)]
fun buffer_equal_to_stuck_aborts() {
    let (scenario, admin_cap, config_id, clock) = new_shared_config();
    let mut config = initialized_config(&scenario, &admin_cap, config_id, &clock);
    // 50 is one tick and the stuck floor, but buffer < stuck fails.
    let mut timing = default_timing();
    timing.pyth_channel = CHANNEL_FIXED_RATE_50MS;
    timing.pyth_price_buffer_ms = TICK_50MS;
    timing.stuck_threshold_ms = TICK_50MS;
    set_timing(&mut config, &admin_cap, timing, &clock);
    abort 999
}

#[test, expected_failure(abort_code = protocol_config::EInvalidDelayedExecutionTiming)]
fun stuck_above_gap_aborts() {
    let (scenario, admin_cap, config_id, clock) = new_shared_config();
    let mut config = initialized_config(&scenario, &admin_cap, config_id, &clock);
    let mut timing = default_timing();
    timing.stuck_threshold_ms = DEFAULT_GAP_WAIT_MS + 1;
    set_timing(&mut config, &admin_cap, timing, &clock);
    abort 999
}

#[test, expected_failure(abort_code = protocol_config::EInvalidDelayedExecutionTiming)]
fun gap_equal_to_stall_aborts() {
    let (scenario, admin_cap, config_id, clock) = new_shared_config();
    let mut config = initialized_config(&scenario, &admin_cap, config_id, &clock);
    let mut timing = default_timing();
    timing.gap_wait_ms = DEFAULT_STALL_TIMEOUT_MS;
    set_timing(&mut config, &admin_cap, timing, &clock);
    abort 999
}

#[test, expected_failure(abort_code = protocol_config::EInvalidDelayedExecutionTiming)]
fun buffer_of_fast_tick_on_slow_channel_aborts() {
    let (scenario, admin_cap, config_id, clock) = new_shared_config();
    let mut config = initialized_config(&scenario, &admin_cap, config_id, &clock);
    // 50 ms is not a whole 200 ms tick.
    let mut timing = default_timing();
    timing.pyth_channel = CHANNEL_FIXED_RATE_200MS;
    timing.pyth_price_buffer_ms = TICK_50MS;
    set_timing(&mut config, &admin_cap, timing, &clock);
    abort 999
}

#[test, expected_failure(abort_code = protocol_config::EInvalidDelayedExecutionTiming)]
fun buffer_of_two_ticks_aborts() {
    let (scenario, admin_cap, config_id, clock) = new_shared_config();
    let mut config = initialized_config(&scenario, &admin_cap, config_id, &clock);
    // 100 ms is two 50 ms ticks; only 0 or exactly one tick is allowed.
    let mut timing = default_timing();
    timing.pyth_channel = CHANNEL_FIXED_RATE_50MS;
    timing.pyth_price_buffer_ms = 2 * TICK_50MS;
    set_timing(&mut config, &admin_cap, timing, &clock);
    abort 999
}

#[test, expected_failure(abort_code = protocol_config::EInvalidDelayedExecutionTiming)]
fun stuck_below_one_slow_tick_aborts() {
    let (scenario, admin_cap, config_id, clock) = new_shared_config();
    let mut config = initialized_config(&scenario, &admin_cap, config_id, &clock);
    // 199 clears the 50 ms floor and the order, but not one 200 ms tick.
    let mut timing = default_timing();
    timing.pyth_channel = CHANNEL_FIXED_RATE_200MS;
    timing.stuck_threshold_ms = TICK_200MS - 1;
    set_timing(&mut config, &admin_cap, timing, &clock);
    abort 999
}

// === Limits: capacities and per-account cap ===

#[test]
fun capacities_accept_min_and_max() {
    let (scenario, admin_cap, config_id, clock) = new_shared_config();
    let mut config = initialized_config(&scenario, &admin_cap, config_id, &clock);

    let mut limits = default_limits();
    limits.mint_capacity = MIN_CAPACITY;
    limits.sell_capacity = MIN_CAPACITY;
    limits.per_account_cap = MIN_CAPACITY;
    assert_limits_accepted(&mut config, &admin_cap, limits, &clock);

    limits.mint_capacity = MAX_CAPACITY;
    limits.sell_capacity = MAX_CAPACITY;
    limits.per_account_cap = MAX_CAPACITY;
    assert_limits_accepted(&mut config, &admin_cap, limits, &clock);

    finish(scenario, admin_cap, config, clock);
}

#[test, expected_failure(abort_code = config_constants::EInvalidMintCapacity)]
fun mint_capacity_zero_aborts() {
    let (scenario, admin_cap, config_id, clock) = new_shared_config();
    let mut config = initialized_config(&scenario, &admin_cap, config_id, &clock);
    let mut limits = default_limits();
    limits.mint_capacity = MIN_CAPACITY - 1;
    set_limits(&mut config, &admin_cap, limits, &clock);
    abort 999
}

#[test, expected_failure(abort_code = config_constants::EInvalidMintCapacity)]
fun mint_capacity_above_max_aborts() {
    let (scenario, admin_cap, config_id, clock) = new_shared_config();
    let mut config = initialized_config(&scenario, &admin_cap, config_id, &clock);
    let mut limits = default_limits();
    limits.mint_capacity = MAX_CAPACITY + 1;
    set_limits(&mut config, &admin_cap, limits, &clock);
    abort 999
}

#[test, expected_failure(abort_code = config_constants::EInvalidSellCapacity)]
fun sell_capacity_zero_aborts() {
    let (scenario, admin_cap, config_id, clock) = new_shared_config();
    let mut config = initialized_config(&scenario, &admin_cap, config_id, &clock);
    let mut limits = default_limits();
    limits.sell_capacity = MIN_CAPACITY - 1;
    set_limits(&mut config, &admin_cap, limits, &clock);
    abort 999
}

#[test, expected_failure(abort_code = config_constants::EInvalidSellCapacity)]
fun sell_capacity_above_max_aborts() {
    let (scenario, admin_cap, config_id, clock) = new_shared_config();
    let mut config = initialized_config(&scenario, &admin_cap, config_id, &clock);
    let mut limits = default_limits();
    limits.sell_capacity = MAX_CAPACITY + 1;
    set_limits(&mut config, &admin_cap, limits, &clock);
    abort 999
}

#[test, expected_failure(abort_code = config_constants::EInvalidPerAccountCap)]
fun per_account_cap_zero_aborts() {
    let (scenario, admin_cap, config_id, clock) = new_shared_config();
    let mut config = initialized_config(&scenario, &admin_cap, config_id, &clock);
    let mut limits = default_limits();
    limits.per_account_cap = MIN_CAPACITY - 1;
    set_limits(&mut config, &admin_cap, limits, &clock);
    abort 999
}

#[test, expected_failure(abort_code = config_constants::EInvalidPerAccountCap)]
fun per_account_cap_above_max_aborts() {
    let (scenario, admin_cap, config_id, clock) = new_shared_config();
    let mut config = initialized_config(&scenario, &admin_cap, config_id, &clock);
    // Both capacities at their ceiling, so the single-value bound is what fails.
    let mut limits = default_limits();
    limits.mint_capacity = MAX_CAPACITY;
    limits.sell_capacity = MAX_CAPACITY;
    limits.per_account_cap = MAX_CAPACITY + 1;
    set_limits(&mut config, &admin_cap, limits, &clock);
    abort 999
}

#[test]
fun per_account_cap_equal_to_smaller_capacity_accepted() {
    let (scenario, admin_cap, config_id, clock) = new_shared_config();
    let mut config = initialized_config(&scenario, &admin_cap, config_id, &clock);

    let mut limits = default_limits();
    limits.mint_capacity = SMALL_CAPACITY;
    limits.sell_capacity = LARGE_CAPACITY;
    limits.per_account_cap = SMALL_CAPACITY;
    assert_limits_accepted(&mut config, &admin_cap, limits, &clock);

    limits.mint_capacity = LARGE_CAPACITY;
    limits.sell_capacity = SMALL_CAPACITY;
    assert_limits_accepted(&mut config, &admin_cap, limits, &clock);

    finish(scenario, admin_cap, config, clock);
}

#[test, expected_failure(abort_code = protocol_config::EInvalidDelayedExecutionLimits)]
fun per_account_cap_above_mint_capacity_aborts() {
    let (scenario, admin_cap, config_id, clock) = new_shared_config();
    let mut config = initialized_config(&scenario, &admin_cap, config_id, &clock);
    let mut limits = default_limits();
    limits.mint_capacity = SMALL_CAPACITY;
    limits.sell_capacity = LARGE_CAPACITY;
    limits.per_account_cap = SMALL_CAPACITY + 1;
    set_limits(&mut config, &admin_cap, limits, &clock);
    abort 999
}

#[test, expected_failure(abort_code = protocol_config::EInvalidDelayedExecutionLimits)]
fun per_account_cap_above_sell_capacity_aborts() {
    let (scenario, admin_cap, config_id, clock) = new_shared_config();
    let mut config = initialized_config(&scenario, &admin_cap, config_id, &clock);
    let mut limits = default_limits();
    limits.mint_capacity = LARGE_CAPACITY;
    limits.sell_capacity = SMALL_CAPACITY;
    limits.per_account_cap = SMALL_CAPACITY + 1;
    set_limits(&mut config, &admin_cap, limits, &clock);
    abort 999
}

// === Limits: minimum sell quantity ===

#[test]
fun min_sell_quantity_accepts_one_lot_and_max_order() {
    let (scenario, admin_cap, config_id, clock) = new_shared_config();
    let mut config = initialized_config(&scenario, &admin_cap, config_id, &clock);

    let mut limits = default_limits();
    limits.min_sell_quantity = lot();
    assert_limits_accepted(&mut config, &admin_cap, limits, &clock);
    limits.min_sell_quantity = MAX_ORDER_QUANTITY_LOTS * lot();
    assert_limits_accepted(&mut config, &admin_cap, limits, &clock);

    finish(scenario, admin_cap, config, clock);
}

#[test, expected_failure(abort_code = config_constants::EInvalidMinSellQuantity)]
fun min_sell_quantity_zero_aborts() {
    let (scenario, admin_cap, config_id, clock) = new_shared_config();
    let mut config = initialized_config(&scenario, &admin_cap, config_id, &clock);
    let mut limits = default_limits();
    limits.min_sell_quantity = 0;
    set_limits(&mut config, &admin_cap, limits, &clock);
    abort 999
}

#[test, expected_failure(abort_code = config_constants::EInvalidMinSellQuantity)]
fun min_sell_quantity_not_whole_lots_aborts() {
    let (scenario, admin_cap, config_id, clock) = new_shared_config();
    let mut config = initialized_config(&scenario, &admin_cap, config_id, &clock);
    // One and a half lots.
    let mut limits = default_limits();
    limits.min_sell_quantity = lot() + lot() / 2;
    set_limits(&mut config, &admin_cap, limits, &clock);
    abort 999
}

#[test, expected_failure(abort_code = config_constants::EInvalidMinSellQuantity)]
fun min_sell_quantity_above_max_order_aborts() {
    let (scenario, admin_cap, config_id, clock) = new_shared_config();
    let mut config = initialized_config(&scenario, &admin_cap, config_id, &clock);
    // Whole lots, but one lot more than an order can hold.
    let mut limits = default_limits();
    limits.min_sell_quantity = (MAX_ORDER_QUANTITY_LOTS + 1) * lot();
    set_limits(&mut config, &admin_cap, limits, &clock);
    abort 999
}

// === Limits: settlement batches ===

#[test]
fun settle_batches_accept_min_and_max() {
    let (scenario, admin_cap, config_id, clock) = new_shared_config();
    let mut config = initialized_config(&scenario, &admin_cap, config_id, &clock);

    let mut limits = default_limits();
    limits.settle_refund_batch = MIN_SETTLE_BATCH;
    limits.settle_payout_batch = MIN_SETTLE_BATCH;
    assert_limits_accepted(&mut config, &admin_cap, limits, &clock);
    limits.settle_refund_batch = MAX_SETTLE_REFUND_BATCH;
    limits.settle_payout_batch = MAX_SETTLE_PAYOUT_BATCH;
    assert_limits_accepted(&mut config, &admin_cap, limits, &clock);

    finish(scenario, admin_cap, config, clock);
}

#[test, expected_failure(abort_code = config_constants::EInvalidSettleRefundBatch)]
fun settle_refund_batch_zero_aborts() {
    let (scenario, admin_cap, config_id, clock) = new_shared_config();
    let mut config = initialized_config(&scenario, &admin_cap, config_id, &clock);
    let mut limits = default_limits();
    limits.settle_refund_batch = MIN_SETTLE_BATCH - 1;
    set_limits(&mut config, &admin_cap, limits, &clock);
    abort 999
}

#[test, expected_failure(abort_code = config_constants::EInvalidSettleRefundBatch)]
fun settle_refund_batch_above_max_aborts() {
    let (scenario, admin_cap, config_id, clock) = new_shared_config();
    let mut config = initialized_config(&scenario, &admin_cap, config_id, &clock);
    let mut limits = default_limits();
    limits.settle_refund_batch = MAX_SETTLE_REFUND_BATCH + 1;
    set_limits(&mut config, &admin_cap, limits, &clock);
    abort 999
}

#[test, expected_failure(abort_code = config_constants::EInvalidSettlePayoutBatch)]
fun settle_payout_batch_zero_aborts() {
    let (scenario, admin_cap, config_id, clock) = new_shared_config();
    let mut config = initialized_config(&scenario, &admin_cap, config_id, &clock);
    let mut limits = default_limits();
    limits.settle_payout_batch = MIN_SETTLE_BATCH - 1;
    set_limits(&mut config, &admin_cap, limits, &clock);
    abort 999
}

#[test, expected_failure(abort_code = config_constants::EInvalidSettlePayoutBatch)]
fun settle_payout_batch_above_max_aborts() {
    let (scenario, admin_cap, config_id, clock) = new_shared_config();
    let mut config = initialized_config(&scenario, &admin_cap, config_id, &clock);
    let mut limits = default_limits();
    limits.settle_payout_batch = MAX_SETTLE_PAYOUT_BATCH + 1;
    set_limits(&mut config, &admin_cap, limits, &clock);
    abort 999
}

// === Order fee ===

#[test]
fun order_fee_accepts_zero_and_cap() {
    let (scenario, admin_cap, config_id, clock) = new_shared_config();
    let mut config = initialized_config(&scenario, &admin_cap, config_id, &clock);

    config.set_order_fee(&admin_cap, 0, &clock);
    assert_eq!(config.delayed_execution_policy().destroy_some().order_fee(), 0);
    config.set_order_fee(&admin_cap, MAX_ORDER_FEE, &clock);
    assert_eq!(config.delayed_execution_policy().destroy_some().order_fee(), MAX_ORDER_FEE);

    finish(scenario, admin_cap, config, clock);
}

#[test, expected_failure(abort_code = config_constants::EInvalidOrderFee)]
fun order_fee_above_cap_aborts() {
    let (scenario, admin_cap, config_id, clock) = new_shared_config();
    let mut config = initialized_config(&scenario, &admin_cap, config_id, &clock);
    config.set_order_fee(&admin_cap, MAX_ORDER_FEE + 1, &clock);
    abort 999
}

// === Helpers ===

/// A real shared `ProtocolConfig` at genesis (watermark at `current_version!()`,
/// not frozen, no policy) and an `AdminCap`, ready in the next transaction.
fun new_shared_config(): (Scenario, AdminCap, ID, Clock) {
    let mut scenario = test::begin(test_constants::admin());
    let config_id = protocol_config::create_and_share(scenario.ctx());
    let admin_cap = admin::new(scenario.ctx());
    let mut clock = clock::create_for_testing(scenario.ctx());
    clock.set_for_testing(EVENT_TIMESTAMP_MS);
    scenario.next_tx(test_constants::admin());
    (scenario, admin_cap, config_id, clock)
}

/// Take the shared config and initialize its policy.
fun initialized_config(
    scenario: &Scenario,
    admin_cap: &AdminCap,
    config_id: ID,
    clock: &Clock,
): ProtocolConfig {
    let mut config = scenario.take_shared_by_id<ProtocolConfig>(config_id);
    config.init_delayed_execution_policy(admin_cap, clock);
    config
}

fun finish(scenario: Scenario, admin_cap: AdminCap, config: ProtocolConfig, clock: Clock) {
    return_shared(config);
    destroy(admin_cap);
    clock.destroy_for_testing();
    scenario.end();
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

fun set_timing(config: &mut ProtocolConfig, admin_cap: &AdminCap, timing: Timing, clock: &Clock) {
    config.set_delayed_execution_timing(
        admin_cap,
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

fun set_limits(config: &mut ProtocolConfig, admin_cap: &AdminCap, limits: Limits, clock: &Clock) {
    config.set_delayed_execution_limits(
        admin_cap,
        limits.mint_capacity,
        limits.sell_capacity,
        limits.per_account_cap,
        limits.min_sell_quantity,
        limits.settle_refund_batch,
        limits.settle_payout_batch,
        clock,
    );
}

/// Set `timing` on top of the default limits and fee, and check every field.
fun assert_timing_accepted(
    config: &mut ProtocolConfig,
    admin_cap: &AdminCap,
    timing: Timing,
    clock: &Clock,
) {
    set_timing(config, admin_cap, timing, clock);
    assert_policy(config, timing, default_limits(), DEFAULT_ORDER_FEE);
}

/// Set `limits` on top of the default timing and fee, and check every field.
fun assert_limits_accepted(
    config: &mut ProtocolConfig,
    admin_cap: &AdminCap,
    limits: Limits,
    clock: &Clock,
) {
    set_limits(config, admin_cap, limits, clock);
    assert_policy(config, default_timing(), limits, DEFAULT_ORDER_FEE);
}

/// Every stored field, read through its public getter.
fun assert_policy(config: &ProtocolConfig, timing: Timing, limits: Limits, order_fee: u64) {
    let policy = config.delayed_execution_policy().destroy_some();
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
/// the complete post-state, byte for byte in the published field order.
fun assert_last_policy_event(event_count: u64, timing: Timing, limits: Limits, order_fee: u64) {
    let events = event::events_by_type<config_events::DelayedExecutionPolicyUpdated>();
    assert_eq!(events.length(), event_count);
    let expected = ExpectedDelayedExecutionPolicyUpdated {
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
