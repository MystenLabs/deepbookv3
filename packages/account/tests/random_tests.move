// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module account::random_tests;

use account::{
    account::{Self, AccountWrapper},
    account_registry::{Self, AccountRegistry},
    accumulator_support
};
use std::{debug, internal::permit, string::utf8, unit_test::{assert_eq, destroy}};
use sui::{
    accumulator::AccumulatorRoot,
    clock::Clock,
    coin,
    test_scenario::{Self as test, Scenario, return_shared}
};

const ADMIN: address = @0xAD;

/// 9-digit float scaling factor (10^9), standard for SUI and fixed-point pricing.
const FLOAT_SCALING: u64 = 1_000_000_000;

public struct TEST_COIN has drop {}
public struct COIN_A has drop {}
public struct COIN_B has drop {}

public struct TestApp has drop {}

public struct TestData has store {
    value: u64,
}

/// Helper to set up a test scenario with system objects, accumulator root, and registry.
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

/// Helper to initialize an account for a given owner.
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

/// 0. Simple baseline test: Deposit exactly 100 tokens and withdraw 80 tokens (9-digit scaling).
#[random_test]
fun random_baseline_deposit_100_withdraw_80() {
    let owner = @0xA11CE;
    let mut scenario = setup_with_account(owner);

    let deposit_amount = 100 * FLOAT_SCALING; // 100.000000000
    let withdraw_amount = 80 * FLOAT_SCALING; //  80.000000000

    debug::print(&utf8(b"--- Test 0: Baseline 100 In, 80 Out (9-Digit Scaling) ---"));
    debug::print(&utf8(b"Deposit (100 tokens * 10^9):"));
    debug::print(&deposit_amount);
    debug::print(&utf8(b"Withdraw (80 tokens * 10^9):"));
    debug::print(&withdraw_amount);

    scenario.next_tx(owner);
    let mut wrapper = take_account_wrapper(&scenario, owner);
    let root = accumulator_support::take_root(&scenario);
    let clock = scenario.take_shared<Clock>();

    let auth = account::generate_auth(scenario.ctx());
    let mut account = wrapper.load_account_mut(auth);

    account.deposit<TEST_COIN>(coin::mint_for_testing<TEST_COIN>(deposit_amount, scenario.ctx()));
    assert_eq!(account.balance<TEST_COIN>(&root, &clock), deposit_amount);

    let withdrawn = account.withdraw<TEST_COIN>(withdraw_amount, scenario.ctx());
    assert_eq!(withdrawn.value(), withdraw_amount);
    destroy(withdrawn);

    let remaining = account.balance<TEST_COIN>(&root, &clock);
    debug::print(&utf8(b"Remaining (20 tokens * 10^9):"));
    debug::print(&remaining);

    assert_eq!(remaining, 20 * FLOAT_SCALING);

    return_shared(clock);
    return_shared(root);
    return_shared(wrapper);
    scenario.end();
}

/// 1. Basic property test: Random deposit and partial withdrawal (9-digit float scaling).
#[random_test]
fun random_deposit_and_withdraw_invariant(raw_deposit: u64, raw_withdraw: u64) {
    let owner = @0xA11CE;
    let mut scenario = setup_with_account(owner);

    // Random whole tokens scaled by 9 decimals
    let deposit_tokens = (raw_deposit % 50) + 10; // 10 to 59 tokens
    let withdraw_tokens = (raw_withdraw % (deposit_tokens - 1)) + 1; // 1 to (deposit_tokens - 1)

    let deposit_amount = deposit_tokens * FLOAT_SCALING;
    let withdraw_amount = withdraw_tokens * FLOAT_SCALING;

    debug::print(&utf8(b"--- Test 1: Deposit & Partial Withdraw (9-Digit Scaling) ---"));
    debug::print(&utf8(b"Deposit Scaled:"));
    debug::print(&deposit_amount);
    debug::print(&utf8(b"Withdraw Scaled:"));
    debug::print(&withdraw_amount);

    scenario.next_tx(owner);
    let mut wrapper = take_account_wrapper(&scenario, owner);
    let root = accumulator_support::take_root(&scenario);
    let clock = scenario.take_shared<Clock>();

    let auth = account::generate_auth(scenario.ctx());
    let mut account = wrapper.load_account_mut(auth);

    account.deposit<TEST_COIN>(coin::mint_for_testing<TEST_COIN>(deposit_amount, scenario.ctx()));
    assert_eq!(account.balance<TEST_COIN>(&root, &clock), deposit_amount);

    let withdrawn = account.withdraw<TEST_COIN>(withdraw_amount, scenario.ctx());
    assert_eq!(withdrawn.value(), withdraw_amount);
    destroy(withdrawn);

    let expected_remaining = deposit_amount - withdraw_amount;
    debug::print(&utf8(b"Remaining Scaled:"));
    debug::print(&account.balance<TEST_COIN>(&root, &clock));

    assert_eq!(account.balance<TEST_COIN>(&root, &clock), expected_remaining);

    return_shared(clock);
    return_shared(root);
    return_shared(wrapper);
    scenario.end();
}

