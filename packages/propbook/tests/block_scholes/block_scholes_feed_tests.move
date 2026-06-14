// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module propbook::block_scholes_feed_tests;

use block_scholes_oracle::update::{Self, Update};
use propbook::{
    block_scholes_feed::{Self, BlockScholesFeed},
    oracle_lane,
    registry::{Self, OracleRegistry}
};
use std::unit_test::assert_eq;
use sui::{clock, test_scenario::{Self as test, Scenario, return_shared}};

const ADMIN: address = @0xAD;
const BS_SOURCE_ID: u32 = 1;
const OTHER_BS_SOURCE_ID: u32 = 2;
/// A numeric id used for BOTH a Pyth and a BS feed to prove kinds don't collide.
const SHARED_SOURCE_ID: u32 = 7;

const SPOT: u64 = 50_000_000_000_000; // 50_000 * 1e9
const SPOT_LATER: u64 = 49_000_000_000_000; // 49_000 * 1e9

const EXPIRY_A: u64 = 1_700_100_000_000;
const EXPIRY_B: u64 = 1_700_200_000_000;
const FORWARD_A: u64 = 50_500_000_000_000;
const FORWARD_B: u64 = 49_000_000_000_000;
const FORWARD_A2: u64 = 50_600_000_000_000;
const UNKNOWN_EXPIRY: u64 = 9_999_999_999;

const SVI_A: u64 = 40_000_000;
const SVI_B: u64 = 120_000_000;
const SVI_SIGMA: u64 = 90_000_000;
const RHO_MAG: u64 = 300_000_000;
const RHO_NEG: bool = true;
const M_MAG: u64 = 25_000_000;
const M_NEG: bool = false;
const FLOAT_SCALING: u64 = 1_000_000_000;

const PUBLISHED_MS: u64 = 420_123;
const LANDED_MS: u64 = 420_173;
const LANDED_HIGH: u64 = 1_000_000;
const T_EARLY: u64 = 100;
const T_MID: u64 = 150;
const T_LATE: u64 = 200;
const T_SAME: u64 = 300;
const VERSION_ZERO: u64 = 0;

#[test]
fun update_from_bs_records_source_observation_and_surface() {
    let (mut scenario, feed_obj_id) = setup_feed();
    let mut feed = scenario.take_shared_by_id<BlockScholesFeed>(feed_obj_id);
    let mut clock = clock::create_for_testing(scenario.ctx());
    clock.set_for_testing(LANDED_MS);

    feed.update_from_bs(
        bs_update(BS_SOURCE_ID, EXPIRY_A, PUBLISHED_MS, SPOT, FORWARD_A),
        &clock,
        scenario.ctx(),
    );

    assert_eq!(feed.bs_source_id(), BS_SOURCE_ID);
    assert!(feed.has_observation(EXPIRY_A, PUBLISHED_MS));

    let first_observed = feed.observation_at_minute(EXPIRY_A, PUBLISHED_MS);
    assert_eq!(block_scholes_feed::observation_bs_source_id(&first_observed), BS_SOURCE_ID);
    assert_eq!(block_scholes_feed::observation_expiry_ms(&first_observed), EXPIRY_A);
    assert_eq!(block_scholes_feed::observation_spot(&first_observed), SPOT);
    assert_eq!(block_scholes_feed::observation_forward(&first_observed), FORWARD_A);
    assert_eq!(block_scholes_feed::observation_source_timestamp_ms(&first_observed), PUBLISHED_MS);
    assert_eq!(block_scholes_feed::observation_update_timestamp_ms(&first_observed), LANDED_MS);

    assert!(feed.has_expiry(EXPIRY_A));
    assert_eq!(feed.spot(EXPIRY_A), SPOT);
    assert_eq!(feed.forward(EXPIRY_A), FORWARD_A);
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
    let (mut scenario, feed_obj_id) = setup_feed();
    let mut feed = scenario.take_shared_by_id<BlockScholesFeed>(feed_obj_id);
    let mut clock = clock::create_for_testing(scenario.ctx());
    clock.set_for_testing(LANDED_HIGH);

    feed.update_from_bs(
        bs_update(BS_SOURCE_ID, EXPIRY_A, T_SAME, SPOT, FORWARD_A),
        &clock,
        scenario.ctx(),
    );
    feed.update_from_bs(
        bs_update(BS_SOURCE_ID, EXPIRY_B, T_SAME, SPOT, FORWARD_B),
        &clock,
        scenario.ctx(),
    );

    assert!(feed.has_expiry(EXPIRY_A));
    assert!(feed.has_expiry(EXPIRY_B));
    assert_eq!(feed.forward(EXPIRY_A), FORWARD_A);
    assert_eq!(feed.forward(EXPIRY_B), FORWARD_B);
    assert_eq!(
        block_scholes_feed::observation_forward(
            &feed.observation_at_minute(EXPIRY_A, T_SAME),
        ),
        FORWARD_A,
    );
    assert_eq!(
        block_scholes_feed::observation_forward(
            &feed.observation_at_minute(EXPIRY_B, T_SAME),
        ),
        FORWARD_B,
    );

    clock.destroy_for_testing();
    return_shared(feed);
    scenario.end();
}

