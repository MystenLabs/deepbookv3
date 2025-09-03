// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module margin_trading::margin_manager_tests;

use deepbook::pool::Pool;
use margin_trading::{
    margin_manager::{Self, MarginManager},
    margin_pool::{Self, MarginPool},
    margin_registry::{MarginRegistry, MarginPoolCap},
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
        get_margin_pool_caps,
        destroy_2,
        return_shared_2,
        return_shared_3,
        return_to_sender_2,
        advance_time
    }
};
use sui::{test_scenario::{Self as test, return_shared}, test_utils::destroy};
use token::deep::DEEP;

#[test]
fun test_margin_manager_creation() {
    let (mut scenario, clock, admin_cap, maintainer_cap) = setup_margin_registry();

    // Test creating multiple margin pools
    scenario.next_tx(test_constants::user1());
    create_margin_pool<BTC>(
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
    let (mut scenario, mut clock, admin_cap, maintainer_cap) = setup_margin_registry();

    clock.set_for_testing(1000000);
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

    scenario.next_tx(test_constants::admin());
    let cap1 = scenario.take_from_sender<MarginPoolCap>();
    let cap2 = scenario.take_from_sender<MarginPoolCap>();

    let (usdc_pool_cap, usdt_pool_cap) = if (cap1.margin_pool_id() == usdc_pool_id) {
        (cap1, cap2)
    } else {
        (cap2, cap1)
    };

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
    let mut usdc_pool = scenario.take_shared_by_id<MarginPool<USDC>>(usdc_pool_id);
    let mut usdt_pool = scenario.take_shared_by_id<MarginPool<USDT>>(usdt_pool_id);
    let registry = scenario.take_shared<MarginRegistry>();

    let usdc_supply = mint_coin<USDC>(
        1_000_000 * test_constants::usdc_multiplier(),
        scenario.ctx(),
    );
    let usdt_supply = mint_coin<USDT>(
        1_000_000 * test_constants::usdt_multiplier(),
        scenario.ctx(),
    );

    usdc_pool.supply(&registry, usdc_supply, &clock, scenario.ctx());
    usdt_pool.supply(&registry, usdt_supply, &clock, scenario.ctx());

    usdc_pool.enable_deepbook_pool_for_loan(&registry, pool_id, &usdc_pool_cap, &clock);
    usdt_pool.enable_deepbook_pool_for_loan(&registry, pool_id, &usdt_pool_cap, &clock);

    test::return_shared(usdc_pool);
    test::return_shared(usdt_pool);

    return_to_sender_2!(&scenario, usdc_pool_cap, usdt_pool_cap);

    scenario.next_tx(test_constants::user1());
    let pool = scenario.take_shared<Pool<USDC, USDT>>();
    margin_manager::new<USDC, USDT>(&pool, &registry, &clock, scenario.ctx());

    scenario.next_tx(test_constants::admin());
    let usdc_price = build_demo_usdc_price_info_object(&mut scenario, &clock);
    let usdt_price = build_demo_usdt_price_info_object(&mut scenario, &clock);

    // Test borrowing with oracle prices
    scenario.next_tx(test_constants::user1());
    let mut mm = scenario.take_shared<MarginManager<USDC, USDT>>();
    let mut usdt_pool = scenario.take_shared_by_id<MarginPool<USDT>>(usdt_pool_id);

    // User1 deposits 10k USDC as collateral
    let deposit_coin = mint_coin<USDC>(10_000_000_000, scenario.ctx()); // 10k USDC with 6 decimals
    mm.deposit<USDC, USDT, USDC>(&registry, deposit_coin, scenario.ctx());

    // Borrow 5k USDT against the collateral (50% borrow ratio)
    let request = mm.borrow_quote<USDC, USDT>(
        &registry,
        &mut usdt_pool,
        5_000_000_000, // 5k USDT with 6 decimals
        &clock,
        scenario.ctx(),
    );

    // Prove the request is valid using oracle prices
    mm.prove_and_destroy_request<USDC, USDT, USDT>(
        &registry,
        &mut usdt_pool,
        &pool,
        &usdc_price,
        &usdt_price,
        &clock,
        request,
    );

    test::return_shared(mm);
    test::return_shared(usdt_pool);
    test::return_shared(pool);

    destroy_2!(usdc_price, usdt_price);
    cleanup_margin_test(registry, admin_cap, maintainer_cap, clock, scenario);
}

#[test]
fun test_btc_usd_margin_trading() {
    let (
        mut scenario,
        clock,
        admin_cap,
        maintainer_cap,
        _btc_pool_id,
        usdc_pool_id,
        _pool_id,
    ) = setup_btc_usd_margin_trading();

    let btc_price = build_btc_price_info_object(
        &mut scenario,
        60000,
        &clock,
    );
    let usdc_price = build_demo_usdc_price_info_object(&mut scenario, &clock);

    scenario.next_tx(test_constants::user1());
    let pool = scenario.take_shared<Pool<BTC, USDC>>();
    let registry = scenario.take_shared<MarginRegistry>();
    margin_manager::new<BTC, USDC>(&pool, &registry, &clock, scenario.ctx());

    scenario.next_tx(test_constants::user1());
    let mut mm = scenario.take_shared<MarginManager<BTC, USDC>>();
    let mut usdc_pool = scenario.take_shared_by_id<MarginPool<USDC>>(usdc_pool_id);

    let deposit = mint_coin<BTC>(btc_multiplier() / 2, scenario.ctx()); // 0.5 BTC
    mm.deposit<BTC, USDC, BTC>(&registry, deposit, scenario.ctx());

    let request = mm.borrow_quote<BTC, USDC>(
        &registry,
        &mut usdc_pool,
        15_000_000000, // $15,000
        &clock,
        scenario.ctx(),
    );

    mm.prove_and_destroy_request<BTC, USDC, USDC>(
        &registry,
        &mut usdc_pool,
        &pool,
        &btc_price,
        &usdc_price,
        &clock,
        request,
    );

    test::return_shared(mm);
    test::return_shared(usdc_pool);
    test::return_shared(pool);

    destroy_2!(btc_price, usdc_price);
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

    let request = mm.borrow_base<BTC, USDC>(
        &registry,
        &mut btc_pool,
        2 * btc_multiplier(),
        &clock,
        scenario.ctx(),
    );

    mm.prove_and_destroy_request<BTC, USDC, BTC>(
        &registry,
        &mut btc_pool,
        &pool,
        &btc_price,
        &usdc_price,
        &clock,
        request,
    );

    clock.set_for_testing(1000001);
    let btc_increased = build_btc_price_info_object(
        &mut scenario,
        300000,
        &clock,
    );

    scenario.next_tx(test_constants::admin());
    let (fulfillment, base_coin, quote_coin) = mm.liquidate<BTC, USDC, BTC>(
        &registry,
        &btc_increased,
        &usdc_price,
        &mut btc_pool,
        &mut pool,
        &clock,
        scenario.ctx(),
    );

    destroy(fulfillment);
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
    let (mut scenario, mut clock, admin_cap, maintainer_cap) = setup_margin_registry();

    clock.set_for_testing(1000000);
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

    // Get pool caps for enabling loans
    let (usdc_pool_cap, usdt_pool_cap) = get_margin_pool_caps(
        &mut scenario,
        usdc_pool_id,
    );

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
    let mut usdc_pool = scenario.take_shared_by_id<MarginPool<USDC>>(usdc_pool_id);
    let mut usdt_pool = scenario.take_shared_by_id<MarginPool<USDT>>(usdt_pool_id);
    let registry = scenario.take_shared<MarginRegistry>();

    usdc_pool.supply(
        &registry,
        mint_coin<USDC>(1_000_000 * test_constants::usdc_multiplier(), scenario.ctx()),
        &clock,
        scenario.ctx(),
    );
    usdt_pool.supply(
        &registry,
        mint_coin<USDT>(1_000_000 * test_constants::usdt_multiplier(), scenario.ctx()),
        &clock,
        scenario.ctx(),
    );

    usdc_pool.enable_deepbook_pool_for_loan(&registry, pool_id, &usdc_pool_cap, &clock);
    usdt_pool.enable_deepbook_pool_for_loan(&registry, pool_id, &usdt_pool_cap, &clock);

    return_shared_2!(usdc_pool, usdt_pool);
    return_to_sender_2!(&scenario, usdc_pool_cap, usdt_pool_cap);

    scenario.next_tx(test_constants::user1());
    let pool = scenario.take_shared<Pool<USDC, USDT>>();
    margin_manager::new<USDC, USDT>(&pool, &registry, &clock, scenario.ctx());

    scenario.next_tx(test_constants::user1());
    let mut mm = scenario.take_shared<MarginManager<USDC, USDT>>();
    let mut usdt_pool = scenario.take_shared_by_id<MarginPool<USDT>>(usdt_pool_id);

    mm.deposit<USDC, USDT, USDC>(
        &registry,
        mint_coin<USDC>(10_000 * test_constants::usdc_multiplier(), scenario.ctx()),
        scenario.ctx(),
    );
    let borrow_request = mm.borrow_quote<USDC, USDT>(
        &registry,
        &mut usdt_pool,
        1000 * test_constants::usdt_multiplier(),
        &clock,
        scenario.ctx(),
    );

    let usdc_price = build_demo_usdc_price_info_object(&mut scenario, &clock);
    let usdt_price = build_demo_usdt_price_info_object(&mut scenario, &clock);

    mm.prove_and_destroy_request<USDC, USDT, USDT>(
        &registry,
        &mut usdt_pool,
        &pool,
        &usdc_price,
        &usdt_price,
        &clock,
        borrow_request,
    );

    // Now test withdrawal with existing loan (risk ratio should still be high)
    let withdraw_amount = 100 * test_constants::usdc_multiplier();
    let (withdrawn_coin, withdraw_request) = mm.withdraw<USDC, USDT, USDC>(
        &registry,
        withdraw_amount,
        scenario.ctx(),
    );

    mm.prove_and_destroy_request<USDC, USDT, USDT>(
        &registry,
        &mut usdt_pool, // Use the pool where we have a loan
        &pool,
        &usdc_price,
        &usdt_price,
        &clock,
        withdraw_request,
    );

    assert!(withdrawn_coin.value() == withdraw_amount);
    destroy(withdrawn_coin);

    return_shared_3!(mm, usdt_pool, pool);
    destroy_2!(usdc_price, usdt_price);
    cleanup_margin_test(registry, admin_cap, maintainer_cap, clock, scenario);
}

#[test, expected_failure(abort_code = margin_manager::EWithdrawRiskRatioExceeded)]
fun test_withdrawal_fails_when_risk_ratio_goes_below_limit() {
    let (mut scenario, mut clock, admin_cap, maintainer_cap) = setup_margin_registry();

    clock.set_for_testing(1000000);
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

    let (usdc_pool_cap, usdt_pool_cap) = get_margin_pool_caps(
        &mut scenario,
        usdc_pool_id,
    );

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
    let mut usdc_pool = scenario.take_shared_by_id<MarginPool<USDC>>(usdc_pool_id);
    let mut usdt_pool = scenario.take_shared_by_id<MarginPool<USDT>>(usdt_pool_id);
    let registry = scenario.take_shared<MarginRegistry>();

    usdc_pool.supply(
        &registry,
        mint_coin<USDC>(1_000_000 * test_constants::usdc_multiplier(), scenario.ctx()),
        &clock,
        scenario.ctx(),
    );
    usdt_pool.supply(
        &registry,
        mint_coin<USDT>(1_000_000 * test_constants::usdt_multiplier(), scenario.ctx()),
        &clock,
        scenario.ctx(),
    );

    usdc_pool.enable_deepbook_pool_for_loan(&registry, pool_id, &usdc_pool_cap, &clock);
    usdt_pool.enable_deepbook_pool_for_loan(&registry, pool_id, &usdt_pool_cap, &clock);

    return_shared_2!(usdc_pool, usdt_pool);
    return_to_sender_2!(&scenario, usdc_pool_cap, usdt_pool_cap);

    scenario.next_tx(test_constants::user1());
    let pool = scenario.take_shared<Pool<USDC, USDT>>();
    margin_manager::new<USDC, USDT>(&pool, &registry, &clock, scenario.ctx());

    scenario.next_tx(test_constants::user1());
    let mut mm = scenario.take_shared<MarginManager<USDC, USDT>>();
    let mut usdt_pool = scenario.take_shared_by_id<MarginPool<USDT>>(usdt_pool_id);

    let usdc_deposit = mint_coin<USDC>(10_000 * test_constants::usdc_multiplier(), scenario.ctx());
    mm.deposit<USDC, USDT, USDC>(&registry, usdc_deposit, scenario.ctx());

    let borrow_request = mm.borrow_quote<USDC, USDT>(
        &registry,
        &mut usdt_pool,
        4000 * test_constants::usdt_multiplier(),
        &clock,
        scenario.ctx(),
    );

    let usdc_price = build_demo_usdc_price_info_object(&mut scenario, &clock);
    let usdt_price = build_demo_usdt_price_info_object(&mut scenario, &clock);

    mm.prove_and_destroy_request<USDC, USDT, USDT>(
        &registry,
        &mut usdt_pool,
        &pool,
        &usdc_price,
        &usdt_price,
        &clock,
        borrow_request,
    );

    let (withdraw_coin, withdraw_request) = mm.withdraw<USDC, USDT, USDC>(
        &registry,
        7000 * test_constants::usdc_multiplier(),
        scenario.ctx(),
    );
    destroy(withdraw_coin);

    mm.prove_and_destroy_request<USDC, USDT, USDT>(
        &registry,
        &mut usdt_pool,
        &pool,
        &usdc_price,
        &usdt_price,
        &clock,
        withdraw_request,
    );

    abort
}

// Borrow tests
#[test, expected_failure(abort_code = margin_manager::ECannotHaveLoanInMoreThanOneMarginPool)]
fun test_borrow_fails_from_both_pools() {
    let (mut scenario, mut clock, admin_cap, maintainer_cap) = setup_margin_registry();

    clock.set_for_testing(1000000);
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

    let (usdc_pool_cap, usdt_pool_cap) = get_margin_pool_caps(
        &mut scenario,
        usdc_pool_id,
    );

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
    let mut usdc_pool = scenario.take_shared_by_id<MarginPool<USDC>>(usdc_pool_id);
    let mut usdt_pool = scenario.take_shared_by_id<MarginPool<USDT>>(usdt_pool_id);
    let registry = scenario.take_shared<MarginRegistry>();

    usdc_pool.supply(
        &registry,
        mint_coin<USDC>(1_000_000 * test_constants::usdc_multiplier(), scenario.ctx()),
        &clock,
        scenario.ctx(),
    );
    usdt_pool.supply(
        &registry,
        mint_coin<USDT>(1_000_000 * test_constants::usdt_multiplier(), scenario.ctx()),
        &clock,
        scenario.ctx(),
    );

    usdc_pool.enable_deepbook_pool_for_loan(&registry, pool_id, &usdc_pool_cap, &clock);
    usdt_pool.enable_deepbook_pool_for_loan(&registry, pool_id, &usdt_pool_cap, &clock);

    return_shared_2!(usdc_pool, usdt_pool);
    return_to_sender_2!(&scenario, usdc_pool_cap, usdt_pool_cap);

    scenario.next_tx(test_constants::user1());
    let pool = scenario.take_shared<Pool<USDC, USDT>>();
    margin_manager::new<USDC, USDT>(&pool, &registry, &clock, scenario.ctx());

    scenario.next_tx(test_constants::user1());
    let mut mm = scenario.take_shared<MarginManager<USDC, USDT>>();
    let mut usdt_pool = scenario.take_shared_by_id<MarginPool<USDT>>(usdt_pool_id);
    let mut usdc_pool = scenario.take_shared_by_id<MarginPool<USDC>>(usdc_pool_id);

    mm.deposit<USDC, USDT, USDC>(
        &registry,
        mint_coin<USDC>(10_000 * test_constants::usdc_multiplier(), scenario.ctx()),
        scenario.ctx(),
    );

    let request1 = mm.borrow_quote<USDC, USDT>(
        &registry,
        &mut usdt_pool,
        1000 * test_constants::usdt_multiplier(),
        &clock,
        scenario.ctx(),
    );

    let usdc_price = build_demo_usdc_price_info_object(&mut scenario, &clock);
    let usdt_price = build_demo_usdt_price_info_object(&mut scenario, &clock);

    mm.prove_and_destroy_request<USDC, USDT, USDT>(
        &registry,
        &mut usdt_pool,
        &pool,
        &usdc_price,
        &usdt_price,
        &clock,
        request1,
    );

    let _request2 = mm.borrow_base<USDC, USDT>(
        &registry,
        &mut usdc_pool,
        1000 * test_constants::usdc_multiplier(),
        &clock,
        scenario.ctx(),
    );

    abort
}

#[test, expected_failure(abort_code = margin_pool::EInvalidLoanQuantity)]
fun test_borrow_fails_with_zero_amount() {
    let (mut scenario, mut clock, admin_cap, maintainer_cap) = setup_margin_registry();

    clock.set_for_testing(1000000);
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

    let (_usdc_pool_cap, usdt_pool_cap) = get_margin_pool_caps(
        &mut scenario,
        usdc_pool_id,
    );

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

    // Setup USDT pool
    scenario.next_tx(test_constants::admin());
    let mut usdt_pool = scenario.take_shared_by_id<MarginPool<USDT>>(usdt_pool_id);
    let registry = scenario.take_shared<MarginRegistry>();

    usdt_pool.supply(
        &registry,
        mint_coin<USDT>(1_000_000 * test_constants::usdt_multiplier(), scenario.ctx()),
        &clock,
        scenario.ctx(),
    );
    usdt_pool.enable_deepbook_pool_for_loan(&registry, pool_id, &usdt_pool_cap, &clock);

    return_shared(usdt_pool);
    scenario.return_to_sender(usdt_pool_cap);

    // Create margin manager
    scenario.next_tx(test_constants::user1());
    let pool = scenario.take_shared<Pool<USDC, USDT>>();
    margin_manager::new<USDC, USDT>(&pool, &registry, &clock, scenario.ctx());

    scenario.next_tx(test_constants::user1());
    let mut mm = scenario.take_shared<MarginManager<USDC, USDT>>();
    let mut usdt_pool = scenario.take_shared_by_id<MarginPool<USDT>>(usdt_pool_id);

    mm.deposit<USDC, USDT, USDC>(
        &registry,
        mint_coin<USDC>(10_000 * test_constants::usdc_multiplier(), scenario.ctx()),
        scenario.ctx(),
    );

    let _request = mm.borrow_quote<USDC, USDT>(
        &registry,
        &mut usdt_pool,
        0,
        &clock,
        scenario.ctx(),
    );

    abort
}

#[test, expected_failure(abort_code = margin_manager::EBorrowRiskRatioExceeded)]
fun test_borrow_fails_when_risk_ratio_below_150() {
    let (mut scenario, mut clock, admin_cap, maintainer_cap) = setup_margin_registry();

    clock.set_for_testing(1000000);
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

    let (_usdc_pool_cap, usdt_pool_cap) = get_margin_pool_caps(
        &mut scenario,
        usdc_pool_id,
    );

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

    // Setup USDT pool
    scenario.next_tx(test_constants::admin());
    let mut usdt_pool = scenario.take_shared_by_id<MarginPool<USDT>>(usdt_pool_id);
    let registry = scenario.take_shared<MarginRegistry>();

    usdt_pool.supply(
        &registry,
        mint_coin<USDT>(1_000_000 * test_constants::usdt_multiplier(), scenario.ctx()),
        &clock,
        scenario.ctx(),
    );
    usdt_pool.enable_deepbook_pool_for_loan(&registry, pool_id, &usdt_pool_cap, &clock);

    return_shared(usdt_pool);
    scenario.return_to_sender(usdt_pool_cap);

    // Create margin manager
    scenario.next_tx(test_constants::user1());
    let pool = scenario.take_shared<Pool<USDC, USDT>>();
    margin_manager::new<USDC, USDT>(&pool, &registry, &clock, scenario.ctx());

    scenario.next_tx(test_constants::user1());
    let mut mm = scenario.take_shared<MarginManager<USDC, USDT>>();
    let mut usdt_pool = scenario.take_shared_by_id<MarginPool<USDT>>(usdt_pool_id);

    // Deposit small collateral
    mm.deposit<USDC, USDT, USDC>(
        &registry,
        mint_coin<USDC>(1000 * test_constants::usdc_multiplier(), scenario.ctx()),
        scenario.ctx(),
    );

    // Try to borrow amount that would push risk ratio below 1.5
    // With $1000 collateral, borrowing $5000 would give ratio of 0.2 which is way below 1.5
    let borrow_amount = 5000 * test_constants::usdt_multiplier();
    let request = mm.borrow_quote<USDC, USDT>(
        &registry,
        &mut usdt_pool,
        borrow_amount,
        &clock,
        scenario.ctx(),
    );

    let usdc_price = build_demo_usdc_price_info_object(&mut scenario, &clock);
    let usdt_price = build_demo_usdt_price_info_object(&mut scenario, &clock);

    // This should fail during prove_and_destroy_request
    mm.prove_and_destroy_request<USDC, USDT, USDT>(
        &registry,
        &mut usdt_pool,
        &pool,
        &usdc_price,
        &usdt_price,
        &clock,
        request,
    );

    abort
}

// Repay tests
#[test, expected_failure(abort_code = margin_manager::EIncorrectMarginPool)]
fun test_repay_fails_wrong_pool() {
    let (mut scenario, mut clock, admin_cap, maintainer_cap) = setup_margin_registry();

    clock.set_for_testing(1000000);
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

    let (usdc_pool_cap, usdt_pool_cap) = get_margin_pool_caps(
        &mut scenario,
        usdc_pool_id,
    );

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
    let mut usdc_pool = scenario.take_shared_by_id<MarginPool<USDC>>(usdc_pool_id);
    let mut usdt_pool = scenario.take_shared_by_id<MarginPool<USDT>>(usdt_pool_id);
    let registry = scenario.take_shared<MarginRegistry>();

    usdc_pool.supply(
        &registry,
        mint_coin<USDC>(1_000_000 * test_constants::usdc_multiplier(), scenario.ctx()),
        &clock,
        scenario.ctx(),
    );
    usdt_pool.supply(
        &registry,
        mint_coin<USDT>(1_000_000 * test_constants::usdt_multiplier(), scenario.ctx()),
        &clock,
        scenario.ctx(),
    );

    usdc_pool.enable_deepbook_pool_for_loan(&registry, pool_id, &usdc_pool_cap, &clock);
    usdt_pool.enable_deepbook_pool_for_loan(&registry, pool_id, &usdt_pool_cap, &clock);

    return_shared_2!(usdc_pool, usdt_pool);
    return_to_sender_2!(&scenario, usdc_pool_cap, usdt_pool_cap);

    scenario.next_tx(test_constants::user1());
    let pool = scenario.take_shared<Pool<USDC, USDT>>();
    margin_manager::new<USDC, USDT>(&pool, &registry, &clock, scenario.ctx());

    scenario.next_tx(test_constants::user1());
    let mut mm = scenario.take_shared<MarginManager<USDC, USDT>>();
    let mut usdt_pool = scenario.take_shared_by_id<MarginPool<USDT>>(usdt_pool_id);
    let mut usdc_pool = scenario.take_shared_by_id<MarginPool<USDC>>(usdc_pool_id);

    mm.deposit<USDC, USDT, USDC>(
        &registry,
        mint_coin<USDC>(10_000 * test_constants::usdc_multiplier(), scenario.ctx()),
        scenario.ctx(),
    );
    let request = mm.borrow_quote<USDC, USDT>(
        &registry,
        &mut usdt_pool,
        2000 * test_constants::usdt_multiplier(),
        &clock,
        scenario.ctx(),
    );

    let usdc_price = build_demo_usdc_price_info_object(&mut scenario, &clock);
    let usdt_price = build_demo_usdt_price_info_object(&mut scenario, &clock);

    mm.prove_and_destroy_request<USDC, USDT, USDT>(
        &registry,
        &mut usdt_pool,
        &pool,
        &usdc_price,
        &usdt_price,
        &clock,
        request,
    );

    // Try to repay to wrong pool (USDC pool instead of USDT pool)
    let repay_coin = mint_coin<USDC>(1000 * test_constants::usdc_multiplier(), scenario.ctx());
    mm.deposit<USDC, USDT, USDC>(&registry, repay_coin, scenario.ctx());
    mm.repay_base<USDC, USDT>(
        &registry,
        &mut usdc_pool,
        option::some(1000 * test_constants::usdc_multiplier()),
        &clock,
        scenario.ctx(),
    );

    abort
}

#[test]
fun test_repay_full_with_none() {
    let (mut scenario, mut clock, admin_cap, maintainer_cap) = setup_margin_registry();

    clock.set_for_testing(1000000);
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

    let (usdc_pool_cap, usdt_pool_cap) = get_margin_pool_caps(
        &mut scenario,
        usdc_pool_id,
    );

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

    // Setup USDT pool
    scenario.next_tx(test_constants::admin());
    let mut usdt_pool = scenario.take_shared_by_id<MarginPool<USDT>>(usdt_pool_id);
    let registry = scenario.take_shared<MarginRegistry>();

    usdt_pool.supply(
        &registry,
        mint_coin<USDT>(1_000_000 * test_constants::usdt_multiplier(), scenario.ctx()),
        &clock,
        scenario.ctx(),
    );
    usdt_pool.enable_deepbook_pool_for_loan(&registry, pool_id, &usdt_pool_cap, &clock);

    return_shared(usdt_pool);
    return_to_sender_2!(&scenario, usdc_pool_cap, usdt_pool_cap);

    // Create margin manager and borrow
    scenario.next_tx(test_constants::user1());
    let pool = scenario.take_shared<Pool<USDC, USDT>>();
    margin_manager::new<USDC, USDT>(&pool, &registry, &clock, scenario.ctx());

    scenario.next_tx(test_constants::user1());
    let mut mm = scenario.take_shared<MarginManager<USDC, USDT>>();
    let mut usdt_pool = scenario.take_shared_by_id<MarginPool<USDT>>(usdt_pool_id);

    // Deposit and borrow
    mm.deposit<USDC, USDT, USDC>(
        &registry,
        mint_coin<USDC>(10_000 * test_constants::usdc_multiplier(), scenario.ctx()),
        scenario.ctx(),
    );
    let request = mm.borrow_quote<USDC, USDT>(
        &registry,
        &mut usdt_pool,
        2000 * test_constants::usdt_multiplier(),
        &clock,
        scenario.ctx(),
    );

    let usdc_price = build_demo_usdc_price_info_object(&mut scenario, &clock);
    let usdt_price = build_demo_usdt_price_info_object(&mut scenario, &clock);

    mm.prove_and_destroy_request<USDC, USDT, USDT>(
        &registry,
        &mut usdt_pool,
        &pool,
        &usdc_price,
        &usdt_price,
        &clock,
        request,
    );

    // Repay full loan
    let repay_coin = mint_coin<USDT>(3000 * test_constants::usdt_multiplier(), scenario.ctx()); // More than enough

    // Deposit the repay coin margin manager's balance manager
    mm.deposit<USDC, USDT, USDT>(&registry, repay_coin, scenario.ctx());

    let repaid_amount = mm.repay_quote<USDC, USDT>(
        &registry,
        &mut usdt_pool,
        option::none(),
        &clock,
        scenario.ctx(),
    );

    assert!(repaid_amount > 0);
    return_shared_3!(mm, usdt_pool, pool);
    destroy_2!(usdc_price, usdt_price);
    cleanup_margin_test(registry, admin_cap, maintainer_cap, clock, scenario);
}

#[test]
fun test_repay_exact_amount_no_rounding_errors() {
    let (mut scenario, mut clock, admin_cap, maintainer_cap) = setup_margin_registry();

    clock.set_for_testing(1000000);
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

    let (usdc_pool_cap, usdt_pool_cap) = get_margin_pool_caps(
        &mut scenario,
        usdc_pool_id,
    );

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
    let mut usdt_pool = scenario.take_shared_by_id<MarginPool<USDT>>(usdt_pool_id);
    let registry = scenario.take_shared<MarginRegistry>();

    usdt_pool.supply(
        &registry,
        mint_coin<USDT>(1_000_000 * test_constants::usdt_multiplier(), scenario.ctx()),
        &clock,
        scenario.ctx(),
    );
    usdt_pool.enable_deepbook_pool_for_loan(&registry, pool_id, &usdt_pool_cap, &clock);

    return_shared(usdt_pool);
    return_to_sender_2!(&scenario, usdc_pool_cap, usdt_pool_cap);

    scenario.next_tx(test_constants::user1());
    let pool = scenario.take_shared<Pool<USDC, USDT>>();
    margin_manager::new<USDC, USDT>(&pool, &registry, &clock, scenario.ctx());

    scenario.next_tx(test_constants::user1());
    let mut mm = scenario.take_shared<MarginManager<USDC, USDT>>();
    let mut usdt_pool = scenario.take_shared_by_id<MarginPool<USDT>>(usdt_pool_id);

    mm.deposit<USDC, USDT, USDC>(
        &registry,
        mint_coin<USDC>(100_000 * test_constants::usdc_multiplier(), scenario.ctx()),
        scenario.ctx(),
    );

    // testing for rounding errors when repaying shares * index
    let test_amounts = vector[
        100 * test_constants::usdt_multiplier(), // Small amount
        1234567890, // Odd amount
        999999999, // Just under 1 USDT
    ];

    test_amounts.do!(|borrow_amount| {
        // Borrow
        let request = mm.borrow_quote<USDC, USDT>(
            &registry,
            &mut usdt_pool,
            borrow_amount,
            &clock,
            scenario.ctx(),
        );

        let usdc_price = build_demo_usdc_price_info_object(&mut scenario, &clock);
        let usdt_price = build_demo_usdt_price_info_object(&mut scenario, &clock);

        mm.prove_and_destroy_request<USDC, USDT, USDT>(
            &registry,
            &mut usdt_pool,
            &pool,
            &usdc_price,
            &usdt_price,
            &clock,
            request,
        );

        // Get the borrowed shares and calculate exact amount (shares * index)
        let borrowed_shares = mm.quote_borrowed_shares();
        let exact_amount = usdt_pool.to_borrow_amount(borrowed_shares);

        // Deposit enough for repayment
        let repay_coin = mint_coin<USDT>(exact_amount + 1000, scenario.ctx()); // Add buffer
        mm.deposit<USDC, USDT, USDT>(&registry, repay_coin, scenario.ctx());

        // Repay the exact amount equal to shares * index
        let repaid_amount = mm.repay_quote<USDC, USDT>(
            &registry,
            &mut usdt_pool,
            option::some(exact_amount),
            &clock,
            scenario.ctx(),
        );

        // Verify no rounding error: repaid amount should equal calculated amount
        assert!(repaid_amount == exact_amount, 0);

        // Verify shares are zero or within 1 mist tolerance
        let remaining_shares = mm.quote_borrowed_shares();
        assert!(remaining_shares <= 1, 1); // At most 1 share due to potential rounding

        // Clean up any remaining debt
        if (remaining_shares > 0) {
            let remaining_amount = usdt_pool.to_borrow_amount(remaining_shares);
            if (remaining_amount > 0) {
                mm.deposit<USDC, USDT, USDT>(
                    &registry,
                    mint_coin<USDT>(remaining_amount + 1, scenario.ctx()),
                    scenario.ctx(),
                );
                mm.repay_quote<USDC, USDT>(
                    &registry,
                    &mut usdt_pool,
                    option::none(),
                    &clock,
                    scenario.ctx(),
                );
            };
        };

        destroy_2!(usdc_price, usdt_price);
    });

    return_shared_3!(mm, usdt_pool, pool);
    cleanup_margin_test(registry, admin_cap, maintainer_cap, clock, scenario);
}

#[test]
fun test_repayment_priority_logic() {
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
    let mut usdc_pool = scenario.take_shared_by_id<MarginPool<USDC>>(usdc_pool_id);
    let mut usdt_pool = scenario.take_shared_by_id<MarginPool<USDT>>(usdt_pool_id);
    let registry = scenario.take_shared<MarginRegistry>();

    usdc_pool.supply(
        &registry,
        mint_coin<USDC>(1_000_000 * test_constants::usdc_multiplier(), scenario.ctx()),
        &clock,
        scenario.ctx(),
    );
    usdt_pool.supply(
        &registry,
        mint_coin<USDT>(1_000_000 * test_constants::usdt_multiplier(), scenario.ctx()),
        &clock,
        scenario.ctx(),
    );

    usdc_pool.enable_deepbook_pool_for_loan(&registry, pool_id, &usdc_pool_cap, &clock);
    usdt_pool.enable_deepbook_pool_for_loan(&registry, pool_id, &usdt_pool_cap, &clock);

    return_shared_2!(usdc_pool, usdt_pool);
    return_to_sender_2!(&scenario, usdc_pool_cap, usdt_pool_cap);

    scenario.next_tx(test_constants::user1());
    let pool = scenario.take_shared<Pool<USDC, USDT>>();
    margin_manager::new<USDC, USDT>(&pool, &registry, &clock, scenario.ctx());

    scenario.next_tx(test_constants::user1());
    let mut mm = scenario.take_shared<MarginManager<USDC, USDT>>();
    let mut usdt_pool = scenario.take_shared_by_id<MarginPool<USDT>>(usdt_pool_id);

    // Setup position with debt
    mm.deposit<USDC, USDT, USDC>(
        &registry,
        mint_coin<USDC>(20_000 * test_constants::usdc_multiplier(), scenario.ctx()),
        scenario.ctx(),
    );

    let request = mm.borrow_quote<USDC, USDT>(
        &registry,
        &mut usdt_pool,
        5_000 * test_constants::usdt_multiplier(),
        &clock,
        scenario.ctx(),
    );

    let usdc_price = build_demo_usdc_price_info_object(&mut scenario, &clock);
    let usdt_price = build_demo_usdt_price_info_object(&mut scenario, &clock);

    mm.prove_and_destroy_request<USDC, USDT, USDT>(
        &registry,
        &mut usdt_pool,
        &pool,
        &usdc_price,
        &usdt_price,
        &clock,
        request,
    );

    advance_time(&mut clock, 1000 * 100); // 100 seconds later

    // Partial repayment
    mm.deposit<USDC, USDT, USDT>(
        &registry,
        mint_coin<USDT>(2_000 * test_constants::usdt_multiplier(), scenario.ctx()),
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
        mint_coin<USDT>(5_000 * test_constants::usdt_multiplier(), scenario.ctx()),
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
    assert!(mm.quote_borrowed_shares() == 0);

    return_shared_3!(mm, usdt_pool, pool);
    destroy_2!(usdc_price, usdt_price);
    cleanup_margin_test(registry, admin_cap, maintainer_cap, clock, scenario);
}
