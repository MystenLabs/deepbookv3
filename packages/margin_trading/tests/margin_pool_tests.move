// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module margin_trading::margin_pool_tests;

use margin_trading::{
    margin_pool::{Self, MarginPool},
    margin_registry::{Self, MarginRegistry, MarginAdminCap, MaintainerCap, MarginPoolCap},
    protocol_config::{Self}
};
use sui::{
    clock::{Self, Clock},
    coin::{Self, Coin},
    test_scenario::{Self as test, Scenario},
    test_utils::destroy
};

public struct USDC has drop {}
public struct USDT has drop {}

const USER1: address = @0x1;
const USER2: address = @0x2;
const ADMIN: address = @0x0;

// Test constants
const SUPPLY_CAP: u64 = 1_000_000_000_000; // 1M tokens with 9 decimals 
const MAX_UTILIZATION_RATE: u64 = 800_000_000; // 80% with 9 decimals
const PROTOCOL_SPREAD: u64 = 100_000_000; // 10% with 9 decimals

fun setup_test(): (Scenario, Clock, MarginRegistry, MarginAdminCap, MaintainerCap, ID) {
    let mut scenario = test::begin(ADMIN);
    let clock = clock::create_for_testing(scenario.ctx());
    
    let (mut registry, admin_cap) = margin_registry::new_for_testing(scenario.ctx());
    let maintainer_cap = margin_registry::mint_maintainer_cap(&mut registry, &admin_cap, scenario.ctx());
    
    let margin_pool_config = protocol_config::new_margin_pool_config(
        SUPPLY_CAP,
        MAX_UTILIZATION_RATE,
        PROTOCOL_SPREAD,
    );
    let interest_config = protocol_config::new_interest_config(
        50_000_000,   // base_rate: 5% with 9 decimals
        100_000_000,  // base_slope: 10% with 9 decimals
        800_000_000,  // optimal_utilization: 80% with 9 decimals
        2_000_000_000, // excess_slope: 200% with 9 decimals
    );
    let protocol_config = protocol_config::new_protocol_config(margin_pool_config, interest_config);
    let pool_id = margin_pool::create_margin_pool<USDC>(
        &mut registry,
        protocol_config,
        &maintainer_cap,
        &clock,
        scenario.ctx(),
    );
    
    (scenario, clock, registry, admin_cap, maintainer_cap, pool_id)
}

fun mint_coin<T>(amount: u64, ctx: &mut TxContext): Coin<T> {
    coin::mint_for_testing<T>(amount, ctx)
}

fun cleanup_test(registry: MarginRegistry, admin_cap: MarginAdminCap, maintainer_cap: MaintainerCap, clock: Clock, scenario: Scenario) {
    destroy(registry);
    destroy(admin_cap);
    destroy(maintainer_cap);
    destroy(clock);
    scenario.end();
}

/// Test-only wrapper for borrow function to test ENotEnoughAssetInPool
#[test_only]
public fun test_borrow<Asset>(
    pool: &mut MarginPool<Asset>,
    amount: u64,
    clock: &Clock,
    ctx: &mut TxContext,
): Coin<Asset> {
    pool.borrow(amount, clock, ctx)
}

#[test]
fun test_supply_and_withdraw_basic() {
    let (mut scenario, mut clock, registry, admin_cap, maintainer_cap, pool_id) = setup_test();
    clock.set_for_testing(1000);
    
    scenario.next_tx(ADMIN);
    let mut pool = scenario.take_shared_by_id<MarginPool<USDC>>(pool_id);
    
    scenario.next_tx(USER1);
    let supply_coin = mint_coin<USDC>(100_000_000_000, scenario.ctx()); // 100 tokens with 9 decimals
    pool.supply<USDC>(&registry, supply_coin, option::none(), &clock, scenario.ctx());
    
    let withdrawn = pool.withdraw<USDC>(&registry, option::some(50_000_000_000), &clock, scenario.ctx()); // 50 tokens
    assert!(withdrawn.value() == 50_000_000_000);
    
    destroy(withdrawn);
    test::return_shared(pool);
    cleanup_test(registry, admin_cap, maintainer_cap, clock, scenario);
}

