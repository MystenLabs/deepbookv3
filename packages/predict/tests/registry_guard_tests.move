// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Guard coverage for the registry's creation/version/pause abort codes and the
/// builder-code owner guard.
///
/// `builder_code::ENotOwner` is covered by the disabled root-dependent test below
/// once an empty `AccumulatorRoot` can be constructed: `claim_all_builder_fees`
/// runs `assert_owner` before touching accumulator funds. The non-zero builder-fee
/// claim itself, where fees are delivered to the builder-code object address
/// through the system settlement barrier, still needs integration coverage; see
/// `packages/account/ACCUMULATOR_TESTING_STATUS.md`.
#[test_only]
module deepbook_predict::registry_guard_tests;

use deepbook_predict::{
    accumulator_support,
    admin::AdminCap,
    builder_code::{Self, BuilderCode},
    constants,
    flow_test_helpers,
    market_lifecycle_cap::MarketLifecycleCap,
    market_manager,
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
use std::unit_test::{assert_eq, destroy};
use sui::{clock::{Self, Clock}, test_scenario::{Scenario, return_shared}};

/// A Propbook underlying id the registry never approves.
const UNREGISTERED_UNDERLYING_ID: u32 = 777;
const START_OF_TIME_MS: u64 = 0;
const WINDOW_SIZE_THREE: u64 = 3;

// === builder_code owner guard ===

/* DISABLED(testnet-fw): needs AccumulatorRoot — nightly create_for_testing is absent on testnet; see accumulator_support.move. Restore the file/test when stable Sui ships it.
#[test, expected_failure(abort_code = builder_code::ENotOwner)]
fun claim_builder_fees_by_non_owner_aborts() {
    let (mut scenario, registry_id) = test_helpers::setup_test();

    // Alice creates a builder code: its owner is the sender.
    scenario.next_tx(test_constants::alice());
    let mut reg = scenario.take_shared_by_id<Registry>(registry_id);
    let config = scenario.take_shared<ProtocolConfig>();
    let code_id = reg.create_builder_code(&config, 0, scenario.ctx());
    return_shared(reg);
    return_shared(config);

    // An empty accumulator root suffices: `claim_all_builder_fees` runs `assert_owner`
    // before reading any settled funds.
    scenario.next_tx(test_constants::admin());
    accumulator_support::create_shared_root(&mut scenario);

    // Bob is not the owner, so the owner guard aborts.
    scenario.next_tx(test_constants::bob());
    let mut code = scenario.take_shared_by_id<BuilderCode>(code_id);
    let root = accumulator_support::take_root(&scenario);
    let coin = code.claim_all_builder_fees(&root, scenario.ctx());
    destroy(coin);
    abort 999
}

*/
// === create_expiry_market ===

#[test, expected_failure(abort_code = market_manager::ECadenceDisabled)]
fun create_expiry_market_with_disabled_cadence_aborts() {
    let mut fx = flow_test_helpers::setup_market_default();

    let _expiry_id = fx.create_next_expiry_for_cadence(market_manager::cadence_five_minute!());
    abort 999
}

#[test]
fun create_expiry_market_creates_next_missing_expiries_until_window_full() {
    let (
        mut scenario,
        mut reg,
        mut vault,
        oracle_registry,
        config,
        lifecycle_cap,
        admin_cap,
        clock,
    ) = setup_bound_creation_context(WINDOW_SIZE_THREE);

    let first_id = create_one_minute_market(
        &mut reg,
        &mut vault,
        &config,
        &oracle_registry,
        &lifecycle_cap,
        &clock,
        &mut scenario,
    );
    let second_id = create_one_minute_market(
        &mut reg,
        &mut vault,
        &config,
        &oracle_registry,
        &lifecycle_cap,
        &clock,
        &mut scenario,
    );
    let third_id = create_one_minute_market(
        &mut reg,
        &mut vault,
        &config,
        &oracle_registry,
        &lifecycle_cap,
        &clock,
        &mut scenario,
    );

    let one_minute = constants::one_minute_ms!();
    assert_market_id(&reg, one_minute, first_id);
    assert_market_id(&reg, 2 * one_minute, second_id);
    assert_market_id(&reg, 3 * one_minute, third_id);

    clock.destroy_for_testing();
    return_shared(config);
    return_shared(oracle_registry);
    return_shared(reg);
    return_shared(vault);
    lifecycle_cap.destroy();
    destroy(admin_cap);
    scenario.end();
}

#[test, expected_failure(abort_code = market_manager::ECadenceWindowExceeded)]
fun create_expiry_market_after_window_full_aborts() {
    let (
        mut scenario,
        mut reg,
        mut vault,
        oracle_registry,
        config,
        lifecycle_cap,
        _admin_cap,
        clock,
    ) = setup_bound_creation_context(WINDOW_SIZE_THREE);

    let _first_id = create_one_minute_market(
        &mut reg,
        &mut vault,
        &config,
        &oracle_registry,
        &lifecycle_cap,
        &clock,
        &mut scenario,
    );
    let _second_id = create_one_minute_market(
        &mut reg,
        &mut vault,
        &config,
        &oracle_registry,
        &lifecycle_cap,
        &clock,
        &mut scenario,
    );
    let _third_id = create_one_minute_market(
        &mut reg,
        &mut vault,
        &config,
        &oracle_registry,
        &lifecycle_cap,
        &clock,
        &mut scenario,
    );
    let _fourth_id = create_one_minute_market(
        &mut reg,
        &mut vault,
        &config,
        &oracle_registry,
        &lifecycle_cap,
        &clock,
        &mut scenario,
    );
    abort 999
}

#[test]
fun create_expiry_market_skips_higher_rank_overlap() {
    let (
        mut scenario,
        mut reg,
        mut vault,
        oracle_registry,
        config,
        lifecycle_cap,
        admin_cap,
        mut clock,
    ) = setup_bound_creation_context(WINDOW_SIZE_THREE);

    reg.set_cadence_config(
        &config,
        &admin_cap,
        market_manager::cadence_five_minute!(),
        test_constants::default_tick_size(),
        test_constants::default_max_expiry_allocation(),
        test_constants::default_cadence_window_size(),
    );
    clock.set_for_testing(constants::five_minutes_ms!() - constants::one_minute_ms!());

    let first_id = create_one_minute_market(
        &mut reg,
        &mut vault,
        &config,
        &oracle_registry,
        &lifecycle_cap,
        &clock,
        &mut scenario,
    );
    let second_id = create_one_minute_market(
        &mut reg,
        &mut vault,
        &config,
        &oracle_registry,
        &lifecycle_cap,
        &clock,
        &mut scenario,
    );

    assert!(
        reg
            .expiry_market_id(
                test_constants::propbook_underlying_id(),
                constants::five_minutes_ms!(),
            )
            .is_none(),
    );
    assert_market_id(&reg, constants::five_minutes_ms!() + constants::one_minute_ms!(), first_id);
    assert_market_id(
        &reg,
        constants::five_minutes_ms!() + 2 * constants::one_minute_ms!(),
        second_id,
    );

    clock.destroy_for_testing();
    return_shared(config);
    return_shared(oracle_registry);
    return_shared(reg);
    return_shared(vault);
    lifecycle_cap.destroy();
    destroy(admin_cap);
    scenario.end();
}

#[test, expected_failure(abort_code = market_manager::ECadenceWindowExceeded)]
fun create_expiry_market_with_only_reserved_slot_in_window_aborts() {
    let (
        mut scenario,
        mut reg,
        mut vault,
        oracle_registry,
        config,
        lifecycle_cap,
        admin_cap,
        mut clock,
    ) = setup_bound_creation_context(test_constants::default_cadence_window_size());

    reg.set_cadence_config(
        &config,
        &admin_cap,
        market_manager::cadence_five_minute!(),
        test_constants::default_tick_size(),
        test_constants::default_max_expiry_allocation(),
        test_constants::default_cadence_window_size(),
    );
    clock.set_for_testing(constants::five_minutes_ms!() - constants::one_minute_ms!());

    let _expiry_id = create_one_minute_market(
        &mut reg,
        &mut vault,
        &config,
        &oracle_registry,
        &lifecycle_cap,
        &clock,
        &mut scenario,
    );
    abort 999
}

#[test, expected_failure(abort_code = market_manager::EMarketAlreadyCreated)]
fun create_expiry_market_duplicate_expiry_aborts() {
    let (mut scenario, registry_id, admin_cap, pyth_id, bs_id) = setup_registered_feeds();

    scenario.next_tx(test_constants::admin());
    test_helpers::bind_feeds_to_underlying(&scenario, pyth_id, bs_id);

    scenario.next_tx(test_constants::admin());
    let mut daily_clock = clock::create_for_testing(scenario.ctx());
    let mut reg = scenario.take_shared_by_id<Registry>(registry_id);
    let mut vault = scenario.take_shared<PoolVault>();
    let oracle_registry = scenario.take_shared<OracleRegistry>();
    let config = scenario.take_shared<ProtocolConfig>();
    let lifecycle_cap = reg.mint_lifecycle_cap(&config, &admin_cap, scenario.ctx());
    reg.set_cadence_config(
        &config,
        &admin_cap,
        market_manager::cadence_one_day!(),
        test_constants::default_tick_size(),
        test_constants::default_max_expiry_allocation(),
        test_constants::default_cadence_window_size(),
    );
    daily_clock.set_for_testing(constants::one_week_ms!() - constants::one_day_ms!());
    let _daily_id = reg.create_expiry_market(
        &mut vault,
        &config,
        &oracle_registry,
        &lifecycle_cap,
        test_constants::propbook_underlying_id(),
        market_manager::cadence_one_day!(),
        &daily_clock,
        scenario.ctx(),
    );
    daily_clock.destroy_for_testing();
    reg.set_cadence_config(
        &config,
        &admin_cap,
        market_manager::cadence_one_week!(),
        test_constants::default_tick_size(),
        test_constants::default_max_expiry_allocation(),
        test_constants::default_cadence_window_size(),
    );
    let mut weekly_clock = clock::create_for_testing(scenario.ctx());
    weekly_clock.set_for_testing(START_OF_TIME_MS);
    let _weekly_id = reg.create_expiry_market(
        &mut vault,
        &config,
        &oracle_registry,
        &lifecycle_cap,
        test_constants::propbook_underlying_id(),
        market_manager::cadence_one_week!(),
        &weekly_clock,
        scenario.ctx(),
    );
    abort 999
}

#[test, expected_failure(abort_code = market_manager::EUnderlyingNotRegistered)]
fun create_expiry_market_with_unregistered_underlying_aborts() {
    let (mut scenario, mut reg, config, admin_cap) = test_helpers::begin_registry_test();
    plp::init_for_testing(scenario.ctx());
    propbook_registry::init_for_testing(scenario.ctx());
    let registry_id = reg.id();
    reg.set_cadence_config(
        &config,
        &admin_cap,
        test_constants::default_cadence_id(),
        test_constants::default_tick_size(),
        test_constants::default_max_expiry_allocation(),
        test_constants::default_cadence_window_size(),
    );
    return_shared(reg);
    return_shared(config);

    scenario.next_tx(test_constants::admin());
    let mut clock = clock::create_for_testing(scenario.ctx());
    clock.set_for_testing(test_constants::now_ms());
    let mut reg = scenario.take_shared_by_id<Registry>(registry_id);
    let mut vault = scenario.take_shared<PoolVault>();
    let oracle_registry = scenario.take_shared<OracleRegistry>();
    let config = scenario.take_shared<ProtocolConfig>();
    let lifecycle_cap = reg.mint_lifecycle_cap(&config, &admin_cap, scenario.ctx());
    let _expiry_id = reg.create_expiry_market(
        &mut vault,
        &config,
        &oracle_registry,
        &lifecycle_cap,
        UNREGISTERED_UNDERLYING_ID,
        test_constants::default_cadence_id(),
        &clock,
        scenario.ctx(),
    );
    abort 999
}

#[test, expected_failure(abort_code = market_manager::EPythFeedNotBoundToUnderlying)]
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
    let lifecycle_cap = reg.mint_lifecycle_cap(&config, &admin_cap, scenario.ctx());
    let _expiry_id = reg.create_expiry_market(
        &mut vault,
        &config,
        &oracle_registry,
        &lifecycle_cap,
        test_constants::propbook_underlying_id(),
        test_constants::default_cadence_id(),
        &clock,
        scenario.ctx(),
    );
    abort 999
}

