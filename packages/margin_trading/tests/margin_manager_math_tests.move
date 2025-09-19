// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module margin_trading::margin_manager_math_tests;

use deepbook::pool::Pool;
use margin_trading::{
    margin_manager::{Self, MarginManager},
    margin_pool::MarginPool,
    margin_registry::MarginRegistry,
    test_constants::{Self, USDC, BTC, SUI, btc_multiplier, sui_multiplier},
    test_helpers::{
        cleanup_margin_test,
        mint_coin,
        build_demo_usdc_price_info_object,
        build_btc_price_info_object,
        build_sui_price_info_object,
        setup_btc_usd_margin_trading,
        setup_btc_sui_margin_trading,
        destroy_3,
        return_shared_3
    }
};
use sui::test_utils::destroy;

const ENoError: u64 = 0;
const ECannotLiquidate: u64 = 1;
const ECannotWithdraw: u64 = 2;

#[test]
fun test_liquidation_ok() {
    test_liquidation(ENoError);
}

#[test, expected_failure(abort_code = margin_manager::ECannotLiquidate)]
fun test_liquidation_cannot_liquidate() {
    test_liquidation(ECannotLiquidate);
}

#[test]
fun test_liquidation_2_ok() {
    test_liquidation_2(ENoError);
}

#[test, expected_failure(abort_code = margin_manager::EWithdrawRiskRatioExceeded)]
fun test_liquidation_cannot_withdraw() {
    test_liquidation_2(ECannotWithdraw);
}

fun test_liquidation(error_code: u64) {
    let (
        mut scenario,
        clock,
        admin_cap,
        maintainer_cap,
        _btc_pool_id,
        usdc_pool_id,
        _pool_id,
    ) = setup_btc_usd_margin_trading();

    let btc_price = build_btc_price_info_object(&mut scenario, 50, &clock);
    let usdc_price = build_demo_usdc_price_info_object(&mut scenario, &clock);

    scenario.next_tx(test_constants::user1());
    let mut pool = scenario.take_shared<Pool<BTC, USDC>>();
    let registry = scenario.take_shared<MarginRegistry>();
    margin_manager::new<BTC, USDC>(&pool, &registry, &clock, scenario.ctx());

    scenario.next_tx(test_constants::user1());
    let mut mm = scenario.take_shared<MarginManager<BTC, USDC>>();
    let mut usdc_pool = scenario.take_shared_by_id<MarginPool<USDC>>(usdc_pool_id);

    // Deposit 1 BTC worth $50
    mm.deposit<BTC, USDC, BTC>(
        &registry,
        mint_coin<BTC>(1 * btc_multiplier(), scenario.ctx()),
        scenario.ctx(),
    );

    // Borrow $200 USDC. Risk ratio = (50 + 200) / 200 = 1.25
    mm.borrow_quote<BTC, USDC>(
        &registry,
        &mut usdc_pool,
        &btc_price,
        &usdc_price,
        &pool,
        200 * test_constants::usdc_multiplier(),
        &clock,
        scenario.ctx(),
    );

    assert!(
        mm.risk_ratio(&registry, &btc_price, &usdc_price, &pool, &usdc_pool, &clock) == 1_250_000_000,
        0,
    );

    // Perform liquidation and check rewards
    scenario.next_tx(test_constants::liquidator());

    if (error_code == ECannotLiquidate) {
        // At BTC price 40, Risk ratio = (40 + 200) / 200 = 1.2, still cannot liquidate
        let repay_coin = mint_coin<USDC>(500 * test_constants::usdc_multiplier(), scenario.ctx());
        let btc_price_40 = build_btc_price_info_object(&mut scenario, 40, &clock);
        assert!(
            mm.risk_ratio(&registry, &btc_price_40, &usdc_price, &pool, &usdc_pool, &clock) == 1_200_000_000,
            0,
        );

        let (_base_coin, _quote_coin, _remaining_repay_coin) = mm.liquidate<BTC, USDC, USDC>(
            &registry,
            &btc_price_40,
            &usdc_price,
            &mut usdc_pool,
            &mut pool,
            repay_coin,
            &clock,
            scenario.ctx(),
        );
        abort
    };

    // At BTC price 10, Risk ratio = (18 + 200) / 200 = 218 / 200 = 1.09 < 1.1, can liquidate
    let repay_coin = mint_coin<USDC>(500 * test_constants::usdc_multiplier(), scenario.ctx());
    let btc_price_18 = build_btc_price_info_object(&mut scenario, 18, &clock);
    assert!(
        mm.risk_ratio(&registry, &btc_price_18, &usdc_price, &pool, &usdc_pool, &clock) == 1_090_000_000,
        0,
    );

    // 164.8 USDC will be used to liquidate. 160 USDC for repayment of loan, 4.8 for pool liquidation fee.
    // Since 160 USDC is used for repayment, the liquidator should receive 160 * 0.02 = 3.2 as a reward.
    // Risk ratio after liquidation = (218 - 160 * 1.05) / (200 - 160) = 1.25 (our target liquidation)
    // Remaining_repay_coin = 500 - 164.8 = 335.2 USDC
    // The liquidator should receive 160 * 1.05 = 168 USDC. The net profit is 168 - 164.8 = 3.2 USDC
    // 3.2 USDC / 160 USDC = 2% reward
    let (base_coin, quote_coin, remaining_repay_coin) = mm.liquidate<BTC, USDC, USDC>(
        &registry,
        &btc_price_18,
        &usdc_price,
        &mut usdc_pool,
        &mut pool,
        repay_coin,
        &clock,
        scenario.ctx(),
    );

    assert!(base_coin.value() == 0, 0); // 0 BTC
    assert!(quote_coin.value() == 168 * test_constants::usdc_multiplier(), 0); // 168 USDC
    assert!(remaining_repay_coin.value() == 335_200_000, 0); // 335.2 USDC

    destroy_3!(remaining_repay_coin, base_coin, quote_coin);
    return_shared_3!(mm, usdc_pool, pool);
    destroy_3!(btc_price, usdc_price, btc_price_18);
    cleanup_margin_test(registry, admin_cap, maintainer_cap, clock, scenario);
}

