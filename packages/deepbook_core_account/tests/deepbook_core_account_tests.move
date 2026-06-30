// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module deepbook_core_account::deepbook_core_account_tests;

use account::{
    account::{Self, AccountWrapper},
    account_registry::{Self, AccountAdminCap, AccountRegistry}
};
use deepbook::{
    balance_manager::{Self as balance_manager, BalanceManager},
    constants,
    order_info::OrderInfo,
    pool::{Self, Pool},
    registry::{Self, Registry}
};
use deepbook_core_account::deepbook_core_account::{Self as dca, DeepbookCoreAccountApp};
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
const BASE_AMOUNT: u64 = 5_000_000_000;
const RESTING_ASK_CLIENT_ORDER_ID: u64 = 11;
const FILLING_BID_CLIENT_ORDER_ID: u64 = 12;
const ZERO_BALANCE: u64 = 0;
const NO_OPEN_ORDER_COUNT: u64 = 0;
const SINGLE_OPEN_ORDER_COUNT: u64 = 1;
const FIRST_OPEN_ORDER_INDEX: u64 = 0;

public struct BASE has store {}
public struct QUOTE has store {}

#[test]
fun first_touch_lazily_creates_stable_manager() {
    let (mut scenario, registry_id, pool_id, mut wrapper) = setup_account();
    authorize_core_app(&mut scenario, registry_id);

    scenario.next_tx(ALICE);
    let registry = scenario.take_shared_by_id<Registry>(registry_id);
    let mut pool = scenario.take_shared_by_id<Pool<BASE, QUOTE>>(pool_id);
    let clock = scenario.take_shared<Clock>();
    assert!(!dca::is_initialized(wrapper.load_account()));

    dca::cancel_live_orders<BASE, QUOTE>(
        &mut pool,
        &registry,
        &mut wrapper,
        account::generate_auth(scenario.ctx()),
        vector[],
        &clock,
        scenario.ctx(),
    );
    assert!(dca::is_initialized(wrapper.load_account()));
    let first = dca::balance_manager_id(wrapper.load_account()).destroy_some();

    dca::cancel_live_orders<BASE, QUOTE>(
        &mut pool,
        &registry,
        &mut wrapper,
        account::generate_auth(scenario.ctx()),
        vector[],
        &clock,
        scenario.ctx(),
    );
    let second = dca::balance_manager_id(wrapper.load_account()).destroy_some();
    assert_eq!(first, second);

    return_shared(clock);
    return_shared(pool);
    return_shared(registry);
    destroy(wrapper);
    scenario.end();
}

#[test]
fun uninitialized_account_getters_return_empty_values() {
    let (mut scenario, _registry_id, pool_id, wrapper) = setup_account();

    scenario.next_tx(ALICE);
    let pool = scenario.take_shared_by_id<Pool<BASE, QUOTE>>(pool_id);
    let account = wrapper.load_account();
    let (base_locked, quote_locked, deep_locked) = dca::locked_balance<BASE, QUOTE>(&pool, account);

    assert!(!dca::account_exists<BASE, QUOTE>(&pool, account));
    assert!(dca::account<BASE, QUOTE>(&pool, account).is_none());
    assert!(dca::account_open_orders<BASE, QUOTE>(&pool, account).is_empty());
    assert_eq!(
        dca::get_account_order_details<BASE, QUOTE>(&pool, account).length(),
        NO_OPEN_ORDER_COUNT,
    );
    assert_eq!(base_locked, ZERO_BALANCE);
    assert_eq!(quote_locked, ZERO_BALANCE);
    assert_eq!(deep_locked, ZERO_BALANCE);

    return_shared(pool);
    destroy(wrapper);
    scenario.end();
}

