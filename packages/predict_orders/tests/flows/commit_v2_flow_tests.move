// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Flow coverage for `commit_v2`'s Block Scholes slot rule, the gap rule, the
/// refunds when no usable inputs price an order, the retired Lazer-only commit,
/// and the desk's `BsTiming` setter.
///
/// Mints placed at the fixture clock 120_000 get τ = 121_000 and deadline
/// 126_000. At the launch timing (value lag 500, SVI lag 1_000, gap wait 1_000)
/// τ's canonical slots are spot and forward at floor(120_500 / 500) * 500 =
/// 120_500 and SVI at floor(120_000 / 1_000) * 1_000 = 120_000. The next slots are
/// 121_000 and 121_000, accepted from 122_000.
#[test_only]
module deepbook_predict_orders::commit_v2_flow_tests;

use deepbook_predict::{expiry_market, flow_test_helpers as helpers, test_constants};
use deepbook_predict_math::block_scholes::{Self, BsVol};
use deepbook_predict_orders::{
    delayed_execution_config::{Self, BsTiming},
    desk,
    order_queue,
    queue,
    queue_event_views as events,
    queue_events::BsTimingUpdated,
    queue_fixture::{Self as fixture, QueueTest}
};
use fixed_math::i64;
use std::unit_test::assert_eq;
use sui::{bcs, event};

const QUANTITY: u64 = 4_000_000;
const MAX_COST: u64 = 3_000_000;
const TAU: u64 = 121_000;
const DEADLINE: u64 = 126_000;
const VALUE_SLOT: u64 = 120_500;
const SVI_SLOT: u64 = 120_000;
const NEXT_VALUE_SLOT: u64 = 121_000;
const NEXT_SVI_SLOT: u64 = 121_000;
const VALUE_STEP: u64 = 500;
const SVI_STEP: u64 = 1_000;
/// τ plus the launch gap wait.
const GAP_OPEN_AT: u64 = 122_000;
const ORDER_FEE: u64 = 20_000;
const RESOLVE_ALL: u64 = 10;
/// Lags a step longer than launch: canonical slots 120_000 and 119_000.
const LONGER_VALUE_LAG: u64 = 1_000;
const LONGER_SVI_LAG: u64 = 2_000;
const LONGER_VALUE_SLOT: u64 = 120_000;
const LONGER_SVI_SLOT: u64 = 119_000;
const LAUNCH_GAP_WAIT: u64 = 1_000;
const MIN_GAP_WAIT: u64 = 50;
const MAX_LAG: u64 = 10_000;

fun live_price(): u64 { fixture::live_price() }

fun place_mint(q: &mut QueueTest): u64 {
    q.enqueue_atm(QUANTITY, MAX_COST)
}

/// At `clock_ms`, commit the 200 ms update stamped τ with exactly `vols`.
fun commit_vols(q: &mut QueueTest, clock_ms: u64, vols: vector<BsVol>) {
    q.set_clock(clock_ms);
    q.commit_with(vector[fixture::price_update(TAU, live_price())], vols);
}

fun status(q: &QueueTest, record_id: u64): u8 { q.record(record_id).status() }

// === The slot rule ===

#[test]
fun the_canonical_slots_commit_the_cohort() {
    let mut q = fixture::new();
    let record_id = place_mint(&mut q);
    let vol = q.vol_at(VALUE_SLOT, SVI_SLOT);
    commit_vols(&mut q, TAU, vector[vol]);

    assert_eq!(status(&q, record_id), order_queue::status_committed());
    let (spot_ms, forward_ms, svi_ms) = q.committed_vol_times(record_id);
    assert_eq!(spot_ms, VALUE_SLOT);
    assert_eq!(forward_ms, VALUE_SLOT);
    assert_eq!(svi_ms, SVI_SLOT);
    assert_eq!(q.resolve(RESOLVE_ALL), 1);
    assert_eq!(events::fills().length(), 1);
    q.assert_invariants();
    q.finish();
}

