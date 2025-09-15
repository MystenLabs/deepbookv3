// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module margin_trading::margin_manager_tests;

use deepbook::pool::Pool;
use margin_trading::{
    margin_manager::{Self, MarginManager},
    margin_pool::{Self, MarginPool},
    margin_registry::MarginRegistry,
    test_constants::{Self, USDC, USDT, BTC, INVALID_ASSET, btc_multiplier},
    test_helpers::{
        setup_margin_registry,
        create_margin_pool,
        create_pool_for_testing,
        enable_margin_trading_on_pool,
        default_protocol_config,
        cleanup_margin_test,
        mint_coin,
        build_demo_usdc_price_info_object,
        build_demo_usdt_price_info_object,
        build_btc_price_info_object,
        setup_btc_usd_margin_trading,
        setup_usdc_usdt_margin_trading,
        destroy_2,
        return_shared_2,
        return_shared_3,
        advance_time
    }
};
use sui::{test_scenario::{Self as test, return_shared}, test_utils::destroy};
use token::deep::DEEP;

#[test]
fun test_margin_manager_creation() {
    let (mut scenario, clock, admin_cap, maintainer_cap) = setup_margin_registry();

    create_margin_pool<USDT>(
        &mut scenario,
        &maintainer_cap,
        default_protocol_config(),
        &clock,
    );
    create_margin_pool<USDC>(
        &mut scenario,
        &maintainer_cap,
        default_protocol_config(),
        &clock,
    );

    // Create DeepBook pool and enable margin trading on it
    let pool_id = create_pool_for_testing<USDC, USDT>(&mut scenario);
    scenario.next_tx(test_constants::admin());
    let mut registry = scenario.take_shared<MarginRegistry>();
    enable_margin_trading_on_pool<USDC, USDT>(
        pool_id,
        &mut registry,
        &admin_cap,
        &clock,
        &mut scenario,
    );
    return_shared(registry);

    scenario.next_tx(test_constants::admin());
    let pool = scenario.take_shared<Pool<USDC, USDT>>();
    let registry = scenario.take_shared<MarginRegistry>();
    margin_manager::new<USDC, USDT>(&pool, &registry, &clock, scenario.ctx());
    return_shared(pool);
    cleanup_margin_test(registry, admin_cap, maintainer_cap, clock, scenario);
}

#[test]
fun test_margin_trading_with_oracle() {
    let (
        mut scenario,
        clock,
        admin_cap,
        maintainer_cap,
        usdc_pool_id,
        _usdt_pool_id,
        _pool_id,
    ) = setup_usdc_usdt_margin_trading();

    scenario.next_tx(test_constants::user1());
    let registry = scenario.take_shared<MarginRegistry>();
    let pool = scenario.take_shared<Pool<USDT, USDC>>();
    margin_manager::new<USDT, USDC>(&pool, &registry, &clock, scenario.ctx());

    scenario.next_tx(test_constants::admin());
    let usdc_price = build_demo_usdc_price_info_object(&mut scenario, &clock);
    let usdt_price = build_demo_usdt_price_info_object(&mut scenario, &clock);

    // Test borrowing with oracle prices
    scenario.next_tx(test_constants::user1());
    let mut mm = scenario.take_shared<MarginManager<USDT, USDC>>();
    let mut usdc_pool = scenario.take_shared_by_id<MarginPool<USDC>>(usdc_pool_id);

    // User1 deposits 10k USDT as collateral
    let deposit_coin = mint_coin<USDT>(10_000_000_000, scenario.ctx()); // 10k USDT with 6 decimals
    mm.deposit<USDT, USDC, USDT>(&registry, deposit_coin, scenario.ctx());

    // Borrow 5k USDC against the collateral (50% borrow ratio)
    mm.borrow_quote<USDT, USDC>(
        &registry,
        &mut usdc_pool,
        &usdt_price,
        &usdc_price,
        &pool,
        5_000_000_000, // 5k USDC with 6 decimals
        &clock,
        scenario.ctx(),
    );

    test::return_shared(mm);
    test::return_shared(usdc_pool);
    test::return_shared(pool);

    destroy_2!(usdc_price, usdt_price);
    cleanup_margin_test(registry, admin_cap, maintainer_cap, clock, scenario);
}

// #[test]
// fun test_btc_usd_margin_trading() {
//     let (
//         mut scenario,
//         clock,
//         admin_cap,
//         maintainer_cap,
//         _btc_pool_id,
//         usdc_pool_id,
//         _pool_id,
//     ) = setup_btc_usd_margin_trading();

//     let btc_price = build_btc_price_info_object(
//         &mut scenario,
//         60000,
//         &clock,
//     );
//     let usdc_price = build_demo_usdc_price_info_object(&mut scenario, &clock);

//     scenario.next_tx(test_constants::user1());
//     let pool = scenario.take_shared<Pool<BTC, USDC>>();
//     let registry = scenario.take_shared<MarginRegistry>();
//     margin_manager::new<BTC, USDC>(&pool, &registry, &clock, scenario.ctx());

//     scenario.next_tx(test_constants::user1());
//     let mut mm = scenario.take_shared<MarginManager<BTC, USDC>>();
//     let mut usdc_pool = scenario.take_shared_by_id<MarginPool<USDC>>(usdc_pool_id);

//     let deposit = mint_coin<BTC>(btc_multiplier() / 2, scenario.ctx()); // 0.5 BTC
//     mm.deposit<BTC, USDC, BTC>(&registry, deposit, scenario.ctx());

//     mm.borrow_quote<BTC, USDC>(
//         &registry,
//         &mut usdc_pool,
//         &btc_price,
//         &usdc_price,
//         &pool,
//         15_000_000000, // $15,000
//         &clock,
//         scenario.ctx(),
//     );

//     test::return_shared(mm);
//     test::return_shared(usdc_pool);
//     test::return_shared(pool);

//     destroy_2!(btc_price, usdc_price);
//     cleanup_margin_test(registry, admin_cap, maintainer_cap, clock, scenario);
// }

/// Test demonstrates depositing USD and borrowing BTC at near-max LTV
#[test]
fun test_usd_deposit_btc_borrow() {
    let (
        mut scenario,
        mut clock,
        admin_cap,
        maintainer_cap,
        btc_pool_id,
        _usdc_pool_id,
        _pool_id,
    ) = setup_btc_usd_margin_trading();

    // Set initial prices
    let btc_price = build_btc_price_info_object(
        &mut scenario,
        100000,
        &clock,
    );
    let usdc_price = build_demo_usdc_price_info_object(&mut scenario, &clock);

    scenario.next_tx(test_constants::user1());
    let mut pool = scenario.take_shared<Pool<BTC, USDC>>();
    let registry = scenario.take_shared<MarginRegistry>();
    margin_manager::new<BTC, USDC>(&pool, &registry, &clock, scenario.ctx());

    scenario.next_tx(test_constants::user1());
    let mut mm = scenario.take_shared<MarginManager<BTC, USDC>>();
    let mut btc_pool = scenario.take_shared_by_id<MarginPool<BTC>>(btc_pool_id);

    // Deposit 100000 USD
    mm.deposit<BTC, USDC, USDC>(
        &registry,
        mint_coin<USDC>(100_000_000000, scenario.ctx()),
        scenario.ctx(),
    );

    mm.borrow_base<BTC, USDC>(
        &registry,
        &mut btc_pool,
        &btc_price,
        &usdc_price,
        &pool,
        2 * btc_multiplier(),
        &clock,
        scenario.ctx(),
    );

    advance_time(&mut clock, 1);
    let btc_increased = build_btc_price_info_object(
        &mut scenario,
        300000,
        &clock,
    );

    let debt_coin = mint_coin<BTC>(10 * test_constants::btc_multiplier(), scenario.ctx());
    scenario.next_tx(test_constants::admin());
    let (base_coin, quote_coin, debt_coin) = mm.liquidate<BTC, USDC, BTC>(
        &registry,
        &btc_increased,
        &usdc_price,
        &mut btc_pool,
        &mut pool,
        debt_coin,
        &clock,
        scenario.ctx(),
    );

    destroy(debt_coin);
    destroy(base_coin);
    destroy(quote_coin);

    test::return_shared(mm);
    test::return_shared(btc_pool);
    test::return_shared(pool);

    destroy_2!(btc_price, usdc_price);
    destroy(btc_increased);
    cleanup_margin_test(registry, admin_cap, maintainer_cap, clock, scenario);
}

