// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Lifecycle-cap allowlist coverage: `registry::mint_lifecycle_cap` /
/// `registry::revoke_lifecycle_cap` and the `ELifecycleCapNotValid` gate on
/// `registry::create_expiry_market`, plus the writer-cap set seeded at market
/// creation (unseeded cap rejection, duplicate ids, empty set + later admin
/// registration).
#[test_only]
module deepbook_predict::lifecycle_cap_tests;

use deepbook_predict::{
    admin::{Self, AdminCap},
    market_lifecycle_cap::MarketLifecycleCap,
    market_oracle::{Self, MarketOracle},
    market_oracle_writer_cap,
    oracle_fixture::{Self, OracleFixture},
    plp::PoolVault,
    protocol_config::ProtocolConfig,
    pyth_source::PythSource,
    registry::{Self, Registry},
    test_constants,
    test_helpers
};
use std::unit_test::{assert_eq, destroy};
use sui::{clock, test_scenario::{Self as test, Scenario, return_shared}};

/// Added to the fixture's `default_expiry_ms` so the second market's expiry is
/// unique (the fixture already created a market at the default expiry).
const SECOND_EXPIRY_OFFSET_MS: u64 = 100_000;

/// 1.01 x default_live_price (100e9): a forward distinct from the spot so the
/// getter assertions pin both stored fields independently.
const ONE_PCT_ABOVE_LIVE_PRICE: u64 = 101_000_000_000;

const EUnexpectedSuccess: u64 = 999;

// === Lifecycle-cap allowlist gates ===

#[test, expected_failure(abort_code = registry::ELifecycleCapNotValid)]
fun create_with_revoked_lifecycle_cap_aborts() {
    let mut fx = oracle_fixture::setup_oracle_default();
    let admin_cap = admin::new(fx.scenario_mut().ctx());
    let writer_cap = market_oracle_writer_cap::create(&admin_cap, fx.scenario_mut().ctx());
    let revoked_cap = mint_lifecycle_cap(&mut fx, &admin_cap);
    revoke_lifecycle_cap(&mut fx, &admin_cap, revoked_cap.id());
    let (_expiry_id, _oracle_id) = create_second_market(
        &mut fx,
        &revoked_cap,
        vector[writer_cap.id()],
    );
    abort EUnexpectedSuccess
}

#[test, expected_failure(abort_code = registry::ELifecycleCapNotFound)]
fun revoke_unknown_lifecycle_cap_aborts() {
    let (_scenario, mut registry, admin_cap) = test_helpers::begin_registry_test();
    // An id that was never minted into the allowlist.
    registry::revoke_lifecycle_cap(&mut registry, &admin_cap, object::id_from_address(@0xCAFE));
    abort EUnexpectedSuccess
}

#[test]
fun destroy_lifecycle_cap_does_not_revoke() {
    let (mut scenario, mut registry, admin_cap) = test_helpers::begin_registry_test();
    let cap = registry::mint_lifecycle_cap(&mut registry, &admin_cap, scenario.ctx());
    let other_cap = registry::mint_lifecycle_cap(&mut registry, &admin_cap, scenario.ctx());
    let destroyed_id = cap.id();
    cap.destroy();
    // Destroying the cap object must not touch the registry allowlist: the id is
    // still allow-listed, so revoking it by the copied id succeeds (revoke
    // aborts ELifecycleCapNotValid for ids not in the set).
    registry::revoke_lifecycle_cap(&mut registry, &admin_cap, destroyed_id);
    // Post-state: revoking the destroyed cap's id leaves other allow-listed
    // caps valid.
    registry::revoke_lifecycle_cap(&mut registry, &admin_cap, other_cap.id());
    other_cap.destroy();
    destroy(admin_cap);
    return_shared(registry);
    scenario.end();
}

// === Writer-cap seeding at market creation ===

#[test, expected_failure(abort_code = market_oracle::EInvalidMarketOracleWriterCap)]
fun update_prices_with_unseeded_writer_cap_aborts() {
    let mut fx = oracle_fixture::setup_oracle_default();
    let admin_cap = admin::new(fx.scenario_mut().ctx());
    // The fixture market's writer set was seeded with only the fixture cap at
    // creation; a second admin-created cap is not authorized.
    let unseeded_cap = market_oracle_writer_cap::create(&admin_cap, fx.scenario_mut().ctx());
    let (_pyth, mut oracle, _config) = fx.take_oracle();
    oracle.update_block_scholes_prices(
        &unseeded_cap,
        test_constants::default_live_price(),
        test_constants::default_live_price(),
        test_constants::live_source_timestamp_ms(),
        fx.clock(),
    );
    abort EUnexpectedSuccess
}

#[test, expected_failure(abort_code = sui::vec_set::EKeyAlreadyExists)]
fun duplicate_writer_cap_ids_abort() {
    let mut fx = oracle_fixture::setup_oracle_default();
    let admin_cap = admin::new(fx.scenario_mut().ctx());
    let writer_cap = market_oracle_writer_cap::create(&admin_cap, fx.scenario_mut().ctx());
    let lifecycle_cap = mint_lifecycle_cap(&mut fx, &admin_cap);
    let (_expiry_id, _oracle_id) = create_second_market(
        &mut fx,
        &lifecycle_cap,
        vector[writer_cap.id(), writer_cap.id()],
    );
    abort EUnexpectedSuccess
}