#[test]
fun the_next_slots_wait_for_the_gap_wait() {
    let mut q = fixture::new();
    let record_id = place_mint(&mut q);
    let next_value = q.vol_at(NEXT_VALUE_SLOT, SVI_SLOT);
    let next_svi = q.vol_at(VALUE_SLOT, NEXT_SVI_SLOT);
    let both_next = q.vol_at(NEXT_VALUE_SLOT, NEXT_SVI_SLOT);
    // One ms before the gap wait passes, none of them is accepted.
    commit_vols(&mut q, GAP_OPEN_AT - 1, vector[next_value, next_svi, both_next]);
    assert_eq!(status(&q, record_id), order_queue::status_pending());
    q.finish();
}

#[test]
fun after_the_gap_wait_the_next_value_slot_commits() {
    let mut q = fixture::new();
    let record_id = place_mint(&mut q);
    let vol = q.vol_at(NEXT_VALUE_SLOT, SVI_SLOT);
    commit_vols(&mut q, GAP_OPEN_AT, vector[vol]);
    assert_eq!(status(&q, record_id), order_queue::status_committed());
    let (spot_ms, _, svi_ms) = q.committed_vol_times(record_id);
    assert_eq!(spot_ms, NEXT_VALUE_SLOT);
    assert_eq!(svi_ms, SVI_SLOT);
    q.finish();
}

#[test]
fun after_the_gap_wait_the_next_svi_slot_commits() {
    let mut q = fixture::new();
    let record_id = place_mint(&mut q);
    let vol = q.vol_at(VALUE_SLOT, NEXT_SVI_SLOT);
    commit_vols(&mut q, GAP_OPEN_AT, vector[vol]);
    assert_eq!(status(&q, record_id), order_queue::status_committed());
    let (spot_ms, _, svi_ms) = q.committed_vol_times(record_id);
    assert_eq!(spot_ms, VALUE_SLOT);
    assert_eq!(svi_ms, NEXT_SVI_SLOT);
    q.finish();
}

#[test]
fun after_the_gap_wait_both_next_slots_commit() {
    let mut q = fixture::new();
    let record_id = place_mint(&mut q);
    let vol = q.vol_at(NEXT_VALUE_SLOT, NEXT_SVI_SLOT);
    commit_vols(&mut q, GAP_OPEN_AT, vector[vol]);
    assert_eq!(status(&q, record_id), order_queue::status_committed());
    q.finish();
}

/// Only the single next slot is admissible, however long the wait.
#[test]
fun two_slots_later_never_commits() {
    let mut q = fixture::new();
    let record_id = place_mint(&mut q);
    let late_value = q.vol_at(NEXT_VALUE_SLOT + VALUE_STEP, SVI_SLOT);
    let late_svi = q.vol_at(VALUE_SLOT, NEXT_SVI_SLOT + SVI_STEP);
    let early_value = q.vol_at(VALUE_SLOT - VALUE_STEP, SVI_SLOT);
    commit_vols(&mut q, DEADLINE - 1, vector[late_value, late_svi, early_value]);
    assert_eq!(status(&q, record_id), order_queue::status_pending());
    q.finish();
}

/// With every admissible pair on offer, the canonical one prices the cohort,
/// wherever it sits in the vector.
#[test]
fun the_canonical_slots_win_over_the_next_ones() {
    let mut q = fixture::new();
    let record_id = place_mint(&mut q);
    let both_next = q.vol_at(NEXT_VALUE_SLOT, NEXT_SVI_SLOT);
    let next_value = q.vol_at(NEXT_VALUE_SLOT, SVI_SLOT);
    let canonical = q.vol_at(VALUE_SLOT, SVI_SLOT);
    commit_vols(&mut q, GAP_OPEN_AT, vector[both_next, next_value, canonical]);
    let (spot_ms, _, svi_ms) = q.committed_vol_times(record_id);
    assert_eq!(spot_ms, VALUE_SLOT);
    assert_eq!(svi_ms, SVI_SLOT);
    q.finish();
}

