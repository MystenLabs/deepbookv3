// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

#[test_only]
// INITIAL_DEPOSIT/WITHDRAW_AMOUNT/POST_WITHDRAW_BALANCE, the `coin`/`Clock` imports, and
// one `let mut` are used only by the AccumulatorRoot-dependent deposit/withdraw tests
// disabled on this branch (see accumulator_support.move).
#[allow(unused_const, unused_let_mut)]
module account::account_tests;

use account::{
    account::{Self, AccountWrapper},
    account_registry::{Self, AccountAdminCap, AccountRegistry},
    accumulator_support
};
use std::{internal::permit, unit_test::{assert_eq, destroy}};
use sui::{clock::Clock, coin, object, test_scenario::{Self as test, Scenario, return_shared}};

const ADMIN: address = @0xAD;
const ALICE: address = @0xA11CE;
const BOB: address = @0xB0B;
const INITIAL_DEPOSIT: u64 = 1_000;
const WITHDRAW_AMOUNT: u64 = 350;
const POST_WITHDRAW_BALANCE: u64 = 650;
const DATA_INITIAL_VALUE: u64 = 17;
const DATA_UPDATED_VALUE: u64 = 29;

public struct TEST_COIN has drop {}

public struct TestApp has drop {}

public struct OtherApp has drop {}

public struct TestData has store {
    value: u64,
}

public struct OwnerObject has key {
    id: UID,
}

#[test]
fun registry_creates_one_canonical_account_per_owner() {
    let mut scenario = setup();
    let mut registry = scenario.take_shared<AccountRegistry>();
    let account_id = registry.derived_address(ALICE).to_id();
    let wrapper_id = registry.derived_wrapper_address(ALICE).to_id();

    assert!(!registry.derived_exists(ALICE));
    assert!(!registry.derived_wrapper_exists(ALICE));

    scenario.next_tx(ALICE);
    let wrapper = registry.new(scenario.ctx());
    let account = wrapper.load_account();

    assert_eq!(account.owner(), ALICE);
    assert_eq!(account.account_id(), account_id);
    // Funds receive/settle at the wrapper address now (a real shared input object),
    // not the nested account_id.
    assert_eq!(account.receive_address(), wrapper_id.to_address());
    assert!(registry.derived_exists(ALICE));
    assert!(registry.derived_wrapper_exists(ALICE));
    assert_eq!(registry.derived_address(ALICE).to_id(), account_id);
    assert_eq!(registry.derived_wrapper_address(ALICE).to_id(), wrapper_id);

    wrapper.share();
    return_shared(registry);
    scenario.end();
}

#[test]
fun authorize_then_deauthorize_app() {
    let scenario = setup();
    let admin_cap = scenario.take_from_sender<AccountAdminCap>();
    let mut registry = scenario.take_shared<AccountRegistry>();

    registry.authorize_app<TestApp>(&admin_cap);
    assert!(registry.is_app_authorized<TestApp>());

    registry.deauthorize_app<TestApp>(&admin_cap);
    assert!(!registry.is_app_authorized<TestApp>());

    return_shared(registry);
    destroy(admin_cap);
    scenario.end();
}

#[test, expected_failure(abort_code = account_registry::EAccountAlreadyExists)]
fun creating_second_account_for_same_owner_aborts() {
    let mut scenario = setup();
    scenario.next_tx(ALICE);
    let mut registry = scenario.take_shared<AccountRegistry>();
    let first = registry.new(scenario.ctx());
    first.share();

    let second = registry.new(scenario.ctx());
    second.share();

    abort 999
}