// Creation tests
#[test]
fun test_margin_manager_creation_ok() {
    let (mut scenario, clock, admin_cap, maintainer_cap) = setup_margin_registry();

    scenario.next_tx(test_constants::user1());
    create_margin_pool<USDC>(&mut scenario, &maintainer_cap, default_protocol_config(), &clock);
    create_margin_pool<USDT>(&mut scenario, &maintainer_cap, default_protocol_config(), &clock);

    let pool_id = create_pool_for_testing<USDC, USDT>(&mut scenario);
    scenario.next_tx(test_constants::admin());
    let mut registry = scenario.take_shared<MarginRegistry>();
    enable_margin_trading_on_pool<USDC, USDT>(
        pool_id,
        &mut registry,
        &admin_cap,
        &clock,
        &mut scenario,
    );
    return_shared(registry);

    scenario.next_tx(test_constants::user1());
    let pool = scenario.take_shared<Pool<USDC, USDT>>();
    let registry = scenario.take_shared<MarginRegistry>();
    margin_manager::new<USDC, USDT>(&pool, &registry, &clock, scenario.ctx());

    scenario.next_tx(test_constants::user1());
    let mm = scenario.take_shared<MarginManager<USDC, USDT>>();

    return_shared_2!(mm, pool);
    cleanup_margin_test(registry, admin_cap, maintainer_cap, clock, scenario);
}

#[test, expected_failure(abort_code = margin_manager::EMarginTradingNotAllowedInPool)]
fun test_margin_manager_creation_fails_when_not_enabled() {
    let (mut scenario, clock, _admin_cap, maintainer_cap) = setup_margin_registry();

    scenario.next_tx(test_constants::user1());
    create_margin_pool<USDC>(&mut scenario, &maintainer_cap, default_protocol_config(), &clock);
    create_margin_pool<USDT>(&mut scenario, &maintainer_cap, default_protocol_config(), &clock);

    // Create pool without margin trading
    let _pool_id = create_pool_for_testing<USDC, USDT>(&mut scenario);

    scenario.next_tx(test_constants::user1());
    let pool = scenario.take_shared<Pool<USDC, USDT>>();
    let registry = scenario.take_shared<MarginRegistry>();
    // should fail
    margin_manager::new<USDC, USDT>(&pool, &registry, &clock, scenario.ctx());

    abort
}

// Deposit tests
#[test]
fun test_deposit_with_base_quote_deep_assets() {
    let (mut scenario, clock, admin_cap, maintainer_cap) = setup_margin_registry();

    scenario.next_tx(test_constants::user1());
    create_margin_pool<USDC>(&mut scenario, &maintainer_cap, default_protocol_config(), &clock);
    create_margin_pool<USDT>(&mut scenario, &maintainer_cap, default_protocol_config(), &clock);

    let pool_id = create_pool_for_testing<USDC, USDT>(&mut scenario);
    scenario.next_tx(test_constants::admin());
    let mut registry = scenario.take_shared<MarginRegistry>();
    enable_margin_trading_on_pool<USDC, USDT>(
        pool_id,
        &mut registry,
        &admin_cap,
        &clock,
        &mut scenario,
    );
    return_shared(registry);

    scenario.next_tx(test_constants::user1());
    let pool = scenario.take_shared<Pool<USDC, USDT>>();
    let registry = scenario.take_shared<MarginRegistry>();
    margin_manager::new<USDC, USDT>(&pool, &registry, &clock, scenario.ctx());

    scenario.next_tx(test_constants::user1());
    let mut mm = scenario.take_shared<MarginManager<USDC, USDT>>();

    mm.deposit<USDC, USDT, USDC>(
        &registry,
        mint_coin<USDC>(1000 * test_constants::usdc_multiplier(), scenario.ctx()),
        scenario.ctx(),
    );

    mm.deposit<USDC, USDT, USDT>(
        &registry,
        mint_coin<USDT>(2000 * test_constants::usdt_multiplier(), scenario.ctx()),
        scenario.ctx(),
    );

    mm.deposit<USDC, USDT, DEEP>(
        &registry,
        mint_coin<DEEP>(500 * 1_000_000_000, scenario.ctx()),
        scenario.ctx(),
    );

    return_shared_2!(mm, pool);
    cleanup_margin_test(registry, admin_cap, maintainer_cap, clock, scenario);
}

#[test, expected_failure(abort_code = margin_manager::EInvalidDeposit)]
fun test_deposit_with_invalid_asset_fails() {
    let (mut scenario, clock, admin_cap, maintainer_cap) = setup_margin_registry();
    scenario.next_tx(test_constants::user1());
    create_margin_pool<USDC>(&mut scenario, &maintainer_cap, default_protocol_config(), &clock);
    create_margin_pool<USDT>(&mut scenario, &maintainer_cap, default_protocol_config(), &clock);

    let pool_id = create_pool_for_testing<USDC, USDT>(&mut scenario);
    scenario.next_tx(test_constants::admin());
    let mut registry = scenario.take_shared<MarginRegistry>();
    enable_margin_trading_on_pool<USDC, USDT>(
        pool_id,
        &mut registry,
        &admin_cap,
        &clock,
        &mut scenario,
    );
    return_shared(registry);

    scenario.next_tx(test_constants::user1());
    let pool = scenario.take_shared<Pool<USDC, USDT>>();
    let registry = scenario.take_shared<MarginRegistry>();
    margin_manager::new<USDC, USDT>(&pool, &registry, &clock, scenario.ctx());

    scenario.next_tx(test_constants::user1());
    let mut mm = scenario.take_shared<MarginManager<USDC, USDT>>();

    mm.deposit<USDC, USDT, INVALID_ASSET>(
        &registry,
        mint_coin<INVALID_ASSET>(1000 * test_constants::usdc_multiplier(), scenario.ctx()),
        scenario.ctx(),
    );

    abort
}

