// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module deepbook_sessions::spot_sessions_tests;

use account::{
    account::{Self as account, AccountWrapper},
    account_registry::{Self as account_registry, AccountAdminCap, AccountRegistry}
};
use deepbook::{
    balance_manager::{Self as balance_manager, BalanceManager},
    constants,
    order_info::OrderInfo,
    pool::{Self as pool, Pool},
    registry::{Self as registry, Registry}
};
use deepbook_core_account::{
    account_data::{Self as account_data, DeepbookCoreAccountApp},
    deepbook_core_account as dca
};
use deepbook_sessions::{
    session_config::{Self as session_config, SessionsConfig},
    sessions::{Self as sessions, SessionsApp}
};
use std::unit_test::{assert_eq, destroy};
use sui::{
    accumulator::{Self as accumulator, AccumulatorRoot},
    clock::{Self as clock, Clock},
    coin,
    test_scenario::{Self as test, Scenario, return_shared},
    transfer
};
use token::deep::DEEP;

const ADMIN: address = @0xAD;
const ALICE: address = @0xA11CE;
const BOB: address = @0xB0B;
const SESSION: address = @0x5E5510;

const NOW_MS: u64 = 1_000;
const SESSION_DURATION_MS: u64 = 60_000;
const SESSION_EXPIRES_AT_MS: u64 = 61_000; // 1_000 + 60_000.
const ACCOUNT_BALANCE: u64 = 5_000_000_000;
const LIMIT_ORDER_CLIENT_ID: u64 = 11;
const SECOND_LIMIT_ORDER_CLIENT_ID: u64 = 12;
const THIRD_LIMIT_ORDER_CLIENT_ID: u64 = 13;
const MARKET_MAKER_CLIENT_ID: u64 = 21;
const MARKET_TAKER_CLIENT_ID: u64 = 22;
const FILLING_BID_CLIENT_ID: u64 = 31;
const NO_OPEN_ORDERS: u64 = 0;
const ONE_OPEN_ORDER: u64 = 1;
const TWO_OPEN_ORDERS: u64 = 2;
const ZERO_BALANCE: u64 = 0;
const ZERO_ORDER_ID: u128 = 0;
const EUnexpectedSuccess: u64 = 999;
const FUTURE_VERSION: u64 = 2;

public struct BASE has store {}
public struct QUOTE has store {}

public struct SpotFixture {
    scenario: Scenario,
    registry_id: ID,
    pool_id: ID,
    wrapper_id: ID,
    sessions_config_id: ID,
}