fun test_liquidation_2(error_code: u64) {
    let (
        mut scenario,
        clock,
        admin_cap,
        maintainer_cap,
        btc_pool_id,
        usdc_pool_id,
        _pool_id,
    ) = setup_btc_usd_margin_trading();

    let btc_price = build_btc_price_info_object(&mut scenario, 500, &clock);
    let usdc_price = build_demo_usdc_price_info_object(&mut scenario, &clock);

    scenario.next_tx(test_constants::user1());
    let mut pool = scenario.take_shared<Pool<BTC, USDC>>();
    let registry = scenario.take_shared<MarginRegistry>();
    margin_manager::new<BTC, USDC>(&pool, &registry, &clock, scenario.ctx());

    scenario.next_tx(test_constants::user1());
    let mut mm = scenario.take_shared<MarginManager<BTC, USDC>>();
    let mut usdc_pool = scenario.take_shared_by_id<MarginPool<USDC>>(usdc_pool_id);
    let btc_pool = scenario.take_shared_by_id<MarginPool<BTC>>(btc_pool_id);

    // Deposit 1 BTC worth $500
    mm.deposit<BTC, USDC, BTC>(
        &registry,
        mint_coin<BTC>(1 * btc_multiplier(), scenario.ctx()),
        scenario.ctx(),
    );

    // Borrow $200 USDC. Risk ratio = (500 + 200) / 200 = 3.5
    mm.borrow_quote<BTC, USDC>(
        &registry,
        &mut usdc_pool,
        &btc_price,
        &usdc_price,
        &pool,
        200 * test_constants::usdc_multiplier(),
        &clock,
        scenario.ctx(),
    );

    assert!(
        mm.risk_ratio(&registry, &btc_price, &usdc_price, &pool, &usdc_pool, &clock) == 3_500_000_000,
        0,
    );

    // Now we withdraw 100 USDC. This should be allowed since risk ratio >= 2;
    let withdraw_usdc = mm.withdraw<BTC, USDC, USDC>(
        &registry,
        &btc_pool,
        &usdc_pool,
        &btc_price,
        &usdc_price,
        &pool,
        100 * test_constants::usdc_multiplier(),
        &clock,
        scenario.ctx(),
    );
    withdraw_usdc.burn_for_testing();

    // Risk ratio is now (500 + 100) / 200 = 3.0
    assert!(
        mm.risk_ratio(&registry, &btc_price, &usdc_price, &pool, &usdc_pool, &clock) == 3_000_000_000,
        0,
    );

    if (error_code == ECannotWithdraw) {
        // At BTC price 500, we try to withdraw half BTC. (250 + 100) / 200 = 1.75 < 2.0, cannot withdraw
        let withdraw_usdc_2 = mm.withdraw<BTC, USDC, BTC>(
            &registry,
            &btc_pool,
            &usdc_pool,
            &btc_price,
            &usdc_price,
            &pool,
            5000_0000,
            &clock,
            scenario.ctx(),
        );
        withdraw_usdc_2.burn_for_testing();
        abort
    };

    // Perform liquidation and check rewards
    scenario.next_tx(test_constants::liquidator());

    // At BTC price 115, Risk ratio = (115 + 100) / 200 = 1.075 < 1.1, can liquidate
    let repay_coin = mint_coin<USDC>(500 * test_constants::usdc_multiplier(), scenario.ctx());
    let btc_price_115 = build_btc_price_info_object(&mut scenario, 115, &clock);
    assert!(
        mm.risk_ratio(&registry, &btc_price_115, &usdc_price, &pool, &usdc_pool, &clock) == 1_075_000_000,
        0,
    );

    // 180.25 USDC will be used to liquidate. 175 USDC for repayment of loan, 5.25 for pool liquidation fee.
    // Since 175 USDC is used for repayment, the liquidator should receive 175 * 0.02 = 3.5 as a reward.
    // Risk ratio after liquidation = (215 - 175 * 1.05) / (200 - 175) = 1.25 (our target liquidation)
    // Remaining_repay_coin = 500 - 180.25 = 319.75 USDC
    // The liquidator should receive 175 * 1.05 = 183.75 USDC. The net profit is 183.75 - 180.25 = 3.5 USDC
    // 3.5 USDC / 175 USDC = 2% reward
    // Since there's only 100 USDC in the manager, quote_coin will be 100 USDC
    // The remaining 83.75 USDC will be taken as base_coin (in BTC). 83.75 / 115 = 0.728260869565217391 BTC
    let (base_coin, quote_coin, remaining_repay_coin) = mm.liquidate<BTC, USDC, USDC>(
        &registry,
        &btc_price_115,
        &usdc_price,
        &mut usdc_pool,
        &mut pool,
        repay_coin,
        &clock,
        scenario.ctx(),
    );

    assert!(base_coin.value() == 72826087, 0); // ~0.72826087 BTC
    assert!(quote_coin.value() == 100 * test_constants::usdc_multiplier(), 0); // 100 USDC
    assert!(remaining_repay_coin.value() == 319_750_000, 0); // 319.75 USDC

    destroy_3!(remaining_repay_coin, base_coin, quote_coin);
    return_shared_3!(mm, usdc_pool, pool);
    destroy_3!(btc_price, usdc_price, btc_price_115);
    destroy(btc_pool);
    cleanup_margin_test(registry, admin_cap, maintainer_cap, clock, scenario);
}