/// Without the canonical pair, the next SVI slot is preferred over the next value
/// slot.
#[test]
fun the_next_svi_slot_is_preferred_to_the_next_value_slot() {
    let mut q = fixture::new();
    let record_id = place_mint(&mut q);
    let both_next = q.vol_at(NEXT_VALUE_SLOT, NEXT_SVI_SLOT);
    let next_value = q.vol_at(NEXT_VALUE_SLOT, SVI_SLOT);
    let next_svi = q.vol_at(VALUE_SLOT, NEXT_SVI_SLOT);
    commit_vols(&mut q, GAP_OPEN_AT, vector[both_next, next_value, next_svi]);
    let (spot_ms, _, svi_ms) = q.committed_vol_times(record_id);
    assert_eq!(spot_ms, VALUE_SLOT);
    assert_eq!(svi_ms, NEXT_SVI_SLOT);
    q.finish();
}

/// Inputs for another expiry match no cohort here.
#[test]
fun inputs_for_another_expiry_leave_the_cohort_waiting() {
    let mut q = fixture::new();
    let record_id = place_mint(&mut q);
    let vol = q.vol_at(VALUE_SLOT, SVI_SLOT);
    let other = with_expiry(&vol, vol.expiry_ms() + 60_000);
    commit_vols(&mut q, TAU, vector[other]);
    assert_eq!(status(&q, record_id), order_queue::status_pending());
    q.finish();
}

// === Refunds ===

/// A cohort no usable inputs ever reach refunds at its deadline (reason 5) with
/// the order fee returned.
#[test]
fun with_no_block_scholes_inputs_the_cohort_refunds_at_its_deadline() {
    let mut q = fixture::new();
    let record_id = place_mint(&mut q);
    commit_vols(&mut q, GAP_OPEN_AT, vector[]);
    assert_eq!(status(&q, record_id), order_queue::status_pending());

    q.set_clock(DEADLINE);
    assert_eq!(q.resolve(RESOLVE_ALL), 1);
    let refund = events::refunds()[0];
    assert_eq!(refund.refund_record_id(), record_id);
    assert_eq!(refund.refund_reason(), order_queue::reason_deadline());
    assert_eq!(refund.refund_order_fee_returned(), ORDER_FEE);
    q.assert_invariants();
    q.finish();
}

/// Committed inputs that do not price at the tick refund with reason 10 and
/// return the order fee.
#[test]
fun inputs_that_do_not_price_refund_with_reason_10_and_the_fee() {
    let mut q = fixture::new();
    let record_id = place_mint(&mut q);
    let vol = q.vol_at(VALUE_SLOT, SVI_SLOT);
    // `rho` past 1 leaves Predict's pricing envelope.
    let bad = block_scholes::new_vol_for_testing(
        vol.base_asset(),
        vol.svi_model(),
        vol.svi_decimals(),
        vol.expiry_ms(),
        vol.value_ms(),
        vol.spot(),
        vol.forward(),
        vol.svi_ms(),
        vol.a_magnitude(),
        vol.a_is_negative(),
        vol.b(),
        i64::from_u64(2 * test_constants::float()),
        vol.m(),
        vol.sigma(),
    );
    commit_vols(&mut q, TAU, vector[bad]);
    assert_eq!(status(&q, record_id), order_queue::status_committed());

    assert_eq!(q.resolve(RESOLVE_ALL), 1);
    let refund = events::refunds()[0];
    assert_eq!(refund.refund_reason(), order_queue::reason_no_vol());
    assert_eq!(refund.refund_order_fee_returned(), ORDER_FEE);
    assert_eq!(status(&q, record_id), order_queue::status_refunded());
    q.assert_invariants();
    q.finish();
}