#[test]
fun account_getters_return_core_account_and_order_state() {
    let (mut scenario, registry_id, pool_id, mut wrapper) = setup_whitelisted_account();
    authorize_core_app(&mut scenario, registry_id);
    let trade_amount = constants::min_size();

    scenario.next_tx(ALICE);
    let registry = scenario.take_shared_by_id<Registry>(registry_id);
    let mut pool = scenario.take_shared_by_id<Pool<BASE, QUOTE>>(pool_id);
    let root = scenario.take_shared<AccumulatorRoot>();
    let clock = scenario.take_shared<Clock>();
    let ask = dca::place_limit_order<BASE, QUOTE>(
        &mut pool,
        &registry,
        &mut wrapper,
        account::generate_auth(scenario.ctx()),
        RESTING_ASK_CLIENT_ORDER_ID,
        constants::no_restriction(),
        constants::self_matching_allowed(),
        constants::float_scaling(),
        trade_amount,
        false,
        true,
        constants::max_u64(),
        trade_amount,
        0,
        0,
        &root,
        &clock,
        scenario.ctx(),
    );
    let account = wrapper.load_account();
    let order_id = ask.order_id();
    let open_orders = dca::account_open_orders<BASE, QUOTE>(&pool, account);
    let order_details = dca::get_account_order_details<BASE, QUOTE>(&pool, account);
    let core_account = dca::account<BASE, QUOTE>(&pool, account).destroy_some();
    let (base_locked, quote_locked, deep_locked) = dca::locked_balance<BASE, QUOTE>(&pool, account);

    assert!(dca::account_exists<BASE, QUOTE>(&pool, account));
    assert!(open_orders.contains(&order_id));
    assert_eq!(open_orders.length(), SINGLE_OPEN_ORDER_COUNT);
    assert_eq!(core_account.open_orders().length(), SINGLE_OPEN_ORDER_COUNT);
    assert!(core_account.open_orders().contains(&order_id));
    assert_eq!(order_details.length(), SINGLE_OPEN_ORDER_COUNT);
    assert_eq!(order_details.borrow(FIRST_OPEN_ORDER_INDEX).order_id(), order_id);
    assert_eq!(base_locked, trade_amount);
    assert_eq!(quote_locked, ZERO_BALANCE);
    assert_eq!(deep_locked, ZERO_BALANCE);

    return_shared(clock);
    return_shared(root);
    return_shared(pool);
    return_shared(registry);
    destroy(wrapper);
    scenario.end();
}

#[test]
fun funding_round_trip_sweeps_back_to_account() {
    let (mut scenario, registry_id, pool_id, mut wrapper) = setup_account();
    authorize_core_app(&mut scenario, registry_id);

    scenario.next_tx(ALICE);
    let registry = scenario.take_shared_by_id<Registry>(registry_id);
    let mut pool = scenario.take_shared_by_id<Pool<BASE, QUOTE>>(pool_id);
    let root = scenario.take_shared<AccumulatorRoot>();
    let clock = scenario.take_shared<Clock>();

    let _ = dca::place_limit_order<BASE, QUOTE>(
        &mut pool,
        &registry,
        &mut wrapper,
        account::generate_auth(scenario.ctx()),
        1,
        constants::immediate_or_cancel(),
        constants::self_matching_allowed(),
        constants::float_scaling(),
        constants::min_size(),
        false,
        false,
        constants::max_u64(),
        constants::min_size(),
        0,
        0,
        &root,
        &clock,
        scenario.ctx(),
    );
    assert_eq!(wrapper.load_account().balance<BASE>(&root, &clock), BASE_AMOUNT);
    assert_eq!(dca::balance_manager_balance<BASE>(wrapper.load_account()), 0);

    let account = wrapper.load_account_mut(account::generate_auth(scenario.ctx()));
    let withdrawn = account.withdraw<BASE>(BASE_AMOUNT, scenario.ctx());
    assert_eq!(withdrawn.value(), BASE_AMOUNT);
    destroy(withdrawn);

    return_shared(clock);
    return_shared(root);
    return_shared(pool);
    return_shared(registry);
    destroy(wrapper);
    scenario.end();
}

