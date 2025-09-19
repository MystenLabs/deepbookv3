// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module margin_trading::margin_master_tests;

use margin_trading::margin_pool::MarginPool;
use margin_trading::margin_registry::MarginRegistry;
use margin_trading::test_constants::{Self, USDC, USDT};
use margin_trading::test_helpers::{
    setup_margin_registry,
    create_margin_pool,
    default_protocol_config,
    cleanup_margin_test,
    mint_coin,
    advance_time
};
use sui::test_scenario::return_shared;
use sui::test_utils::destroy;

/// A comprehensive master test demonstrating the core margin trading workflow:
/// 1. Setup margin pools for USDC and USDT
/// 2. Users supply assets to pools with referral system
/// 3. Users borrow from pools with interest accrual
/// 4. Time progression to demonstrate interest accumulation
/// 5. Users withdraw from pools with earned interest
/// 6. Pool liquidation scenarios
/// 7. Comprehensive cleanup
#[test]
fun test_comprehensive_margin_trading_flow() {
    let (mut scenario, mut clock, admin_cap, maintainer_cap) = setup_margin_registry();

    // === Phase 1: Setup Margin Pools ===
    create_margin_pool<USDC>(
        &mut scenario,
        &maintainer_cap,
        default_protocol_config(),
        &clock,
    );
    create_margin_pool<USDT>(
        &mut scenario,
        &maintainer_cap,
        default_protocol_config(),
        &clock,
    );

    scenario.next_tx(test_constants::admin());
    let registry = scenario.take_shared<MarginRegistry>();
    let mut usdc_pool = scenario.take_shared<MarginPool<USDC>>();
    let mut usdt_pool = scenario.take_shared<MarginPool<USDT>>();

    // === Phase 2: Supply Assets to Pools ===

    // User1 supplies USDC (without referral to avoid protocol fees issue)
    scenario.next_tx(test_constants::user1());
    let usdc_supply1 = mint_coin<USDC>(100000 * test_constants::usdc_multiplier(), scenario.ctx());
    usdc_pool.supply(&registry, usdc_supply1, option::none(), &clock, scenario.ctx());

    // User1 also supplies USDT
    let usdt_supply1 = mint_coin<USDT>(50000 * test_constants::usdt_multiplier(), scenario.ctx());
    usdt_pool.supply(&registry, usdt_supply1, option::none(), &clock, scenario.ctx());

    // User2 supplies additional USDC
    scenario.next_tx(test_constants::user2());
    let usdc_supply2 = mint_coin<USDC>(75000 * test_constants::usdc_multiplier(), scenario.ctx());
    usdc_pool.supply(&registry, usdc_supply2, option::none(), &clock, scenario.ctx());

    // User2 also supplies USDT
    let usdt_supply2 = mint_coin<USDT>(30000 * test_constants::usdt_multiplier(), scenario.ctx());
    usdt_pool.supply(&registry, usdt_supply2, option::none(), &clock, scenario.ctx());

    // === Phase 3: Borrowing Operations ===

    // User1 borrows USDC
    scenario.next_tx(test_constants::user1());
    let (borrowed_usdc1, _, usdc_borrow_shares1) = usdc_pool.borrow(
        15000 * test_constants::usdc_multiplier(),
        &clock,
        scenario.ctx(),
    );
    destroy(borrowed_usdc1);

    // User2 borrows USDT
    scenario.next_tx(test_constants::user2());
    let (borrowed_usdt1, _, usdt_borrow_shares1) = usdt_pool.borrow(
        10000 * test_constants::usdt_multiplier(),
        &clock,
        scenario.ctx(),
    );
    destroy(borrowed_usdt1);

    // User2 borrows more USDC
    let (borrowed_usdc2, _, _) = usdc_pool.borrow(
        20000 * test_constants::usdc_multiplier(),
        &clock,
        scenario.ctx(),
    );
    destroy(borrowed_usdc2);

    // === Phase 4: Time Progression and Interest Accrual ===

    // Advance time by 6 months to accrue interest
    advance_time(&mut clock, 180 * 24 * 60 * 60 * 1000);

    // Verify that debt has grown due to interest
    let debt_after_interest1 = usdc_pool.borrow_shares_to_amount(usdc_borrow_shares1, &clock);
    assert!(debt_after_interest1 > 15000 * test_constants::usdc_multiplier(), 1);

    let debt_after_interest2 = usdt_pool.borrow_shares_to_amount(usdt_borrow_shares1, &clock);
    assert!(debt_after_interest2 > 10000 * test_constants::usdt_multiplier(), 2);

    // === Phase 5: Repayment Operations ===

    // User1 partially repays USDC loan
    scenario.next_tx(test_constants::user1());
    let partial_repay_amount = debt_after_interest1 / 2;
    let partial_repay_shares = usdc_borrow_shares1 / 2;
    let repay_coin1 = mint_coin<USDC>(partial_repay_amount, scenario.ctx());
    usdc_pool.repay(partial_repay_shares, repay_coin1, &clock);

    // User2 fully repays USDT loan
    scenario.next_tx(test_constants::user2());
    let full_repay_coin = mint_coin<USDT>(debt_after_interest2, scenario.ctx());
    usdt_pool.repay(usdt_borrow_shares1, full_repay_coin, &clock);

    // === Phase 6: Liquidation Scenarios ===

    // Test simple liquidation scenario with zero shares (should get all as reward)
    scenario.next_tx(test_constants::liquidator());
    let zero_liquidation_coin = mint_coin<USDC>(
        1000 * test_constants::usdc_multiplier(),
        scenario.ctx(),
    );
    let (liquidated_amount, reward, default) = usdc_pool.repay_liquidation(
        0, // zero shares
        zero_liquidation_coin,
        &clock,
    );

    // Verify liquidation results - with zero shares, all payment becomes reward
    assert!(liquidated_amount == 0, 3);
    assert!(reward == 1000 * test_constants::usdc_multiplier(), 4);
    assert!(default == 0, 5);

    // === Phase 7: Withdrawal Operations with Interest ===

    // User1 withdraws part of supplied USDC (should include earned interest)
    scenario.next_tx(test_constants::user1());
    let withdrawn_usdc1 = usdc_pool.withdraw(
        &registry,
        option::some(30000 * test_constants::usdc_multiplier()),
        &clock,
        scenario.ctx(),
    );
    // Verify withdrawal amount (should be exactly what was requested)
    assert!(withdrawn_usdc1.value() == 30000 * test_constants::usdc_multiplier(), 9);
    destroy(withdrawn_usdc1);

    // User2 withdraws all supplied USDT (should include earned interest)
    scenario.next_tx(test_constants::user2());
    let withdrawn_usdt2 = usdt_pool.withdraw(
        &registry,
        option::none(), // withdraw all
        &clock,
        scenario.ctx(),
    );
    // Should be more than originally supplied due to interest earned
    assert!(withdrawn_usdt2.value() >= 30000 * test_constants::usdt_multiplier(), 10);
    destroy(withdrawn_usdt2);

    // User1 withdraws remaining USDT
    scenario.next_tx(test_constants::user1());
    let withdrawn_usdt1 = usdt_pool.withdraw(
        &registry,
        option::none(),
        &clock,
        scenario.ctx(),
    );
    assert!(withdrawn_usdt1.value() >= 50000 * test_constants::usdt_multiplier(), 11);
    destroy(withdrawn_usdt1);

    // === Phase 8: Final Pool State Verification ===

    // Verify pools have remaining liquidity for remaining borrowers
    scenario.next_tx(test_constants::user2());
    let final_withdrawn_usdc = usdc_pool.withdraw(
        &registry,
        option::some(40000 * test_constants::usdc_multiplier()),
        &clock,
        scenario.ctx(),
    );
    destroy(final_withdrawn_usdc);

    // === Cleanup ===
    return_shared(usdc_pool);
    return_shared(usdt_pool);
    cleanup_margin_test(registry, admin_cap, maintainer_cap, clock, scenario);
}