// Withdrawal tests
#[test]
fun test_withdrawal_ok_when_risk_ratio_above_limit() {
    let (
        mut scenario,
        clock,
        admin_cap,
        maintainer_cap,
        usdc_pool_id,
        usdt_pool_id,
        _pool_id,
    ) = setup_usdc_usdt_margin_trading();

    scenario.next_tx(test_constants::user1());
    let registry = scenario.take_shared<MarginRegistry>();
    let pool = scenario.take_shared<Pool<USDT, USDC>>();
    margin_manager::new<USDT, USDC>(&pool, &registry, &clock, scenario.ctx());

    scenario.next_tx(test_constants::user1());
    let mut mm = scenario.take_shared<MarginManager<USDT, USDC>>();
    let mut usdc_pool = scenario.take_shared_by_id<MarginPool<USDC>>(usdc_pool_id);
    let usdt_pool = scenario.take_shared_by_id<MarginPool<USDT>>(usdt_pool_id);

    mm.deposit<USDT, USDC, USDT>(
        &registry,
        mint_coin<USDT>(10_000 * test_constants::usdt_multiplier(), scenario.ctx()),
        scenario.ctx(),
    );
    let usdc_price = build_demo_usdc_price_info_object(&mut scenario, &clock);
    let usdt_price = build_demo_usdt_price_info_object(&mut scenario, &clock);
    mm.borrow_quote<USDT, USDC>(
        &registry,
        &mut usdc_pool,
        &usdt_price,
        &usdc_price,
        &pool,
        1000 * test_constants::usdc_multiplier(),
        &clock,
        scenario.ctx(),
    );

    // Now test withdrawal with existing loan (risk ratio should still be high)
    let withdraw_amount = 100 * test_constants::usdt_multiplier();
    let withdrawn_coin = mm.withdraw<USDT, USDC, USDT>(
        &registry,
        &usdt_pool,
        &usdc_pool,
        &usdt_price,
        &usdc_price,
        &pool,
        withdraw_amount,
        &clock,
        scenario.ctx(),
    );

    assert!(withdrawn_coin.value() == withdraw_amount);
    destroy(withdrawn_coin);

    return_shared_3!(mm, usdc_pool, pool);
    return_shared(usdt_pool);
    destroy_2!(usdc_price, usdt_price);
    cleanup_margin_test(registry, admin_cap, maintainer_cap, clock, scenario);
}

#[test, expected_failure(abort_code = margin_manager::EWithdrawRiskRatioExceeded)]
fun test_withdrawal_fails_when_risk_ratio_goes_below_limit() {
    let (
        mut scenario,
        clock,
        _admin_cap,
        _maintainer_cap,
        usdc_pool_id,
        usdt_pool_id,
        _pool_id,
    ) = setup_usdc_usdt_margin_trading();

    scenario.next_tx(test_constants::user1());
    let registry = scenario.take_shared<MarginRegistry>();
    let pool = scenario.take_shared<Pool<USDT, USDC>>();
    margin_manager::new<USDT, USDC>(&pool, &registry, &clock, scenario.ctx());

    scenario.next_tx(test_constants::user1());
    let mut mm = scenario.take_shared<MarginManager<USDT, USDC>>();
    let mut usdc_pool = scenario.take_shared_by_id<MarginPool<USDC>>(usdc_pool_id);
    let usdt_pool = scenario.take_shared_by_id<MarginPool<USDT>>(usdt_pool_id);

    let usdt_deposit = mint_coin<USDT>(10_000 * test_constants::usdt_multiplier(), scenario.ctx());
    mm.deposit<USDT, USDC, USDT>(&registry, usdt_deposit, scenario.ctx());

    let usdc_price = build_demo_usdc_price_info_object(&mut scenario, &clock);
    let usdt_price = build_demo_usdt_price_info_object(&mut scenario, &clock);
    mm.borrow_quote<USDT, USDC>(
        &registry,
        &mut usdc_pool,
        &usdt_price,
        &usdc_price,
        &pool,
        5000 * test_constants::usdc_multiplier(),
        &clock,
        scenario.ctx(),
    );

    let withdraw_amount = 9000 * test_constants::usdt_multiplier();
    let withdraw_coin = mm.withdraw<USDT, USDC, USDT>(
        &registry,
        &usdt_pool,
        &usdc_pool,
        &usdt_price,
        &usdc_price,
        &pool,
        withdraw_amount,
        &clock,
        scenario.ctx(),
    );
    destroy(withdraw_coin);

    abort
}

// Borrow tests
#[test, expected_failure(abort_code = margin_manager::ECannotHaveLoanInMoreThanOneMarginPool)]
fun test_borrow_fails_from_both_pools() {
    let (
        mut scenario,
        clock,
        _admin_cap,
        _maintainer_cap,
        usdc_pool_id,
        usdt_pool_id,
        _pool_id,
    ) = setup_usdc_usdt_margin_trading();

    scenario.next_tx(test_constants::user1());
    let registry = scenario.take_shared<MarginRegistry>();
    let pool = scenario.take_shared<Pool<USDT, USDC>>();
    margin_manager::new<USDT, USDC>(&pool, &registry, &clock, scenario.ctx());

    scenario.next_tx(test_constants::user1());
    let mut mm = scenario.take_shared<MarginManager<USDT, USDC>>();
    let mut usdc_pool = scenario.take_shared_by_id<MarginPool<USDC>>(usdc_pool_id);
    let mut usdt_pool = scenario.take_shared_by_id<MarginPool<USDT>>(usdt_pool_id);

    mm.deposit<USDT, USDC, USDT>(
        &registry,
        mint_coin<USDT>(10_000 * test_constants::usdt_multiplier(), scenario.ctx()),
        scenario.ctx(),
    );

    let usdc_price = build_demo_usdc_price_info_object(&mut scenario, &clock);
    let usdt_price = build_demo_usdt_price_info_object(&mut scenario, &clock);
    mm.borrow_quote<USDT, USDC>(
        &registry,
        &mut usdc_pool,
        &usdt_price,
        &usdc_price,
        &pool,
        1000 * test_constants::usdc_multiplier(),
        &clock,
        scenario.ctx(),
    );

    mm.borrow_base<USDT, USDC>(
        &registry,
        &mut usdt_pool,
        &usdt_price,
        &usdc_price,
        &pool,
        1000 * test_constants::usdc_multiplier(),
        &clock,
        scenario.ctx(),
    );

    abort
}

#[test, expected_failure(abort_code = margin_pool::EBorrowAmountTooLow)]
fun test_borrow_fails_with_zero_amount() {
    let (
        mut scenario,
        clock,
        _admin_cap,
        _maintainer_cap,
        usdc_pool_id,
        _usdt_pool_id,
        _pool_id,
    ) = setup_usdc_usdt_margin_trading();

    scenario.next_tx(test_constants::user1());
    let registry = scenario.take_shared<MarginRegistry>();
    let pool = scenario.take_shared<Pool<USDT, USDC>>();
    margin_manager::new<USDT, USDC>(&pool, &registry, &clock, scenario.ctx());

    scenario.next_tx(test_constants::user1());
    let mut mm = scenario.take_shared<MarginManager<USDT, USDC>>();
    let mut usdc_pool = scenario.take_shared_by_id<MarginPool<USDC>>(usdc_pool_id);

    mm.deposit<USDT, USDC, USDT>(
        &registry,
        mint_coin<USDT>(10_000 * test_constants::usdt_multiplier(), scenario.ctx()),
        scenario.ctx(),
    );

    let usdc_price = build_demo_usdc_price_info_object(&mut scenario, &clock);
    let usdt_price = build_demo_usdt_price_info_object(&mut scenario, &clock);
    mm.borrow_quote<USDT, USDC>(
        &registry,
        &mut usdc_pool,
        &usdt_price,
        &usdc_price,
        &pool,
        0,
        &clock,
        scenario.ctx(),
    );

    abort
}