#[test]
fun session_places_and_cancels_spot_limit_orders() {
    let mut fixture = setup_spot_fixture();
    authorize_session(&mut fixture);
    let registry_id = fixture.registry_id;
    let pool_id = fixture.pool_id;
    let wrapper_id = fixture.wrapper_id;
    let trade_amount = constants::min_size();

    fixture.scenario.next_tx(SESSION);
    let registry = fixture.scenario.take_shared_by_id<Registry>(registry_id);
    let account_registry = fixture.scenario.take_shared<AccountRegistry>();
    let mut pool = fixture.scenario.take_shared_by_id<Pool<BASE, QUOTE>>(pool_id);
    let mut wrapper = fixture.scenario.take_shared_by_id<AccountWrapper>(wrapper_id);
    let sessions_config = fixture
        .scenario
        .take_shared_by_id<SessionsConfig>(fixture.sessions_config_id);
    let root = fixture.scenario.take_shared<AccumulatorRoot>();
    let clock = fixture.scenario.take_shared<Clock>();
    let first = sessions::place_limit_order<BASE, QUOTE>(
        &mut pool,
        &registry,
        &account_registry,
        &mut wrapper,
        &sessions_config,
        LIMIT_ORDER_CLIENT_ID,
        constants::no_restriction(),
        constants::self_matching_allowed(),
        constants::float_scaling(),
        trade_amount,
        false,
        true,
        constants::max_u64(),
        &root,
        &clock,
        fixture.scenario.ctx(),
    );
    let first_id = first.order_id();
    assert_eq!(first.status(), constants::live());
    assert!(first.order_inserted());
    assert_eq!(
        dca::pool_account_open_orders<BASE, QUOTE>(&pool, wrapper.load_account()).length(),
        ONE_OPEN_ORDER,
    );
    let (base_locked, quote_locked, deep_locked) = dca::locked_balance<BASE, QUOTE>(
        &pool,
        wrapper.load_account(),
    );
    assert_eq!(base_locked, trade_amount);
    assert_eq!(quote_locked, ZERO_BALANCE);
    assert_eq!(deep_locked, ZERO_BALANCE);
    return_shared(clock);
    return_shared(root);
    return_shared(sessions_config);
    return_shared(wrapper);
    return_shared(pool);
    return_shared(account_registry);
    return_shared(registry);

    fixture.scenario.next_tx(SESSION);
    let account_registry = fixture.scenario.take_shared<AccountRegistry>();
    let mut pool = fixture.scenario.take_shared_by_id<Pool<BASE, QUOTE>>(pool_id);
    let mut wrapper = fixture.scenario.take_shared_by_id<AccountWrapper>(wrapper_id);
    let sessions_config = fixture
        .scenario
        .take_shared_by_id<SessionsConfig>(fixture.sessions_config_id);
    let root = fixture.scenario.take_shared<AccumulatorRoot>();
    let clock = fixture.scenario.take_shared<Clock>();
    sessions::cancel_live_order<BASE, QUOTE>(
        &mut pool,
        &account_registry,
        &mut wrapper,
        &sessions_config,
        first_id,
        &clock,
        fixture.scenario.ctx(),
    );
    assert_eq!(
        dca::pool_account_open_orders<BASE, QUOTE>(&pool, wrapper.load_account()).length(),
        NO_OPEN_ORDERS,
    );
    assert_eq!(wrapper.load_account().balance<BASE>(&root, &clock), ACCOUNT_BALANCE);
    return_shared(clock);
    return_shared(root);
    return_shared(sessions_config);
    return_shared(wrapper);
    return_shared(pool);
    return_shared(account_registry);

    fixture.scenario.next_tx(SESSION);
    let registry = fixture.scenario.take_shared_by_id<Registry>(registry_id);
    let account_registry = fixture.scenario.take_shared<AccountRegistry>();
    let mut pool = fixture.scenario.take_shared_by_id<Pool<BASE, QUOTE>>(pool_id);
    let mut wrapper = fixture.scenario.take_shared_by_id<AccountWrapper>(wrapper_id);
    let sessions_config = fixture
        .scenario
        .take_shared_by_id<SessionsConfig>(fixture.sessions_config_id);
    let root = fixture.scenario.take_shared<AccumulatorRoot>();
    let clock = fixture.scenario.take_shared<Clock>();
    let second = sessions::place_limit_order<BASE, QUOTE>(
        &mut pool,
        &registry,
        &account_registry,
        &mut wrapper,
        &sessions_config,
        SECOND_LIMIT_ORDER_CLIENT_ID,
        constants::no_restriction(),
        constants::self_matching_allowed(),
        constants::float_scaling(),
        trade_amount,
        false,
        true,
        constants::max_u64(),
        &root,
        &clock,
        fixture.scenario.ctx(),
    );
    let third = sessions::place_limit_order<BASE, QUOTE>(
        &mut pool,
        &registry,
        &account_registry,
        &mut wrapper,
        &sessions_config,
        THIRD_LIMIT_ORDER_CLIENT_ID,
        constants::no_restriction(),
        constants::self_matching_allowed(),
        constants::float_scaling(),
        trade_amount,
        false,
        true,
        constants::max_u64(),
        &root,
        &clock,
        fixture.scenario.ctx(),
    );
    assert_eq!(
        dca::pool_account_open_orders<BASE, QUOTE>(&pool, wrapper.load_account()).length(),
        TWO_OPEN_ORDERS,
    );
    let second_id = second.order_id();
    let third_id = third.order_id();
    return_shared(clock);
    return_shared(root);
    return_shared(sessions_config);
    return_shared(wrapper);
    return_shared(pool);
    return_shared(account_registry);
    return_shared(registry);

    fixture.scenario.next_tx(SESSION);
    let account_registry = fixture.scenario.take_shared<AccountRegistry>();
    let mut pool = fixture.scenario.take_shared_by_id<Pool<BASE, QUOTE>>(pool_id);
    let mut wrapper = fixture.scenario.take_shared_by_id<AccountWrapper>(wrapper_id);
    let sessions_config = fixture
        .scenario
        .take_shared_by_id<SessionsConfig>(fixture.sessions_config_id);
    let root = fixture.scenario.take_shared<AccumulatorRoot>();
    let clock = fixture.scenario.take_shared<Clock>();
    sessions::cancel_live_orders<BASE, QUOTE>(
        &mut pool,
        &account_registry,
        &mut wrapper,
        &sessions_config,
        vector[second_id, third_id],
        &clock,
        fixture.scenario.ctx(),
    );
    assert_eq!(
        dca::pool_account_open_orders<BASE, QUOTE>(&pool, wrapper.load_account()).length(),
        NO_OPEN_ORDERS,
    );
    assert_eq!(wrapper.load_account().balance<BASE>(&root, &clock), ACCOUNT_BALANCE);
    return_shared(clock);
    return_shared(root);
    return_shared(sessions_config);
    return_shared(wrapper);
    return_shared(pool);
    return_shared(account_registry);
    finish_spot_fixture(fixture);
}

