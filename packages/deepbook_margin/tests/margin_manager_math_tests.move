// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module deepbook_margin::margin_manager_math_tests;

use deepbook::{pool::Pool, registry::Registry};
use deepbook_margin::{
    margin_manager::{Self, MarginManager},
    margin_pool::MarginPool,
    margin_registry::MarginRegistry,
    test_constants::{Self, USDC, BTC, SUI, btc_multiplier, sui_multiplier, usdc_multiplier},
    test_helpers::{
        cleanup_margin_test,
        mint_coin,
        build_demo_usdc_price_info_object,
        build_btc_price_info_object,
        build_sui_price_info_object,
        setup_btc_usd_deepbook_margin,
        setup_btc_sui_deepbook_margin,
        destroy_3,
        return_shared_3,
        return_shared_4
    }
};
use std::unit_test::destroy;
use sui::test_scenario::return_shared;

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
fun test_liquidation_quote_debt_ok() {
    test_liquidation_quote_debt(ENoError);
}

#[test, expected_failure(abort_code = margin_manager::EWithdrawRiskRatioExceeded)]
fun test_liquidation_cannot_withdraw() {
    test_liquidation_quote_debt(ECannotWithdraw);
}

#[test]
fun test_liquidation_quote_debt_partial_ok() {
    test_liquidation_quote_debt_partial();
}

#[test]
fun test_liquidation_base_debt_default_ok() {
    test_liquidation_base_debt_default();
}

#[test]
fun test_liquidation_base_debt_ok() {
    test_liquidation_base_debt();
}

#[test]
fun test_btc_sui_volatile_pair_ok() {
    test_btc_sui_liquidation(ENoError);
}

#[test, expected_failure(abort_code = margin_manager::ECannotLiquidate)]
fun test_btc_sui_cannot_liquidate() {
    test_btc_sui_liquidation(ECannotLiquidate);
}

