// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module propbook::block_scholes_feed_tests;

use block_scholes_oracle::update::{Self, Update};
use propbook::{
    block_scholes_feed::{Self, BlockScholesFeed},
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

const SPOT: u64 = 50_000_000_000_000; // 50_000 * 1e9 (each surface row carries its own spot)
const SPOT_STALE: u64 = 49_000_000_000_000; // 49_000 * 1e9, carried by a later surface-A row

// Per-expiry forwards; basis = forward / spot (1e9-scaled), hand-computed.
const EXPIRY_A: u64 = 1_700_100_000_000;
const EXPIRY_B: u64 = 1_700_200_000_000;
const FORWARD_A: u64 = 50_500_000_000_000; // basis vs SPOT = 1.01
const BASIS_A: u64 = 1_010_000_000; // 50_500 / 50_000 in 1e9 fixed point
const FORWARD_B: u64 = 49_000_000_000_000; // basis vs SPOT = 0.98
const FORWARD_A2: u64 = 50_600_000_000_000; // the fresher surface-A forward
const UNKNOWN_EXPIRY: u64 = 9_999_999_999;

// SVI fixture (valid under propbook's ingest band: |rho| <= 1, sigma in [1e-3, 100]).
const SVI_A: u64 = 40_000_000;
const SVI_B: u64 = 120_000_000;
const SVI_SIGMA: u64 = 90_000_000; // 0.09, inside [svi_sigma_min, svi_sigma_max]
const RHO_MAG: u64 = 300_000_000; // 0.3, |rho| <= 1
const RHO_NEG: bool = true;
const M_MAG: u64 = 25_000_000;
const M_NEG: bool = false;

const FLOAT_SCALING: u64 = 1_000_000_000;
const SIGMA_MIN: u64 = 1_000_000; // propbook svi_sigma_min (1e-3)
const SIGMA_MAX: u64 = 100_000_000_000; // propbook svi_sigma_max (100.0)

// Publisher timestamps (ms): the happy path (a clean minute, bucket 7) and the
// freshness-ordering tests (tiny values, all in minute bucket 0, below the clock).
const PUBLISHED_MS: u64 = 420_123; // 7 min + 123 ms (minute bucket 7)
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

    assert_eq!(feed.underlying(), BTC_UNDERLYING);

    // Spot minute bucket recorded (queried with the unrounded publish ts).
    assert!(feed.has_minute(PUBLISHED_MS));
    assert_eq!(feed.price_at_minute(PUBLISHED_MS).spot(), SPOT);

    // Per-expiry surface present with exact inputs (spot is per-expiry now).
    assert!(feed.has_expiry(EXPIRY_A));
    assert_eq!(feed.spot(EXPIRY_A), SPOT);
    assert_eq!(feed.forward(EXPIRY_A), FORWARD_A);
    assert_eq!(feed.basis(EXPIRY_A), BASIS_A);
    assert_eq!(feed.surface_freshness_timestamp_ms(EXPIRY_A), PUBLISHED_MS); // min(publish, landed)

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
    // Two expiries with the SAME published ts both apply: surface freshness is
    // per-expiry, so a brand-new expiry row always writes regardless of another
    // expiry's timestamp. The shared minute bucket is first-wins.
    let (mut scenario, feed_obj_id) = setup_feed();
    let mut feed = scenario.take_shared_by_id<BlockScholesFeed>(feed_obj_id);
    let mut clock = clock::create_for_testing(scenario.ctx());
    clock.set_for_testing(LANDED_HIGH);

    feed.update_from_bs(bs_update(BTC_UNDERLYING, EXPIRY_A, T_SAME, SPOT, FORWARD_A), &clock);
    feed.update_from_bs(bs_update(BTC_UNDERLYING, EXPIRY_B, T_SAME, SPOT, FORWARD_B), &clock);

    assert!(feed.has_expiry(EXPIRY_A));
    assert!(feed.has_expiry(EXPIRY_B));
    assert_eq!(feed.forward(EXPIRY_A), FORWARD_A);
    assert_eq!(feed.forward(EXPIRY_B), FORWARD_B);
    // The minute bucket was filled once (first-wins) at T_SAME with the shared spot.
    assert_eq!(feed.price_at_minute(T_SAME).spot(), SPOT);

    clock.destroy_for_testing();
    return_shared(feed);
    scenario.end();
}

#[test]
fun stale_surface_resend_no_ops_but_minute_is_first_wins() {
    // A@T_EARLY, B@T_LATE, then A@T_MID: the A@T_MID surface is fresh (150 > 100),
    // so surface A advances; the shared minute bucket (all three in bucket 0) keeps
    // its first-wins A@T_EARLY spot and never regresses.
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

    // Surface A advanced to the T_MID row (carrying its own SPOT_STALE); B untouched.
    assert_eq!(feed.spot(EXPIRY_A), SPOT_STALE);
    assert_eq!(feed.forward(EXPIRY_A), FORWARD_A2);
    assert_eq!(feed.surface_freshness_timestamp_ms(EXPIRY_A), T_MID);
    assert_eq!(feed.spot(EXPIRY_B), SPOT);
    assert_eq!(feed.forward(EXPIRY_B), FORWARD_B);
    assert_eq!(feed.surface_freshness_timestamp_ms(EXPIRY_B), T_LATE);
    // Minute bucket 0 keeps the first-wins A@T_EARLY spot (never the later SPOT_STALE).
    assert_eq!(feed.price_at_minute(T_EARLY).spot(), SPOT);

    clock.destroy_for_testing();
    return_shared(feed);
    scenario.end();
}