#[test]
fun session_places_spot_market_order() {
    let mut fixture = setup_spot_fixture();
    let maker_id = create_balance_manager_with_funds(&mut fixture);
    let trade_amount = constants::min_size();
    let maker = place_manager_limit_order(
        &mut fixture,
        maker_id,
        MARKET_MAKER_CLIENT_ID,
        trade_amount,
        false,
    );
    assert_eq!(maker.status(), constants::live());
    assert!(maker.order_inserted());
    authorize_session(&mut fixture);
    let registry_id = fixture.registry_id;
    let pool_id = fixture.pool_id;
    let wrapper_id = fixture.wrapper_id;

    fixture.scenario.next_tx(SESSION);
    let registry = fixture.scenario.take_shared_by_id<Registry>(registry_id);
    let account_registry = fixture.scenario.take_shared<AccountRegistry>();
    let mut pool = fixture.scenario.take_shared_by_id<Pool<BASE, QUOTE>>(pool_id);
    let mut wrapper = fixture.scenario.take_shared_by_id<AccountWrapper>(wrapper_id);
    let sessions_config = fixture
        .scenario
        .take_shared_by_id<SessionsConfig>(fixture.sessions_config_id);
    let root = fixture.scenario.take_shared<AccumulatorRoot>();
    let clock = fixture.scenario.take_shared<Clock>();
    let fill = sessions::place_market_order<BASE, QUOTE>(
        &mut pool,
        &registry,
        &account_registry,
        &mut wrapper,
        &sessions_config,
        MARKET_TAKER_CLIENT_ID,
        constants::self_matching_allowed(),
        trade_amount,
        constants::float_scaling(),
        true,
        true,
        &root,
        &clock,
        fixture.scenario.ctx(),
    );
    assert_eq!(fill.status(), constants::filled());
    assert_eq!(fill.executed_quantity(), trade_amount);
    assert_eq!(fill.cumulative_quote_quantity(), trade_amount);
    assert_eq!(wrapper.load_account().balance<BASE>(&root, &clock), ACCOUNT_BALANCE + trade_amount);
    assert_eq!(
        wrapper.load_account().balance<QUOTE>(&root, &clock),
        ACCOUNT_BALANCE - trade_amount,
    );
    assert_eq!(account_data::balance_manager_balance<BASE>(wrapper.load_account()), ZERO_BALANCE);
    assert_eq!(account_data::balance_manager_balance<QUOTE>(wrapper.load_account()), ZERO_BALANCE);
    assert_eq!(account_data::balance_manager_balance<DEEP>(wrapper.load_account()), ZERO_BALANCE);
    return_shared(clock);
    return_shared(root);
    return_shared(sessions_config);
    return_shared(wrapper);
    return_shared(pool);
    return_shared(account_registry);
    return_shared(registry);
    finish_spot_fixture(fixture);
}

