// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Flow coverage for `commit`, driven through `commit_decoded` because a real
/// Pyth Lazer `Update` has no Move test constructor: which update prices which
/// cohort (exact τ, other channels, the one backup tick after the gap wait,
/// including across a policy channel switch), the all-or-nothing commit of a
/// cohort, the per-order feed and property aborts, prices that leave a cohort
/// waiting, overdue cohorts, the subsidy reservation, and the call's gates.
///
/// Every scenario places exact-quantity mints at the fixture clock 120_000 under
/// the default policy (delay 1_000, channel `fixed_rate@200ms`, stall 5_000), so
/// the first cohort's τ is floor((120_000 + 1_000) / 200) * 200 = 121_000 and its
/// deadline is 121_000 + 5_000 = 126_000. A second placement at 120_200 lands on
/// τ = floor(121_200 / 200) * 200 = 121_200 with deadline 126_200.
#[test_only]
module deepbook_predict::commit_flow_tests;

use deepbook_predict::{
    commit_resolve_test_helpers as h,
    expiry_market::{Self, LazerTick},
    flow_test_helpers::{Self as helpers, Fixture, MarketBundle, AccountBundle},
    order_queue,
    protocol_config,
    queue_test_helpers as queue,
    test_constants
};
use pyth_lazer::{
    i16::{Self as lazer_i16, I16 as LazerI16},
    i64::{Self as lazer_i64, I64 as LazerI64}
};
use std::unit_test::assert_eq;

const QUANTITY: u64 = 4_000_000;
const MAX_COST: u64 = 3_000_000;
const TAU: u64 = 121_000;
const SECOND_PLACEMENT_MS: u64 = 120_200;
const SECOND_TAU: u64 = 121_200;
const DEADLINE: u64 = 126_000;
const GAP_WAIT_MS: u64 = 2_000;
/// Channel tick lengths, which are also the only nonzero price buffers each
/// channel allows.
const TICK_200MS: u64 = 200;
const TICK_50MS: u64 = 50;
const US_PER_MS: u64 = 1_000;
const CHANNEL_50MS: u8 = 2;
const NEG_EXPONENT_9: u16 = 9;
const OTHER_FEED_ID: u32 = 2;
/// Above `pricing`'s pricing-safe ceiling of u64::max / 100 once read at 1e9.
const ABOVE_MAX_SPOT: u64 = 1_000_000_000_000_000_000;
/// The fixture's default subsidy rate (20%) and an exact-quantity order's subsidy
/// bound: its t₀ pre-subsidy trading fee, 0.005 * 4m = 20_000 (the far expiry
/// keeps the fee ramp at 1), well inside what the 3m budget could pay.
const SUBSIDY_RATE: u64 = 200_000_000;
/// mul_down(20_000, 0.2) = 4_000.
const RESERVED_SUBSIDY: u64 = 4_000;

// === Matching ===

#[test]
fun commit_exact_tau_update_commits_the_whole_cohort() {
    let (mut fx, mut market, mut account) = queue_market();
    let first = place_mint(&mut fx, &mut market, &mut account);
    let second = place_mint(&mut fx, &mut market, &mut account);
    fx.set_clock_for_testing(TAU);

    queue::commit_decoded(&mut fx, &mut market, vector[h::price_tick(TAU, live_price())]);

    vector[first, second].do!(|record_id| {
        let order = h::record(&market, record_id);
        assert_eq!(order.status(), order_queue::status_committed());
        assert_eq!(order.price().spot(), live_price());
        assert_eq!(order.price().tick_ms(), TAU);
        assert_eq!(order.price().generation_us(), TAU * US_PER_MS);
    });
    let (_, next_id, last_tau_ms, last_committed_tau_ms) = helpers::market(&market).queue_heads();
    assert_eq!(next_id, 2);
    assert_eq!(last_tau_ms, TAU);
    assert_eq!(last_committed_tau_ms, TAU);
    let (cohorts, oldest_uncommitted, _) = helpers::market(&market).waiting_cohorts();
    assert_eq!(cohorts, 1);
    assert!(oldest_uncommitted.is_none());
    queue::assert_queue_invariants(helpers::market(&market));
    finish(fx, market, account);
}