/* DISABLED(testnet-fw): needs AccumulatorRoot — nightly create_for_testing is absent on testnet; see accumulator_support.move. Restore the file/test when stable Sui ships it.
#[test]
fun owner_auth_opens_account_and_coin_paths() {
    let mut scenario = setup_with_account(ALICE);
    scenario.next_tx(ALICE);
    let mut wrapper = take_account_wrapper(&scenario, ALICE);
    let root = accumulator_support::take_root(&scenario);
    let mut clock = scenario.take_shared<Clock>();
    clock.increment_for_testing(1);
    let auth = account::generate_auth(scenario.ctx());
    let account = wrapper.load_account_mut(auth);
    account.deposit<TEST_COIN>(
        coin::mint_for_testing<TEST_COIN>(INITIAL_DEPOSIT, scenario.ctx()),
        &root,
        &clock,
    );
    assert_eq!(account.balance<TEST_COIN>(&root, &clock), INITIAL_DEPOSIT);

    let withdrawn = account.withdraw<TEST_COIN>(WITHDRAW_AMOUNT, &root, &clock, scenario.ctx());
    assert_eq!(withdrawn.value(), WITHDRAW_AMOUNT);
    destroy(withdrawn);
    assert_eq!(account.balance<TEST_COIN>(&root, &clock), POST_WITHDRAW_BALANCE);

    return_shared(clock);
    return_shared(root);
    return_shared(wrapper);
    scenario.end();
}

*/
#[test, expected_failure(abort_code = account::EInvalidOwner)]
fun owner_auth_from_wrong_sender_aborts() {
    let mut scenario = setup_with_account(ALICE);
    scenario.next_tx(BOB);
    let mut wrapper = take_account_wrapper(&scenario, ALICE);
    let auth = account::generate_auth(scenario.ctx());

    wrapper.load_account_mut(auth);

    abort 999
}

/* DISABLED(testnet-fw): needs AccumulatorRoot — nightly create_for_testing is absent on testnet; see accumulator_support.move. Restore the file/test when stable Sui ships it.
#[test, expected_failure(abort_code = account::EBalanceTooLow)]
fun withdrawing_more_than_available_aborts() {
    let mut scenario = setup_with_account(ALICE);
    scenario.next_tx(ALICE);
    let mut wrapper = take_account_wrapper(&scenario, ALICE);
    let root = accumulator_support::take_root(&scenario);
    let clock = scenario.take_shared<Clock>();
    let auth = account::generate_auth(scenario.ctx());
    let account = wrapper.load_account_mut(auth);

    account.deposit<TEST_COIN>(
        coin::mint_for_testing<TEST_COIN>(INITIAL_DEPOSIT, scenario.ctx()),
        &root,
        &clock,
    );
    let coin = account.withdraw<TEST_COIN>(INITIAL_DEPOSIT + 1, &root, &clock, scenario.ctx());
    destroy(coin);

    abort 999
}

*/
#[test]
fun object_auth_opens_self_owned_account() {
    let mut scenario = setup();
    let mut registry = scenario.take_shared<AccountRegistry>();
    let mut owner = OwnerObject { id: object::new(scenario.ctx()) };
    let owner_address = owner.id.to_inner().to_address();
    let wrapper_id = registry.derived_wrapper_address(owner_address).to_id();
    let wrapper = registry.new_self_owned(&mut owner.id, scenario.ctx());

    assert_eq!(wrapper.load_account().owner(), owner_address);
    wrapper.share();
    return_shared(registry);
    scenario.next_tx(ADMIN);

    let mut wrapper = scenario.take_shared_by_id<AccountWrapper>(wrapper_id);
    let auth = account::generate_auth_as_object(&mut owner.id);
    let account = wrapper.load_account_mut(auth);
    assert_eq!(account.owner(), owner_address);

    return_shared(wrapper);
    destroy(owner);
    scenario.end();
}