#[test]
fun withdraw_settled_amounts_sweeps_maker_fill_to_account() {
    let (mut scenario, registry_id, pool_id, mut wrapper) = setup_whitelisted_account();
    authorize_core_app(&mut scenario, registry_id);
    let bob_manager_id = create_balance_manager_with_funds<BASE, QUOTE>(
        &mut scenario,
        BOB,
        BASE_AMOUNT,
    );
    let trade_amount = constants::min_size();

    scenario.next_tx(ALICE);
    let registry = scenario.take_shared_by_id<Registry>(registry_id);
    let mut pool = scenario.take_shared_by_id<Pool<BASE, QUOTE>>(pool_id);
    let root = scenario.take_shared<AccumulatorRoot>();
    let clock = scenario.take_shared<Clock>();
    let ask = dca::place_limit_order<BASE, QUOTE>(
        &mut pool,
        &registry,
        &mut wrapper,
        account::generate_auth(scenario.ctx()),
        RESTING_ASK_CLIENT_ORDER_ID,
        constants::no_restriction(),
        constants::self_matching_allowed(),
        constants::float_scaling(),
        trade_amount,
        false,
        true,
        constants::max_u64(),
        trade_amount,
        0,
        0,
        &root,
        &clock,
        scenario.ctx(),
    );
    let account = wrapper.load_account();
    let manager_id = dca::balance_manager_id(account).destroy_some();
    assert_eq!(ask.status(), constants::live());
    assert!(ask.order_inserted());
    assert_eq!(ask.balance_manager_id(), manager_id);
    assert_eq!(ask.executed_quantity(), 0);
    assert_eq!(account.balance<BASE>(&root, &clock), BASE_AMOUNT - trade_amount);
    assert_eq!(account.balance<QUOTE>(&root, &clock), BASE_AMOUNT);
    assert_eq!(dca::balance_manager_balance<BASE>(account), 0);
    assert_eq!(dca::balance_manager_balance<QUOTE>(account), 0);
    assert_eq!(dca::balance_manager_balance<DEEP>(account), 0);
    return_shared(clock);
    return_shared(root);
    return_shared(pool);
    return_shared(registry);

    let fill = place_manager_market_order<BASE, QUOTE>(
        &mut scenario,
        BOB,
        pool_id,
        bob_manager_id,
        FILLING_BID_CLIENT_ORDER_ID,
        trade_amount,
        true,
    );
    assert_eq!(fill.status(), constants::filled());
    assert_eq!(fill.executed_quantity(), trade_amount);
    assert_eq!(fill.cumulative_quote_quantity(), trade_amount);

    scenario.next_tx(ALICE);
    let registry = scenario.take_shared_by_id<Registry>(registry_id);
    let mut pool = scenario.take_shared_by_id<Pool<BASE, QUOTE>>(pool_id);
    let root = scenario.take_shared<AccumulatorRoot>();
    let clock = scenario.take_shared<Clock>();
    assert_eq!(wrapper.load_account().balance<QUOTE>(&root, &clock), BASE_AMOUNT);
    dca::withdraw_settled_amounts<BASE, QUOTE>(
        &mut pool,
        &registry,
        &mut wrapper,
        account::generate_auth(scenario.ctx()),
        scenario.ctx(),
    );
    let account = wrapper.load_account();
    assert_eq!(account.balance<BASE>(&root, &clock), BASE_AMOUNT - trade_amount);
    assert_eq!(account.balance<QUOTE>(&root, &clock), BASE_AMOUNT + trade_amount);
    assert_eq!(dca::balance_manager_balance<BASE>(account), 0);
    assert_eq!(dca::balance_manager_balance<QUOTE>(account), 0);
    assert_eq!(dca::balance_manager_balance<DEEP>(account), 0);

    return_shared(clock);
    return_shared(root);
    return_shared(pool);
    return_shared(registry);
    destroy(wrapper);
    scenario.end();
}

#[test]
fun permissionless_withdraw_settled_amounts_noops_for_uninitialized_account() {
    let (mut scenario, _registry_id, pool_id, mut wrapper) = setup_whitelisted_account();
    authorize_account_app(&mut scenario);

    scenario.next_tx(BOB);
    let account_registry = scenario.take_shared<AccountRegistry>();
    let mut pool = scenario.take_shared_by_id<Pool<BASE, QUOTE>>(pool_id);
    let root = scenario.take_shared<AccumulatorRoot>();
    let clock = scenario.take_shared<Clock>();
    assert!(!dca::is_initialized(wrapper.load_account()));
    dca::withdraw_settled_amounts_permissionless<BASE, QUOTE>(
        &mut pool,
        &account_registry,
        &mut wrapper,
        scenario.ctx(),
    );
    let account = wrapper.load_account();
    assert!(!dca::is_initialized(account));
    assert_eq!(account.balance<BASE>(&root, &clock), BASE_AMOUNT);
    assert_eq!(account.balance<QUOTE>(&root, &clock), BASE_AMOUNT);
    assert_eq!(account.balance<DEEP>(&root, &clock), BASE_AMOUNT);

    return_shared(clock);
    return_shared(root);
    return_shared(pool);
    return_shared(account_registry);
    destroy(wrapper);
    scenario.end();
}