#[test, expected_failure(abort_code = market_oracle::EInvalidMarketOracleWriterCap)]
fun empty_writer_set_update_aborts() {
    let mut fx = oracle_fixture::setup_oracle_default();
    let admin_cap = admin::new(fx.scenario_mut().ctx());
    let writer_cap = market_oracle_writer_cap::create(&admin_cap, fx.scenario_mut().ctx());
    let lifecycle_cap = mint_lifecycle_cap(&mut fx, &admin_cap);
    let (_expiry_id, oracle_id) = create_second_market(&mut fx, &lifecycle_cap, vector[]);

    let mut oracle = fx.scenario_mut().take_shared_by_id<MarketOracle>(oracle_id);
    let _config = fx.scenario_mut().take_shared<ProtocolConfig>();
    // The writer set is empty: even an admin-created cap cannot write until
    // the admin registers it on this oracle.
    oracle.update_block_scholes_prices(
        &writer_cap,
        test_constants::default_live_price(),
        test_constants::default_live_price(),
        test_constants::live_source_timestamp_ms(),
        fx.clock(),
    );
    abort EUnexpectedSuccess
}

#[test]
fun empty_writer_set_then_admin_registers() {
    let mut fx = oracle_fixture::setup_oracle_default();
    let admin_cap = admin::new(fx.scenario_mut().ctx());
    let writer_cap = market_oracle_writer_cap::create(&admin_cap, fx.scenario_mut().ctx());
    let lifecycle_cap = mint_lifecycle_cap(&mut fx, &admin_cap);
    let (_expiry_id, oracle_id) = create_second_market(&mut fx, &lifecycle_cap, vector[]);

    let mut oracle = fx.scenario_mut().take_shared_by_id<MarketOracle>(oracle_id);
    let config = fx.scenario_mut().take_shared<ProtocolConfig>();
    oracle.register_writer_cap(&admin_cap, writer_cap.id());
    oracle.update_block_scholes_prices(
        &writer_cap,
        test_constants::default_live_price(),
        ONE_PCT_ABOVE_LIVE_PRICE,
        test_constants::live_source_timestamp_ms(),
        fx.clock(),
    );
    assert_eq!(oracle.block_scholes_spot(), test_constants::default_live_price());
    assert_eq!(oracle.block_scholes_forward(), ONE_PCT_ABOVE_LIVE_PRICE);

    return_shared(oracle);
    return_shared(config);
    lifecycle_cap.destroy();
    writer_cap.destroy();
    destroy(admin_cap);
    fx.finish();
}

// === Helpers ===

/// Mint a lifecycle cap onto the fixture's shared registry through the admin path.
fun mint_lifecycle_cap(fx: &mut OracleFixture, admin_cap: &AdminCap): MarketLifecycleCap {
    let scenario = fx.scenario_mut();
    let mut registry = scenario.take_shared<Registry>();
    let cap = registry::mint_lifecycle_cap(&mut registry, admin_cap, scenario.ctx());
    return_shared(registry);
    scenario.next_tx(test_constants::admin());
    cap
}

/// Revoke `lifecycle_cap_id` from the fixture's shared registry allowlist.
fun revoke_lifecycle_cap(fx: &mut OracleFixture, admin_cap: &AdminCap, lifecycle_cap_id: ID) {
    let scenario = fx.scenario_mut();
    let mut registry = scenario.take_shared<Registry>();
    registry::revoke_lifecycle_cap(&mut registry, admin_cap, lifecycle_cap_id);
    return_shared(registry);
    scenario.next_tx(test_constants::admin());
}

/// Create a second expiry market (the fixture already created one at the
/// default expiry) through the production registry path, with a caller-chosen
/// lifecycle cap and writer-cap id vector.
fun create_second_market(
    fx: &mut OracleFixture,
    lifecycle_cap: &MarketLifecycleCap,
    writer_cap_ids: vector<ID>,
): (ID, ID) {
    let pyth_id = fx.pyth_id();
    let scenario = fx.scenario_mut();
    let mut clock = clock::create_for_testing(scenario.ctx());
    clock.set_for_testing(test_constants::now_ms());
    let mut registry = scenario.take_shared<Registry>();
    let mut vault = scenario.take_shared<PoolVault>();
    let config = scenario.take_shared<ProtocolConfig>();
    let pyth = scenario.take_shared_by_id<PythSource>(pyth_id);
    let (expiry_id, oracle_id) = registry::create_expiry_market(
        &mut registry,
        &mut vault,
        &config,
        &pyth,
        lifecycle_cap,
        writer_cap_ids,
        test_constants::default_expiry_ms() + SECOND_EXPIRY_OFFSET_MS,
        &clock,
        scenario.ctx(),
    );
    clock.destroy_for_testing();
    return_shared(config);
    return_shared(registry);
    return_shared(vault);
    return_shared(pyth);
    scenario.next_tx(test_constants::admin());
    (expiry_id, oracle_id)
}