#[test]
fun session_withdraws_settled_spot_amounts() {
    let mut fixture = setup_spot_fixture();
    let bob_manager_id = create_balance_manager_with_funds(&mut fixture);
    authorize_session(&mut fixture);
    let registry_id = fixture.registry_id;
    let pool_id = fixture.pool_id;
    let wrapper_id = fixture.wrapper_id;
    let trade_amount = constants::min_size();

    fixture.scenario.next_tx(SESSION);
    let registry = fixture.scenario.take_shared_by_id<Registry>(registry_id);
    let account_registry = fixture.scenario.take_shared<AccountRegistry>();
    let mut pool = fixture.scenario.take_shared_by_id<Pool<BASE, QUOTE>>(pool_id);
    let mut wrapper = fixture.scenario.take_shared_by_id<AccountWrapper>(wrapper_id);
    let sessions_config = fixture
        .scenario
        .take_shared_by_id<SessionsConfig>(fixture.sessions_config_id);
    let root = fixture.scenario.take_shared<AccumulatorRoot>();
    let clock = fixture.scenario.take_shared<Clock>();
    let ask = sessions::place_limit_order<BASE, QUOTE>(
        &mut pool,
        &registry,
        &account_registry,
        &mut wrapper,
        &sessions_config,
        LIMIT_ORDER_CLIENT_ID,
        constants::no_restriction(),
        constants::self_matching_allowed(),
        constants::float_scaling(),
        trade_amount,
        false,
        true,
        constants::max_u64(),
        &root,
        &clock,
        fixture.scenario.ctx(),
    );
    assert_eq!(ask.status(), constants::live());
    assert!(ask.order_inserted());
    assert_eq!(wrapper.load_account().balance<BASE>(&root, &clock), ACCOUNT_BALANCE - trade_amount);
    return_shared(clock);
    return_shared(root);
    return_shared(sessions_config);
    return_shared(wrapper);
    return_shared(pool);
    return_shared(account_registry);
    return_shared(registry);

    let fill = place_manager_market_order(
        &mut fixture,
        bob_manager_id,
        FILLING_BID_CLIENT_ID,
        trade_amount,
        true,
    );
    assert_eq!(fill.status(), constants::filled());
    assert_eq!(fill.executed_quantity(), trade_amount);

    fixture.scenario.next_tx(SESSION);
    let account_registry = fixture.scenario.take_shared<AccountRegistry>();
    let mut pool = fixture.scenario.take_shared_by_id<Pool<BASE, QUOTE>>(pool_id);
    let mut wrapper = fixture.scenario.take_shared_by_id<AccountWrapper>(wrapper_id);
    let sessions_config = fixture
        .scenario
        .take_shared_by_id<SessionsConfig>(fixture.sessions_config_id);
    let root = fixture.scenario.take_shared<AccumulatorRoot>();
    let clock = fixture.scenario.take_shared<Clock>();
    assert_eq!(wrapper.load_account().balance<QUOTE>(&root, &clock), ACCOUNT_BALANCE);
    sessions::withdraw_settled_amounts<BASE, QUOTE>(
        &mut pool,
        &account_registry,
        &mut wrapper,
        &sessions_config,
        &clock,
        fixture.scenario.ctx(),
    );
    assert_eq!(wrapper.load_account().balance<BASE>(&root, &clock), ACCOUNT_BALANCE - trade_amount);
    assert_eq!(
        wrapper.load_account().balance<QUOTE>(&root, &clock),
        ACCOUNT_BALANCE + trade_amount,
    );
    assert_eq!(account_data::balance_manager_balance<BASE>(wrapper.load_account()), ZERO_BALANCE);
    assert_eq!(account_data::balance_manager_balance<QUOTE>(wrapper.load_account()), ZERO_BALANCE);
    assert_eq!(account_data::balance_manager_balance<DEEP>(wrapper.load_account()), ZERO_BALANCE);
    return_shared(clock);
    return_shared(root);
    return_shared(sessions_config);
    return_shared(wrapper);
    return_shared(pool);
    return_shared(account_registry);
    finish_spot_fixture(fixture);
}

#[test, expected_failure(abort_code = sessions::ESessionNotAuthorized)]
fun unapproved_session_cannot_place_spot_order() {
    let mut fixture = setup_spot_fixture();
    let registry_id = fixture.registry_id;
    let pool_id = fixture.pool_id;
    let wrapper_id = fixture.wrapper_id;

    fixture.scenario.next_tx(SESSION);
    let registry = fixture.scenario.take_shared_by_id<Registry>(registry_id);
    let account_registry = fixture.scenario.take_shared<AccountRegistry>();
    let mut pool = fixture.scenario.take_shared_by_id<Pool<BASE, QUOTE>>(pool_id);
    let mut wrapper = fixture.scenario.take_shared_by_id<AccountWrapper>(wrapper_id);
    let sessions_config = fixture
        .scenario
        .take_shared_by_id<SessionsConfig>(fixture.sessions_config_id);
    let root = fixture.scenario.take_shared<AccumulatorRoot>();
    let clock = fixture.scenario.take_shared<Clock>();
    let _ = sessions::place_limit_order<BASE, QUOTE>(
        &mut pool,
        &registry,
        &account_registry,
        &mut wrapper,
        &sessions_config,
        LIMIT_ORDER_CLIENT_ID,
        constants::no_restriction(),
        constants::self_matching_allowed(),
        constants::float_scaling(),
        constants::min_size(),
        false,
        true,
        constants::max_u64(),
        &root,
        &clock,
        fixture.scenario.ctx(),
    );
    abort EUnexpectedSuccess
}