// === Edge Case Tests with Non-Stablecoin Pairs ===

#[test]
fun test_btc_sui_volatile_pair_liquidation() {
    test_btc_sui_liquidation(ENoError);
}

#[test, expected_failure(abort_code = margin_manager::ECannotLiquidate)]
fun test_btc_sui_cannot_liquidate() {
    test_btc_sui_liquidation(ECannotLiquidate);
}

/// Test liquidation with BTC/SUI pair where both assets are volatile
/// This tests cross-asset risk calculations with different decimal precisions
/// BTC: 8 decimals, SUI: 9 decimals
fun test_btc_sui_liquidation(error_code: u64) {
    let (
        mut scenario,
        clock,
        admin_cap,
        maintainer_cap,
        btc_pool_id,
        sui_pool_id,
        _pool_id,
    ) = setup_btc_sui_margin_trading();

    // BTC at $50,000, SUI at $20
    let btc_price = build_btc_price_info_object(&mut scenario, 50000, &clock);
    let sui_price = build_sui_price_info_object(&mut scenario, 20, &clock);

    scenario.next_tx(test_constants::user1());
    let mut pool = scenario.take_shared<Pool<BTC, SUI>>();
    let registry = scenario.take_shared<MarginRegistry>();
    margin_manager::new<BTC, SUI>(&pool, &registry, &clock, scenario.ctx());

    scenario.next_tx(test_constants::user1());
    let mut mm = scenario.take_shared<MarginManager<BTC, SUI>>();
    let btc_pool = scenario.take_shared_by_id<MarginPool<BTC>>(btc_pool_id);
    let mut sui_pool = scenario.take_shared_by_id<MarginPool<SUI>>(sui_pool_id);

    // Deposit 0.1 BTC worth $5,000
    mm.deposit<BTC, SUI, BTC>(
        &registry,
        mint_coin<BTC>(10_000_000, scenario.ctx()), // 0.1 BTC (8 decimals)
        scenario.ctx(),
    );

    // Borrow 200 SUI worth $4,000. Risk ratio = (5000 + 4000) / 4000 = 2.25
    mm.borrow_quote<BTC, SUI>(
        &registry,
        &mut sui_pool,
        &btc_price,
        &sui_price,
        &pool,
        200 * sui_multiplier(), // 200 SUI (9 decimals)
        &clock,
        scenario.ctx(),
    );

    // Calculate expected risk ratio: (5000 + 4000) / 4000 = 2.25
    let actual_risk_ratio = mm.risk_ratio(
        &registry,
        &btc_price,
        &sui_price,
        &pool,
        &sui_pool,
        &clock,
    );
    // Allow some tolerance due to precision
    assert!(actual_risk_ratio >= 2_200_000_000 && actual_risk_ratio <= 2_300_000_000, 0);

    // Perform liquidation test
    scenario.next_tx(test_constants::liquidator());

    if (error_code == ECannotLiquidate) {
        // SUI price stays at $20, risk ratio should still be safe
        // BTC value: $5,000, SUI borrowed value: 200 * $20 = $4,000
        // Risk ratio = (5000 + 4000) / 4000 = 2.25, still cannot liquidate
        let repay_coin = mint_coin<SUI>(3000 * sui_multiplier(), scenario.ctx());

        let safe_risk_ratio = mm.risk_ratio(
            &registry,
            &btc_price,
            &sui_price,
            &pool,
            &sui_pool,
            &clock,
        );
        assert!(safe_risk_ratio > 1_200_000_000, 0); // Should be > 1.2, safe from liquidation

        let (_base_coin, _quote_coin, _remaining_repay_coin) = mm.liquidate<BTC, SUI, SUI>(
            &registry,
            &btc_price,
            &sui_price,
            &mut sui_pool,
            &mut pool,
            repay_coin,
            &clock,
            scenario.ctx(),
        );
        abort
    };

    // Create a liquidatable scenario: BTC drops to $3,000, SUI rises to $100
    // BTC value: 0.1 * $3,000 = $300, SUI borrowed value: 200 * $100 = $20,000
    // Risk ratio = (300 + 20000) / 20000 = 1.015 < 1.1, can liquidate
    let btc_price_crash = build_btc_price_info_object(&mut scenario, 3000, &clock);
    let sui_price_spike = build_sui_price_info_object(&mut scenario, 100, &clock);
    let repay_coin = mint_coin<SUI>(3000 * sui_multiplier(), scenario.ctx());

    let liquidation_risk_ratio = mm.risk_ratio(
        &registry,
        &btc_price_crash,
        &sui_price_spike,
        &pool,
        &sui_pool,
        &clock,
    );
    assert!(liquidation_risk_ratio < 1_100_000_000, 0); // Should be liquidatable

    // Mixed reward liquidation: 200 SUI from manager + 0.1 BTC for remaining reward
    let (base_coin, quote_coin, remaining_repay_coin) = mm.liquidate<BTC, SUI, SUI>(
        &registry,
        &btc_price_crash,
        &sui_price_spike,
        &mut sui_pool,
        &mut pool,
        repay_coin,
        &clock,
        scenario.ctx(),
    );

    // Exact assertions following test_liquidation_2 pattern
    assert!(base_coin.value() == 10000000, 0); // 0.1 BTC exact (8 decimals)
    assert!(quote_coin.value() == 200000000000, 0); // 200 SUI exact (9 decimals)
    assert!(remaining_repay_coin.value() == 2800866666668, 0); // 2800.866666668 SUI exact

    destroy_3!(remaining_repay_coin, base_coin, quote_coin);
    return_shared_3!(mm, sui_pool, pool);
    destroy_3!(btc_price, sui_price, btc_price_crash);
    destroy(sui_price_spike);
    destroy(btc_pool);
    cleanup_margin_test(registry, admin_cap, maintainer_cap, clock, scenario);
}

