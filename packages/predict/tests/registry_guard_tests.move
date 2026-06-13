// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Guard coverage for the registry's creation/version/pause abort codes plus
/// `predict_manager::EMaxCapsReached`.
///
/// Not covered here:
/// - `builder_code::ENotOwner` is only reachable through
///   `claim_all_builder_fees`, which takes `&sui::accumulator::AccumulatorRoot`.
///   At the pinned framework rev that object is created exclusively by the
///   system (`sui::accumulator::create` is private and requires sender `@0x0`)
///   and has no `#[test_only]` constructor or `test_scenario` provisioning, so
///   the path cannot be exercised in a Move unit test.
/// - `predict_manager::EMaxCapsReached` requires `MAX_CAPS` (1000) prior cap
///   mints on one manager. Each mint inserts into the `allow_listed` `VecSet`
///   (a linear scan), so filling the set costs quadratic gas and exceeds the
///   suite's standard `--gas-limit 100000000000` before the guard can fire
///   (verified empirically: 750 mints fit, 1000 run out of gas inside
///   `vec_set::insert`).
#[test_only]
module deepbook_predict::registry_guard_tests;

use deepbook_predict::{
    constants,
    flow_test_helpers,
    market_oracle_writer_cap,
    plp::{Self, PoolVault},
    protocol_config::ProtocolConfig,
    pyth_source::{Self, PythSource},
    registry::{Self, Registry},
    test_constants,
    test_helpers
};
use sui::{clock, test_scenario::return_shared};

// === create_expiry_market ===

#[test, expected_failure(abort_code = registry::EInvalidExpiry)]
fun create_expiry_market_with_expiry_at_now_aborts() {
    let mut fx = flow_test_helpers::setup_market_default();

    // Boundary: expiry == clock.timestamp_ms() fails the strict `expiry > now`.
    let (_expiry_id, _oracle_id) = fx.create_expiry(test_constants::now_ms());
    abort 999
}

#[test, expected_failure(abort_code = registry::EExpiryMarketAlreadyCreated)]
fun create_expiry_market_duplicate_expiry_aborts() {
    let mut fx = flow_test_helpers::setup_market_default();

    let (_expiry_id, _oracle_id) = fx.create_expiry(test_constants::default_expiry_ms());
    let (_dup_id, _dup_oracle_id) = fx.create_expiry(test_constants::default_expiry_ms());
    abort 999
}

#[test, expected_failure(abort_code = registry::EFeedIdMismatch)]
fun create_expiry_market_with_wrong_pyth_source_object_aborts() {
    let (mut scenario, mut reg, admin_cap) = test_helpers::begin_registry_test();
    plp::init_for_testing(scenario.ctx());
    registry::create_pyth_source(
        &mut reg,
        &admin_cap,
        test_constants::pyth_feed_id(),
        test_constants::default_tick_size(),
        scenario.ctx(),
    );
    // A second source claiming the registered feed id, created outside the
    // registry, so its object ID differs from the registered config's source.
    // Registry feed uniqueness means every registry-created source matches its
    // own config, so this state is only constructible through the package
    // constructor — the test pins the object-identity guard (defense-in-depth
    // against any future non-registry creation path) at the unit level.
    let rogue_pyth_id = pyth_source::create_and_share(
        test_constants::pyth_feed_id(),
        reg.allowed_versions(),
        scenario.ctx(),
    );
    let oracle_cap = market_oracle_writer_cap::create(&admin_cap, scenario.ctx());
    let clock = clock::create_for_testing(scenario.ctx());
    let registry_id = reg.id();
    return_shared(reg);

    scenario.next_tx(test_constants::admin());
    let mut reg = scenario.take_shared_by_id<Registry>(registry_id);
    let vault = scenario.take_shared<PoolVault>();
    let config = scenario.take_shared<ProtocolConfig>();
    let rogue_pyth = scenario.take_shared_by_id<PythSource>(rogue_pyth_id);
    let lifecycle_cap = registry::mint_lifecycle_cap(&mut reg, &admin_cap, scenario.ctx());
    let (_expiry_id, _oracle_id) = registry::create_expiry_market(
        &mut reg,
        &vault,
        &config,
        &rogue_pyth,
        &lifecycle_cap,
        vector[oracle_cap.id()],
        test_constants::default_expiry_ms(),
        &clock,
        scenario.ctx(),
    );
    abort 999
}

// === PauseCap ===

#[test, expected_failure(abort_code = registry::EPauseCapNotValid)]
fun revoked_pause_cap_cannot_disable_version() {
    let (mut scenario, mut reg, admin_cap) = test_helpers::begin_registry_test();

    let pause_cap = registry::mint_pause_cap(&mut reg, &admin_cap, scenario.ctx());
    registry::revoke_pause_cap(&mut reg, &admin_cap, object::id(&pause_cap));
    registry::disable_version_pause_cap(&mut reg, &pause_cap, constants::current_version!());
    abort 999
}

// === Version management ===

#[test, expected_failure(abort_code = registry::EVersionAlreadyEnabled)]
fun enable_version_already_enabled_aborts() {
    let (_scenario, mut reg, admin_cap) = test_helpers::begin_registry_test();

    // The current version is enabled at init.
    registry::enable_version(&mut reg, &admin_cap, constants::current_version!());
    abort 999
}

#[test, expected_failure(abort_code = registry::EVersionNotEnabled)]
fun disable_version_never_enabled_aborts() {
    let (_scenario, mut reg, admin_cap) = test_helpers::begin_registry_test();

    let never_enabled = constants::current_version!() + 1;
    registry::disable_version(&mut reg, &admin_cap, never_enabled);
    abort 999
}

#[test, expected_failure(abort_code = registry::ECannotDisableLastVersion)]
fun disable_last_remaining_version_aborts() {
    let (_scenario, mut reg, admin_cap) = test_helpers::begin_registry_test();

    // The init-enabled current version is the only entry in the allowed set.
    registry::disable_version(&mut reg, &admin_cap, constants::current_version!());
    abort 999
}