#[test]
fun per_expiry_latest_advances_but_first_observed_bucket_stays_first() {
    let (mut scenario, feed_obj_id) = setup_feed();
    let mut feed = scenario.take_shared_by_id<BlockScholesFeed>(feed_obj_id);
    let mut clock = clock::create_for_testing(scenario.ctx());
    clock.set_for_testing(LANDED_HIGH);

    feed.update_from_bs(
        bs_update(BS_SOURCE_ID, EXPIRY_A, T_EARLY, SPOT, FORWARD_A),
        &clock,
        scenario.ctx(),
    );
    feed.update_from_bs(
        bs_update(BS_SOURCE_ID, EXPIRY_B, T_LATE, SPOT, FORWARD_B),
        &clock,
        scenario.ctx(),
    );
    feed.update_from_bs(
        bs_update(BS_SOURCE_ID, EXPIRY_A, T_MID, SPOT_LATER, FORWARD_A2),
        &clock,
        scenario.ctx(),
    );

    assert_eq!(feed.spot(EXPIRY_A), SPOT_LATER);
    assert_eq!(feed.forward(EXPIRY_A), FORWARD_A2);
    assert_eq!(feed.surface_freshness_timestamp_ms(EXPIRY_A), T_MID);
    assert_eq!(feed.spot(EXPIRY_B), SPOT);
    assert_eq!(feed.forward(EXPIRY_B), FORWARD_B);
    assert_eq!(feed.surface_freshness_timestamp_ms(EXPIRY_B), T_LATE);

    assert_eq!(
        block_scholes_feed::observation_spot(
            &feed.observation_at_minute(EXPIRY_A, T_EARLY),
        ),
        SPOT,
    );
    assert_eq!(
        block_scholes_feed::observation_spot(
            &feed.observation_at_minute(EXPIRY_B, T_LATE),
        ),
        SPOT,
    );

    clock.destroy_for_testing();
    return_shared(feed);
    scenario.end();
}

#[test, expected_failure(abort_code = oracle_lane::EStaleSourceUpdate)]
fun same_expiry_stale_resend_aborts() {
    let (mut scenario, feed_obj_id) = setup_feed();
    let mut feed = scenario.take_shared_by_id<BlockScholesFeed>(feed_obj_id);
    let mut clock = clock::create_for_testing(scenario.ctx());
    clock.set_for_testing(LANDED_HIGH);

    feed.update_from_bs(
        bs_update(BS_SOURCE_ID, EXPIRY_A, T_SAME, SPOT, FORWARD_A),
        &clock,
        scenario.ctx(),
    );
    feed.update_from_bs(
        bs_update(BS_SOURCE_ID, EXPIRY_A, T_SAME, SPOT_LATER, FORWARD_A2),
        &clock,
        scenario.ctx(),
    );

    abort 999
}

#[test]
fun has_expiry_reflects_live_observation_rows() {
    let (mut scenario, feed_obj_id) = setup_feed();
    let mut feed = scenario.take_shared_by_id<BlockScholesFeed>(feed_obj_id);
    let mut clock = clock::create_for_testing(scenario.ctx());
    clock.set_for_testing(LANDED_MS);

    feed.update_from_bs(
        bs_update(BS_SOURCE_ID, EXPIRY_A, PUBLISHED_MS, SPOT, FORWARD_A),
        &clock,
        scenario.ctx(),
    );

    assert!(feed.has_expiry(EXPIRY_A));
    assert!(!feed.has_expiry(EXPIRY_B));
    assert!(!feed.has_expiry(UNKNOWN_EXPIRY));

    clock.destroy_for_testing();
    return_shared(feed);
    scenario.end();
}