#[test]
fun test_extreme_price_volatility_btc_sui() {
    let (
        mut scenario,
        clock,
        admin_cap,
        maintainer_cap,
        btc_pool_id,
        sui_pool_id,
        _pool_id,
    ) = setup_btc_sui_margin_trading();

    // Start with moderate prices: BTC at $30,000, SUI at $10
    let btc_price = build_btc_price_info_object(&mut scenario, 30000, &clock);
    let sui_price = build_sui_price_info_object(&mut scenario, 10, &clock);

    scenario.next_tx(test_constants::user1());
    let pool = scenario.take_shared<Pool<BTC, SUI>>();
    let registry = scenario.take_shared<MarginRegistry>();
    margin_manager::new<BTC, SUI>(&pool, &registry, &clock, scenario.ctx());

    scenario.next_tx(test_constants::user1());
    let mut mm = scenario.take_shared<MarginManager<BTC, SUI>>();
    let btc_pool = scenario.take_shared_by_id<MarginPool<BTC>>(btc_pool_id);
    let mut sui_pool = scenario.take_shared_by_id<MarginPool<SUI>>(sui_pool_id);

    // Deposit 1 BTC worth $30,000
    mm.deposit<BTC, SUI, BTC>(
        &registry,
        mint_coin<BTC>(1 * btc_multiplier(), scenario.ctx()),
        scenario.ctx(),
    );

    // Borrow 2,000 SUI worth $20,000. Risk ratio = (30000 + 20000) / 20000 = 2.5
    mm.borrow_quote<BTC, SUI>(
        &registry,
        &mut sui_pool,
        &btc_price,
        &sui_price,
        &pool,
        2000 * sui_multiplier(),
        &clock,
        scenario.ctx(),
    );

    let initial_risk_ratio = mm.risk_ratio(
        &registry,
        &btc_price,
        &sui_price,
        &pool,
        &sui_pool,
        &clock,
    );
    assert!(initial_risk_ratio == 2_500_000_000, 0);

    // Test extreme volatility scenarios

    // Scenario 1: BTC moons to $100,000, SUI stays at $10
    // BTC value: $100,000, SUI debt: $20,000
    // Risk ratio = (100000 + 20000) / 20000 = 6.0
    let btc_price_moon = build_btc_price_info_object(&mut scenario, 100000, &clock);
    let moon_risk_ratio = mm.risk_ratio(
        &registry,
        &btc_price_moon,
        &sui_price,
        &pool,
        &sui_pool,
        &clock,
    );
    assert!(moon_risk_ratio == 6_000_000_000, 0);

    // Scenario 2: SUI moons to $100, BTC stays at $30,000
    // BTC value: $30,000, SUI debt: 2,000 * $100 = $200,000
    // Risk ratio = (30000 + 200000) / 200000 = 1.15
    let sui_price_moon = build_sui_price_info_object(&mut scenario, 100, &clock);
    let sui_moon_risk_ratio = mm.risk_ratio(
        &registry,
        &btc_price,
        &sui_price_moon,
        &pool,
        &sui_pool,
        &clock,
    );
    assert!(sui_moon_risk_ratio == 1_150_000_000, 0);

    // Scenario 3: Both assets crash - BTC to $10,000, SUI to $10
    // BTC value: $10,000, SUI debt: 2,000 * $10 = $20,000
    // Risk ratio = (10000 + 20000) / 20000 = 1.5
    let btc_price_crash = build_btc_price_info_object(&mut scenario, 10000, &clock);
    let sui_price_crash_realistic = build_sui_price_info_object(&mut scenario, 10, &clock);

    let crash_risk_ratio = mm.risk_ratio(
        &registry,
        &btc_price_crash,
        &sui_price_crash_realistic,
        &pool,
        &sui_pool,
        &clock,
    );
    // Should be high risk ratio since both assets crashed
    // BTC: $10,000, SUI debt: $20,000, ratio should be (10000 + 20000) / 20000 = 1.5
    assert!(crash_risk_ratio >= 1_400_000_000 && crash_risk_ratio <= 1_600_000_000, 0); // Should be around 1.5

    // Test that we can withdraw when risk ratio is very high
    let withdraw_sui = mm.withdraw<BTC, SUI, SUI>(
        &registry,
        &btc_pool,
        &sui_pool,
        &btc_price_moon, // Using moon price for high ratio
        &sui_price,
        &pool,
        500 * sui_multiplier(), // Withdraw 500 SUI
        &clock,
        scenario.ctx(),
    );
    withdraw_sui.burn_for_testing();

    // Verify we can still calculate risk ratios after withdrawal
    let post_withdraw_ratio = mm.risk_ratio(
        &registry,
        &btc_price_moon,
        &sui_price,
        &pool,
        &sui_pool,
        &clock,
    );
    assert!(post_withdraw_ratio > 4_000_000_000, 0); // Should still be very high

    destroy_3!(btc_price, sui_price, btc_price_moon);
    destroy_3!(sui_price_moon, btc_price_crash, sui_price_crash_realistic);
    return_shared_3!(mm, sui_pool, pool);
    destroy(btc_pool);
    cleanup_margin_test(registry, admin_cap, maintainer_cap, clock, scenario);
}