#[test, expected_failure(abort_code = margin_manager::EBorrowRiskRatioExceeded)]
fun test_borrow_fails_when_risk_ratio_below_150() {
    let (
        mut scenario,
        clock,
        _admin_cap,
        _maintainer_cap,
        usdc_pool_id,
        _usdt_pool_id,
        _pool_id,
    ) = setup_usdc_usdt_margin_trading();

    scenario.next_tx(test_constants::user1());
    let registry = scenario.take_shared<MarginRegistry>();
    let pool = scenario.take_shared<Pool<USDT, USDC>>();
    margin_manager::new<USDT, USDC>(&pool, &registry, &clock, scenario.ctx());

    scenario.next_tx(test_constants::user1());
    let mut mm = scenario.take_shared<MarginManager<USDT, USDC>>();
    let mut usdc_pool = scenario.take_shared_by_id<MarginPool<USDC>>(usdc_pool_id);

    // Deposit small collateral
    mm.deposit<USDT, USDC, USDT>(
        &registry,
        mint_coin<USDT>(1000 * test_constants::usdt_multiplier(), scenario.ctx()),
        scenario.ctx(),
    );

    // Try to borrow amount that would push risk ratio below 1.5
    // With $1000 collateral, borrowing $5000 would give ratio of 0.2 which is way below 1.5
    let usdc_price = build_demo_usdc_price_info_object(&mut scenario, &clock);
    let usdt_price = build_demo_usdt_price_info_object(&mut scenario, &clock);
    let borrow_amount = 5000 * test_constants::usdc_multiplier();
    mm.borrow_quote<USDT, USDC>(
        &registry,
        &mut usdc_pool,
        &usdt_price,
        &usdc_price,
        &pool,
        borrow_amount,
        &clock,
        scenario.ctx(),
    );

    abort
}

// Repay tests
#[test, expected_failure(abort_code = margin_manager::EIncorrectMarginPool)]
fun test_repay_fails_wrong_pool() {
    let (
        mut scenario,
        clock,
        _admin_cap,
        _maintainer_cap,
        usdc_pool_id,
        usdt_pool_id,
        _pool_id,
    ) = setup_usdc_usdt_margin_trading();

    scenario.next_tx(test_constants::user1());
    let registry = scenario.take_shared<MarginRegistry>();
    let pool = scenario.take_shared<Pool<USDT, USDC>>();
    margin_manager::new<USDT, USDC>(&pool, &registry, &clock, scenario.ctx());

    scenario.next_tx(test_constants::user1());
    let mut mm = scenario.take_shared<MarginManager<USDT, USDC>>();
    let mut usdc_pool = scenario.take_shared_by_id<MarginPool<USDC>>(usdc_pool_id);
    let mut usdt_pool = scenario.take_shared_by_id<MarginPool<USDT>>(usdt_pool_id);

    mm.deposit<USDT, USDC, USDT>(
        &registry,
        mint_coin<USDT>(10_000 * test_constants::usdt_multiplier(), scenario.ctx()),
        scenario.ctx(),
    );
    let usdc_price = build_demo_usdc_price_info_object(&mut scenario, &clock);
    let usdt_price = build_demo_usdt_price_info_object(&mut scenario, &clock);
    let borrow_amount = 2000 * test_constants::usdc_multiplier();
    mm.borrow_quote<USDT, USDC>(
        &registry,
        &mut usdc_pool,
        &usdt_price,
        &usdc_price,
        &pool,
        borrow_amount,
        &clock,
        scenario.ctx(),
    );

    // Try to repay to wrong pool (USDT pool instead of USDC pool)
    let repay_coin = mint_coin<USDT>(1000 * test_constants::usdt_multiplier(), scenario.ctx());
    mm.deposit<USDT, USDC, USDT>(&registry, repay_coin, scenario.ctx());
    mm.repay_base<USDT, USDC>(
        &registry,
        &mut usdt_pool,
        option::none(),
        &clock,
        scenario.ctx(),
    );

    abort
}

#[test]
fun test_repay_full_with_none() {
    let (
        mut scenario,
        clock,
        admin_cap,
        maintainer_cap,
        usdc_pool_id,
        _usdt_pool_id,
        _pool_id,
    ) = setup_usdc_usdt_margin_trading();

    // Create margin manager and borrow
    scenario.next_tx(test_constants::user1());
    let registry = scenario.take_shared<MarginRegistry>();
    let pool = scenario.take_shared<Pool<USDT, USDC>>();
    margin_manager::new<USDT, USDC>(&pool, &registry, &clock, scenario.ctx());

    scenario.next_tx(test_constants::user1());
    let mut mm = scenario.take_shared<MarginManager<USDT, USDC>>();
    let mut usdc_pool = scenario.take_shared_by_id<MarginPool<USDC>>(usdc_pool_id);

    // Deposit and borrow
    mm.deposit<USDT, USDC, USDT>(
        &registry,
        mint_coin<USDT>(10_000 * test_constants::usdt_multiplier(), scenario.ctx()),
        scenario.ctx(),
    );
    let usdc_price = build_demo_usdc_price_info_object(&mut scenario, &clock);
    let usdt_price = build_demo_usdt_price_info_object(&mut scenario, &clock);
    let borrow_amount = 2000 * test_constants::usdc_multiplier();
    mm.borrow_quote<USDT, USDC>(
        &registry,
        &mut usdc_pool,
        &usdt_price,
        &usdc_price,
        &pool,
        borrow_amount,
        &clock,
        scenario.ctx(),
    );

    // Repay full loan
    let repay_coin = mint_coin<USDC>(3000 * test_constants::usdc_multiplier(), scenario.ctx()); // More than enough

    // Deposit the repay coin margin manager's balance manager
    mm.deposit<USDT, USDC, USDC>(&registry, repay_coin, scenario.ctx());

    let repaid_amount = mm.repay_quote<USDT, USDC>(
        &registry,
        &mut usdc_pool,
        option::none(),
        &clock,
        scenario.ctx(),
    );

    assert!(repaid_amount > 0);
    return_shared_3!(mm, usdc_pool, pool);
    destroy_2!(usdc_price, usdt_price);
    cleanup_margin_test(registry, admin_cap, maintainer_cap, clock, scenario);
}