/// An order admitted under a Lazer feed the binding no longer names is skipped by
/// the commit, not aborted on, and refunds at its deadline with the order fee.
#[test]
fun an_order_admitted_under_a_replaced_feed_refunds_at_its_deadline() {
    let mut q = fixture::new();
    let record_id = place_mint(&mut q);
    q.set_binding_feed(test_constants::pyth_feed_id() + 1);
    let vol = q.vol_at(VALUE_SLOT, SVI_SLOT);
    commit_vols(&mut q, TAU, vector[vol]);
    assert_eq!(status(&q, record_id), order_queue::status_pending());

    q.set_clock(DEADLINE);
    assert_eq!(q.resolve(RESOLVE_ALL), 1);
    let refund = events::refunds()[0];
    assert_eq!(refund.refund_record_id(), record_id);
    assert_eq!(refund.refund_reason(), order_queue::reason_deadline());
    assert_eq!(refund.refund_order_fee_returned(), ORDER_FEE);
    q.assert_invariants();
    q.finish();
}

/// Inputs decoded under another SVI model than the market's binding are refused
/// by Predict's commit.
#[test, expected_failure(abort_code = expiry_market::EWrongVol)]
fun inputs_under_another_model_abort_the_commit() {
    let mut q = fixture::new();
    place_mint(&mut q);
    let vol = q.vol_at(VALUE_SLOT, SVI_SLOT);
    let other = block_scholes::new_vol_for_testing(
        vol.base_asset(),
        b"SVI_REGIME".to_string(),
        vol.svi_decimals(),
        vol.expiry_ms(),
        vol.value_ms(),
        vol.spot(),
        vol.forward(),
        vol.svi_ms(),
        vol.a_magnitude(),
        vol.a_is_negative(),
        vol.b(),
        vol.rho(),
        vol.m(),
        vol.sigma(),
    );
    commit_vols(&mut q, TAU, vector[other]);
    abort 999
}

#[test, expected_failure(abort_code = queue::EUseV2)]
fun the_lazer_only_commit_is_retired() {
    let mut q = fixture::new();
    place_mint(&mut q);
    q.set_clock(TAU);
    q.commit_v1();
    abort 999
}

// === BsTiming ===

#[test]
fun the_desk_starts_at_the_launch_timing() {
    let q = fixture::new();
    let timing = q.desk().bs_timing();
    assert_eq!(timing.bs_value_lag_ms(), VALUE_STEP);
    assert_eq!(timing.bs_svi_lag_ms(), SVI_STEP);
    assert_eq!(timing.bs_gap_wait_ms(), LAUNCH_GAP_WAIT);
    q.finish();
}

/// Longer lags move the canonical slots, including for a cohort already waiting,
/// and the setter emits its post-state.
#[test]
fun set_bs_timing_moves_the_slots_of_waiting_cohorts() {
    let mut q = fixture::new();
    let record_id = place_mint(&mut q);
    q.set_bs_timing(LONGER_VALUE_LAG, LONGER_SVI_LAG, LAUNCH_GAP_WAIT);
    let emitted = event::events_by_type<BsTimingUpdated>();
    assert_eq!(emitted.length(), 1);
    let mut expected = bcs::to_bytes(&q.desk_id());
    expected.append(bcs::to_bytes(&timing(LONGER_VALUE_LAG, LONGER_SVI_LAG, LAUNCH_GAP_WAIT)));
    expected.append(bcs::to_bytes(&q.fx().clock().timestamp_ms()));
    assert_eq!(bcs::to_bytes(&emitted[0]), expected);

    let launch = q.vol_at(VALUE_SLOT, SVI_SLOT);
    commit_vols(&mut q, TAU, vector[launch]);
    assert_eq!(status(&q, record_id), order_queue::status_pending());
    let longer = q.vol_at(LONGER_VALUE_SLOT, LONGER_SVI_SLOT);
    commit_vols(&mut q, TAU, vector[longer]);
    assert_eq!(status(&q, record_id), order_queue::status_committed());
    q.finish();
}

#[test]
fun set_bs_timing_accepts_its_bounds() {
    let mut q = fixture::new();
    q.set_bs_timing(VALUE_STEP, SVI_STEP, MIN_GAP_WAIT);
    q.set_bs_timing(MAX_LAG, MAX_LAG, MAX_LAG);
    let timing = q.desk().bs_timing();
    assert_eq!(timing.bs_value_lag_ms(), MAX_LAG);
    assert_eq!(timing.bs_svi_lag_ms(), MAX_LAG);
    assert_eq!(timing.bs_gap_wait_ms(), MAX_LAG);
    q.finish();
}

