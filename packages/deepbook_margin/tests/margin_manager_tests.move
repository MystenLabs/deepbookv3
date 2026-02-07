// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module deepbook_margin::margin_manager_tests;

use deepbook::{pool::Pool, registry::Registry};
use deepbook_margin::{
    margin_constants,
    margin_manager::{Self, MarginManager},
    margin_pool::{Self, MarginPool},
    margin_registry::{Self, MarginRegistry},
    test_constants::{Self, USDC, USDT, BTC, INVALID_ASSET, btc_multiplier},
    test_helpers::{
        Self,
        setup_margin_registry,
        create_margin_pool,
        create_pool_for_testing,
        enable_deepbook_margin_on_pool,
        default_protocol_config,
        cleanup_margin_test,
        mint_coin,
        build_demo_usdc_price_info_object,
        build_demo_usdt_price_info_object,
        build_btc_price_info_object,
        build_stale_btc_price_info_object,
        build_stale_usdc_price_info_object,
        setup_btc_usd_deepbook_margin,
        setup_usdc_usdt_deepbook_margin,
        destroy_2,
        destroy_3,
        return_shared_2,
        return_shared_3,
        return_shared_4,
        advance_time,
        get_margin_pool_caps,
        return_to_sender_2
    }
};
use std::unit_test::destroy;
use sui::test_scenario::return_shared;
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
    let (pool_id, registry_id) = create_pool_for_testing<USDC, USDT>(&mut scenario);
    scenario.next_tx(test_constants::admin());
    let mut registry = scenario.take_shared<MarginRegistry>();
    enable_deepbook_margin_on_pool<USDC, USDT>(
        pool_id,
        &mut registry,
        &admin_cap,
        &clock,
        &mut scenario,
    );
    return_shared(registry);

    scenario.next_tx(test_constants::admin());
    let pool = scenario.take_shared<Pool<USDC, USDT>>();
    let mut registry = scenario.take_shared<MarginRegistry>();
    let deepbook_registry = scenario.take_shared_by_id<Registry>(registry_id);
    margin_manager::new<USDC, USDT>(
        &pool,
        &deepbook_registry,
        &mut registry,
        &clock,
        scenario.ctx(),
    );
    return_shared_2!(deepbook_registry, pool);
    cleanup_margin_test(registry, admin_cap, maintainer_cap, clock, scenario);
}

#[test]
fun test_deepbook_margin_with_oracle() {
    let (
        mut scenario,
        clock,
        admin_cap,
        maintainer_cap,
        usdc_pool_id,
        _usdt_pool_id,
        _pool_id,
        registry_id,
    ) = setup_usdc_usdt_deepbook_margin();

    scenario.next_tx(test_constants::user1());
    let mut registry = scenario.take_shared<MarginRegistry>();
    let pool = scenario.take_shared<Pool<USDT, USDC>>();
    let deepbook_registry = scenario.take_shared_by_id<Registry>(registry_id);
    margin_manager::new<USDT, USDC>(
        &pool,
        &deepbook_registry,
        &mut registry,
        &clock,
        scenario.ctx(),
    );
    return_shared(deepbook_registry);

    scenario.next_tx(test_constants::admin());
    let usdc_price = build_demo_usdc_price_info_object(&mut scenario, &clock);
    let usdt_price = build_demo_usdt_price_info_object(&mut scenario, &clock);

    // Test borrowing with oracle prices
    scenario.next_tx(test_constants::user1());
    let mut mm = scenario.take_shared<MarginManager<USDT, USDC>>();
    let mut usdc_pool = scenario.take_shared_by_id<MarginPool<USDC>>(usdc_pool_id);

    // User1 deposits 10k USDT as collateral
    let deposit_coin = mint_coin<USDT>(10_000_000_000, scenario.ctx()); // 10k USDT with 6 decimals
    mm.deposit<USDT, USDC, USDT>(
        &registry,
        &usdt_price,
        &usdc_price,
        deposit_coin,
        &clock,
        scenario.ctx(),
    );

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

    destroy_2!(usdc_price, usdt_price);
    return_shared_3!(usdc_pool, pool, mm);
    cleanup_margin_test(registry, admin_cap, maintainer_cap, clock, scenario);
}

#[test]
fun test_btc_usd_deepbook_margin() {
    let (
        mut scenario,
        clock,
        admin_cap,
        maintainer_cap,
        _btc_pool_id,
        usdc_pool_id,
        _pool_id,
        registry_id,
    ) = setup_btc_usd_deepbook_margin();

    let btc_price = build_btc_price_info_object(
        &mut scenario,
        60000,
        &clock,
    );
    let usdc_price = build_demo_usdc_price_info_object(&mut scenario, &clock);

    scenario.next_tx(test_constants::user1());
    let pool = scenario.take_shared<Pool<BTC, USDC>>();
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

    let deposit = mint_coin<BTC>(btc_multiplier() / 2, scenario.ctx()); // 0.5 BTC
    mm.deposit<BTC, USDC, BTC>(&registry, &btc_price, &usdc_price, deposit, &clock, scenario.ctx());

    mm.borrow_quote<BTC, USDC>(
        &registry,
        &mut usdc_pool,
        &btc_price,
        &usdc_price,
        &pool,
        15_000_000000, // $15,000
        &clock,
        scenario.ctx(),
    );

    return_shared_2!(usdc_pool, pool);
    destroy_2!(btc_price, usdc_price);
    return_shared(mm);
    cleanup_margin_test(registry, admin_cap, maintainer_cap, clock, scenario);
}

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
        registry_id,
    ) = setup_btc_usd_deepbook_margin();

    // Set initial prices
    let btc_price = build_btc_price_info_object(
        &mut scenario,
        100000,
        &clock,
    );
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
    let mut btc_pool = scenario.take_shared_by_id<MarginPool<BTC>>(btc_pool_id);

    // Deposit 100000 USD
    mm.deposit<BTC, USDC, USDC>(
        &registry,
        &btc_price,
        &usdc_price,
        mint_coin<USDC>(100_000 * test_constants::usdc_multiplier(), scenario.ctx()),
        &clock,
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
        1_000_000,
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

    return_shared_2!(btc_pool, pool);
    destroy_2!(btc_price, usdc_price);
    return_shared(mm);
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

    let (pool_id, registry_id) = create_pool_for_testing<USDC, USDT>(&mut scenario);
    scenario.next_tx(test_constants::admin());
    let mut registry = scenario.take_shared<MarginRegistry>();
    enable_deepbook_margin_on_pool<USDC, USDT>(
        pool_id,
        &mut registry,
        &admin_cap,
        &clock,
        &mut scenario,
    );
    return_shared(registry);

    scenario.next_tx(test_constants::user1());
    let pool = scenario.take_shared<Pool<USDC, USDT>>();
    let mut registry = scenario.take_shared<MarginRegistry>();
    let deepbook_registry = scenario.take_shared_by_id<Registry>(registry_id);
    margin_manager::new<USDC, USDT>(
        &pool,
        &deepbook_registry,
        &mut registry,
        &clock,
        scenario.ctx(),
    );
    return_shared(deepbook_registry);

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
    let (_pool_id, registry_id) = create_pool_for_testing<USDC, USDT>(&mut scenario);

    scenario.next_tx(test_constants::user1());
    let pool = scenario.take_shared<Pool<USDC, USDT>>();
    let mut registry = scenario.take_shared<MarginRegistry>();
    // should fail
    let deepbook_registry = scenario.take_shared_by_id<Registry>(registry_id);
    margin_manager::new<USDC, USDT>(
        &pool,
        &deepbook_registry,
        &mut registry,
        &clock,
        scenario.ctx(),
    );
    return_shared(deepbook_registry);

    abort
}

// Deposit tests
#[test]
fun test_deposit_with_base_quote_deep_assets() {
    let (mut scenario, clock, admin_cap, maintainer_cap) = setup_margin_registry();

    scenario.next_tx(test_constants::user1());
    create_margin_pool<USDC>(&mut scenario, &maintainer_cap, default_protocol_config(), &clock);
    create_margin_pool<USDT>(&mut scenario, &maintainer_cap, default_protocol_config(), &clock);

    let (pool_id, registry_id) = create_pool_for_testing<USDC, USDT>(&mut scenario);
    scenario.next_tx(test_constants::admin());
    let mut registry = scenario.take_shared<MarginRegistry>();
    enable_deepbook_margin_on_pool<USDC, USDT>(
        pool_id,
        &mut registry,
        &admin_cap,
        &clock,
        &mut scenario,
    );
    return_shared(registry);

    scenario.next_tx(test_constants::user1());
    let pool = scenario.take_shared<Pool<USDC, USDT>>();
    let mut registry = scenario.take_shared<MarginRegistry>();
    let deepbook_registry = scenario.take_shared_by_id<Registry>(registry_id);
    margin_manager::new<USDC, USDT>(
        &pool,
        &deepbook_registry,
        &mut registry,
        &clock,
        scenario.ctx(),
    );
    return_shared(deepbook_registry);

    scenario.next_tx(test_constants::user1());
    let mut mm = scenario.take_shared<MarginManager<USDC, USDT>>();
    let usdc_price = build_demo_usdc_price_info_object(&mut scenario, &clock);
    let usdt_price = build_demo_usdt_price_info_object(&mut scenario, &clock);

    mm.deposit<USDC, USDT, USDC>(
        &registry,
        &usdc_price,
        &usdt_price,
        mint_coin<USDC>(1000 * test_constants::usdc_multiplier(), scenario.ctx()),
        &clock,
        scenario.ctx(),
    );

    mm.deposit<USDC, USDT, USDT>(
        &registry,
        &usdc_price,
        &usdt_price,
        mint_coin<USDT>(2000 * test_constants::usdt_multiplier(), scenario.ctx()),
        &clock,
        scenario.ctx(),
    );

    mm.deposit<USDC, USDT, DEEP>(
        &registry,
        &usdc_price,
        &usdt_price,
        mint_coin<DEEP>(500 * 1_000_000_000, scenario.ctx()),
        &clock,
        scenario.ctx(),
    );

    destroy_2!(usdc_price, usdt_price);
    return_shared_2!(mm, pool);
    cleanup_margin_test(registry, admin_cap, maintainer_cap, clock, scenario);
}

