// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module propbook::block_scholes_feed_tests;

use block_scholes_oracle::update::{Self, Update};
use propbook::{
    block_scholes_feed::{Self, BlockScholesFeed},
    feed_core,
    pyth_feed,
    registry::{Self, OracleRegistry}
};
use std::unit_test::assert_eq;
use sui::{clock, test_scenario::{Self as test, Scenario, return_shared}};

const ADMIN: address = @0xAD;
const BTC_UNDERLYING: u32 = 1;
const OTHER_UNDERLYING: u32 = 2;
/// A numeric id used for BOTH a pyth and a BS feed to prove kinds don't collide.
const SHARED_ID: u32 = 7;

const SPOT: u64 = 50_000_000_000_000; // 50_000 * 1e9 (the persistent/primary spot)
const SPOT_STALE: u64 = 49_000_000_000_000; // 49_000 * 1e9, carried by stale updates; must not win

// Per-expiry forwards; basis = forward / SPOT (1e9-scaled), hand-computed.
const EXPIRY_A: u64 = 1_700_100_000_000;
const EXPIRY_B: u64 = 1_700_200_000_000;
const FORWARD_A: u64 = 50_500_000_000_000; // basis vs SPOT = 1.01
const BASIS_A: u64 = 1_010_000_000;
const FORWARD_B: u64 = 49_000_000_000_000; // basis vs SPOT = 0.98
const FORWARD_A2: u64 = 50_600_000_000_000; // the fresher surface-A forward (stale-spot test)
const UNKNOWN_EXPIRY: u64 = 9_999_999_999;

// SVI fixture shared by the test updates.
const SVI_A: u64 = 40_000_000;
const SVI_B: u64 = 120_000_000;
const SVI_SIGMA: u64 = 90_000_000;
const RHO_MAG: u64 = 300_000_000;
const RHO_NEG: bool = true;
const M_MAG: u64 = 25_000_000;
const M_NEG: bool = false;

// Publisher timestamps (ms) for the happy path (a clean minute) and the
// freshness-ordering tests (tiny values, all within one minute bucket and below
// the test clock landing time).
const PUBLISHED_MS: u64 = 420_123; // 7 min + 123 ms
const LANDED_MS: u64 = 420_173; // 50 ms after publish
const LANDED_HIGH: u64 = 1_000_000; // landing time above every freshness-test publish
const T_EARLY: u64 = 100;
const T_MID: u64 = 150;
const T_LATE: u64 = 200;
const T_SAME: u64 = 300;

#[test]
fun update_from_bs_records_spot_and_surface() {
    let (mut scenario, feed_obj_id) = setup_feed();
    let mut feed = scenario.take_shared_by_id<BlockScholesFeed>(feed_obj_id);
    let mut clock = clock::create_for_testing(scenario.ctx());
    clock.set_for_testing(LANDED_MS);

    feed.update_from_bs(bs_update(BTC_UNDERLYING, EXPIRY_A, PUBLISHED_MS, SPOT, FORWARD_A), &clock);

    // Core spot + freshness reflect the underlying snapshot.
    assert_eq!(feed.underlying(), BTC_UNDERLYING);
    assert_eq!(feed.spot(), SPOT);
    assert_eq!(feed.source_timestamp_ms(), PUBLISHED_MS);
    assert_eq!(feed.update_timestamp_ms(), LANDED_MS);
    assert_eq!(feed.freshness_timestamp_ms(), PUBLISHED_MS); // min(publish, landed)

    // Spot minute bucket recorded (queried with the unrounded publish ts).
    assert!(feed.has_minute(PUBLISHED_MS));
    assert_eq!(feed.price_at_minute(PUBLISHED_MS).spot(), SPOT);

    // Surface present with exact inputs.
    assert!(feed.has_expiry(EXPIRY_A));
    assert_eq!(feed.forward(EXPIRY_A), FORWARD_A);
    assert_eq!(feed.basis(EXPIRY_A), BASIS_A);
    assert_eq!(feed.surface_freshness_timestamp_ms(EXPIRY_A), PUBLISHED_MS);

    let svi0 = feed.svi(EXPIRY_A);
    assert_eq!(svi0.a(), SVI_A);
    assert_eq!(svi0.b(), SVI_B);
    assert_eq!(svi0.sigma(), SVI_SIGMA);
    assert_eq!(svi0.rho().magnitude(), RHO_MAG);
    assert_eq!(svi0.rho().is_negative(), RHO_NEG);
    assert_eq!(svi0.m().magnitude(), M_MAG);
    assert_eq!(svi0.m().is_negative(), M_NEG);

    clock.destroy_for_testing();
    return_shared(feed);
    scenario.end();
}

