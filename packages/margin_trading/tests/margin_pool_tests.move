// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module margin_trading::margin_pool_tests;

use margin_trading::{margin_pool::{Self, MarginPool}, margin_state};
use std::option::some;
use sui::{
    clock::{Self, Clock},
    coin::{Self, Coin},
    test_scenario::{Self as test, Scenario},
    test_utils::destroy
};

// Test coin types
public struct USDC has drop {}

const USER1: address = @0x1;
const USER2: address = @0x2;

// Test constants
const SUPPLY_CAP: u64 = 1_000_000_000_000; // 1M tokens with 6 decimals
const MAX_BORROW_PERCENTAGE: u64 = 800_000_000; // 80% with 9 decimals
const PROTOCOL_SPREAD: u64 = 100_000_000; // 10% with 9 decimals

fun setup_test(): (Scenario, Clock, MarginPool<USDC>) {
    let mut scenario = test::begin(@0x0);
    let clock = clock::create_for_testing(scenario.ctx());
    let interest_params = margin_state::new_interest_params(
        50_000_000, // base_rate: 5% with 9 decimals
        100_000_000, // base_slope: 10% with 9 decimals
        800_000_000, // optimal_utilization: 80% with 9 decimals
        2_000_000_000, // excess_slope: 200% with 9 decimals
    );
    let _pool_id = margin_pool::create_margin_pool<USDC>(
        interest_params,
        SUPPLY_CAP,
        MAX_BORROW_PERCENTAGE,
        PROTOCOL_SPREAD,
        &clock,
        scenario.ctx(),
    );

    scenario.next_tx(@0x0);
    let pool = scenario.take_shared<MarginPool<USDC>>();
    (scenario, clock, pool)
}

fun mint_coin<T>(amount: u64, ctx: &mut TxContext): Coin<T> {
    coin::mint_for_testing<T>(amount, ctx)
}

#[test]
fun test_supply_and_withdraw_basic() {
    let (mut scenario, mut clock, mut pool) = setup_test();

    // Set clock to avoid interest rate calculation issues
    clock.set_for_testing(1000);

    // User supplies tokens
    scenario.next_tx(USER1);
    let supply_coin = mint_coin<USDC>(100000, scenario.ctx());
    pool.supply<USDC>(supply_coin, option::none(), &clock, scenario.ctx());

    // User withdraws tokens
    let withdrawn = pool.withdraw<USDC>(some(50000), &clock, scenario.ctx());
    assert!(withdrawn.value() == 50000);

    destroy(withdrawn);
    test::return_shared(pool);
    destroy(clock);
    scenario.end();
}

#[test, expected_failure(abort_code = margin_pool::ESupplyCapExceeded)]
fun test_supply_cap_enforcement() {
    let (mut scenario, mut clock, mut pool) = setup_test();

    clock.set_for_testing(1000);

    scenario.next_tx(USER1);
    let supply_coin = mint_coin<USDC>(SUPPLY_CAP + 1, scenario.ctx());

    // This should fail due to supply cap
    pool.supply<USDC>(supply_coin, option::none(), &clock, scenario.ctx());

    destroy(pool);
    destroy(clock);
    scenario.end();
}

#[test]
fun test_multiple_users_supply_withdraw() {
    let (mut scenario, mut clock, mut pool) = setup_test();

    clock.set_for_testing(1000);

    // User1 supplies
    scenario.next_tx(USER1);
    let supply_coin1 = mint_coin<USDC>(50000, scenario.ctx());
    pool.supply<USDC>(supply_coin1, option::none(), &clock, scenario.ctx());

    // User2 supplies
    scenario.next_tx(USER2);
    let supply_coin2 = mint_coin<USDC>(30000, scenario.ctx());
    pool.supply<USDC>(supply_coin2, option::none(), &clock, scenario.ctx());
    // User1 withdraws
    scenario.next_tx(USER1);
    let withdrawn1 = pool.withdraw<USDC>(option::some(25000), &clock, scenario.ctx());
    assert!(withdrawn1.value() == 25000);

    // User2 withdraws
    scenario.next_tx(USER2);
    let withdrawn2 = pool.withdraw<USDC>(option::some(15000), &clock, scenario.ctx());
    assert!(withdrawn2.value() == 15000);

    destroy(withdrawn1);
    destroy(withdrawn2);
    destroy(pool);
    destroy(clock);
    scenario.end();
}

#[test]
fun test_withdraw_all() {
    let (mut scenario, mut clock, mut pool) = setup_test();

    clock.set_for_testing(1000);

    scenario.next_tx(USER1);
    let supply_amount = 100000;
    let supply_coin = mint_coin<USDC>(supply_amount, scenario.ctx());
    pool.supply<USDC>(supply_coin, option::none(), &clock, scenario.ctx());

    // Withdraw all (using option::none())
    let withdrawn = pool.withdraw<USDC>(option::none(), &clock, scenario.ctx());
    assert!(withdrawn.value() == supply_amount);

    destroy(withdrawn);
    destroy(pool);
    destroy(clock);
    scenario.end();
}

#[test, expected_failure(abort_code = margin_pool::ECannotWithdrawMoreThanSupply)]
fun test_withdraw_more_than_supplied() {
    let (mut scenario, mut clock, mut pool) = setup_test();

    clock.set_for_testing(1000);

    scenario.next_tx(USER1);
    let supply_coin = mint_coin<USDC>(50000, scenario.ctx());
    pool.supply<USDC>(supply_coin, option::none(), &clock, scenario.ctx());

    // Try to withdraw more than supplied
    let withdrawn = pool.withdraw<USDC>(option::some(60000), &clock, scenario.ctx());

    destroy(withdrawn);
    destroy(pool);
    destroy(clock);
    scenario.end();
}

#[test]
fun test_create_margin_pool() {
    let (scenario, clock, pool) = setup_test();

    // Test that pool was created with correct parameters
    assert!(pool.supply_cap() == SUPPLY_CAP);

    destroy(pool);
    destroy(clock);
    scenario.end();
}