#[test]
fun commit_reports_the_cohort_in_cohort_committed() {
    let (mut fx, mut market, mut account) = queue_market();
    let first = place_mint(&mut fx, &mut market, &mut account);
    let second = place_mint(&mut fx, &mut market, &mut account);
    fx.set_clock_for_testing(TAU);

    queue::commit_decoded(&mut fx, &mut market, vector[h::price_tick(TAU, live_price())]);

    let commits = h::commits();
    assert_eq!(commits.length(), 1);
    let commit = commits[0];
    assert_eq!(commit.commit_market_id(), helpers::market(&market).id());
    assert_eq!(commit.commit_tau_ms(), TAU);
    assert_eq!(commit.commit_tick_ms(), TAU);
    assert_eq!(commit.commit_first_record_id(), first);
    assert_eq!(commit.commit_last_record_id(), second);
    assert_eq!(commit.commit_price_magnitude(), live_price());
    assert!(!commit.commit_price_is_negative());
    assert_eq!(commit.commit_exponent_magnitude(), NEG_EXPONENT_9);
    assert!(commit.commit_exponent_is_negative());
    assert_eq!(commit.commit_generation_us(), TAU * US_PER_MS);
    assert_eq!(commit.commit_pyth_source_id(), test_constants::pyth_feed_id());
    assert_eq!(commit.commit_pyth_channel(), h::channel_200ms());
    assert_eq!(commit.commit_sender(), test_constants::alice());
    assert_eq!(commit.commit_onchain_timestamp_ms(), TAU);
    finish(fx, market, account);
}

#[test]
fun commit_skips_updates_that_match_no_cohort() {
    let (mut fx, mut market, mut account) = queue_market();
    let record_id = place_mint(&mut fx, &mut market, &mut account);
    // Past the gap wait, so only the zero price buffer keeps the later tick out.
    fx.set_clock_for_testing(TAU + GAP_WAIT_MS);

    queue::commit_decoded(
        &mut fx,
        &mut market,
        vector[
            // One tick past τ: no exact match, and no backup at buffer 0.
            h::price_tick(TAU + TICK_200MS, live_price()),
            // Stamped τ, but on the 50 ms channel the cohort was not placed on.
            tick_on(CHANNEL_50MS, TAU),
        ],
    );

    assert_eq!(h::record(&market, record_id).status(), order_queue::status_pending());
    assert_eq!(last_committed_tau_ms(&market), 0);
    let (cohorts, oldest_uncommitted, oldest_above_committed) = helpers::market(
        &market,
    ).waiting_cohorts();
    assert_eq!(cohorts, 1);
    assert_eq!(oldest_uncommitted, option::some(TAU));
    assert_eq!(oldest_above_committed, option::some(TAU));
    assert!(h::commits().is_empty());
    finish(fx, market, account);
}

#[test]
fun commit_backup_tick_waits_for_the_gap() {
    let (mut fx, mut market, mut account) = queue_market();
    set_timing(&mut fx, &mut market, h::channel_200ms(), TICK_200MS);
    let record_id = place_mint(&mut fx, &mut market, &mut account);
    let ticks = vector[h::price_tick(TAU + TICK_200MS, live_price())];

    // One ms before τ + gap_wait: the backup tick is not yet accepted.
    fx.set_clock_for_testing(TAU + GAP_WAIT_MS - 1);
    queue::commit_decoded(&mut fx, &mut market, ticks);
    assert_eq!(h::record(&market, record_id).status(), order_queue::status_pending());
    assert!(h::commits().is_empty());

    fx.set_clock_for_testing(TAU + GAP_WAIT_MS);
    queue::commit_decoded(&mut fx, &mut market, ticks);
    let order = h::record(&market, record_id);
    assert_eq!(order.status(), order_queue::status_committed());
    assert_eq!(order.price().tick_ms(), TAU + TICK_200MS);
    assert_eq!(order.price().generation_us(), (TAU + TICK_200MS) * US_PER_MS);
    // The cohort's τ, not the backup tick, is what `last_committed_tau_ms` tracks.
    assert_eq!(last_committed_tau_ms(&market), TAU);
    let commits = h::commits();
    assert_eq!(commits.length(), 1);
    assert_eq!(commits[0].commit_tau_ms(), TAU);
    assert_eq!(commits[0].commit_tick_ms(), TAU + TICK_200MS);
    finish(fx, market, account);
}

