// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module margin_trading::margin_master_tests;

use deepbook::math;
use margin_trading::{
    margin_constants,
    margin_pool::MarginPool,
    margin_registry::MarginRegistry,
    test_constants::{Self, USDC, USDT},
    test_helpers::{
        setup_margin_registry,
        create_margin_pool,
        default_protocol_config,
        cleanup_margin_test,
        mint_coin,
        advance_time
    }
};
use sui::{test_scenario::return_shared, test_utils::destroy};

/// A comprehensive master test demonstrating the core margin trading workflow with exact interest calculations:
/// 1. Setup margin pools for USDC and USDT
/// 2. Users supply assets to pools (no referral to avoid protocol fees)
/// 3. Users borrow from pools creating debt positions
/// 4. Time progression by exactly 1 year with precise interest accrual calculations
/// 5. Verify exact interest amounts based on utilization rates and interest rate model
/// 6. Users repay and withdraw with earned interest
/// 7. Pool liquidation scenarios and comprehensive cleanup
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
    // Interest Rate Model:
    // - Base rate: 5%
    // - Base slope: 10%
    // - Optimal utilization: 80%
    // - Excess slope: 200%
    // Formula: if utilization < 80% then rate = 5% + 10% * utilization
    //          else rate = 5% + 10% * 80% + 200% * (utilization - 80%)

    // Advance time by exactly 1 year for precise interest calculations
    advance_time(&mut clock, margin_constants::year_ms());

    // Calculate expected interest for USDC loan manually
    // Step 1: Calculate utilization rate
    // Total supply: 175000 USDC (100000 + 75000)
    // Total borrow: 35000 USDC (15000 + 20000 from User2)
    // Utilization rate = borrow / supply = 35000 / 175000 = 0.2 = 200_000_000 (with 9 decimals)
    let total_supply_usdc = 175000 * test_constants::usdc_multiplier();
    let total_borrow_usdc = 35000 * test_constants::usdc_multiplier();
    let utilization_rate_usdc = math::div(total_borrow_usdc, total_supply_usdc);

    // Step 2: Calculate interest rate
    // Since 20% < 80% optimal, use base rate + base_slope * utilization
    // Interest rate = 5% + 10% * 20% = 5% + 2% = 7%
    let base_rate = test_constants::base_rate(); // 50_000_000 (5%)
    let base_slope = test_constants::base_slope(); // 100_000_000 (10%)
    let interest_rate_usdc = base_rate + math::mul(utilization_rate_usdc, base_slope);

    // Step 3: Calculate time-adjusted rate for 1 year
    let time_adjusted_rate_usdc = math::div(
        math::mul(margin_constants::year_ms(), interest_rate_usdc),
        margin_constants::year_ms(),
    ); // This should equal interest_rate_usdc since time = 1 year

    // Step 4: Calculate interest on total borrow
    let interest_usdc = math::mul(total_borrow_usdc, time_adjusted_rate_usdc);

    // Step 5: Calculate new total borrow (for reference)
    let _new_total_borrow_usdc = total_borrow_usdc + interest_usdc;

    // Step 6: Calculate expected debt for User1's shares
    // User1's debt = (User1's shares / total shares) * new total borrow
    // But we need to calculate this using the same logic as borrow_shares_to_amount
    // Expected debt = shares / (total_shares / new_total_borrow) = shares * new_total_borrow / total_shares

    // For now, let's verify the actual calculation matches our manual one
    let debt_after_interest1 = usdc_pool.borrow_shares_to_amount(usdc_borrow_shares1, &clock);

    // The actual calculation in borrow_shares_to_amount:
    // 1. Calculate interest on total pool borrow: interest = total_borrow * time_adjusted_rate
    // 2. New total borrow = total_borrow + interest
    // 3. ratio = total_borrow_shares / new_total_borrow
    // 4. user_debt = user_shares / ratio = user_shares * new_total_borrow / total_borrow_shares

    // Since User1 has 15000 out of 35000 total borrow, their share ratio is 15000/35000
    // After interest, total borrow becomes 35000 * (1 + 7%) = 37450
    // User1's debt = (15000/35000) * 37450 = 16050 USDC
    let new_total_borrow_after_interest =
        total_borrow_usdc + math::mul(total_borrow_usdc, interest_rate_usdc);
    let user1_borrow_ratio = math::div(
        15000 * test_constants::usdc_multiplier(),
        total_borrow_usdc,
    );
    let expected_usdc_debt = math::mul(user1_borrow_ratio, new_total_borrow_after_interest);

    // Allow small tolerance for rounding in share calculations
    let tolerance = 1000; // Small tolerance for rounding
    assert!(
        debt_after_interest1 >= expected_usdc_debt - tolerance &&
        debt_after_interest1 <= expected_usdc_debt + tolerance,
        1,
    );

    // Calculate expected interest for USDT loan manually
    // Total supply: 80000 USDT (50000 + 30000)
    // Total borrow: 10000 USDT (only User2's loan)
    // Utilization rate = borrow / supply = 10000 / 80000 = 0.125 = 125_000_000 (with 9 decimals)
    let total_supply_usdt = 80000 * test_constants::usdt_multiplier();
    let total_borrow_usdt = 10000 * test_constants::usdt_multiplier();
    let utilization_rate_usdt = math::div(total_borrow_usdt, total_supply_usdt);

    // Interest rate = 5% + 10% * 12.5% = 5% + 1.25% = 6.25%
    let interest_rate_usdt = base_rate + math::mul(utilization_rate_usdt, base_slope);

    // Calculate time-adjusted rate for 1 year (for reference)
    let _time_adjusted_rate_usdt = interest_rate_usdt; // Since time = 1 year

    // For USDT, User2 has all 10000 out of 10000 total borrow, so ratio is 100%
    // After interest, total borrow becomes 10000 * (1 + 6.25%) = 10625 USDT
    // User2's debt = 100% * 10625 = 10625 USDT
    let debt_after_interest2 = usdt_pool.borrow_shares_to_amount(usdt_borrow_shares1, &clock);
    let new_total_borrow_usdt_after_interest =
        total_borrow_usdt + math::mul(total_borrow_usdt, interest_rate_usdt);
    let expected_usdt_debt = new_total_borrow_usdt_after_interest; // User2 has 100% of the borrow

    // Allow small tolerance for rounding in share calculations
    assert!(
        debt_after_interest2 >= expected_usdt_debt - tolerance &&
        debt_after_interest2 <= expected_usdt_debt + tolerance,
        2,
    );

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
    // Should be more than originally supplied due to interest earned
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