#[test, expected_failure(abort_code = margin_manager::EInvalidDeposit)]
fun test_deposit_with_invalid_asset_fails() {
    let (mut scenario, clock, admin_cap, maintainer_cap) = setup_margin_registry();
    scenario.next_tx(test_constants::user1());
    create_margin_pool<USDC>(&mut scenario, &maintainer_cap, default_protocol_config(), &clock);
    create_margin_pool<USDT>(&mut scenario, &maintainer_cap, default_protocol_config(), &clock);

    let (pool_id, registry_id) = create_pool_for_testing<USDC, USDT>(&mut scenario);
    scenario.next_tx(test_constants::admin());
    let mut registry = scenario.take_shared<MarginRegistry>();
    enable_deepbook_margin_on_pool<USDC, USDT>(
        pool_id,
        &mut registry,
        &admin_cap,
        &clock,
        &mut scenario,
    );
    return_shared(registry);

    scenario.next_tx(test_constants::user1());
    let pool = scenario.take_shared<Pool<USDC, USDT>>();
    let mut registry = scenario.take_shared<MarginRegistry>();
    let deepbook_registry = scenario.take_shared_by_id<Registry>(registry_id);
    margin_manager::new<USDC, USDT>(
        &pool,
        &deepbook_registry,
        &mut registry,
        &clock,
        scenario.ctx(),
    );
    return_shared(deepbook_registry);

    scenario.next_tx(test_constants::user1());
    let mut mm = scenario.take_shared<MarginManager<USDC, USDT>>();
    let usdc_price = build_demo_usdc_price_info_object(&mut scenario, &clock);
    let usdt_price = build_demo_usdt_price_info_object(&mut scenario, &clock);

    mm.deposit<USDC, USDT, INVALID_ASSET>(
        &registry,
        &usdc_price,
        &usdt_price,
        mint_coin<INVALID_ASSET>(1000 * test_constants::usdc_multiplier(), scenario.ctx()),
        &clock,
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
        registry_id,
    ) = setup_usdc_usdt_deepbook_margin();

    scenario.next_tx(test_constants::user1());
    let mut registry = scenario.take_shared<MarginRegistry>();
    let pool = scenario.take_shared<Pool<USDT, USDC>>();
    let deepbook_registry = scenario.take_shared_by_id<Registry>(registry_id);
    margin_manager::new<USDT, USDC>(
        &pool,
        &deepbook_registry,
        &mut registry,
        &clock,
        scenario.ctx(),
    );
    return_shared(deepbook_registry);

    scenario.next_tx(test_constants::user1());
    let mut mm = scenario.take_shared<MarginManager<USDT, USDC>>();
    let mut usdc_pool = scenario.take_shared_by_id<MarginPool<USDC>>(usdc_pool_id);
    let usdt_pool = scenario.take_shared_by_id<MarginPool<USDT>>(usdt_pool_id);
    let usdc_price = build_demo_usdc_price_info_object(&mut scenario, &clock);
    let usdt_price = build_demo_usdt_price_info_object(&mut scenario, &clock);

    mm.deposit<USDT, USDC, USDT>(
        &registry,
        &usdt_price,
        &usdc_price,
        mint_coin<USDT>(10_000 * test_constants::usdt_multiplier(), scenario.ctx()),
        &clock,
        scenario.ctx(),
    );
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

    destroy_2!(usdc_price, usdt_price);
    return_shared_4!(usdc_pool, pool, usdt_pool, mm);
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
        registry_id,
    ) = setup_usdc_usdt_deepbook_margin();

    scenario.next_tx(test_constants::user1());
    let mut registry = scenario.take_shared<MarginRegistry>();
    let pool = scenario.take_shared<Pool<USDT, USDC>>();
    let deepbook_registry = scenario.take_shared_by_id<Registry>(registry_id);
    margin_manager::new<USDT, USDC>(
        &pool,
        &deepbook_registry,
        &mut registry,
        &clock,
        scenario.ctx(),
    );
    return_shared(deepbook_registry);

    scenario.next_tx(test_constants::user1());
    let mut mm = scenario.take_shared<MarginManager<USDT, USDC>>();
    let mut usdc_pool = scenario.take_shared_by_id<MarginPool<USDC>>(usdc_pool_id);
    let usdt_pool = scenario.take_shared_by_id<MarginPool<USDT>>(usdt_pool_id);

    let usdc_price = build_demo_usdc_price_info_object(&mut scenario, &clock);
    let usdt_price = build_demo_usdt_price_info_object(&mut scenario, &clock);
    let usdt_deposit = mint_coin<USDT>(10_000 * test_constants::usdt_multiplier(), scenario.ctx());
    mm.deposit<USDT, USDC, USDT>(
        &registry,
        &usdt_price,
        &usdc_price,
        usdt_deposit,
        &clock,
        scenario.ctx(),
    );
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
        registry_id,
    ) = setup_usdc_usdt_deepbook_margin();

    scenario.next_tx(test_constants::user1());
    let mut registry = scenario.take_shared<MarginRegistry>();
    let pool = scenario.take_shared<Pool<USDT, USDC>>();
    let deepbook_registry = scenario.take_shared_by_id<Registry>(registry_id);
    margin_manager::new<USDT, USDC>(
        &pool,
        &deepbook_registry,
        &mut registry,
        &clock,
        scenario.ctx(),
    );
    return_shared(deepbook_registry);

    scenario.next_tx(test_constants::user1());
    let mut mm = scenario.take_shared<MarginManager<USDT, USDC>>();
    let mut usdc_pool = scenario.take_shared_by_id<MarginPool<USDC>>(usdc_pool_id);
    let mut usdt_pool = scenario.take_shared_by_id<MarginPool<USDT>>(usdt_pool_id);
    let usdc_price = build_demo_usdc_price_info_object(&mut scenario, &clock);
    let usdt_price = build_demo_usdt_price_info_object(&mut scenario, &clock);

    mm.deposit<USDT, USDC, USDT>(
        &registry,
        &usdt_price,
        &usdc_price,
        mint_coin<USDT>(10_000 * test_constants::usdt_multiplier(), scenario.ctx()),
        &clock,
        scenario.ctx(),
    );

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
        registry_id,
    ) = setup_usdc_usdt_deepbook_margin();

    scenario.next_tx(test_constants::user1());
    let mut registry = scenario.take_shared<MarginRegistry>();
    let pool = scenario.take_shared<Pool<USDT, USDC>>();
    let deepbook_registry = scenario.take_shared_by_id<Registry>(registry_id);
    margin_manager::new<USDT, USDC>(
        &pool,
        &deepbook_registry,
        &mut registry,
        &clock,
        scenario.ctx(),
    );
    return_shared(deepbook_registry);

    scenario.next_tx(test_constants::user1());
    let mut mm = scenario.take_shared<MarginManager<USDT, USDC>>();
    let mut usdc_pool = scenario.take_shared_by_id<MarginPool<USDC>>(usdc_pool_id);
    let usdc_price = build_demo_usdc_price_info_object(&mut scenario, &clock);
    let usdt_price = build_demo_usdt_price_info_object(&mut scenario, &clock);

    mm.deposit<USDT, USDC, USDT>(
        &registry,
        &usdt_price,
        &usdc_price,
        mint_coin<USDT>(10_000 * test_constants::usdt_multiplier(), scenario.ctx()),
        &clock,
        scenario.ctx(),
    );
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
        registry_id,
    ) = setup_usdc_usdt_deepbook_margin();

    scenario.next_tx(test_constants::user1());
    let mut registry = scenario.take_shared<MarginRegistry>();
    let pool = scenario.take_shared<Pool<USDT, USDC>>();
    let deepbook_registry = scenario.take_shared_by_id<Registry>(registry_id);
    margin_manager::new<USDT, USDC>(
        &pool,
        &deepbook_registry,
        &mut registry,
        &clock,
        scenario.ctx(),
    );
    return_shared(deepbook_registry);

    scenario.next_tx(test_constants::user1());
    let mut mm = scenario.take_shared<MarginManager<USDT, USDC>>();
    let mut usdc_pool = scenario.take_shared_by_id<MarginPool<USDC>>(usdc_pool_id);

    // Deposit small collateral
    let usdc_price = build_demo_usdc_price_info_object(&mut scenario, &clock);
    let usdt_price = build_demo_usdt_price_info_object(&mut scenario, &clock);
    mm.deposit<USDT, USDC, USDT>(
        &registry,
        &usdt_price,
        &usdc_price,
        mint_coin<USDT>(1000 * test_constants::usdt_multiplier(), scenario.ctx()),
        &clock,
        scenario.ctx(),
    );

    // Try to borrow amount that would push risk ratio below 1.5
    // With $1000 collateral, borrowing $5000 would give ratio of 0.2 which is way below 1.5
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
        registry_id,
    ) = setup_usdc_usdt_deepbook_margin();

    scenario.next_tx(test_constants::user1());
    let mut registry = scenario.take_shared<MarginRegistry>();
    let pool = scenario.take_shared<Pool<USDT, USDC>>();
    let deepbook_registry = scenario.take_shared_by_id<Registry>(registry_id);
    margin_manager::new<USDT, USDC>(
        &pool,
        &deepbook_registry,
        &mut registry,
        &clock,
        scenario.ctx(),
    );
    return_shared(deepbook_registry);

    scenario.next_tx(test_constants::user1());
    let mut mm = scenario.take_shared<MarginManager<USDT, USDC>>();
    let mut usdc_pool = scenario.take_shared_by_id<MarginPool<USDC>>(usdc_pool_id);
    let mut usdt_pool = scenario.take_shared_by_id<MarginPool<USDT>>(usdt_pool_id);

    let usdc_price = build_demo_usdc_price_info_object(&mut scenario, &clock);
    let usdt_price = build_demo_usdt_price_info_object(&mut scenario, &clock);
    mm.deposit<USDT, USDC, USDT>(
        &registry,
        &usdt_price,
        &usdc_price,
        mint_coin<USDT>(10_000 * test_constants::usdt_multiplier(), scenario.ctx()),
        &clock,
        scenario.ctx(),
    );
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
    mm.deposit<USDT, USDC, USDT>(
        &registry,
        &usdt_price,
        &usdc_price,
        repay_coin,
        &clock,
        scenario.ctx(),
    );
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
        registry_id,
    ) = setup_usdc_usdt_deepbook_margin();

    // Create margin manager and borrow
    scenario.next_tx(test_constants::user1());
    let mut registry = scenario.take_shared<MarginRegistry>();
    let pool = scenario.take_shared<Pool<USDT, USDC>>();
    let deepbook_registry = scenario.take_shared_by_id<Registry>(registry_id);
    margin_manager::new<USDT, USDC>(
        &pool,
        &deepbook_registry,
        &mut registry,
        &clock,
        scenario.ctx(),
    );
    return_shared(deepbook_registry);

    scenario.next_tx(test_constants::user1());
    let mut mm = scenario.take_shared<MarginManager<USDT, USDC>>();
    let mut usdc_pool = scenario.take_shared_by_id<MarginPool<USDC>>(usdc_pool_id);

    // Deposit and borrow
    let usdc_price = build_demo_usdc_price_info_object(&mut scenario, &clock);
    let usdt_price = build_demo_usdt_price_info_object(&mut scenario, &clock);
    mm.deposit<USDT, USDC, USDT>(
        &registry,
        &usdt_price,
        &usdc_price,
        mint_coin<USDT>(10_000 * test_constants::usdt_multiplier(), scenario.ctx()),
        &clock,
        scenario.ctx(),
    );
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
    mm.deposit<USDT, USDC, USDC>(
        &registry,
        &usdt_price,
        &usdc_price,
        repay_coin,
        &clock,
        scenario.ctx(),
    );

    let repaid_amount = mm.repay_quote<USDT, USDC>(
        &registry,
        &mut usdc_pool,
        option::none(),
        &clock,
        scenario.ctx(),
    );

    assert!(repaid_amount > 0);
    destroy_2!(usdc_price, usdt_price);
    return_shared_3!(usdc_pool, pool, mm);
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
        registry_id,
    ) = setup_usdc_usdt_deepbook_margin();

    scenario.next_tx(test_constants::user1());
    let mut registry = scenario.take_shared<MarginRegistry>();
    let pool = scenario.take_shared<Pool<USDT, USDC>>();
    let deepbook_registry = scenario.take_shared_by_id<Registry>(registry_id);
    margin_manager::new<USDT, USDC>(
        &pool,
        &deepbook_registry,
        &mut registry,
        &clock,
        scenario.ctx(),
    );
    return_shared(deepbook_registry);

    scenario.next_tx(test_constants::user1());
    let mut mm = scenario.take_shared<MarginManager<USDT, USDC>>();
    let mut usdc_pool = scenario.take_shared_by_id<MarginPool<USDC>>(usdc_pool_id);
    let usdc_price = build_demo_usdc_price_info_object(&mut scenario, &clock);
    let usdt_price = build_demo_usdt_price_info_object(&mut scenario, &clock);

    mm.deposit<USDT, USDC, USDT>(
        &registry,
        &usdt_price,
        &usdc_price,
        mint_coin<USDT>(100_000 * test_constants::usdt_multiplier(), scenario.ctx()),
        &clock,
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
        mm.deposit<USDT, USDC, USDC>(
            &registry,
            &usdt_price,
            &usdc_price,
            repay_coin,
            &clock,
            scenario.ctx(),
        );

        // Repay the exact amount equal to shares * index
        let repaid_amount = mm.repay_quote<USDT, USDC>(
            &registry,
            &mut usdc_pool,
            option::none(),
            &clock,
            scenario.ctx(),
        );

        // Verify no rounding error: repaid amount should equal calculated amount
        assert!(repaid_amount == exact_amount);

        // Verify shares are zero
        let borrowed_quote_shares = mm.borrowed_quote_shares();
        assert!(borrowed_quote_shares == 0);

        // Clean up any remaining debt
        if (borrowed_quote_shares > 0) {
            let remaining_amount = usdc_pool.borrow_shares_to_amount(
                borrowed_quote_shares,
                &clock,
            );
            if (remaining_amount > 0) {
                mm.deposit<USDT, USDC, USDC>(
                    &registry,
                    &usdt_price,
                    &usdc_price,
                    mint_coin<USDC>(remaining_amount + 1, scenario.ctx()),
                    &clock,
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
    });

    destroy_2!(usdc_price, usdt_price);
    return_shared_3!(mm, usdc_pool, pool);
    cleanup_margin_test(registry, admin_cap, maintainer_cap, clock, scenario);
}

#[test]
fun test_liquidation_reward_calculations() {
    let (
        mut scenario,
        clock,
        admin_cap,
        maintainer_cap,
        _btc_pool_id,
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
    let btc_price = build_btc_price_info_object(&mut scenario, 50000, &clock);
    let usdc_price = build_demo_usdc_price_info_object(&mut scenario, &clock);

    // Deposit 1 BTC worth $50k
    mm.deposit<BTC, USDC, BTC>(
        &registry,
        &btc_price,
        &usdc_price,
        mint_coin<BTC>(btc_multiplier(), scenario.ctx()),
        &clock,
        scenario.ctx(),
    );

    // Borrow $45k
    mm.borrow_quote<BTC, USDC>(
        &registry,
        &mut usdc_pool,
        &btc_price,
        &usdc_price,
        &pool,
        45_000_000_000,
        &clock,
        scenario.ctx(),
    );

    // Price drops severely to trigger liquidation
    // At $10k BTC price: ($10k BTC + $45k USDC) / $45k debt = $55k / $45k = 122% (still above 110%)
    // At $2k BTC price: ($2k BTC + $45k USDC) / $45k debt = $47k / $45k = 104.4% (below 110% - triggers liquidation!)
    let btc_price_dropped = build_btc_price_info_object(&mut scenario, 2000, &clock);

    // Perform liquidation and check rewards
    scenario.next_tx(test_constants::liquidator());
    let debt_coin = mint_coin<USDC>(50_000_000_000, scenario.ctx());

    let (base_coin, quote_coin, remaining_debt) = mm.liquidate<BTC, USDC, USDC>(
        &registry,
        &btc_price_dropped,
        &usdc_price,
        &mut usdc_pool,
        &mut pool,
        debt_coin,
        &clock,
        scenario.ctx(),
    );

    let liquidator_btc_reward = base_coin.value();
    let liquidator_usdc_reward = quote_coin.value();

    // Verify liquidator received rewards (should be non-zero)
    assert!(liquidator_btc_reward > 0 || liquidator_usdc_reward > 0);

    destroy_3!(remaining_debt, base_coin, quote_coin);
    return_shared_3!(mm, usdc_pool, pool);
    destroy_3!(btc_price, usdc_price, btc_price_dropped);
    cleanup_margin_test(registry, admin_cap, maintainer_cap, clock, scenario);
}

// === Risk Ratio Calculation Tests ===

#[test]
fun test_risk_ratio_with_zero_assets() {
    let (mut scenario, clock, admin_cap, maintainer_cap) = setup_margin_registry();

    scenario.next_tx(test_constants::user1());
    create_margin_pool<USDC>(&mut scenario, &maintainer_cap, default_protocol_config(), &clock);
    create_margin_pool<USDT>(&mut scenario, &maintainer_cap, default_protocol_config(), &clock);

    let (pool_id, registry_id) = create_pool_for_testing<USDC, USDT>(&mut scenario);
    scenario.next_tx(test_constants::admin());
    let mut registry = scenario.take_shared<MarginRegistry>();
    enable_deepbook_margin_on_pool<USDC, USDT>(
        pool_id,
        &mut registry,
        &admin_cap,
        &clock,
        &mut scenario,
    );
    return_shared(registry);

    scenario.next_tx(test_constants::user1());
    let pool = scenario.take_shared<Pool<USDC, USDT>>();
    let mut registry = scenario.take_shared<MarginRegistry>();
    let deepbook_registry = scenario.take_shared_by_id<Registry>(registry_id);
    margin_manager::new<USDC, USDT>(
        &pool,
        &deepbook_registry,
        &mut registry,
        &clock,
        scenario.ctx(),
    );
    return_shared(deepbook_registry);

    scenario.next_tx(test_constants::user1());
    let mm = scenario.take_shared<MarginManager<USDC, USDT>>();

    assert!(mm.borrowed_base_shares() == 0);
    assert!(mm.borrowed_quote_shares() == 0);

    return_shared_2!(mm, pool);
    cleanup_margin_test(registry, admin_cap, maintainer_cap, clock, scenario);
}

#[test]
fun test_risk_ratio_with_multiple_assets() {
    let (mut scenario, clock, admin_cap, maintainer_cap) = setup_margin_registry();
    let usdc_pool_id = create_margin_pool<USDC>(
        &mut scenario,
        &maintainer_cap,
        default_protocol_config(),
        &clock,
    );
    let usdt_pool_id = create_margin_pool<USDT>(
        &mut scenario,
        &maintainer_cap,
        default_protocol_config(),
        &clock,
    );
    let (usdc_pool_cap, usdt_pool_cap) = get_margin_pool_caps(&mut scenario, usdc_pool_id);

    let (pool_id, registry_id) = create_pool_for_testing<USDC, USDT>(&mut scenario);
    scenario.next_tx(test_constants::admin());
    let mut registry = scenario.take_shared<MarginRegistry>();
    enable_deepbook_margin_on_pool<USDC, USDT>(
        pool_id,
        &mut registry,
        &admin_cap,
        &clock,
        &mut scenario,
    );
    return_shared(registry);

    // Setup pools
    scenario.next_tx(test_constants::admin());
    let mut usdc_pool = scenario.take_shared_by_id<MarginPool<USDC>>(usdc_pool_id);
    let mut usdt_pool = scenario.take_shared_by_id<MarginPool<USDT>>(usdt_pool_id);
    let mut registry = scenario.take_shared<MarginRegistry>();

    let usdc_supplier_cap = test_helpers::supply_to_pool(
        &mut usdc_pool,
        &registry,
        1_000_000 * test_constants::usdc_multiplier(),
        &clock,
        scenario.ctx(),
    );
    let usdt_supplier_cap = test_helpers::supply_to_pool(
        &mut usdt_pool,
        &registry,
        1_000_000 * test_constants::usdt_multiplier(),
        &clock,
        scenario.ctx(),
    );

    usdc_pool.enable_deepbook_pool_for_loan(&registry, pool_id, &usdc_pool_cap, &clock);
    usdt_pool.enable_deepbook_pool_for_loan(&registry, pool_id, &usdt_pool_cap, &clock);

    destroy(usdc_supplier_cap);
    destroy(usdt_supplier_cap);

    return_shared_2!(usdc_pool, usdt_pool);
    return_to_sender_2!(&scenario, usdc_pool_cap, usdt_pool_cap);

    scenario.next_tx(test_constants::user1());
    let pool = scenario.take_shared<Pool<USDC, USDT>>();
    let deepbook_registry = scenario.take_shared_by_id<Registry>(registry_id);
    margin_manager::new<USDC, USDT>(
        &pool,
        &deepbook_registry,
        &mut registry,
        &clock,
        scenario.ctx(),
    );
    return_shared(deepbook_registry);

    scenario.next_tx(test_constants::user1());
    let mut mm = scenario.take_shared<MarginManager<USDC, USDT>>();
    let mut usdt_pool = scenario.take_shared_by_id<MarginPool<USDT>>(usdt_pool_id);
    let usdc_price = build_demo_usdc_price_info_object(&mut scenario, &clock);
    let usdt_price = build_demo_usdt_price_info_object(&mut scenario, &clock);

    // Deposit multiple asset types
    mm.deposit<USDC, USDT, USDC>(
        &registry,
        &usdc_price,
        &usdt_price,
        mint_coin<USDC>(5_000 * test_constants::usdc_multiplier(), scenario.ctx()),
        &clock,
        scenario.ctx(),
    );
    mm.deposit<USDC, USDT, USDT>(
        &registry,
        &usdc_price,
        &usdt_price,
        mint_coin<USDT>(3_000 * test_constants::usdt_multiplier(), scenario.ctx()),
        &clock,
        scenario.ctx(),
    );
    mm.deposit<USDC, USDT, DEEP>(
        &registry,
        &usdc_price,
        &usdt_price,
        mint_coin<DEEP>(1_000 * 1_000_000_000, scenario.ctx()),
        &clock,
        scenario.ctx(),
    );

    // Borrow to create debt
    mm.borrow_quote<USDC, USDT>(
        &registry,
        &mut usdt_pool,
        &usdc_price,
        &usdt_price,
        &pool,
        2_000 * test_constants::usdt_multiplier(),
        &clock,
        scenario.ctx(),
    );

    // Risk ratio should account for all assets vs debt
    // Total collateral value: $5000 USDC + $3000 USDT = $8000
    // Total debt: $2000 USDT
    // Risk ratio should be approximately 4.0 (400%)

    return_shared_3!(usdt_pool, pool, mm);
    destroy_2!(usdc_price, usdt_price);
    cleanup_margin_test(registry, admin_cap, maintainer_cap, clock, scenario);
}

#[test]
fun test_risk_ratio_with_oracle_price_changes() {
    let (
        mut scenario,
        mut clock,
        admin_cap,
        maintainer_cap,
        _btc_pool_id,
        usdc_pool_id,
        _pool_id,
        registry_id,
    ) = setup_btc_usd_deepbook_margin();

    scenario.next_tx(test_constants::user1());
    let pool = scenario.take_shared<Pool<BTC, USDC>>();
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
    let btc_pool = scenario.take_shared_by_id<MarginPool<BTC>>(_btc_pool_id);
    let mut usdc_pool = scenario.take_shared_by_id<MarginPool<USDC>>(usdc_pool_id);
    let btc_price = build_btc_price_info_object(&mut scenario, 50000, &clock);
    let usdc_price = build_demo_usdc_price_info_object(&mut scenario, &clock);

    // Deposit 1 BTC worth $50k
    mm.deposit<BTC, USDC, BTC>(
        &registry,
        &btc_price,
        &usdc_price,
        mint_coin<BTC>(btc_multiplier(), scenario.ctx()),
        &clock,
        scenario.ctx(),
    );

    // Borrow $20k (40% LTV initially)
    mm.borrow_quote<BTC, USDC>(
        &registry,
        &mut usdc_pool,
        &btc_price,
        &usdc_price,
        &pool,
        20_000_000000,
        &clock,
        scenario.ctx(),
    );

    // Initial risk ratio: $50k / $20k = 2.5 (250%)

    // BTC price increases to $60k
    advance_time(&mut clock, 1000);
    let btc_price_increased = build_btc_price_info_object(&mut scenario, 60000, &clock);

    // Try withdrawing - should succeed as risk ratio improved to $60k / $20k = 3.0 (300%)
    let withdrawn = mm.withdraw<BTC, USDC, BTC>(
        &registry,
        &btc_pool,
        &usdc_pool,
        &btc_price_increased,
        &usdc_price,
        &pool,
        btc_multiplier() / 10, // Withdraw 0.1 BTC
        &clock,
        scenario.ctx(),
    );

    destroy(withdrawn);

    // BTC price drops to $35k
    advance_time(&mut clock, 1000);
    let btc_price_dropped = build_btc_price_info_object(&mut scenario, 35000, &clock);

    // Risk ratio now: 0.9 BTC * $35k / $20k = $31.5k / $20k = 1.575 (157.5%)
    // Still above liquidation threshold (120%) but close

    return_shared_2!(btc_pool, usdc_pool);
    return_shared_2!(mm, pool);
    destroy_3!(btc_price, usdc_price, btc_price_increased);
    destroy(btc_price_dropped);
    cleanup_margin_test(registry, admin_cap, maintainer_cap, clock, scenario);
}

// === Position Limits Tests ===

#[test, expected_failure(abort_code = margin_manager::EBorrowRiskRatioExceeded)]
fun test_max_leverage_enforcement() {
    let (mut scenario, clock, admin_cap, maintainer_cap) = setup_margin_registry();

    let usdc_pool_id = create_margin_pool<USDC>(
        &mut scenario,
        &maintainer_cap,
        default_protocol_config(),
        &clock,
    );
    let usdt_pool_id = create_margin_pool<USDT>(
        &mut scenario,
        &maintainer_cap,
        default_protocol_config(),
        &clock,
    );

    let (usdc_pool_cap, usdt_pool_cap) = get_margin_pool_caps(&mut scenario, usdc_pool_id);

    let (pool_id, registry_id) = create_pool_for_testing<USDC, USDT>(&mut scenario);
    scenario.next_tx(test_constants::admin());
    let mut registry = scenario.take_shared<MarginRegistry>();
    enable_deepbook_margin_on_pool<USDC, USDT>(
        pool_id,
        &mut registry,
        &admin_cap,
        &clock,
        &mut scenario,
    );
    return_shared(registry);

    scenario.next_tx(test_constants::admin());
    let mut usdt_pool = scenario.take_shared_by_id<MarginPool<USDT>>(usdt_pool_id);
    let mut registry = scenario.take_shared<MarginRegistry>();
    let supplier_cap = margin_pool::mint_supplier_cap(&registry, &clock, scenario.ctx());

    usdt_pool.supply(
        &registry,
        &supplier_cap,
        mint_coin<USDT>(10_000_000 * test_constants::usdt_multiplier(), scenario.ctx()),
        option::none(),
        &clock,
    );
    usdt_pool.enable_deepbook_pool_for_loan(&registry, pool_id, &usdt_pool_cap, &clock);

    return_shared(usdt_pool);
    return_to_sender_2!(&scenario, usdc_pool_cap, usdt_pool_cap);

    scenario.next_tx(test_constants::user1());
    let pool = scenario.take_shared<Pool<USDC, USDT>>();
    let deepbook_registry = scenario.take_shared_by_id<Registry>(registry_id);
    margin_manager::new<USDC, USDT>(
        &pool,
        &deepbook_registry,
        &mut registry,
        &clock,
        scenario.ctx(),
    );
    return_shared(deepbook_registry);

    scenario.next_tx(test_constants::user1());
    let mut mm = scenario.take_shared<MarginManager<USDC, USDT>>();
    let mut usdt_pool = scenario.take_shared_by_id<MarginPool<USDT>>(usdt_pool_id);
    let usdc_price = build_demo_usdc_price_info_object(&mut scenario, &clock);
    let usdt_price = build_demo_usdt_price_info_object(&mut scenario, &clock);

    // Deposit small collateral
    mm.deposit<USDC, USDT, USDC>(
        &registry,
        &usdc_price,
        &usdt_price,
        mint_coin<USDC>(1_000 * test_constants::usdc_multiplier(), scenario.ctx()),
        &clock,
        scenario.ctx(),
    );

    // Try to borrow beyond max leverage (would require > 10x leverage)
    let excessive_borrow = 10_000 * test_constants::usdt_multiplier();
    // This should fail due to exceeding max leverage
    mm.borrow_quote<USDC, USDT>(
        &registry,
        &mut usdt_pool,
        &usdc_price,
        &usdt_price,
        &pool,
        excessive_borrow,
        &clock,
        scenario.ctx(),
    );

    abort
}

#[test, expected_failure(abort_code = margin_pool::EBorrowAmountTooLow)]
fun test_min_position_size_requirement() {
    let (mut scenario, clock, admin_cap, maintainer_cap) = setup_margin_registry();

    let usdc_pool_id = create_margin_pool<USDC>(
        &mut scenario,
        &maintainer_cap,
        default_protocol_config(),
        &clock,
    );
    let usdt_pool_id = create_margin_pool<USDT>(
        &mut scenario,
        &maintainer_cap,
        default_protocol_config(),
        &clock,
    );

    let (usdc_pool_cap, usdt_pool_cap) = get_margin_pool_caps(&mut scenario, usdc_pool_id);

    let (pool_id, registry_id) = create_pool_for_testing<USDC, USDT>(&mut scenario);
    scenario.next_tx(test_constants::admin());
    let mut registry = scenario.take_shared<MarginRegistry>();
    enable_deepbook_margin_on_pool<USDC, USDT>(
        pool_id,
        &mut registry,
        &admin_cap,
        &clock,
        &mut scenario,
    );
    return_shared(registry);

    scenario.next_tx(test_constants::admin());
    let mut usdt_pool = scenario.take_shared_by_id<MarginPool<USDT>>(usdt_pool_id);
    let mut registry = scenario.take_shared<MarginRegistry>();

    let usdt_supplier_cap = test_helpers::supply_to_pool(
        &mut usdt_pool,
        &registry,
        1_000_000 * test_constants::usdt_multiplier(),
        &clock,
        scenario.ctx(),
    );
    usdt_pool.enable_deepbook_pool_for_loan(&registry, pool_id, &usdt_pool_cap, &clock);

    destroy(usdt_supplier_cap);
    return_shared(usdt_pool);
    return_to_sender_2!(&scenario, usdc_pool_cap, usdt_pool_cap);

    scenario.next_tx(test_constants::user1());
    let pool = scenario.take_shared<Pool<USDC, USDT>>();
    let deepbook_registry = scenario.take_shared_by_id<Registry>(registry_id);
    margin_manager::new<USDC, USDT>(
        &pool,
        &deepbook_registry,
        &mut registry,
        &clock,
        scenario.ctx(),
    );
    return_shared(deepbook_registry);

    scenario.next_tx(test_constants::user1());
    let mut mm = scenario.take_shared<MarginManager<USDC, USDT>>();
    let mut usdt_pool = scenario.take_shared_by_id<MarginPool<USDT>>(usdt_pool_id);
    let usdc_price = build_demo_usdc_price_info_object(&mut scenario, &clock);
    let usdt_price = build_demo_usdt_price_info_object(&mut scenario, &clock);

    mm.deposit<USDC, USDT, USDC>(
        &registry,
        &usdc_price,
        &usdt_price,
        mint_coin<USDC>(10_000 * test_constants::usdc_multiplier(), scenario.ctx()),
        &clock,
        scenario.ctx(),
    );

    // Try to borrow below minimum position size (default min_borrow is 10 * PRECISION_DECIMAL_9)
    let tiny_borrow = 1; // 1 mist, way below minimum
    mm.borrow_quote<USDC, USDT>(
        &registry,
        &mut usdt_pool,
        &usdc_price,
        &usdt_price,
        &pool,
        tiny_borrow,
        &clock,
        scenario.ctx(),
    );

    // This should never be reached due to expected failure
    return_shared_2!(usdt_pool, pool);
    destroy_2!(usdc_price, usdt_price);
    return_shared(mm);
    cleanup_margin_test(registry, admin_cap, maintainer_cap, clock, scenario);
}

#[test]
fun test_repayment_rounding() {
    let (mut scenario, mut clock, admin_cap, maintainer_cap) = setup_margin_registry();

    let usdc_pool_id = create_margin_pool<USDC>(
        &mut scenario,
        &maintainer_cap,
        default_protocol_config(),
        &clock,
    );
    let usdt_pool_id = create_margin_pool<USDT>(
        &mut scenario,
        &maintainer_cap,
        default_protocol_config(),
        &clock,
    );

    let (usdc_pool_cap, usdt_pool_cap) = get_margin_pool_caps(&mut scenario, usdc_pool_id);

    let (pool_id, registry_id) = create_pool_for_testing<USDC, USDT>(&mut scenario);
    scenario.next_tx(test_constants::admin());
    let mut registry = scenario.take_shared<MarginRegistry>();
    enable_deepbook_margin_on_pool<USDC, USDT>(
        pool_id,
        &mut registry,
        &admin_cap,
        &clock,
        &mut scenario,
    );
    return_shared(registry);

    scenario.next_tx(test_constants::admin());
    let mut usdc_pool = scenario.take_shared_by_id<MarginPool<USDC>>(usdc_pool_id);
    let mut usdt_pool = scenario.take_shared_by_id<MarginPool<USDT>>(usdt_pool_id);
    let mut registry = scenario.take_shared<MarginRegistry>();

    let usdc_supplier_cap = test_helpers::supply_to_pool(
        &mut usdc_pool,
        &registry,
        1_000_000 * test_constants::usdc_multiplier(),
        &clock,
        scenario.ctx(),
    );
    let usdt_supplier_cap = test_helpers::supply_to_pool(
        &mut usdt_pool,
        &registry,
        1_000_000 * test_constants::usdt_multiplier(),
        &clock,
        scenario.ctx(),
    );

    usdc_pool.enable_deepbook_pool_for_loan(&registry, pool_id, &usdc_pool_cap, &clock);
    usdt_pool.enable_deepbook_pool_for_loan(&registry, pool_id, &usdt_pool_cap, &clock);

    destroy(usdc_supplier_cap);
    destroy(usdt_supplier_cap);
    return_shared_2!(usdc_pool, usdt_pool);
    return_to_sender_2!(&scenario, usdc_pool_cap, usdt_pool_cap);

    scenario.next_tx(test_constants::user1());
    let pool = scenario.take_shared<Pool<USDC, USDT>>();
    let deepbook_registry = scenario.take_shared_by_id<Registry>(registry_id);
    margin_manager::new<USDC, USDT>(
        &pool,
        &deepbook_registry,
        &mut registry,
        &clock,
        scenario.ctx(),
    );
    return_shared(deepbook_registry);

    scenario.next_tx(test_constants::user1());
    let mut mm = scenario.take_shared<MarginManager<USDC, USDT>>();
    let mut usdt_pool = scenario.take_shared_by_id<MarginPool<USDT>>(usdt_pool_id);
    let usdc_price = build_demo_usdc_price_info_object(&mut scenario, &clock);
    let usdt_price = build_demo_usdt_price_info_object(&mut scenario, &clock);

    // Setup position with debt
    mm.deposit<USDC, USDT, USDC>(
        &registry,
        &usdc_price,
        &usdt_price,
        mint_coin<USDC>(20_000 * test_constants::usdc_multiplier(), scenario.ctx()),
        &clock,
        scenario.ctx(),
    );

    mm.borrow_quote<USDC, USDT>(
        &registry,
        &mut usdt_pool,
        &usdc_price,
        &usdt_price,
        &pool,
        5_000 * test_constants::usdt_multiplier(),
        &clock,
        scenario.ctx(),
    );

    advance_time(&mut clock, 1000 * 100); // 100 seconds later

    destroy_2!(usdc_price, usdt_price);

    // Recreate price objects after time advance (they become stale)
    // Create new ones in a new transaction to avoid stale price errors
    scenario.next_tx(test_constants::user1());
    let usdc_price = build_demo_usdc_price_info_object(&mut scenario, &clock);
    let usdt_price = build_demo_usdt_price_info_object(&mut scenario, &clock);

    // Partial repayment
    mm.deposit<USDC, USDT, USDT>(
        &registry,
        &usdc_price,
        &usdt_price,
        mint_coin<USDT>(2_000 * test_constants::usdt_multiplier(), scenario.ctx()),
        &clock,
        scenario.ctx(),
    );

    let repaid_amount = mm.repay_quote<USDC, USDT>(
        &registry,
        &mut usdt_pool,
        option::some(2_000 * test_constants::usdt_multiplier()),
        &clock,
        scenario.ctx(),
    );

    assert!(repaid_amount == 2_000 * test_constants::usdt_multiplier());

    // Full repayment
    mm.deposit<USDC, USDT, USDT>(
        &registry,
        &usdc_price,
        &usdt_price,
        mint_coin<USDT>(5_000 * test_constants::usdt_multiplier(), scenario.ctx()),
        &clock,
        scenario.ctx(),
    );

    let final_repaid = mm.repay_quote<USDC, USDT>(
        &registry,
        &mut usdt_pool,
        option::none(), // Repay all
        &clock,
        scenario.ctx(),
    );

    assert!(final_repaid > 0);
    assert!(mm.borrowed_quote_shares() == 0);

    return_shared_2!(usdt_pool, pool);
    destroy_2!(usdc_price, usdt_price);
    return_shared(mm);
    cleanup_margin_test(registry, admin_cap, maintainer_cap, clock, scenario);
}

#[test]
fun test_asset_rebalancing_between_pools() {
    let (mut scenario, clock, admin_cap, maintainer_cap) = setup_margin_registry();

    let usdc_pool_id = create_margin_pool<USDC>(
        &mut scenario,
        &maintainer_cap,
        default_protocol_config(),
        &clock,
    );
    let usdt_pool_id = create_margin_pool<USDT>(
        &mut scenario,
        &maintainer_cap,
        default_protocol_config(),
        &clock,
    );

    let (usdc_pool_cap, usdt_pool_cap) = get_margin_pool_caps(&mut scenario, usdc_pool_id);

    let (pool_id, registry_id) = create_pool_for_testing<USDC, USDT>(&mut scenario);
    scenario.next_tx(test_constants::admin());
    let mut registry = scenario.take_shared<MarginRegistry>();
    enable_deepbook_margin_on_pool<USDC, USDT>(
        pool_id,
        &mut registry,
        &admin_cap,
        &clock,
        &mut scenario,
    );
    return_shared(registry);

    scenario.next_tx(test_constants::admin());
    let mut usdc_pool = scenario.take_shared_by_id<MarginPool<USDC>>(usdc_pool_id);
    let mut usdt_pool = scenario.take_shared_by_id<MarginPool<USDT>>(usdt_pool_id);
    let mut registry = scenario.take_shared<MarginRegistry>();

    let usdc_supplier_cap = test_helpers::supply_to_pool(
        &mut usdc_pool,
        &registry,
        1_000_000 * test_constants::usdc_multiplier(),
        &clock,
        scenario.ctx(),
    );
    let usdt_supplier_cap = test_helpers::supply_to_pool(
        &mut usdt_pool,
        &registry,
        1_000_000 * test_constants::usdt_multiplier(),
        &clock,
        scenario.ctx(),
    );

    usdc_pool.enable_deepbook_pool_for_loan(&registry, pool_id, &usdc_pool_cap, &clock);
    usdt_pool.enable_deepbook_pool_for_loan(&registry, pool_id, &usdt_pool_cap, &clock);

    destroy(usdc_supplier_cap);
    destroy(usdt_supplier_cap);
    return_shared_2!(usdc_pool, usdt_pool);
    return_to_sender_2!(&scenario, usdc_pool_cap, usdt_pool_cap);

    scenario.next_tx(test_constants::user1());
    let pool = scenario.take_shared<Pool<USDC, USDT>>();
    let deepbook_registry = scenario.take_shared_by_id<Registry>(registry_id);
    margin_manager::new<USDC, USDT>(
        &pool,
        &deepbook_registry,
        &mut registry,
        &clock,
        scenario.ctx(),
    );
    return_shared(deepbook_registry);

    scenario.next_tx(test_constants::user1());
    let mut mm = scenario.take_shared<MarginManager<USDC, USDT>>();

    // Get margin pools for withdraw API
    let usdc_pool = scenario.take_shared_by_id<MarginPool<USDC>>(usdc_pool_id);
    let usdt_pool = scenario.take_shared_by_id<MarginPool<USDT>>(usdt_pool_id);
    let usdc_price = build_demo_usdc_price_info_object(&mut scenario, &clock);
    let usdt_price = build_demo_usdt_price_info_object(&mut scenario, &clock);

    // Deposit assets in both base and quote
    mm.deposit<USDC, USDT, USDC>(
        &registry,
        &usdc_price,
        &usdt_price,
        mint_coin<USDC>(10_000 * test_constants::usdc_multiplier(), scenario.ctx()),
        &clock,
        scenario.ctx(),
    );
    mm.deposit<USDC, USDT, USDT>(
        &registry,
        &usdc_price,
        &usdt_price,
        mint_coin<USDT>(10_000 * test_constants::usdt_multiplier(), scenario.ctx()),
        &clock,
        scenario.ctx(),
    );

    // Withdraw from one type (using new API)
    let usdc_withdrawn = mm.withdraw<USDC, USDT, USDC>(
        &registry,
        &usdc_pool,
        &usdt_pool,
        &usdc_price,
        &usdt_price,
        &pool,
        5_000 * test_constants::usdc_multiplier(),
        &clock,
        scenario.ctx(),
    );

    // No debt, so withdrawal should succeed
    assert!(usdc_withdrawn.value() == 5_000 * test_constants::usdc_multiplier());

    // Deposit back different asset
    mm.deposit<USDC, USDT, USDT>(
        &registry,
        &usdc_price,
        &usdt_price,
        mint_coin<USDT>(5_000 * test_constants::usdt_multiplier(), scenario.ctx()),
        &clock,
        scenario.ctx(),
    );

    destroy(usdc_withdrawn);
    destroy_2!(usdc_price, usdt_price);
    return_shared_3!(usdc_pool, usdt_pool, pool);
    return_shared(mm);
    cleanup_margin_test(registry, admin_cap, maintainer_cap, clock, scenario);
}

#[test]
fun test_risk_ratio_returns_max_when_no_loan_but_has_assets() {
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
    let pool = scenario.take_shared<Pool<BTC, USDC>>();
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
    let btc_pool = scenario.take_shared_by_id<MarginPool<BTC>>(btc_pool_id);
    let usdc_pool = scenario.take_shared_by_id<MarginPool<USDC>>(usdc_pool_id);
    let btc_price = build_btc_price_info_object(&mut scenario, 50000, &clock);
    let usdc_price = build_demo_usdc_price_info_object(&mut scenario, &clock);

    // Deposit 1 BTC worth $50k (but don't borrow anything)
    mm.deposit<BTC, USDC, BTC>(
        &registry,
        &btc_price,
        &usdc_price,
        mint_coin<BTC>(btc_multiplier(), scenario.ctx()),
        &clock,
        scenario.ctx(),
    );

    assert!(mm.borrowed_base_shares() == 0);
    assert!(mm.borrowed_quote_shares() == 0);

    let risk_ratio = mm.risk_ratio<BTC, USDC>(
        &registry,
        &btc_price,
        &usdc_price,
        &pool,
        &btc_pool,
        &usdc_pool,
        &clock,
    );

    assert!(risk_ratio == margin_constants::max_risk_ratio());

    destroy_2!(btc_price, usdc_price);
    return_shared_3!(btc_pool, usdc_pool, pool);
    return_shared(mm);
    cleanup_margin_test(registry, admin_cap, maintainer_cap, clock, scenario);
}

#[test]
fun test_risk_ratio_returns_max_when_completely_empty() {
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

    let btc_price = build_btc_price_info_object(&mut scenario, 50000, &clock);
    let usdc_price = build_demo_usdc_price_info_object(&mut scenario, &clock);

    scenario.next_tx(test_constants::user1());
    let pool = scenario.take_shared<Pool<BTC, USDC>>();
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
    let mm = scenario.take_shared<MarginManager<BTC, USDC>>();
    let btc_pool = scenario.take_shared_by_id<MarginPool<BTC>>(btc_pool_id);
    let usdc_pool = scenario.take_shared_by_id<MarginPool<USDC>>(usdc_pool_id);

    assert!(mm.borrowed_base_shares() == 0);
    assert!(mm.borrowed_quote_shares() == 0);

    let (base_assets, quote_assets) = mm.calculate_assets<BTC, USDC>(&pool);
    assert!(base_assets == 0);
    assert!(quote_assets == 0);

    let risk_ratio = mm.risk_ratio<BTC, USDC>(
        &registry,
        &btc_price,
        &usdc_price,
        &pool,
        &btc_pool,
        &usdc_pool,
        &clock,
    );

    assert!(risk_ratio == margin_constants::max_risk_ratio());

    destroy_2!(btc_price, usdc_price);
    return_shared_3!(btc_pool, usdc_pool, pool);
    return_shared(mm);
    cleanup_margin_test(registry, admin_cap, maintainer_cap, clock, scenario);
}

#[test]
fun test_borrow_at_exact_min_risk_ratio_no_rounding_issues() {
    let (mut scenario, mut clock, admin_cap, maintainer_cap) = setup_margin_registry();

    clock.set_for_testing(1000000);

    // Create USDC margin pool
    let usdc_pool_id = create_margin_pool<USDC>(
        &mut scenario,
        &maintainer_cap,
        default_protocol_config(),
        &clock,
    );

    // Create USDT margin pool (needed for the DeepBook pool)
    let usdt_pool_id = create_margin_pool<USDT>(
        &mut scenario,
        &maintainer_cap,
        default_protocol_config(),
        &clock,
    );

    // Create DeepBook pool
    let (pool_id, registry_id) = create_pool_for_testing<USDT, USDC>(&mut scenario);
    scenario.next_tx(test_constants::admin());
    let mut registry = scenario.take_shared<MarginRegistry>();
    enable_deepbook_margin_on_pool<USDT, USDC>(
        pool_id,
        &mut registry,
        &admin_cap,
        &clock,
        &mut scenario,
    );
    return_shared(registry);

    // Fund the USDC margin pool with exactly 10 USDC (10 * 10^6)
    scenario.next_tx(test_constants::admin());
    let (usdc_pool_cap, usdt_pool_cap) = get_margin_pool_caps(&mut scenario, usdc_pool_id);
    let mut usdc_pool = scenario.take_shared_by_id<MarginPool<USDC>>(usdc_pool_id);
    let mut usdt_pool = scenario.take_shared_by_id<MarginPool<USDT>>(usdt_pool_id);
    let registry = scenario.take_shared<MarginRegistry>();
    let supplier_cap = margin_pool::mint_supplier_cap(&registry, &clock, scenario.ctx());

    usdc_pool.supply(
        &registry,
        &supplier_cap,
        mint_coin<USDC>(10 * test_constants::usdc_multiplier(), scenario.ctx()),
        option::none(),
        &clock,
    );

    // Also fund USDT pool for completeness
    usdt_pool.supply(
        &registry,
        &supplier_cap,
        mint_coin<USDT>(10_000 * test_constants::usdt_multiplier(), scenario.ctx()),
        option::none(),
        &clock,
    );

    usdc_pool.enable_deepbook_pool_for_loan(&registry, pool_id, &usdc_pool_cap, &clock);
    usdt_pool.enable_deepbook_pool_for_loan(&registry, pool_id, &usdt_pool_cap, &clock);

    return_shared_2!(usdc_pool, usdt_pool);
    return_shared(registry);
    scenario.return_to_sender(usdt_pool_cap);
    scenario.return_to_sender(usdc_pool_cap);
    destroy(supplier_cap);

    // User creates margin manager
    scenario.next_tx(test_constants::user1());
    let mut registry = scenario.take_shared<MarginRegistry>();
    let pool = scenario.take_shared<Pool<USDT, USDC>>();
    let deepbook_registry = scenario.take_shared_by_id<Registry>(registry_id);
    margin_manager::new<USDT, USDC>(
        &pool,
        &deepbook_registry,
        &mut registry,
        &clock,
        scenario.ctx(),
    );
    return_shared_2!(deepbook_registry, pool);
    return_shared(registry);

    // User deposits exactly 1 USDC (1 * 10^6)
    scenario.next_tx(test_constants::user1());
    let mut mm = scenario.take_shared<MarginManager<USDT, USDC>>();
    let registry = scenario.take_shared<MarginRegistry>();
    let usdc_price = build_demo_usdc_price_info_object(&mut scenario, &clock);
    let usdt_price = build_demo_usdt_price_info_object(&mut scenario, &clock);

    let deposit_coin = mint_coin<USDC>(1 * test_constants::usdc_multiplier(), scenario.ctx());
    mm.deposit<USDT, USDC, USDC>(
        &registry,
        &usdt_price,
        &usdc_price,
        deposit_coin,
        &clock,
        scenario.ctx(),
    );
    destroy_2!(usdc_price, usdt_price);
    return_shared_2!(mm, registry);

    // User borrows exactly 4 USDC (4 * 10^6)
    // Risk ratio should be (1 + 4) / 4 = 1.25, exactly at the minimum
    scenario.next_tx(test_constants::user1());
    let mut mm = scenario.take_shared<MarginManager<USDT, USDC>>();
    let mut usdc_pool = scenario.take_shared_by_id<MarginPool<USDC>>(usdc_pool_id);
    let registry = scenario.take_shared<MarginRegistry>();
    let pool = scenario.take_shared<Pool<USDT, USDC>>();
    let usdc_price = build_demo_usdc_price_info_object(&mut scenario, &clock);
    let usdt_price = build_demo_usdt_price_info_object(&mut scenario, &clock);

    mm.borrow_quote<USDT, USDC>(
        &registry,
        &mut usdc_pool,
        &usdt_price,
        &usdc_price,
        &pool,
        4 * test_constants::usdc_multiplier(), // 4 USDC
        &clock,
        scenario.ctx(),
    );

    // Verify risk ratio is exactly at the minimum (1.25 with 9 decimals = 1_250_000_000)
    let base_pool = scenario.take_shared_by_id<MarginPool<USDT>>(usdt_pool_id);
    let risk_ratio = mm.risk_ratio(
        &registry,
        &usdt_price,
        &usdc_price,
        &pool,
        &base_pool,
        &usdc_pool,
        &clock,
    );

    // Risk ratio should be exactly the minimum borrow risk ratio (1.25)
    assert!(risk_ratio == test_constants::min_borrow_risk_ratio());

    return_shared(base_pool);
    destroy_2!(usdc_price, usdt_price);
    return_shared_3!(usdc_pool, pool, mm);
    cleanup_margin_test(registry, admin_cap, maintainer_cap, clock, scenario);
}

#[test]
fun test_borrow_at_exact_min_risk_ratio_with_custom_price() {
    let (mut scenario, mut clock, admin_cap, maintainer_cap) = setup_margin_registry();

    clock.set_for_testing(1000000);

    // Create USDC margin pool
    let usdc_pool_id = create_margin_pool<USDC>(
        &mut scenario,
        &maintainer_cap,
        default_protocol_config(),
        &clock,
    );

    // Create USDT margin pool (needed for the DeepBook pool)
    let usdt_pool_id = create_margin_pool<USDT>(
        &mut scenario,
        &maintainer_cap,
        default_protocol_config(),
        &clock,
    );

    // Create DeepBook pool
    let (pool_id, registry_id) = create_pool_for_testing<USDT, USDC>(&mut scenario);
    scenario.next_tx(test_constants::admin());
    let mut registry = scenario.take_shared<MarginRegistry>();
    enable_deepbook_margin_on_pool<USDT, USDC>(
        pool_id,
        &mut registry,
        &admin_cap,
        &clock,
        &mut scenario,
    );
    return_shared(registry);

    // Fund the USDC margin pool with exactly 10 USDC (10 * 10^6)
    scenario.next_tx(test_constants::admin());
    let (usdc_pool_cap, usdt_pool_cap) = get_margin_pool_caps(&mut scenario, usdc_pool_id);
    let mut usdc_pool = scenario.take_shared_by_id<MarginPool<USDC>>(usdc_pool_id);
    let mut usdt_pool = scenario.take_shared_by_id<MarginPool<USDT>>(usdt_pool_id);
    let registry = scenario.take_shared<MarginRegistry>();
    let supplier_cap = margin_pool::mint_supplier_cap(&registry, &clock, scenario.ctx());

    usdc_pool.supply(
        &registry,
        &supplier_cap,
        mint_coin<USDC>(10 * test_constants::usdc_multiplier(), scenario.ctx()),
        option::none(),
        &clock,
    );

    // Also fund USDT pool for completeness
    usdt_pool.supply(
        &registry,
        &supplier_cap,
        mint_coin<USDT>(10_000 * test_constants::usdt_multiplier(), scenario.ctx()),
        option::none(),
        &clock,
    );

    usdc_pool.enable_deepbook_pool_for_loan(&registry, pool_id, &usdc_pool_cap, &clock);
    usdt_pool.enable_deepbook_pool_for_loan(&registry, pool_id, &usdt_pool_cap, &clock);

    return_shared_2!(usdc_pool, usdt_pool);
    return_shared(registry);
    scenario.return_to_sender(usdt_pool_cap);
    scenario.return_to_sender(usdc_pool_cap);
    destroy(supplier_cap);

    // User creates margin manager
    scenario.next_tx(test_constants::user1());
    let mut registry = scenario.take_shared<MarginRegistry>();
    let pool = scenario.take_shared<Pool<USDT, USDC>>();
    let deepbook_registry = scenario.take_shared_by_id<Registry>(registry_id);
    margin_manager::new<USDT, USDC>(
        &pool,
        &deepbook_registry,
        &mut registry,
        &clock,
        scenario.ctx(),
    );
    return_shared_2!(deepbook_registry, pool);
    return_shared(registry);

    // User deposits exactly 1 USDC (1 * 10^6)
    scenario.next_tx(test_constants::user1());
    let mut mm = scenario.take_shared<MarginManager<USDT, USDC>>();
    let registry = scenario.take_shared<MarginRegistry>();
    let usdc_price = build_demo_usdc_price_info_object(&mut scenario, &clock);
    let usdt_price = build_demo_usdt_price_info_object(&mut scenario, &clock);

    let deposit_coin = mint_coin<USDC>(1 * test_constants::usdc_multiplier(), scenario.ctx());
    mm.deposit<USDT, USDC, USDC>(
        &registry,
        &usdt_price,
        &usdc_price,
        deposit_coin,
        &clock,
        scenario.ctx(),
    );
    destroy_2!(usdc_price, usdt_price);
    return_shared_2!(mm, registry);

    // User borrows exactly 4 USDC (4 * 10^6)
    // With USDC at 0.99984495 instead of 1.00, verify the operation still works
    scenario.next_tx(test_constants::user1());
    let mut mm = scenario.take_shared<MarginManager<USDT, USDC>>();
    let mut usdc_pool = scenario.take_shared_by_id<MarginPool<USDC>>(usdc_pool_id);
    let registry = scenario.take_shared<MarginRegistry>();
    let pool = scenario.take_shared<Pool<USDT, USDC>>();
    let usdc_price = test_helpers::build_demo_usdc_price_info_object_with_price(
        &mut scenario,
        99984495, // $0.99984495 with 8 decimals
        &clock,
    );
    let usdt_price = build_demo_usdt_price_info_object(&mut scenario, &clock);

    mm.borrow_quote<USDT, USDC>(
        &registry,
        &mut usdc_pool,
        &usdt_price,
        &usdc_price,
        &pool,
        4 * test_constants::usdc_multiplier(), // 4 USDC
        &clock,
        scenario.ctx(),
    );

    // Verify risk ratio
    let base_pool = scenario.take_shared_by_id<MarginPool<USDT>>(usdt_pool_id);
    let risk_ratio = mm.risk_ratio(
        &registry,
        &usdt_price,
        &usdc_price,
        &pool,
        &base_pool,
        &usdc_pool,
        &clock,
    );

    // Risk ratio should still be approximately at the minimum
    // With the price difference, it might be slightly different
    // USDC at 0.99984495: (1 * 0.99984495 + 4 * 0.99984495) / (4 * 0.99984495) = 5/4 = 1.25
    // The ratio should still be exactly 1.25 since both assets use the same price
    assert!(risk_ratio == test_constants::min_borrow_risk_ratio());

    return_shared(base_pool);
    destroy_2!(usdc_price, usdt_price);
    return_shared_3!(usdc_pool, pool, mm);
    cleanup_margin_test(registry, admin_cap, maintainer_cap, clock, scenario);
}

#[test, expected_failure(abort_code = margin_manager::ERepayAmountTooLow)]
fun test_liquidate_fails_with_too_low_repay_amount() {
    let (
        mut scenario,
        mut clock,
        _admin_cap,
        _maintainer_cap,
        _btc_pool_id,
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
    let btc_price = build_btc_price_info_object(&mut scenario, 50000, &clock);
    let usdc_price = build_demo_usdc_price_info_object(&mut scenario, &clock);

    // Deposit 1 BTC worth $50k
    mm.deposit<BTC, USDC, BTC>(
        &registry,
        &btc_price,
        &usdc_price,
        mint_coin<BTC>(btc_multiplier(), scenario.ctx()),
        &clock,
        scenario.ctx(),
    );

    // Borrow $40k USDC (risk ratio = 50k/40k = 1.25)
    mm.borrow_quote<BTC, USDC>(
        &registry,
        &mut usdc_pool,
        &btc_price,
        &usdc_price,
        &pool,
        40_000_000_000,
        &clock,
        scenario.ctx(),
    );

    // Advance time by 1 day to accrue interest
    advance_time(&mut clock, 86_400_000); // 1 day in milliseconds

    // Drop BTC price to $3k to make position underwater and liquidatable
    // Assets: 1 BTC at $3k + $40k USDC = $43k
    // Debt: $40k+ (with interest)
    // Risk ratio: ~$43k / ~$40k = ~1.075 (107.5%) < 110% liquidation threshold
    // Create new price object AFTER time advancement to ensure it's fresh
    destroy(btc_price);
    destroy(usdc_price);
    scenario.next_tx(test_constants::admin());
    let btc_price_dropped = build_btc_price_info_object(&mut scenario, 3000, &clock);
    let usdc_price_fresh = build_demo_usdc_price_info_object(&mut scenario, &clock);

    // Try to liquidate with an extremely small repay amount (1 unit)
    // This should fail with ERepayAmountTooLow
    scenario.next_tx(test_constants::liquidator());
    let debt_coin = mint_coin<USDC>(1, scenario.ctx()); // Just 1 unit - way too low

    let (base_coin, quote_coin, remaining_debt) = mm.liquidate<BTC, USDC, USDC>(
        &registry,
        &btc_price_dropped,
        &usdc_price_fresh,
        &mut usdc_pool,
        &mut pool,
        debt_coin,
        &clock,
        scenario.ctx(),
    );

    // Should never reach here
    destroy_3!(base_coin, quote_coin, remaining_debt);
    abort (0)
}

#[test]
fun test_unregister_margin_manager() {
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
    let (pool_id, registry_id) = create_pool_for_testing<USDC, USDT>(&mut scenario);
    scenario.next_tx(test_constants::admin());
    let mut registry = scenario.take_shared<MarginRegistry>();
    enable_deepbook_margin_on_pool<USDC, USDT>(
        pool_id,
        &mut registry,
        &admin_cap,
        &clock,
        &mut scenario,
    );
    return_shared(registry);

    // Create first margin manager
    scenario.next_tx(test_constants::user1());
    let pool = scenario.take_shared<Pool<USDC, USDT>>();
    let mut registry = scenario.take_shared<MarginRegistry>();
    let deepbook_registry = scenario.take_shared_by_id<Registry>(registry_id);
    let manager1_id = margin_manager::new<USDC, USDT>(
        &pool,
        &deepbook_registry,
        &mut registry,
        &clock,
        scenario.ctx(),
    );
    return_shared_3!(deepbook_registry, pool, registry);

    // Create second margin manager
    scenario.next_tx(test_constants::user1());
    let pool = scenario.take_shared<Pool<USDC, USDT>>();
    let mut registry = scenario.take_shared<MarginRegistry>();
    let deepbook_registry = scenario.take_shared_by_id<Registry>(registry_id);
    let manager2_id = margin_manager::new<USDC, USDT>(
        &pool,
        &deepbook_registry,
        &mut registry,
        &clock,
        scenario.ctx(),
    );
    return_shared_3!(deepbook_registry, pool, registry);

    // Verify both are registered
    scenario.next_tx(test_constants::user1());
    let registry = scenario.take_shared<MarginRegistry>();
    let manager_ids = margin_registry::get_margin_manager_ids(&registry, test_constants::user1());
    assert!(manager_ids.length() == 2);
    assert!(manager_ids.contains(&manager1_id));
    assert!(manager_ids.contains(&manager2_id));
    return_shared(registry);

    // Unregister first manager
    scenario.next_tx(test_constants::user1());
    let mut mm1 = scenario.take_shared_by_id<MarginManager<USDC, USDT>>(manager1_id);
    let mut registry = scenario.take_shared<MarginRegistry>();
    margin_manager::unregister_margin_manager<USDC, USDT>(
        &mut mm1,
        &mut registry,
        scenario.ctx(),
    );
    return_shared_2!(mm1, registry);

    // Verify only second manager remains
    scenario.next_tx(test_constants::user1());
    let registry = scenario.take_shared<MarginRegistry>();
    let manager_ids = margin_registry::get_margin_manager_ids(&registry, test_constants::user1());
    assert!(manager_ids.length() == 1);
    assert!(!manager_ids.contains(&manager1_id));
    assert!(manager_ids.contains(&manager2_id));
    cleanup_margin_test(registry, admin_cap, maintainer_cap, clock, scenario);
}

#[test]
#[expected_failure(abort_code = margin_manager::EPoolNotEnabledForMarginTrading)]
fun test_borrow_base_fails_when_pool_disabled() {
    let (
        mut scenario,
        clock,
        admin_cap,
        _maintainer_cap,
        btc_pool_id,
        _usdc_pool_id,
        _pool_id,
        registry_id,
    ) = setup_btc_usd_deepbook_margin();

    // Supply liquidity to BTC pool
    scenario.next_tx(test_constants::admin());
    let mut btc_pool = scenario.take_shared_by_id<MarginPool<BTC>>(btc_pool_id);
    let registry = scenario.take_shared<MarginRegistry>();
    let supplier_cap = test_helpers::supply_to_pool(
        &mut btc_pool,
        &registry,
        100 * btc_multiplier(),
        &clock,
        scenario.ctx(),
    );
    return_shared_2!(btc_pool, registry);
    destroy(supplier_cap);

    // Create margin manager and deposit collateral
    scenario.next_tx(test_constants::user1());
    let pool = scenario.take_shared<Pool<BTC, USDC>>();
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
    return_shared_2!(pool, registry);

    scenario.next_tx(test_constants::user1());
    let mut mm = scenario.take_shared<MarginManager<BTC, USDC>>();
    let registry = scenario.take_shared<MarginRegistry>();
    let btc_price = build_btc_price_info_object(&mut scenario, 50000, &clock);
    let usdc_price = build_demo_usdc_price_info_object(&mut scenario, &clock);
    let deposit_coin = mint_coin<USDC>(
        5_000_000 * test_constants::usdc_multiplier(),
        scenario.ctx(),
    );
    mm.deposit<BTC, USDC, USDC>(
        &registry,
        &btc_price,
        &usdc_price,
        deposit_coin,
        &clock,
        scenario.ctx(),
    );
    destroy_2!(btc_price, usdc_price);
    return_shared_2!(mm, registry);

    // Admin disables the deepbook pool
    scenario.next_tx(test_constants::admin());
    let mut registry = scenario.take_shared<MarginRegistry>();
    let mut pool = scenario.take_shared<Pool<BTC, USDC>>();
    registry.disable_deepbook_pool<BTC, USDC>(&admin_cap, &mut pool, &clock);
    return_shared_2!(registry, pool);

    // User1 tries to borrow BTC - this should fail with EPoolNotEnabledForMarginTrading
    scenario.next_tx(test_constants::user1());
    let mut mm = scenario.take_shared<MarginManager<BTC, USDC>>();
    let registry = scenario.take_shared<MarginRegistry>();
    let mut btc_pool = scenario.take_shared_by_id<MarginPool<BTC>>(btc_pool_id);
    let pool = scenario.take_shared<Pool<BTC, USDC>>();
    let btc_price = build_btc_price_info_object(&mut scenario, 50000, &clock);
    let usdc_price = build_demo_usdc_price_info_object(&mut scenario, &clock);

    mm.borrow_base<BTC, USDC>(
        &registry,
        &mut btc_pool,
        &btc_price,
        &usdc_price,
        &pool,
        10 * btc_multiplier(),
        &clock,
        scenario.ctx(),
    );

    // Cleanup (unreachable due to expected failure above)
    abort 0
}

#[test]
#[expected_failure(abort_code = margin_manager::EPoolNotEnabledForMarginTrading)]
fun test_borrow_quote_fails_when_pool_disabled() {
    let (
        mut scenario,
        clock,
        admin_cap,
        _maintainer_cap,
        _btc_pool_id,
        usdc_pool_id,
        _pool_id,
        registry_id,
    ) = setup_btc_usd_deepbook_margin();

    // Supply liquidity to USDC pool
    scenario.next_tx(test_constants::admin());
    let mut usdc_pool = scenario.take_shared_by_id<MarginPool<USDC>>(usdc_pool_id);
    let registry = scenario.take_shared<MarginRegistry>();
    let supplier_cap = test_helpers::supply_to_pool(
        &mut usdc_pool,
        &registry,
        10_000_000 * test_constants::usdc_multiplier(),
        &clock,
        scenario.ctx(),
    );
    return_shared_2!(usdc_pool, registry);
    destroy(supplier_cap);

    // Create margin manager and deposit collateral
    scenario.next_tx(test_constants::user1());
    let pool = scenario.take_shared<Pool<BTC, USDC>>();
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
    return_shared_2!(pool, registry);

    scenario.next_tx(test_constants::user1());
    let mut mm = scenario.take_shared<MarginManager<BTC, USDC>>();
    let registry = scenario.take_shared<MarginRegistry>();
    let btc_price = build_btc_price_info_object(&mut scenario, 50000, &clock);
    let usdc_price = build_demo_usdc_price_info_object(&mut scenario, &clock);
    let deposit_coin = mint_coin<BTC>(
        10 * btc_multiplier(),
        scenario.ctx(),
    );
    mm.deposit<BTC, USDC, BTC>(
        &registry,
        &btc_price,
        &usdc_price,
        deposit_coin,
        &clock,
        scenario.ctx(),
    );
    destroy_2!(btc_price, usdc_price);
    return_shared_2!(mm, registry);

    // Admin disables the deepbook pool
    scenario.next_tx(test_constants::admin());
    let mut registry = scenario.take_shared<MarginRegistry>();
    let mut pool = scenario.take_shared<Pool<BTC, USDC>>();
    registry.disable_deepbook_pool<BTC, USDC>(&admin_cap, &mut pool, &clock);
    return_shared_2!(registry, pool);

    // User1 tries to borrow USDC - this should fail with EPoolNotEnabledForMarginTrading
    scenario.next_tx(test_constants::user1());
    let mut mm = scenario.take_shared<MarginManager<BTC, USDC>>();
    let registry = scenario.take_shared<MarginRegistry>();
    let mut usdc_pool = scenario.take_shared_by_id<MarginPool<USDC>>(usdc_pool_id);
    let pool = scenario.take_shared<Pool<BTC, USDC>>();
    let btc_price = build_btc_price_info_object(&mut scenario, 50000, &clock);
    let usdc_price = build_demo_usdc_price_info_object(&mut scenario, &clock);

    mm.borrow_quote<BTC, USDC>(
        &registry,
        &mut usdc_pool,
        &btc_price,
        &usdc_price,
        &pool,
        100_000 * test_constants::usdc_multiplier(),
        &clock,
        scenario.ctx(),
    );

    // Cleanup (unreachable due to expected failure above)
    abort 0
}

#[test, expected_failure(abort_code = margin_manager::EOutstandingDebt)]
fun test_unregister_margin_manager_fails_with_outstanding_base_debt() {
    let (
        mut scenario,
        clock,
        _admin_cap,
        _maintainer_cap,
        btc_pool_id,
        _usdc_pool_id,
        _pool_id,
        registry_id,
    ) = setup_btc_usd_deepbook_margin();

    // Supply liquidity to BTC pool so we can borrow
    scenario.next_tx(test_constants::admin());
    let mut btc_pool = scenario.take_shared_by_id<MarginPool<BTC>>(btc_pool_id);
    let registry = scenario.take_shared<MarginRegistry>();
    let supplier_cap = margin_pool::mint_supplier_cap(&registry, &clock, scenario.ctx());
    btc_pool.supply(
        &registry,
        &supplier_cap,
        mint_coin<BTC>(100 * btc_multiplier(), scenario.ctx()),
        option::none(),
        &clock,
    );
    return_shared_2!(btc_pool, registry);
    destroy(supplier_cap);

    // Create margin manager
    scenario.next_tx(test_constants::user1());
    let pool = scenario.take_shared<Pool<BTC, USDC>>();
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
    return_shared_2!(pool, registry);

    // Deposit collateral (USDC)
    scenario.next_tx(test_constants::user1());
    let mut mm = scenario.take_shared<MarginManager<BTC, USDC>>();
    let registry = scenario.take_shared<MarginRegistry>();
    let btc_price = build_btc_price_info_object(&mut scenario, 50000, &clock);
    let usdc_price = build_demo_usdc_price_info_object(&mut scenario, &clock);
    mm.deposit<BTC, USDC, USDC>(
        &registry,
        &btc_price,
        &usdc_price,
        mint_coin<USDC>(1_000_000 * test_constants::usdc_multiplier(), scenario.ctx()),
        &clock,
        scenario.ctx(),
    );
    destroy_2!(btc_price, usdc_price);
    return_shared_2!(mm, registry);

    // Borrow BTC (base asset) to create outstanding debt
    scenario.next_tx(test_constants::user1());
    let mut mm = scenario.take_shared<MarginManager<BTC, USDC>>();
    let registry = scenario.take_shared<MarginRegistry>();
    let mut btc_pool = scenario.take_shared_by_id<MarginPool<BTC>>(btc_pool_id);
    let pool = scenario.take_shared<Pool<BTC, USDC>>();
    let btc_price = build_btc_price_info_object(&mut scenario, 50000, &clock);
    let usdc_price = build_demo_usdc_price_info_object(&mut scenario, &clock);

    mm.borrow_base<BTC, USDC>(
        &registry,
        &mut btc_pool,
        &btc_price,
        &usdc_price,
        &pool,
        1 * btc_multiplier(),
        &clock,
        scenario.ctx(),
    );

    assert!(mm.borrowed_base_shares() > 0);

    destroy_2!(btc_price, usdc_price);
    return_shared_3!(btc_pool, pool, registry);
    return_shared(mm);

    // Try to unregister with outstanding base debt - should fail
    scenario.next_tx(test_constants::user1());
    let mut mm = scenario.take_shared<MarginManager<BTC, USDC>>();
    let mut registry = scenario.take_shared<MarginRegistry>();

    margin_manager::unregister_margin_manager<BTC, USDC>(
        &mut mm,
        &mut registry,
        scenario.ctx(),
    );

    // Cleanup (unreachable due to expected failure above)
    abort 0
}

#[test, expected_failure(abort_code = margin_manager::EOutstandingDebt)]
fun test_unregister_margin_manager_fails_with_outstanding_quote_debt() {
    let (
        mut scenario,
        clock,
        _admin_cap,
        _maintainer_cap,
        _btc_pool_id,
        usdc_pool_id,
        _pool_id,
        registry_id,
    ) = setup_btc_usd_deepbook_margin();

    // Supply liquidity to USDC pool so we can borrow
    scenario.next_tx(test_constants::admin());
    let mut usdc_pool = scenario.take_shared_by_id<MarginPool<USDC>>(usdc_pool_id);
    let registry = scenario.take_shared<MarginRegistry>();
    let supplier_cap = margin_pool::mint_supplier_cap(&registry, &clock, scenario.ctx());
    usdc_pool.supply(
        &registry,
        &supplier_cap,
        mint_coin<USDC>(1_000_000 * test_constants::usdc_multiplier(), scenario.ctx()),
        option::none(),
        &clock,
    );
    return_shared_2!(usdc_pool, registry);
    destroy(supplier_cap);

    // Create margin manager
    scenario.next_tx(test_constants::user1());
    let pool = scenario.take_shared<Pool<BTC, USDC>>();
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
    return_shared_2!(pool, registry);

    // Deposit collateral (BTC)
    scenario.next_tx(test_constants::user1());
    let mut mm = scenario.take_shared<MarginManager<BTC, USDC>>();
    let registry = scenario.take_shared<MarginRegistry>();
    let btc_price = build_btc_price_info_object(&mut scenario, 50000, &clock);
    let usdc_price = build_demo_usdc_price_info_object(&mut scenario, &clock);
    mm.deposit<BTC, USDC, BTC>(
        &registry,
        &btc_price,
        &usdc_price,
        mint_coin<BTC>(10 * btc_multiplier(), scenario.ctx()),
        &clock,
        scenario.ctx(),
    );
    destroy_2!(btc_price, usdc_price);
    return_shared_2!(mm, registry);

    // Borrow USDC (quote asset) to create outstanding debt
    scenario.next_tx(test_constants::user1());
    let mut mm = scenario.take_shared<MarginManager<BTC, USDC>>();
    let registry = scenario.take_shared<MarginRegistry>();
    let mut usdc_pool = scenario.take_shared_by_id<MarginPool<USDC>>(usdc_pool_id);
    let pool = scenario.take_shared<Pool<BTC, USDC>>();
    let btc_price = build_btc_price_info_object(&mut scenario, 50000, &clock);
    let usdc_price = build_demo_usdc_price_info_object(&mut scenario, &clock);

    mm.borrow_quote<BTC, USDC>(
        &registry,
        &mut usdc_pool,
        &btc_price,
        &usdc_price,
        &pool,
        10_000 * test_constants::usdc_multiplier(),
        &clock,
        scenario.ctx(),
    );

    assert!(mm.borrowed_quote_shares() > 0);

    destroy_2!(btc_price, usdc_price);
    return_shared_3!(usdc_pool, pool, registry);
    return_shared(mm);

    // Try to unregister with outstanding quote debt - should fail
    scenario.next_tx(test_constants::user1());
    let mut mm = scenario.take_shared<MarginManager<BTC, USDC>>();
    let mut registry = scenario.take_shared<MarginRegistry>();

    margin_manager::unregister_margin_manager<BTC, USDC>(
        &mut mm,
        &mut registry,
        scenario.ctx(),
    );

    // Cleanup (unreachable due to expected failure above)
    abort 0
}

#[test]
/// Test that liquidation works when there are unsettled maker fill balances.
/// This tests the fix where withdraw_settled_amounts is called before cancel_all_orders
/// to ensure any filled maker orders have their proceeds deposited to balance_manager.
fun liquidation_with_unsettled_maker_fills() {
    use deepbook::{balance_manager, constants};

    let (
        mut scenario,
        clock,
        admin_cap,
        maintainer_cap,
        _btc_pool_id,
        usdc_pool_id,
        _pool_id,
        registry_id,
    ) = setup_btc_usd_deepbook_margin();

    // Step 1: User1 creates margin manager, deposits BTC, borrows USDC
    scenario.next_tx(test_constants::user1());
    let pool = scenario.take_shared<Pool<BTC, USDC>>();
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
    let btc_price = build_btc_price_info_object(&mut scenario, 50000, &clock);
    let usdc_price = build_demo_usdc_price_info_object(&mut scenario, &clock);

    // Deposit 1 BTC worth $50k
    mm.deposit<BTC, USDC, BTC>(
        &registry,
        &btc_price,
        &usdc_price,
        mint_coin<BTC>(btc_multiplier(), scenario.ctx()),
        &clock,
        scenario.ctx(),
    );

    // Borrow $40k USDC
    mm.borrow_quote<BTC, USDC>(
        &registry,
        &mut usdc_pool,
        &btc_price,
        &usdc_price,
        &pool,
        40_000_000_000,
        &clock,
        scenario.ctx(),
    );

    destroy_2!(btc_price, usdc_price);
    return_shared_4!(mm, usdc_pool, pool, registry);

    // Step 2: User1 places a maker BID order (buy BTC with USDC)
    scenario.next_tx(test_constants::user1());
    let mut pool = scenario.take_shared<Pool<BTC, USDC>>();
    let registry = scenario.take_shared<MarginRegistry>();
    let mut mm = scenario.take_shared<MarginManager<BTC, USDC>>();
    let btc_price = build_btc_price_info_object(&mut scenario, 50000, &clock);
    let usdc_price = build_demo_usdc_price_info_object(&mut scenario, &clock);

    // Place a bid for 0.1 BTC at a price that will sit in the book as maker
    let bid_price = 500_000u64; // price in pool units
    let bid_quantity = btc_multiplier() / 10; // 0.1 BTC

    deepbook_margin::pool_proxy::place_limit_order<BTC, USDC>(
        &registry,
        &mut mm,
        &mut pool,
        1,
        constants::no_restriction(),
        constants::self_matching_allowed(),
        bid_price,
        bid_quantity,
        true, // is_bid
        false, // pay_with_deep
        18446744073709551615,
        &clock,
        scenario.ctx(),
    );

    destroy_2!(btc_price, usdc_price);
    return_shared_3!(mm, pool, registry);

    // Step 3: Taker fills User1's bid by selling BTC
    scenario.next_tx(test_constants::user2());
    let mut taker_bm = balance_manager::new(scenario.ctx());
    taker_bm.deposit(mint_coin<BTC>(btc_multiplier(), scenario.ctx()), scenario.ctx());
    let trade_proof = taker_bm.generate_proof_as_owner(scenario.ctx());

    let mut pool = scenario.take_shared<Pool<BTC, USDC>>();

    // Place IOC sell order that crosses User1's bid
    pool.place_limit_order<BTC, USDC>(
        &mut taker_bm,
        &trade_proof,
        2,
        constants::immediate_or_cancel(),
        constants::self_matching_allowed(),
        bid_price,
        bid_quantity,
        false, // is_bid = false (selling)
        false,
        18446744073709551615,
        &clock,
        scenario.ctx(),
    );

    return_shared(pool);
    transfer::public_share_object(taker_bm);

    // User1's margin manager now has BTC in settled_balances (NOT in balance_manager yet)

    // Step 4: Price drops to make User1 liquidatable
    scenario.next_tx(test_constants::liquidator());
    let mut pool = scenario.take_shared<Pool<BTC, USDC>>();
    let registry = scenario.take_shared<MarginRegistry>();
    let mut mm = scenario.take_shared<MarginManager<BTC, USDC>>();
    let mut usdc_pool = scenario.take_shared_by_id<MarginPool<USDC>>(usdc_pool_id);

    let btc_price_dropped = build_btc_price_info_object(&mut scenario, 2000, &clock);
    let usdc_price = build_demo_usdc_price_info_object(&mut scenario, &clock);

    // Step 5: Liquidator liquidates - should succeed because withdraw_settled_amounts
    // is called first, depositing the BTC from filled maker order to balance_manager
    let debt_coin = mint_coin<USDC>(50_000_000_000, scenario.ctx());

    let (base_coin, quote_coin, remaining_debt) = mm.liquidate<BTC, USDC, USDC>(
        &registry,
        &btc_price_dropped,
        &usdc_price,
        &mut usdc_pool,
        &mut pool,
        debt_coin,
        &clock,
        scenario.ctx(),
    );

    // Liquidation succeeded - liquidator received assets
    assert!(base_coin.value() > 0 || quote_coin.value() > 0);

    destroy_3!(remaining_debt, base_coin, quote_coin);
    destroy_2!(btc_price_dropped, usdc_price);
    return_shared_3!(mm, usdc_pool, pool);
    cleanup_margin_test(registry, admin_cap, maintainer_cap, clock, scenario);
}

#[test]
/// Tests that manager_state works with stale oracle prices (older than max_age_secs).
/// The config sets max_age_secs to 60, but we use prices that are 120 seconds old.
fun manager_state_works_with_stale_oracles() {
    let (
        mut scenario,
        mut clock,
        admin_cap,
        maintainer_cap,
        btc_pool_id,
        usdc_pool_id,
        pool_id,
        registry_id,
    ) = setup_btc_usd_deepbook_margin();

    // Create margin manager
    scenario.next_tx(test_constants::user1());
    let mut registry = scenario.take_shared<MarginRegistry>();
    let pool = scenario.take_shared<Pool<BTC, USDC>>();
    let deepbook_registry = scenario.take_shared_by_id<Registry>(registry_id);
    margin_manager::new<BTC, USDC>(
        &pool,
        &deepbook_registry,
        &mut registry,
        &clock,
        scenario.ctx(),
    );
    return_shared(deepbook_registry);
    return_shared(pool);
    return_shared(registry);

    // Deposit USDC as collateral
    scenario.next_tx(test_constants::user1());
    let mut mm = scenario.take_shared<MarginManager<BTC, USDC>>();
    let registry = scenario.take_shared<MarginRegistry>();
    let pool = scenario.take_shared<Pool<BTC, USDC>>();

    let btc_price = build_btc_price_info_object(&mut scenario, 50000, &clock);
    let usdc_price = build_demo_usdc_price_info_object(&mut scenario, &clock);

    let deposit_coin = mint_coin<USDC>(100_000_000_000, scenario.ctx()); // 100k USDC
    mm.deposit<BTC, USDC, USDC>(
        &registry,
        &btc_price,
        &usdc_price,
        deposit_coin,
        &clock,
        scenario.ctx(),
    );

    destroy_2!(btc_price, usdc_price);
    return_shared_3!(mm, pool, registry);

    // Advance time by 120 seconds to make future oracle prices stale
    // (config has max_age_secs = 60)
    clock.increment_for_testing(120_000); // 120 seconds in ms

    // Create stale price info objects (120 seconds old relative to current clock)
    scenario.next_tx(test_constants::user1());
    let stale_btc_price = build_stale_btc_price_info_object(&mut scenario, 50000, &clock, 120);
    let stale_usdc_price = build_stale_usdc_price_info_object(&mut scenario, &clock, 120);

    let mm = scenario.take_shared<MarginManager<BTC, USDC>>();
    let registry = scenario.take_shared<MarginRegistry>();
    let pool = scenario.take_shared<Pool<BTC, USDC>>();
    let btc_pool = scenario.take_shared_by_id<MarginPool<BTC>>(btc_pool_id);
    let usdc_pool = scenario.take_shared_by_id<MarginPool<USDC>>(usdc_pool_id);

    // Call manager_state with stale oracles - should succeed because it uses unsafe functions
    let (
        manager_id,
        deepbook_pool_id,
        risk_ratio,
        base_asset,
        quote_asset,
        base_debt,
        quote_debt,
        base_pyth_price,
        base_pyth_decimals,
        quote_pyth_price,
        quote_pyth_decimals,
        current_price,
        _lowest_trigger_above_price,
        _highest_trigger_below_price,
    ) = mm.manager_state<BTC, USDC>(
        &registry,
        &stale_btc_price,
        &stale_usdc_price,
        &pool,
        &btc_pool,
        &usdc_pool,
        &clock,
    );

    // Verify returned values are sensible
    assert!(manager_id == mm.id());
    assert!(deepbook_pool_id == pool_id);
    assert!(risk_ratio > 0); // Should have max risk ratio since no debt
    assert!(base_asset == 0); // No BTC deposited
    assert!(quote_asset == 100_000_000_000); // 100k USDC deposited
    assert!(base_debt == 0);
    assert!(quote_debt == 0);
    assert!(base_pyth_price > 0); // BTC price should be non-zero
    assert!(base_pyth_decimals == 8); // Pyth uses 8 decimals
    assert!(quote_pyth_price > 0); // USDC price should be non-zero
    assert!(quote_pyth_decimals == 8);
    assert!(current_price > 0);

    destroy_2!(stale_btc_price, stale_usdc_price);
    return_shared_4!(mm, pool, btc_pool, usdc_pool);
    cleanup_margin_test(registry, admin_cap, maintainer_cap, clock, scenario);
}

#[test]
/// Tests that manager_state returns accurate values with stale oracles.
/// Verifies exact price values, debt amounts, and asset balances.
fun manager_state_returns_accurate_values_with_stale_oracles() {
    let (
        mut scenario,
        mut clock,
        admin_cap,
        maintainer_cap,
        btc_pool_id,
        usdc_pool_id,
        pool_id,
        registry_id,
    ) = setup_btc_usd_deepbook_margin();

    // Create margin manager
    scenario.next_tx(test_constants::user1());
    let mut registry = scenario.take_shared<MarginRegistry>();
    let pool = scenario.take_shared<Pool<BTC, USDC>>();
    let deepbook_registry = scenario.take_shared_by_id<Registry>(registry_id);
    margin_manager::new<BTC, USDC>(
        &pool,
        &deepbook_registry,
        &mut registry,
        &clock,
        scenario.ctx(),
    );
    return_shared(deepbook_registry);
    return_shared(pool);
    return_shared(registry);

    // Deposit USDC as collateral and borrow BTC
    scenario.next_tx(test_constants::user1());
    let mut mm = scenario.take_shared<MarginManager<BTC, USDC>>();
    let registry = scenario.take_shared<MarginRegistry>();
    let pool = scenario.take_shared<Pool<BTC, USDC>>();
    let mut btc_pool = scenario.take_shared_by_id<MarginPool<BTC>>(btc_pool_id);

    let btc_price = build_btc_price_info_object(&mut scenario, 50000, &clock);
    let usdc_price = build_demo_usdc_price_info_object(&mut scenario, &clock);

    // Deposit 100k USDC
    let usdc_deposit = 100_000_000_000u64; // 100k USDC (6 decimals)
    let deposit_coin = mint_coin<USDC>(usdc_deposit, scenario.ctx());
    mm.deposit<BTC, USDC, USDC>(
        &registry,
        &btc_price,
        &usdc_price,
        deposit_coin,
        &clock,
        scenario.ctx(),
    );

    // Borrow 0.5 BTC (worth $25k at $50k/BTC, ~25% of collateral)
    let btc_borrow = 50_000_000u64; // 0.5 BTC (8 decimals)
    mm.borrow_base<BTC, USDC>(
        &registry,
        &mut btc_pool,
        &btc_price,
        &usdc_price,
        &pool,
        btc_borrow,
        &clock,
        scenario.ctx(),
    );

    destroy_2!(btc_price, usdc_price);
    return_shared_4!(mm, pool, btc_pool, registry);

    // Advance time by 120 seconds to make oracle prices stale
    clock.increment_for_testing(120_000);

    // Create stale price info objects
    scenario.next_tx(test_constants::user1());
    let btc_price_usd = 50000u64;
    let stale_btc_price = build_stale_btc_price_info_object(
        &mut scenario,
        btc_price_usd,
        &clock,
        120,
    );
    let stale_usdc_price = build_stale_usdc_price_info_object(&mut scenario, &clock, 120);

    let mm = scenario.take_shared<MarginManager<BTC, USDC>>();
    let registry = scenario.take_shared<MarginRegistry>();
    let pool = scenario.take_shared<Pool<BTC, USDC>>();
    let btc_pool = scenario.take_shared_by_id<MarginPool<BTC>>(btc_pool_id);
    let usdc_pool = scenario.take_shared_by_id<MarginPool<USDC>>(usdc_pool_id);

    let (
        manager_id,
        deepbook_pool_id,
        risk_ratio,
        base_asset,
        quote_asset,
        base_debt,
        quote_debt,
        base_pyth_price,
        base_pyth_decimals,
        quote_pyth_price,
        quote_pyth_decimals,
        current_price,
        _lowest_trigger_above_price,
        _highest_trigger_below_price,
    ) = mm.manager_state<BTC, USDC>(
        &registry,
        &stale_btc_price,
        &stale_usdc_price,
        &pool,
        &btc_pool,
        &usdc_pool,
        &clock,
    );

    // Verify IDs
    assert!(manager_id == mm.id());
    assert!(deepbook_pool_id == pool_id);

    // Verify asset balances
    // Borrowed BTC goes to balance manager, so base_asset = btc_borrow
    assert!(base_asset == btc_borrow); // 0.5 BTC
    assert!(quote_asset == usdc_deposit); // 100k USDC

    // Verify debt - base_debt should be the borrowed amount (may have tiny interest)
    // With 120 seconds elapsed, interest should be minimal
    assert!(base_debt >= btc_borrow); // At least the borrowed amount
    assert!(base_debt < btc_borrow + 1000); // Less than borrowed + tiny interest buffer
    assert!(quote_debt == 0); // No quote debt

    // Verify Pyth prices are exact
    // BTC price: 50000 * 10^8 (pyth_multiplier) = 5_000_000_000_000
    let expected_btc_pyth_price = btc_price_usd * test_constants::pyth_multiplier();
    assert!(base_pyth_price == expected_btc_pyth_price);
    assert!(base_pyth_decimals == 8);

    // USDC price: 1 * 10^8 (pyth_multiplier) = 100_000_000
    let expected_usdc_pyth_price = 1 * test_constants::pyth_multiplier();
    assert!(quote_pyth_price == expected_usdc_pyth_price);
    assert!(quote_pyth_decimals == 8);

    // Verify current_price is reasonable
    // BTC/USDC price should be around 50000 * 10^6 (USDC has 6 decimals, BTC has 8)
    // Price = (BTC_USD_price / USDC_USD_price) adjusted for decimals
    // With BTC at $50k and USDC at $1, price should be ~50000 * 10^6 = 50_000_000_000
    assert!(current_price > 0);

    // Verify risk ratio is reasonable
    // With $100k collateral and ~$25k debt (0.5 BTC at $50k), risk ratio should be healthy
    assert!(risk_ratio > 0);

    destroy_2!(stale_btc_price, stale_usdc_price);
    return_shared_4!(mm, pool, btc_pool, usdc_pool);
    cleanup_margin_test(registry, admin_cap, maintainer_cap, clock, scenario);
}

#[test, expected_failure(abort_code = pyth::pyth::E_STALE_PRICE_UPDATE)]
/// Tests that borrow_base fails when oracle prices are stale.
/// This confirms that state-changing functions still use validated price checks.
fun borrow_base_fails_with_stale_oracles() {
    let (
        mut scenario,
        mut clock,
        _admin_cap,
        _maintainer_cap,
        btc_pool_id,
        _usdc_pool_id,
        _pool_id,
        registry_id,
    ) = setup_btc_usd_deepbook_margin();

    // Create margin manager
    scenario.next_tx(test_constants::user1());
    let mut registry = scenario.take_shared<MarginRegistry>();
    let pool = scenario.take_shared<Pool<BTC, USDC>>();
    let deepbook_registry = scenario.take_shared_by_id<Registry>(registry_id);
    margin_manager::new<BTC, USDC>(
        &pool,
        &deepbook_registry,
        &mut registry,
        &clock,
        scenario.ctx(),
    );
    return_shared(deepbook_registry);
    return_shared(pool);
    return_shared(registry);

    // Deposit USDC as collateral with fresh prices
    scenario.next_tx(test_constants::user1());
    let mut mm = scenario.take_shared<MarginManager<BTC, USDC>>();
    let registry = scenario.take_shared<MarginRegistry>();
    let pool = scenario.take_shared<Pool<BTC, USDC>>();

    let btc_price = build_btc_price_info_object(&mut scenario, 50000, &clock);
    let usdc_price = build_demo_usdc_price_info_object(&mut scenario, &clock);

    let deposit_coin = mint_coin<USDC>(100_000_000_000, scenario.ctx()); // 100k USDC
    mm.deposit<BTC, USDC, USDC>(
        &registry,
        &btc_price,
        &usdc_price,
        deposit_coin,
        &clock,
        scenario.ctx(),
    );

    destroy_2!(btc_price, usdc_price);
    return_shared_3!(mm, pool, registry);

    // Advance time by 120 seconds to make prices stale
    clock.increment_for_testing(120_000);

    // Try to borrow with stale prices - should fail
    scenario.next_tx(test_constants::user1());
    let stale_btc_price = build_stale_btc_price_info_object(&mut scenario, 50000, &clock, 120);
    let stale_usdc_price = build_stale_usdc_price_info_object(&mut scenario, &clock, 120);

    let mut mm = scenario.take_shared<MarginManager<BTC, USDC>>();
    let registry = scenario.take_shared<MarginRegistry>();
    let pool = scenario.take_shared<Pool<BTC, USDC>>();
    let mut btc_pool = scenario.take_shared_by_id<MarginPool<BTC>>(btc_pool_id);

    // This should fail with E_STALE_PRICE_UPDATE
    mm.borrow_base<BTC, USDC>(
        &registry,
        &mut btc_pool,
        &stale_btc_price,
        &stale_usdc_price,
        &pool,
        10_000_000, // 0.1 BTC
        &clock,
        scenario.ctx(),
    );

    abort 0 // Never reached
}
