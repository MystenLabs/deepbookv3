// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module deepbook_predict::registry_create_tests;

use deepbook_predict::{
    admin::AdminCap,
    config_constants,
    constants,
    expiry_market::ExpiryMarket,
    market_oracle::{Self, MarketOracle, MarketOracleCap},
    plp::{Self, PoolVault},
    pricing,
    protocol_config::ProtocolConfig,
    pyth_source::PythSource,
    registry,
    strike_grid,
    test_constants,
    test_helpers
};
use dusdc::dusdc::DUSDC;
use std::unit_test::{assert_eq, destroy};
use sui::{clock, coin, test_scenario::{Self as test, Scenario, return_shared}};

const PYTH_FEED_BTC: u32 = 100;
const PYTH_FEED_ETH: u32 = 200;
const BTC_TICK_SIZE: u64 = 1_000_000_000; // $1.00 in 1e9 price scaling
const WIDER_BTC_TICK_SIZE: u64 = 10_000_000_000; // $10.00 in 1e9 price scaling
const ETH_TICK_SIZE: u64 = 100_000_000; // $0.10 in 1e9 price scaling
const INVALID_TICK_SIZE: u64 = BTC_TICK_SIZE + 1;
const INITIAL_EXPIRY_TICK_SIZE: u64 = 3_000_000_000;
const UPDATED_EXPIRY_TICK_SIZE: u64 = 1_000_000_000;
const TOO_WIDE_EXPIRY_TICK_SIZE: u64 = 2_000_000_000;
const EXPIRY_FEE_MAX_MULTIPLIER_DISABLED: u64 = 1_000_000_000; // 1.0 — sentinel disables ramp
const RAMP_WINDOW_MS: u64 = 3_600_000;
const RAMP_MAX_MULTIPLIER: u64 = 2_000_000_000; // 2.0x at expiry
const NOW_MS: u64 = 1_700_000_000_000;
const SOURCE_TIMESTAMP_MS: u64 = 1_699_999_999_000;
const EXPIRY_MS: u64 = 1_700_003_600_000;
const BTC_SPOT: u64 = 100_000_000_000_000;
const EXPECTED_CENTERED_MIN_STRIKE: u64 = 50_000_000_000_000;
const EXPECTED_CENTERED_MAX_STRIKE: u64 = 150_000_000_000_000;
const POOL_SUPPLY: u64 = 100_000_000_000;

// === create_pyth_source ===

#[test]
fun create_pyth_source_returns_id_and_registers() {
    let (mut scenario, mut reg, admin_cap) = test_helpers::begin_registry_test();

    let pyth_id = registry::create_pyth_source(
        &mut reg,
        &admin_cap,
        PYTH_FEED_BTC,
        BTC_TICK_SIZE,
        config_constants::default_expiry_fee_window_ms!(),
        EXPIRY_FEE_MAX_MULTIPLIER_DISABLED,
        scenario.ctx(),
    );
    let registered = registry::pyth_source_id(&reg, PYTH_FEED_BTC);
    assert!(registered.is_some());
    assert!(*registered.borrow() == pyth_id);
    let tick_size = registry::pyth_feed_tick_size(&reg, PYTH_FEED_BTC);
    assert!(tick_size.is_some());
    assert!(*tick_size.borrow() == BTC_TICK_SIZE);
    let window = registry::pyth_feed_expiry_fee_window_ms(&reg, PYTH_FEED_BTC);
    assert!(*window.borrow() == config_constants::default_expiry_fee_window_ms!());
    let multiplier = registry::pyth_feed_expiry_fee_max_multiplier(&reg, PYTH_FEED_BTC);
    assert!(*multiplier.borrow() == EXPIRY_FEE_MAX_MULTIPLIER_DISABLED);
    // Other feed ids must remain unmapped.
    assert!(registry::pyth_source_id(&reg, PYTH_FEED_ETH).is_none());
    assert!(registry::pyth_feed_tick_size(&reg, PYTH_FEED_ETH).is_none());
    assert!(registry::pyth_feed_expiry_fee_window_ms(&reg, PYTH_FEED_ETH).is_none());
    assert!(registry::pyth_feed_expiry_fee_max_multiplier(&reg, PYTH_FEED_ETH).is_none());

    test_helpers::finish_registry_test(scenario, reg, admin_cap);
}