#[test]
fun test_repay_exact_amount_no_rounding_errors() {
    let (
        mut scenario,
        clock,
        admin_cap,
        maintainer_cap,
        usdc_pool_id,
        _usdt_pool_id,
        _pool_id,
    ) = setup_usdc_usdt_margin_trading();

    scenario.next_tx(test_constants::user1());
    let registry = scenario.take_shared<MarginRegistry>();
    let pool = scenario.take_shared<Pool<USDT, USDC>>();
    margin_manager::new<USDT, USDC>(&pool, &registry, &clock, scenario.ctx());

    scenario.next_tx(test_constants::user1());
    let mut mm = scenario.take_shared<MarginManager<USDT, USDC>>();
    let mut usdc_pool = scenario.take_shared_by_id<MarginPool<USDC>>(usdc_pool_id);

    mm.deposit<USDT, USDC, USDT>(
        &registry,
        mint_coin<USDT>(100_000 * test_constants::usdt_multiplier(), scenario.ctx()),
        scenario.ctx(),
    );

    // testing for rounding errors when repaying shares * index
    let test_amounts = vector[
        100 * test_constants::usdc_multiplier(), // Small amount
        1234567890, // Odd amount
        999999999, // Just under 1 USDC
    ];

    test_amounts.do!(|borrow_amount| {
        // Borrow
        let usdc_price = build_demo_usdc_price_info_object(&mut scenario, &clock);
        let usdt_price = build_demo_usdt_price_info_object(&mut scenario, &clock);
        mm.borrow_quote<USDT, USDC>(
            &registry,
            &mut usdc_pool,
            &usdt_price,
            &usdc_price,
            &pool,
            borrow_amount,
            &clock,
            scenario.ctx(),
        );

        // Get the borrowed shares and calculate exact amount (shares * index)
        let (_, borrowed_quote_shares) = mm.borrowed_shares();
        let exact_amount = usdc_pool.borrow_shares_to_amount(borrowed_quote_shares, &clock);

        // Deposit enough for repayment
        let repay_coin = mint_coin<USDC>(exact_amount + 1000, scenario.ctx()); // Add buffer
        mm.deposit<USDT, USDC, USDC>(&registry, repay_coin, scenario.ctx());

        // Repay the exact amount equal to shares * index
        let repaid_amount = mm.repay_quote<USDT, USDC>(
            &registry,
            &mut usdc_pool,
            option::none(),
            &clock,
            scenario.ctx(),
        );

        // Verify no rounding error: repaid amount should equal calculated amount
        assert!(repaid_amount == exact_amount, 0);

        // Verify shares are zero or within 1 mist tolerance
        let (_, remaining_quote_shares) = mm.borrowed_shares();
        assert!(remaining_quote_shares <= 1, 1); // At most 1 share due to potential rounding

        // Clean up any remaining debt
        if (remaining_quote_shares > 0) {
            let remaining_amount = usdc_pool.borrow_shares_to_amount(
                remaining_quote_shares,
                &clock,
            );
            if (remaining_amount > 0) {
                mm.deposit<USDT, USDC, USDC>(
                    &registry,
                    mint_coin<USDC>(remaining_amount + 1, scenario.ctx()),
                    scenario.ctx(),
                );
                mm.repay_quote<USDT, USDC>(
                    &registry,
                    &mut usdc_pool,
                    option::none(),
                    &clock,
                    scenario.ctx(),
                );
            };
        };

        destroy_2!(usdc_price, usdt_price);
    });

    return_shared_3!(mm, usdc_pool, pool);
    cleanup_margin_test(registry, admin_cap, maintainer_cap, clock, scenario);
}

// TODO: Fix liquidation test - risk ratio calculation seems off
// #[test]
// #[test, expected_failure(abort_code = margin_manager::ECannotLiquidate)]
// fun test_liquidation_reward_calculations() {
//     let (
//         mut scenario,
//         mut clock,
//         admin_cap,
//         maintainer_cap,
//         _btc_pool_id,
//         usdc_pool_id,
//         _pool_id,
//     ) = setup_btc_usd_margin_trading();

//     let btc_price = build_btc_price_info_object(&mut scenario, 50000, &clock);
//     let usdc_price = build_demo_usdc_price_info_object(&mut scenario, &clock);

//     scenario.next_tx(test_constants::user1());
//     let mut pool = scenario.take_shared<Pool<BTC, USDC>>();
//     let registry = scenario.take_shared<MarginRegistry>();
//     margin_manager::new<BTC, USDC>(&pool, &registry, &clock, scenario.ctx());

//     scenario.next_tx(test_constants::user1());
//     let mut mm = scenario.take_shared<MarginManager<BTC, USDC>>();
//     let mut usdc_pool = scenario.take_shared_by_id<MarginPool<USDC>>(usdc_pool_id);

//     // Deposit 1 BTC worth $50k
//     mm.deposit<BTC, USDC, BTC>(
//         &registry,
//         mint_coin<BTC>(btc_multiplier(), scenario.ctx()),
//         scenario.ctx(),
//     );

//     // Borrow $30k (60% LTV)
//     mm.borrow_quote<BTC, USDC>(
//         &registry,
//         &mut usdc_pool,
//         &btc_price,
//         &usdc_price,
//         &pool,
//         30_000_000_000,
//         &clock,
//         scenario.ctx(),
//     );

//     // Price drops to trigger liquidation
//     advance_time(&mut clock, 1000);
//     let btc_price_dropped = build_btc_price_info_object(&mut scenario, 35000, &clock);

//     // Perform liquidation and check rewards
//     scenario.next_tx(test_constants::liquidator());
//     let initial_liquidator_btc = 0;
//     let initial_liquidator_usdc = 0;

//     let (fulfillment, base_coin, quote_coin) = mm.liquidate<BTC, USDC, USDC>(
//         &registry,
//         &btc_price_dropped,
//         &usdc_price,
//         &mut usdc_pool,
//         &mut pool,
//         &clock,
//         scenario.ctx(),
//     );

//     let liquidator_btc_reward = base_coin.value();
//     let liquidator_usdc_reward = quote_coin.value();

//     // Verify liquidator received rewards (should be non-zero)
//     assert!(
//         liquidator_btc_reward > initial_liquidator_btc || liquidator_usdc_reward > initial_liquidator_usdc,
//     );

//     destroy_3!(fulfillment, base_coin, quote_coin);
//     return_shared_3!(mm, usdc_pool, pool);
//     destroy_3!(btc_price, usdc_price, btc_price_dropped);
//     cleanup_margin_test(registry, admin_cap, maintainer_cap, clock, scenario);
// }

// === Risk Ratio Calculation Tests ===

// #[test]
// fun test_risk_ratio_with_zero_assets() {
//     let (mut scenario, clock, admin_cap, maintainer_cap) = setup_margin_registry();

//     scenario.next_tx(test_constants::user1());
//     create_margin_pool<USDC>(&mut scenario, &maintainer_cap, default_protocol_config(), &clock);
//     create_margin_pool<USDT>(&mut scenario, &maintainer_cap, default_protocol_config(), &clock);

//     let pool_id = create_pool_for_testing<USDC, USDT>(&mut scenario);
//     scenario.next_tx(test_constants::admin());
//     let mut registry = scenario.take_shared<MarginRegistry>();
//     enable_margin_trading_on_pool<USDC, USDT>(
//         pool_id,
//         &mut registry,
//         &admin_cap,
//         &clock,
//         &mut scenario,
//     );
//     return_shared(registry);

//     scenario.next_tx(test_constants::user1());
//     let pool = scenario.take_shared<Pool<USDC, USDT>>();
//     let registry = scenario.take_shared<MarginRegistry>();
//     margin_manager::new<USDC, USDT>(&pool, &registry, &clock, scenario.ctx());

//     scenario.next_tx(test_constants::user1());
//     let mm = scenario.take_shared<MarginManager<USDC, USDT>>();

//     assert!(mm.base_borrowed_shares() == 0);
//     assert!(mm.quote_borrowed_shares() == 0);

//     return_shared_2!(mm, pool);
//     cleanup_margin_test(registry, admin_cap, maintainer_cap, clock, scenario);
// }

// #[test]
// fun test_risk_ratio_with_multiple_assets() {
//     let (mut scenario, mut clock, admin_cap, maintainer_cap) = setup_margin_registry();
//     let usdc_pool_id = create_margin_pool<USDC>(
//         &mut scenario,
//         &maintainer_cap,
//         default_protocol_config(),
//         &clock,
//     );
//     let usdt_pool_id = create_margin_pool<USDT>(
//         &mut scenario,
//         &maintainer_cap,
//         default_protocol_config(),
//         &clock,
//     );
//     let (usdc_pool_cap, usdt_pool_cap) = get_margin_pool_caps(&mut scenario, usdc_pool_id);

//     let pool_id = create_pool_for_testing<USDC, USDT>(&mut scenario);
//     scenario.next_tx(test_constants::admin());
//     let mut registry = scenario.take_shared<MarginRegistry>();
//     enable_margin_trading_on_pool<USDC, USDT>(
//         pool_id,
//         &mut registry,
//         &admin_cap,
//         &clock,
//         &mut scenario,
//     );
//     return_shared(registry);

