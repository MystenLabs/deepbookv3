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
    session_config::{Self as session_config, SessionsAdminCap, SessionsConfig},
    sessions::{Self as sessions, SessionsApp}
};
use std::unit_test::{assert_eq, destroy};
use sui::{
    accumulator::{Self as accumulator, AccumulatorRoot},
    clock::{Self as clock, Clock},
    coin,
    event,
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
const FUTURE_VERSION: u64 = 5;
// Spend budgets, in multiples of the minimum order size the tests trade.
const TWO_ORDERS: u64 = 2;
const FIVE_ORDERS: u64 = 5;
const NO_BUDGET: u64 = 0;
// Fees on a minimum-size order at price 1 in a pool with DeepBook's default
// 10 bps taker and 5 bps maker fees, paid in the spent asset at DeepBook's 1.25x
// penalty: floor(10_000 * 1.25 * 0.001) = floor(12.5) and
// floor(10_000 * 1.25 * 0.0005) = floor(6.25).
const TAKER_FEE_ON_MIN_ORDER: u64 = 12;
const MAKER_FEE_ON_MIN_ORDER: u64 = 6;
const LAST_VERSION_BEFORE_GRANT_TERMS: u64 = 3;

public struct BASE has store {}
public struct QUOTE has store {}
/// The base asset of a second pool, which the allowlist does not name.
public struct JUNK has store {}

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
    approve_full_spend(&mut fixture);
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
    approve_full_spend(&mut fixture);
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
    approve_full_spend(&mut fixture);
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

#[test, expected_failure(abort_code = session_config::EPoolNotAllowed)]
fun session_cannot_place_limit_order_on_an_unlisted_pool() {
    let mut fixture = setup_spot_fixture();
    let registry_id = fixture.registry_id;
    let junk_pool_id = create_pool<JUNK, QUOTE>(&mut fixture.scenario, registry_id);
    authorize_session(&mut fixture);

    session_limit_order<JUNK, QUOTE>(&mut fixture, junk_pool_id, LIMIT_ORDER_CLIENT_ID, true);
    abort EUnexpectedSuccess
}

#[test, expected_failure(abort_code = session_config::EPoolNotAllowed)]
fun session_cannot_place_market_order_on_an_unlisted_pool() {
    let mut fixture = setup_spot_fixture();
    let registry_id = fixture.registry_id;
    let junk_pool_id = create_pool<JUNK, QUOTE>(&mut fixture.scenario, registry_id);
    authorize_session(&mut fixture);

    session_market_order<JUNK, QUOTE>(&mut fixture, junk_pool_id, true);
    abort EUnexpectedSuccess
}

#[test, expected_failure(abort_code = session_config::EPoolNotAllowed)]
fun session_spot_orders_fail_closed_before_any_pool_is_allowed() {
    let mut fixture = setup_unlisted_spot_fixture();
    authorize_session(&mut fixture);
    let pool_id = fixture.pool_id;

    session_limit_order<BASE, QUOTE>(&mut fixture, pool_id, LIMIT_ORDER_CLIENT_ID, false);
    abort EUnexpectedSuccess
}

#[test, expected_failure(abort_code = session_config::EPoolNotAllowed)]
fun session_cannot_place_order_on_a_disallowed_pool() {
    let mut fixture = setup_spot_fixture();
    authorize_session(&mut fixture);
    let pool_id = fixture.pool_id;
    admin_disallow_pool(&mut fixture, pool_id);

    session_market_order<BASE, QUOTE>(&mut fixture, pool_id, true);
    abort EUnexpectedSuccess
}

#[test]
fun session_cancels_an_order_on_a_disallowed_pool() {
    let mut fixture = setup_spot_fixture();
    authorize_session(&mut fixture);
    approve_full_spend(&mut fixture);
    let pool_id = fixture.pool_id;
    let wrapper_id = fixture.wrapper_id;
    let order = session_limit_order<BASE, QUOTE>(
        &mut fixture,
        pool_id,
        LIMIT_ORDER_CLIENT_ID,
        false,
    );
    assert_eq!(order.status(), constants::live());
    admin_disallow_pool(&mut fixture, pool_id);

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
        order.order_id(),
        &clock,
        fixture.scenario.ctx(),
    );
    assert_eq!(
        dca::pool_account_open_orders<BASE, QUOTE>(&pool, wrapper.load_account()).length(),
        NO_OPEN_ORDERS,
    );
    // Cancelling returns the locked base to Account custody in full.
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
fun limit_order_charges_the_quote_it_locks() {
    let mut fixture = setup_spot_fixture();
    authorize_session(&mut fixture);
    let trade_amount = constants::min_size();
    approve_spend<QUOTE>(&mut fixture, FIVE_ORDERS * trade_amount);
    let pool_id = fixture.pool_id;

    // A bid for `trade_amount` at price 1 rests on the empty book and locks
    // `trade_amount` of quote. The fixture pool charges no fees, so no DEEP
    // moves and the session needs no DEEP budget.
    let bid = session_limit_order<BASE, QUOTE>(&mut fixture, pool_id, LIMIT_ORDER_CLIENT_ID, true);
    assert_eq!(bid.status(), constants::live());

    assert_eq!(spend_remaining<QUOTE>(&mut fixture), (FIVE_ORDERS - 1) * trade_amount);
    assert_eq!(spend_remaining<BASE>(&mut fixture), NO_BUDGET);
    assert_eq!(account_balance<QUOTE>(&mut fixture), ACCOUNT_BALANCE - trade_amount);
    finish_spot_fixture(fixture);
}

#[test]
fun order_for_exactly_the_budget_spends_it_all() {
    let mut fixture = setup_spot_fixture();
    authorize_session(&mut fixture);
    let trade_amount = constants::min_size();
    approve_spend<QUOTE>(&mut fixture, trade_amount);
    let pool_id = fixture.pool_id;

    session_limit_order<BASE, QUOTE>(&mut fixture, pool_id, LIMIT_ORDER_CLIENT_ID, true);

    assert_eq!(spend_remaining<QUOTE>(&mut fixture), NO_BUDGET);
    finish_spot_fixture(fixture);
}

#[test, expected_failure(abort_code = sessions::ESpendLimitExceeded)]
fun order_above_the_budget_aborts() {
    let mut fixture = setup_spot_fixture();
    authorize_session(&mut fixture);
    let trade_amount = constants::min_size();
    approve_spend<QUOTE>(&mut fixture, trade_amount - 1);
    let pool_id = fixture.pool_id;

    session_limit_order<BASE, QUOTE>(&mut fixture, pool_id, LIMIT_ORDER_CLIENT_ID, true);
    abort EUnexpectedSuccess
}

#[test, expected_failure(abort_code = sessions::ESpendLimitExceeded)]
fun order_without_a_budget_aborts() {
    let mut fixture = setup_spot_fixture();
    authorize_session(&mut fixture);
    let pool_id = fixture.pool_id;

    session_limit_order<BASE, QUOTE>(&mut fixture, pool_id, LIMIT_ORDER_CLIENT_ID, false);
    abort EUnexpectedSuccess
}

#[test, expected_failure(abort_code = sessions::ESpendLimitExceeded)]
fun budget_for_another_asset_does_not_cover_the_order() {
    let mut fixture = setup_spot_fixture();
    authorize_session(&mut fixture);
    approve_spend<BASE>(&mut fixture, ACCOUNT_BALANCE);
    let pool_id = fixture.pool_id;

    // A bid spends quote, and the session holds only a base budget.
    session_limit_order<BASE, QUOTE>(&mut fixture, pool_id, LIMIT_ORDER_CLIENT_ID, true);
    abort EUnexpectedSuccess
}

#[test]
fun market_fill_charges_only_the_asset_it_spends() {
    let mut fixture = setup_spot_fixture();
    let maker_id = create_balance_manager_with_funds(&mut fixture);
    let trade_amount = constants::min_size();
    place_manager_limit_order(&mut fixture, maker_id, MARKET_MAKER_CLIENT_ID, trade_amount, false);
    authorize_session(&mut fixture);
    approve_spend<QUOTE>(&mut fixture, TWO_ORDERS * trade_amount);
    let pool_id = fixture.pool_id;

    // The bid fills `trade_amount` at price 1: it spends that much quote and
    // receives that much base, and receiving never adds to a budget.
    let fill = session_market_order<BASE, QUOTE>(&mut fixture, pool_id, true);
    assert_eq!(fill.status(), constants::filled());

    assert_eq!(spend_remaining<QUOTE>(&mut fixture), trade_amount);
    assert_eq!(spend_remaining<BASE>(&mut fixture), NO_BUDGET);
    assert_eq!(account_balance<BASE>(&mut fixture), ACCOUNT_BALANCE + trade_amount);
    finish_spot_fixture(fixture);
}

#[test]
fun cancel_does_not_restore_the_budget() {
    let mut fixture = setup_spot_fixture();
    authorize_session(&mut fixture);
    let trade_amount = constants::min_size();
    approve_spend<BASE>(&mut fixture, trade_amount);
    let pool_id = fixture.pool_id;
    let wrapper_id = fixture.wrapper_id;
    let ask = session_limit_order<BASE, QUOTE>(&mut fixture, pool_id, LIMIT_ORDER_CLIENT_ID, false);
    assert_eq!(spend_remaining<BASE>(&mut fixture), NO_BUDGET);

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
        ask.order_id(),
        &clock,
        fixture.scenario.ctx(),
    );
    return_shared(clock);
    return_shared(sessions_config);
    return_shared(wrapper);
    return_shared(pool);
    return_shared(account_registry);

    // The locked base is back in the Account, and the budget stays spent.
    assert_eq!(account_balance<BASE>(&mut fixture), ACCOUNT_BALANCE);
    assert_eq!(spend_remaining<BASE>(&mut fixture), NO_BUDGET);
    finish_spot_fixture(fixture);
}