#[test]
fun official_settlement_records_exact_resolution_without_latest() {
    let (mut scenario, feed_obj_id) = setup_feed();
    let mut feed = scenario.take_shared_by_id<BlockScholesFeed>(feed_obj_id);
    let mut clock = clock::create_for_testing(scenario.ctx());
    clock.set_for_testing(LANDED_HIGH);

    feed.record_official_settlement_from_bs(
        bs_update(BS_SOURCE_ID, EXPIRY_A, T_EARLY, SPOT, FORWARD_A),
        &clock,
        scenario.ctx(),
    );

    assert!(!feed.has_expiry(EXPIRY_A));
    assert!(!feed.has_observation(EXPIRY_A, T_EARLY));
    assert!(feed.has_official_settlement(EXPIRY_A, T_EARLY));
    assert!(!feed.has_official_settlement(EXPIRY_A, T_EARLY + 1));

    let settlement = feed.official_observation_at_resolution(EXPIRY_A, T_EARLY);
    assert_eq!(block_scholes_feed::observation_spot(&settlement), SPOT);
    assert_eq!(block_scholes_feed::observation_forward(&settlement), FORWARD_A);
    assert_eq!(block_scholes_feed::observation_source_timestamp_ms(&settlement), T_EARLY);

    clock.destroy_for_testing();
    return_shared(feed);
    scenario.end();
}

#[test]
fun registry_records_bs_source_feed() {
    let (scenario, feed_obj_id) = setup_feed();
    let registry = scenario.take_shared<OracleRegistry>();

    assert!(registry.contains_block_scholes_source(BS_SOURCE_ID));
    assert_eq!(
        registry.propbook_block_scholes_id_for_source(BS_SOURCE_ID).destroy_some(),
        feed_obj_id,
    );

    return_shared(registry);
    scenario.end();
}

#[test]
fun pyth_and_bs_share_numeric_source_id_across_kinds() {
    let mut scenario = test::begin(ADMIN);
    registry::init_for_testing(scenario.ctx());
    scenario.next_tx(ADMIN);
    let mut registry = scenario.take_shared<OracleRegistry>();

    let bs_id = registry::create_and_share_block_scholes_feed(
        &mut registry,
        SHARED_SOURCE_ID,
        scenario.ctx(),
    );
    let pyth_id = registry::create_and_share_pyth_feed(
        &mut registry,
        SHARED_SOURCE_ID,
        scenario.ctx(),
    );

    assert!(bs_id != pyth_id);
    assert_eq!(
        registry.propbook_block_scholes_id_for_source(SHARED_SOURCE_ID).destroy_some(),
        bs_id,
    );
    assert_eq!(registry.propbook_pyth_id_for_source(SHARED_SOURCE_ID).destroy_some(), pyth_id);

    return_shared(registry);
    scenario.end();
}

#[test, expected_failure(abort_code = registry::ESourceAlreadyExists)]
fun create_duplicate_source_aborts() {
    let (mut scenario, _feed_obj_id) = setup_feed();
    let mut registry = scenario.take_shared<OracleRegistry>();

    registry::create_and_share_block_scholes_feed(&mut registry, BS_SOURCE_ID, scenario.ctx());

    abort 999
}

#[test, expected_failure(abort_code = block_scholes_feed::EWrongSource)]
fun update_wrong_source_aborts() {
    let (mut scenario, feed_obj_id) = setup_feed();
    let mut feed = scenario.take_shared_by_id<BlockScholesFeed>(feed_obj_id);
    let mut clock = clock::create_for_testing(scenario.ctx());
    clock.set_for_testing(LANDED_HIGH);

    feed.update_from_bs(
        bs_update(OTHER_BS_SOURCE_ID, EXPIRY_A, T_EARLY, SPOT, FORWARD_A),
        &clock,
        scenario.ctx(),
    );

    abort 999
}

#[test, expected_failure(abort_code = oracle_lane::EFutureSourceUpdate)]
fun update_future_source_aborts() {
    let (mut scenario, feed_obj_id) = setup_feed();
    let mut feed = scenario.take_shared_by_id<BlockScholesFeed>(feed_obj_id);
    let mut clock = clock::create_for_testing(scenario.ctx());
    clock.set_for_testing(T_EARLY);

    feed.update_from_bs(
        bs_update(BS_SOURCE_ID, EXPIRY_A, T_LATE, SPOT, FORWARD_A),
        &clock,
        scenario.ctx(),
    );

    abort 999
}