#[test]
fun sibling_expiries_same_timestamp_both_apply() {
    // Regression: two expiries with the SAME published ts both apply. The old
    // strict store_tick would have aborted the second (non-advancing) update.
    let (mut scenario, feed_obj_id) = setup_feed();
    let mut feed = scenario.take_shared_by_id<BlockScholesFeed>(feed_obj_id);
    let mut clock = clock::create_for_testing(scenario.ctx());
    clock.set_for_testing(LANDED_HIGH);

    feed.update_from_bs(bs_update(BTC_UNDERLYING, EXPIRY_A, T_SAME, SPOT, FORWARD_A), &clock);
    // Same publish ts: spot is a no-op (no abort), but expiry B is a fresh new row.
    feed.update_from_bs(bs_update(BTC_UNDERLYING, EXPIRY_B, T_SAME, SPOT, FORWARD_B), &clock);

    assert!(feed.has_expiry(EXPIRY_A));
    assert!(feed.has_expiry(EXPIRY_B));
    assert_eq!(feed.forward(EXPIRY_A), FORWARD_A);
    assert_eq!(feed.forward(EXPIRY_B), FORWARD_B);
    // Spot recorded once at T_SAME; the second (non-advancing) update left it.
    assert_eq!(feed.spot(), SPOT);
    assert_eq!(feed.source_timestamp_ms(), T_SAME);

    clock.destroy_for_testing();
    return_shared(feed);
    scenario.end();
}

#[test]
fun stale_spot_fresh_surface_updates_only_the_surface() {
    // A@100, B@200, then A@150: the A@150 spot is stale (150 < 200) but its
    // surface is fresh (150 > 100), so only surface A advances; spot stays at B's.
    let (mut scenario, feed_obj_id) = setup_feed();
    let mut feed = scenario.take_shared_by_id<BlockScholesFeed>(feed_obj_id);
    let mut clock = clock::create_for_testing(scenario.ctx());
    clock.set_for_testing(LANDED_HIGH);

    feed.update_from_bs(bs_update(BTC_UNDERLYING, EXPIRY_A, T_EARLY, SPOT, FORWARD_A), &clock);
    feed.update_from_bs(bs_update(BTC_UNDERLYING, EXPIRY_B, T_LATE, SPOT, FORWARD_B), &clock);
    feed.update_from_bs(
        bs_update(BTC_UNDERLYING, EXPIRY_A, T_MID, SPOT_STALE, FORWARD_A2),
        &clock,
    );

    // Spot did NOT regress: it stays at the T_LATE (B-era) value and timestamp.
    assert_eq!(feed.spot(), SPOT);
    assert_eq!(feed.source_timestamp_ms(), T_LATE);
    // Surface A advanced to the T_MID row; B is untouched.
    assert_eq!(feed.forward(EXPIRY_A), FORWARD_A2);
    assert_eq!(feed.surface_freshness_timestamp_ms(EXPIRY_A), T_MID);
    assert_eq!(feed.forward(EXPIRY_B), FORWARD_B);
    assert_eq!(feed.surface_freshness_timestamp_ms(EXPIRY_B), T_LATE);

    clock.destroy_for_testing();
    return_shared(feed);
    scenario.end();
}