#[test]
fun settled_proceeds_do_not_offset_the_next_order() {
    let mut fixture = setup_spot_fixture();
    let bob_manager_id = create_balance_manager_with_funds(&mut fixture);
    authorize_session(&mut fixture);
    let trade_amount = constants::min_size();
    approve_spend<BASE>(&mut fixture, trade_amount);
    approve_spend<QUOTE>(&mut fixture, trade_amount);
    let pool_id = fixture.pool_id;

    // The session's ask fills against Bob, which leaves `trade_amount` of quote
    // settled in the pool for the Account.
    session_limit_order<BASE, QUOTE>(&mut fixture, pool_id, LIMIT_ORDER_CLIENT_ID, false);
    let fill = place_manager_market_order(
        &mut fixture,
        bob_manager_id,
        FILLING_BID_CLIENT_ID,
        trade_amount,
        true,
    );
    assert_eq!(fill.executed_quantity(), trade_amount);

    // The next bid locks `trade_amount` of quote. The settled quote reaches the
    // Account before the bid is measured, so the bid is charged in full.
    session_limit_order<BASE, QUOTE>(
        &mut fixture,
        pool_id,
        SECOND_LIMIT_ORDER_CLIENT_ID,
        true,
    );

    assert_eq!(spend_remaining<QUOTE>(&mut fixture), NO_BUDGET);
    // + trade_amount settled from the ask, - trade_amount locked by the bid.
    assert_eq!(account_balance<QUOTE>(&mut fixture), ACCOUNT_BALANCE);
    finish_spot_fixture(fixture);
}