#[test]
fun commit_accepts_only_the_next_channel_tick_as_backup() {
    let (mut fx, mut market, mut account) = queue_market();
    set_timing(&mut fx, &mut market, h::channel_200ms(), TICK_200MS);
    let record_id = place_mint(&mut fx, &mut market, &mut account);
    fx.set_clock_for_testing(TAU + GAP_WAIT_MS);

    // Off the channel grid, and two ticks past τ: neither is a backup.
    queue::commit_decoded(
        &mut fx,
        &mut market,
        vector[
            h::price_tick(TAU + TICK_200MS / 2, live_price()),
            h::price_tick(TAU + 2 * TICK_200MS, live_price()),
        ],
    );
    assert_eq!(h::record(&market, record_id).status(), order_queue::status_pending());
    assert!(h::commits().is_empty());

    // The next tick commits wherever it sits in the list.
    queue::commit_decoded(
        &mut fx,
        &mut market,
        vector[
            h::price_tick(TAU + 2 * TICK_200MS, live_price()),
            h::price_tick(TAU + TICK_200MS, live_price()),
        ],
    );
    assert_eq!(h::record(&market, record_id).price().tick_ms(), TAU + TICK_200MS);
    finish(fx, market, account);
}

#[test]
fun commit_exact_tau_update_beats_an_earlier_listed_backup() {
    let (mut fx, mut market, mut account) = queue_market();
    set_timing(&mut fx, &mut market, h::channel_200ms(), TICK_200MS);
    let record_id = place_mint(&mut fx, &mut market, &mut account);
    fx.set_clock_for_testing(TAU + GAP_WAIT_MS);

    queue::commit_decoded(
        &mut fx,
        &mut market,
        vector[h::price_tick(TAU + TICK_200MS, live_price()), h::price_tick(TAU, live_price())],
    );

    assert_eq!(h::record(&market, record_id).price().tick_ms(), TAU);
    finish(fx, market, account);
}

#[test]
fun commit_backup_follows_a_50ms_cohort_after_the_policy_moves_to_200ms() {
    let (mut fx, mut market, mut account) = queue_market();
    set_timing(&mut fx, &mut market, CHANNEL_50MS, TICK_50MS);
    // floor((120_000 + 1_000) / 50) * 50 = 121_000 on the 50 ms channel.
    let record_id = place_mint(&mut fx, &mut market, &mut account);
    set_timing(&mut fx, &mut market, h::channel_200ms(), TICK_200MS);
    fx.set_clock_for_testing(TAU + GAP_WAIT_MS);

    // The 200 ms buffer does not widen the waiting cohort's window: later 50 ms
    // ticks and a 200 ms tick are all refused.
    queue::commit_decoded(
        &mut fx,
        &mut market,
        vector[
            tick_on(CHANNEL_50MS, TAU + 2 * TICK_50MS),
            tick_on(CHANNEL_50MS, TAU + 3 * TICK_50MS),
            tick_on(CHANNEL_50MS, TAU + TICK_200MS),
            tick_on(h::channel_200ms(), TAU + TICK_200MS),
        ],
    );
    assert_eq!(h::record(&market, record_id).status(), order_queue::status_pending());
    assert!(h::commits().is_empty());

    queue::commit_decoded(&mut fx, &mut market, vector[tick_on(CHANNEL_50MS, TAU + TICK_50MS)]);
    let order = h::record(&market, record_id);
    assert_eq!(order.status(), order_queue::status_committed());
    assert_eq!(order.price().tick_ms(), TAU + TICK_50MS);
    finish(fx, market, account);
}

