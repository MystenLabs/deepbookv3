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
    admin::AdminCap,
    constants,
    flow_test_helpers,
    plp::{Self, PoolVault},
    protocol_config::ProtocolConfig,
    registry::{Self, Registry},
    test_constants,
    test_helpers
};
use propbook::{
    block_scholes_feed::BlockScholesFeed,
    pyth_feed::PythFeed,
    registry::{Self as propbook_registry, OracleRegistry, RegistryAdminCap}
};
use std::unit_test::destroy;
use sui::{clock, test_scenario::{Scenario, return_shared}};

/// A Pyth source id the registry never approves; a `PythFeed` created for it
/// is therefore not bound to any registered tick-size config.
const UNREGISTERED_PYTH_SOURCE_ID: u32 = 777;

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
    registry::register_pyth_source(
        &mut reg,
        &admin_cap,
        test_constants::pyth_feed_id(),
        test_constants::default_tick_size(),
    );
    let registry_id = reg.id();
    return_shared(reg);

    scenario.next_tx(test_constants::admin());
    let mut oracle_registry = scenario.take_shared<OracleRegistry>();
    let rogue_pyth_id = propbook_registry::create_and_share_pyth_feed(
        &mut oracle_registry,
        UNREGISTERED_PYTH_SOURCE_ID,
        scenario.ctx(),
    );
    let bs_id = propbook_registry::create_and_share_block_scholes_feed(
        &mut oracle_registry,
        UNREGISTERED_PYTH_SOURCE_ID,
        scenario.ctx(),
    );
    return_shared(oracle_registry);
    let mut clock = clock::create_for_testing(scenario.ctx());
    clock.set_for_testing(test_constants::now_ms());

    scenario.next_tx(test_constants::admin());
    let mut reg = scenario.take_shared_by_id<Registry>(registry_id);
    let mut vault = scenario.take_shared<PoolVault>();
    let oracle_registry = scenario.take_shared<OracleRegistry>();
    let config = scenario.take_shared<ProtocolConfig>();
    let rogue_pyth = scenario.take_shared_by_id<PythFeed>(rogue_pyth_id);
    let bs = scenario.take_shared_by_id<BlockScholesFeed>(bs_id);
    let lifecycle_cap = registry::mint_lifecycle_cap(&mut reg, &admin_cap, scenario.ctx());
    // The unapproved Pyth source fails the `register_pyth_source` gate before the
    // canonical-binding check, so the underlying id below is never reached.
    let _expiry_id = registry::create_expiry_market(
        &mut reg,
        &mut vault,
        &config,
        &oracle_registry,
        &rogue_pyth,
        &bs,
        &lifecycle_cap,
        test_constants::propbook_underlying_id(),
        test_constants::default_expiry_ms(),
        &clock,
        scenario.ctx(),
    );
    abort 999
}

#[test, expected_failure(abort_code = registry::EPythFeedNotBoundToUnderlying)]
fun create_expiry_market_with_unbound_pyth_feed_aborts() {
    // Pyth source approved + feeds created, but nothing is bound to the underlying,
    // so the Pyth canonical-binding check (after the approval gate) fails first.
    let (mut scenario, registry_id, admin_cap, pyth_id, bs_id) = setup_registered_feeds();

    scenario.next_tx(test_constants::admin());
    let mut clock = clock::create_for_testing(scenario.ctx());
    clock.set_for_testing(test_constants::now_ms());
    let mut reg = scenario.take_shared_by_id<Registry>(registry_id);
    let mut vault = scenario.take_shared<PoolVault>();
    let oracle_registry = scenario.take_shared<OracleRegistry>();
    let config = scenario.take_shared<ProtocolConfig>();
    let pyth = scenario.take_shared_by_id<PythFeed>(pyth_id);
    let bs = scenario.take_shared_by_id<BlockScholesFeed>(bs_id);
    let lifecycle_cap = registry::mint_lifecycle_cap(&mut reg, &admin_cap, scenario.ctx());
    let _expiry_id = registry::create_expiry_market(
        &mut reg,
        &mut vault,
        &config,
        &oracle_registry,
        &pyth,
        &bs,
        &lifecycle_cap,
        test_constants::propbook_underlying_id(),
        test_constants::default_expiry_ms(),
        &clock,
        scenario.ctx(),
    );
    abort 999
}