#[test, expected_failure(abort_code = delayed_execution_config::EInvalidBsTiming)]
fun a_value_lag_under_its_step_is_refused() {
    let mut q = fixture::new();
    q.set_bs_timing(VALUE_STEP - 1, SVI_STEP, LAUNCH_GAP_WAIT);
    abort 999
}

#[test, expected_failure(abort_code = delayed_execution_config::EInvalidBsTiming)]
fun an_svi_lag_under_its_step_is_refused() {
    let mut q = fixture::new();
    q.set_bs_timing(VALUE_STEP, SVI_STEP - 1, LAUNCH_GAP_WAIT);
    abort 999
}

#[test, expected_failure(abort_code = delayed_execution_config::EInvalidBsTiming)]
fun a_lag_past_ten_seconds_is_refused() {
    let mut q = fixture::new();
    q.set_bs_timing(MAX_LAG + 1, SVI_STEP, LAUNCH_GAP_WAIT);
    abort 999
}

#[test, expected_failure(abort_code = delayed_execution_config::EInvalidBsTiming)]
fun a_gap_wait_under_its_floor_is_refused() {
    let mut q = fixture::new();
    q.set_bs_timing(VALUE_STEP, SVI_STEP, MIN_GAP_WAIT - 1);
    abort 999
}

#[test, expected_failure(abort_code = desk::EProtocolFrozen)]
fun set_bs_timing_refuses_while_predict_is_frozen() {
    let mut q = fixture::new();
    q.set_frozen(true);
    q.set_bs_timing(VALUE_STEP, SVI_STEP, LAUNCH_GAP_WAIT);
    abort 999
}

// === The forwarders ===

/// The enqueue signature version 5 published still places, ignoring its Propbook
/// arguments, and its order fills like one placed through `_v2`.
#[test]
fun the_version_5_enqueue_signatures_still_place_and_fill() {
    let mut q = fixture::new();
    let record_id = q.enqueue_quantity_v1(
        helpers::strike_tick(),
        helpers::pos_inf_tick(),
        QUANTITY,
        MAX_COST,
        std::u64::max_value!(),
    );
    assert_eq!(status(&q, record_id), order_queue::status_pending());
    q.commit_at(TAU, live_price());
    q.set_clock(TAU);
    assert_eq!(q.resolve(RESOLVE_ALL), 1);
    assert_eq!(status(&q, record_id), order_queue::status_open());

    // An early sell through the version 5 signature also places.
    let mut q = q.next_tx(test_constants::alice());
    q.refresh_oracle_at(TAU);
    let sell_id = q.enqueue_sell_v1(record_id, QUANTITY, 0, 0);
    assert_eq!(status(&q, sell_id), order_queue::status_pending());
    assert_eq!(status(&q, record_id), order_queue::status_closed());
    q.finish();
}

fun timing(value_lag_ms: u64, svi_lag_ms: u64, gap_wait_ms: u64): BsTiming {
    delayed_execution_config::new_bs_timing(value_lag_ms, svi_lag_ms, gap_wait_ms)
}

fun with_expiry(vol: &BsVol, expiry_ms: u64): BsVol {
    block_scholes::new_vol_for_testing(
        vol.base_asset(),
        vol.svi_model(),
        vol.svi_decimals(),
        expiry_ms,
        vol.value_ms(),
        vol.spot(),
        vol.forward(),
        vol.svi_ms(),
        vol.a_magnitude(),
        vol.a_is_negative(),
        vol.b(),
        vol.rho(),
        vol.m(),
        vol.sigma(),
    )
}

/// The fixture market's underlying has the oracle binding these commits decode under.
#[test]
fun the_fixture_market_has_an_oracle_binding() {
    let q = fixture::new();
    assert!(
        helpers::config(q.bundle())
            .oracle_binding(test_constants::propbook_underlying_id())
            .is_some(),
    );
    q.finish();
}