//     // Setup pools
//     scenario.next_tx(test_constants::admin());
//     let mut usdc_pool = scenario.take_shared_by_id<MarginPool<USDC>>(usdc_pool_id);
//     let mut usdt_pool = scenario.take_shared_by_id<MarginPool<USDT>>(usdt_pool_id);
//     let registry = scenario.take_shared<MarginRegistry>();

//     usdc_pool.supply(
//         &registry,
//         mint_coin<USDC>(1_000_000 * test_constants::usdc_multiplier(), scenario.ctx()),
//         &clock,
//         scenario.ctx(),
//     );
//     usdt_pool.supply(
//         &registry,
//         mint_coin<USDT>(1_000_000 * test_constants::usdt_multiplier(), scenario.ctx()),
//         &clock,
//         scenario.ctx(),
//     );

//     usdc_pool.enable_deepbook_pool_for_loan(&registry, pool_id, &usdc_pool_cap, &clock);
//     usdt_pool.enable_deepbook_pool_for_loan(&registry, pool_id, &usdt_pool_cap, &clock);

//     return_shared_2!(usdc_pool, usdt_pool);
//     return_to_sender_2!(&scenario, usdc_pool_cap, usdt_pool_cap);

//     scenario.next_tx(test_constants::user1());
//     let pool = scenario.take_shared<Pool<USDC, USDT>>();
//     margin_manager::new<USDC, USDT>(&pool, &registry, &clock, scenario.ctx());

//     scenario.next_tx(test_constants::user1());
//     let mut mm = scenario.take_shared<MarginManager<USDC, USDT>>();
//     let mut usdt_pool = scenario.take_shared_by_id<MarginPool<USDT>>(usdt_pool_id);

//     // Deposit multiple asset types
//     mm.deposit<USDC, USDT, USDC>(
//         &registry,
//         mint_coin<USDC>(5_000 * test_constants::usdc_multiplier(), scenario.ctx()),
//         scenario.ctx(),
//     );
//     mm.deposit<USDC, USDT, USDT>(
//         &registry,
//         mint_coin<USDT>(3_000 * test_constants::usdt_multiplier(), scenario.ctx()),
//         scenario.ctx(),
//     );
//     mm.deposit<USDC, USDT, DEEP>(
//         &registry,
//         mint_coin<DEEP>(1_000 * 1_000_000_000, scenario.ctx()),
//         scenario.ctx(),
//     );

//     // Borrow to create debt
//     let request = mm.borrow_quote<USDC, USDT>(
//         &registry,
//         &mut usdt_pool,
//         2_000 * test_constants::usdt_multiplier(),
//         &clock,
//         scenario.ctx(),
//     );

//     let usdc_price = build_demo_usdc_price_info_object(&mut scenario, &clock);
//     let usdt_price = build_demo_usdt_price_info_object(&mut scenario, &clock);

//     mm.prove_and_destroy_request<USDC, USDT, USDT>(
//         &registry,
//         &mut usdt_pool,
//         &pool,
//         &usdc_price,
//         &usdt_price,
//         &clock,
//         request,
//     );

//     // Risk ratio should account for all assets vs debt
//     // Total collateral value: $5000 USDC + $3000 USDT = $8000
//     // Total debt: $2000 USDT
//     // Risk ratio should be approximately 4.0 (400%)

//     return_shared_3!(mm, usdt_pool, pool);
//     destroy_2!(usdc_price, usdt_price);
//     cleanup_margin_test(registry, admin_cap, maintainer_cap, clock, scenario);
// }

// #[test]
// fun test_risk_ratio_with_oracle_price_changes() {
//     let (
//         mut scenario,
//         mut clock,
//         admin_cap,
//         maintainer_cap,
//         _btc_pool_id,
//         usdc_pool_id,
//         _pool_id,
//     ) = setup_btc_usd_margin_trading();

//     let btc_price = build_btc_price_info_object(&mut scenario, 50000, &clock);
//     let usdc_price = build_demo_usdc_price_info_object(&mut scenario, &clock);

//     scenario.next_tx(test_constants::user1());
//     let mut pool = scenario.take_shared<Pool<BTC, USDC>>();
//     let registry = scenario.take_shared<MarginRegistry>();
//     margin_manager::new<BTC, USDC>(&pool, &registry, &clock, scenario.ctx());

//     scenario.next_tx(test_constants::user1());
//     let mut mm = scenario.take_shared<MarginManager<BTC, USDC>>();
//     let mut usdc_pool = scenario.take_shared_by_id<MarginPool<USDC>>(usdc_pool_id);

//     // Deposit 1 BTC worth $50k
//     mm.deposit<BTC, USDC, BTC>(
//         &registry,
//         mint_coin<BTC>(btc_multiplier(), scenario.ctx()),
//         scenario.ctx(),
//     );

//     // Borrow $20k (40% LTV initially)
//     let request = mm.borrow_quote<BTC, USDC>(
//         &registry,
//         &mut usdc_pool,
//         20_000_000000,
//         &clock,
//         scenario.ctx(),
//     );

//     mm.prove_and_destroy_request<BTC, USDC, USDC>(
//         &registry,
//         &mut usdc_pool,
//         &pool,
//         &btc_price,
//         &usdc_price,
//         &clock,
//         request,
//     );

//     // Initial risk ratio: $50k / $20k = 2.5 (250%)

//     // BTC price increases to $60k
//     advance_time(&mut clock, 1000);
//     let btc_price_increased = build_btc_price_info_object(&mut scenario, 60000, &clock);

//     // Try withdrawing - should succeed as risk ratio improved to $60k / $20k = 3.0 (300%)
//     let (withdrawn, withdraw_request) = mm.withdraw<BTC, USDC, BTC>(
//         &registry,
//         btc_multiplier() / 10, // Withdraw 0.1 BTC
//         scenario.ctx(),
//     );

//     mm.prove_and_destroy_request<BTC, USDC, USDC>(
//         &registry,
//         &mut usdc_pool,
//         &pool,
//         &btc_price_increased,
//         &usdc_price,
//         &clock,
//         withdraw_request,
//     );

//     destroy(withdrawn);

//     // BTC price drops to $35k
//     advance_time(&mut clock, 1000);
//     let btc_price_dropped = build_btc_price_info_object(&mut scenario, 35000, &clock);

//     // Risk ratio now: 0.9 BTC * $35k / $20k = $31.5k / $20k = 1.575 (157.5%)
//     // Still above liquidation threshold (120%) but close

//     return_shared_3!(mm, usdc_pool, pool);
//     destroy_3!(btc_price, usdc_price, btc_price_increased);
//     destroy(btc_price_dropped);
//     cleanup_margin_test(registry, admin_cap, maintainer_cap, clock, scenario);
// }

// // === Position Limits Tests ===

// #[test, expected_failure(abort_code = margin_manager::EBorrowRiskRatioExceeded)]
// fun test_max_leverage_enforcement() {
//     let (mut scenario, mut clock, admin_cap, maintainer_cap) = setup_margin_registry();

//     let usdc_pool_id = create_margin_pool<USDC>(
//         &mut scenario,
//         &maintainer_cap,
//         default_protocol_config(),
//         &clock,
//     );
//     let usdt_pool_id = create_margin_pool<USDT>(
//         &mut scenario,
//         &maintainer_cap,
//         default_protocol_config(),
//         &clock,
//     );