#[test, expected_failure(abort_code = sessions::ESessionNotAuthorized)]
fun session_at_exact_expiration_cannot_place_spot_market_order() {
    let mut fixture = setup_spot_fixture();
    authorize_session(&mut fixture);
    set_clock(&mut fixture, SESSION_EXPIRES_AT_MS);
    let registry_id = fixture.registry_id;
    let pool_id = fixture.pool_id;
    let wrapper_id = fixture.wrapper_id;

    fixture.scenario.next_tx(SESSION);
    let registry = fixture.scenario.take_shared_by_id<Registry>(registry_id);
    let account_registry = fixture.scenario.take_shared<AccountRegistry>();
    let mut pool = fixture.scenario.take_shared_by_id<Pool<BASE, QUOTE>>(pool_id);
    let mut wrapper = fixture.scenario.take_shared_by_id<AccountWrapper>(wrapper_id);
    let sessions_config = fixture
        .scenario
        .take_shared_by_id<SessionsConfig>(fixture.sessions_config_id);
    let root = fixture.scenario.take_shared<AccumulatorRoot>();
    let clock = fixture.scenario.take_shared<Clock>();
    let _ = sessions::place_market_order<BASE, QUOTE>(
        &mut pool,
        &registry,
        &account_registry,
        &mut wrapper,
        &sessions_config,
        MARKET_TAKER_CLIENT_ID,
        constants::self_matching_allowed(),
        constants::min_size(),
        constants::float_scaling(),
        true,
        true,
        &root,
        &clock,
        fixture.scenario.ctx(),
    );
    abort EUnexpectedSuccess
}

#[test, expected_failure(abort_code = sessions::ESessionNotAuthorized)]
fun revoked_session_cannot_cancel_spot_order() {
    let mut fixture = setup_spot_fixture();
    authorize_session(&mut fixture);
    revoke_session(&mut fixture);
    let pool_id = fixture.pool_id;
    let wrapper_id = fixture.wrapper_id;

    fixture.scenario.next_tx(SESSION);
    let account_registry = fixture.scenario.take_shared<AccountRegistry>();
    let mut pool = fixture.scenario.take_shared_by_id<Pool<BASE, QUOTE>>(pool_id);
    let mut wrapper = fixture.scenario.take_shared_by_id<AccountWrapper>(wrapper_id);
    let sessions_config = fixture
        .scenario
        .take_shared_by_id<SessionsConfig>(fixture.sessions_config_id);
    let clock = fixture.scenario.take_shared<Clock>();
    sessions::cancel_live_order<BASE, QUOTE>(
        &mut pool,
        &account_registry,
        &mut wrapper,
        &sessions_config,
        ZERO_ORDER_ID,
        &clock,
        fixture.scenario.ctx(),
    );
    abort EUnexpectedSuccess
}

#[test, expected_failure(abort_code = session_config::EPackageVersionDisabled)]
fun retired_package_version_cannot_use_spot_wrapper() {
    let mut fixture = setup_spot_fixture();
    authorize_session(&mut fixture);
    let sessions_config_id = fixture.sessions_config_id;
    let pool_id = fixture.pool_id;
    let wrapper_id = fixture.wrapper_id;

    fixture.scenario.next_tx(ADMIN);
    let mut sessions_config = fixture
        .scenario
        .take_shared_by_id<SessionsConfig>(sessions_config_id);
    session_config::set_version_watermark_for_testing(&mut sessions_config, FUTURE_VERSION);
    return_shared(sessions_config);

    fixture.scenario.next_tx(SESSION);
    let account_registry = fixture.scenario.take_shared<AccountRegistry>();
    let mut pool = fixture.scenario.take_shared_by_id<Pool<BASE, QUOTE>>(pool_id);
    let mut wrapper = fixture.scenario.take_shared_by_id<AccountWrapper>(wrapper_id);
    let sessions_config = fixture.scenario.take_shared_by_id<SessionsConfig>(sessions_config_id);
    let clock = fixture.scenario.take_shared<Clock>();
    sessions::cancel_live_order<BASE, QUOTE>(
        &mut pool,
        &account_registry,
        &mut wrapper,
        &sessions_config,
        ZERO_ORDER_ID,
        &clock,
        fixture.scenario.ctx(),
    );
    abort EUnexpectedSuccess
}