#[test]
fun ask_on_a_deep_base_pool_charges_the_deep_budget() {
    let mut fixture = setup_spot_fixture();
    let registry_id = fixture.registry_id;
    let deep_pool_id = create_pool<DEEP, QUOTE>(&mut fixture.scenario, registry_id);
    admin_allow_pool(&mut fixture, deep_pool_id);
    authorize_session(&mut fixture);
    let trade_amount = constants::min_size();
    approve_spend<DEEP>(&mut fixture, trade_amount);

    // An ask for `trade_amount` of DEEP locks exactly that much DEEP, and the
    // fixture's pools charge no fees.
    session_limit_order<DEEP, QUOTE>(&mut fixture, deep_pool_id, LIMIT_ORDER_CLIENT_ID, false);

    assert_eq!(spend_remaining<DEEP>(&mut fixture), NO_BUDGET);
    assert_eq!(account_balance<DEEP>(&mut fixture), ACCOUNT_BALANCE - trade_amount);
    finish_spot_fixture(fixture);
}

#[test]
fun approving_replaces_the_budget_and_zero_removes_it() {
    let mut fixture = setup_spot_fixture();
    authorize_session(&mut fixture);
    let trade_amount = constants::min_size();
    approve_spend<QUOTE>(&mut fixture, FIVE_ORDERS * trade_amount);
    approve_spend<QUOTE>(&mut fixture, TWO_ORDERS * trade_amount);
    assert_eq!(spend_remaining<QUOTE>(&mut fixture), TWO_ORDERS * trade_amount);

    approve_spend<QUOTE>(&mut fixture, NO_BUDGET);

    assert_eq!(spend_remaining<QUOTE>(&mut fixture), NO_BUDGET);
    finish_spot_fixture(fixture);
}

