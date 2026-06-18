// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Guard coverage for the registry's creation/version/pause abort codes and the
/// builder-code owner guard.
///
/// `builder_code::ENotOwner` is exercised below: `claim_all_builder_fees` runs
/// `assert_owner` as its first line, before touching any accumulator funds, so a
/// non-owner caller aborts against an EMPTY `AccumulatorRoot` (constructed with
/// `accumulator::create_for_testing`). The non-zero builder-fee CLAIM itself —
/// fees delivered to the builder-code object address through the system settlement
/// barrier — still needs integration coverage; see
/// `packages/account/ACCUMULATOR_TESTING_STATUS.md`.
#[test_only]
module deepbook_predict::registry_guard_tests;

use deepbook_predict::{
    admin::AdminCap,
    builder_code::{Self, BuilderCode},
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
use sui::{accumulator::{Self, AccumulatorRoot}, clock, test_scenario::{Scenario, return_shared}};

/// A Propbook underlying id the registry never approves.
const UNREGISTERED_UNDERLYING_ID: u32 = 777;

// === builder_code owner guard ===

#[test, expected_failure(abort_code = builder_code::ENotOwner)]
fun claim_builder_fees_by_non_owner_aborts() {
    let (mut scenario, registry_id) = test_helpers::setup_test();

    // Alice creates a builder code: its owner is the sender.
    scenario.next_tx(test_constants::alice());
    let mut reg = scenario.take_shared_by_id<Registry>(registry_id);
    let config = scenario.take_shared<ProtocolConfig>();
    let code_id = registry::create_builder_code(&mut reg, &config, 0, scenario.ctx());
    return_shared(reg);
    return_shared(config);

    // An empty accumulator root suffices: `claim_all_builder_fees` runs `assert_owner`
    // before reading any settled funds.
    scenario.next_tx(test_constants::admin());
    accumulator::create_for_testing(scenario.ctx());

    // Bob is not the owner, so the owner guard aborts.
    scenario.next_tx(test_constants::bob());
    let mut code = scenario.take_shared_by_id<BuilderCode>(code_id);
    let root = scenario.take_shared<AccumulatorRoot>();
    let coin = code.claim_all_builder_fees(&root, scenario.ctx());
    destroy(coin);
    abort 999
}

// === create_expiry_market ===

#[test, expected_failure(abort_code = registry::EInvalidExpiry)]
fun create_expiry_market_with_expiry_at_now_aborts() {
    let mut fx = flow_test_helpers::setup_market_default();

    // Boundary: expiry == clock.timestamp_ms() fails the strict `expiry > now`.
    let _expiry_id = fx.create_expiry(test_constants::now_ms());
    abort 999
}

#[test, expected_failure(abort_code = registry::EMarketAlreadyCreated)]
fun create_expiry_market_duplicate_expiry_aborts() {
    let mut fx = flow_test_helpers::setup_market_default();

    let _expiry_id = fx.create_expiry(test_constants::default_expiry_ms());
    let _dup_id = fx.create_expiry(test_constants::default_expiry_ms());
    abort 999
}

#[test, expected_failure(abort_code = registry::EUnderlyingNotRegistered)]
fun create_expiry_market_with_unregistered_underlying_aborts() {
    let (mut scenario, reg, config, admin_cap) = test_helpers::begin_registry_test();
    plp::init_for_testing(scenario.ctx());
    propbook_registry::init_for_testing(scenario.ctx());
    let registry_id = reg.id();
    return_shared(reg);
    return_shared(config);

    scenario.next_tx(test_constants::admin());
    let mut clock = clock::create_for_testing(scenario.ctx());
    clock.set_for_testing(test_constants::now_ms());
    let mut reg = scenario.take_shared_by_id<Registry>(registry_id);
    let mut vault = scenario.take_shared<PoolVault>();
    let oracle_registry = scenario.take_shared<OracleRegistry>();
    let config = scenario.take_shared<ProtocolConfig>();
    let lifecycle_cap = registry::mint_lifecycle_cap(&mut reg, &config, &admin_cap, scenario.ctx());
    let _expiry_id = registry::create_expiry_market(
        &mut reg,
        &mut vault,
        &config,
        &oracle_registry,
        &lifecycle_cap,
        UNREGISTERED_UNDERLYING_ID,
        test_constants::default_expiry_ms(),
        test_constants::default_tick_size(),
        &clock,
        scenario.ctx(),
    );
    abort 999
}

#[test, expected_failure(abort_code = registry::EPythFeedNotBoundToUnderlying)]
fun create_expiry_market_with_unbound_pyth_feed_aborts() {
    // Pyth source approved + feeds created, but nothing is bound to the underlying,
    // so the Pyth canonical-binding check (after the approval gate) fails first.
    let (mut scenario, registry_id, admin_cap, _pyth_id, _bs_id) = setup_registered_feeds();

    scenario.next_tx(test_constants::admin());
    let mut clock = clock::create_for_testing(scenario.ctx());
    clock.set_for_testing(test_constants::now_ms());
    let mut reg = scenario.take_shared_by_id<Registry>(registry_id);
    let mut vault = scenario.take_shared<PoolVault>();
    let oracle_registry = scenario.take_shared<OracleRegistry>();
    let config = scenario.take_shared<ProtocolConfig>();
    let lifecycle_cap = registry::mint_lifecycle_cap(&mut reg, &config, &admin_cap, scenario.ctx());
    let _expiry_id = registry::create_expiry_market(
        &mut reg,
        &mut vault,
        &config,
        &oracle_registry,
        &lifecycle_cap,
        test_constants::propbook_underlying_id(),
        test_constants::default_expiry_ms(),
        test_constants::default_tick_size(),
        &clock,
        scenario.ctx(),
    );
    abort 999
}

#[test, expected_failure(abort_code = registry::EBlockScholesFeedNotBoundToUnderlying)]
fun create_expiry_market_with_unbound_block_scholes_feed_aborts() {
    // Only the Pyth feed is bound to the underlying; the BS check then fails.
    let (mut scenario, registry_id, admin_cap, pyth_id, _bs_id) = setup_registered_feeds();

    scenario.next_tx(test_constants::admin());
    bind_only_pyth(&scenario, pyth_id);

    scenario.next_tx(test_constants::admin());
    let mut clock = clock::create_for_testing(scenario.ctx());
    clock.set_for_testing(test_constants::now_ms());
    let mut reg = scenario.take_shared_by_id<Registry>(registry_id);
    let mut vault = scenario.take_shared<PoolVault>();
    let oracle_registry = scenario.take_shared<OracleRegistry>();
    let config = scenario.take_shared<ProtocolConfig>();
    let lifecycle_cap = registry::mint_lifecycle_cap(&mut reg, &config, &admin_cap, scenario.ctx());
    let _expiry_id = registry::create_expiry_market(
        &mut reg,
        &mut vault,
        &config,
        &oracle_registry,
        &lifecycle_cap,
        test_constants::propbook_underlying_id(),
        test_constants::default_expiry_ms(),
        test_constants::default_tick_size(),
        &clock,
        scenario.ctx(),
    );
    abort 999
}

/// Init all registries, approve the canonical underlying + tick size, and create
/// the two real propbook feeds (catalog-only, NOT yet bound to an underlying).
/// Returns positioned for the caller to bind (or not) then create the market.
fun setup_registered_feeds(): (Scenario, ID, AdminCap, ID, ID) {
    let (mut scenario, mut reg, config, admin_cap) = test_helpers::begin_registry_test();
    plp::init_for_testing(scenario.ctx());
    propbook_registry::init_for_testing(scenario.ctx());
    registry::register_underlying(
        &mut reg,
        &config,
        &admin_cap,
        test_constants::propbook_underlying_id(),
        test_constants::default_tick_size(),
    );
    let registry_id = reg.id();
    return_shared(reg);
    return_shared(config);

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
    );
    return_shared(pyth);
    return_shared(oracle_registry);
    destroy(admin_cap);
}

// === PauseCap ===

#[test, expected_failure(abort_code = registry::EPauseCapNotValid)]
fun revoked_pause_cap_cannot_pause_trading() {
    let (mut scenario, mut reg, mut config, admin_cap) = test_helpers::begin_registry_test();

    let pause_cap = registry::mint_pause_cap(&mut reg, &admin_cap, scenario.ctx());
    registry::revoke_pause_cap(&mut reg, &admin_cap, object::id(&pause_cap));
    // A revoked pause cap can no longer force the trading pause.
    registry::pause_trading_pause_cap(&mut config, &reg, &pause_cap);
    abort 999
}