//     let (_usdc_pool_cap, usdt_pool_cap) = get_margin_pool_caps(&mut scenario, usdc_pool_id);

//     let pool_id = create_pool_for_testing<USDC, USDT>(&mut scenario);
//     scenario.next_tx(test_constants::admin());
//     let mut registry = scenario.take_shared<MarginRegistry>();
//     enable_margin_trading_on_pool<USDC, USDT>(
//         pool_id,
//         &mut registry,
//         &admin_cap,
//         &clock,
//         &mut scenario,
//     );
//     return_shared(registry);

//     scenario.next_tx(test_constants::admin());
//     let mut usdt_pool = scenario.take_shared_by_id<MarginPool<USDT>>(usdt_pool_id);
//     let registry = scenario.take_shared<MarginRegistry>();

//     usdt_pool.supply(
//         &registry,
//         mint_coin<USDT>(10_000_000 * test_constants::usdt_multiplier(), scenario.ctx()),
//         &clock,
//         scenario.ctx(),
//     );
//     usdt_pool.enable_deepbook_pool_for_loan(&registry, pool_id, &usdt_pool_cap, &clock);

//     return_shared(usdt_pool);
//     scenario.return_to_sender(usdt_pool_cap);

//     scenario.next_tx(test_constants::user1());
//     let pool = scenario.take_shared<Pool<USDC, USDT>>();
//     margin_manager::new<USDC, USDT>(&pool, &registry, &clock, scenario.ctx());

//     scenario.next_tx(test_constants::user1());
//     let mut mm = scenario.take_shared<MarginManager<USDC, USDT>>();
//     let mut usdt_pool = scenario.take_shared_by_id<MarginPool<USDT>>(usdt_pool_id);

//     // Deposit small collateral
//     mm.deposit<USDC, USDT, USDC>(
//         &registry,
//         mint_coin<USDC>(1_000 * test_constants::usdc_multiplier(), scenario.ctx()),
//         scenario.ctx(),
//     );

//     // Try to borrow beyond max leverage (would require > 10x leverage)
//     let excessive_borrow = 10_000 * test_constants::usdt_multiplier();
//     let request = mm.borrow_quote<USDC, USDT>(
//         &registry,
//         &mut usdt_pool,
//         excessive_borrow,
//         &clock,
//         scenario.ctx(),
//     );

//     let usdc_price = build_demo_usdc_price_info_object(&mut scenario, &clock);
//     let usdt_price = build_demo_usdt_price_info_object(&mut scenario, &clock);

//     // This should fail due to exceeding max leverage
//     mm.prove_and_destroy_request<USDC, USDT, USDT>(
//         &registry,
//         &mut usdt_pool,
//         &pool,
//         &usdc_price,
//         &usdt_price,
//         &clock,
//         request,
//     );

//     abort
// }

// #[test, expected_failure(abort_code = margin_pool::EBorrowAmountTooLow)]
// fun test_min_position_size_requirement() {
//     let (mut scenario, mut clock, admin_cap, maintainer_cap) = setup_margin_registry();

//     let usdc_pool_id = create_margin_pool<USDC>(
//         &mut scenario,
//         &maintainer_cap,
//         default_protocol_config(),
//         &clock,
//     );
//     let usdt_pool_id = create_margin_pool<USDT>(
//         &mut scenario,
//         &maintainer_cap,
//         default_protocol_config(),
//         &clock,
//     );

//     let (_usdc_pool_cap, usdt_pool_cap) = get_margin_pool_caps(&mut scenario, usdc_pool_id);

//     let pool_id = create_pool_for_testing<USDC, USDT>(&mut scenario);
//     scenario.next_tx(test_constants::admin());
//     let mut registry = scenario.take_shared<MarginRegistry>();
//     enable_margin_trading_on_pool<USDC, USDT>(
//         pool_id,
//         &mut registry,
//         &admin_cap,
//         &clock,
//         &mut scenario,
//     );
//     return_shared(registry);

//     scenario.next_tx(test_constants::admin());
//     let mut usdt_pool = scenario.take_shared_by_id<MarginPool<USDT>>(usdt_pool_id);
//     let registry = scenario.take_shared<MarginRegistry>();

//     usdt_pool.supply(
//         &registry,
//         mint_coin<USDT>(1_000_000 * test_constants::usdt_multiplier(), scenario.ctx()),
//         &clock,
//         scenario.ctx(),
//     );
//     usdt_pool.enable_deepbook_pool_for_loan(&registry, pool_id, &usdt_pool_cap, &clock);

//     return_shared(usdt_pool);
//     scenario.return_to_sender(usdt_pool_cap);

//     scenario.next_tx(test_constants::user1());
//     let pool = scenario.take_shared<Pool<USDC, USDT>>();
//     margin_manager::new<USDC, USDT>(&pool, &registry, &clock, scenario.ctx());

//     scenario.next_tx(test_constants::user1());
//     let mut mm = scenario.take_shared<MarginManager<USDC, USDT>>();
//     let mut usdt_pool = scenario.take_shared_by_id<MarginPool<USDT>>(usdt_pool_id);

//     mm.deposit<USDC, USDT, USDC>(
//         &registry,
//         mint_coin<USDC>(10_000 * test_constants::usdc_multiplier(), scenario.ctx()),
//         scenario.ctx(),
//     );

//     // Try to borrow below minimum position size (default min_borrow is 10 * PRECISION_DECIMAL_9)
//     let tiny_borrow = 1; // 1 mist, way below minimum
//     let _request = mm.borrow_quote<USDC, USDT>(
//         &registry,
//         &mut usdt_pool,
//         tiny_borrow,
//         &clock,
//         scenario.ctx(),
//     );

//     abort
// }

// #[test]
// fun test_repayment_rounding() {
//     let (mut scenario, mut clock, admin_cap, maintainer_cap) = setup_margin_registry();

//     let usdc_pool_id = create_margin_pool<USDC>(
//         &mut scenario,
//         &maintainer_cap,
//         default_protocol_config(),
//         &clock,
//     );
//     let usdt_pool_id = create_margin_pool<USDT>(
//         &mut scenario,
//         &maintainer_cap,
//         default_protocol_config(),
//         &clock,
//     );

//     let (usdc_pool_cap, usdt_pool_cap) = get_margin_pool_caps(&mut scenario, usdc_pool_id);

//     let pool_id = create_pool_for_testing<USDC, USDT>(&mut scenario);
//     scenario.next_tx(test_constants::admin());
//     let mut registry = scenario.take_shared<MarginRegistry>();
//     enable_margin_trading_on_pool<USDC, USDT>(
//         pool_id,
//         &mut registry,
//         &admin_cap,
//         &clock,
//         &mut scenario,
//     );
//     return_shared(registry);

//     scenario.next_tx(test_constants::admin());
//     let mut usdc_pool = scenario.take_shared_by_id<MarginPool<USDC>>(usdc_pool_id);
//     let mut usdt_pool = scenario.take_shared_by_id<MarginPool<USDT>>(usdt_pool_id);
//     let registry = scenario.take_shared<MarginRegistry>();

//     usdc_pool.supply(
//         &registry,
//         mint_coin<USDC>(1_000_000 * test_constants::usdc_multiplier(), scenario.ctx()),
//         &clock,
//         scenario.ctx(),
//     );
//     usdt_pool.supply(
//         &registry,
//         mint_coin<USDT>(1_000_000 * test_constants::usdt_multiplier(), scenario.ctx()),
//         &clock,
//         scenario.ctx(),
//     );