#[test, expected_failure(abort_code = block_scholes_feed::EWrongVersion)]
fun update_wrong_version_aborts() {
    let (mut scenario, feed_obj_id) = setup_feed();
    let mut feed = scenario.take_shared_by_id<BlockScholesFeed>(feed_obj_id);
    let mut clock = clock::create_for_testing(scenario.ctx());
    clock.set_for_testing(LANDED_HIGH);

    feed.set_version_for_testing(VERSION_ZERO);
    feed.update_from_bs(
        bs_update(BS_SOURCE_ID, EXPIRY_A, T_EARLY, SPOT, FORWARD_A),
        &clock,
        scenario.ctx(),
    );

    abort 999
}

#[test]
fun migrate_restores_current_version_and_updates_resume() {
    let (mut scenario, feed_obj_id) = setup_feed();
    let mut feed = scenario.take_shared_by_id<BlockScholesFeed>(feed_obj_id);
    let mut clock = clock::create_for_testing(scenario.ctx());
    clock.set_for_testing(LANDED_HIGH);

    feed.set_version_for_testing(VERSION_ZERO);
    feed.migrate();
    assert_eq!(feed.version(), propbook::constants::current_version!());
    feed.update_from_bs(
        bs_update(BS_SOURCE_ID, EXPIRY_A, T_EARLY, SPOT, FORWARD_A),
        &clock,
        scenario.ctx(),
    );
    assert_eq!(feed.spot(EXPIRY_A), SPOT);

    clock.destroy_for_testing();
    return_shared(feed);
    scenario.end();
}

#[test, expected_failure(abort_code = block_scholes_feed::ENotNewerVersion)]
fun migrate_current_version_aborts() {
    let (scenario, feed_obj_id) = setup_feed();
    let mut feed = scenario.take_shared_by_id<BlockScholesFeed>(feed_obj_id);

    feed.migrate();

    abort 999
}

#[test]
fun update_accepts_raw_surface_without_pricing_envelope_validation() {
    let (mut scenario, feed_obj_id) = setup_feed();
    let mut feed = scenario.take_shared_by_id<BlockScholesFeed>(feed_obj_id);
    let mut clock = clock::create_for_testing(scenario.ctx());
    clock.set_for_testing(LANDED_HIGH);

    feed.update_from_bs(
        update::new_update(
            BS_SOURCE_ID,
            EXPIRY_A,
            T_EARLY,
            0,
            0,
            SVI_A,
            SVI_B,
            0,
            FLOAT_SCALING + 1,
            RHO_NEG,
            FLOAT_SCALING + 2,
            M_NEG,
        ),
        &clock,
        scenario.ctx(),
    );

    assert!(feed.has_expiry(EXPIRY_A));
    assert_eq!(feed.spot(EXPIRY_A), 0);
    assert_eq!(feed.forward(EXPIRY_A), 0);
    let svi0 = feed.svi(EXPIRY_A);
    assert_eq!(svi0.sigma(), 0);
    assert_eq!(svi0.rho().magnitude(), FLOAT_SCALING + 1);
    assert_eq!(svi0.m().magnitude(), FLOAT_SCALING + 2);

    clock.destroy_for_testing();
    return_shared(feed);
    scenario.end();
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

/// Build a single-expiry stub BS Update with the shared valid SVI fixture.
fun bs_update(source_id: u32, expiry: u64, published: u64, spot: u64, forward: u64): Update {
    update::new_update(
        source_id,
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

/// Initialize the package, create+share a BS feed through the registry, and
/// advance so the shared feed is takeable. Returns the scenario and feed id.
fun setup_feed(): (Scenario, ID) {
    let mut scenario = test::begin(ADMIN);
    registry::init_for_testing(scenario.ctx());
    scenario.next_tx(ADMIN);

    let mut registry = scenario.take_shared<OracleRegistry>();
    let feed_obj_id = registry::create_and_share_block_scholes_feed(
        &mut registry,
        BS_SOURCE_ID,
        scenario.ctx(),
    );
    return_shared(registry);
    scenario.next_tx(ADMIN);

    (scenario, feed_obj_id)
}