#[test, expected_failure(abort_code = margin_trading::margin_pool::ESupplyCapExceeded)]
fun test_supply_cap_enforcement() {
    let (mut scenario, mut clock, registry, admin_cap, maintainer_cap, pool_id) = setup_test();
    clock.set_for_testing(1000);
    
    scenario.next_tx(ADMIN);
    let mut pool = scenario.take_shared_by_id<MarginPool<USDC>>(pool_id);
    
    scenario.next_tx(USER1);
    let supply_coin = mint_coin<USDC>(SUPPLY_CAP + 1, scenario.ctx());
    
    // This should fail due to supply cap
    pool.supply<USDC>(&registry, supply_coin, option::none(), &clock, scenario.ctx());
    
    test::return_shared(pool);
    cleanup_test(registry, admin_cap, maintainer_cap, clock, scenario);
}

#[test]
fun test_multiple_users_supply_withdraw() {
    let (mut scenario, mut clock, registry, admin_cap, maintainer_cap, pool_id) = setup_test();
    clock.set_for_testing(1000);
    
    scenario.next_tx(ADMIN);
    let mut pool = scenario.take_shared_by_id<MarginPool<USDC>>(pool_id);
    
    // User1 supplies
    scenario.next_tx(USER1);
    let supply_coin1 = mint_coin<USDC>(50_000_000_000, scenario.ctx()); // 50 tokens
    pool.supply<USDC>(&registry, supply_coin1, option::none(), &clock, scenario.ctx());
    
    // User2 supplies
    scenario.next_tx(USER2);
    let supply_coin2 = mint_coin<USDC>(30_000_000_000, scenario.ctx()); // 30 tokens
    pool.supply<USDC>(&registry, supply_coin2, option::none(), &clock, scenario.ctx());
    
    scenario.next_tx(USER1);
    let withdrawn1 = pool.withdraw<USDC>(&registry, option::some(25_000_000_000), &clock, scenario.ctx());
    assert!(withdrawn1.value() == 25_000_000_000);
    
    scenario.next_tx(USER2);
    let withdrawn2 = pool.withdraw<USDC>(&registry, option::some(15_000_000_000), &clock, scenario.ctx());
    assert!(withdrawn2.value() == 15_000_000_000);
    
    destroy(withdrawn1);
    destroy(withdrawn2);
    test::return_shared(pool);
    cleanup_test(registry, admin_cap, maintainer_cap, clock, scenario);
}

#[test]
fun test_withdraw_all() {
    let (mut scenario, mut clock, registry, admin_cap, maintainer_cap, pool_id) = setup_test();
    clock.set_for_testing(1000);
    
    scenario.next_tx(ADMIN);
    let mut pool = scenario.take_shared_by_id<MarginPool<USDC>>(pool_id);
    
    scenario.next_tx(USER1);
    let supply_amount = 100_000_000_000; // 100 tokens
    let supply_coin = mint_coin<USDC>(supply_amount, scenario.ctx());
    pool.supply<USDC>(&registry, supply_coin, option::none(), &clock, scenario.ctx());
    
    let withdrawn = pool.withdraw<USDC>(&registry, option::none(), &clock, scenario.ctx());
    assert!(withdrawn.value() == supply_amount);
    
    destroy(withdrawn);
    test::return_shared(pool);
    cleanup_test(registry, admin_cap, maintainer_cap, clock, scenario);
}

#[test, expected_failure(abort_code = margin_trading::margin_pool::ECannotWithdrawMoreThanSupply)]
fun test_withdraw_more_than_supplied() {
    let (mut scenario, mut clock, registry, admin_cap, maintainer_cap, pool_id) = setup_test();
    clock.set_for_testing(1000);
    
    scenario.next_tx(ADMIN);
    let mut pool = scenario.take_shared_by_id<MarginPool<USDC>>(pool_id);
    
    scenario.next_tx(USER1);
    let supply_coin = mint_coin<USDC>(50_000_000_000, scenario.ctx()); // 50 tokens
    pool.supply<USDC>(&registry, supply_coin, option::none(), &clock, scenario.ctx());
    
    let withdrawn = pool.withdraw<USDC>(&registry, option::some(60_000_000_000), &clock, scenario.ctx()); 
    
    destroy(withdrawn);
    test::return_shared(pool);
    cleanup_test(registry, admin_cap, maintainer_cap, clock, scenario);
}