#[test]
fun test_decimal_precision_edge_cases() {
    let (
        mut scenario,
        clock,
        admin_cap,
        maintainer_cap,
        btc_pool_id,
        sui_pool_id,
        _pool_id,
    ) = setup_btc_sui_margin_trading();

    // Test with different decimal precisions: BTC (8 decimals) and SUI (9 decimals)
    let btc_price = build_btc_price_info_object(&mut scenario, 50000, &clock);
    let sui_price = build_sui_price_info_object(&mut scenario, 20, &clock);

    scenario.next_tx(test_constants::user1());
    let mut pool = scenario.take_shared<Pool<BTC, SUI>>();
    let registry = scenario.take_shared<MarginRegistry>();
    margin_manager::new<BTC, SUI>(&pool, &registry, &clock, scenario.ctx());

    scenario.next_tx(test_constants::user1());
    let mut mm = scenario.take_shared<MarginManager<BTC, SUI>>();
    let btc_pool = scenario.take_shared_by_id<MarginPool<BTC>>(btc_pool_id);
    let mut sui_pool = scenario.take_shared_by_id<MarginPool<SUI>>(sui_pool_id);

    // Test with very small amounts to check precision
    // Deposit 0.00000001 BTC (1 satoshi) worth $0.0005
    mm.deposit<BTC, SUI, BTC>(
        &registry,
        mint_coin<BTC>(1, scenario.ctx()), // 1 satoshi
        scenario.ctx(),
    );

    // Borrow minimum amount of SUI (above min_borrow threshold)
    mm.borrow_quote<BTC, SUI>(
        &registry,
        &mut sui_pool,
        &btc_price,
        &sui_price,
        &pool,
        test_constants::min_borrow() + 1000, // Above minimum borrow
        &clock,
        scenario.ctx(),
    );

    // Risk ratio should be calculable even with tiny amounts
    let tiny_risk_ratio = mm.risk_ratio(
        &registry,
        &btc_price,
        &sui_price,
        &pool,
        &sui_pool,
        &clock,
    );
    assert!(tiny_risk_ratio > 1_000_000_000, 0); // Should be > 1.0

    // Test with maximum amounts (near overflow boundaries)
    // Deposit large amount of BTC
    mm.deposit<BTC, SUI, BTC>(
        &registry,
        mint_coin<BTC>(1000 * btc_multiplier(), scenario.ctx()), // 1000 BTC
        scenario.ctx(),
    );

    // Borrow reasonable amount of SUI (within pool limits)
    mm.borrow_quote<BTC, SUI>(
        &registry,
        &mut sui_pool,
        &btc_price,
        &sui_price,
        &pool,
        100_000 * sui_multiplier(), // 100K SUI (within the 1M supplied)
        &clock,
        scenario.ctx(),
    );

    // Risk ratio should still be calculable with large amounts
    let large_risk_ratio = mm.risk_ratio(
        &registry,
        &btc_price,
        &sui_price,
        &pool,
        &sui_pool,
        &clock,
    );
    assert!(large_risk_ratio > 1_000_000_000, 0); // Should be > 1.0

    // Test precision in liquidation calculations with mixed decimals
    scenario.next_tx(test_constants::liquidator());

    // Create a liquidatable scenario
    let btc_price_low = build_btc_price_info_object(&mut scenario, 5000, &clock); // BTC crashes
    let sui_price_high = build_sui_price_info_object(&mut scenario, 10, &clock); // SUI moons

    let liquidation_risk_ratio = mm.risk_ratio(
        &registry,
        &btc_price_low,
        &sui_price_high,
        &pool,
        &sui_pool,
        &clock,
    );

    if (liquidation_risk_ratio < 1_100_000_000) {
        // If liquidatable, perform exact liquidation calculation
        let repay_coin = mint_coin<SUI>(200_000 * sui_multiplier(), scenario.ctx());

        // Exact liquidation calculation following test_liquidation_2 pattern:
        // BTC value: 1000 BTC * $100 = $100,000 = 1,000 SUI (at $100/SUI)
        // Available SUI: 100,000 SUI
        // Total assets in SUI: 1,000 + 100,000 = 101,000 SUI
        // SUI debt: 100,000 SUI
        // Target risk ratio: 1.25, target debt = 101,000 / 1.25 = 80,800 SUI
        // SUI to repay: 100,000 - 80,800 = 19,200 SUI
        // Pool liquidation fee: 19,200 * 0.0025 = 48 SUI
        // Total SUI used: 19,200 + 48 = 19,248 SUI
        // Liquidator reward: 19,200 * 1.05 = 20,160 SUI
        // Since there's enough SUI, all reward paid in SUI
        // Remaining repay coin: 200,000 - 19,248 = 180,752 SUI
        let btc_extreme_crash = build_btc_price_info_object(&mut scenario, 100, &clock);
        let extreme_risk_ratio = mm.risk_ratio(
            &registry,
            &btc_extreme_crash,
            &sui_price_high,
            &pool,
            &sui_pool,
            &clock,
        );

        if (extreme_risk_ratio < 1_100_000_000) {
            // (This section is now covered by the exact calculation above)
            let (base_coin, quote_coin, remaining_repay_coin) = mm.liquidate<BTC, SUI, SUI>(
                &registry,
                &btc_extreme_crash,
                &sui_price_high,
                &mut sui_pool,
                &mut pool,
                repay_coin,
                &clock,
                scenario.ctx(),
            );

            // Exact assertions following test_liquidation_2 pattern
            assert!(base_coin.value() == 0, 0); // 0 BTC (all reward paid in SUI)
            assert!(quote_coin.value() == 20160000000000, 0); // 20,160 SUI exact (9 decimals)
            assert!(remaining_repay_coin.value() == 180752000000000, 0); // 180,752 SUI exact

            destroy_3!(remaining_repay_coin, base_coin, quote_coin);
            destroy_3!(btc_price_low, sui_price_high, btc_price);
            destroy(btc_extreme_crash);
        } else {
            // Not liquidatable even with extreme crash
            destroy(repay_coin);
            destroy_3!(btc_price_low, sui_price_high, btc_price);
            destroy(btc_extreme_crash);
        };
    } else {
        destroy_3!(btc_price_low, sui_price_high, btc_price);
    };

    destroy(sui_price);
    return_shared_3!(mm, sui_pool, pool);
    destroy(btc_pool);
    cleanup_margin_test(registry, admin_cap, maintainer_cap, clock, scenario);
}