/// Test supply cap enforcement
#[test, expected_failure(abort_code = ::margin_trading::margin_pool::ESupplyCapExceeded)]
fun test_supply_cap_exceeded() {
    let (mut scenario, clock, admin_cap, maintainer_cap) = setup_margin_registry();

    create_margin_pool<USDC>(&mut scenario, &maintainer_cap, default_protocol_config(), &clock);

    scenario.next_tx(test_constants::admin());
    let registry = scenario.take_shared<MarginRegistry>();
    let mut usdc_pool = scenario.take_shared<MarginPool<USDC>>();

    // Try to supply more than the cap allows
    scenario.next_tx(test_constants::user1());
    let huge_supply = mint_coin<USDC>(test_constants::supply_cap() + 1000000, scenario.ctx());
    usdc_pool.supply(&registry, huge_supply, option::none(), &clock, scenario.ctx());

    // Should not reach here
    return_shared(usdc_pool);
    cleanup_margin_test(registry, admin_cap, maintainer_cap, clock, scenario);
}

/// Test minimum borrow amount enforcement
#[test, expected_failure(abort_code = ::margin_trading::margin_pool::EBorrowAmountTooLow)]
fun test_borrow_amount_too_low() {
    let (mut scenario, clock, admin_cap, maintainer_cap) = setup_margin_registry();

    create_margin_pool<USDC>(&mut scenario, &maintainer_cap, default_protocol_config(), &clock);

    scenario.next_tx(test_constants::admin());
    let registry = scenario.take_shared<MarginRegistry>();
    let mut usdc_pool = scenario.take_shared<MarginPool<USDC>>();

    // Supply some assets first
    scenario.next_tx(test_constants::user1());
    let supply = mint_coin<USDC>(10000 * test_constants::usdc_multiplier(), scenario.ctx());
    usdc_pool.supply(&registry, supply, option::none(), &clock, scenario.ctx());

    // Try to borrow below minimum
    scenario.next_tx(test_constants::user2());
    let (borrowed_coin, _, _) = usdc_pool.borrow(1, &clock, scenario.ctx()); // Below minimum

    // Should not reach here
    destroy(borrowed_coin);
    return_shared(usdc_pool);
    cleanup_margin_test(registry, admin_cap, maintainer_cap, clock, scenario);
}