fun test_liquidation(error_code: u64) {
    let (
        mut scenario,
        clock,
        admin_cap,
        maintainer_cap,
        btc_pool_id,
        usdc_pool_id,
        _pool_id,
        registry_id,
    ) = setup_btc_usd_deepbook_margin();

    let btc_price = build_btc_price_info_object(&mut scenario, 50, &clock);
    let usdc_price = build_demo_usdc_price_info_object(&mut scenario, &clock);

    scenario.next_tx(test_constants::user1());
    let mut pool = scenario.take_shared<Pool<BTC, USDC>>();
    let mut registry = scenario.take_shared<MarginRegistry>();
    let deepbook_registry = scenario.take_shared_by_id<Registry>(registry_id);
    margin_manager::new<BTC, USDC>(
        &pool,
        &deepbook_registry,
        &mut registry,
        &clock,
        scenario.ctx(),
    );
    return_shared(deepbook_registry);

    scenario.next_tx(test_constants::user1());
    let mut mm = scenario.take_shared<MarginManager<BTC, USDC>>();
    let mut usdc_pool = scenario.take_shared_by_id<MarginPool<USDC>>(usdc_pool_id);
    let btc_pool = scenario.take_shared_by_id<MarginPool<BTC>>(btc_pool_id);

    // Deposit 1 BTC worth $50
    mm.deposit<BTC, USDC, BTC>(
        &registry,
        &btc_price,
        &usdc_price,
        mint_coin<BTC>(1 * btc_multiplier(), scenario.ctx()),
        &clock,
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
        mm.risk_ratio(&registry, &btc_price, &usdc_price, &pool, &btc_pool,&usdc_pool, &clock) == 1_250_000_000,
        0,
    );

    // Perform liquidation and check rewards
    scenario.next_tx(test_constants::liquidator());

    if (error_code == ECannotLiquidate) {
        // At BTC price 40, Risk ratio = (40 + 200) / 200 = 1.2, still cannot liquidate
        let repay_coin = mint_coin<USDC>(500 * test_constants::usdc_multiplier(), scenario.ctx());
        let btc_price_40 = build_btc_price_info_object(&mut scenario, 40, &clock);
        assert!(
            mm.risk_ratio(&registry, &btc_price_40, &usdc_price, &pool, &btc_pool, &usdc_pool, &clock) == 1_200_000_000,
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
        mm.risk_ratio(&registry, &btc_price_18, &usdc_price, &pool, &btc_pool, &usdc_pool, &clock) == 1_090_000_000,
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

    assert!(base_coin.value() == 0); // 0 BTC
    assert!(quote_coin.value() == 168 * test_constants::usdc_multiplier()); // 168 USDC
    assert!(remaining_repay_coin.value() == 335_200_000); // 335.2 USDC

    destroy_3!(remaining_repay_coin, base_coin, quote_coin);
    return_shared_4!(mm, usdc_pool, pool, btc_pool);
    destroy_3!(btc_price, usdc_price, btc_price_18);
    cleanup_margin_test(registry, admin_cap, maintainer_cap, clock, scenario);
}

fun test_liquidation_quote_debt(error_code: u64) {
    let (
        mut scenario,
        clock,
        admin_cap,
        maintainer_cap,
        btc_pool_id,
        usdc_pool_id,
        _pool_id,
        registry_id,
    ) = setup_btc_usd_deepbook_margin();

    scenario.next_tx(test_constants::user1());
    let mut pool = scenario.take_shared<Pool<BTC, USDC>>();
    let mut registry = scenario.take_shared<MarginRegistry>();
    let deepbook_registry = scenario.take_shared_by_id<Registry>(registry_id);
    margin_manager::new<BTC, USDC>(
        &pool,
        &deepbook_registry,
        &mut registry,
        &clock,
        scenario.ctx(),
    );
    return_shared(deepbook_registry);

    scenario.next_tx(test_constants::user1());
    let mut mm = scenario.take_shared<MarginManager<BTC, USDC>>();
    let mut usdc_pool = scenario.take_shared_by_id<MarginPool<USDC>>(usdc_pool_id);
    let btc_pool = scenario.take_shared_by_id<MarginPool<BTC>>(btc_pool_id);
    let btc_price = build_btc_price_info_object(&mut scenario, 500, &clock);
    let usdc_price = build_demo_usdc_price_info_object(&mut scenario, &clock);

    // Deposit 1 BTC worth $500
    mm.deposit<BTC, USDC, BTC>(
        &registry,
        &btc_price,
        &usdc_price,
        mint_coin<BTC>(1 * btc_multiplier(), scenario.ctx()),
        &clock,
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
        mm.risk_ratio(&registry, &btc_price, &usdc_price, &pool, &btc_pool, &usdc_pool, &clock) == 3_500_000_000,
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
        mm.risk_ratio(&registry, &btc_price, &usdc_price, &pool, &btc_pool, &usdc_pool, &clock) == 3_000_000_000,
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
        mm.risk_ratio(&registry, &btc_price_115, &usdc_price, &pool, &btc_pool, &usdc_pool, &clock) == 1_075_000_000,
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

    assert!(base_coin.value() == 72826087); // ~0.72826087 BTC
    assert!(quote_coin.value() == 100 * test_constants::usdc_multiplier()); // 100 USDC
    assert!(remaining_repay_coin.value() == 319_750_000); // 319.75 USDC

    destroy_3!(remaining_repay_coin, base_coin, quote_coin);
    return_shared_3!(mm, usdc_pool, pool);
    destroy_3!(btc_price, usdc_price, btc_price_115);
    destroy(btc_pool);
    cleanup_margin_test(registry, admin_cap, maintainer_cap, clock, scenario);
}

fun test_liquidation_quote_debt_partial() {
    let (
        mut scenario,
        clock,
        admin_cap,
        maintainer_cap,
        btc_pool_id,
        usdc_pool_id,
        _pool_id,
        registry_id,
    ) = setup_btc_usd_deepbook_margin();

    scenario.next_tx(test_constants::user1());
    let mut pool = scenario.take_shared<Pool<BTC, USDC>>();
    let mut registry = scenario.take_shared<MarginRegistry>();
    let deepbook_registry = scenario.take_shared_by_id<Registry>(registry_id);
    margin_manager::new<BTC, USDC>(
        &pool,
        &deepbook_registry,
        &mut registry,
        &clock,
        scenario.ctx(),
    );
    return_shared(deepbook_registry);

    scenario.next_tx(test_constants::user1());
    let mut mm = scenario.take_shared<MarginManager<BTC, USDC>>();
    let mut usdc_pool = scenario.take_shared_by_id<MarginPool<USDC>>(usdc_pool_id);
    let btc_pool = scenario.take_shared_by_id<MarginPool<BTC>>(btc_pool_id);
    let btc_price = build_btc_price_info_object(&mut scenario, 500, &clock);
    let usdc_price = build_demo_usdc_price_info_object(&mut scenario, &clock);

    // Deposit 1 BTC worth $500
    mm.deposit<BTC, USDC, BTC>(
        &registry,
        &btc_price,
        &usdc_price,
        mint_coin<BTC>(1 * btc_multiplier(), scenario.ctx()),
        &clock,
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
        mm.risk_ratio(&registry, &btc_price, &usdc_price, &pool, &btc_pool, &usdc_pool, &clock) == 3_500_000_000,
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
        mm.risk_ratio(&registry, &btc_price, &usdc_price, &pool, &btc_pool, &usdc_pool, &clock) == 3_000_000_000,
        0,
    );

    // Perform liquidation and check rewards
    scenario.next_tx(test_constants::liquidator());

    // At BTC price 115, Risk ratio = (115 + 100) / 200 = 1.075 < 1.1, can liquidate
    let repay_coin = mint_coin<USDC>(90_125_000, scenario.ctx());
    let btc_price_115 = build_btc_price_info_object(&mut scenario, 115, &clock);
    assert!(
        mm.risk_ratio(&registry, &btc_price_115, &usdc_price, &pool, &btc_pool, &usdc_pool, &clock) == 1_075_000_000,
        0,
    );

    // 90.125 USDC will be used to liquidate. 87.5 USDC for repayment of loan, 2.625 for pool liquidation fee.
    // Since 87.5 USDC is used for repayment, the liquidator should receive 87.5 * 0.02 = 1.75 as a reward.
    // Risk ratio after liquidation = (215 - 87.5 * 1.05) / (200 - 87.5) = 1.094 (not at target since this is a partial liquidation)
    // Remaining_repay_coin = 0 USDC
    // The liquidator should receive 87.5 * 1.05 = 91.875 USDC. The net profit is 91.875 - 90.125 = 1.75 USDC
    // 1.75 USDC / 87.5 USDC = 2% reward
    // Since there's 100 USDC in the manager, only USDC will be paid out
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

    assert!(base_coin.value() == 0); // 0 BTC
    assert!(quote_coin.value() == 91_875_000); // 91.875 USDC
    assert!(remaining_repay_coin.value() == 0); // 0 USDC
    destroy_3!(remaining_repay_coin, base_coin, quote_coin);

    // Since risk ratio still < 1.1, can liquidate again
    let repay_coin = mint_coin<USDC>(90_125_000, scenario.ctx());
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

    assert!(base_coin.value() == 72826087); // ~0.72826087 BTC
    assert!(quote_coin.value() == 8_125_000); // 8.125 USDC
    assert!(remaining_repay_coin.value() == 0); // 0 USDC

    destroy_3!(remaining_repay_coin, base_coin, quote_coin);
    return_shared_3!(mm, usdc_pool, pool);
    destroy_3!(btc_price, usdc_price, btc_price_115);
    destroy(btc_pool);
    cleanup_margin_test(registry, admin_cap, maintainer_cap, clock, scenario);
}

fun test_liquidation_base_debt_default() {
    let (
        mut scenario,
        clock,
        admin_cap,
        maintainer_cap,
        btc_pool_id,
        usdc_pool_id,
        _pool_id,
        registry_id,
    ) = setup_btc_usd_deepbook_margin();

    let btc_price = build_btc_price_info_object(&mut scenario, 500, &clock);
    let usdc_price = build_demo_usdc_price_info_object(&mut scenario, &clock);

    scenario.next_tx(test_constants::user1());
    let mut pool = scenario.take_shared<Pool<BTC, USDC>>();
    let mut registry = scenario.take_shared<MarginRegistry>();
    let deepbook_registry = scenario.take_shared_by_id<Registry>(registry_id);
    margin_manager::new<BTC, USDC>(
        &pool,
        &deepbook_registry,
        &mut registry,
        &clock,
        scenario.ctx(),
    );
    return_shared(deepbook_registry);

    scenario.next_tx(test_constants::user1());
    let mut mm = scenario.take_shared<MarginManager<BTC, USDC>>();
    let usdc_pool = scenario.take_shared_by_id<MarginPool<USDC>>(usdc_pool_id);
    let mut btc_pool = scenario.take_shared_by_id<MarginPool<BTC>>(btc_pool_id);

    // Deposit 500 USDC
    mm.deposit<BTC, USDC, USDC>(
        &registry,
        &btc_price,
        &usdc_price,
        mint_coin<USDC>(500 * usdc_multiplier(), scenario.ctx()),
        &clock,
        scenario.ctx(),
    );

    // Borrow $200 BTC (0.4 BTC). Risk ratio = (500 + 200) / 200 = 3.5
    mm.borrow_base<BTC, USDC>(
        &registry,
        &mut btc_pool,
        &btc_price,
        &usdc_price,
        &pool,
        40000000,
        &clock,
        scenario.ctx(),
    );

    assert!(
        mm.risk_ratio(&registry, &btc_price, &usdc_price, &pool, &btc_pool, &usdc_pool, &clock) == 3_500_000_000,
        0,
    );

    // Now we withdraw 0.2 BTC. This should be allowed since risk ratio >= 2;
    let withdraw_btc = mm.withdraw<BTC, USDC, BTC>(
        &registry,
        &btc_pool,
        &usdc_pool,
        &btc_price,
        &usdc_price,
        &pool,
        20000000,
        &clock,
        scenario.ctx(),
    );
    withdraw_btc.burn_for_testing();

    // Risk ratio is now (500 + 100) / 200 = 3.0
    assert!(
        mm.risk_ratio(&registry, &btc_price, &usdc_price, &pool, &btc_pool, &usdc_pool, &clock) == 3_000_000_000,
        0,
    );

    // Perform liquidation and check rewards
    scenario.next_tx(test_constants::liquidator());

    // We now have 0.2 BTC ($100) and 500 USDC ($500), with a debt of 0.4 BTC ($200)
    // At BTC price 3000, Risk ratio = (600 + 500) / 1200 = 0.916666666666666666 < 1.1, can liquidate
    let repay_coin = mint_coin<BTC>(1 * btc_multiplier(), scenario.ctx());
    let btc_price_3000 = build_btc_price_info_object(&mut scenario, 3000, &clock);

    // 0.3597 BTC will be used to liquidate. 0.3492 BTC for repayment of loan, 0.0105 BTC for pool liquidation fee.
    // Since 0.3492 BTC is used for repayment, the liquidator should receive 0.3492 * 0.02 = 0.006984 as a reward.
    // There should be a full liquidation of the margin manager since it's in default.
    // Remaining_repay_coin = 1 - 0.3597 = 0.6403 BTC
    // The liquidator should receive 0.3492 * 1.05 = 0.36666 BTC = 1100 USD. The net profit is 0.36666 - 0.3597 = 0.00696 BTC
    // 0.00696 BTC / 0.3492 BTC = 2% reward
    // The 0.2 BTC will be used first. 1100 - 0.2 * 3000 = 500 USD. Then the remaining 500 USD will be taken as USDC.
    let (base_coin, quote_coin, remaining_repay_coin) = mm.liquidate<BTC, USDC, BTC>(
        &registry,
        &btc_price_3000,
        &usdc_price,
        &mut btc_pool,
        &mut pool,
        repay_coin,
        &clock,
        scenario.ctx(),
    );

    assert!(base_coin.value() == 20000000); // 0.2 BTC
    assert!(quote_coin.value() == 499999980); // ~500 USDC. Rounding is due to conversion of BTC to USDC.
    assert!(remaining_repay_coin.value() == 64031746); // 0.6403 BTC

    // The loans should be defaulted
    assert!(mm.borrowed_base_shares() == 0); // 0 BTC
    assert!(mm.borrowed_quote_shares() == 0); // 0 USDC

    destroy_3!(remaining_repay_coin, base_coin, quote_coin);
    return_shared_3!(mm, usdc_pool, pool);
    destroy_3!(btc_price, usdc_price, btc_price_3000);
    destroy(btc_pool);
    cleanup_margin_test(registry, admin_cap, maintainer_cap, clock, scenario);
}

fun test_liquidation_base_debt() {
    let (
        mut scenario,
        clock,
        admin_cap,
        maintainer_cap,
        btc_pool_id,
        usdc_pool_id,
        _pool_id,
        registry_id,
    ) = setup_btc_usd_deepbook_margin();

    let btc_price = build_btc_price_info_object(&mut scenario, 500, &clock);
    let usdc_price = build_demo_usdc_price_info_object(&mut scenario, &clock);

    scenario.next_tx(test_constants::user1());
    let mut pool = scenario.take_shared<Pool<BTC, USDC>>();
    let mut registry = scenario.take_shared<MarginRegistry>();
    let deepbook_registry = scenario.take_shared_by_id<Registry>(registry_id);
    margin_manager::new<BTC, USDC>(
        &pool,
        &deepbook_registry,
        &mut registry,
        &clock,
        scenario.ctx(),
    );
    return_shared(deepbook_registry);

    scenario.next_tx(test_constants::user1());
    let mut mm = scenario.take_shared<MarginManager<BTC, USDC>>();
    let usdc_pool = scenario.take_shared_by_id<MarginPool<USDC>>(usdc_pool_id);
    let mut btc_pool = scenario.take_shared_by_id<MarginPool<BTC>>(btc_pool_id);

    // Deposit 500 USDC
    mm.deposit<BTC, USDC, USDC>(
        &registry,
        &btc_price,
        &usdc_price,
        mint_coin<USDC>(500 * usdc_multiplier(), scenario.ctx()),
        &clock,
        scenario.ctx(),
    );

    // Borrow $200 BTC (0.4 BTC). Risk ratio = (500 + 200) / 200 = 3.5
    mm.borrow_base<BTC, USDC>(
        &registry,
        &mut btc_pool,
        &btc_price,
        &usdc_price,
        &pool,
        40000000,
        &clock,
        scenario.ctx(),
    );

    assert!(
        mm.risk_ratio(&registry, &btc_price, &usdc_price, &pool, &btc_pool, &usdc_pool, &clock) == 3_500_000_000,
        0,
    );

    // Now we withdraw 0.2 BTC. This should be allowed since risk ratio >= 2;
    let withdraw_btc = mm.withdraw<BTC, USDC, BTC>(
        &registry,
        &btc_pool,
        &usdc_pool,
        &btc_price,
        &usdc_price,
        &pool,
        20000000,
        &clock,
        scenario.ctx(),
    );
    withdraw_btc.burn_for_testing();

    // Risk ratio is now (500 + 100) / 200 = 3.0
    assert!(
        mm.risk_ratio(&registry, &btc_price, &usdc_price, &pool, &btc_pool, &usdc_pool, &clock) == 3_000_000_000,
        0,
    );

    // Perform liquidation and check rewards
    scenario.next_tx(test_constants::liquidator());

    // We now have 0.2 BTC ($440) and 500 USDC ($500), with a debt of 0.4 BTC ($880)
    // At BTC price 2200, Risk ratio = (440 + 500) / 880 = 1.0681818 < 1.1, can liquidate
    let repay_coin = mint_coin<BTC>(1 * btc_multiplier(), scenario.ctx());
    let btc_price_2200 = build_btc_price_info_object(&mut scenario, 2200, &clock);

    assert!(
        mm.risk_ratio(&registry, &btc_price_2200, &usdc_price, &pool, &btc_pool, &usdc_pool, &clock) == 1_068_181_825,
        0,
    );

    // 0.37454 BTC will be used to liquidate. 0.3636 BTC for repayment of loan, 0.01094 BTC for pool liquidation fee.
    // Since 0.3636 BTC is used for repayment, the liquidator should receive 0.3636 * 0.02 = 0.007272 as a reward.
    // Risk ratio after liquidation = (940 - 824 - 16) / (880 - 800) = 1.25
    // Remaining_repay_coin = 1 - 0.37454 = 0.62546 BTC
    // The liquidator should receive 0.3636 * 1.05 = 0.38178 BTC = 840 USD.
    // The 0.2 BTC will be used first (0.2 BTC = 440 USD). Then the remaining 400 USD will be taken as USDC.
    let (base_coin, quote_coin, remaining_repay_coin) = mm.liquidate<BTC, USDC, BTC>(
        &registry,
        &btc_price_2200,
        &usdc_price,
        &mut btc_pool,
        &mut pool,
        repay_coin,
        &clock,
        scenario.ctx(),
    );

    assert!(base_coin.value() == 20000000); // 0.2 BTC
    assert!(quote_coin.value() == 399999930); // ~400 USDC
    assert!(remaining_repay_coin.value() == 62545457); // 0.62545457 BTC

    destroy_3!(remaining_repay_coin, base_coin, quote_coin);
    return_shared_3!(mm, usdc_pool, pool);
    destroy_3!(btc_price, usdc_price, btc_price_2200);
    destroy(btc_pool);
    cleanup_margin_test(registry, admin_cap, maintainer_cap, clock, scenario);
}

/// Test liquidation with BTC/SUI pair where both assets are volatile
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
        registry_id,
    ) = setup_btc_sui_deepbook_margin();

    // BTC at $50,000, SUI at $20
    let btc_price = build_btc_price_info_object(&mut scenario, 50000, &clock);
    let sui_price = build_sui_price_info_object(&mut scenario, 20, &clock);

    scenario.next_tx(test_constants::user1());
    let mut pool = scenario.take_shared<Pool<BTC, SUI>>();
    let mut registry = scenario.take_shared<MarginRegistry>();
    let deepbook_registry = scenario.take_shared_by_id<Registry>(registry_id);
    margin_manager::new<BTC, SUI>(&pool, &deepbook_registry, &mut registry, &clock, scenario.ctx());
    return_shared(deepbook_registry);

    scenario.next_tx(test_constants::user1());
    let mut mm = scenario.take_shared<MarginManager<BTC, SUI>>();
    let btc_pool = scenario.take_shared_by_id<MarginPool<BTC>>(btc_pool_id);
    let mut sui_pool = scenario.take_shared_by_id<MarginPool<SUI>>(sui_pool_id);

    // Deposit 0.1 BTC worth $5,000
    mm.deposit<BTC, SUI, BTC>(
        &registry,
        &btc_price,
        &sui_price,
        mint_coin<BTC>(10_000_000, scenario.ctx()), // 0.1 BTC (8 decimals)
        &clock,
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
        &btc_pool,
        &sui_pool,
        &clock,
    );
    assert!(actual_risk_ratio == 2_250_000_000);

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
            &btc_pool,
            &sui_pool,
            &clock,
        );
        assert!(safe_risk_ratio > test_constants::liquidation_risk_ratio());

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

    // Create a liquidatable scenario: BTC drops to $15,000, SUI rises to $100
    // BTC value: 0.1 * $15,000 = $1500, SUI borrowed value: 200 * $100 = $20,000
    // Risk ratio = (1500 + 20000) / 20000 = 1.075 < 1.1, can liquidate
    let btc_price_crash = build_btc_price_info_object(&mut scenario, 15000, &clock);
    let sui_price_spike = build_sui_price_info_object(&mut scenario, 100, &clock);
    let repay_coin = mint_coin<SUI>(3000 * sui_multiplier(), scenario.ctx());

    let liquidation_risk_ratio = mm.risk_ratio(
        &registry,
        &btc_price_crash,
        &sui_price_spike,
        &pool,
        &btc_pool,
        &sui_pool,
        &clock,
    );
    assert!(liquidation_risk_ratio == 1_075_000_000); // Should be liquidatable

    // 180.25 SUI total is used. 175 SUI for repayment, 5.25 SUI for pool liquidation fee.
    // The liquidator should receive 175 * 0.02 = 3.5 SUI as a reward.
    // Risk ratio after liquidation = (21500 - 175 * 1.05 * 100) / (20000 - 175 * 100) = 1.25 (our target liquidation)
    // Remaining_repay_coin = 3000 - 180.25 = 2819.75 SUI
    // The liquidator should receive 175 * 1.05 = 183.75 SUI = 183.75 * 100 = 18375 USD.
    // Since there's enough SUI, no BTC is paid out
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

    assert!(base_coin.value() == 0);
    assert!(quote_coin.value() == 183_750_000_000);
    assert!(remaining_repay_coin.value() == 2819_750_000_000);

    destroy_3!(remaining_repay_coin, base_coin, quote_coin);
    return_shared_3!(mm, sui_pool, pool);
    destroy_3!(btc_price, sui_price, btc_price_crash);
    destroy(sui_price_spike);
    destroy(btc_pool);
    cleanup_margin_test(registry, admin_cap, maintainer_cap, clock, scenario);
}
