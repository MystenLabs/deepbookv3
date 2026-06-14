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
    plp::{Self, PoolVault},
    protocol_config::ProtocolConfig,
    registry::{Self, Registry},
    test_constants,
    test_helpers
};
use propbook::{
    block_scholes_feed::{Self, BlockScholesFeed},
    pyth_feed::{Self, PythFeed},
    registry::{Self as propbook_registry, OracleRegistry}
};
use sui::{clock, test_scenario::return_shared};

/// A Pyth Lazer feed id the registry never approves; a `PythFeed` created for it
/// is therefore not bound to any registered tick-size config.
const UNREGISTERED_PYTH_FEED_ID: u32 = 777;

// === create_expiry_market ===

#[test, expected_failure(abort_code = registry::EInvalidExpiry)]
fun create_expiry_market_with_expiry_at_now_aborts() {
    let mut fx = flow_test_helpers::setup_market_default();

    // Boundary: expiry == clock.timestamp_ms() fails the strict `expiry > now`.
    let _expiry_id = fx.create_expiry(test_constants::now_ms());
    abort 999
}

#[test, expected_failure(abort_code = registry::EExpiryMarketAlreadyCreated)]
fun create_expiry_market_duplicate_expiry_aborts() {
    let mut fx = flow_test_helpers::setup_market_default();

    let _expiry_id = fx.create_expiry(test_constants::default_expiry_ms());
    let _dup_id = fx.create_expiry(test_constants::default_expiry_ms());
    abort 999
}

#[test, expected_failure(abort_code = registry::EFeedIdMismatch)]
fun create_expiry_market_with_unregistered_pyth_feed_aborts() {
    let (mut scenario, mut reg, admin_cap) = test_helpers::begin_registry_test();
    plp::init_for_testing(scenario.ctx());
    propbook_registry::init_for_testing(scenario.ctx());
    // Approve the canonical feed so the registry is non-empty; the market is then
    // built against a different, unapproved feed object.
    registry::register_pyth_feed(
        &mut reg,
        &admin_cap,
        test_constants::pyth_feed_id(),
        test_constants::default_tick_size(),
    );
    let registry_id = reg.id();
    return_shared(reg);

    scenario.next_tx(test_constants::admin());
    let mut oracle_registry = scenario.take_shared<OracleRegistry>();
    let rogue_pyth_id = pyth_feed::create_and_share(
        &mut oracle_registry,
        UNREGISTERED_PYTH_FEED_ID,
        scenario.ctx(),
    );
    let bs_id = block_scholes_feed::create_and_share(
        &mut oracle_registry,
        UNREGISTERED_PYTH_FEED_ID,
        scenario.ctx(),
    );
    return_shared(oracle_registry);
    let mut clock = clock::create_for_testing(scenario.ctx());
    clock.set_for_testing(test_constants::now_ms());

    scenario.next_tx(test_constants::admin());
    let mut reg = scenario.take_shared_by_id<Registry>(registry_id);
    let mut vault = scenario.take_shared<PoolVault>();
    let config = scenario.take_shared<ProtocolConfig>();
    let rogue_pyth = scenario.take_shared_by_id<PythFeed>(rogue_pyth_id);
    let bs = scenario.take_shared_by_id<BlockScholesFeed>(bs_id);
    let lifecycle_cap = registry::mint_lifecycle_cap(&mut reg, &admin_cap, scenario.ctx());
    let _expiry_id = registry::create_expiry_market(
        &mut reg,
        &mut vault,
        &config,
        &rogue_pyth,
        &bs,
        &lifecycle_cap,
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