#[test, expected_failure(abort_code = market_manager::EBlockScholesFeedNotBoundToUnderlying)]
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
    let lifecycle_cap = reg.mint_lifecycle_cap(&config, &admin_cap, scenario.ctx());
    let _expiry_id = reg.create_expiry_market(
        &mut vault,
        &config,
        &oracle_registry,
        &lifecycle_cap,
        test_constants::propbook_underlying_id(),
        test_constants::default_cadence_id(),
        &clock,
        scenario.ctx(),
    );
    abort 999
}

/// Init all registries, approve the canonical underlying + default cadence, and create
/// the two real propbook feeds (catalog-only, NOT yet bound to an underlying).
/// Returns positioned for the caller to bind (or not) then create the market.
fun setup_registered_feeds(): (Scenario, ID, AdminCap, ID, ID) {
    let (mut scenario, mut reg, config, admin_cap) = test_helpers::begin_registry_test();
    plp::init_for_testing(scenario.ctx());
    propbook_registry::init_for_testing(scenario.ctx());
    reg.register_underlying(&config, &admin_cap, test_constants::propbook_underlying_id());
    reg.set_cadence_config(
        &config,
        &admin_cap,
        test_constants::default_cadence_id(),
        test_constants::default_tick_size(),
        test_constants::default_max_expiry_allocation(),
        test_constants::default_cadence_window_size(),
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

fun setup_bound_creation_context(
    window_size: u64,
): (
    Scenario,
    Registry,
    PoolVault,
    OracleRegistry,
    ProtocolConfig,
    MarketLifecycleCap,
    AdminCap,
    Clock,
) {
    let (mut scenario, registry_id, admin_cap, pyth_id, bs_id) = setup_registered_feeds();

    scenario.next_tx(test_constants::admin());
    test_helpers::bind_feeds_to_underlying(&scenario, pyth_id, bs_id);

    scenario.next_tx(test_constants::admin());
    let mut reg = scenario.take_shared_by_id<Registry>(registry_id);
    let vault = scenario.take_shared<PoolVault>();
    let oracle_registry = scenario.take_shared<OracleRegistry>();
    let config = scenario.take_shared<ProtocolConfig>();
    let lifecycle_cap = reg.mint_lifecycle_cap(&config, &admin_cap, scenario.ctx());
    reg.set_cadence_config(
        &config,
        &admin_cap,
        market_manager::cadence_one_minute!(),
        test_constants::default_tick_size(),
        test_constants::default_max_expiry_allocation(),
        window_size,
    );
    let mut clock = clock::create_for_testing(scenario.ctx());
    clock.set_for_testing(START_OF_TIME_MS);

    (scenario, reg, vault, oracle_registry, config, lifecycle_cap, admin_cap, clock)
}

fun create_one_minute_market(
    reg: &mut Registry,
    vault: &mut PoolVault,
    config: &ProtocolConfig,
    oracle_registry: &OracleRegistry,
    lifecycle_cap: &MarketLifecycleCap,
    clock: &Clock,
    scenario: &mut Scenario,
): ID {
    reg.create_expiry_market(
        vault,
        config,
        oracle_registry,
        lifecycle_cap,
        test_constants::propbook_underlying_id(),
        market_manager::cadence_one_minute!(),
        clock,
        scenario.ctx(),
    )
}

fun assert_market_id(reg: &Registry, expiry: u64, expected_id: ID) {
    let id = reg.expiry_market_id(test_constants::propbook_underlying_id(), expiry);
    assert!(id.is_some());
    assert_eq!(*id.borrow(), expected_id);
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

    let pause_cap = reg.mint_pause_cap(&admin_cap, scenario.ctx());
    reg.revoke_pause_cap(&admin_cap, pause_cap.id());
    // A revoked pause cap can no longer force the trading pause.
    registry::pause_trading_pause_cap(&mut config, &reg, &pause_cap);
    abort 999
}