#[test]
fun revoking_clears_the_budgets_and_reauthorizing_keeps_them() {
    let mut fixture = setup_spot_fixture();
    authorize_session(&mut fixture);
    let trade_amount = constants::min_size();
    approve_spend<QUOTE>(&mut fixture, trade_amount);

    authorize_session(&mut fixture);
    assert_eq!(spend_remaining<QUOTE>(&mut fixture), trade_amount);

    revoke_session(&mut fixture);
    assert_eq!(event::events_by_type<sessions::SessionSpendCleared>().length(), 1);
    authorize_session(&mut fixture);
    assert_eq!(spend_remaining<QUOTE>(&mut fixture), NO_BUDGET);
    finish_spot_fixture(fixture);
}

#[test, expected_failure(abort_code = sessions::ESessionNotAuthorized)]
fun approving_spend_for_an_unauthorized_session_aborts() {
    let mut fixture = setup_spot_fixture();

    approve_spend<QUOTE>(&mut fixture, ACCOUNT_BALANCE);
    abort EUnexpectedSuccess
}

#[test, expected_failure(abort_code = account::EInvalidOwner)]
fun only_the_owner_can_approve_spend() {
    let mut fixture = setup_spot_fixture();
    authorize_session(&mut fixture);
    let wrapper_id = fixture.wrapper_id;

    fixture.scenario.next_tx(SESSION);
    let mut wrapper = fixture.scenario.take_shared_by_id<AccountWrapper>(wrapper_id);
    let sessions_config = fixture
        .scenario
        .take_shared_by_id<SessionsConfig>(fixture.sessions_config_id);
    sessions::approve_session_spend<QUOTE>(
        &mut wrapper,
        &sessions_config,
        SESSION,
        ACCOUNT_BALANCE,
        fixture.scenario.ctx(),
    );
    abort EUnexpectedSuccess
}

#[test, expected_failure(abort_code = session_config::EPackageVersionDisabled)]
fun retired_package_version_cannot_approve_spend() {
    let mut fixture = setup_spot_fixture();
    authorize_session(&mut fixture);
    let sessions_config_id = fixture.sessions_config_id;
    fixture.scenario.next_tx(ADMIN);
    let mut sessions_config = fixture
        .scenario
        .take_shared_by_id<SessionsConfig>(sessions_config_id);
    session_config::set_version_watermark_for_testing(&mut sessions_config, FUTURE_VERSION);
    return_shared(sessions_config);

    approve_spend<QUOTE>(&mut fixture, ACCOUNT_BALANCE);
    abort EUnexpectedSuccess
}

#[test]
fun resting_order_charges_its_maker_fee() {
    let mut fixture = setup_spot_fixture();
    let fee_pool_id = setup_fee_pool(&mut fixture);
    authorize_session(&mut fixture);
    let trade_amount = constants::min_size();
    approve_spend<JUNK>(&mut fixture, trade_amount + MAKER_FEE_ON_MIN_ORDER);

    // The ask rests on the empty book: it locks `trade_amount` of base and
    // reserves the maker fee in base.
    let ask = session_order_paying_input_fees<JUNK, QUOTE>(
        &mut fixture,
        fee_pool_id,
        LIMIT_ORDER_CLIENT_ID,
        trade_amount,
        false,
    );
    assert_eq!(ask.status(), constants::live());

    assert_eq!(spend_remaining<JUNK>(&mut fixture), NO_BUDGET);
    assert_eq!(
        account_balance<JUNK>(&mut fixture),
        ACCOUNT_BALANCE - trade_amount - MAKER_FEE_ON_MIN_ORDER,
    );
    finish_spot_fixture(fixture);
}

#[test]
fun taker_fill_charges_its_taker_fee() {
    let mut fixture = setup_spot_fixture();
    let fee_pool_id = setup_fee_pool(&mut fixture);
    let maker_id = create_balance_manager_with_funds(&mut fixture);
    let trade_amount = constants::min_size();
    place_manager_order_paying_input_fees<JUNK, QUOTE>(
        &mut fixture,
        fee_pool_id,
        maker_id,
        MARKET_MAKER_CLIENT_ID,
        true,
    );
    authorize_session(&mut fixture);
    approve_spend<JUNK>(&mut fixture, trade_amount + TAKER_FEE_ON_MIN_ORDER);

    // The ask fills against Bob's bid: it sells `trade_amount` of base and pays
    // the taker fee in base. The quote it receives adds nothing to a budget.
    let ask = session_order_paying_input_fees<JUNK, QUOTE>(
        &mut fixture,
        fee_pool_id,
        LIMIT_ORDER_CLIENT_ID,
        trade_amount,
        false,
    );
    assert_eq!(ask.status(), constants::filled());

    assert_eq!(spend_remaining<JUNK>(&mut fixture), NO_BUDGET);
    assert_eq!(spend_remaining<QUOTE>(&mut fixture), NO_BUDGET);
    finish_spot_fixture(fixture);
}