#[test]
fun permissionless_withdraw_settled_amounts_uses_account_registry_app_auth() {
    let (mut scenario, registry_id, pool_id, mut wrapper) = setup_whitelisted_account();
    authorize_core_app(&mut scenario, registry_id);
    authorize_account_app(&mut scenario);
    let bob_manager_id = create_balance_manager_with_funds<BASE, QUOTE>(
        &mut scenario,
        BOB,
        BASE_AMOUNT,
    );
    let trade_amount = constants::min_size();

    scenario.next_tx(ALICE);
    let registry = scenario.take_shared_by_id<Registry>(registry_id);
    let mut pool = scenario.take_shared_by_id<Pool<BASE, QUOTE>>(pool_id);
    let root = scenario.take_shared<AccumulatorRoot>();
    let clock = scenario.take_shared<Clock>();
    let ask = dca::place_limit_order<BASE, QUOTE>(
        &mut pool,
        &registry,
        &mut wrapper,
        account::generate_auth(scenario.ctx()),
        RESTING_ASK_CLIENT_ORDER_ID,
        constants::no_restriction(),
        constants::self_matching_allowed(),
        constants::float_scaling(),
        trade_amount,
        false,
        true,
        constants::max_u64(),
        trade_amount,
        0,
        0,
        &root,
        &clock,
        scenario.ctx(),
    );
    assert_eq!(ask.status(), constants::live());
    assert!(ask.order_inserted());
    return_shared(clock);
    return_shared(root);
    return_shared(pool);
    return_shared(registry);

    let fill = place_manager_market_order<BASE, QUOTE>(
        &mut scenario,
        BOB,
        pool_id,
        bob_manager_id,
        FILLING_BID_CLIENT_ORDER_ID,
        trade_amount,
        true,
    );
    assert_eq!(fill.status(), constants::filled());

    scenario.next_tx(BOB);
    let account_registry = scenario.take_shared<AccountRegistry>();
    let mut pool = scenario.take_shared_by_id<Pool<BASE, QUOTE>>(pool_id);
    let root = scenario.take_shared<AccumulatorRoot>();
    let clock = scenario.take_shared<Clock>();
    assert_eq!(wrapper.load_account().balance<QUOTE>(&root, &clock), BASE_AMOUNT);
    dca::withdraw_settled_amounts_permissionless<BASE, QUOTE>(
        &mut pool,
        &account_registry,
        &mut wrapper,
        scenario.ctx(),
    );
    let account = wrapper.load_account();
    assert_eq!(account.balance<BASE>(&root, &clock), BASE_AMOUNT - trade_amount);
    assert_eq!(account.balance<QUOTE>(&root, &clock), BASE_AMOUNT + trade_amount);
    assert_eq!(dca::balance_manager_balance<BASE>(account), 0);
    assert_eq!(dca::balance_manager_balance<QUOTE>(account), 0);
    assert_eq!(dca::balance_manager_balance<DEEP>(account), 0);

    return_shared(clock);
    return_shared(root);
    return_shared(pool);
    return_shared(account_registry);
    destroy(wrapper);
    scenario.end();
}

fun setup_account(): (Scenario, ID, ID, AccountWrapper) {
    setup_account_with_pool(false)
}

fun setup_whitelisted_account(): (Scenario, ID, ID, AccountWrapper) {
    setup_account_with_pool(true)
}