/// 2. Boundary test: Full withdrawal always leaves balance at zero (9-digit float scaling).
#[random_test]
fun random_full_withdrawal_leaves_zero(raw_amount: u64) {
    let owner = @0xB0B;
    let mut scenario = setup_with_account(owner);

    let tokens = (raw_amount % 50) + 1; // 1 to 50 tokens
    let amount = tokens * FLOAT_SCALING; // Scaled by 10^9

    debug::print(&utf8(b"--- Test 2: Full Withdrawal (9-Digit Float Scaling) ---"));
    debug::print(&utf8(b"Token Units:"));
    debug::print(&tokens);
    debug::print(&utf8(b"Scaled Amount (9 Digits):"));
    debug::print(&amount);

    scenario.next_tx(owner);
    let mut wrapper = take_account_wrapper(&scenario, owner);
    let root = accumulator_support::take_root(&scenario);
    let clock = scenario.take_shared<Clock>();

    let auth = account::generate_auth(scenario.ctx());
    let mut account = wrapper.load_account_mut(auth);

    account.deposit<TEST_COIN>(coin::mint_for_testing<TEST_COIN>(amount, scenario.ctx()));
    let withdrawn = account.withdraw<TEST_COIN>(amount, scenario.ctx());
    assert_eq!(withdrawn.value(), amount);
    destroy(withdrawn);

    debug::print(&utf8(b"Balance after 100% withdraw (must be 0):"));
    debug::print(&account.balance<TEST_COIN>(&root, &clock));

    assert_eq!(account.balance<TEST_COIN>(&root, &clock), 0);

    return_shared(clock);
    return_shared(root);
    return_shared(wrapper);
    scenario.end();
}

/// 3. Multiple sequential deposits accumulate monotonically without loss (9-digit scaling).
#[random_test]
fun random_multiple_deposits_accumulate(raw_a: u64, raw_b: u64, raw_c: u64) {
    let owner = @0xCAFE;
    let mut scenario = setup_with_account(owner);

    let tokens_a = (raw_a % 30) + 1; // 1 to 30 tokens
    let tokens_b = (raw_b % 30) + 1;
    let tokens_c = (raw_c % 30) + 1;

    let amount_a = tokens_a * FLOAT_SCALING;
    let amount_b = tokens_b * FLOAT_SCALING;
    let amount_c = tokens_c * FLOAT_SCALING;

    debug::print(&utf8(b"--- Test 3: Multiple Deposits Accumulate (9-Digit Scaling) ---"));
    debug::print(&utf8(b"Deposit A (Scaled):"));
    debug::print(&amount_a);
    debug::print(&utf8(b"Deposit B (Scaled):"));
    debug::print(&amount_b);
    debug::print(&utf8(b"Deposit C (Scaled):"));
    debug::print(&amount_c);

    scenario.next_tx(owner);
    let mut wrapper = take_account_wrapper(&scenario, owner);
    let root = accumulator_support::take_root(&scenario);
    let clock = scenario.take_shared<Clock>();

    let auth = account::generate_auth(scenario.ctx());
    let mut account = wrapper.load_account_mut(auth);

    account.deposit<TEST_COIN>(coin::mint_for_testing<TEST_COIN>(amount_a, scenario.ctx()));
    account.deposit<TEST_COIN>(coin::mint_for_testing<TEST_COIN>(amount_b, scenario.ctx()));
    account.deposit<TEST_COIN>(coin::mint_for_testing<TEST_COIN>(amount_c, scenario.ctx()));

    let total_expected = amount_a + amount_b + amount_c;
    debug::print(&utf8(b"Total Stored Scaled Balance:"));
    debug::print(&account.balance<TEST_COIN>(&root, &clock));

    assert_eq!(account.balance<TEST_COIN>(&root, &clock), total_expected);

    return_shared(clock);
    return_shared(root);
    return_shared(wrapper);
    scenario.end();
}

