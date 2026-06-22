// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Lifecycle-cap allowlist coverage: `registry::mint_lifecycle_cap` /
/// `registry::revoke_lifecycle_cap`, the `ELifecycleCapNotValid` gate on
/// `registry::create_expiry_market`, and that destroying a cap leaves the
/// allowlist untouched.
#[test_only]
module deepbook_predict::lifecycle_cap_tests;

use deepbook_predict::{
    admin::{Self, AdminCap},
    market_lifecycle_cap::MarketLifecycleCap,
    oracle_fixture::{Self, OracleFixture},
    plp::PoolVault,
    protocol_config::ProtocolConfig,
    registry::{Self, Registry},
    test_constants,
    test_helpers
};
use propbook::registry::OracleRegistry;
use std::unit_test::destroy;
use sui::{clock, test_scenario::return_shared};

const EUnexpectedSuccess: u64 = 999;

// === Lifecycle-cap allowlist gates ===

#[test, expected_failure(abort_code = registry::ELifecycleCapNotValid)]
fun create_with_revoked_lifecycle_cap_aborts() {
    let mut fx = oracle_fixture::setup_oracle_default();
    let admin_cap = admin::new(fx.scenario_mut().ctx());
    let revoked_cap = mint_lifecycle_cap(&mut fx, &admin_cap);
    revoke_lifecycle_cap(&mut fx, &admin_cap, revoked_cap.id());
    let _expiry_id = create_second_market(&mut fx, &revoked_cap);
    abort EUnexpectedSuccess
}

#[test, expected_failure(abort_code = registry::ELifecycleCapNotValid)]
fun generate_proof_with_revoked_lifecycle_cap_aborts() {
    let mut fx = oracle_fixture::setup_oracle_default();
    let admin_cap = admin::new(fx.scenario_mut().ctx());
    let revoked_cap = mint_lifecycle_cap(&mut fx, &admin_cap);
    revoke_lifecycle_cap(&mut fx, &admin_cap, revoked_cap.id());

    let scenario = fx.scenario_mut();
    let registry = scenario.take_shared<Registry>();
    let proof = registry.generate_lifecycle_proof(&revoked_cap);
    proof.destroy_proof();

    abort EUnexpectedSuccess
}

#[test, expected_failure(abort_code = registry::ELifecycleCapNotFound)]
fun revoke_unknown_lifecycle_cap_aborts() {
    let (_scenario, mut registry, _config, admin_cap) = test_helpers::begin_registry_test();
    // An id that was never minted into the allowlist.
    registry.revoke_lifecycle_cap(&admin_cap, object::id_from_address(@0xCAFE));
    abort EUnexpectedSuccess
}

#[test]
fun destroy_lifecycle_cap_does_not_revoke() {
    let (mut scenario, mut registry, config, admin_cap) = test_helpers::begin_registry_test();
    let cap = registry.mint_lifecycle_cap(&config, &admin_cap, scenario.ctx());
    let other_cap = registry.mint_lifecycle_cap(
        &config,
        &admin_cap,
        scenario.ctx(),
    );
    let destroyed_id = cap.id();
    cap.destroy();
    // Destroying the cap object must not touch the registry allowlist: the id is
    // still allow-listed, so revoking it by the copied id succeeds (revoke
    // aborts ELifecycleCapNotFound for ids not in the set).
    registry.revoke_lifecycle_cap(&admin_cap, destroyed_id);
    // Post-state: revoking the destroyed cap's id leaves other allow-listed
    // caps valid.
    registry.revoke_lifecycle_cap(&admin_cap, other_cap.id());
    other_cap.destroy();
    destroy(admin_cap);
    return_shared(registry);
    return_shared(config);
    scenario.end();
}

// === Helpers ===

/// Mint a lifecycle cap onto the fixture's shared registry through the admin path.
fun mint_lifecycle_cap(fx: &mut OracleFixture, admin_cap: &AdminCap): MarketLifecycleCap {
    let scenario = fx.scenario_mut();
    let mut registry = scenario.take_shared<Registry>();
    let config = scenario.take_shared<ProtocolConfig>();
    let cap = registry.mint_lifecycle_cap(&config, admin_cap, scenario.ctx());
    return_shared(config);
    return_shared(registry);
    scenario.next_tx(test_constants::admin());
    cap
}

/// Revoke `lifecycle_cap_id` from the fixture's shared registry allowlist.
fun revoke_lifecycle_cap(fx: &mut OracleFixture, admin_cap: &AdminCap, lifecycle_cap_id: ID) {
    let scenario = fx.scenario_mut();
    let mut registry = scenario.take_shared<Registry>();
    registry.revoke_lifecycle_cap(admin_cap, lifecycle_cap_id);
    return_shared(registry);
    scenario.next_tx(test_constants::admin());
}

/// Attempt market creation through the production registry path with a
/// caller-chosen lifecycle cap. Revoked-cap tests abort before cadence logic.
fun create_second_market(fx: &mut OracleFixture, lifecycle_cap: &MarketLifecycleCap): ID {
    let scenario = fx.scenario_mut();
    let mut clock = clock::create_for_testing(scenario.ctx());
    clock.set_for_testing(test_constants::now_ms());
    let mut registry = scenario.take_shared<Registry>();
    let mut vault = scenario.take_shared<PoolVault>();
    let oracle_registry = scenario.take_shared<OracleRegistry>();
    let config = scenario.take_shared<ProtocolConfig>();
    let expiry_id = registry.create_expiry_market(
        &mut vault,
        &config,
        &oracle_registry,
        lifecycle_cap,
        test_constants::propbook_underlying_id(),
        test_constants::default_cadence_id(),
        &clock,
        scenario.ctx(),
    );
    clock.destroy_for_testing();
    return_shared(config);
    return_shared(oracle_registry);
    return_shared(registry);
    return_shared(vault);
    scenario.next_tx(test_constants::admin());
    expiry_id
}
