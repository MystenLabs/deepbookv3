// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module margin_trading::margin_manager_tests;

use deepbook::pool::Pool;
use margin_trading::{
    margin_manager::{Self, MarginManager},
    margin_pool::MarginPool,
    margin_registry::{MarginRegistry, MarginPoolCap},
    test_constants::{Self, USDC, USDT, BTC},
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
        setup_btc_usd_margin_trading
    }
};
use sui::{test_scenario::{Self as test, return_shared}, test_utils::destroy};

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

    scenario.return_to_sender(usdc_pool_cap);
    scenario.return_to_sender(usdt_pool_cap);

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

    destroy(usdc_price);
    destroy(usdt_price);
    cleanup_margin_test(registry, admin_cap, maintainer_cap, clock, scenario);
}

/// Test demonstrates BTC/USD margin trading with borrowing
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

    // BTC price: $60,000
    let btc_price = build_btc_price_info_object(
        &mut scenario,
        60000,
        &clock,
    );
    let usdc_price = build_demo_usdc_price_info_object(&mut scenario, &clock);

    // USER1 creates margin manager and borrows
    scenario.next_tx(test_constants::user1());
    let pool = scenario.take_shared<Pool<BTC, USDC>>();
    let registry = scenario.take_shared<MarginRegistry>();
    margin_manager::new<BTC, USDC>(&pool, &registry, &clock, scenario.ctx());

    scenario.next_tx(test_constants::user1());
    let mut mm = scenario.take_shared<MarginManager<BTC, USDC>>();
    let mut usdc_pool = scenario.take_shared_by_id<MarginPool<USDC>>(usdc_pool_id);

    // Deposit 0.5 BTC as collateral
    let deposit = mint_coin<BTC>(50000000, scenario.ctx()); // 0.5 BTC
    mm.deposit<BTC, USDC, BTC>(&registry, deposit, scenario.ctx());

    let request = mm.borrow_quote<BTC, USDC>(
        &registry,
        &mut usdc_pool,
        15_000_000000, // $15,000
        &clock,
        scenario.ctx(),
    );

    // Prove the borrow is valid
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

    destroy(btc_price);
    destroy(usdc_price);
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

    // Borrow 2 BTC
    let request = mm.borrow_base<BTC, USDC>(
        &registry,
        &mut btc_pool,
        200000000,
        &clock,
        scenario.ctx(),
    );

    // Prove borrow is valid
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

    destroy(btc_price);
    destroy(usdc_price);
    destroy(btc_increased);
    cleanup_margin_test(registry, admin_cap, maintainer_cap, clock, scenario);
}