#[test]
fun stale_resend_is_a_clean_noop() {
    // Same expiry + same published ts twice: the second changes nothing and does
    // NOT abort (the surface is not fresh).
    let (mut scenario, feed_obj_id) = setup_feed();
    let mut feed = scenario.take_shared_by_id<BlockScholesFeed>(feed_obj_id);
    let mut clock = clock::create_for_testing(scenario.ctx());
    clock.set_for_testing(LANDED_HIGH);

    feed.update_from_bs(bs_update(BTC_UNDERLYING, EXPIRY_A, T_SAME, SPOT, FORWARD_A), &clock);
    feed.update_from_bs(
        bs_update(BTC_UNDERLYING, EXPIRY_A, T_SAME, SPOT_STALE, FORWARD_A2),
        &clock,
    );

    assert_eq!(feed.spot(EXPIRY_A), SPOT);
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

    feed.update_from_bs(bs_update(OTHER_UNDERLYING, EXPIRY_A, T_EARLY, SPOT, FORWARD_A), &clock);

    abort 999
}

#[test, expected_failure(abort_code = block_scholes_feed::EZeroSpot)]
fun update_zero_spot_aborts() {
    let (mut scenario, feed_obj_id) = setup_feed();
    let mut feed = scenario.take_shared_by_id<BlockScholesFeed>(feed_obj_id);
    let mut clock = clock::create_for_testing(scenario.ctx());
    clock.set_for_testing(LANDED_HIGH);

    feed.update_from_bs(bs_update(BTC_UNDERLYING, EXPIRY_A, T_EARLY, 0, FORWARD_A), &clock);

    abort 999
}

#[test, expected_failure(abort_code = block_scholes_feed::EFutureSourceUpdate)]
fun update_future_source_aborts() {
    let (mut scenario, feed_obj_id) = setup_feed();
    let mut feed = scenario.take_shared_by_id<BlockScholesFeed>(feed_obj_id);
    let mut clock = clock::create_for_testing(scenario.ctx());
    clock.set_for_testing(T_EARLY); // landing before publish → future source

    feed.update_from_bs(bs_update(BTC_UNDERLYING, EXPIRY_A, T_LATE, SPOT, FORWARD_A), &clock);

    abort 999
}

// === Surface math-validity guards (ingest chokepoint) ===

#[test, expected_failure(abort_code = block_scholes_feed::EZeroForward)]
fun update_zero_forward_aborts() {
    let (mut scenario, feed_obj_id) = setup_feed();
    let mut feed = scenario.take_shared_by_id<BlockScholesFeed>(feed_obj_id);
    let mut clock = clock::create_for_testing(scenario.ctx());
    clock.set_for_testing(LANDED_HIGH);

    // Spot is valid but the forward is zero: the surface is fresh, so the write
    // path rejects it (a zero forward would make basis/forward math degenerate).
    feed.update_from_bs(bs_update(BTC_UNDERLYING, EXPIRY_A, T_EARLY, SPOT, 0), &clock);

    abort 999
}

#[test, expected_failure(abort_code = block_scholes_feed::EInvalidSviRho)]
fun update_rho_above_one_aborts() {
    let (mut scenario, feed_obj_id) = setup_feed();
    let mut feed = scenario.take_shared_by_id<BlockScholesFeed>(feed_obj_id);
    let mut clock = clock::create_for_testing(scenario.ctx());
    clock.set_for_testing(LANDED_HIGH);

    // |rho| = 1.0 + 1 ulp > 1 violates the SVI no-arbitrage bound.
    feed.update_from_bs(
        svi_update(SPOT, FORWARD_A, SVI_SIGMA, FLOAT_SCALING + 1, M_MAG),
        &clock,
    );

    abort 999
}

#[test, expected_failure(abort_code = block_scholes_feed::EInvalidSviSigma)]
fun update_sigma_below_min_aborts() {
    let (mut scenario, feed_obj_id) = setup_feed();
    let mut feed = scenario.take_shared_by_id<BlockScholesFeed>(feed_obj_id);
    let mut clock = clock::create_for_testing(scenario.ctx());
    clock.set_for_testing(LANDED_HIGH);

    feed.update_from_bs(svi_update(SPOT, FORWARD_A, SIGMA_MIN - 1, RHO_MAG, M_MAG), &clock);

    abort 999
}

#[test, expected_failure(abort_code = block_scholes_feed::EInvalidSviSigma)]
fun update_sigma_above_max_aborts() {
    let (mut scenario, feed_obj_id) = setup_feed();
    let mut feed = scenario.take_shared_by_id<BlockScholesFeed>(feed_obj_id);
    let mut clock = clock::create_for_testing(scenario.ctx());
    clock.set_for_testing(LANDED_HIGH);

    feed.update_from_bs(svi_update(SPOT, FORWARD_A, SIGMA_MAX + 1, RHO_MAG, M_MAG), &clock);

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

// EWrongVersion on the BS path is enforced by the version gate in `update_from_bs`;
// re-exercising it needs a test seam to corrupt the feed's stored version, and the
// seam count is intentionally minimized, so it is not retested here.

/// Build a single-expiry stub BS Update with the shared valid SVI fixture.
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

/// Build a BTC@EXPIRY_A update at T_EARLY with explicit SVI sigma/rho/m for the
/// surface-validity guard tests.
fun svi_update(spot: u64, forward: u64, sigma: u64, rho_mag: u64, m_mag: u64): Update {
    update::new_update(
        BTC_UNDERLYING,
        EXPIRY_A,
        T_EARLY,
        spot,
        forward,
        SVI_A,
        SVI_B,
        sigma,
        rho_mag,
        RHO_NEG,
        m_mag,
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