#[test]
fun self_matched_fill_is_charged_in_full() {
    let mut fixture = setup_spot_fixture();
    let fee_pool_id = setup_fee_pool(&mut fixture);
    authorize_session(&mut fixture);
    let trade_amount = constants::min_size();
    approve_spend<QUOTE>(&mut fixture, trade_amount + MAKER_FEE_ON_MIN_ORDER);
    approve_spend<JUNK>(&mut fixture, trade_amount + TAKER_FEE_ON_MIN_ORDER);

    // The session's own bid rests first, then its ask fills against it. The
    // Account receives its own quote and base back, and the ask is still
    // charged everything it sold and paid.
    session_order_paying_input_fees<JUNK, QUOTE>(
        &mut fixture,
        fee_pool_id,
        LIMIT_ORDER_CLIENT_ID,
        trade_amount,
        true,
    );
    let ask = session_order_paying_input_fees<JUNK, QUOTE>(
        &mut fixture,
        fee_pool_id,
        SECOND_LIMIT_ORDER_CLIENT_ID,
        trade_amount,
        false,
    );
    assert_eq!(ask.executed_quantity(), trade_amount);

    assert_eq!(spend_remaining<QUOTE>(&mut fixture), NO_BUDGET);
    assert_eq!(spend_remaining<JUNK>(&mut fixture), NO_BUDGET);
    finish_spot_fixture(fixture);
}

#[test]
fun partial_fill_charges_the_fill_the_remainder_and_both_fees() {
    let mut fixture = setup_spot_fixture();
    let fee_pool_id = setup_fee_pool(&mut fixture);
    let maker_id = create_balance_manager_with_funds(&mut fixture);
    let trade_amount = constants::min_size();
    place_manager_order_paying_input_fees<JUNK, QUOTE>(
        &mut fixture,
        fee_pool_id,
        maker_id,
        MARKET_MAKER_CLIENT_ID,
        true,
    );
    authorize_session(&mut fixture);
    // The ask for twice the minimum fills `trade_amount` against Bob's bid and
    // rests the other `trade_amount`: it is charged both halves, the taker fee
    // on the fill and the maker fee on the remainder.
    let charge = TWO_ORDERS * trade_amount + TAKER_FEE_ON_MIN_ORDER + MAKER_FEE_ON_MIN_ORDER;
    approve_spend<JUNK>(&mut fixture, charge);

    let ask = session_order_paying_input_fees<JUNK, QUOTE>(
        &mut fixture,
        fee_pool_id,
        LIMIT_ORDER_CLIENT_ID,
        TWO_ORDERS * trade_amount,
        false,
    );
    assert_eq!(ask.executed_quantity(), trade_amount);
    assert!(ask.order_inserted());

    assert_eq!(spend_remaining<JUNK>(&mut fixture), NO_BUDGET);
    assert_eq!(account_balance<JUNK>(&mut fixture), ACCOUNT_BALANCE - charge);
    finish_spot_fixture(fixture);
}

#[test]
fun new_grant_clears_a_budget_the_pre_upgrade_revoke_left() {
    let mut fixture = setup_spot_fixture();
    authorize_session(&mut fixture);
    approve_spend<QUOTE>(&mut fixture, ACCOUNT_BALANCE);
    let wrapper_id = fixture.wrapper_id;

    // The pre-upgrade `revoke_session` removes the session but not its budget.
    fixture.scenario.next_tx(ALICE);
    let mut wrapper = fixture.scenario.take_shared_by_id<AccountWrapper>(wrapper_id);
    sessions::revoke_session_without_builder_for_testing(
        &mut wrapper,
        SESSION,
        fixture.scenario.ctx(),
    );
    assert_eq!(sessions::session_spend_remaining<QUOTE>(&wrapper, SESSION), ACCOUNT_BALANCE);
    return_shared(wrapper);

    authorize_session(&mut fixture);

    assert_eq!(spend_remaining<QUOTE>(&mut fixture), NO_BUDGET);
    finish_spot_fixture(fixture);
}