#[test]
fun commit_backup_follows_a_200ms_cohort_after_the_policy_moves_to_50ms() {
    let (mut fx, mut market, mut account) = queue_market();
    // Placed under the default 200 ms channel with no buffer.
    let record_id = place_mint(&mut fx, &mut market, &mut account);
    set_timing(&mut fx, &mut market, CHANNEL_50MS, TICK_50MS);
    fx.set_clock_for_testing(TAU + GAP_WAIT_MS);

    // Neither a 50 ms-later tick on the cohort's channel nor one on the new
    // policy channel is its backup.
    queue::commit_decoded(
        &mut fx,
        &mut market,
        vector[
            tick_on(h::channel_200ms(), TAU + TICK_50MS),
            tick_on(CHANNEL_50MS, TAU + TICK_50MS),
        ],
    );
    assert_eq!(h::record(&market, record_id).status(), order_queue::status_pending());

    // Its own next 200 ms tick commits it, beyond the 50 ms buffer: the buffer
    // only switches the backup on.
    queue::commit_decoded(
        &mut fx,
        &mut market,
        vector[tick_on(h::channel_200ms(), TAU + TICK_200MS)],
    );
    assert_eq!(h::record(&market, record_id).price().tick_ms(), TAU + TICK_200MS);
    finish(fx, market, account);
}

#[test]
fun commit_one_update_prices_two_cohorts() {
    let (mut fx, mut market, mut account) = queue_market();
    set_timing(&mut fx, &mut market, h::channel_200ms(), TICK_200MS);
    let first = place_mint(&mut fx, &mut market, &mut account);
    fx.set_clock_for_testing(SECOND_PLACEMENT_MS);
    let second = place_mint(&mut fx, &mut market, &mut account);
    // Past the first cohort's gap wait, before either deadline.
    fx.set_clock_for_testing(TAU + GAP_WAIT_MS);

    // Stamped the second cohort's τ, which is also the first cohort's next
    // 200 ms tick, so it is the first cohort's backup.
    queue::commit_decoded(&mut fx, &mut market, vector[h::price_tick(SECOND_TAU, live_price())]);

    assert_eq!(h::record(&market, first).price().tick_ms(), SECOND_TAU);
    assert_eq!(h::record(&market, second).price().tick_ms(), SECOND_TAU);
    assert_eq!(last_committed_tau_ms(&market), SECOND_TAU);
    let commits = h::commits();
    assert_eq!(commits.length(), 2);
    assert_eq!(commits[0].commit_tau_ms(), TAU);
    assert_eq!(commits[1].commit_tau_ms(), SECOND_TAU);
    finish(fx, market, account);
}

#[test]
fun commit_prices_cohorts_in_any_order_and_keeps_the_committed_tau_monotone() {
    let (mut fx, mut market, mut account) = queue_market();
    let first = place_mint(&mut fx, &mut market, &mut account);
    fx.set_clock_for_testing(SECOND_PLACEMENT_MS);
    let second = place_mint(&mut fx, &mut market, &mut account);
    fx.set_clock_for_testing(SECOND_TAU);

    // The later cohort commits first and never waits on the earlier one.
    queue::commit_decoded(&mut fx, &mut market, vector[h::price_tick(SECOND_TAU, live_price())]);
    assert_eq!(h::record(&market, first).status(), order_queue::status_pending());
    assert_eq!(h::record(&market, second).status(), order_queue::status_committed());
    assert_eq!(last_committed_tau_ms(&market), SECOND_TAU);

    queue::commit_decoded(&mut fx, &mut market, vector[h::price_tick(TAU, live_price())]);
    assert_eq!(h::record(&market, first).status(), order_queue::status_committed());
    assert_eq!(last_committed_tau_ms(&market), SECOND_TAU);
    finish(fx, market, account);
}