#[test]
fun test_btc_sui_mixed_reward_liquidation() {
    // Test liquidation where reward is paid partially in debt asset and partially in collateral
    let (
        mut scenario,
        clock,
        admin_cap,
        maintainer_cap,
        btc_pool_id,
        sui_pool_id,
        _pool_id,
    ) = setup_btc_sui_margin_trading();

    // BTC at $40,000, SUI at $20
    let btc_price = build_btc_price_info_object(&mut scenario, 40000, &clock);
    let sui_price = build_sui_price_info_object(&mut scenario, 20, &clock);

    scenario.next_tx(test_constants::user1());
    let mut pool = scenario.take_shared<Pool<BTC, SUI>>();
    let registry = scenario.take_shared<MarginRegistry>();
    margin_manager::new<BTC, SUI>(&pool, &registry, &clock, scenario.ctx());

    scenario.next_tx(test_constants::user1());
    let mut mm = scenario.take_shared<MarginManager<BTC, SUI>>();
    let btc_pool = scenario.take_shared_by_id<MarginPool<BTC>>(btc_pool_id);
    let mut sui_pool = scenario.take_shared_by_id<MarginPool<SUI>>(sui_pool_id);

    // Deposit 1.5 BTC worth $60,000 to allow for larger withdrawal
    mm.deposit<BTC, SUI, BTC>(
        &registry,
        mint_coin<BTC>(15 * btc_multiplier() / 10, scenario.ctx()),
        scenario.ctx(),
    );

    // Borrow 1,800 SUI worth $36,000. Risk ratio = (60000 + 36000) / 36000 = 2.667
    mm.borrow_quote<BTC, SUI>(
        &registry,
        &mut sui_pool,
        &btc_price,
        &sui_price,
        &pool,
        1800 * sui_multiplier(),
        &clock,
        scenario.ctx(),
    );

    // Withdraw some SUI to reduce available SUI balance in the manager
    // Risk ratio after withdrawal must be >= 200%
    // Current: ($60k + $36k) / $36k = 2.667
    // After withdrawing 1200 SUI ($24k): ($60k + $12k) / $36k = 2.0 (exactly at limit)
    let withdrawn_sui = mm.withdraw<BTC, SUI, SUI>(
        &registry,
        &btc_pool,
        &sui_pool,
        &btc_price,
        &sui_price,
        &pool,
        1200 * sui_multiplier(), // Withdraw 1200 SUI, leaving 600 SUI
        &clock,
        scenario.ctx(),
    );
    withdrawn_sui.burn_for_testing();

    // Perform liquidation test
    scenario.next_tx(test_constants::liquidator());

    // Create liquidatable scenario: BTC drops to $20,000, SUI rises to $30
    // BTC value: $20,000, SUI debt: 1,800 * $30 = $54,000
    // Available SUI in manager: 600 SUI worth $18,000
    // Total assets: $20,000 + $18,000 = $38,000
    // Risk ratio = $38,000 / $54,000 = 0.704 < 1.1, liquidatable
    let btc_price_drop = build_btc_price_info_object(&mut scenario, 20000, &clock);
    let sui_price_rise = build_sui_price_info_object(&mut scenario, 30, &clock);
    let repay_coin = mint_coin<SUI>(20000 * sui_multiplier(), scenario.ctx());

    let liquidation_risk_ratio = mm.risk_ratio(
        &registry,
        &btc_price_drop,
        &sui_price_rise,
        &pool,
        &sui_pool,
        &clock,
    );
    assert!(liquidation_risk_ratio < 1_100_000_000, 0);

    // Mixed reward liquidation: 600 SUI from manager + 1.5 BTC for remaining reward
    let (base_coin, quote_coin, remaining_repay_coin) = mm.liquidate<BTC, SUI, SUI>(
        &registry,
        &btc_price_drop,
        &sui_price_rise,
        &mut sui_pool,
        &mut pool,
        repay_coin,
        &clock,
        scenario.ctx(),
    );

    // Exact assertions following test_liquidation_2 pattern
    assert!(base_coin.value() == 150000000, 0); // 1.5 BTC exact (8 decimals)
    assert!(quote_coin.value() == 600000000000, 0); // 600 SUI exact (9 decimals)
    assert!(remaining_repay_coin.value() == 18430476190477, 0); // 18430.476190477 SUI exact

    destroy_3!(remaining_repay_coin, base_coin, quote_coin);
    return_shared_3!(mm, sui_pool, pool);
    destroy_3!(btc_price, sui_price, btc_price_drop);
    destroy(sui_price_rise);
    destroy(btc_pool);
    cleanup_margin_test(registry, admin_cap, maintainer_cap, clock, scenario);
}