fun setup_spot_fixture(): SpotFixture {
    let mut scenario = test::begin(ADMIN);

    scenario.next_tx(@0x0);
    accumulator::create_for_testing(scenario.ctx());

    scenario.next_tx(ADMIN);
    let registry_id = registry::test_registry(scenario.ctx());
    account_registry::init_for_testing(scenario.ctx());
    let (sessions_config_id, sessions_admin_cap) = session_config::init_for_testing(scenario.ctx());
    destroy(sessions_admin_cap);
    let mut clock = clock::create_for_testing(scenario.ctx());
    clock.set_for_testing(NOW_MS);
    clock.share_for_testing();
    let pool_id = create_pool(&mut scenario, registry_id);
    authorize_core_app(&mut scenario, registry_id);
    authorize_sessions_app(&mut scenario);

    scenario.next_tx(ALICE);
    let mut account_registry = scenario.take_shared<AccountRegistry>();
    let mut wrapper = account_registry.new(scenario.ctx());
    let account = wrapper.load_account_mut(account::generate_auth(scenario.ctx()));
    account.deposit<BASE>(coin::mint_for_testing<BASE>(ACCOUNT_BALANCE, scenario.ctx()));
    account.deposit<QUOTE>(coin::mint_for_testing<QUOTE>(ACCOUNT_BALANCE, scenario.ctx()));
    account.deposit<DEEP>(coin::mint_for_testing<DEEP>(ACCOUNT_BALANCE, scenario.ctx()));
    let wrapper_id = wrapper.id();
    wrapper.share();
    return_shared(account_registry);

    SpotFixture { scenario, registry_id, pool_id, wrapper_id, sessions_config_id }
}

fun authorize_session(fixture: &mut SpotFixture) {
    let wrapper_id = fixture.wrapper_id;
    fixture.scenario.next_tx(ALICE);
    let mut wrapper = fixture.scenario.take_shared_by_id<AccountWrapper>(wrapper_id);
    let sessions_config = fixture
        .scenario
        .take_shared_by_id<SessionsConfig>(fixture.sessions_config_id);
    let clock = fixture.scenario.take_shared<Clock>();
    sessions::authorize_session(
        &mut wrapper,
        &sessions_config,
        SESSION,
        SESSION_DURATION_MS,
        &clock,
        fixture.scenario.ctx(),
    );
    assert_eq!(
        sessions::session_expiration_ms(&wrapper, SESSION),
        option::some(SESSION_EXPIRES_AT_MS),
    );
    return_shared(clock);
    return_shared(sessions_config);
    return_shared(wrapper);
}

fun revoke_session(fixture: &mut SpotFixture) {
    let wrapper_id = fixture.wrapper_id;
    fixture.scenario.next_tx(ALICE);
    let mut wrapper = fixture.scenario.take_shared_by_id<AccountWrapper>(wrapper_id);
    sessions::revoke_session(&mut wrapper, SESSION, fixture.scenario.ctx());
    assert!(sessions::session_expiration_ms(&wrapper, SESSION).is_none());
    return_shared(wrapper);
}

fun set_clock(fixture: &mut SpotFixture, timestamp_ms: u64) {
    fixture.scenario.next_tx(ADMIN);
    let mut clock = fixture.scenario.take_shared<Clock>();
    clock.set_for_testing(timestamp_ms);
    assert_eq!(clock.timestamp_ms(), timestamp_ms);
    return_shared(clock);
}