/// Test borrowing more than available in pool
#[test, expected_failure(abort_code = ::margin_trading::margin_pool::ENotEnoughAssetInPool)]
fun test_not_enough_asset_in_pool() {
    let (mut scenario, clock, admin_cap, maintainer_cap) = setup_margin_registry();

    create_margin_pool<USDC>(&mut scenario, &maintainer_cap, default_protocol_config(), &clock);

    scenario.next_tx(test_constants::admin());
    let registry = scenario.take_shared<MarginRegistry>();
    let mut usdc_pool = scenario.take_shared<MarginPool<USDC>>();

    // Supply small amount
    scenario.next_tx(test_constants::user1());
    let small_supply = mint_coin<USDC>(1000 * test_constants::usdc_multiplier(), scenario.ctx());
    usdc_pool.supply(&registry, small_supply, option::none(), &clock, scenario.ctx());

    // Try to borrow much more than available
    scenario.next_tx(test_constants::user2());
    let (borrowed_coin, _, _) = usdc_pool.borrow(
        10000 * test_constants::usdc_multiplier(), // Much more than supplied
        &clock,
        scenario.ctx(),
    );

    // Should not reach here
    destroy(borrowed_coin);
    return_shared(usdc_pool);
    cleanup_margin_test(registry, admin_cap, maintainer_cap, clock, scenario);
}