#[test]
fun authorized_app_auth_opens_account_and_data_lane() {
    let mut scenario = setup_with_account(ALICE);
    let admin_cap = scenario.take_from_sender<AccountAdminCap>();
    let mut registry = scenario.take_shared<AccountRegistry>();
    registry.authorize_app<TestApp>(&admin_cap);
    assert!(registry.is_app_authorized<TestApp>());
    return_shared(registry);
    destroy(admin_cap);
    scenario.next_tx(ADMIN);

    let registry = scenario.take_shared<AccountRegistry>();
    let wrapper_id = registry.derived_wrapper_address(ALICE).to_id();
    let auth = registry.generate_auth_as_app<TestApp>(permit<TestApp>());
    return_shared(registry);
    let mut wrapper = scenario.take_shared_by_id<AccountWrapper>(wrapper_id);
    let account = wrapper.load_account_mut(auth);

    assert!(!account.has_data<TestApp>());
    account.attach<TestApp, TestData>(permit<TestApp>(), TestData { value: DATA_INITIAL_VALUE });
    assert!(account.has_data<TestApp>());
    assert_eq!(account.borrow_data<TestApp, TestData>().value, DATA_INITIAL_VALUE);
    account.borrow_data_mut<TestApp, TestData>(permit<TestApp>()).value = DATA_UPDATED_VALUE;
    assert_eq!(account.borrow_data<TestApp, TestData>().value, DATA_UPDATED_VALUE);
    assert!(!account.has_data<OtherApp>());
    let data = account.detach<TestApp, TestData>(permit<TestApp>());
    assert_eq!(data.value, DATA_UPDATED_VALUE);
    let TestData { value: _ } = data;
    assert!(!account.has_data<TestApp>());

    return_shared(wrapper);
    scenario.end();
}

#[test, expected_failure(abort_code = account_registry::EAppNotAuthorized)]
fun unauthorized_app_auth_aborts() {
    let scenario = setup_with_account(ALICE);
    let registry = scenario.take_shared<AccountRegistry>();
    let wrapper_id = registry.derived_wrapper_address(ALICE).to_id();
    let auth = registry.generate_auth_as_app<TestApp>(permit<TestApp>());

    return_shared(registry);
    let mut wrapper = scenario.take_shared_by_id<AccountWrapper>(wrapper_id);
    wrapper.load_account_mut(auth);

    abort 999
}

#[test, expected_failure(abort_code = account_registry::EAppAlreadyAuthorized)]
fun authorizing_same_app_twice_aborts() {
    let scenario = setup();
    let admin_cap = scenario.take_from_sender<AccountAdminCap>();
    let mut registry = scenario.take_shared<AccountRegistry>();

    registry.authorize_app<TestApp>(&admin_cap);
    registry.authorize_app<TestApp>(&admin_cap);

    abort 999
}

#[test, expected_failure(abort_code = account_registry::EAppNotAuthorized)]
fun deauthorizing_unknown_app_aborts() {
    let scenario = setup();
    let admin_cap = scenario.take_from_sender<AccountAdminCap>();
    let mut registry = scenario.take_shared<AccountRegistry>();

    registry.deauthorize_app<TestApp>(&admin_cap);

    abort 999
}

fun setup(): Scenario {
    let mut scenario = test::begin(ADMIN);
    scenario.create_system_objects();
    scenario.next_tx(@0x0);
    accumulator_support::create_shared_root(&mut scenario);
    scenario.next_tx(ADMIN);
    account_registry::init_for_testing(scenario.ctx());
    scenario.next_tx(ADMIN);
    scenario
}

fun setup_with_account(owner: address): Scenario {
    let mut scenario = setup();
    scenario.next_tx(owner);
    let mut registry = scenario.take_shared<AccountRegistry>();
    let wrapper = registry.new(scenario.ctx());
    wrapper.share();
    return_shared(registry);
    scenario.next_tx(ADMIN);
    scenario
}

fun take_account_wrapper(scenario: &Scenario, owner: address): AccountWrapper {
    let registry = scenario.take_shared<AccountRegistry>();
    let wrapper_id = registry.derived_wrapper_address(owner).to_id();
    return_shared(registry);
    scenario.take_shared_by_id<AccountWrapper>(wrapper_id)
}