#[test]
fun commit_twice_is_a_no_op() {
    let (mut fx, mut market, mut account) = queue_market();
    let record_id = place_mint(&mut fx, &mut market, &mut account);
    fx.set_clock_for_testing(TAU);
    queue::commit_decoded(&mut fx, &mut market, vector[h::price_tick(TAU, live_price())]);
    // A different price for the same τ cannot overwrite the committed one.
    queue::commit_decoded(
        &mut fx,
        &mut market,
        vector[h::price_tick(TAU, live_price() + test_constants::float())],
    );

    assert_eq!(h::record(&market, record_id).price().spot(), live_price());
    assert_eq!(h::commits().length(), 1);
    queue::assert_queue_invariants(helpers::market(&market));
    finish(fx, market, account);
}

// === Cohorts that stay waiting ===

#[test]
fun commit_never_commits_a_cohort_at_or_past_its_deadline() {
    let (mut fx, mut market, mut account) = queue_market();
    let first = place_mint(&mut fx, &mut market, &mut account);
    fx.set_clock_for_testing(SECOND_PLACEMENT_MS);
    let second = place_mint(&mut fx, &mut market, &mut account);
    // Exactly the first cohort's deadline, one tick before the second's.
    fx.set_clock_for_testing(DEADLINE);

    queue::commit_decoded(
        &mut fx,
        &mut market,
        vector[h::price_tick(TAU, live_price()), h::price_tick(SECOND_TAU, live_price())],
    );

    let overdue = h::record(&market, first);
    assert_eq!(overdue.status(), order_queue::status_pending());
    assert_eq!(overdue.price().tick_ms(), 0);
    assert_eq!(h::record(&market, second).status(), order_queue::status_committed());
    // Only the second cohort raised it; nothing marks the first RefundDue.
    assert_eq!(last_committed_tau_ms(&market), SECOND_TAU);
    assert_eq!(h::commits().length(), 1);
    finish(fx, market, account);
}

#[test]
fun commit_leaves_the_cohort_waiting_on_an_unusable_or_early_price() {
    let (mut fx, mut market, mut account) = queue_market();
    let record_id = place_mint(&mut fx, &mut market, &mut account);
    fx.set_clock_for_testing(TAU);
    let feed_id = test_constants::pyth_feed_id();
    let exponent = option::some(lazer_i16::new(NEG_EXPONENT_9, true));
    let generation = option::some(option::some(TAU * US_PER_MS));
    let unusable = vector[
        // Requested but empty price.
        queue::lazer_feed(feed_id, option::some(option::none()), exponent, generation),
        // Requested but empty update time.
        queue::lazer_feed(
            feed_id,
            lazer_price(live_price(), false),
            exponent,
            option::some(option::none()),
        ),
        // Zero, negative, and above the pricing-safe spot ceiling.
        queue::lazer_feed(feed_id, lazer_price(0, false), exponent, generation),
        queue::lazer_feed(feed_id, lazer_price(live_price(), true), exponent, generation),
        queue::lazer_feed(feed_id, lazer_price(ABOVE_MAX_SPOT, false), exponent, generation),
        // Generated one µs before τ.
        queue::lazer_feed(
            feed_id,
            lazer_price(live_price(), false),
            exponent,
            option::some(option::some(TAU * US_PER_MS - 1)),
        ),
    ];

    unusable.do!(|feed| {
        queue::commit_decoded(
            &mut fx,
            &mut market,
            vector[queue::lazer_tick_with_feeds(TAU * US_PER_MS, h::channel_200ms(), vector[feed])],
        );
        assert_eq!(h::record(&market, record_id).status(), order_queue::status_pending());
        assert_eq!(last_committed_tau_ms(&market), 0);
    });
    assert!(h::commits().is_empty());

    // The cohort still commits on a usable τ update before its deadline.
    queue::commit_decoded(&mut fx, &mut market, vector[h::price_tick(TAU, live_price())]);
    assert_eq!(h::record(&market, record_id).status(), order_queue::status_committed());
    assert_eq!(h::commits().length(), 1);
    finish(fx, market, account);
}

// === Subsidy ===