#[test]
fun create_pyth_source_distinct_feeds_yield_distinct_ids() {
    let (mut scenario, mut reg, admin_cap) = test_helpers::begin_registry_test();

    let btc_id = registry::create_pyth_source(
        &mut reg,
        &admin_cap,
        PYTH_FEED_BTC,
        BTC_TICK_SIZE,
        config_constants::default_expiry_fee_window_ms!(),
        EXPIRY_FEE_MAX_MULTIPLIER_DISABLED,
        scenario.ctx(),
    );
    let eth_id = registry::create_pyth_source(
        &mut reg,
        &admin_cap,
        PYTH_FEED_ETH,
        ETH_TICK_SIZE,
        config_constants::default_expiry_fee_window_ms!(),
        EXPIRY_FEE_MAX_MULTIPLIER_DISABLED,
        scenario.ctx(),
    );
    assert!(btc_id != eth_id);

    test_helpers::finish_registry_test(scenario, reg, admin_cap);
}

#[test, expected_failure(abort_code = registry::EPythSourceAlreadyCreated)]
fun create_pyth_source_duplicate_feed_aborts() {
    let (mut scenario, mut reg, admin_cap) = test_helpers::begin_registry_test();

    registry::create_pyth_source(
        &mut reg,
        &admin_cap,
        PYTH_FEED_BTC,
        BTC_TICK_SIZE,
        config_constants::default_expiry_fee_window_ms!(),
        EXPIRY_FEE_MAX_MULTIPLIER_DISABLED,
        scenario.ctx(),
    );
    registry::create_pyth_source(
        &mut reg,
        &admin_cap,
        PYTH_FEED_BTC,
        BTC_TICK_SIZE,
        config_constants::default_expiry_fee_window_ms!(),
        EXPIRY_FEE_MAX_MULTIPLIER_DISABLED,
        scenario.ctx(),
    );
    abort 999
}

#[test, expected_failure(abort_code = registry::EPackageVersionDisabled)]
fun create_pyth_source_with_current_version_disabled_aborts() {
    // Admin can disable current_version via the version-management path (which
    // bypasses the version gate). Subsequent create_pyth_source then fails the
    // mirrored-version check.
    let (mut scenario, mut reg, admin_cap) = test_helpers::begin_registry_test();
    let current = constants::current_version!();
    let next = current + 1;
    registry::enable_version(&mut reg, &admin_cap, next);
    registry::disable_version(&mut reg, &admin_cap, current);

    registry::create_pyth_source(
        &mut reg,
        &admin_cap,
        PYTH_FEED_BTC,
        BTC_TICK_SIZE,
        config_constants::default_expiry_fee_window_ms!(),
        EXPIRY_FEE_MAX_MULTIPLIER_DISABLED,
        scenario.ctx(),
    );
    abort 999
}

#[test, expected_failure(abort_code = deepbook_predict::config_constants::EInvalidOracleTickSize)]
fun create_pyth_source_unaligned_tick_size_aborts() {
    let (mut scenario, mut reg, admin_cap) = test_helpers::begin_registry_test();

    registry::create_pyth_source(
        &mut reg,
        &admin_cap,
        PYTH_FEED_BTC,
        INVALID_TICK_SIZE,
        config_constants::default_expiry_fee_window_ms!(),
        EXPIRY_FEE_MAX_MULTIPLIER_DISABLED,
        scenario.ctx(),
    );
    abort 999
}

// === pyth_source_id getter for unknown feed ===

#[test]
fun pyth_source_id_returns_none_for_unmapped_feed() {
    let (scenario, reg, admin_cap) = test_helpers::begin_registry_test();

    assert!(registry::pyth_source_id(&reg, PYTH_FEED_BTC).is_none());
    assert!(registry::pyth_feed_tick_size(&reg, PYTH_FEED_BTC).is_none());
    assert!(registry::pyth_feed_expiry_fee_window_ms(&reg, PYTH_FEED_BTC).is_none());

    test_helpers::finish_registry_test(scenario, reg, admin_cap);
}

// === pyth feed tick size admin setter ===

#[test]
fun set_pyth_feed_tick_size_updates_registered_feed() {
    let (mut scenario, mut reg, admin_cap) = test_helpers::begin_registry_test();

    registry::create_pyth_source(
        &mut reg,
        &admin_cap,
        PYTH_FEED_BTC,
        BTC_TICK_SIZE,
        config_constants::default_expiry_fee_window_ms!(),
        EXPIRY_FEE_MAX_MULTIPLIER_DISABLED,
        scenario.ctx(),
    );
    registry::set_pyth_feed_tick_size(&mut reg, &admin_cap, PYTH_FEED_BTC, WIDER_BTC_TICK_SIZE);

    let tick_size = registry::pyth_feed_tick_size(&reg, PYTH_FEED_BTC);
    assert!(tick_size.is_some());
    assert!(*tick_size.borrow() == WIDER_BTC_TICK_SIZE);

    test_helpers::finish_registry_test(scenario, reg, admin_cap);
}