fun create_balance_manager_with_funds(fixture: &mut SpotFixture): ID {
    fixture.scenario.next_tx(BOB);
    let mut manager = balance_manager::new(fixture.scenario.ctx());
    manager.deposit<BASE>(
        coin::mint_for_testing<BASE>(ACCOUNT_BALANCE, fixture.scenario.ctx()),
        fixture.scenario.ctx(),
    );
    manager.deposit<QUOTE>(
        coin::mint_for_testing<QUOTE>(ACCOUNT_BALANCE, fixture.scenario.ctx()),
        fixture.scenario.ctx(),
    );
    manager.deposit<DEEP>(
        coin::mint_for_testing<DEEP>(ACCOUNT_BALANCE, fixture.scenario.ctx()),
        fixture.scenario.ctx(),
    );
    let manager_id = manager.id();
    transfer::public_share_object(manager);
    manager_id
}

fun place_manager_limit_order(
    fixture: &mut SpotFixture,
    manager_id: ID,
    client_order_id: u64,
    quantity: u64,
    is_bid: bool,
): OrderInfo {
    let pool_id = fixture.pool_id;
    fixture.scenario.next_tx(BOB);
    let mut pool = fixture.scenario.take_shared_by_id<Pool<BASE, QUOTE>>(pool_id);
    let clock = fixture.scenario.take_shared<Clock>();
    let mut manager = fixture.scenario.take_shared_by_id<BalanceManager>(manager_id);
    let proof = manager.generate_proof_as_owner(fixture.scenario.ctx());
    let info = pool.place_limit_order<BASE, QUOTE>(
        &mut manager,
        &proof,
        client_order_id,
        constants::no_restriction(),
        constants::self_matching_allowed(),
        constants::float_scaling(),
        quantity,
        is_bid,
        true,
        constants::max_u64(),
        &clock,
        fixture.scenario.ctx(),
    );
    return_shared(manager);
    return_shared(clock);
    return_shared(pool);
    info
}

fun place_manager_market_order(
    fixture: &mut SpotFixture,
    manager_id: ID,
    client_order_id: u64,
    quantity: u64,
    is_bid: bool,
): OrderInfo {
    let pool_id = fixture.pool_id;
    fixture.scenario.next_tx(BOB);
    let mut pool = fixture.scenario.take_shared_by_id<Pool<BASE, QUOTE>>(pool_id);
    let clock = fixture.scenario.take_shared<Clock>();
    let mut manager = fixture.scenario.take_shared_by_id<BalanceManager>(manager_id);
    let proof = manager.generate_proof_as_owner(fixture.scenario.ctx());
    let info = pool.place_market_order<BASE, QUOTE>(
        &mut manager,
        &proof,
        client_order_id,
        constants::self_matching_allowed(),
        quantity,
        is_bid,
        true,
        &clock,
        fixture.scenario.ctx(),
    );
    return_shared(manager);
    return_shared(clock);
    return_shared(pool);
    info
}

fun authorize_core_app(scenario: &mut Scenario, registry_id: ID) {
    scenario.next_tx(ADMIN);
    let admin_cap = registry::get_admin_cap_for_testing(scenario.ctx());
    let mut registry = scenario.take_shared_by_id<Registry>(registry_id);
    registry.authorize_app<DeepbookCoreAccountApp>(&admin_cap);
    return_shared(registry);
    destroy(admin_cap);
}

fun authorize_sessions_app(scenario: &mut Scenario) {
    scenario.next_tx(ADMIN);
    let admin_cap = scenario.take_from_sender<AccountAdminCap>();
    let mut registry = scenario.take_shared<AccountRegistry>();
    registry.authorize_app<SessionsApp>(&admin_cap);
    return_shared(registry);
    destroy(admin_cap);
}

fun create_pool(scenario: &mut Scenario, registry_id: ID): ID {
    scenario.next_tx(ADMIN);
    let admin_cap = registry::get_admin_cap_for_testing(scenario.ctx());
    let mut registry = scenario.take_shared_by_id<Registry>(registry_id);
    let pool_id = pool::create_pool_admin<BASE, QUOTE>(
        &mut registry,
        constants::tick_size(),
        constants::lot_size(),
        constants::min_size(),
        true,
        false,
        &admin_cap,
        scenario.ctx(),
    );
    return_shared(registry);
    destroy(admin_cap);
    pool_id
}

fun finish_spot_fixture(fixture: SpotFixture) {
    let SpotFixture {
        scenario,
        registry_id: _,
        pool_id: _,
        wrapper_id: _,
        sessions_config_id: _,
    } = fixture;
    scenario.end();
}