#[test]
fun commit_reserves_each_mint_subsidy_from_the_incentives() {
    let (mut fx, mut market, mut account) = queue_market();
    fund_fee_incentives(&mut fx, &mut market);
    let incentives = helpers::market(&market).fee_incentive_balance();
    assert!(incentives >= 2 * RESERVED_SUBSIDY);
    let first = place_mint(&mut fx, &mut market, &mut account);
    let second = place_mint(&mut fx, &mut market, &mut account);
    fx.set_clock_for_testing(TAU);

    queue::commit_decoded(&mut fx, &mut market, vector[h::price_tick(TAU, live_price())]);

    vector[first, second].do!(|record_id| {
        let escrow = h::record(&market, record_id).escrow();
        assert_eq!(escrow.subsidy_rate(), SUBSIDY_RATE);
        assert_eq!(escrow.subsidy_reserved(), RESERVED_SUBSIDY);
    });
    assert_eq!(helpers::market(&market).fee_incentive_balance(), incentives - 2 * RESERVED_SUBSIDY);
    queue::assert_queue_invariants(helpers::market(&market));
    finish(fx, market, account);
}

// === Aborts ===

#[test, expected_failure(abort_code = expiry_market::EPythFeedMissing)]
fun commit_without_the_order_feed_aborts() {
    let (mut fx, mut market, mut account) = queue_market();
    place_mint(&mut fx, &mut market, &mut account);
    let tick = queue::lazer_tick(
        TAU,
        h::channel_200ms(),
        OTHER_FEED_ID,
        live_price(),
        NEG_EXPONENT_9,
        TAU * US_PER_MS,
    );
    queue::commit_decoded(&mut fx, &mut market, vector[tick]);
    abort 999
}

#[test, expected_failure(abort_code = expiry_market::EPythPropertyNotRequested)]
fun commit_without_a_requested_price_aborts() {
    commit_one_feed_on_a_fresh_cohort(
        option::none(),
        option::some(lazer_i16::new(NEG_EXPONENT_9, true)),
        option::some(option::some(TAU * US_PER_MS)),
    );
    abort 999
}

#[test, expected_failure(abort_code = expiry_market::EPythPropertyNotRequested)]
fun commit_without_a_requested_exponent_aborts() {
    commit_one_feed_on_a_fresh_cohort(
        option::some(option::some(lazer_i64::new(live_price(), false))),
        option::none(),
        option::some(option::some(TAU * US_PER_MS)),
    );
    abort 999
}

#[test, expected_failure(abort_code = expiry_market::EPythPropertyNotRequested)]
fun commit_without_a_requested_update_time_aborts() {
    commit_one_feed_on_a_fresh_cohort(
        option::some(option::some(lazer_i64::new(live_price(), false))),
        option::some(lazer_i16::new(NEG_EXPONENT_9, true)),
        option::none(),
    );
    abort 999
}

#[test, expected_failure(abort_code = expiry_market::EGenerationAfterEnvelope)]
fun commit_with_a_generation_after_the_envelope_aborts() {
    commit_one_feed_on_a_fresh_cohort(
        option::some(option::some(lazer_i64::new(live_price(), false))),
        option::some(lazer_i16::new(NEG_EXPONENT_9, true)),
        option::some(option::some(TAU * US_PER_MS + 1)),
    );
    abort 999
}

#[test, expected_failure(abort_code = expiry_market::EUpdateDoesNotMatchQueue)]
fun commit_with_a_fractional_ms_envelope_aborts() {
    let (mut fx, mut market, mut account) = queue_market();
    place_mint(&mut fx, &mut market, &mut account);
    let feed = queue::lazer_feed(
        test_constants::pyth_feed_id(),
        option::some(option::some(lazer_i64::new(live_price(), false))),
        option::some(lazer_i16::new(NEG_EXPONENT_9, true)),
        option::some(option::some(TAU * US_PER_MS)),
    );
    queue::commit_decoded(
        &mut fx,
        &mut market,
        vector[queue::lazer_tick_with_feeds(TAU * US_PER_MS + 1, h::channel_200ms(), vector[feed])],
    );
    abort 999
}