#[test, expected_failure(abort_code = registry::EBlockScholesFeedNotBoundToUnderlying)]
fun create_expiry_market_with_unbound_block_scholes_feed_aborts() {
    // Only the Pyth feed is bound to the underlying; the BS check then fails.
    let (mut scenario, registry_id, admin_cap, pyth_id, bs_id) = setup_registered_feeds();

    scenario.next_tx(test_constants::admin());
    bind_only_pyth(&scenario, pyth_id);

    scenario.next_tx(test_constants::admin());
    let mut clock = clock::create_for_testing(scenario.ctx());
    clock.set_for_testing(test_constants::now_ms());
    let mut reg = scenario.take_shared_by_id<Registry>(registry_id);
    let mut vault = scenario.take_shared<PoolVault>();
    let oracle_registry = scenario.take_shared<OracleRegistry>();
    let config = scenario.take_shared<ProtocolConfig>();
    let pyth = scenario.take_shared_by_id<PythFeed>(pyth_id);
    let bs = scenario.take_shared_by_id<BlockScholesFeed>(bs_id);
    let lifecycle_cap = registry::mint_lifecycle_cap(&mut reg, &admin_cap, scenario.ctx());
    let _expiry_id = registry::create_expiry_market(
        &mut reg,
        &mut vault,
        &config,
        &oracle_registry,
        &pyth,
        &bs,
        &lifecycle_cap,
        test_constants::propbook_underlying_id(),
        test_constants::default_expiry_ms(),
        &clock,
        scenario.ctx(),
    );
    abort 999
}

/// Init all registries, approve the canonical Pyth source + tick size, and create
/// the two real propbook feeds (catalog-only, NOT yet bound to an underlying).
/// Returns positioned for the caller to bind (or not) then create the market.
fun setup_registered_feeds(): (Scenario, ID, AdminCap, ID, ID) {
    let (mut scenario, mut reg, admin_cap) = test_helpers::begin_registry_test();
    plp::init_for_testing(scenario.ctx());
    propbook_registry::init_for_testing(scenario.ctx());
    registry::register_pyth_source(
        &mut reg,
        &admin_cap,
        test_constants::pyth_feed_id(),
        test_constants::default_tick_size(),
    );
    let registry_id = reg.id();
    return_shared(reg);

    scenario.next_tx(test_constants::admin());
    let mut oracle_registry = scenario.take_shared<OracleRegistry>();
    let pyth_id = propbook_registry::create_and_share_pyth_feed(
        &mut oracle_registry,
        test_constants::pyth_feed_id(),
        scenario.ctx(),
    );
    let bs_id = propbook_registry::create_and_share_block_scholes_feed(
        &mut oracle_registry,
        test_constants::pyth_feed_id(),
        scenario.ctx(),
    );
    return_shared(oracle_registry);

    (scenario, registry_id, admin_cap, pyth_id, bs_id)
}

/// Bind only the Pyth feed to the canonical underlying, leaving the BS feed
/// unbound. Operates within the current (admin) transaction.
fun bind_only_pyth(scenario: &Scenario, pyth_id: ID) {
    let admin_cap = scenario.take_from_sender<RegistryAdminCap>();
    let mut oracle_registry = scenario.take_shared<OracleRegistry>();
    let pyth = scenario.take_shared_by_id<PythFeed>(pyth_id);
    propbook_registry::bind_pyth_to_underlying(
        &mut oracle_registry,
        &admin_cap,
        &pyth,
        test_constants::propbook_underlying_id(),
        test_constants::quote_asset_id(),
    );
    return_shared(pyth);
    return_shared(oracle_registry);
    destroy(admin_cap);
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