#[test]
fun test_create_margin_pool_with_config() {
    let (mut scenario, clock, registry, admin_cap, maintainer_cap, pool_id) = setup_test();
    
    scenario.next_tx(ADMIN);
    let pool = scenario.take_shared_by_id<MarginPool<USDC>>(pool_id);
    
    test::return_shared(pool);
    cleanup_test(registry, admin_cap, maintainer_cap, clock, scenario);
}

#[test]
fun test_interest_accrual_over_time() {
    let (mut scenario, mut clock, registry, admin_cap, maintainer_cap, pool_id) = setup_test();
    clock.set_for_testing(1000);
    
    scenario.next_tx(ADMIN);
    let mut pool = scenario.take_shared_by_id<MarginPool<USDC>>(pool_id);
    
    scenario.next_tx(USER1);
    let supply_amount = 100_000_000_000; // 100 tokens
    let supply_coin = mint_coin<USDC>(supply_amount, scenario.ctx());
    pool.supply<USDC>(&registry, supply_coin, option::none(), &clock, scenario.ctx());
    
    // Advance time by 1 day
    clock.set_for_testing(1000 + 86400000);
    
    let withdrawn = pool.withdraw<USDC>(&registry, option::none(), &clock, scenario.ctx());
    assert!(withdrawn.value() >= supply_amount);
    
    destroy(withdrawn);
    test::return_shared(pool);
    cleanup_test(registry, admin_cap, maintainer_cap, clock, scenario);
}

#[test, expected_failure(abort_code = margin_trading::margin_pool::ENotEnoughAssetInPool)]
fun test_not_enough_asset_in_pool() {
    let (mut scenario, mut clock, registry, admin_cap, maintainer_cap, pool_id) = setup_test();
    
    clock.set_for_testing(1000);
    
    scenario.next_tx(ADMIN);
    let mut pool = scenario.take_shared_by_id<MarginPool<USDC>>(pool_id);
    
    scenario.next_tx(USER1);
    let supply_coin = mint_coin<USDC>(100_000_000_000, scenario.ctx()); // 100 tokens
    pool.supply<USDC>(&registry, supply_coin, option::none(), &clock, scenario.ctx());
    
    scenario.next_tx(USER2);
    let borrowed_coin = test_borrow(&mut pool, 80_000_000_000, &clock, scenario.ctx()); // 80 tokens
    destroy(borrowed_coin);
    
    // Should fail due to outstanding loan
    scenario.next_tx(USER1);
    let withdrawn = pool.withdraw<USDC>(&registry, option::none(), &clock, scenario.ctx());
    
    destroy(withdrawn);
    test::return_shared(pool);
    cleanup_test(registry, admin_cap, maintainer_cap, clock, scenario);
}

#[test, expected_failure(abort_code = margin_trading::margin_pool::EMaxPoolBorrowPercentageExceeded)]
fun test_max_pool_borrow_percentage_exceeded() {
    let (mut scenario, mut clock, registry, admin_cap, maintainer_cap, pool_id) = setup_test();
    
    clock.set_for_testing(1000);
    
    scenario.next_tx(ADMIN);
    let mut pool = scenario.take_shared_by_id<MarginPool<USDC>>(pool_id);
    
    scenario.next_tx(USER1);
    let supply_coin = mint_coin<USDC>(100_000_000_000, scenario.ctx()); // 100 tokens
    pool.supply<USDC>(&registry, supply_coin, option::none(), &clock, scenario.ctx());
    
    // Above max utilization rate
    scenario.next_tx(USER2);
    let borrowed_coin = test_borrow(&mut pool, 85_000_000_000, &clock, scenario.ctx()); // 85 tokens > 80%
    
    destroy(borrowed_coin);
    test::return_shared(pool);
    cleanup_test(registry, admin_cap, maintainer_cap, clock, scenario);
}