#[test, expected_failure(abort_code = protocol_config::EProtocolFrozen)]
fun commit_while_frozen_aborts() {
    let (mut fx, mut market, mut account) = queue_market();
    place_mint(&mut fx, &mut market, &mut account);
    fx.set_frozen_bundle(&mut market, true);
    queue::commit_decoded(&mut fx, &mut market, vector[h::price_tick(TAU, live_price())]);
    abort 999
}

#[test, expected_failure(abort_code = protocol_config::EPolicyNotInitialized)]
fun commit_before_the_policy_exists_aborts() {
    let (mut fx, expiry_id, _) = helpers::setup_live_market(
        test_constants::default_expiry_ms(),
        test_constants::default_live_price(),
    );
    let mut market = fx.take_market_bundle(expiry_id);
    queue::commit_decoded(&mut fx, &mut market, vector[h::price_tick(TAU, live_price())]);
    abort 999
}

// === Helpers ===

fun live_price(): u64 { test_constants::default_live_price() }

/// The default queue market, entered as alice at the fixture clock.
fun queue_market(): (Fixture, MarketBundle, AccountBundle) {
    let (mut fx, expiry_id, trader) = queue::setup_queue_market(
        test_constants::default_expiry_ms(),
        live_price(),
    );
    let (market, account) = h::enter(&mut fx, expiry_id, &trader);
    (fx, market, account)
}

fun place_mint(fx: &mut Fixture, market: &mut MarketBundle, account: &mut AccountBundle): u64 {
    queue::enqueue_exact_quantity(
        fx,
        market,
        account,
        helpers::strike_tick(),
        helpers::pos_inf_tick(),
        QUANTITY,
        MAX_COST,
        std::u64::max_value!(),
    )
}

/// Set the policy channel and price buffer, keeping every other timing default.
fun set_timing(fx: &mut Fixture, market: &mut MarketBundle, channel: u8, buffer_ms: u64) {
    let (admin_cap, clock, _) = fx.admin_parts();
    helpers::config_mut(market).set_delayed_execution_timing(
        admin_cap,
        1_000,
        5_000,
        1_500,
        GAP_WAIT_MS,
        buffer_ms,
        channel,
        60_000,
        clock,
    );
}

/// A usable update at the live price on `channel`, generated at its envelope.
fun tick_on(channel: u8, envelope_ms: u64): LazerTick {
    queue::lazer_tick(
        envelope_ms,
        channel,
        test_constants::pyth_feed_id(),
        live_price(),
        NEG_EXPONENT_9,
        envelope_ms * US_PER_MS,
    )
}

/// Sponsor the pool and let a rebalance hand the market its fee incentives.
fun fund_fee_incentives(fx: &mut Fixture, market: &mut MarketBundle) {
    fx.sponsor_fee_incentives_bundle(market, test_constants::usdc_unit() * 10);
    fx.rebalance_expiry_cash_bundle(market);
}

fun last_committed_tau_ms(market: &MarketBundle): u64 {
    let (_, _, _, last_committed_tau_ms) = helpers::market(market).queue_heads();
    last_committed_tau_ms
}

/// Place one mint and commit one hand-built feed for its τ.
fun commit_one_feed_on_a_fresh_cohort(
    price: Option<Option<LazerI64>>,
    exponent: Option<LazerI16>,
    generation: Option<Option<u64>>,
) {
    let (mut fx, mut market, mut account) = queue_market();
    place_mint(&mut fx, &mut market, &mut account);
    let feed = queue::lazer_feed(test_constants::pyth_feed_id(), price, exponent, generation);
    queue::commit_decoded(
        &mut fx,
        &mut market,
        vector[queue::lazer_tick_with_feeds(TAU * US_PER_MS, h::channel_200ms(), vector[feed])],
    );
    finish(fx, market, account);
}

/// A requested, non-empty Lazer price.
fun lazer_price(magnitude: u64, is_negative: bool): Option<Option<LazerI64>> {
    option::some(option::some(lazer_i64::new(magnitude, is_negative)))
}

fun finish(fx: Fixture, market: MarketBundle, account: AccountBundle) {
    h::finish(fx, market, account);
}