#[test, expected_failure(abort_code = registry::EPythFeedNotRegistered)]
fun set_pyth_feed_tick_size_unknown_feed_aborts() {
    let (_scenario, mut reg, admin_cap) = test_helpers::begin_registry_test();

    registry::set_pyth_feed_tick_size(&mut reg, &admin_cap, PYTH_FEED_BTC, BTC_TICK_SIZE);
    abort 999
}

// === create_expiry_market ===

#[test]
fun create_expiry_market_uses_registered_tick_size() {
    let (mut scenario, registry_id, pyth_id, cap) = setup_ready_expiry_creation(
        UPDATED_EXPIRY_TICK_SIZE,
    );

    scenario.next_tx(test_constants::admin());
    let mut reg = scenario.take_shared_by_id<registry::Registry>(registry_id);
    let mut vault = scenario.take_shared<PoolVault>();
    let config = scenario.take_shared<ProtocolConfig>();
    let pyth = scenario.take_shared_by_id<PythSource>(pyth_id);
    let mut clock = clock::create_for_testing(scenario.ctx());
    clock.set_for_testing(NOW_MS);

    let (expiry_market_id, market_oracle_id) = registry::create_expiry_market(
        &mut reg,
        &mut vault,
        &config,
        &pyth,
        &cap,
        EXPIRY_MS,
        &clock,
        scenario.ctx(),
    );
    assert!(vault.active_expiry_markets().contains(&expiry_market_id));
    assert_eq!(
        vault.max_expiry_funding(expiry_market_id),
        config_constants::default_max_expiry_funding!(),
    );
    let (sent_to_expiry, received_from_expiry) = vault.expiry_flow_amounts(expiry_market_id);
    assert_eq!(sent_to_expiry, 0);
    assert_eq!(received_from_expiry, 0);
    return_shared(pyth);
    return_shared(config);
    return_shared(vault);
    return_shared(reg);
    clock.destroy_for_testing();
    destroy(cap);

    scenario.next_tx(test_constants::admin());
    let market = scenario.take_shared_by_id<ExpiryMarket>(expiry_market_id);
    let oracle = scenario.take_shared_by_id<MarketOracle>(market_oracle_id);
    assert_eq!(market.market_oracle_id(), market_oracle_id);
    assert_eq!(market.pyth_lazer_feed_id(), PYTH_FEED_BTC);
    assert_eq!(market.expiry(), EXPIRY_MS);
    assert_eq!(market.min_strike(), EXPECTED_CENTERED_MIN_STRIKE);
    assert_eq!(market.tick_size(), UPDATED_EXPIRY_TICK_SIZE);
    assert_eq!(market.max_strike(), EXPECTED_CENTERED_MAX_STRIKE);
    assert_eq!(market.expiry_fee_window_ms(), RAMP_WINDOW_MS);
    assert_eq!(market.expiry_fee_max_multiplier(), RAMP_MAX_MULTIPLIER);
    assert_eq!(market.cash_balance(), 0);
    assert_eq!(oracle.id(), market_oracle_id);
    return_shared(oracle);
    return_shared(market);
    scenario.end();
}

#[test, expected_failure(abort_code = strike_grid::EOracleTickSizeTooLargeForSpot)]
fun create_expiry_market_aborts_when_tick_size_too_large_for_spot() {
    let (mut scenario, registry_id, pyth_id, cap) = setup_ready_expiry_creation(
        TOO_WIDE_EXPIRY_TICK_SIZE,
    );

    scenario.next_tx(test_constants::admin());
    let mut reg = scenario.take_shared_by_id<registry::Registry>(registry_id);
    let mut vault = scenario.take_shared<PoolVault>();
    let config = scenario.take_shared<ProtocolConfig>();
    let pyth = scenario.take_shared_by_id<PythSource>(pyth_id);
    let mut clock = clock::create_for_testing(scenario.ctx());
    clock.set_for_testing(NOW_MS);

    registry::create_expiry_market(
        &mut reg,
        &mut vault,
        &config,
        &pyth,
        &cap,
        EXPIRY_MS,
        &clock,
        scenario.ctx(),
    );
    abort 999
}