#[test, expected_failure(abort_code = sessions::ESpendApprovalsNotEnabled)]
fun approving_spend_before_the_watermark_reaches_4_aborts() {
    let mut fixture = setup_spot_fixture();
    authorize_session(&mut fixture);
    let sessions_config_id = fixture.sessions_config_id;
    fixture.scenario.next_tx(ADMIN);
    let mut sessions_config = fixture
        .scenario
        .take_shared_by_id<SessionsConfig>(sessions_config_id);
    session_config::set_version_watermark_for_testing(
        &mut sessions_config,
        LAST_VERSION_BEFORE_GRANT_TERMS,
    );
    return_shared(sessions_config);

    approve_spend<QUOTE>(&mut fixture, ACCOUNT_BALANCE);
    abort EUnexpectedSuccess
}

/// The spot fixture with its pool on the session allowlist.
fun setup_spot_fixture(): SpotFixture {
    let mut fixture = setup_unlisted_spot_fixture();
    let pool_id = fixture.pool_id;
    admin_allow_pool(&mut fixture, pool_id);
    fixture
}

fun setup_unlisted_spot_fixture(): SpotFixture {
    let mut scenario = test::begin(ADMIN);

    scenario.next_tx(@0x0);
    accumulator::create_for_testing(scenario.ctx());

    scenario.next_tx(ADMIN);
    let registry_id = registry::test_registry(scenario.ctx());
    account_registry::init_for_testing(scenario.ctx());
    let (sessions_config_id, sessions_admin_cap) = session_config::init_for_testing(scenario.ctx());
    transfer::public_transfer(sessions_admin_cap, ADMIN);
    let mut clock = clock::create_for_testing(scenario.ctx());
    clock.set_for_testing(NOW_MS);
    clock.share_for_testing();
    let pool_id = create_pool<BASE, QUOTE>(&mut scenario, registry_id);
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

fun admin_allow_pool(fixture: &mut SpotFixture, pool_id: ID) {
    fixture.scenario.next_tx(ADMIN);
    let admin_cap = fixture.scenario.take_from_sender<SessionsAdminCap>();
    let mut sessions_config = fixture
        .scenario
        .take_shared_by_id<SessionsConfig>(fixture.sessions_config_id);
    sessions_config.admin_allow_pool(&admin_cap, pool_id);
    assert!(sessions_config.allowed_pools().contains(&pool_id));
    return_shared(sessions_config);
    fixture.scenario.return_to_sender(admin_cap);
}

fun admin_disallow_pool(fixture: &mut SpotFixture, pool_id: ID) {
    fixture.scenario.next_tx(ADMIN);
    let admin_cap = fixture.scenario.take_from_sender<SessionsAdminCap>();
    let mut sessions_config = fixture
        .scenario
        .take_shared_by_id<SessionsConfig>(fixture.sessions_config_id);
    sessions_config.admin_disallow_pool(&admin_cap, pool_id);
    assert!(!sessions_config.allowed_pools().contains(&pool_id));
    return_shared(sessions_config);
    fixture.scenario.return_to_sender(admin_cap);
}

/// A session-key limit order for the minimum size at price 1.
fun session_limit_order<BaseAsset, QuoteAsset>(
    fixture: &mut SpotFixture,
    pool_id: ID,
    client_order_id: u64,
    is_bid: bool,
): OrderInfo {
    let registry_id = fixture.registry_id;
    let wrapper_id = fixture.wrapper_id;
    fixture.scenario.next_tx(SESSION);
    let registry = fixture.scenario.take_shared_by_id<Registry>(registry_id);
    let account_registry = fixture.scenario.take_shared<AccountRegistry>();
    let mut pool = fixture.scenario.take_shared_by_id<Pool<BaseAsset, QuoteAsset>>(pool_id);
    let mut wrapper = fixture.scenario.take_shared_by_id<AccountWrapper>(wrapper_id);
    let sessions_config = fixture
        .scenario
        .take_shared_by_id<SessionsConfig>(fixture.sessions_config_id);
    let root = fixture.scenario.take_shared<AccumulatorRoot>();
    let clock = fixture.scenario.take_shared<Clock>();
    let info = sessions::place_limit_order<BaseAsset, QuoteAsset>(
        &mut pool,
        &registry,
        &account_registry,
        &mut wrapper,
        &sessions_config,
        client_order_id,
        constants::no_restriction(),
        constants::self_matching_allowed(),
        constants::float_scaling(),
        constants::min_size(),
        is_bid,
        true,
        constants::max_u64(),
        &root,
        &clock,
        fixture.scenario.ctx(),
    );
    return_shared(clock);
    return_shared(root);
    return_shared(sessions_config);
    return_shared(wrapper);
    return_shared(pool);
    return_shared(account_registry);
    return_shared(registry);
    info
}

/// A session-key market order for the minimum size with a price limit of 1.
fun session_market_order<BaseAsset, QuoteAsset>(
    fixture: &mut SpotFixture,
    pool_id: ID,
    is_bid: bool,
): OrderInfo {
    let registry_id = fixture.registry_id;
    let wrapper_id = fixture.wrapper_id;
    fixture.scenario.next_tx(SESSION);
    let registry = fixture.scenario.take_shared_by_id<Registry>(registry_id);
    let account_registry = fixture.scenario.take_shared<AccountRegistry>();
    let mut pool = fixture.scenario.take_shared_by_id<Pool<BaseAsset, QuoteAsset>>(pool_id);
    let mut wrapper = fixture.scenario.take_shared_by_id<AccountWrapper>(wrapper_id);
    let sessions_config = fixture
        .scenario
        .take_shared_by_id<SessionsConfig>(fixture.sessions_config_id);
    let root = fixture.scenario.take_shared<AccumulatorRoot>();
    let clock = fixture.scenario.take_shared<Clock>();
    let info = sessions::place_market_order<BaseAsset, QuoteAsset>(
        &mut pool,
        &registry,
        &account_registry,
        &mut wrapper,
        &sessions_config,
        MARKET_TAKER_CLIENT_ID,
        constants::self_matching_allowed(),
        constants::min_size(),
        constants::float_scaling(),
        is_bid,
        true,
        &root,
        &clock,
        fixture.scenario.ctx(),
    );
    return_shared(clock);
    return_shared(root);
    return_shared(sessions_config);
    return_shared(wrapper);
    return_shared(pool);
    return_shared(account_registry);
    return_shared(registry);
    info
}

/// Approve what the session may spend of `T`, as Alice, the Account owner.
fun approve_spend<T>(fixture: &mut SpotFixture, amount: u64) {
    let wrapper_id = fixture.wrapper_id;
    fixture.scenario.next_tx(ALICE);
    let mut wrapper = fixture.scenario.take_shared_by_id<AccountWrapper>(wrapper_id);
    let sessions_config = fixture
        .scenario
        .take_shared_by_id<SessionsConfig>(fixture.sessions_config_id);
    sessions::approve_session_spend<T>(
        &mut wrapper,
        &sessions_config,
        SESSION,
        amount,
        fixture.scenario.ctx(),
    );
    assert_eq!(sessions::session_spend_remaining<T>(&wrapper, SESSION), amount);
    return_shared(sessions_config);
    return_shared(wrapper);
}

/// Budgets covering the Account's whole base, quote and DEEP balances.
fun approve_full_spend(fixture: &mut SpotFixture) {
    approve_spend<BASE>(fixture, ACCOUNT_BALANCE);
    approve_spend<QUOTE>(fixture, ACCOUNT_BALANCE);
    approve_spend<DEEP>(fixture, ACCOUNT_BALANCE);
}

fun spend_remaining<T>(fixture: &mut SpotFixture): u64 {
    let wrapper_id = fixture.wrapper_id;
    fixture.scenario.next_tx(ALICE);
    let wrapper = fixture.scenario.take_shared_by_id<AccountWrapper>(wrapper_id);
    let remaining = sessions::session_spend_remaining<T>(&wrapper, SESSION);
    return_shared(wrapper);
    remaining
}

fun account_balance<T>(fixture: &mut SpotFixture): u64 {
    let wrapper_id = fixture.wrapper_id;
    fixture.scenario.next_tx(ALICE);
    let wrapper = fixture.scenario.take_shared_by_id<AccountWrapper>(wrapper_id);
    let root = fixture.scenario.take_shared<AccumulatorRoot>();
    let clock = fixture.scenario.take_shared<Clock>();
    let balance = wrapper.load_account().balance<T>(&root, &clock);
    return_shared(clock);
    return_shared(root);
    return_shared(wrapper);
    balance
}

/// A fee-charging `JUNK`/`QUOTE` pool on the allowlist, with `JUNK` in the Account.
fun setup_fee_pool(fixture: &mut SpotFixture): ID {
    let registry_id = fixture.registry_id;
    fixture.scenario.next_tx(ADMIN);
    let admin_cap = registry::get_admin_cap_for_testing(fixture.scenario.ctx());
    let mut registry = fixture.scenario.take_shared_by_id<Registry>(registry_id);
    let pool_id = pool::create_pool_admin<JUNK, QUOTE>(
        &mut registry,
        constants::tick_size(),
        constants::lot_size(),
        constants::min_size(),
        false,
        false,
        &admin_cap,
        fixture.scenario.ctx(),
    );
    return_shared(registry);
    destroy(admin_cap);
    admin_allow_pool(fixture, pool_id);

    let wrapper_id = fixture.wrapper_id;
    fixture.scenario.next_tx(ALICE);
    let mut wrapper = fixture.scenario.take_shared_by_id<AccountWrapper>(wrapper_id);
    let account = wrapper.load_account_mut(account::generate_auth(fixture.scenario.ctx()));
    account.deposit<JUNK>(coin::mint_for_testing<JUNK>(ACCOUNT_BALANCE, fixture.scenario.ctx()));
    return_shared(wrapper);
    pool_id
}

/// A session-key limit order at price 1 that pays fees in the asset it spends.
fun session_order_paying_input_fees<BaseAsset, QuoteAsset>(
    fixture: &mut SpotFixture,
    pool_id: ID,
    client_order_id: u64,
    quantity: u64,
    is_bid: bool,
): OrderInfo {
    let registry_id = fixture.registry_id;
    let wrapper_id = fixture.wrapper_id;
    fixture.scenario.next_tx(SESSION);
    let registry = fixture.scenario.take_shared_by_id<Registry>(registry_id);
    let account_registry = fixture.scenario.take_shared<AccountRegistry>();
    let mut pool = fixture.scenario.take_shared_by_id<Pool<BaseAsset, QuoteAsset>>(pool_id);
    let mut wrapper = fixture.scenario.take_shared_by_id<AccountWrapper>(wrapper_id);
    let sessions_config = fixture
        .scenario
        .take_shared_by_id<SessionsConfig>(fixture.sessions_config_id);
    let root = fixture.scenario.take_shared<AccumulatorRoot>();
    let clock = fixture.scenario.take_shared<Clock>();
    let info = sessions::place_limit_order<BaseAsset, QuoteAsset>(
        &mut pool,
        &registry,
        &account_registry,
        &mut wrapper,
        &sessions_config,
        client_order_id,
        constants::no_restriction(),
        constants::self_matching_allowed(),
        constants::float_scaling(),
        quantity,
        is_bid,
        false,
        constants::max_u64(),
        &root,
        &clock,
        fixture.scenario.ctx(),
    );
    return_shared(clock);
    return_shared(root);
    return_shared(sessions_config);
    return_shared(wrapper);
    return_shared(pool);
    return_shared(account_registry);
    return_shared(registry);
    info
}

/// Bob's minimum-size limit order at price 1 that pays fees in the asset it spends.
fun place_manager_order_paying_input_fees<BaseAsset, QuoteAsset>(
    fixture: &mut SpotFixture,
    pool_id: ID,
    manager_id: ID,
    client_order_id: u64,
    is_bid: bool,
): OrderInfo {
    fixture.scenario.next_tx(BOB);
    let mut pool = fixture.scenario.take_shared_by_id<Pool<BaseAsset, QuoteAsset>>(pool_id);
    let clock = fixture.scenario.take_shared<Clock>();
    let mut manager = fixture.scenario.take_shared_by_id<BalanceManager>(manager_id);
    let proof = manager.generate_proof_as_owner(fixture.scenario.ctx());
    let info = pool.place_limit_order<BaseAsset, QuoteAsset>(
        &mut manager,
        &proof,
        client_order_id,
        constants::no_restriction(),
        constants::self_matching_allowed(),
        constants::float_scaling(),
        constants::min_size(),
        is_bid,
        false,
        constants::max_u64(),
        &clock,
        fixture.scenario.ctx(),
    );
    return_shared(manager);
    return_shared(clock);
    return_shared(pool);
    info
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

fun create_pool<BaseAsset, QuoteAsset>(scenario: &mut Scenario, registry_id: ID): ID {
    scenario.next_tx(ADMIN);
    let admin_cap = registry::get_admin_cap_for_testing(scenario.ctx());
    let mut registry = scenario.take_shared_by_id<Registry>(registry_id);
    let pool_id = pool::create_pool_admin<BaseAsset, QuoteAsset>(
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