#[test]
fun stale_resend_is_a_clean_noop() {
    // Same expiry + same published ts twice: the second changes nothing and does
    // NOT abort (neither spot nor surface is fresh).
    let (mut scenario, feed_obj_id) = setup_feed();
    let mut feed = scenario.take_shared_by_id<BlockScholesFeed>(feed_obj_id);
    let mut clock = clock::create_for_testing(scenario.ctx());
    clock.set_for_testing(LANDED_HIGH);

    feed.update_from_bs(bs_update(BTC_UNDERLYING, EXPIRY_A, T_SAME, SPOT, FORWARD_A), &clock);
    feed.update_from_bs(
        bs_update(BTC_UNDERLYING, EXPIRY_A, T_SAME, SPOT_STALE, FORWARD_A2),
        &clock,
    );

    assert_eq!(feed.spot(), SPOT);
    assert_eq!(feed.source_timestamp_ms(), T_SAME);
    assert_eq!(feed.forward(EXPIRY_A), FORWARD_A);
    assert_eq!(feed.surface_freshness_timestamp_ms(EXPIRY_A), T_SAME);

    clock.destroy_for_testing();
    return_shared(feed);
    scenario.end();
}

#[test]
fun has_expiry_reflects_written_rows() {
    let (mut scenario, feed_obj_id) = setup_feed();
    let mut feed = scenario.take_shared_by_id<BlockScholesFeed>(feed_obj_id);
    let mut clock = clock::create_for_testing(scenario.ctx());
    clock.set_for_testing(LANDED_MS);

    feed.update_from_bs(bs_update(BTC_UNDERLYING, EXPIRY_A, PUBLISHED_MS, SPOT, FORWARD_A), &clock);

    assert!(feed.has_expiry(EXPIRY_A));
    assert!(!feed.has_expiry(EXPIRY_B));
    assert!(!feed.has_expiry(UNKNOWN_EXPIRY));

    clock.destroy_for_testing();
    return_shared(feed);
    scenario.end();
}

#[test]
fun registry_records_bs_feed() {
    let (scenario, feed_obj_id) = setup_feed();
    let registry = scenario.take_shared<OracleRegistry>();

    assert!(registry.contains_feed(registry::kind_block_scholes!(), BTC_UNDERLYING));
    assert_eq!(
        registry.feed_object_id(registry::kind_block_scholes!(), BTC_UNDERLYING).destroy_some(),
        feed_obj_id,
    );

    return_shared(registry);
    scenario.end();
}

#[test]
fun pyth_and_bs_share_numeric_id_across_kinds() {
    let mut scenario = test::begin(ADMIN);
    registry::init_for_testing(scenario.ctx());
    scenario.next_tx(ADMIN);
    let mut registry = scenario.take_shared<OracleRegistry>();

    // Same numeric id under different kinds must not collide.
    let bs_id = block_scholes_feed::create_and_share(&mut registry, SHARED_ID, scenario.ctx());
    let pyth_id = pyth_feed::create_and_share(&mut registry, SHARED_ID, scenario.ctx());

    assert!(bs_id != pyth_id);
    assert_eq!(
        registry.feed_object_id(registry::kind_block_scholes!(), SHARED_ID).destroy_some(),
        bs_id,
    );
    assert_eq!(registry.feed_object_id(registry::kind_pyth!(), SHARED_ID).destroy_some(), pyth_id);

    return_shared(registry);
    scenario.end();
}

#[test, expected_failure(abort_code = registry::EFeedAlreadyExists)]
fun create_duplicate_underlying_aborts() {
    let (mut scenario, _feed_obj_id) = setup_feed();
    let mut registry = scenario.take_shared<OracleRegistry>();

    // A second BS feed for the same underlying reverts.
    block_scholes_feed::create_and_share(&mut registry, BTC_UNDERLYING, scenario.ctx());

    abort 999
}

#[test, expected_failure(abort_code = block_scholes_feed::EWrongUnderlying)]
fun update_wrong_underlying_aborts() {
    let (mut scenario, feed_obj_id) = setup_feed();
    let mut feed = scenario.take_shared_by_id<BlockScholesFeed>(feed_obj_id);
    let mut clock = clock::create_for_testing(scenario.ctx());
    clock.set_for_testing(LANDED_HIGH);

    // Update whose underlying does not match the feed's binding.
    feed.update_from_bs(bs_update(OTHER_UNDERLYING, EXPIRY_A, T_EARLY, SPOT, FORWARD_A), &clock);

    abort 999
}