fun setup_account_with_pool(whitelisted_pool: bool): (Scenario, ID, ID, AccountWrapper) {
    let mut scenario = test::begin(ADMIN);

    scenario.next_tx(@0x0);
    accumulator::create_for_testing(scenario.ctx());

    scenario.next_tx(ADMIN);
    let registry_id = deepbook::registry::test_registry(scenario.ctx());
    account_registry::init_for_testing(scenario.ctx());
    clock::create_for_testing(scenario.ctx()).share_for_testing();
    let pool_id = create_pool<BASE, QUOTE>(&mut scenario, registry_id, whitelisted_pool);

    scenario.next_tx(ALICE);
    let mut account_registry = scenario.take_shared<AccountRegistry>();
    let mut wrapper = account_registry.new(scenario.ctx());
    let account = wrapper.load_account_mut(account::generate_auth(scenario.ctx()));
    account.deposit<BASE>(coin::mint_for_testing<BASE>(BASE_AMOUNT, scenario.ctx()));
    account.deposit<QUOTE>(coin::mint_for_testing<QUOTE>(BASE_AMOUNT, scenario.ctx()));
    account.deposit<DEEP>(coin::mint_for_testing<DEEP>(BASE_AMOUNT, scenario.ctx()));
    return_shared(account_registry);

    (scenario, registry_id, pool_id, wrapper)
}

fun create_balance_manager_with_funds<BaseAsset, QuoteAsset>(
    scenario: &mut Scenario,
    owner: address,
    amount: u64,
): ID {
    scenario.next_tx(owner);
    let mut manager = balance_manager::new(scenario.ctx());
    manager.deposit<BaseAsset>(
        coin::mint_for_testing<BaseAsset>(amount, scenario.ctx()),
        scenario.ctx(),
    );
    manager.deposit<QuoteAsset>(
        coin::mint_for_testing<QuoteAsset>(amount, scenario.ctx()),
        scenario.ctx(),
    );
    manager.deposit<DEEP>(coin::mint_for_testing<DEEP>(amount, scenario.ctx()), scenario.ctx());
    let id = manager.id();
    transfer::public_share_object(manager);
    id
}

fun place_manager_market_order<BaseAsset, QuoteAsset>(
    scenario: &mut Scenario,
    trader: address,
    pool_id: ID,
    balance_manager_id: ID,
    client_order_id: u64,
    quantity: u64,
    is_bid: bool,
): OrderInfo {
    scenario.next_tx(trader);
    let mut pool = scenario.take_shared_by_id<Pool<BaseAsset, QuoteAsset>>(pool_id);
    let clock = scenario.take_shared<Clock>();
    let mut manager = scenario.take_shared_by_id<BalanceManager>(balance_manager_id);
    let proof = manager.generate_proof_as_owner(scenario.ctx());
    let info = pool.place_market_order<BaseAsset, QuoteAsset>(
        &mut manager,
        &proof,
        client_order_id,
        constants::self_matching_allowed(),
        quantity,
        is_bid,
        true,
        &clock,
        scenario.ctx(),
    );
    return_shared(clock);
    return_shared(pool);
    return_shared(manager);
    info
}

fun authorize_core_app(scenario: &mut Scenario, registry_id: ID) {
    scenario.next_tx(ADMIN);
    let admin_cap = deepbook::registry::get_admin_cap_for_testing(scenario.ctx());
    let mut registry = scenario.take_shared_by_id<Registry>(registry_id);
    registry.authorize_app<DeepbookCoreAccountApp>(&admin_cap);
    return_shared(registry);
    destroy(admin_cap);
}

fun authorize_account_app(scenario: &mut Scenario) {
    scenario.next_tx(ADMIN);
    let admin_cap = scenario.take_from_sender<AccountAdminCap>();
    let mut registry = scenario.take_shared<AccountRegistry>();
    registry.authorize_app<DeepbookCoreAccountApp>(&admin_cap);
    return_shared(registry);
    destroy(admin_cap);
}

fun create_pool<BaseAsset, QuoteAsset>(
    scenario: &mut Scenario,
    registry_id: ID,
    whitelisted_pool: bool,
): ID {
    scenario.next_tx(ADMIN);
    let admin_cap = registry::get_admin_cap_for_testing(scenario.ctx());
    let mut registry = scenario.take_shared_by_id<Registry>(registry_id);
    let pool_id = pool::create_pool_admin<BaseAsset, QuoteAsset>(
        &mut registry,
        constants::tick_size(),
        constants::lot_size(),
        constants::min_size(),
        whitelisted_pool,
        false,
        &admin_cap,
        scenario.ctx(),
    );
    return_shared(registry);
    destroy(admin_cap);
    pool_id
}