#[test, expected_failure(abort_code = pricing::EPythSpotStale)]
fun create_expiry_market_aborts_when_pyth_spot_is_stale() {
    let (mut scenario, registry_id, pyth_id, cap) = setup_ready_expiry_creation(
        UPDATED_EXPIRY_TICK_SIZE,
    );

    scenario.next_tx(test_constants::admin());
    let mut pyth = scenario.take_shared_by_id<PythSource>(pyth_id);
    let stale_timestamp_ms =
        NOW_MS - deepbook_predict::config_constants::default_pyth_spot_freshness_ms!() - 1;
    pyth.set_state_for_testing(BTC_SPOT, stale_timestamp_ms, stale_timestamp_ms);
    return_shared(pyth);

    scenario.next_tx(test_constants::admin());
    let mut reg = scenario.take_shared_by_id<registry::Registry>(registry_id);
    let mut vault = scenario.take_shared<PoolVault>();
    let config = scenario.take_shared<ProtocolConfig>();
    let pyth = scenario.take_shared_by_id<PythSource>(pyth_id);
    let mut clock = clock::create_for_testing(scenario.ctx());
    clock.set_for_testing(NOW_MS);

    registry::create_expiry_market(
        &mut reg,
        &mut vault,
        &config,
        &pyth,
        &cap,
        EXPIRY_MS,
        &clock,
        scenario.ctx(),
    );
    abort 999
}

fun setup_ready_expiry_creation(expiry_tick_size: u64): (Scenario, ID, ID, MarketOracleCap) {
    let mut scenario = test::begin(test_constants::admin());
    let registry_id = registry::init_for_testing(scenario.ctx());
    plp::init_for_testing(scenario.ctx());

    scenario.next_tx(test_constants::admin());
    let mut reg = scenario.take_shared_by_id<registry::Registry>(registry_id);
    let admin_cap = scenario.take_from_sender<AdminCap>();
    let cap = market_oracle::create_cap(&admin_cap, scenario.ctx());
    let pyth_id = registry::create_pyth_source(
        &mut reg,
        &admin_cap,
        PYTH_FEED_BTC,
        INITIAL_EXPIRY_TICK_SIZE,
        config_constants::default_expiry_fee_window_ms!(),
        EXPIRY_FEE_MAX_MULTIPLIER_DISABLED,
        scenario.ctx(),
    );
    registry::set_pyth_feed_tick_size(&mut reg, &admin_cap, PYTH_FEED_BTC, expiry_tick_size);
    registry::set_pyth_feed_expiry_fee_window_ms(
        &mut reg,
        &admin_cap,
        PYTH_FEED_BTC,
        RAMP_WINDOW_MS,
    );
    registry::set_pyth_feed_expiry_fee_max_multiplier(
        &mut reg,
        &admin_cap,
        PYTH_FEED_BTC,
        RAMP_MAX_MULTIPLIER,
    );
    return_shared(reg);
    destroy(admin_cap);

    scenario.next_tx(test_constants::admin());
    let mut pyth = scenario.take_shared_by_id<PythSource>(pyth_id);
    pyth.set_state_for_testing(BTC_SPOT, SOURCE_TIMESTAMP_MS, SOURCE_TIMESTAMP_MS);
    return_shared(pyth);

    scenario.next_tx(test_constants::admin());
    let mut vault = scenario.take_shared<PoolVault>();
    let mut config = scenario.take_shared<ProtocolConfig>();
    let sync = plp::start_pool_sync(&mut config, &vault);
    let lp = vault.supply(
        &mut config,
        sync,
        coin::mint_for_testing<DUSDC>(POOL_SUPPLY, scenario.ctx()),
        scenario.ctx(),
    );
    assert_eq!(coin::burn_for_testing(lp), POOL_SUPPLY);
    return_shared(config);
    return_shared(vault);

    (scenario, registry_id, pyth_id, cap)
}

// === create_manager / create_and_share_manager ===

#[test]
fun create_manager_yields_distinct_objects_per_caller() {
    // The PredictManager key includes the sender, so two different addresses
    // can each claim their own derived manager.
    let mut scenario = test::begin(test_constants::alice());
    let registry_id = registry::init_for_testing(scenario.ctx());

    scenario.next_tx(test_constants::alice());
    let mut reg = scenario.take_shared_by_id<registry::Registry>(registry_id);
    let alice_mgr = registry::create_manager(&mut reg, scenario.ctx());
    return_shared(reg);

    scenario.next_tx(test_constants::bob());
    let mut reg = scenario.take_shared_by_id<registry::Registry>(registry_id);
    let bob_mgr = registry::create_manager(&mut reg, scenario.ctx());
    return_shared(reg);

    // Different senders produce different derived ids.
    assert!(object::id(&alice_mgr) != object::id(&bob_mgr));

    destroy(alice_mgr);
    destroy(bob_mgr);
    scenario.end();
}