//     usdc_pool.enable_deepbook_pool_for_loan(&registry, pool_id, &usdc_pool_cap, &clock);
//     usdt_pool.enable_deepbook_pool_for_loan(&registry, pool_id, &usdt_pool_cap, &clock);

//     return_shared_2!(usdc_pool, usdt_pool);
//     return_to_sender_2!(&scenario, usdc_pool_cap, usdt_pool_cap);

//     scenario.next_tx(test_constants::user1());
//     let pool = scenario.take_shared<Pool<USDC, USDT>>();
//     margin_manager::new<USDC, USDT>(&pool, &registry, &clock, scenario.ctx());

//     scenario.next_tx(test_constants::user1());
//     let mut mm = scenario.take_shared<MarginManager<USDC, USDT>>();
//     let mut usdt_pool = scenario.take_shared_by_id<MarginPool<USDT>>(usdt_pool_id);

//     // Setup position with debt
//     mm.deposit<USDC, USDT, USDC>(
//         &registry,
//         mint_coin<USDC>(20_000 * test_constants::usdc_multiplier(), scenario.ctx()),
//         scenario.ctx(),
//     );

//     let request = mm.borrow_quote<USDC, USDT>(
//         &registry,
//         &mut usdt_pool,
//         5_000 * test_constants::usdt_multiplier(),
//         &clock,
//         scenario.ctx(),
//     );

//     let usdc_price = build_demo_usdc_price_info_object(&mut scenario, &clock);
//     let usdt_price = build_demo_usdt_price_info_object(&mut scenario, &clock);

//     mm.prove_and_destroy_request<USDC, USDT, USDT>(
//         &registry,
//         &mut usdt_pool,
//         &pool,
//         &usdc_price,
//         &usdt_price,
//         &clock,
//         request,
//     );

//     // TODO: WAIT ON TONY FIX
//     // advance_time(&mut clock, 1000 * 100); // 100 seconds later

//     // Partial repayment
//     mm.deposit<USDC, USDT, USDT>(
//         &registry,
//         mint_coin<USDT>(2_000 * test_constants::usdt_multiplier(), scenario.ctx()),
//         scenario.ctx(),
//     );

//     let repaid_amount = mm.repay_quote<USDC, USDT>(
//         &registry,
//         &mut usdt_pool,
//         option::some(2_000 * test_constants::usdt_multiplier()),
//         &clock,
//         scenario.ctx(),
//     );

//     assert!(repaid_amount == 2_000 * test_constants::usdt_multiplier());

//     // Full repayment
//     mm.deposit<USDC, USDT, USDT>(
//         &registry,
//         mint_coin<USDT>(5_000 * test_constants::usdt_multiplier(), scenario.ctx()),
//         scenario.ctx(),
//     );

//     let final_repaid = mm.repay_quote<USDC, USDT>(
//         &registry,
//         &mut usdt_pool,
//         option::none(), // Repay all
//         &clock,
//         scenario.ctx(),
//     );

//     assert!(final_repaid > 0);
//     assert!(mm.quote_borrowed_shares() == 0);

//     return_shared_3!(mm, usdt_pool, pool);
//     destroy_2!(usdc_price, usdt_price);
//     cleanup_margin_test(registry, admin_cap, maintainer_cap, clock, scenario);
// }

// #[test]
// fun test_asset_rebalancing_between_pools() {
//     let (mut scenario, mut clock, admin_cap, maintainer_cap) = setup_margin_registry();

//     let usdc_pool_id = create_margin_pool<USDC>(
//         &mut scenario,
//         &maintainer_cap,
//         default_protocol_config(),
//         &clock,
//     );
//     let usdt_pool_id = create_margin_pool<USDT>(
//         &mut scenario,
//         &maintainer_cap,
//         default_protocol_config(),
//         &clock,
//     );

//     let (usdc_pool_cap, usdt_pool_cap) = get_margin_pool_caps(&mut scenario, usdc_pool_id);

//     let pool_id = create_pool_for_testing<USDC, USDT>(&mut scenario);
//     scenario.next_tx(test_constants::admin());
//     let mut registry = scenario.take_shared<MarginRegistry>();
//     enable_margin_trading_on_pool<USDC, USDT>(
//         pool_id,
//         &mut registry,
//         &admin_cap,
//         &clock,
//         &mut scenario,
//     );
//     return_shared(registry);

//     scenario.next_tx(test_constants::admin());
//     let mut usdc_pool = scenario.take_shared_by_id<MarginPool<USDC>>(usdc_pool_id);
//     let mut usdt_pool = scenario.take_shared_by_id<MarginPool<USDT>>(usdt_pool_id);
//     let registry = scenario.take_shared<MarginRegistry>();

//     usdc_pool.supply(
//         &registry,
//         mint_coin<USDC>(1_000_000 * test_constants::usdc_multiplier(), scenario.ctx()),
//         &clock,
//         scenario.ctx(),
//     );
//     usdt_pool.supply(
//         &registry,
//         mint_coin<USDT>(1_000_000 * test_constants::usdt_multiplier(), scenario.ctx()),
//         &clock,
//         scenario.ctx(),
//     );

//     usdc_pool.enable_deepbook_pool_for_loan(&registry, pool_id, &usdc_pool_cap, &clock);
//     usdt_pool.enable_deepbook_pool_for_loan(&registry, pool_id, &usdt_pool_cap, &clock);

//     return_shared_2!(usdc_pool, usdt_pool);
//     return_to_sender_2!(&scenario, usdc_pool_cap, usdt_pool_cap);

//     scenario.next_tx(test_constants::user1());
//     let pool = scenario.take_shared<Pool<USDC, USDT>>();
//     margin_manager::new<USDC, USDT>(&pool, &registry, &clock, scenario.ctx());

//     scenario.next_tx(test_constants::user1());
//     let mut mm = scenario.take_shared<MarginManager<USDC, USDT>>();

//     // Deposit assets in both base and quote
//     mm.deposit<USDC, USDT, USDC>(
//         &registry,
//         mint_coin<USDC>(10_000 * test_constants::usdc_multiplier(), scenario.ctx()),
//         scenario.ctx(),
//     );
//     mm.deposit<USDC, USDT, USDT>(
//         &registry,
//         mint_coin<USDT>(10_000 * test_constants::usdt_multiplier(), scenario.ctx()),
//         scenario.ctx(),
//     );

//     // Withdraw from one type
//     let (usdc_withdrawn, withdraw_request) = mm.withdraw<USDC, USDT, USDC>(
//         &registry,
//         5_000 * test_constants::usdc_multiplier(),
//         scenario.ctx(),
//     );

//     let usdc_price = build_demo_usdc_price_info_object(&mut scenario, &clock);
//     let usdt_price = build_demo_usdt_price_info_object(&mut scenario, &clock);

//     // No debt, so withdrawal should succeed without proving
//     destroy(withdraw_request);
//     assert!(usdc_withdrawn.value() == 5_000 * test_constants::usdc_multiplier());

//     // Deposit back different asset
//     mm.deposit<USDC, USDT, USDT>(
//         &registry,
//         mint_coin<USDT>(5_000 * test_constants::usdt_multiplier(), scenario.ctx()),
//         scenario.ctx(),
//     );

//     destroy(usdc_withdrawn);
//     return_shared_2!(mm, pool);
//     destroy_2!(usdc_price, usdt_price);
//     cleanup_margin_test(registry, admin_cap, maintainer_cap, clock, scenario);
// }