#[test, expected_failure(abort_code = margin_trading::margin_pool::EInvalidLoanQuantity)]
fun test_invalid_loan_quantity() {
    let (mut scenario, mut clock, registry, admin_cap, maintainer_cap, pool_id) = setup_test();
    
    clock.set_for_testing(1000);
    
    scenario.next_tx(ADMIN);
    let mut pool = scenario.take_shared_by_id<MarginPool<USDC>>(pool_id);
    
    scenario.next_tx(USER1);
    let supply_coin = mint_coin<USDC>(100_000_000_000, scenario.ctx()); // 100 tokens
    pool.supply<USDC>(&registry, supply_coin, option::none(), &clock, scenario.ctx());
    
    scenario.next_tx(USER2);
    let borrowed_coin = test_borrow(&mut pool, 0, &clock, scenario.ctx());
    
    destroy(borrowed_coin);
    test::return_shared(pool);
    cleanup_test(registry, admin_cap, maintainer_cap, clock, scenario);
}

#[test, expected_failure(abort_code = margin_trading::margin_pool::EDeepbookPoolAlreadyAllowed)]
fun test_deepbook_pool_already_allowed() {
    let (mut scenario, mut clock, registry, admin_cap, maintainer_cap, pool_id) = setup_test();
    
    clock.set_for_testing(1000);
    
    scenario.next_tx(ADMIN);
    let mut pool = scenario.take_shared_by_id<MarginPool<USDC>>(pool_id);
    let margin_pool_cap = scenario.take_from_sender<MarginPoolCap>();
    
    let deepbook_pool_id = object::id_from_address(@0x123);
    
    pool.enable_deepbook_pool_for_loan(&registry, deepbook_pool_id, &margin_pool_cap);
    pool.enable_deepbook_pool_for_loan(&registry, deepbook_pool_id, &margin_pool_cap);
    
    scenario.return_to_sender(margin_pool_cap);
    test::return_shared(pool);
    cleanup_test(registry, admin_cap, maintainer_cap, clock, scenario);
}

#[test, expected_failure(abort_code = margin_trading::margin_pool::EInvalidMarginPoolCap)]
fun test_invalid_margin_pool_cap() {
    let (mut scenario, mut clock, mut registry, admin_cap, maintainer_cap, pool_id) = setup_test();
    
    clock.set_for_testing(1000);
    
    // Create a second margin pool to get a different MarginPoolCap
    scenario.next_tx(ADMIN);
    let margin_pool_config2 = protocol_config::new_margin_pool_config(
        500_000_000_000, // Different supply cap
        MAX_UTILIZATION_RATE,
        PROTOCOL_SPREAD,
    );
    let interest_config2 = protocol_config::new_interest_config(
        50_000_000,
        100_000_000,
        800_000_000,
        2_000_000_000,
    );
    let protocol_config2 = protocol_config::new_protocol_config(margin_pool_config2, interest_config2);
    let _pool_id2 = margin_pool::create_margin_pool<USDT>(
        &mut registry,
        protocol_config2,
        &maintainer_cap,
        &clock,
        scenario.ctx(),
    );
    
    scenario.next_tx(ADMIN);
    let mut pool = scenario.take_shared_by_id<MarginPool<USDC>>(pool_id);
    let wrong_margin_pool_cap = scenario.take_from_sender<MarginPoolCap>(); // This cap belongs to pool2, not pool
    
    let deepbook_pool_id = object::id_from_address(@0x123);
    
    // Try to use wrong cap with the first pool (should fail)
    pool.enable_deepbook_pool_for_loan(&registry, deepbook_pool_id, &wrong_margin_pool_cap);
    
    scenario.return_to_sender(wrong_margin_pool_cap);
    test::return_shared(pool);
    cleanup_test(registry, admin_cap, maintainer_cap, clock, scenario);
}