#[test, expected_failure(abort_code = feed_core::EZeroSpot)]
fun update_zero_spot_aborts() {
    let (mut scenario, feed_obj_id) = setup_feed();
    let mut feed = scenario.take_shared_by_id<BlockScholesFeed>(feed_obj_id);
    let mut clock = clock::create_for_testing(scenario.ctx());
    clock.set_for_testing(LANDED_HIGH);

    // A zero spot always aborts, even though freshness is otherwise no-op.
    feed.update_from_bs(bs_update(BTC_UNDERLYING, EXPIRY_A, T_EARLY, 0, FORWARD_A), &clock);

    abort 999
}

#[test, expected_failure(abort_code = feed_core::EFutureSourceUpdate)]
fun update_future_source_aborts() {
    let (mut scenario, feed_obj_id) = setup_feed();
    let mut feed = scenario.take_shared_by_id<BlockScholesFeed>(feed_obj_id);
    let mut clock = clock::create_for_testing(scenario.ctx());
    // Landing time before the publish ts → future source.
    clock.set_for_testing(T_EARLY);

    feed.update_from_bs(bs_update(BTC_UNDERLYING, EXPIRY_A, T_LATE, SPOT, FORWARD_A), &clock);

    abort 999
}

#[test, expected_failure(abort_code = block_scholes_feed::EExpiryNotFound)]
fun forward_on_unknown_expiry_aborts() {
    let (scenario, feed_obj_id) = setup_feed();
    let feed = scenario.take_shared_by_id<BlockScholesFeed>(feed_obj_id);

    feed.forward(UNKNOWN_EXPIRY);

    abort 999
}

#[test, expected_failure(abort_code = block_scholes_feed::EExpiryNotFound)]
fun svi_on_unknown_expiry_aborts() {
    let (scenario, feed_obj_id) = setup_feed();
    let feed = scenario.take_shared_by_id<BlockScholesFeed>(feed_obj_id);

    feed.svi(UNKNOWN_EXPIRY);

    abort 999
}

#[test, expected_failure(abort_code = block_scholes_feed::EExpiryNotFound)]
fun surface_freshness_on_unknown_expiry_aborts() {
    let (scenario, feed_obj_id) = setup_feed();
    let feed = scenario.take_shared_by_id<BlockScholesFeed>(feed_obj_id);

    feed.surface_freshness_timestamp_ms(UNKNOWN_EXPIRY);

    abort 999
}

// EWrongVersion on the BS path is enforced by the shared `feed_core::
// store_tick_if_fresh` chokepoint (covered by `feed_core_tests::
// store_tick_wrong_version_aborts`). It cannot be re-exercised through
// `update_from_bs` without a BS test seam to corrupt the embedded core's version,
// and the task pins the seam count at three — so it is intentionally not retested
// here.

/// Build a single-expiry stub BS Update with the shared SVI fixture.
fun bs_update(underlying: u32, expiry: u64, published: u64, spot: u64, forward: u64): Update {
    update::new_update(
        underlying,
        expiry,
        published,
        spot,
        forward,
        SVI_A,
        SVI_B,
        SVI_SIGMA,
        RHO_MAG,
        RHO_NEG,
        M_MAG,
        M_NEG,
    )
}

/// Initialize the package (shares the registry), create+share a BS feed, and
/// advance so the shared feed is takeable. Returns the scenario and feed id.
fun setup_feed(): (Scenario, ID) {
    let mut scenario = test::begin(ADMIN);
    registry::init_for_testing(scenario.ctx());
    scenario.next_tx(ADMIN);

    let mut registry = scenario.take_shared<OracleRegistry>();
    let feed_obj_id = block_scholes_feed::create_and_share(
        &mut registry,
        BTC_UNDERLYING,
        scenario.ctx(),
    );
    return_shared(registry);
    scenario.next_tx(ADMIN);

    (scenario, feed_obj_id)
}