/// 4. Multi-coin isolation: Withdrawing COIN_A does not touch COIN_B balance (9-digit scaling).
#[random_test]
fun random_multi_coin_isolation(raw_a: u64, raw_b: u64) {
    let owner = @0xD00D;
    let mut scenario = setup_with_account(owner);

    let tokens_a = (raw_a % 40) + 10; // 10 to 49 tokens
    let tokens_b = (raw_b % 40) + 10;
    let withdraw_tokens_a = tokens_a / 2;

    let amount_a = tokens_a * FLOAT_SCALING;
    let amount_b = tokens_b * FLOAT_SCALING;
    let withdraw_a = withdraw_tokens_a * FLOAT_SCALING;

    debug::print(&utf8(b"--- Test 4: Multi-Coin Isolation (9-Digit Scaling) ---"));
    debug::print(&utf8(b"Coin A Deposit Scaled:"));
    debug::print(&amount_a);
    debug::print(&utf8(b"Coin B Deposit Scaled:"));
    debug::print(&amount_b);
    debug::print(&utf8(b"Withdrawing half of Coin A:"));
    debug::print(&withdraw_a);

    scenario.next_tx(owner);
    let mut wrapper = take_account_wrapper(&scenario, owner);
    let root = accumulator_support::take_root(&scenario);
    let clock = scenario.take_shared<Clock>();

    let auth = account::generate_auth(scenario.ctx());
    let mut account = wrapper.load_account_mut(auth);

    account.deposit<COIN_A>(coin::mint_for_testing<COIN_A>(amount_a, scenario.ctx()));
    account.deposit<COIN_B>(coin::mint_for_testing<COIN_B>(amount_b, scenario.ctx()));

    let withdrawn_a = account.withdraw<COIN_A>(withdraw_a, scenario.ctx());
    destroy(withdrawn_a);

    debug::print(&utf8(b"Coin A Balance Left (Scaled):"));
    debug::print(&account.balance<COIN_A>(&root, &clock));
    debug::print(&utf8(b"Coin B Balance Left (must remain unchanged):"));
    debug::print(&account.balance<COIN_B>(&root, &clock));

    assert_eq!(account.balance<COIN_A>(&root, &clock), amount_a - withdraw_a);
    assert_eq!(account.balance<COIN_B>(&root, &clock), amount_b);

    return_shared(clock);
    return_shared(root);
    return_shared(wrapper);
    scenario.end();
}

/// 5. Boundary test: Over-withdrawing arbitrary excess amounts always aborts (9-digit scaling).
#[random_test, expected_failure(abort_code = account::EBalanceTooLow)]
fun random_excessive_withdrawal_aborts(raw_deposit: u64, raw_excess: u64) {
    let owner = @0xEE;
    let mut scenario = setup_with_account(owner);

    let deposit_tokens = (raw_deposit % 20) + 1; // 1 to 20 tokens
    let excess_tokens = (raw_excess % 10) + 1; // 1 to 10 tokens

    let deposit_amount = deposit_tokens * FLOAT_SCALING;
    let withdraw_amount = (deposit_tokens + excess_tokens) * FLOAT_SCALING;

    debug::print(
        &utf8(b"--- Test 5: Excessive Withdrawal with 9-Digit Scaling (Expect Abort) ---"),
    );
    debug::print(&utf8(b"Deposit Scaled:"));
    debug::print(&deposit_amount);
    debug::print(&utf8(b"Trying to Over-Withdraw Scaled:"));
    debug::print(&withdraw_amount);

    scenario.next_tx(owner);
    let mut wrapper = take_account_wrapper(&scenario, owner);

    let auth = account::generate_auth(scenario.ctx());
    let mut account = wrapper.load_account_mut(auth);

    account.deposit<TEST_COIN>(coin::mint_for_testing<TEST_COIN>(deposit_amount, scenario.ctx()));

    let withdrawn = account.withdraw<TEST_COIN>(withdraw_amount, scenario.ctx());
    destroy(withdrawn);

    return_shared(wrapper);
    scenario.end();
}

/// 6. App data round-trip: Arbitrary 9-digit scaled values store and retrieve losslessly.
#[random_test]
fun random_app_data_roundtrip(raw_value: u64) {
    let owner = @0xFF;
    let mut scenario = setup_with_account(owner);

    let tokens = (raw_value % 100) + 1;
    let value = tokens * FLOAT_SCALING; // 9-digit scaled value

    debug::print(&utf8(b"--- Test 6: App Data Roundtrip (9-Digit Scaling) ---"));
    debug::print(&utf8(b"Data Scaled Value (9 Digits):"));
    debug::print(&value);

    scenario.next_tx(owner);
    let mut wrapper = take_account_wrapper(&scenario, owner);

    let auth = account::generate_auth(scenario.ctx());
    let mut account = wrapper.load_account_mut(auth);

    account.attach<TestApp, TestData>(permit<TestApp>(), TestData { value });

    assert_eq!(account.borrow_data<TestApp, TestData>().value, value);

    let detached = account.detach<TestApp, TestData>(permit<TestApp>());
    assert_eq!(detached.value, value);
    let TestData { value: _ } = detached;

    debug::print(&utf8(b"Stored & Detached Intact with 9 Digits!"));

    return_shared(wrapper);
    scenario.end();
}
