// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module margin_trading::margin_manager_math_tests;

use deepbook::pool::Pool;
use margin_trading::{
    margin_manager::{Self, MarginManager},
    margin_pool::MarginPool,
    margin_registry::MarginRegistry,
    test_constants::{Self, USDC, BTC, btc_multiplier},
    test_helpers::{
        cleanup_margin_test,
        mint_coin,
        build_demo_usdc_price_info_object,
        build_btc_price_info_object,
        setup_btc_usd_margin_trading,
        destroy_3,
        return_shared_3
    }
};

const ENoError: u64 = 0;
const ECannotLiquidate: u64 = 1;

#[test]
fun test_liquidation_ok() {
    test_liquidation(ENoError);
}

#[test, expected_failure(abort_code = margin_manager::ECannotLiquidate)]
fun test_liquidation_cannot_liquidate() {
    test_liquidation(ECannotLiquidate);
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
    // The liquidator should receive 160 * 1.05 = 168 USDC as reward, as there's USDC in the manager.
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
