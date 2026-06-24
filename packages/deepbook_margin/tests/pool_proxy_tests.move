// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module deepbook_margin::pool_proxy_tests;

use deepbook::{constants, pool::Pool, registry::Registry};
use deepbook_margin::{
    margin_constants,
    margin_manager::{Self, MarginManager},
    margin_pool::{Self, MarginPool},
    margin_registry::{Self, MarginRegistry},
    pool_proxy,
    test_constants::{Self, USDC, USDT},
    test_helpers::{
        Self,
        setup_pool_proxy_test_env,
        setup_margin_registry,
        create_margin_pool,
        create_pool_for_testing,
        enable_deepbook_margin_on_pool,
        initialize_pool_price,
        get_margin_pool_caps,
        default_protocol_config,
        cleanup_margin_test,
        mint_coin,
        destroy_2,
        return_shared_2,
        return_shared_3,
        build_demo_usdc_price_info_object,
        build_demo_usdt_price_info_object,
        build_demo_usdc_price_info_object_with_price,
        setup_orderbook_liquidity_stablecoin,
        setup_orderbook_liquidity_at_prices,
        setup_orderbook_liquidity_out_of_bounds_stablecoin
    }
};
use std::unit_test::{assert_eq, destroy};
use sui::test_scenario::return_shared;
use token::deep::DEEP;

// === Place Limit Order Tests ===
#[test]
fun test_place_limit_order_ok() {
    let (
        mut scenario,
        clock,
        _admin_cap,
        _maintainer_cap,
        base_pool_id,
        quote_pool_id,
        pool_id,
        registry_id,
    ) = setup_pool_proxy_test_env<USDC, USDT>();

    scenario.next_tx(test_constants::user1());
    let mut pool = scenario.take_shared_by_id<Pool<USDC, USDT>>(pool_id);
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

    // Deposit some collateral
    mm.deposit<USDC, USDT, USDC>(
        &registry,
        &usdc_price,
        &usdt_price,
        mint_coin<USDC>(10000 * test_constants::usdc_multiplier(), scenario.ctx()),
        &clock,
        scenario.ctx(),
    );
    destroy_2!(usdc_price, usdt_price);

    // Place a limit order successfully
    // Price must be within 5% of oracle price (1_000_000_000 for USDC/USDT at $1 each)
    let base_pool = scenario.take_shared_by_id<MarginPool<USDC>>(base_pool_id);
    let quote_pool = scenario.take_shared_by_id<MarginPool<USDT>>(quote_pool_id);
    let order_info = test_helpers::place_limit_order_v2_for_test<USDC, USDT>(
        &mut scenario,
        &registry,
        &base_pool,
        &quote_pool,
        &mut mm,
        &mut pool,
        1,
        // client_order_id
        constants::no_restriction(),
        constants::self_matching_allowed(),
        1_000_000_000,
        // price (1.0 in 9 decimals, within 5% of oracle price)
        100 * test_constants::usdc_multiplier(),
        // quantity
        false,
        // is_bid (sell USDC for USDT)
        false,
        // pay_with_deep
        2000000,
        // expire_timestamp
        &clock,
    );
    return_shared(base_pool);
    return_shared(quote_pool);

    // Verify the order was placed (basic sanity check)
    destroy(order_info);

    return_shared_2!(mm, pool);
    cleanup_margin_test(registry, _admin_cap, _maintainer_cap, clock, scenario);
}

#[test, expected_failure(abort_code = pool_proxy::EIncorrectDeepBookPool)]
fun test_place_limit_order_incorrect_pool() {
    let (
        mut scenario,
        clock,
        _admin_cap,
        _maintainer_cap,
        base_pool_id,
        quote_pool_id,
        pool_id,
        registry_id,
    ) = setup_pool_proxy_test_env<USDC, USDT>();

    // Create a wrong pool
    let (wrong_pool_id, _wrong_registry_id) = create_pool_for_testing<USDC, USDT>(&mut scenario);

    scenario.next_tx(test_constants::user1());
    let pool = scenario.take_shared_by_id<Pool<USDC, USDT>>(pool_id);
    let mut wrong_pool = scenario.take_shared_by_id<Pool<USDC, USDT>>(wrong_pool_id);
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

    // Try to place order with wrong pool - should fail
    let base_pool = scenario.take_shared_by_id<MarginPool<USDC>>(base_pool_id);
    let quote_pool = scenario.take_shared_by_id<MarginPool<USDT>>(quote_pool_id);
    test_helpers::place_limit_order_v2_for_test<USDC, USDT>(
        &mut scenario,
        &registry,
        &base_pool,
        &quote_pool,
        &mut mm,
        &mut wrong_pool,
        // Wrong pool!
        1,
        constants::no_restriction(),
        constants::self_matching_allowed(),
        1_000_000,
        100,
        true,
        false,
        0,
        &clock,
    );
    return_shared(base_pool);
    return_shared(quote_pool);

    abort
}

#[test, expected_failure(abort_code = pool_proxy::EIncorrectDeepBookPool)]
fun test_place_limit_order_pool_not_enabled() {
    let (mut scenario, clock, admin_cap, maintainer_cap) = setup_margin_registry();

    // Create a margin pool
    let base_pool_id = create_margin_pool<USDC>(
        &mut scenario,
        &maintainer_cap,
        default_protocol_config(),
        &clock,
    );
    let quote_pool_id = create_margin_pool<USDT>(
        &mut scenario,
        &maintainer_cap,
        default_protocol_config(),
        &clock,
    );

    // Create a pool that is NOT enabled for margin trading
    let (non_margin_pool_id, _non_margin_registry_id) = create_pool_for_testing<USDC, USDT>(
        &mut scenario,
    );

    // Create another pool that IS enabled for margin trading
    let (margin_pool_id, margin_registry_id) = create_pool_for_testing<USDC, USDT>(&mut scenario);

    scenario.next_tx(test_constants::admin());
    let mut registry = scenario.take_shared<MarginRegistry>();
    enable_deepbook_margin_on_pool<USDC, USDT>(
        margin_pool_id,
        &mut registry,
        &admin_cap,
        &clock,
        &mut scenario,
    );
    return_shared(registry);

    // Create margin manager with the enabled pool
    scenario.next_tx(test_constants::user1());
    let margin_pool = scenario.take_shared_by_id<Pool<USDC, USDT>>(margin_pool_id);
    let deepbook_registry = scenario.take_shared_by_id<Registry>(margin_registry_id);
    let mut registry = scenario.take_shared<MarginRegistry>();
    margin_manager::new<USDC, USDT>(
        &margin_pool,
        &deepbook_registry,
        &mut registry,
        &clock,
        scenario.ctx(),
    );
    return_shared(deepbook_registry);

    scenario.next_tx(test_constants::user1());
    let mut mm = scenario.take_shared<MarginManager<USDC, USDT>>();
    let mut non_margin_pool = scenario.take_shared_by_id<Pool<USDC, USDT>>(non_margin_pool_id);
    let usdc_price = build_demo_usdc_price_info_object(&mut scenario, &clock);
    let usdt_price = build_demo_usdt_price_info_object(&mut scenario, &clock);

    mm.deposit<USDC, USDT, USDC>(
        &registry,
        &usdc_price,
        &usdt_price,
        mint_coin<USDC>(10000 * test_constants::usdc_multiplier(), scenario.ctx()),
        &clock,
        scenario.ctx(),
    );
    destroy_2!(usdc_price, usdt_price);

    // Try to place order with non-enabled pool - should fail
    let base_pool = scenario.take_shared_by_id<MarginPool<USDC>>(base_pool_id);
    let quote_pool = scenario.take_shared_by_id<MarginPool<USDT>>(quote_pool_id);
    test_helpers::place_limit_order_v2_for_test<USDC, USDT>(
        &mut scenario,
        &registry,
        &base_pool,
        &quote_pool,
        &mut mm,
        &mut non_margin_pool,
        1,
        constants::no_restriction(),
        constants::self_matching_allowed(),
        1_000_000,
        100 * test_constants::usdc_multiplier(),
        false,
        false,
        2000000,
        &clock,
    );
    return_shared(base_pool);
    return_shared(quote_pool);

    abort
}

// === Place Market Order Tests ===
#[test]
fun test_place_market_order_ok() {
    let (
        mut scenario,
        clock,
        _admin_cap,
        _maintainer_cap,
        base_pool_id,
        quote_pool_id,
        pool_id,
        registry_id,
    ) = setup_pool_proxy_test_env<USDC, USDT>();

    // Set up orderbook liquidity for market orders
    setup_orderbook_liquidity_stablecoin<USDC, USDT>(&mut scenario, pool_id, &clock);

    scenario.next_tx(test_constants::user1());
    let mut pool = scenario.take_shared_by_id<Pool<USDC, USDT>>(pool_id);
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
        mint_coin<USDC>(10000 * test_constants::usdc_multiplier(), scenario.ctx()),
        &clock,
        scenario.ctx(),
    );
    destroy_2!(usdc_price, usdt_price);

    // Sell USDC (is_bid=false) since we deposited USDC
    let base_pool = scenario.take_shared_by_id<MarginPool<USDC>>(base_pool_id);
    let quote_pool = scenario.take_shared_by_id<MarginPool<USDT>>(quote_pool_id);
    let order_info = test_helpers::place_market_order_v2_for_test<USDC, USDT>(
        &mut scenario,
        &registry,
        &base_pool,
        &quote_pool,
        &mut mm,
        &mut pool,
        2,
        // client_order_id
        constants::self_matching_allowed(),
        100 * test_constants::usdc_multiplier(),
        // quantity
        false,
        // is_bid = false (sell USDC)
        false,
        // pay_with_deep
        &clock,
    );
    return_shared(base_pool);
    return_shared(quote_pool);

    destroy(order_info);
    return_shared_2!(mm, pool);
    cleanup_margin_test(registry, _admin_cap, _maintainer_cap, clock, scenario);
}

#[test, expected_failure(abort_code = pool_proxy::EIncorrectDeepBookPool)]
fun test_place_market_order_incorrect_pool() {
    let (
        mut scenario,
        clock,
        _admin_cap,
        _maintainer_cap,
        base_pool_id,
        quote_pool_id,
        pool_id,
        registry_id,
    ) = setup_pool_proxy_test_env<USDC, USDT>();

    let (wrong_pool_id, _wrong_registry_id) = create_pool_for_testing<USDC, USDT>(&mut scenario);

    scenario.next_tx(test_constants::user1());
    let pool = scenario.take_shared_by_id<Pool<USDC, USDT>>(pool_id);
    let mut wrong_pool = scenario.take_shared_by_id<Pool<USDC, USDT>>(wrong_pool_id);
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

    let base_pool = scenario.take_shared_by_id<MarginPool<USDC>>(base_pool_id);
    let quote_pool = scenario.take_shared_by_id<MarginPool<USDT>>(quote_pool_id);
    test_helpers::place_market_order_v2_for_test<USDC, USDT>(
        &mut scenario,
        &registry,
        &base_pool,
        &quote_pool,
        &mut mm,
        &mut wrong_pool,
        // Wrong pool!
        2,
        constants::self_matching_allowed(),
        100,
        true,
        false,
        &clock,
    );
    return_shared(base_pool);
    return_shared(quote_pool);

    abort
}

#[test, expected_failure(abort_code = pool_proxy::EIncorrectDeepBookPool)]
fun test_place_market_order_pool_not_enabled() {
    let (mut scenario, clock, admin_cap, maintainer_cap) = setup_margin_registry();

    let base_pool_id = create_margin_pool<USDC>(
        &mut scenario,
        &maintainer_cap,
        default_protocol_config(),
        &clock,
    );
    let quote_pool_id = create_margin_pool<USDT>(
        &mut scenario,
        &maintainer_cap,
        default_protocol_config(),
        &clock,
    );

    let (non_margin_pool_id, _non_margin_registry_id) = create_pool_for_testing<USDC, USDT>(
        &mut scenario,
    );
    let (margin_pool_id, margin_registry_id) = create_pool_for_testing<USDC, USDT>(&mut scenario);

    scenario.next_tx(test_constants::admin());
    let mut registry = scenario.take_shared<MarginRegistry>();
    enable_deepbook_margin_on_pool<USDC, USDT>(
        margin_pool_id,
        &mut registry,
        &admin_cap,
        &clock,
        &mut scenario,
    );
    return_shared(registry);

    scenario.next_tx(test_constants::user1());
    let margin_pool = scenario.take_shared_by_id<Pool<USDC, USDT>>(margin_pool_id);
    let deepbook_registry = scenario.take_shared_by_id<Registry>(margin_registry_id);
    let mut registry = scenario.take_shared<MarginRegistry>();
    margin_manager::new<USDC, USDT>(
        &margin_pool,
        &deepbook_registry,
        &mut registry,
        &clock,
        scenario.ctx(),
    );
    return_shared(deepbook_registry);

    scenario.next_tx(test_constants::user1());
    let mut mm = scenario.take_shared<MarginManager<USDC, USDT>>();
    let mut non_margin_pool = scenario.take_shared_by_id<Pool<USDC, USDT>>(non_margin_pool_id);
    let usdc_price = build_demo_usdc_price_info_object(&mut scenario, &clock);
    let usdt_price = build_demo_usdt_price_info_object(&mut scenario, &clock);

    mm.deposit<USDC, USDT, USDC>(
        &registry,
        &usdc_price,
        &usdt_price,
        mint_coin<USDC>(10000 * test_constants::usdc_multiplier(), scenario.ctx()),
        &clock,
        scenario.ctx(),
    );
    destroy_2!(usdc_price, usdt_price);

    let base_pool = scenario.take_shared_by_id<MarginPool<USDC>>(base_pool_id);
    let quote_pool = scenario.take_shared_by_id<MarginPool<USDT>>(quote_pool_id);
    test_helpers::place_market_order_v2_for_test<USDC, USDT>(
        &mut scenario,
        &registry,
        &base_pool,
        &quote_pool,
        &mut mm,
        &mut non_margin_pool,
        2,
        constants::self_matching_allowed(),
        100 * test_constants::usdc_multiplier(),
        false,
        false,
        &clock,
    );
    return_shared(base_pool);
    return_shared(quote_pool);

    abort
}

// === Place Reduce Only Limit Order Tests ===

#[test]
fun test_place_reduce_only_limit_order_ok() {
    let (
        mut scenario,
        clock,
        _admin_cap,
        _maintainer_cap,
        base_pool_id,
        quote_pool_id,
        pool_id,
        registry_id,
    ) = setup_pool_proxy_test_env<USDC, USDT>();

    scenario.next_tx(test_constants::user1());
    let mut pool = scenario.take_shared_by_id<Pool<USDC, USDT>>(pool_id);
    let mut registry = scenario.take_shared<MarginRegistry>();
    let mut base_pool = scenario.take_shared_by_id<MarginPool<USDC>>(base_pool_id);
    let quote_pool = scenario.take_shared_by_id<MarginPool<USDT>>(quote_pool_id);
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

    // Deposit USDT as collateral
    mm.deposit<USDC, USDT, USDT>(
        &registry,
        &usdc_price,
        &usdt_price,
        mint_coin<USDT>(10000 * test_constants::usdt_multiplier(), scenario.ctx()),
        &clock,
        scenario.ctx(),
    );

    // Borrow USDC to establish a base debt
    mm.borrow_base<USDC, USDT>(
        &registry,
        &mut base_pool,
        &usdc_price,
        &usdt_price,
        &pool,
        500 * test_constants::usdc_multiplier(), // Borrow 500 USDC
        &clock,
        scenario.ctx(),
    );

    // Withdraw some USDC so we have debt but less assets (creating a net debt position)
    let withdrawn_coin = mm.withdraw<USDC, USDT, USDC>(
        &registry,
        &base_pool,
        &quote_pool,
        &usdc_price,
        &usdt_price,
        &pool,
        300 * test_constants::usdc_multiplier(), // Withdraw 300 USDC
        &clock,
        scenario.ctx(),
    );

    // Destroy the withdrawn coin
    destroy(withdrawn_coin);

    // Now place a reduce-only limit order to buy USDC (reducing the debt)
    // Price must be within 5% of oracle price (1_000_000_000 for USDC/USDT at $1 each)
    let order_info = test_helpers::place_reduce_only_limit_order_v2_for_test<USDC, USDT>(
        &mut scenario,
        &registry,
        &base_pool,
        &quote_pool,
        &mut mm,
        &mut pool,
        // Pass base_pool since we have USDC debt
        1,
        constants::no_restriction(),
        constants::self_matching_allowed(),
        1_000_000_000,
        // price (1.0 in 9 decimals, within 5% of oracle price)
        100 * test_constants::usdc_multiplier(),
        // quantity (less than debt)
        true,
        // is_bid = true (buying USDC to reduce debt)
        false,
        2000000,
        // expire_timestamp
        &clock,
    );

    // Verify the order was placed successfully
    destroy(order_info);
    return_shared_3!(mm, pool, base_pool);
    return_shared(quote_pool);
    destroy(usdc_price);
    destroy(usdt_price);
    cleanup_margin_test(registry, _admin_cap, _maintainer_cap, clock, scenario);
}

#[test]
fun test_place_reduce_only_limit_order_ok_ask() {
    let (
        mut scenario,
        clock,
        _admin_cap,
        _maintainer_cap,
        base_pool_id,
        quote_pool_id,
        pool_id,
        registry_id,
    ) = setup_pool_proxy_test_env<USDC, USDT>();

    scenario.next_tx(test_constants::user1());
    let mut pool = scenario.take_shared_by_id<Pool<USDC, USDT>>(pool_id);
    let mut registry = scenario.take_shared<MarginRegistry>();
    let base_pool = scenario.take_shared_by_id<MarginPool<USDC>>(base_pool_id);
    let mut quote_pool = scenario.take_shared_by_id<MarginPool<USDT>>(quote_pool_id);
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

    // Deposit USDC as collateral
    mm.deposit<USDC, USDT, USDC>(
        &registry,
        &usdc_price,
        &usdt_price,
        mint_coin<USDC>(10000 * test_constants::usdc_multiplier(), scenario.ctx()),
        &clock,
        scenario.ctx(),
    );

    // Borrow USDT to establish a quote debt
    mm.borrow_quote<USDC, USDT>(
        &registry,
        &mut quote_pool,
        &usdc_price,
        &usdt_price,
        &pool,
        500 * test_constants::usdt_multiplier(),
        &clock,
        scenario.ctx(),
    );

    // Withdraw some USDT so we have debt but less assets (creating a net debt position)
    let withdrawn_coin = mm.withdraw<USDC, USDT, USDT>(
        &registry,
        &base_pool,
        &quote_pool,
        &usdc_price,
        &usdt_price,
        &pool,
        300 * test_constants::usdt_multiplier(),
        &clock,
        scenario.ctx(),
    );

    destroy(withdrawn_coin);

    // Now place a reduce-only limit order to sell USDC for USDT (reducing the quote debt)
    let order_info = test_helpers::place_reduce_only_limit_order_v2_for_test<USDC, USDT>(
        &mut scenario,
        &registry,
        &base_pool,
        &quote_pool,
        &mut mm,
        &mut pool,
        1,
        constants::no_restriction(),
        constants::self_matching_allowed(),
        1_000_000_000,
        // price (1.0 in 9 decimals)
        100 * test_constants::usdc_multiplier(),
        // quantity (selling 100 USDC to get ~100 USDT, less than 300 debt)
        false,
        // is_bid = false (selling USDC to get USDT)
        false,
        2000000,
        &clock,
    );

    destroy(order_info);
    return_shared_2!(mm, pool);
    return_shared_2!(base_pool, quote_pool);
    destroy(usdc_price);
    destroy(usdt_price);
    cleanup_margin_test(registry, _admin_cap, _maintainer_cap, clock, scenario);
}

// Pure reduce-only limit ask selling *more* than the net quote debt — the #5
// case the old net-debt cap forbade. Long: 10000 USDC collateral, 500 USDT
// debt, ~200 USDT free (net quote debt ~300). A reduce-only limit ask for 500
// USDC now rests (it is below the 10000 gross base the manager holds); the old
// cap rejected anything above ~300.
#[test]
fun reduce_only_limit_ask_above_net_debt_ok() {
    let (
        mut scenario,
        clock,
        _admin_cap,
        _maintainer_cap,
        base_pool_id,
        quote_pool_id,
        pool_id,
        registry_id,
    ) = setup_pool_proxy_test_env<USDC, USDT>();

    scenario.next_tx(test_constants::user1());
    let mut pool = scenario.take_shared_by_id<Pool<USDC, USDT>>(pool_id);
    let mut registry = scenario.take_shared<MarginRegistry>();
    let base_pool = scenario.take_shared_by_id<MarginPool<USDC>>(base_pool_id);
    let mut quote_pool = scenario.take_shared_by_id<MarginPool<USDT>>(quote_pool_id);
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
        mint_coin<USDC>(10000 * test_constants::usdc_multiplier(), scenario.ctx()),
        &clock,
        scenario.ctx(),
    );
    mm.borrow_quote<USDC, USDT>(
        &registry,
        &mut quote_pool,
        &usdc_price,
        &usdt_price,
        &pool,
        500 * test_constants::usdt_multiplier(),
        &clock,
        scenario.ctx(),
    );
    let withdrawn_coin = mm.withdraw<USDC, USDT, USDT>(
        &registry,
        &base_pool,
        &quote_pool,
        &usdc_price,
        &usdt_price,
        &pool,
        300 * test_constants::usdt_multiplier(),
        &clock,
        scenario.ctx(),
    );
    destroy(withdrawn_coin);

    // 500 USDC > the ~300 net quote debt, < the 10000 gross base held.
    let order_info = test_helpers::place_reduce_only_limit_order_v2_for_test<USDC, USDT>(
        &mut scenario,
        &registry,
        &base_pool,
        &quote_pool,
        &mut mm,
        &mut pool,
        1,
        constants::no_restriction(),
        constants::self_matching_allowed(),
        1_000_000_000,
        500 * test_constants::usdc_multiplier(),
        false,
        false,
        2000000,
        &clock,
    );

    // The order rested (no book liquidity) at the full requested size.
    assert_eq!(order_info.original_quantity(), 500 * test_constants::usdc_multiplier());
    assert_eq!(order_info.executed_quantity(), 0);

    destroy(order_info);
    return_shared_2!(mm, pool);
    return_shared_2!(base_pool, quote_pool);
    destroy(usdc_price);
    destroy(usdt_price);
    cleanup_margin_test(registry, _admin_cap, _maintainer_cap, clock, scenario);
}

#[test, expected_failure(abort_code = pool_proxy::EIncorrectDeepBookPool)]
fun test_place_reduce_only_limit_order_incorrect_pool() {
    let (
        mut scenario,
        clock,
        _admin_cap,
        _maintainer_cap,
        base_pool_id,
        quote_pool_id,
        pool_id,
        registry_id,
    ) = setup_pool_proxy_test_env<USDC, USDT>();

    let (wrong_pool_id, _wrong_registry_id) = create_pool_for_testing<USDC, USDT>(&mut scenario);

    scenario.next_tx(test_constants::user1());
    let pool = scenario.take_shared_by_id<Pool<USDC, USDT>>(pool_id);
    let mut wrong_pool = scenario.take_shared_by_id<Pool<USDC, USDT>>(wrong_pool_id);
    let mut registry = scenario.take_shared<MarginRegistry>();
    let quote_pool = scenario.take_shared_by_id<MarginPool<USDT>>(quote_pool_id);

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
    let base_pool = scenario.take_shared_by_id<MarginPool<USDC>>(base_pool_id);

    test_helpers::place_reduce_only_limit_order_v2_for_test<USDC, USDT>(
        &mut scenario,
        &registry,
        &base_pool,
        &quote_pool,
        &mut mm,
        &mut wrong_pool,
        3,
        constants::no_restriction(),
        constants::self_matching_allowed(),
        1_000_000,
        500,
        false,
        false,
        0,
        &clock,
    );

    abort
}

// Defense-in-depth: passing a margin pool whose id is not registered against
// the manager must abort in `calculate_debts` with EIncorrectMarginPool. The
// only constructable "wrong pool" scenario in tests is a manager with no debt
// at all (the registry enforces one MarginPool<Asset> per asset type, so a
// debt-side mismatch cannot be wired up). The v2 entry dispatches to
// `calculate_debts(quote_margin_pool, ...)` when `has_base_debt` is false,
// and the registered margin_pool_id is None, so the contains-check fails.
#[test, expected_failure(abort_code = margin_manager::EIncorrectMarginPool)]
fun test_place_reduce_only_limit_order_v2_unregistered_pool() {
    let (
        mut scenario,
        clock,
        _admin_cap,
        _maintainer_cap,
        base_pool_id,
        quote_pool_id,
        pool_id,
        registry_id,
    ) = setup_pool_proxy_test_env<USDC, USDT>();

    scenario.next_tx(test_constants::user1());
    let mut pool = scenario.take_shared_by_id<Pool<USDC, USDT>>(pool_id);
    let mut registry = scenario.take_shared<MarginRegistry>();
    let base_pool = scenario.take_shared_by_id<MarginPool<USDC>>(base_pool_id);
    let quote_pool = scenario.take_shared_by_id<MarginPool<USDT>>(quote_pool_id);
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

    test_helpers::place_reduce_only_limit_order_v2_for_test<USDC, USDT>(
        &mut scenario,
        &registry,
        &base_pool,
        &quote_pool,
        &mut mm,
        &mut pool,
        1,
        constants::no_restriction(),
        constants::self_matching_allowed(),
        1_000_000_000,
        100 * test_constants::usdc_multiplier(),
        true,
        false,
        2000000,
        &clock,
    );

    abort
}

#[test, expected_failure(abort_code = pool_proxy::ENotReduceOnlyOrder)]
fun test_place_reduce_only_limit_order_not_reduce_only() {
    let (
        mut scenario,
        clock,
        _admin_cap,
        _maintainer_cap,
        base_pool_id,
        quote_pool_id,
        pool_id,
        registry_id,
    ) = setup_pool_proxy_test_env<USDC, USDT>();

    scenario.next_tx(test_constants::user1());
    let mut pool = scenario.take_shared_by_id<Pool<USDC, USDT>>(pool_id);
    let mut registry = scenario.take_shared<MarginRegistry>();
    let mut quote_pool = scenario.take_shared_by_id<MarginPool<USDT>>(quote_pool_id);
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

    // Deposit some USDT to use as collateral
    mm.deposit<USDC, USDT, USDT>(
        &registry,
        &usdc_price,
        &usdt_price,
        mint_coin<USDT>(10000 * test_constants::usdt_multiplier(), scenario.ctx()),
        &clock,
        scenario.ctx(),
    );
    destroy_2!(usdc_price, usdt_price);

    let usdc_price = build_demo_usdc_price_info_object(&mut scenario, &clock);
    let usdt_price = build_demo_usdt_price_info_object(&mut scenario, &clock);
    // Borrow some USDT to establish relationship with quote pool
    mm.borrow_quote<USDC, USDT>(
        &registry,
        &mut quote_pool,
        &usdc_price,
        &usdt_price,
        &pool,
        100 * test_constants::usdt_multiplier(), // Small borrow amount
        &clock,
        scenario.ctx(),
    );

    // User has no USDC debt but has USDT debt, tries to buy USDC (is_bid = true)
    // This should fail because it's not reducing any USDC position - user is increasing exposure
    // Price must be within 5% of oracle price (1_000_000_000 for USDC/USDT at $1 each)
    let base_pool = scenario.take_shared_by_id<MarginPool<USDC>>(base_pool_id);
    test_helpers::place_reduce_only_limit_order_v2_for_test<USDC, USDT>(
        &mut scenario,
        &registry,
        &base_pool,
        &quote_pool,
        &mut mm,
        &mut pool,
        // Pass quote_pool since we have USDT debt
        1,
        constants::no_restriction(),
        constants::self_matching_allowed(),
        1_000_000_000,
        // price (1.0 in 9 decimals, within 5% of oracle price)
        100 * test_constants::usdc_multiplier(),
        // quantity
        true,
        // is_bid = true (buying USDC)
        false,
        2000000,
        // expire_timestamp
        &clock,
    );

    return_shared_3!(mm, pool, quote_pool);
    return_shared(base_pool);
    destroy(usdc_price);
    destroy(usdt_price);
    cleanup_margin_test(registry, _admin_cap, _maintainer_cap, clock, scenario);
}

#[test, expected_failure(abort_code = pool_proxy::ENotReduceOnlyOrder)]
fun test_place_reduce_only_limit_order_not_reduce_only_quantity_bid() {
    let (
        mut scenario,
        clock,
        _admin_cap,
        _maintainer_cap,
        base_pool_id,
        quote_pool_id,
        pool_id,
        registry_id,
    ) = setup_pool_proxy_test_env<USDC, USDT>();

    scenario.next_tx(test_constants::user1());
    let mut pool = scenario.take_shared_by_id<Pool<USDC, USDT>>(pool_id);
    let mut registry = scenario.take_shared<MarginRegistry>();
    let mut base_pool = scenario.take_shared_by_id<MarginPool<USDC>>(base_pool_id);
    let quote_pool = scenario.take_shared_by_id<MarginPool<USDT>>(quote_pool_id);
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

    // Deposit some USDT to use as collateral
    mm.deposit<USDC, USDT, USDT>(
        &registry,
        &usdc_price,
        &usdt_price,
        mint_coin<USDT>(10000 * test_constants::usdt_multiplier(), scenario.ctx()),
        &clock,
        scenario.ctx(),
    );
    destroy_2!(usdc_price, usdt_price);

    let usdc_price = build_demo_usdc_price_info_object(&mut scenario, &clock);
    let usdt_price = build_demo_usdt_price_info_object(&mut scenario, &clock);
    // Borrow some USDC
    mm.borrow_base<USDC, USDT>(
        &registry,
        &mut base_pool,
        &usdc_price,
        &usdt_price,
        &pool,
        100 * test_constants::usdc_multiplier(), // Small borrow amount
        &clock,
        scenario.ctx(),
    );

    let coin = mm.withdraw<USDC, USDT, USDC>(
        &registry,
        &base_pool,
        &quote_pool, // Pass quote_pool since we have USDT debt
        &usdc_price,
        &usdt_price,
        &pool,
        100 * test_constants::usdc_multiplier(), // Withdraw some USDC so we have have net debt
        &clock,
        scenario.ctx(),
    );
    destroy(coin);

    // User has USDC debt, tries to buy more USDC than debt
    // This should fail because user is trying to buy more USDC than debt
    test_helpers::place_reduce_only_limit_order_v2_for_test<USDC, USDT>(
        &mut scenario,
        &registry,
        &base_pool,
        &quote_pool,
        &mut mm,
        &mut pool,
        // Pass quote_pool since we have USDT debt
        1,
        constants::no_restriction(),
        constants::self_matching_allowed(),
        constants::float_scaling(),
        // price
        101 * test_constants::usdc_multiplier(),
        // quantity
        true,
        // is_bid = true (buying USDC)
        false,
        2000000,
        // expire_timestamp
        &clock,
    );

    return_shared_2!(mm, pool);
    return_shared_2!(base_pool, quote_pool);
    destroy(usdc_price);
    destroy(usdt_price);
    cleanup_margin_test(registry, _admin_cap, _maintainer_cap, clock, scenario);
}

#[test, expected_failure(abort_code = pool_proxy::ENotReduceOnlyOrder)]
fun test_place_reduce_only_limit_order_not_reduce_only_quantity_ask() {
    let (
        mut scenario,
        clock,
        _admin_cap,
        _maintainer_cap,
        base_pool_id,
        quote_pool_id,
        pool_id,
        registry_id,
    ) = setup_pool_proxy_test_env<USDC, USDT>();

    scenario.next_tx(test_constants::user1());
    let mut pool = scenario.take_shared_by_id<Pool<USDC, USDT>>(pool_id);
    let mut registry = scenario.take_shared<MarginRegistry>();
    let base_pool = scenario.take_shared_by_id<MarginPool<USDC>>(base_pool_id);
    let mut quote_pool = scenario.take_shared_by_id<MarginPool<USDT>>(quote_pool_id);
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

    // Deposit some USDC to use as collateral
    mm.deposit<USDC, USDT, USDC>(
        &registry,
        &usdc_price,
        &usdt_price,
        mint_coin<USDC>(10000 * test_constants::usdt_multiplier(), scenario.ctx()),
        &clock,
        scenario.ctx(),
    );
    // Borrow some USDT
    mm.borrow_quote<USDC, USDT>(
        &registry,
        &mut quote_pool,
        &usdc_price,
        &usdt_price,
        &pool,
        100 * test_constants::usdt_multiplier(), // Small borrow amount
        &clock,
        scenario.ctx(),
    );

    let coin = mm.withdraw<USDC, USDT, USDT>(
        &registry,
        &base_pool,
        &quote_pool, // Pass quote_pool since we have USDT debt
        &usdc_price,
        &usdt_price,
        &pool,
        100 * test_constants::usdt_multiplier(), // Withdraw some USDT so we have net debt
        &clock,
        scenario.ctx(),
    );
    destroy(coin);

    // Long position (USDC collateral, USDT debt). The ask tries to sell 10001
    // USDC but the manager holds only 10000 — beyond the gross-holdings cap, so
    // it aborts. Selling between net debt and gross holdings is now allowed.
    test_helpers::place_reduce_only_limit_order_v2_for_test<USDC, USDT>(
        &mut scenario,
        &registry,
        &base_pool,
        &quote_pool,
        &mut mm,
        &mut pool,
        // Pass quote_pool since we have USDT debt
        1,
        constants::no_restriction(),
        constants::self_matching_allowed(),
        constants::float_scaling(),
        // price
        10001 * test_constants::usdc_multiplier(),
        // quantity (exceeds the 10000 USDC the manager holds)
        false,
        // is_bid = false (selling USDC)
        false,
        2000000,
        // expire_timestamp
        &clock,
    );

    return_shared_2!(mm, pool);
    return_shared_2!(base_pool, quote_pool);
    destroy(usdc_price);
    destroy(usdt_price);
    cleanup_margin_test(registry, _admin_cap, _maintainer_cap, clock, scenario);
}

// === Place Reduce Only Market Order Tests ===

// Reduce-only market BID against the standard orderbook (asks at $1.01) fills
// 1% above oracle, leaving the manager's `risk_ratio` slightly worse than
// before. The v2 monotonic-improvement invariant catches that and aborts —
// reduce-only fills must monotonically improve (or hold) solvency. The
// matching limit-order path (placed at exact oracle price) still passes its
// `_ok` test above.
#[test, expected_failure(abort_code = pool_proxy::EReduceOnlyMustImproveRiskRatio)]
fun test_place_reduce_only_market_order_ok() {
    let (
        mut scenario,
        clock,
        _admin_cap,
        _maintainer_cap,
        base_pool_id,
        quote_pool_id,
        pool_id,
        registry_id,
    ) = setup_pool_proxy_test_env<USDC, USDT>();

    // Set up orderbook liquidity for market orders
    setup_orderbook_liquidity_stablecoin<USDC, USDT>(&mut scenario, pool_id, &clock);

    scenario.next_tx(test_constants::user1());
    let mut pool = scenario.take_shared_by_id<Pool<USDC, USDT>>(pool_id);
    let mut registry = scenario.take_shared<MarginRegistry>();
    let mut base_pool = scenario.take_shared_by_id<MarginPool<USDC>>(base_pool_id);
    let quote_pool = scenario.take_shared_by_id<MarginPool<USDT>>(quote_pool_id);
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

    // Deposit USDT as collateral
    mm.deposit<USDC, USDT, USDT>(
        &registry,
        &usdc_price,
        &usdt_price,
        mint_coin<USDT>(10000 * test_constants::usdt_multiplier(), scenario.ctx()),
        &clock,
        scenario.ctx(),
    );
    // Borrow USDC to establish a base debt
    mm.borrow_base<USDC, USDT>(
        &registry,
        &mut base_pool,
        &usdc_price,
        &usdt_price,
        &pool,
        500 * test_constants::usdc_multiplier(), // Borrow 500 USDC
        &clock,
        scenario.ctx(),
    );

    // Withdraw some USDC so we have debt but less assets (creating a net debt position)
    let withdrawn_coin = mm.withdraw<USDC, USDT, USDC>(
        &registry,
        &base_pool,
        &quote_pool,
        &usdc_price,
        &usdt_price,
        &pool,
        300 * test_constants::usdc_multiplier(), // Withdraw 300 USDC
        &clock,
        scenario.ctx(),
    );

    // Destroy the withdrawn coin
    destroy(withdrawn_coin);

    // Now place a reduce-only market order to buy USDC (reducing the debt)
    let order_info = test_helpers::place_reduce_only_market_order_v2_for_test<USDC, USDT>(
        &mut scenario,
        &registry,
        &base_pool,
        &quote_pool,
        &mut mm,
        &mut pool,
        // Pass base_pool since we have USDC debt
        2,
        constants::self_matching_allowed(),
        100 * test_constants::usdc_multiplier(),
        // quantity (less than debt)
        true,
        // is_bid = true (buying USDC to reduce debt)
        false,
        &clock,
    );

    // Verify the order was placed successfully
    destroy(order_info);
    return_shared_3!(mm, pool, base_pool);
    return_shared(quote_pool);
    destroy(usdc_price);
    destroy(usdt_price);
    cleanup_margin_test(registry, _admin_cap, _maintainer_cap, clock, scenario);
}

// Symmetric to `test_place_reduce_only_market_order_ok` — sell-side reduce-only
// market hits bids at $0.99 (1% below oracle), degrading risk_ratio. Aborts on
// the monotonic invariant.
#[test, expected_failure(abort_code = pool_proxy::EReduceOnlyMustImproveRiskRatio)]
fun test_place_reduce_only_market_order_ok_ask() {
    let (
        mut scenario,
        clock,
        _admin_cap,
        _maintainer_cap,
        base_pool_id,
        quote_pool_id,
        pool_id,
        registry_id,
    ) = setup_pool_proxy_test_env<USDC, USDT>();

    setup_orderbook_liquidity_stablecoin<USDC, USDT>(&mut scenario, pool_id, &clock);

    scenario.next_tx(test_constants::user1());
    let mut pool = scenario.take_shared_by_id<Pool<USDC, USDT>>(pool_id);
    let mut registry = scenario.take_shared<MarginRegistry>();
    let base_pool = scenario.take_shared_by_id<MarginPool<USDC>>(base_pool_id);
    let mut quote_pool = scenario.take_shared_by_id<MarginPool<USDT>>(quote_pool_id);
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

    // Deposit USDC as collateral
    mm.deposit<USDC, USDT, USDC>(
        &registry,
        &usdc_price,
        &usdt_price,
        mint_coin<USDC>(10000 * test_constants::usdc_multiplier(), scenario.ctx()),
        &clock,
        scenario.ctx(),
    );

    // Borrow USDT to establish a quote debt
    mm.borrow_quote<USDC, USDT>(
        &registry,
        &mut quote_pool,
        &usdc_price,
        &usdt_price,
        &pool,
        500 * test_constants::usdt_multiplier(),
        &clock,
        scenario.ctx(),
    );

    // Withdraw some USDT so we have debt but less assets (creating a net debt position)
    let withdrawn_coin = mm.withdraw<USDC, USDT, USDT>(
        &registry,
        &base_pool,
        &quote_pool,
        &usdc_price,
        &usdt_price,
        &pool,
        300 * test_constants::usdt_multiplier(),
        &clock,
        scenario.ctx(),
    );

    destroy(withdrawn_coin);

    // Now place a reduce-only market order to sell USDC for USDT (reducing the quote debt)
    let order_info = test_helpers::place_reduce_only_market_order_v2_for_test<USDC, USDT>(
        &mut scenario,
        &registry,
        &base_pool,
        &quote_pool,
        &mut mm,
        &mut pool,
        2,
        constants::self_matching_allowed(),
        100 * test_constants::usdc_multiplier(),
        // quantity (selling 100 USDC to get ~100 USDT, less than 300 debt)
        false,
        // is_bid = false (selling USDC to get USDT)
        false,
        &clock,
    );

    destroy(order_info);
    return_shared_2!(mm, pool);
    return_shared_2!(base_pool, quote_pool);
    destroy(usdc_price);
    destroy(usdt_price);
    cleanup_margin_test(registry, _admin_cap, _maintainer_cap, clock, scenario);
}

// === Place Reduce Only Market Order And Repay Loan Tests ===

// Identical position to the `test_place_reduce_only_market_order_ok`
// expected_failure above: a reduce-only market BID buying USDC fills at $1.01
// (1% above oracle). On the swap-only path that strictly lowers risk_ratio and
// aborts on the monotonic invariant. Bundling the repay turns the slippage into
// a net deleverage, so risk_ratio improves instead and the close succeeds.
#[test]
fun reduce_only_and_repay_bid_succeeds_where_swap_only_fails() {
    let (
        mut scenario,
        clock,
        _admin_cap,
        _maintainer_cap,
        base_pool_id,
        quote_pool_id,
        pool_id,
        registry_id,
    ) = setup_pool_proxy_test_env<USDC, USDT>();

    setup_orderbook_liquidity_stablecoin<USDC, USDT>(&mut scenario, pool_id, &clock);

    scenario.next_tx(test_constants::user1());
    let mut pool = scenario.take_shared_by_id<Pool<USDC, USDT>>(pool_id);
    let mut registry = scenario.take_shared<MarginRegistry>();
    let mut base_pool = scenario.take_shared_by_id<MarginPool<USDC>>(base_pool_id);
    let mut quote_pool = scenario.take_shared_by_id<MarginPool<USDT>>(quote_pool_id);
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

    mm.deposit<USDC, USDT, USDT>(
        &registry,
        &usdc_price,
        &usdt_price,
        mint_coin<USDT>(10000 * test_constants::usdt_multiplier(), scenario.ctx()),
        &clock,
        scenario.ctx(),
    );
    mm.borrow_base<USDC, USDT>(
        &registry,
        &mut base_pool,
        &usdc_price,
        &usdt_price,
        &pool,
        500 * test_constants::usdc_multiplier(),
        &clock,
        scenario.ctx(),
    );
    let withdrawn = mm.withdraw<USDC, USDT, USDC>(
        &registry,
        &base_pool,
        &quote_pool,
        &usdc_price,
        &usdt_price,
        &pool,
        300 * test_constants::usdc_multiplier(),
        &clock,
        scenario.ctx(),
    );
    destroy(withdrawn);

    let shares_before = mm.borrowed_base_shares();
    let rr_before = mm.risk_ratio(
        &registry,
        &usdc_price,
        &usdt_price,
        &pool,
        &base_pool,
        &quote_pool,
        &clock,
    );

    let order_info = test_helpers::place_reduce_only_market_order_and_repay_loan_for_test<
        USDC,
        USDT,
    >(
        &mut scenario,
        &registry,
        &mut mm,
        &mut pool,
        &mut base_pool,
        &mut quote_pool,
        2,
        constants::self_matching_allowed(),
        100 * test_constants::usdc_multiplier(),
        true,
        false,
        &clock,
    );
    destroy(order_info);

    let rr_after = mm.risk_ratio(
        &registry,
        &usdc_price,
        &usdt_price,
        &pool,
        &base_pool,
        &quote_pool,
        &clock,
    );

    // Some base debt was repaid (but not all — net debt position remains), and
    // the deleverage strictly improved solvency despite the 1% buy slippage.
    assert!(mm.borrowed_base_shares() < shares_before);
    assert!(mm.borrowed_base_shares() > 0);
    assert!(rr_after > rr_before);

    return_shared_3!(mm, pool, base_pool);
    return_shared(quote_pool);
    destroy(usdc_price);
    destroy(usdt_price);
    cleanup_margin_test(registry, _admin_cap, _maintainer_cap, clock, scenario);
}

// Sell-side counterpart: reduce-only market ASK selling USDC fills at $0.99 (1%
// below oracle), which aborts the swap-only path. Repaying the proceeds against
// the quote debt deleverages and lifts risk_ratio, so the close succeeds.
#[test]
fun reduce_only_and_repay_ask_succeeds_where_swap_only_fails() {
    let (
        mut scenario,
        clock,
        _admin_cap,
        _maintainer_cap,
        base_pool_id,
        quote_pool_id,
        pool_id,
        registry_id,
    ) = setup_pool_proxy_test_env<USDC, USDT>();

    setup_orderbook_liquidity_stablecoin<USDC, USDT>(&mut scenario, pool_id, &clock);

    scenario.next_tx(test_constants::user1());
    let mut pool = scenario.take_shared_by_id<Pool<USDC, USDT>>(pool_id);
    let mut registry = scenario.take_shared<MarginRegistry>();
    let mut base_pool = scenario.take_shared_by_id<MarginPool<USDC>>(base_pool_id);
    let mut quote_pool = scenario.take_shared_by_id<MarginPool<USDT>>(quote_pool_id);
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
        mint_coin<USDC>(10000 * test_constants::usdc_multiplier(), scenario.ctx()),
        &clock,
        scenario.ctx(),
    );
    mm.borrow_quote<USDC, USDT>(
        &registry,
        &mut quote_pool,
        &usdc_price,
        &usdt_price,
        &pool,
        500 * test_constants::usdt_multiplier(),
        &clock,
        scenario.ctx(),
    );
    let withdrawn = mm.withdraw<USDC, USDT, USDT>(
        &registry,
        &base_pool,
        &quote_pool,
        &usdc_price,
        &usdt_price,
        &pool,
        300 * test_constants::usdt_multiplier(),
        &clock,
        scenario.ctx(),
    );
    destroy(withdrawn);

    let shares_before = mm.borrowed_quote_shares();
    let rr_before = mm.risk_ratio(
        &registry,
        &usdc_price,
        &usdt_price,
        &pool,
        &base_pool,
        &quote_pool,
        &clock,
    );

    let order_info = test_helpers::place_reduce_only_market_order_and_repay_loan_for_test<
        USDC,
        USDT,
    >(
        &mut scenario,
        &registry,
        &mut mm,
        &mut pool,
        &mut base_pool,
        &mut quote_pool,
        2,
        constants::self_matching_allowed(),
        100 * test_constants::usdc_multiplier(),
        false,
        false,
        &clock,
    );
    destroy(order_info);

    let rr_after = mm.risk_ratio(
        &registry,
        &usdc_price,
        &usdt_price,
        &pool,
        &base_pool,
        &quote_pool,
        &clock,
    );

    assert!(mm.borrowed_quote_shares() < shares_before);
    assert!(mm.borrowed_quote_shares() > 0);
    assert!(rr_after > rr_before);

    return_shared_3!(mm, pool, quote_pool);
    return_shared(base_pool);
    destroy(usdc_price);
    destroy(usdt_price);
    cleanup_margin_test(registry, _admin_cap, _maintainer_cap, clock, scenario);
}

// The motivating scenario: a leveraged long whose risk_ratio has drifted to
// 1.20 — below `min_borrow` (1.25) but above `liquidation` (1.10). It is stuck
// in the danger zone: it cannot borrow, and a normal market order would abort
// (`place_market_order_v2` requires post-trade risk_ratio >= min_borrow). The
// bundled close-and-repay is its only wind-down path: it deleverages the
// position back above the borrow floor with a market order.
//
// Position: deposit 2000 USDC, borrow 1000 USDT, withdraw the 1000 USDT
// (risk_ratio at $1.00 is exactly 2.0 = min_withdraw). USDC then drifts to
// $0.60, giving risk_ratio = 2000 * 0.60 / 1000 = 1.20.
#[test]
fun reduce_only_and_repay_closes_from_danger_zone() {
    let (
        mut scenario,
        clock,
        _admin_cap,
        _maintainer_cap,
        base_pool_id,
        quote_pool_id,
        pool_id,
        registry_id,
    ) = setup_pool_proxy_test_env<USDC, USDT>();

    // Liquidity around the drifted $0.60 oracle: a $0.59 bid (within the 5%
    // band, ~1.7% adverse) for the manager's sell to fill against.
    setup_orderbook_liquidity_at_prices<USDC, USDT>(
        &mut scenario,
        pool_id,
        590_000_000,
        610_000_000,
        &clock,
    );

    scenario.next_tx(test_constants::user1());
    let mut pool = scenario.take_shared_by_id<Pool<USDC, USDT>>(pool_id);
    let mut registry = scenario.take_shared<MarginRegistry>();
    let mut base_pool = scenario.take_shared_by_id<MarginPool<USDC>>(base_pool_id);
    let mut quote_pool = scenario.take_shared_by_id<MarginPool<USDT>>(quote_pool_id);
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
        mint_coin<USDC>(2000 * test_constants::usdc_multiplier(), scenario.ctx()),
        &clock,
        scenario.ctx(),
    );
    mm.borrow_quote<USDC, USDT>(
        &registry,
        &mut quote_pool,
        &usdc_price,
        &usdt_price,
        &pool,
        1000 * test_constants::usdt_multiplier(),
        &clock,
        scenario.ctx(),
    );
    let withdrawn = mm.withdraw<USDC, USDT, USDT>(
        &registry,
        &base_pool,
        &quote_pool,
        &usdc_price,
        &usdt_price,
        &pool,
        1000 * test_constants::usdt_multiplier(),
        &clock,
        scenario.ctx(),
    );
    destroy(withdrawn);
    destroy(usdc_price);

    // Drift USDC to $0.60 and refresh the stored price the band keys off of.
    let usdc_drifted = build_demo_usdc_price_info_object_with_price(
        &mut scenario,
        60_000_000,
        &clock,
    );
    pool_proxy::update_current_price<USDC, USDT>(
        &mut registry,
        &pool,
        &usdc_drifted,
        &usdt_price,
        &clock,
    );

    let pool_id_inner = pool.id();
    let shares_before = mm.borrowed_quote_shares();
    let rr_before = mm.risk_ratio(
        &registry,
        &usdc_drifted,
        &usdt_price,
        &pool,
        &base_pool,
        &quote_pool,
        &clock,
    );
    // Exactly 1.20 — in the danger zone: below min_borrow, above liquidation.
    assert!(rr_before == 1_200_000_000);
    assert!(rr_before < registry.min_borrow_risk_ratio(pool_id_inner));
    assert!(rr_before >= registry.liquidation_risk_ratio(pool_id_inner));

    let order_info = pool_proxy::place_reduce_only_market_order_and_repay_loan<USDC, USDT>(
        &registry,
        &mut mm,
        &mut pool,
        &mut base_pool,
        &mut quote_pool,
        &usdc_drifted,
        &usdt_price,
        2,
        constants::self_matching_allowed(),
        1000 * test_constants::usdc_multiplier(),
        false,
        false,
        &clock,
        scenario.ctx(),
    );
    destroy(order_info);

    let rr_after = mm.risk_ratio(
        &registry,
        &usdc_drifted,
        &usdt_price,
        &pool,
        &base_pool,
        &quote_pool,
        &clock,
    );

    // Debt repaid and the position climbed back above the borrow floor.
    assert!(mm.borrowed_quote_shares() < shares_before);
    assert!(rr_after > rr_before);
    assert!(rr_after >= registry.min_borrow_risk_ratio(pool_id_inner));

    return_shared_3!(mm, pool, quote_pool);
    return_shared(base_pool);
    destroy(usdc_drifted);
    destroy(usdt_price);
    cleanup_margin_test(registry, _admin_cap, _maintainer_cap, clock, scenario);
}

// Full close where the ask sells *more* base than the net quote debt — the case
// the old net-debt cap forbade. Long position: 10000 USDC collateral, 500 USDT
// debt, ~200 USDT free, so net quote debt is ~300. Selling 600 USDC produces
// ~594 USDT, which repays the whole 500 debt and clears the loan. Demonstrates
// the gross-holdings cap (issues #4 and #5).
#[test]
fun reduce_only_and_repay_fully_closes_selling_above_net_debt() {
    let (
        mut scenario,
        clock,
        _admin_cap,
        _maintainer_cap,
        base_pool_id,
        quote_pool_id,
        pool_id,
        registry_id,
    ) = setup_pool_proxy_test_env<USDC, USDT>();

    setup_orderbook_liquidity_stablecoin<USDC, USDT>(&mut scenario, pool_id, &clock);

    scenario.next_tx(test_constants::user1());
    let mut pool = scenario.take_shared_by_id<Pool<USDC, USDT>>(pool_id);
    let mut registry = scenario.take_shared<MarginRegistry>();
    let mut base_pool = scenario.take_shared_by_id<MarginPool<USDC>>(base_pool_id);
    let mut quote_pool = scenario.take_shared_by_id<MarginPool<USDT>>(quote_pool_id);
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
        mint_coin<USDC>(10000 * test_constants::usdc_multiplier(), scenario.ctx()),
        &clock,
        scenario.ctx(),
    );
    mm.borrow_quote<USDC, USDT>(
        &registry,
        &mut quote_pool,
        &usdc_price,
        &usdt_price,
        &pool,
        500 * test_constants::usdt_multiplier(),
        &clock,
        scenario.ctx(),
    );
    let withdrawn = mm.withdraw<USDC, USDT, USDT>(
        &registry,
        &base_pool,
        &quote_pool,
        &usdc_price,
        &usdt_price,
        &pool,
        300 * test_constants::usdt_multiplier(),
        &clock,
        scenario.ctx(),
    );
    destroy(withdrawn);

    let shares_before = mm.borrowed_quote_shares();
    let base_before = mm.base_balance();

    // Sell 600 USDC: above the ~300 net quote debt, below the 10000 gross base.
    let order_info = test_helpers::place_reduce_only_market_order_and_repay_loan_for_test<
        USDC,
        USDT,
    >(
        &mut scenario,
        &registry,
        &mut mm,
        &mut pool,
        &mut base_pool,
        &mut quote_pool,
        2,
        constants::self_matching_allowed(),
        600 * test_constants::usdc_multiplier(),
        false,
        false,
        &clock,
    );
    destroy(order_info);

    // The proceeds cleared the entire loan and base was sold down.
    assert!(shares_before > 0);
    assert_eq!(mm.borrowed_quote_shares(), 0);
    assert!(mm.base_balance() < base_before);

    return_shared_3!(mm, pool, quote_pool);
    return_shared(base_pool);
    destroy(usdc_price);
    destroy(usdt_price);
    cleanup_margin_test(registry, _admin_cap, _maintainer_cap, clock, scenario);
}

// A reduce-only-and-repay bid whose quantity exceeds the net base debt is
// rejected: the bid covers a short, so it stays capped at the net short
// (500 - 200 = 300) to avoid flipping into a long. A 400 USDC bid is not
// reduce-only.
#[test, expected_failure(abort_code = pool_proxy::ENotReduceOnlyOrder)]
fun reduce_only_and_repay_quantity_exceeds_debt_aborts() {
    let (
        mut scenario,
        clock,
        _admin_cap,
        _maintainer_cap,
        base_pool_id,
        quote_pool_id,
        pool_id,
        registry_id,
    ) = setup_pool_proxy_test_env<USDC, USDT>();

    setup_orderbook_liquidity_stablecoin<USDC, USDT>(&mut scenario, pool_id, &clock);

    scenario.next_tx(test_constants::user1());
    let mut pool = scenario.take_shared_by_id<Pool<USDC, USDT>>(pool_id);
    let mut registry = scenario.take_shared<MarginRegistry>();
    let mut base_pool = scenario.take_shared_by_id<MarginPool<USDC>>(base_pool_id);
    let mut quote_pool = scenario.take_shared_by_id<MarginPool<USDT>>(quote_pool_id);
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

    mm.deposit<USDC, USDT, USDT>(
        &registry,
        &usdc_price,
        &usdt_price,
        mint_coin<USDT>(10000 * test_constants::usdt_multiplier(), scenario.ctx()),
        &clock,
        scenario.ctx(),
    );
    mm.borrow_base<USDC, USDT>(
        &registry,
        &mut base_pool,
        &usdc_price,
        &usdt_price,
        &pool,
        500 * test_constants::usdc_multiplier(),
        &clock,
        scenario.ctx(),
    );
    let withdrawn = mm.withdraw<USDC, USDT, USDC>(
        &registry,
        &base_pool,
        &quote_pool,
        &usdc_price,
        &usdt_price,
        &pool,
        300 * test_constants::usdc_multiplier(),
        &clock,
        scenario.ctx(),
    );
    destroy(withdrawn);

    // Short position: net base debt is 500 - 200 = 300, so a 400 USDC bid
    // overshoots the net short and is not reduce-only.
    let order_info = test_helpers::place_reduce_only_market_order_and_repay_loan_for_test<
        USDC,
        USDT,
    >(
        &mut scenario,
        &registry,
        &mut mm,
        &mut pool,
        &mut base_pool,
        &mut quote_pool,
        2,
        constants::self_matching_allowed(),
        400 * test_constants::usdc_multiplier(),
        true,
        false,
        &clock,
    );
    destroy(order_info);

    abort
}

#[test, expected_failure(abort_code = pool_proxy::EIncorrectDeepBookPool)]
fun test_place_reduce_only_market_order_incorrect_pool() {
    let (
        mut scenario,
        clock,
        _admin_cap,
        _maintainer_cap,
        base_pool_id,
        quote_pool_id,
        pool_id,
        registry_id,
    ) = setup_pool_proxy_test_env<USDC, USDT>();

    let (wrong_pool_id, _wrong_registry_id) = create_pool_for_testing<USDC, USDT>(&mut scenario);

    scenario.next_tx(test_constants::user1());
    let pool = scenario.take_shared_by_id<Pool<USDC, USDT>>(pool_id);
    let mut wrong_pool = scenario.take_shared_by_id<Pool<USDC, USDT>>(wrong_pool_id);
    let mut registry = scenario.take_shared<MarginRegistry>();
    let quote_pool = scenario.take_shared_by_id<MarginPool<USDT>>(quote_pool_id);

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
    let base_pool = scenario.take_shared_by_id<MarginPool<USDC>>(base_pool_id);

    test_helpers::place_reduce_only_market_order_v2_for_test<USDC, USDT>(
        &mut scenario,
        &registry,
        &base_pool,
        &quote_pool,
        &mut mm,
        &mut wrong_pool,
        4,
        constants::self_matching_allowed(),
        500,
        false,
        false,
        &clock,
    );

    abort
}

// Market-order counterpart of `test_place_reduce_only_limit_order_v2_unregistered_pool`.
// See that test for the rationale (registry uniqueness blocks a debt-side
// mismatch; only the no-debt path is constructable).
#[test, expected_failure(abort_code = margin_manager::EIncorrectMarginPool)]
fun test_place_reduce_only_market_order_v2_unregistered_pool() {
    let (
        mut scenario,
        clock,
        _admin_cap,
        _maintainer_cap,
        base_pool_id,
        quote_pool_id,
        pool_id,
        registry_id,
    ) = setup_pool_proxy_test_env<USDC, USDT>();

    scenario.next_tx(test_constants::user1());
    let mut pool = scenario.take_shared_by_id<Pool<USDC, USDT>>(pool_id);
    let mut registry = scenario.take_shared<MarginRegistry>();
    let base_pool = scenario.take_shared_by_id<MarginPool<USDC>>(base_pool_id);
    let quote_pool = scenario.take_shared_by_id<MarginPool<USDT>>(quote_pool_id);
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

    test_helpers::place_reduce_only_market_order_v2_for_test<USDC, USDT>(
        &mut scenario,
        &registry,
        &base_pool,
        &quote_pool,
        &mut mm,
        &mut pool,
        2,
        constants::self_matching_allowed(),
        100 * test_constants::usdc_multiplier(),
        true,
        false,
        &clock,
    );

    abort
}

#[test, expected_failure(abort_code = pool_proxy::ENotReduceOnlyOrder)]
fun test_place_reduce_only_market_order_not_reduce_only() {
    let (
        mut scenario,
        clock,
        _admin_cap,
        _maintainer_cap,
        base_pool_id,
        quote_pool_id,
        pool_id,
        registry_id,
    ) = setup_pool_proxy_test_env<USDC, USDT>();

    // Set up orderbook liquidity for market orders
    setup_orderbook_liquidity_stablecoin<USDC, USDT>(&mut scenario, pool_id, &clock);

    scenario.next_tx(test_constants::user1());
    let mut pool = scenario.take_shared_by_id<Pool<USDC, USDT>>(pool_id);
    let mut registry = scenario.take_shared<MarginRegistry>();
    let mut quote_pool = scenario.take_shared_by_id<MarginPool<USDT>>(quote_pool_id);
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

    // Deposit some USDT to use as collateral
    mm.deposit<USDC, USDT, USDT>(
        &registry,
        &usdc_price,
        &usdt_price,
        mint_coin<USDT>(10000 * test_constants::usdt_multiplier(), scenario.ctx()),
        &clock,
        scenario.ctx(),
    );
    destroy_2!(usdc_price, usdt_price);

    let usdc_price = build_demo_usdc_price_info_object(&mut scenario, &clock);
    let usdt_price = build_demo_usdt_price_info_object(&mut scenario, &clock);
    // Borrow some USDT to establish relationship with quote pool
    mm.borrow_quote<USDC, USDT>(
        &registry,
        &mut quote_pool,
        &usdc_price,
        &usdt_price,
        &pool,
        100 * test_constants::usdt_multiplier(), // Small borrow amount
        &clock,
        scenario.ctx(),
    );

    // User has no USDC debt but has USDT debt, tries to buy USDC (is_bid = true)
    // This should fail because it's not reducing any USDC position - user is increasing exposure
    let base_pool = scenario.take_shared_by_id<MarginPool<USDC>>(base_pool_id);
    test_helpers::place_reduce_only_market_order_v2_for_test<USDC, USDT>(
        &mut scenario,
        &registry,
        &base_pool,
        &quote_pool,
        &mut mm,
        &mut pool,
        // Pass quote_pool since we have USDT debt
        3,
        constants::self_matching_allowed(),
        100 * test_constants::usdc_multiplier(),
        // quantity
        true,
        // is_bid = true (buying USDC)
        false,
        &clock,
    );

    return_shared_3!(mm, pool, quote_pool);
    return_shared(base_pool);
    destroy(usdc_price);
    destroy(usdt_price);
    cleanup_margin_test(registry, _admin_cap, _maintainer_cap, clock, scenario);
}

#[test, expected_failure(abort_code = pool_proxy::ENotReduceOnlyOrder)]
fun test_place_reduce_only_market_order_not_reduce_only_quantity_bid() {
    let (
        mut scenario,
        clock,
        _admin_cap,
        _maintainer_cap,
        base_pool_id,
        quote_pool_id,
        pool_id,
        registry_id,
    ) = setup_pool_proxy_test_env<USDC, USDT>();

    setup_orderbook_liquidity_stablecoin<USDC, USDT>(&mut scenario, pool_id, &clock);

    scenario.next_tx(test_constants::user1());
    let mut pool = scenario.take_shared_by_id<Pool<USDC, USDT>>(pool_id);
    let mut registry = scenario.take_shared<MarginRegistry>();
    let mut base_pool = scenario.take_shared_by_id<MarginPool<USDC>>(base_pool_id);
    let quote_pool = scenario.take_shared_by_id<MarginPool<USDT>>(quote_pool_id);
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

    mm.deposit<USDC, USDT, USDT>(
        &registry,
        &usdc_price,
        &usdt_price,
        mint_coin<USDT>(10000 * test_constants::usdt_multiplier(), scenario.ctx()),
        &clock,
        scenario.ctx(),
    );

    mm.borrow_base<USDC, USDT>(
        &registry,
        &mut base_pool,
        &usdc_price,
        &usdt_price,
        &pool,
        100 * test_constants::usdc_multiplier(),
        &clock,
        scenario.ctx(),
    );

    let coin = mm.withdraw<USDC, USDT, USDC>(
        &registry,
        &base_pool,
        &quote_pool,
        &usdc_price,
        &usdt_price,
        &pool,
        100 * test_constants::usdc_multiplier(),
        &clock,
        scenario.ctx(),
    );
    destroy(coin);

    // User has USDC debt of 100, tries to buy 101 USDC (more than debt)
    test_helpers::place_reduce_only_market_order_v2_for_test<USDC, USDT>(
        &mut scenario,
        &registry,
        &base_pool,
        &quote_pool,
        &mut mm,
        &mut pool,
        4,
        constants::self_matching_allowed(),
        101 * test_constants::usdc_multiplier(),
        true,
        // is_bid
        false,
        &clock,
    );

    abort
}

#[test, expected_failure(abort_code = pool_proxy::ENotReduceOnlyOrder)]
fun test_place_reduce_only_market_order_not_reduce_only_quantity_ask() {
    let (
        mut scenario,
        clock,
        _admin_cap,
        _maintainer_cap,
        base_pool_id,
        quote_pool_id,
        pool_id,
        registry_id,
    ) = setup_pool_proxy_test_env<USDC, USDT>();

    setup_orderbook_liquidity_stablecoin<USDC, USDT>(&mut scenario, pool_id, &clock);

    scenario.next_tx(test_constants::user1());
    let mut pool = scenario.take_shared_by_id<Pool<USDC, USDT>>(pool_id);
    let mut registry = scenario.take_shared<MarginRegistry>();
    let base_pool = scenario.take_shared_by_id<MarginPool<USDC>>(base_pool_id);
    let mut quote_pool = scenario.take_shared_by_id<MarginPool<USDT>>(quote_pool_id);
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
        mint_coin<USDC>(10000 * test_constants::usdc_multiplier(), scenario.ctx()),
        &clock,
        scenario.ctx(),
    );

    mm.borrow_quote<USDC, USDT>(
        &registry,
        &mut quote_pool,
        &usdc_price,
        &usdt_price,
        &pool,
        100 * test_constants::usdt_multiplier(),
        &clock,
        scenario.ctx(),
    );

    let coin = mm.withdraw<USDC, USDT, USDT>(
        &registry,
        &base_pool,
        &quote_pool,
        &usdc_price,
        &usdt_price,
        &pool,
        100 * test_constants::usdt_multiplier(),
        &clock,
        scenario.ctx(),
    );
    destroy(coin);

    // User has USDT debt of 100, tries to sell enough to get more than 100 USDT (quote_quantity > debt)
    // Selling 150 USDC at ~1:1 should yield ~150 USDT, exceeding the 100 USDT debt
    test_helpers::place_reduce_only_market_order_v2_for_test<USDC, USDT>(
        &mut scenario,
        &registry,
        &base_pool,
        &quote_pool,
        &mut mm,
        &mut pool,
        5,
        constants::self_matching_allowed(),
        150 * test_constants::usdc_multiplier(),
        false,
        // is_bid = false (selling USDC to get USDT)
        false,
        &clock,
    );

    abort
}

// === Stake Tests ===
#[test]
fun test_stake_ok() {
    let (
        mut scenario,
        clock,
        _admin_cap,
        _maintainer_cap,
        _base_pool_id,
        _quote_pool_id,
        pool_id,
        registry_id,
    ) = setup_pool_proxy_test_env<USDC, USDT>();

    scenario.next_tx(test_constants::user1());
    let mut pool = scenario.take_shared_by_id<Pool<USDC, USDT>>(pool_id);
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

    // Deposit DEEP tokens
    mm.deposit<USDC, USDT, DEEP>(
        &registry,
        &usdc_price,
        &usdt_price,
        mint_coin<DEEP>(1000 * test_constants::deep_multiplier(), scenario.ctx()),
        &clock,
        scenario.ctx(),
    );
    destroy_2!(usdc_price, usdt_price);

    // Stake DEEP tokens - should work since this is not a DEEP margin manager
    pool_proxy::stake<USDC, USDT>(
        &registry,
        &mut mm,
        &mut pool,
        100 * test_constants::deep_multiplier(), // 100 DEEP
        scenario.ctx(),
    );

    return_shared_2!(mm, pool);
    cleanup_margin_test(registry, _admin_cap, _maintainer_cap, clock, scenario);
}

#[test, expected_failure(abort_code = pool_proxy::ECannotStakeWithDeepMarginManager)]
fun test_stake_with_deep_margin_manager() {
    let (
        mut scenario,
        clock,
        _admin_cap,
        _maintainer_cap,
        _base_pool_id,
        _quote_pool_id,
        pool_id,
        registry_id,
    ) = setup_pool_proxy_test_env<DEEP, USDT>();

    scenario.next_tx(test_constants::user1());
    let mut pool = scenario.take_shared_by_id<Pool<DEEP, USDT>>(pool_id);
    let mut registry = scenario.take_shared<MarginRegistry>();
    let deepbook_registry = scenario.take_shared_by_id<Registry>(registry_id);
    margin_manager::new<DEEP, USDT>(
        &pool,
        &deepbook_registry,
        &mut registry,
        &clock,
        scenario.ctx(),
    );
    return_shared(deepbook_registry);

    scenario.next_tx(test_constants::user1());
    let mut mm = scenario.take_shared<MarginManager<DEEP, USDT>>();

    // Try to stake with DEEP margin manager - should fail
    pool_proxy::stake<DEEP, USDT>(
        &registry,
        &mut mm,
        &mut pool,
        100 * test_constants::deep_multiplier(),
        scenario.ctx(),
    );

    abort
}

// === Other Function Tests ===
#[test]
fun test_modify_order_ok() {
    let (
        mut scenario,
        clock,
        _admin_cap,
        _maintainer_cap,
        base_pool_id,
        quote_pool_id,
        pool_id,
        registry_id,
    ) = setup_pool_proxy_test_env<USDC, USDT>();

    scenario.next_tx(test_constants::user1());
    let mut pool = scenario.take_shared_by_id<Pool<USDC, USDT>>(pool_id);
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
        mint_coin<USDC>(10000 * test_constants::usdc_multiplier(), scenario.ctx()),
        &clock,
        scenario.ctx(),
    );
    destroy_2!(usdc_price, usdt_price);

    // First place an order
    let base_pool = scenario.take_shared_by_id<MarginPool<USDC>>(base_pool_id);
    let quote_pool = scenario.take_shared_by_id<MarginPool<USDT>>(quote_pool_id);
    let order_info = test_helpers::place_limit_order_v2_for_test<USDC, USDT>(
        &mut scenario,
        &registry,
        &base_pool,
        &quote_pool,
        &mut mm,
        &mut pool,
        1,
        constants::no_restriction(),
        constants::self_matching_allowed(),
        1_000_000_000,
        // price (1.0 in 9 decimals)
        100 * test_constants::usdc_multiplier(),
        false,
        // is_bid (sell USDC for USDT)
        false,
        2000000,
        // expire_timestamp
        &clock,
    );
    return_shared(base_pool);
    return_shared(quote_pool);

    let order_id = order_info.order_id();

    // Now modify the order (new quantity must be less than original)
    pool_proxy::modify_order<USDC, USDT>(
        &registry,
        &mut mm,
        &mut pool,
        order_id,
        50 * test_constants::usdc_multiplier(), // new quantity (less than original)
        &clock,
        scenario.ctx(),
    );

    destroy(order_info);
    return_shared_2!(mm, pool);
    cleanup_margin_test(registry, _admin_cap, _maintainer_cap, clock, scenario);
}

#[test]
fun test_cancel_order_ok() {
    let (
        mut scenario,
        clock,
        _admin_cap,
        _maintainer_cap,
        base_pool_id,
        quote_pool_id,
        pool_id,
        registry_id,
    ) = setup_pool_proxy_test_env<USDC, USDT>();

    scenario.next_tx(test_constants::user1());
    let mut pool = scenario.take_shared_by_id<Pool<USDC, USDT>>(pool_id);
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
        mint_coin<USDC>(10000 * test_constants::usdc_multiplier(), scenario.ctx()),
        &clock,
        scenario.ctx(),
    );
    destroy_2!(usdc_price, usdt_price);

    let base_pool = scenario.take_shared_by_id<MarginPool<USDC>>(base_pool_id);
    let quote_pool = scenario.take_shared_by_id<MarginPool<USDT>>(quote_pool_id);
    let order_info = test_helpers::place_limit_order_v2_for_test<USDC, USDT>(
        &mut scenario,
        &registry,
        &base_pool,
        &quote_pool,
        &mut mm,
        &mut pool,
        1,
        constants::no_restriction(),
        constants::self_matching_allowed(),
        1_000_000_000,
        // price (1.0 in 9 decimals)
        100 * test_constants::usdc_multiplier(),
        false,
        // is_bid (sell USDC for USDT)
        false,
        2000000,
        // expire_timestamp
        &clock,
    );
    return_shared(base_pool);
    return_shared(quote_pool);

    let order_id = order_info.order_id();

    // Cancel the order
    pool_proxy::cancel_order<USDC, USDT>(
        &registry,
        &mut mm,
        &mut pool,
        order_id,
        &clock,
        scenario.ctx(),
    );

    destroy(order_info);
    return_shared_2!(mm, pool);
    cleanup_margin_test(registry, _admin_cap, _maintainer_cap, clock, scenario);
}

#[test]
fun test_cancel_orders_ok() {
    let (
        mut scenario,
        clock,
        _admin_cap,
        _maintainer_cap,
        base_pool_id,
        quote_pool_id,
        pool_id,
        registry_id,
    ) = setup_pool_proxy_test_env<USDC, USDT>();

    scenario.next_tx(test_constants::user1());
    let mut pool = scenario.take_shared_by_id<Pool<USDC, USDT>>(pool_id);
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
        mint_coin<USDC>(10000 * test_constants::usdc_multiplier(), scenario.ctx()),
        &clock,
        scenario.ctx(),
    );
    destroy_2!(usdc_price, usdt_price);

    let base_pool = scenario.take_shared_by_id<MarginPool<USDC>>(base_pool_id);
    let quote_pool = scenario.take_shared_by_id<MarginPool<USDT>>(quote_pool_id);
    let order_info1 = test_helpers::place_limit_order_v2_for_test<USDC, USDT>(
        &mut scenario,
        &registry,
        &base_pool,
        &quote_pool,
        &mut mm,
        &mut pool,
        1,
        constants::no_restriction(),
        constants::self_matching_allowed(),
        1_000_000_000,
        // price (1.0 in 9 decimals)
        1000 * test_constants::usdc_multiplier(),
        // Increased quantity to meet minimum size
        false,
        // is_bid (sell USDC for USDT)
        false,
        2000000,
        // expire_timestamp
        &clock,
    );
    let order_info2 = test_helpers::place_limit_order_v2_for_test<USDC, USDT>(
        &mut scenario,
        &registry,
        &base_pool,
        &quote_pool,
        &mut mm,
        &mut pool,
        2,
        constants::no_restriction(),
        constants::self_matching_allowed(),
        1_020_000_000,
        // price (1.02 in 9 decimals, slightly higher)
        1000 * test_constants::usdc_multiplier(),
        // Increased quantity to meet minimum size
        false,
        // is_bid (sell USDC for USDT)
        false,
        2000000,
        // expire_timestamp
        &clock,
    );
    return_shared(base_pool);
    return_shared(quote_pool);

    let order_ids = vector[order_info1.order_id(), order_info2.order_id()];

    pool_proxy::cancel_orders<USDC, USDT>(
        &registry,
        &mut mm,
        &mut pool,
        order_ids,
        &clock,
        scenario.ctx(),
    );

    destroy_2!(order_info1, order_info2);
    return_shared_2!(mm, pool);
    cleanup_margin_test(registry, _admin_cap, _maintainer_cap, clock, scenario);
}

#[test]
fun test_cancel_all_orders_ok() {
    let (
        mut scenario,
        clock,
        _admin_cap,
        _maintainer_cap,
        _base_pool_id,
        _quote_pool_id,
        pool_id,
        registry_id,
    ) = setup_pool_proxy_test_env<USDC, USDT>();

    scenario.next_tx(test_constants::user1());
    let mut pool = scenario.take_shared_by_id<Pool<USDC, USDT>>(pool_id);
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
        mint_coin<USDC>(10000 * test_constants::usdc_multiplier(), scenario.ctx()),
        &clock,
        scenario.ctx(),
    );
    destroy_2!(usdc_price, usdt_price);

    pool_proxy::cancel_all_orders<USDC, USDT>(
        &registry,
        &mut mm,
        &mut pool,
        &clock,
        scenario.ctx(),
    );

    return_shared_2!(mm, pool);
    cleanup_margin_test(registry, _admin_cap, _maintainer_cap, clock, scenario);
}

#[test]
fun test_withdraw_settled_amounts_ok() {
    let (
        mut scenario,
        clock,
        _admin_cap,
        _maintainer_cap,
        _base_pool_id,
        _quote_pool_id,
        pool_id,
        registry_id,
    ) = setup_pool_proxy_test_env<USDC, USDT>();

    scenario.next_tx(test_constants::user1());
    let mut pool = scenario.take_shared_by_id<Pool<USDC, USDT>>(pool_id);
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

    pool_proxy::withdraw_settled_amounts<USDC, USDT>(
        &registry,
        &mut mm,
        &mut pool,
        scenario.ctx(),
    );

    return_shared_2!(mm, pool);
    cleanup_margin_test(registry, _admin_cap, _maintainer_cap, clock, scenario);
}

#[test]
fun test_unstake_ok() {
    let (
        mut scenario,
        clock,
        _admin_cap,
        _maintainer_cap,
        _base_pool_id,
        _quote_pool_id,
        pool_id,
        registry_id,
    ) = setup_pool_proxy_test_env<USDC, USDT>();

    scenario.next_tx(test_constants::user1());
    let mut pool = scenario.take_shared_by_id<Pool<USDC, USDT>>(pool_id);
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

    pool_proxy::unstake<USDC, USDT>(
        &registry,
        &mut mm,
        &mut pool,
        scenario.ctx(),
    );

    return_shared_2!(mm, pool);
    cleanup_margin_test(registry, _admin_cap, _maintainer_cap, clock, scenario);
}

#[test]
fun test_submit_proposal_ok() {
    let (
        mut scenario,
        clock,
        admin_cap,
        _maintainer_cap,
        _base_pool_id,
        _quote_pool_id,
        pool_id,
        registry_id,
    ) = setup_pool_proxy_test_env<USDC, USDT>();

    scenario.next_tx(test_constants::user1());
    let mut pool = scenario.take_shared_by_id<Pool<USDC, USDT>>(pool_id);
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

    // Deposit DEEP tokens
    mm.deposit<USDC, USDT, DEEP>(
        &registry,
        &usdc_price,
        &usdt_price,
        mint_coin<DEEP>(
            20000 * test_constants::deep_multiplier(),
            scenario.ctx(),
        ), // 20000 DEEP with 6 decimals
        &clock,
        scenario.ctx(),
    );
    destroy_2!(usdc_price, usdt_price);

    // Stake DEEP tokens (10000 DEEP to be safe)
    pool_proxy::stake<USDC, USDT>(
        &registry,
        &mut mm,
        &mut pool,
        10000 * test_constants::deep_multiplier(), // 10000 DEEP stake amount
        scenario.ctx(),
    );

    // Transition to next epoch for stake to become active
    scenario.next_epoch(test_constants::admin());

    // Continue the transaction as user1
    scenario.next_tx(test_constants::user1());

    // Now submit a proposal
    pool_proxy::submit_proposal<USDC, USDT>(
        &registry,
        &mut mm,
        &mut pool,
        600000, // taker_fee
        200000, // maker_fee
        10000 * test_constants::deep_multiplier(), // stake_required
        scenario.ctx(),
    );

    return_shared_2!(mm, pool);
    cleanup_margin_test(registry, admin_cap, _maintainer_cap, clock, scenario);
}

#[test]
fun test_vote_ok() {
    let (
        mut scenario,
        clock,
        admin_cap,
        _maintainer_cap,
        _base_pool_id,
        _quote_pool_id,
        pool_id,
        registry_id,
    ) = setup_pool_proxy_test_env<USDC, USDT>();

    scenario.next_tx(test_constants::user1());
    let mut pool = scenario.take_shared_by_id<Pool<USDC, USDT>>(pool_id);
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

    // Deposit DEEP tokens
    mm.deposit<USDC, USDT, DEEP>(
        &registry,
        &usdc_price,
        &usdt_price,
        mint_coin<DEEP>(
            20000 * test_constants::deep_multiplier(),
            scenario.ctx(),
        ), // 20000 DEEP with 6 decimals
        &clock,
        scenario.ctx(),
    );
    destroy_2!(usdc_price, usdt_price);

    // Stake DEEP tokens (10000 DEEP to be safe)
    pool_proxy::stake<USDC, USDT>(
        &registry,
        &mut mm,
        &mut pool,
        10000 * test_constants::deep_multiplier(), // 10000 DEEP stake amount
        scenario.ctx(),
    );

    // Transition to next epoch for stake to become active
    scenario.next_epoch(test_constants::admin());

    // Continue the transaction as user1
    scenario.next_tx(test_constants::user1());

    // Get the balance manager ID to use as proposal ID
    let balance_manager = mm.balance_manager();
    let balance_manager_id = object::id(balance_manager);

    // First submit a proposal (this creates a proposal with balance_manager_id as the key)
    pool_proxy::submit_proposal<USDC, USDT>(
        &registry,
        &mut mm,
        &mut pool,
        600000, // taker_fee
        200000, // maker_fee
        10000 * test_constants::deep_multiplier(), // stake_required
        scenario.ctx(),
    );

    // Vote on the proposal using balance manager ID as proposal ID
    pool_proxy::vote<USDC, USDT>(
        &registry,
        &mut mm,
        &mut pool,
        balance_manager_id,
        scenario.ctx(),
    );

    return_shared_2!(mm, pool);
    cleanup_margin_test(registry, admin_cap, _maintainer_cap, clock, scenario);
}

#[test]
fun test_claim_rebates_ok() {
    let (
        mut scenario,
        clock,
        _admin_cap,
        _maintainer_cap,
        _base_pool_id,
        _quote_pool_id,
        pool_id,
        registry_id,
    ) = setup_pool_proxy_test_env<USDC, USDT>();

    scenario.next_tx(test_constants::user1());
    let mut pool = scenario.take_shared_by_id<Pool<USDC, USDT>>(pool_id);
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

    pool_proxy::claim_rebates<USDC, USDT>(
        &registry,
        &mut mm,
        &mut pool,
        scenario.ctx(),
    );

    return_shared_2!(mm, pool);
    cleanup_margin_test(registry, _admin_cap, _maintainer_cap, clock, scenario);
}

// === Permissionless Settlement Tests ===
#[test]
fun test_withdraw_settled_amounts_permissionless_ok() {
    let (
        mut scenario,
        clock,
        _admin_cap,
        _maintainer_cap,
        base_pool_id,
        quote_pool_id,
        pool_id,
        registry_id,
    ) = setup_pool_proxy_test_env<USDC, USDT>();

    // User1 creates margin manager and places an order
    scenario.next_tx(test_constants::user1());
    let mut pool = scenario.take_shared_by_id<Pool<USDC, USDT>>(pool_id);
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

    // Deposit USDC
    mm.deposit<USDC, USDT, USDC>(
        &registry,
        &usdc_price,
        &usdt_price,
        mint_coin<USDC>(10000 * test_constants::usdc_multiplier(), scenario.ctx()),
        &clock,
        scenario.ctx(),
    );
    destroy_2!(usdc_price, usdt_price);

    // Place a sell order
    // Price must be within 5% of oracle price (1_000_000_000 for USDC/USDT at $1 each)
    let base_pool = scenario.take_shared_by_id<MarginPool<USDC>>(base_pool_id);
    let quote_pool = scenario.take_shared_by_id<MarginPool<USDT>>(quote_pool_id);
    let order_info = test_helpers::place_limit_order_v2_for_test<USDC, USDT>(
        &mut scenario,
        &registry,
        &base_pool,
        &quote_pool,
        &mut mm,
        &mut pool,
        1,
        // client_order_id
        constants::no_restriction(),
        constants::self_matching_allowed(),
        1_000_000_000,
        // price (1.0 in 9 decimals, within 5% of oracle price)
        100 * test_constants::usdc_multiplier(),
        // quantity
        false,
        // is_bid (sell USDC for USDT)
        false,
        // pay_with_deep
        2000000,
        // expire_timestamp
        &clock,
    );
    return_shared(base_pool);
    return_shared(quote_pool);

    destroy(order_info);

    // User2 places a matching buy order to fill user1's order
    scenario.next_tx(test_constants::user2());
    let deepbook_registry = scenario.take_shared_by_id<Registry>(registry_id);
    margin_manager::new<USDC, USDT>(
        &pool,
        &deepbook_registry,
        &mut registry,
        &clock,
        scenario.ctx(),
    );
    return_shared(deepbook_registry);

    scenario.next_tx(test_constants::user2());
    let mut mm2 = scenario.take_shared<MarginManager<USDC, USDT>>();
    let usdc_price = build_demo_usdc_price_info_object(&mut scenario, &clock);
    let usdt_price = build_demo_usdt_price_info_object(&mut scenario, &clock);

    // Deposit USDT for user2
    mm2.deposit<USDC, USDT, USDT>(
        &registry,
        &usdc_price,
        &usdt_price,
        mint_coin<USDT>(10000 * test_constants::usdt_multiplier(), scenario.ctx()),
        &clock,
        scenario.ctx(),
    );
    destroy_2!(usdc_price, usdt_price);

    // Place a buy order that matches user1's sell order
    let base_pool = scenario.take_shared_by_id<MarginPool<USDC>>(base_pool_id);
    let quote_pool = scenario.take_shared_by_id<MarginPool<USDT>>(quote_pool_id);
    let order_info2 = test_helpers::place_limit_order_v2_for_test<USDC, USDT>(
        &mut scenario,
        &registry,
        &base_pool,
        &quote_pool,
        &mut mm2,
        &mut pool,
        2,
        // client_order_id
        constants::no_restriction(),
        constants::self_matching_allowed(),
        1_000_000_000,
        // same price (1.0 in 9 decimals)
        100 * test_constants::usdc_multiplier(),
        // same quantity
        true,
        // is_bid (buy USDC with USDT)
        false,
        // pay_with_deep
        2000000,
        // expire_timestamp
        &clock,
    );
    return_shared(base_pool);
    return_shared(quote_pool);
    destroy(order_info2);

    // Now user1 has settled balances (received USDT from the trade)
    // User2 (not the owner) calls withdraw_settled_amounts_permissionless for user1
    scenario.next_tx(test_constants::user2());
    pool_proxy::withdraw_settled_amounts_permissionless<USDC, USDT>(
        &registry,
        &mut mm,
        &mut pool,
    );

    // Verify that the settlement succeeded (if it failed, we would have aborted)
    return_shared_3!(mm, mm2, pool);
    cleanup_margin_test(registry, _admin_cap, _maintainer_cap, clock, scenario);
}

#[test, expected_failure(abort_code = ::deepbook::vault::ENoBalanceToSettle)]
fun test_withdraw_settled_amounts_permissionless_no_balance_e() {
    let (
        mut scenario,
        clock,
        _admin_cap,
        _maintainer_cap,
        _base_pool_id,
        _quote_pool_id,
        pool_id,
        registry_id,
    ) = setup_pool_proxy_test_env<USDC, USDT>();

    // User1 creates margin manager but doesn't trade
    scenario.next_tx(test_constants::user1());
    let mut pool = scenario.take_shared_by_id<Pool<USDC, USDT>>(pool_id);
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

    // Try to settle when there's nothing to settle - should fail
    scenario.next_tx(test_constants::user2());
    pool_proxy::withdraw_settled_amounts_permissionless<USDC, USDT>(
        &registry,
        &mut mm,
        &mut pool,
    );

    abort 0
}

#[test, expected_failure(abort_code = margin_manager::EIncorrectDeepBookPool)]
fun test_withdraw_settled_amounts_permissionless_incorrect_pool_e() {
    let (
        mut scenario,
        clock,
        _admin_cap,
        _maintainer_cap,
        _base_pool_id,
        _quote_pool_id,
        pool_id,
        registry_id,
    ) = setup_pool_proxy_test_env<USDC, USDT>();

    // Create a wrong pool
    let (wrong_pool_id, _wrong_registry_id) = create_pool_for_testing<USDC, USDT>(&mut scenario);

    scenario.next_tx(test_constants::user1());
    let pool = scenario.take_shared_by_id<Pool<USDC, USDT>>(pool_id);
    let mut wrong_pool = scenario.take_shared_by_id<Pool<USDC, USDT>>(wrong_pool_id);
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

    // Try to settle with wrong pool - should fail
    scenario.next_tx(test_constants::user2());
    pool_proxy::withdraw_settled_amounts_permissionless<USDC, USDT>(
        &registry,
        &mut mm,
        &mut wrong_pool, // Wrong pool!
    );

    abort 0
}

// === Price Protection Tests ===

#[test, expected_failure(abort_code = margin_registry::EPriceDeviationTooHigh)]
fun test_limit_order_price_too_high() {
    // Test that a limit order with price > 5% above oracle price is rejected
    let (
        mut scenario,
        clock,
        _admin_cap,
        _maintainer_cap,
        base_pool_id,
        quote_pool_id,
        pool_id,
        registry_id,
    ) = setup_pool_proxy_test_env<USDC, USDT>();

    scenario.next_tx(test_constants::user1());
    let mut pool = scenario.take_shared_by_id<Pool<USDC, USDT>>(pool_id);
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

    // Deposit collateral
    mm.deposit<USDC, USDT, USDC>(
        &registry,
        &usdc_price,
        &usdt_price,
        mint_coin<USDC>(10000 * test_constants::usdc_multiplier(), scenario.ctx()),
        &clock,
        scenario.ctx(),
    );

    destroy_2!(usdc_price, usdt_price);

    // Try to place order at price 10% above oracle (1_100_000_000)
    // Oracle price is 1_000_000_000 (1.0), tolerance is 5%
    // 10% above = 1_100_000_000, which exceeds upper bound of 1_050_000_000
    let base_pool = scenario.take_shared_by_id<MarginPool<USDC>>(base_pool_id);
    let quote_pool = scenario.take_shared_by_id<MarginPool<USDT>>(quote_pool_id);
    test_helpers::place_limit_order_v2_for_test<USDC, USDT>(
        &mut scenario,
        &registry,
        &base_pool,
        &quote_pool,
        &mut mm,
        &mut pool,
        1,
        constants::no_restriction(),
        constants::self_matching_allowed(),
        1_100_000_000,
        // 10% above oracle - should fail
        100 * test_constants::usdc_multiplier(),
        true,
        false,
        18446744073709551615,
        &clock,
    );
    return_shared(base_pool);
    return_shared(quote_pool);

    abort 0
}

#[test, expected_failure(abort_code = margin_registry::EPriceDeviationTooHigh)]
fun test_limit_order_price_too_low() {
    // Test that an ask (sell) order with price < 5% below oracle price is rejected
    // Asks only check lower bound - selling below oracle is bad
    let (
        mut scenario,
        clock,
        _admin_cap,
        _maintainer_cap,
        base_pool_id,
        quote_pool_id,
        pool_id,
        registry_id,
    ) = setup_pool_proxy_test_env<USDC, USDT>();

    scenario.next_tx(test_constants::user1());
    let mut pool = scenario.take_shared_by_id<Pool<USDC, USDT>>(pool_id);
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

    // Deposit collateral
    mm.deposit<USDC, USDT, USDC>(
        &registry,
        &usdc_price,
        &usdt_price,
        mint_coin<USDC>(10000 * test_constants::usdc_multiplier(), scenario.ctx()),
        &clock,
        scenario.ctx(),
    );

    destroy_2!(usdc_price, usdt_price);

    // Try to place ask order at price 10% below oracle (900_000_000)
    // Oracle price is 1_000_000_000 (1.0), tolerance is 5%
    // 10% below = 900_000_000, which is below lower bound of 950_000_000
    // For asks, lower bound is checked - should fail
    let base_pool = scenario.take_shared_by_id<MarginPool<USDC>>(base_pool_id);
    let quote_pool = scenario.take_shared_by_id<MarginPool<USDT>>(quote_pool_id);
    test_helpers::place_limit_order_v2_for_test<USDC, USDT>(
        &mut scenario,
        &registry,
        &base_pool,
        &quote_pool,
        &mut mm,
        &mut pool,
        1,
        constants::no_restriction(),
        constants::self_matching_allowed(),
        900_000_000,
        // 10% below oracle - should fail for asks
        100 * test_constants::usdc_multiplier(),
        false,
        // is_bid = false (ask/sell order)
        false,
        18446744073709551615,
        &clock,
    );
    return_shared(base_pool);
    return_shared(quote_pool);

    abort 0
}

#[test]
fun test_limit_order_price_at_upper_bound_ok() {
    // Test that a limit order at exactly 5% above oracle is allowed
    let (
        mut scenario,
        clock,
        _admin_cap,
        _maintainer_cap,
        base_pool_id,
        quote_pool_id,
        pool_id,
        registry_id,
    ) = setup_pool_proxy_test_env<USDC, USDT>();

    scenario.next_tx(test_constants::user1());
    let mut pool = scenario.take_shared_by_id<Pool<USDC, USDT>>(pool_id);
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

    // Deposit collateral
    mm.deposit<USDC, USDT, USDC>(
        &registry,
        &usdc_price,
        &usdt_price,
        mint_coin<USDC>(10000 * test_constants::usdc_multiplier(), scenario.ctx()),
        &clock,
        scenario.ctx(),
    );

    destroy_2!(usdc_price, usdt_price);

    // Place order at price exactly at 5% above oracle (1_050_000_000)
    // Oracle price is 1_000_000_000 (1.0), upper bound = 1_050_000_000
    // Using is_bid=false (sell USDC) since we deposited USDC
    let base_pool = scenario.take_shared_by_id<MarginPool<USDC>>(base_pool_id);
    let quote_pool = scenario.take_shared_by_id<MarginPool<USDT>>(quote_pool_id);
    let order_info = test_helpers::place_limit_order_v2_for_test<USDC, USDT>(
        &mut scenario,
        &registry,
        &base_pool,
        &quote_pool,
        &mut mm,
        &mut pool,
        1,
        constants::no_restriction(),
        constants::self_matching_allowed(),
        1_050_000_000,
        // Exactly at upper bound - should succeed
        100 * test_constants::usdc_multiplier(),
        false,
        // sell USDC for USDT
        false,
        18446744073709551615,
        &clock,
    );
    return_shared(base_pool);
    return_shared(quote_pool);

    assert!(order_info.client_order_id() == 1);
    destroy(order_info);
    return_shared_2!(mm, pool);
    cleanup_margin_test(registry, _admin_cap, _maintainer_cap, clock, scenario);
}

#[test]
fun test_limit_order_price_at_lower_bound_ok() {
    // Test that a limit order at exactly 5% below oracle is allowed
    let (
        mut scenario,
        clock,
        _admin_cap,
        _maintainer_cap,
        base_pool_id,
        quote_pool_id,
        pool_id,
        registry_id,
    ) = setup_pool_proxy_test_env<USDC, USDT>();

    scenario.next_tx(test_constants::user1());
    let mut pool = scenario.take_shared_by_id<Pool<USDC, USDT>>(pool_id);
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

    // Deposit collateral
    mm.deposit<USDC, USDT, USDC>(
        &registry,
        &usdc_price,
        &usdt_price,
        mint_coin<USDC>(10000 * test_constants::usdc_multiplier(), scenario.ctx()),
        &clock,
        scenario.ctx(),
    );

    destroy_2!(usdc_price, usdt_price);

    // Place order at price exactly at 5% below oracle (950_000_000)
    // Oracle price is 1_000_000_000 (1.0), lower bound = 950_000_000
    // Using is_bid=false (sell USDC) since we deposited USDC
    let base_pool = scenario.take_shared_by_id<MarginPool<USDC>>(base_pool_id);
    let quote_pool = scenario.take_shared_by_id<MarginPool<USDT>>(quote_pool_id);
    let order_info = test_helpers::place_limit_order_v2_for_test<USDC, USDT>(
        &mut scenario,
        &registry,
        &base_pool,
        &quote_pool,
        &mut mm,
        &mut pool,
        1,
        constants::no_restriction(),
        constants::self_matching_allowed(),
        950_000_000,
        // Exactly at lower bound - should succeed
        100 * test_constants::usdc_multiplier(),
        false,
        // sell USDC for USDT
        false,
        18446744073709551615,
        &clock,
    );
    return_shared(base_pool);
    return_shared(quote_pool);

    assert!(order_info.client_order_id() == 1);
    destroy(order_info);
    return_shared_2!(mm, pool);
    cleanup_margin_test(registry, _admin_cap, _maintainer_cap, clock, scenario);
}

#[test, expected_failure(abort_code = margin_registry::EToleranceTooLow)]
fun test_set_tolerance_too_low() {
    // Test that tolerance below 1% is rejected
    let (mut scenario, clock, admin_cap, maintainer_cap) = setup_margin_registry();

    // Create margin pools first (required for enabling DeepBook pool)
    let _base_pool_id = create_margin_pool<USDC>(
        &mut scenario,
        &maintainer_cap,
        default_protocol_config(),
        &clock,
    );
    let _quote_pool_id = create_margin_pool<USDT>(
        &mut scenario,
        &maintainer_cap,
        default_protocol_config(),
        &clock,
    );

    // Create and enable a pool
    let (pool_id, _registry_id) = create_pool_for_testing<USDC, USDT>(&mut scenario);

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
    let pool = scenario.take_shared_by_id<Pool<USDC, USDT>>(pool_id);
    let mut registry = scenario.take_shared<MarginRegistry>();

    // Try to set tolerance below 1% (10_000_000)
    registry.set_price_tolerance<USDC, USDT>(
        &admin_cap,
        &pool,
        5_000_000, // 0.5% - too low
        &clock,
    );

    abort 0
}

#[test, expected_failure(abort_code = margin_registry::EToleranceTooHigh)]
fun test_set_tolerance_too_high() {
    // Test that tolerance above 50% is rejected
    let (mut scenario, clock, admin_cap, maintainer_cap) = setup_margin_registry();

    // Create margin pools first (required for enabling DeepBook pool)
    let _base_pool_id = create_margin_pool<USDC>(
        &mut scenario,
        &maintainer_cap,
        default_protocol_config(),
        &clock,
    );
    let _quote_pool_id = create_margin_pool<USDT>(
        &mut scenario,
        &maintainer_cap,
        default_protocol_config(),
        &clock,
    );

    // Create and enable a pool
    let (pool_id, _registry_id) = create_pool_for_testing<USDC, USDT>(&mut scenario);

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
    let pool = scenario.take_shared_by_id<Pool<USDC, USDT>>(pool_id);
    let mut registry = scenario.take_shared<MarginRegistry>();

    // Try to set tolerance above 50% (500_000_000)
    registry.set_price_tolerance<USDC, USDT>(
        &admin_cap,
        &pool,
        600_000_000, // 60% - too high
        &clock,
    );

    abort 0
}

#[test]
fun test_set_tolerance_within_bounds_ok() {
    // Test that setting tolerance within 1%-50% is allowed
    let (mut scenario, clock, admin_cap, maintainer_cap) = setup_margin_registry();

    // Create margin pools first (required for enabling DeepBook pool)
    let _base_pool_id = create_margin_pool<USDC>(
        &mut scenario,
        &maintainer_cap,
        default_protocol_config(),
        &clock,
    );
    let _quote_pool_id = create_margin_pool<USDT>(
        &mut scenario,
        &maintainer_cap,
        default_protocol_config(),
        &clock,
    );

    // Create and enable a pool
    let (pool_id, _registry_id) = create_pool_for_testing<USDC, USDT>(&mut scenario);

    scenario.next_tx(test_constants::admin());
    let mut registry = scenario.take_shared<MarginRegistry>();
    enable_deepbook_margin_on_pool<USDC, USDT>(
        pool_id,
        &mut registry,
        &admin_cap,
        &clock,
        &mut scenario,
    );

    // Initialize price for the pool (required for set_price_tolerance)
    initialize_pool_price<USDC, USDT>(pool_id, &mut registry, &clock, &mut scenario);

    return_shared(registry);

    scenario.next_tx(test_constants::admin());
    let pool = scenario.take_shared_by_id<Pool<USDC, USDT>>(pool_id);
    let mut registry = scenario.take_shared<MarginRegistry>();

    // Set tolerance to 10% (100_000_000) - should succeed
    registry.set_price_tolerance<USDC, USDT>(
        &admin_cap,
        &pool,
        100_000_000, // 10% - within bounds
        &clock,
    );

    return_shared_2!(registry, pool);
    destroy(admin_cap);
    destroy(maintainer_cap);
    destroy(clock);
    scenario.end();
}

#[test, expected_failure(abort_code = margin_registry::EMaxPriceAgeTooLow)]
fun test_set_max_price_age_too_low() {
    let (mut scenario, clock, admin_cap, maintainer_cap) = setup_margin_registry();

    let _base_pool_id = create_margin_pool<USDC>(
        &mut scenario,
        &maintainer_cap,
        default_protocol_config(),
        &clock,
    );
    let _quote_pool_id = create_margin_pool<USDT>(
        &mut scenario,
        &maintainer_cap,
        default_protocol_config(),
        &clock,
    );

    let (pool_id, _registry_id) = create_pool_for_testing<USDC, USDT>(&mut scenario);

    scenario.next_tx(test_constants::admin());
    let mut registry = scenario.take_shared<MarginRegistry>();
    enable_deepbook_margin_on_pool<USDC, USDT>(
        pool_id,
        &mut registry,
        &admin_cap,
        &clock,
        &mut scenario,
    );
    initialize_pool_price<USDC, USDT>(pool_id, &mut registry, &clock, &mut scenario);
    return_shared(registry);

    scenario.next_tx(test_constants::admin());
    let pool = scenario.take_shared_by_id<Pool<USDC, USDT>>(pool_id);
    let mut registry = scenario.take_shared<MarginRegistry>();

    registry.set_max_price_age<USDC, USDT>(
        &admin_cap,
        &pool,
        10_000u64, // 10 seconds - too low
        &clock,
    );

    abort 0
}

#[test, expected_failure(abort_code = margin_registry::EMaxPriceAgeTooHigh)]
fun test_set_max_price_age_too_high() {
    let (mut scenario, clock, admin_cap, maintainer_cap) = setup_margin_registry();

    let _base_pool_id = create_margin_pool<USDC>(
        &mut scenario,
        &maintainer_cap,
        default_protocol_config(),
        &clock,
    );
    let _quote_pool_id = create_margin_pool<USDT>(
        &mut scenario,
        &maintainer_cap,
        default_protocol_config(),
        &clock,
    );

    let (pool_id, _registry_id) = create_pool_for_testing<USDC, USDT>(&mut scenario);

    scenario.next_tx(test_constants::admin());
    let mut registry = scenario.take_shared<MarginRegistry>();
    enable_deepbook_margin_on_pool<USDC, USDT>(
        pool_id,
        &mut registry,
        &admin_cap,
        &clock,
        &mut scenario,
    );
    initialize_pool_price<USDC, USDT>(pool_id, &mut registry, &clock, &mut scenario);
    return_shared(registry);

    scenario.next_tx(test_constants::admin());
    let pool = scenario.take_shared_by_id<Pool<USDC, USDT>>(pool_id);
    let mut registry = scenario.take_shared<MarginRegistry>();

    registry.set_max_price_age<USDC, USDT>(
        &admin_cap,
        &pool,
        4_000_000u64, // 66+ minutes - too high
        &clock,
    );

    abort 0
}

// === Tolerance and Max Price Age Update Effect Tests ===

#[test]
fun test_tolerance_decrease_changes_bounds() {
    // Verify that decreasing tolerance from 5% to 1% correctly changes price bounds
    let (mut scenario, clock, admin_cap, maintainer_cap) = setup_margin_registry();

    let _base_pool_id = create_margin_pool<USDC>(
        &mut scenario,
        &maintainer_cap,
        default_protocol_config(),
        &clock,
    );
    let _quote_pool_id = create_margin_pool<USDT>(
        &mut scenario,
        &maintainer_cap,
        default_protocol_config(),
        &clock,
    );

    let (pool_id, _registry_id) = create_pool_for_testing<USDC, USDT>(&mut scenario);

    scenario.next_tx(test_constants::admin());
    let mut registry = scenario.take_shared<MarginRegistry>();
    enable_deepbook_margin_on_pool<USDC, USDT>(
        pool_id,
        &mut registry,
        &admin_cap,
        &clock,
        &mut scenario,
    );
    initialize_pool_price<USDC, USDT>(pool_id, &mut registry, &clock, &mut scenario);
    return_shared(registry);

    // Verify default 5% tolerance bounds
    scenario.next_tx(test_constants::user1());
    let registry = scenario.take_shared<MarginRegistry>();
    let (lower_bound, upper_bound) = registry.get_price_bounds(pool_id, &clock);
    // Oracle price is 1_000_000_000
    // With 5% tolerance: lower = 950_000_000, upper = 1_050_000_000
    assert!(lower_bound == 950_000_000);
    assert!(upper_bound == 1_050_000_000);
    return_shared(registry);

    // Admin decreases tolerance to 1%
    scenario.next_tx(test_constants::admin());
    let pool = scenario.take_shared_by_id<Pool<USDC, USDT>>(pool_id);
    let mut registry = scenario.take_shared<MarginRegistry>();

    registry.set_price_tolerance<USDC, USDT>(
        &admin_cap,
        &pool,
        10_000_000, // 1% tolerance
        &clock,
    );
    return_shared_2!(registry, pool);

    // Verify new 1% tolerance bounds
    scenario.next_tx(test_constants::user1());
    let registry = scenario.take_shared<MarginRegistry>();
    let (lower_bound, upper_bound) = registry.get_price_bounds(pool_id, &clock);
    // With 1% tolerance: lower = 990_000_000, upper = 1_010_000_000
    assert!(lower_bound == 990_000_000);
    assert!(upper_bound == 1_010_000_000);

    return_shared(registry);
    destroy(admin_cap);
    destroy(maintainer_cap);
    destroy(clock);
    scenario.end();
}

#[test]
fun test_tolerance_increase_changes_bounds() {
    // Verify that increasing tolerance from 5% to 10% correctly changes price bounds
    let (mut scenario, clock, admin_cap, maintainer_cap) = setup_margin_registry();

    let _base_pool_id = create_margin_pool<USDC>(
        &mut scenario,
        &maintainer_cap,
        default_protocol_config(),
        &clock,
    );
    let _quote_pool_id = create_margin_pool<USDT>(
        &mut scenario,
        &maintainer_cap,
        default_protocol_config(),
        &clock,
    );

    let (pool_id, _registry_id) = create_pool_for_testing<USDC, USDT>(&mut scenario);

    scenario.next_tx(test_constants::admin());
    let mut registry = scenario.take_shared<MarginRegistry>();
    enable_deepbook_margin_on_pool<USDC, USDT>(
        pool_id,
        &mut registry,
        &admin_cap,
        &clock,
        &mut scenario,
    );
    initialize_pool_price<USDC, USDT>(pool_id, &mut registry, &clock, &mut scenario);
    return_shared(registry);

    // Verify default 5% tolerance bounds
    scenario.next_tx(test_constants::user1());
    let registry = scenario.take_shared<MarginRegistry>();
    let (lower_bound, upper_bound) = registry.get_price_bounds(pool_id, &clock);
    assert!(lower_bound == 950_000_000); // 1_000_000_000 * 0.95
    assert!(upper_bound == 1_050_000_000); // 1_000_000_000 * 1.05
    return_shared(registry);

    // Admin increases tolerance to 10%
    scenario.next_tx(test_constants::admin());
    let pool = scenario.take_shared_by_id<Pool<USDC, USDT>>(pool_id);
    let mut registry = scenario.take_shared<MarginRegistry>();

    registry.set_price_tolerance<USDC, USDT>(
        &admin_cap,
        &pool,
        100_000_000, // 10% tolerance
        &clock,
    );
    return_shared_2!(registry, pool);

    // Verify new 10% tolerance bounds
    scenario.next_tx(test_constants::user1());
    let registry = scenario.take_shared<MarginRegistry>();
    let (lower_bound, upper_bound) = registry.get_price_bounds(pool_id, &clock);
    // With 10% tolerance:
    // lower_bound = 1_000_000_000 * 0.90 = 900_000_000
    // upper_bound = 1_000_000_000 * 1.10 = 1_100_000_000
    assert!(lower_bound == 900_000_000);
    assert!(upper_bound == 1_100_000_000);

    // A price of 920_000_000 (8% below oracle) is now within bounds
    // Previously with 5% tolerance, lower_bound was 950_000_000, so 920_000_000 would fail
    // Now with 10% tolerance, lower_bound is 900_000_000, so 920_000_000 passes

    return_shared(registry);
    destroy(admin_cap);
    destroy(maintainer_cap);
    destroy(clock);
    scenario.end();
}

#[test, expected_failure(abort_code = margin_registry::EPriceUpdateRequired)]
fun test_max_price_age_decrease_makes_price_stale() {
    // Price is fresh with 5 minute max age, becomes stale after decreasing to 30 seconds
    let (mut scenario, mut clock, admin_cap, maintainer_cap) = setup_margin_registry();

    clock.set_for_testing(1_000_000); // Start at 1 second

    let _base_pool_id = create_margin_pool<USDC>(
        &mut scenario,
        &maintainer_cap,
        default_protocol_config(),
        &clock,
    );
    let _quote_pool_id = create_margin_pool<USDT>(
        &mut scenario,
        &maintainer_cap,
        default_protocol_config(),
        &clock,
    );

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
    initialize_pool_price<USDC, USDT>(pool_id, &mut registry, &clock, &mut scenario);
    return_shared(registry);

    // Advance clock by 1 minute (60,000 ms) - still fresh with default 5 min max age
    clock.increment_for_testing(60_000);

    // Verify price is still fresh
    scenario.next_tx(test_constants::user1());
    let registry = scenario.take_shared<MarginRegistry>();
    let (_lower_bound, _upper_bound) = registry.get_price_bounds(pool_id, &clock);
    return_shared(registry);

    // Admin decreases max_price_age to 30 seconds
    scenario.next_tx(test_constants::admin());
    let pool = scenario.take_shared_by_id<Pool<USDC, USDT>>(pool_id);
    let mut registry = scenario.take_shared<MarginRegistry>();

    registry.set_max_price_age<USDC, USDT>(
        &admin_cap,
        &pool,
        30_000, // 30 seconds
        &clock,
    );
    return_shared_2!(registry, pool);

    // Now price should be stale (1 minute old > 30 second max age)
    scenario.next_tx(test_constants::user1());
    let registry = scenario.take_shared<MarginRegistry>();
    let (_lower_bound, _upper_bound) = registry.get_price_bounds(pool_id, &clock); // Should fail

    return_shared(registry);
    destroy(admin_cap);
    destroy(maintainer_cap);
    destroy(registry_id);
    destroy(clock);
    scenario.end();
}

#[test]
fun test_max_price_age_increase_makes_price_fresh() {
    // Price is stale with 5 minute max age, becomes fresh after increasing to 10 minutes
    let (mut scenario, mut clock, admin_cap, maintainer_cap) = setup_margin_registry();

    clock.set_for_testing(1_000_000); // Start at 1 second

    let _base_pool_id = create_margin_pool<USDC>(
        &mut scenario,
        &maintainer_cap,
        default_protocol_config(),
        &clock,
    );
    let _quote_pool_id = create_margin_pool<USDT>(
        &mut scenario,
        &maintainer_cap,
        default_protocol_config(),
        &clock,
    );

    let (pool_id, _registry_id) = create_pool_for_testing<USDC, USDT>(&mut scenario);

    scenario.next_tx(test_constants::admin());
    let mut registry = scenario.take_shared<MarginRegistry>();
    enable_deepbook_margin_on_pool<USDC, USDT>(
        pool_id,
        &mut registry,
        &admin_cap,
        &clock,
        &mut scenario,
    );
    initialize_pool_price<USDC, USDT>(pool_id, &mut registry, &clock, &mut scenario);
    return_shared(registry);

    // Advance clock by 6 minutes (360,000 ms) - stale with default 5 min max age
    clock.increment_for_testing(360_000);

    // Admin increases max_price_age to 10 minutes before checking
    scenario.next_tx(test_constants::admin());
    let pool = scenario.take_shared_by_id<Pool<USDC, USDT>>(pool_id);
    let mut registry = scenario.take_shared<MarginRegistry>();

    registry.set_max_price_age<USDC, USDT>(
        &admin_cap,
        &pool,
        600_000, // 10 minutes
        &clock,
    );
    return_shared_2!(registry, pool);

    // Now price should be fresh (6 minutes old < 10 minute max age)
    scenario.next_tx(test_constants::user1());
    let registry = scenario.take_shared<MarginRegistry>();
    let (lower_bound, upper_bound) = registry.get_price_bounds(pool_id, &clock);

    // Verify we got valid bounds (price is fresh)
    assert!(lower_bound > 0);
    assert!(upper_bound > lower_bound);

    return_shared(registry);
    destroy(admin_cap);
    destroy(maintainer_cap);
    destroy(clock);
    scenario.end();
}

#[test, expected_failure(abort_code = margin_registry::EPriceDeviationTooHigh)]
fun test_tolerance_decrease_rejects_order_e2e() {
    // End-to-end test: place order fails after tolerance is decreased
    let (mut scenario, clock, admin_cap, maintainer_cap) = setup_margin_registry();

    let base_pool_id = create_margin_pool<USDC>(
        &mut scenario,
        &maintainer_cap,
        default_protocol_config(),
        &clock,
    );
    let quote_pool_id = create_margin_pool<USDT>(
        &mut scenario,
        &maintainer_cap,
        default_protocol_config(),
        &clock,
    );

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
    initialize_pool_price<USDC, USDT>(pool_id, &mut registry, &clock, &mut scenario);
    return_shared(registry);

    // Admin decreases tolerance to 1%
    scenario.next_tx(test_constants::admin());
    let pool = scenario.take_shared_by_id<Pool<USDC, USDT>>(pool_id);
    let mut registry = scenario.take_shared<MarginRegistry>();

    registry.set_price_tolerance<USDC, USDT>(
        &admin_cap,
        &pool,
        10_000_000, // 1% tolerance
        &clock,
    );
    return_shared_2!(registry, pool);

    // Create margin manager and deposit collateral
    scenario.next_tx(test_constants::user1());
    let pool = scenario.take_shared_by_id<Pool<USDC, USDT>>(pool_id);
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
    return_shared_2!(registry, pool);

    scenario.next_tx(test_constants::user1());
    let mut mm = scenario.take_shared<MarginManager<USDC, USDT>>();
    let mut pool = scenario.take_shared_by_id<Pool<USDC, USDT>>(pool_id);
    let registry = scenario.take_shared<MarginRegistry>();
    let usdc_price = build_demo_usdc_price_info_object(&mut scenario, &clock);
    let usdt_price = build_demo_usdt_price_info_object(&mut scenario, &clock);

    mm.deposit<USDC, USDT, USDC>(
        &registry,
        &usdc_price,
        &usdt_price,
        mint_coin<USDC>(10000 * test_constants::usdc_multiplier(), scenario.ctx()),
        &clock,
        scenario.ctx(),
    );
    destroy_2!(usdc_price, usdt_price);

    // Try to place bid at 4% above oracle - should FAIL with 1% tolerance
    let base_pool = scenario.take_shared_by_id<MarginPool<USDC>>(base_pool_id);
    let quote_pool = scenario.take_shared_by_id<MarginPool<USDT>>(quote_pool_id);
    test_helpers::place_limit_order_v2_for_test<USDC, USDT>(
        &mut scenario,
        &registry,
        &base_pool,
        &quote_pool,
        &mut mm,
        &mut pool,
        1,
        constants::no_restriction(),
        constants::self_matching_allowed(),
        1_040_000_000,
        // 4% above oracle
        100 * test_constants::usdc_multiplier(),
        true,
        // is_bid
        false,
        2000000,
        &clock,
    );
    return_shared(base_pool);
    return_shared(quote_pool);

    abort 0
}

#[test, expected_failure(abort_code = margin_registry::EPriceUpdateRequired)]
fun test_max_price_age_decrease_rejects_order_e2e() {
    // End-to-end test: order fails after max_price_age is decreased and price becomes stale
    let (mut scenario, mut clock, admin_cap, maintainer_cap) = setup_margin_registry();

    clock.set_for_testing(1_000_000);

    let base_pool_id = create_margin_pool<USDC>(
        &mut scenario,
        &maintainer_cap,
        default_protocol_config(),
        &clock,
    );
    let quote_pool_id = create_margin_pool<USDT>(
        &mut scenario,
        &maintainer_cap,
        default_protocol_config(),
        &clock,
    );

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
    initialize_pool_price<USDC, USDT>(pool_id, &mut registry, &clock, &mut scenario);
    return_shared(registry);

    // Advance clock by 1 minute
    clock.increment_for_testing(60_000);

    // Admin decreases max_price_age to 30 seconds
    scenario.next_tx(test_constants::admin());
    let pool = scenario.take_shared_by_id<Pool<USDC, USDT>>(pool_id);
    let mut registry = scenario.take_shared<MarginRegistry>();

    registry.set_max_price_age<USDC, USDT>(
        &admin_cap,
        &pool,
        30_000, // 30 seconds
        &clock,
    );
    return_shared_2!(registry, pool);

    // Create margin manager and deposit collateral
    scenario.next_tx(test_constants::user1());
    let pool = scenario.take_shared_by_id<Pool<USDC, USDT>>(pool_id);
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
    return_shared_2!(registry, pool);

    scenario.next_tx(test_constants::user1());
    let mut mm = scenario.take_shared<MarginManager<USDC, USDT>>();
    let mut pool = scenario.take_shared_by_id<Pool<USDC, USDT>>(pool_id);
    let registry = scenario.take_shared<MarginRegistry>();
    let usdc_price = build_demo_usdc_price_info_object(&mut scenario, &clock);
    let usdt_price = build_demo_usdt_price_info_object(&mut scenario, &clock);

    mm.deposit<USDC, USDT, USDC>(
        &registry,
        &usdc_price,
        &usdt_price,
        mint_coin<USDC>(10000 * test_constants::usdc_multiplier(), scenario.ctx()),
        &clock,
        scenario.ctx(),
    );
    destroy_2!(usdc_price, usdt_price);

    // Try to place order - should FAIL because price is stale
    let base_pool = scenario.take_shared_by_id<MarginPool<USDC>>(base_pool_id);
    let quote_pool = scenario.take_shared_by_id<MarginPool<USDT>>(quote_pool_id);
    test_helpers::place_limit_order_v2_for_test<USDC, USDT>(
        &mut scenario,
        &registry,
        &base_pool,
        &quote_pool,
        &mut mm,
        &mut pool,
        1,
        constants::no_restriction(),
        constants::self_matching_allowed(),
        1_000_000_000,
        100 * test_constants::usdc_multiplier(),
        true,
        false,
        2000000,
        &clock,
    );
    return_shared(base_pool);
    return_shared(quote_pool);

    abort 0
}

// === Self-Matching Prevention Tests ===
// Note: Margin trading forces CANCEL_TAKER self-matching option.
// This prevents users from matching against their own orders by canceling the taker side.
// Cross-wallet self-matching between different margin managers cannot be fully prevented
// at the protocol level - see security review for details.

// === Additional Price Protection Boundary Tests ===

#[test, expected_failure(abort_code = margin_registry::EPriceDeviationTooHigh)]
fun test_limit_order_price_just_above_upper_bound_fails() {
    // Test that a bid (buy) order at price 1 unit above upper bound fails
    // Bids only check upper bound - buying above oracle is bad
    let (
        mut scenario,
        clock,
        _admin_cap,
        _maintainer_cap,
        base_pool_id,
        quote_pool_id,
        pool_id,
        registry_id,
    ) = setup_pool_proxy_test_env<USDC, USDT>();

    scenario.next_tx(test_constants::user1());
    let mut pool = scenario.take_shared_by_id<Pool<USDC, USDT>>(pool_id);
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
        mint_coin<USDC>(10000 * test_constants::usdc_multiplier(), scenario.ctx()),
        &clock,
        scenario.ctx(),
    );

    destroy_2!(usdc_price, usdt_price);

    // Oracle price is 1_000_000_000, upper bound = 1_050_000_000
    // Price 1_050_000_001 is just above upper bound - should fail for bids
    let base_pool = scenario.take_shared_by_id<MarginPool<USDC>>(base_pool_id);
    let quote_pool = scenario.take_shared_by_id<MarginPool<USDT>>(quote_pool_id);
    test_helpers::place_limit_order_v2_for_test<USDC, USDT>(
        &mut scenario,
        &registry,
        &base_pool,
        &quote_pool,
        &mut mm,
        &mut pool,
        1,
        constants::no_restriction(),
        constants::self_matching_allowed(),
        1_050_000_001,
        // Just above upper bound
        100 * test_constants::usdc_multiplier(),
        true,
        // is_bid = true (buy order)
        false,
        18446744073709551615,
        &clock,
    );
    return_shared(base_pool);
    return_shared(quote_pool);

    abort 0
}

#[test, expected_failure(abort_code = margin_registry::EPriceDeviationTooHigh)]
fun test_limit_order_price_just_below_lower_bound_fails() {
    // Test that a limit order at price 1 unit below lower bound fails
    let (
        mut scenario,
        clock,
        _admin_cap,
        _maintainer_cap,
        base_pool_id,
        quote_pool_id,
        pool_id,
        registry_id,
    ) = setup_pool_proxy_test_env<USDC, USDT>();

    scenario.next_tx(test_constants::user1());
    let mut pool = scenario.take_shared_by_id<Pool<USDC, USDT>>(pool_id);
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
        mint_coin<USDC>(10000 * test_constants::usdc_multiplier(), scenario.ctx()),
        &clock,
        scenario.ctx(),
    );

    destroy_2!(usdc_price, usdt_price);

    // Oracle price is 1_000_000_000, lower bound = 950_000_000
    // Price 949_999_999 is just below lower bound - should fail
    let base_pool = scenario.take_shared_by_id<MarginPool<USDC>>(base_pool_id);
    let quote_pool = scenario.take_shared_by_id<MarginPool<USDT>>(quote_pool_id);
    test_helpers::place_limit_order_v2_for_test<USDC, USDT>(
        &mut scenario,
        &registry,
        &base_pool,
        &quote_pool,
        &mut mm,
        &mut pool,
        1,
        constants::no_restriction(),
        constants::self_matching_allowed(),
        949_999_999,
        // Just below lower bound
        100 * test_constants::usdc_multiplier(),
        false,
        false,
        18446744073709551615,
        &clock,
    );
    return_shared(base_pool);
    return_shared(quote_pool);

    abort 0
}

#[test]
fun test_bid_order_allowed_at_any_price_below_oracle() {
    // Test that bid (buy) orders can be placed at any price below oracle
    // Bids only check upper bound - buying below oracle is always fine
    let (
        mut scenario,
        clock,
        _admin_cap,
        _maintainer_cap,
        base_pool_id,
        quote_pool_id,
        pool_id,
        registry_id,
    ) = setup_pool_proxy_test_env<USDC, USDT>();

    scenario.next_tx(test_constants::user1());
    let mut pool = scenario.take_shared_by_id<Pool<USDC, USDT>>(pool_id);
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

    // Deposit USDT collateral for buying USDC
    mm.deposit<USDC, USDT, USDT>(
        &registry,
        &usdc_price,
        &usdt_price,
        mint_coin<USDT>(10000 * test_constants::usdt_multiplier(), scenario.ctx()),
        &clock,
        scenario.ctx(),
    );

    destroy_2!(usdc_price, usdt_price);

    // Place bid at 50% below oracle (500_000_000)
    // Oracle price is 1_000_000_000 (1.0), this is way below lower bound of 950_000_000
    // But bids don't check lower bound - should succeed
    let base_pool = scenario.take_shared_by_id<MarginPool<USDC>>(base_pool_id);
    let quote_pool = scenario.take_shared_by_id<MarginPool<USDT>>(quote_pool_id);
    let order_info = test_helpers::place_limit_order_v2_for_test<USDC, USDT>(
        &mut scenario,
        &registry,
        &base_pool,
        &quote_pool,
        &mut mm,
        &mut pool,
        1,
        constants::no_restriction(),
        constants::self_matching_allowed(),
        500_000_000,
        // 50% below oracle - should succeed for bids
        100 * test_constants::usdc_multiplier(),
        true,
        // is_bid = true (buy order)
        false,
        18446744073709551615,
        &clock,
    );
    return_shared(base_pool);
    return_shared(quote_pool);

    assert!(order_info.client_order_id() == 1);
    destroy(order_info);
    return_shared_2!(mm, pool);
    cleanup_margin_test(registry, _admin_cap, _maintainer_cap, clock, scenario);
}

#[test]
fun test_ask_order_allowed_at_any_price_above_oracle() {
    // Test that ask (sell) orders can be placed at any price above oracle
    // Asks only check lower bound - selling above oracle is always fine
    let (
        mut scenario,
        clock,
        _admin_cap,
        _maintainer_cap,
        base_pool_id,
        quote_pool_id,
        pool_id,
        registry_id,
    ) = setup_pool_proxy_test_env<USDC, USDT>();

    scenario.next_tx(test_constants::user1());
    let mut pool = scenario.take_shared_by_id<Pool<USDC, USDT>>(pool_id);
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

    // Deposit USDC collateral for selling
    mm.deposit<USDC, USDT, USDC>(
        &registry,
        &usdc_price,
        &usdt_price,
        mint_coin<USDC>(10000 * test_constants::usdc_multiplier(), scenario.ctx()),
        &clock,
        scenario.ctx(),
    );

    destroy_2!(usdc_price, usdt_price);

    // Place ask at 50% above oracle (1_500_000_000)
    // Oracle price is 1_000_000_000 (1.0), this is way above upper bound of 1_050_000_000
    // But asks don't check upper bound - should succeed
    let base_pool = scenario.take_shared_by_id<MarginPool<USDC>>(base_pool_id);
    let quote_pool = scenario.take_shared_by_id<MarginPool<USDT>>(quote_pool_id);
    let order_info = test_helpers::place_limit_order_v2_for_test<USDC, USDT>(
        &mut scenario,
        &registry,
        &base_pool,
        &quote_pool,
        &mut mm,
        &mut pool,
        1,
        constants::no_restriction(),
        constants::self_matching_allowed(),
        1_500_000_000,
        // 50% above oracle - should succeed for asks
        100 * test_constants::usdc_multiplier(),
        false,
        // is_bid = false (sell order)
        false,
        18446744073709551615,
        &clock,
    );
    return_shared(base_pool);
    return_shared(quote_pool);

    assert!(order_info.client_order_id() == 1);
    destroy(order_info);
    return_shared_2!(mm, pool);
    cleanup_margin_test(registry, _admin_cap, _maintainer_cap, clock, scenario);
}

#[test]
fun test_market_buy_order_above_oracle_within_bounds() {
    // Test that market buy orders work when execution price is above oracle
    // but within the 5% upper bound tolerance
    // Orderbook has asks at $1.01, oracle is $1.00, upper bound is $1.05
    let (
        mut scenario,
        clock,
        _admin_cap,
        _maintainer_cap,
        base_pool_id,
        quote_pool_id,
        pool_id,
        registry_id,
    ) = setup_pool_proxy_test_env<USDC, USDT>();

    // Set up orderbook with asks at $1.01 (above oracle but within bounds)
    setup_orderbook_liquidity_stablecoin<USDC, USDT>(&mut scenario, pool_id, &clock);

    scenario.next_tx(test_constants::user1());
    let mut pool = scenario.take_shared_by_id<Pool<USDC, USDT>>(pool_id);
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

    // Deposit USDT to buy USDC
    mm.deposit<USDC, USDT, USDT>(
        &registry,
        &usdc_price,
        &usdt_price,
        mint_coin<USDT>(10000 * test_constants::usdt_multiplier(), scenario.ctx()),
        &clock,
        scenario.ctx(),
    );
    destroy_2!(usdc_price, usdt_price);

    // Market buy USDC - will execute at $1.01 (above oracle of $1.00)
    // Bids only check upper bound ($1.05), so $1.01 should pass
    let base_pool = scenario.take_shared_by_id<MarginPool<USDC>>(base_pool_id);
    let quote_pool = scenario.take_shared_by_id<MarginPool<USDT>>(quote_pool_id);
    let order_info = test_helpers::place_market_order_v2_for_test<USDC, USDT>(
        &mut scenario,
        &registry,
        &base_pool,
        &quote_pool,
        &mut mm,
        &mut pool,
        1,
        constants::self_matching_allowed(),
        100 * test_constants::usdc_multiplier(),
        true,
        // is_bid = true (buy)
        false,
        &clock,
    );
    return_shared(base_pool);
    return_shared(quote_pool);

    assert!(order_info.client_order_id() == 1);
    destroy(order_info);
    return_shared_2!(mm, pool);
    cleanup_margin_test(registry, _admin_cap, _maintainer_cap, clock, scenario);
}

#[test]
fun test_market_sell_order_below_oracle_within_bounds() {
    // Test that market sell orders work when execution price is below oracle
    // but within the 5% lower bound tolerance
    // Orderbook has bids at $0.99, oracle is $1.00, lower bound is $0.95
    let (
        mut scenario,
        clock,
        _admin_cap,
        _maintainer_cap,
        base_pool_id,
        quote_pool_id,
        pool_id,
        registry_id,
    ) = setup_pool_proxy_test_env<USDC, USDT>();

    // Set up orderbook with bids at $0.99 (below oracle but within bounds)
    setup_orderbook_liquidity_stablecoin<USDC, USDT>(&mut scenario, pool_id, &clock);

    scenario.next_tx(test_constants::user1());
    let mut pool = scenario.take_shared_by_id<Pool<USDC, USDT>>(pool_id);
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

    // Deposit USDC to sell
    mm.deposit<USDC, USDT, USDC>(
        &registry,
        &usdc_price,
        &usdt_price,
        mint_coin<USDC>(10000 * test_constants::usdc_multiplier(), scenario.ctx()),
        &clock,
        scenario.ctx(),
    );
    destroy_2!(usdc_price, usdt_price);

    // Market sell USDC - will execute at $0.99 (below oracle of $1.00)
    // Asks only check lower bound ($0.95), so $0.99 should pass
    let base_pool = scenario.take_shared_by_id<MarginPool<USDC>>(base_pool_id);
    let quote_pool = scenario.take_shared_by_id<MarginPool<USDT>>(quote_pool_id);
    let order_info = test_helpers::place_market_order_v2_for_test<USDC, USDT>(
        &mut scenario,
        &registry,
        &base_pool,
        &quote_pool,
        &mut mm,
        &mut pool,
        1,
        constants::self_matching_allowed(),
        100 * test_constants::usdc_multiplier(),
        false,
        // is_bid = false (sell)
        false,
        &clock,
    );
    return_shared(base_pool);
    return_shared(quote_pool);

    assert!(order_info.client_order_id() == 1);
    destroy(order_info);
    return_shared_2!(mm, pool);
    cleanup_margin_test(registry, _admin_cap, _maintainer_cap, clock, scenario);
}

#[test, expected_failure(abort_code = margin_registry::EPriceDeviationTooHigh)]
fun test_market_buy_order_exceeds_upper_bound() {
    // Test that market buy orders fail when execution price exceeds upper bound
    // Orderbook has asks at $1.10 (10% above oracle), upper bound is $1.05 (5%)
    let (
        mut scenario,
        clock,
        _admin_cap,
        _maintainer_cap,
        base_pool_id,
        quote_pool_id,
        pool_id,
        registry_id,
    ) = setup_pool_proxy_test_env<USDC, USDT>();

    // Set up orderbook with asks at $1.10 (exceeds 5% upper bound)
    setup_orderbook_liquidity_out_of_bounds_stablecoin<USDC, USDT>(&mut scenario, pool_id, &clock);

    scenario.next_tx(test_constants::user1());
    let mut pool = scenario.take_shared_by_id<Pool<USDC, USDT>>(pool_id);
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

    // Deposit USDT to buy USDC
    mm.deposit<USDC, USDT, USDT>(
        &registry,
        &usdc_price,
        &usdt_price,
        mint_coin<USDT>(10000 * test_constants::usdt_multiplier(), scenario.ctx()),
        &clock,
        scenario.ctx(),
    );
    destroy_2!(usdc_price, usdt_price);

    // Market buy USDC - will try to execute at $1.10 (exceeds upper bound of $1.05)
    // Should fail with EPriceDeviationTooHigh
    let base_pool = scenario.take_shared_by_id<MarginPool<USDC>>(base_pool_id);
    let quote_pool = scenario.take_shared_by_id<MarginPool<USDT>>(quote_pool_id);
    test_helpers::place_market_order_v2_for_test<USDC, USDT>(
        &mut scenario,
        &registry,
        &base_pool,
        &quote_pool,
        &mut mm,
        &mut pool,
        1,
        constants::self_matching_allowed(),
        100 * test_constants::usdc_multiplier(),
        true,
        // is_bid = true (buy)
        false,
        &clock,
    );
    return_shared(base_pool);
    return_shared(quote_pool);

    abort
}

#[test, expected_failure(abort_code = margin_registry::EPriceDeviationTooHigh)]
fun test_market_sell_order_below_lower_bound() {
    // Test that market sell orders fail when execution price is below lower bound
    // Orderbook has bids at $0.90 (10% below oracle), lower bound is $0.95 (5%)
    let (
        mut scenario,
        clock,
        _admin_cap,
        _maintainer_cap,
        base_pool_id,
        quote_pool_id,
        pool_id,
        registry_id,
    ) = setup_pool_proxy_test_env<USDC, USDT>();

    // Set up orderbook with bids at $0.90 (below 5% lower bound)
    setup_orderbook_liquidity_out_of_bounds_stablecoin<USDC, USDT>(&mut scenario, pool_id, &clock);

    scenario.next_tx(test_constants::user1());
    let mut pool = scenario.take_shared_by_id<Pool<USDC, USDT>>(pool_id);
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

    // Deposit USDC to sell
    mm.deposit<USDC, USDT, USDC>(
        &registry,
        &usdc_price,
        &usdt_price,
        mint_coin<USDC>(10000 * test_constants::usdc_multiplier(), scenario.ctx()),
        &clock,
        scenario.ctx(),
    );
    destroy_2!(usdc_price, usdt_price);

    // Market sell USDC - will try to execute at $0.90 (below lower bound of $0.95)
    // Should fail with EPriceDeviationTooHigh
    let base_pool = scenario.take_shared_by_id<MarginPool<USDC>>(base_pool_id);
    let quote_pool = scenario.take_shared_by_id<MarginPool<USDT>>(quote_pool_id);
    test_helpers::place_market_order_v2_for_test<USDC, USDT>(
        &mut scenario,
        &registry,
        &base_pool,
        &quote_pool,
        &mut mm,
        &mut pool,
        1,
        constants::self_matching_allowed(),
        100 * test_constants::usdc_multiplier(),
        false,
        // is_bid = false (sell)
        false,
        &clock,
    );
    return_shared(base_pool);
    return_shared(quote_pool);

    abort
}

#[test, expected_failure(abort_code = pool_proxy::ENoLiquidityInOrderbook)]
fun test_market_buy_order_no_liquidity() {
    // Test that market buy orders fail when there's no liquidity (base_out == 0)
    let (
        mut scenario,
        clock,
        _admin_cap,
        _maintainer_cap,
        base_pool_id,
        quote_pool_id,
        pool_id,
        registry_id,
    ) = setup_pool_proxy_test_env<USDC, USDT>();

    // Don't set up any orderbook liquidity

    scenario.next_tx(test_constants::user1());
    let mut pool = scenario.take_shared_by_id<Pool<USDC, USDT>>(pool_id);
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

    mm.deposit<USDC, USDT, USDT>(
        &registry,
        &usdc_price,
        &usdt_price,
        mint_coin<USDT>(10000 * test_constants::usdt_multiplier(), scenario.ctx()),
        &clock,
        scenario.ctx(),
    );
    destroy_2!(usdc_price, usdt_price);

    // Market buy with no liquidity - base_out will be 0
    // Should fail with ENoLiquidityInOrderbook
    let base_pool = scenario.take_shared_by_id<MarginPool<USDC>>(base_pool_id);
    let quote_pool = scenario.take_shared_by_id<MarginPool<USDT>>(quote_pool_id);
    test_helpers::place_market_order_v2_for_test<USDC, USDT>(
        &mut scenario,
        &registry,
        &base_pool,
        &quote_pool,
        &mut mm,
        &mut pool,
        1,
        constants::self_matching_allowed(),
        100 * test_constants::usdc_multiplier(),
        true,
        // is_bid = true (buy)
        false,
        &clock,
    );
    return_shared(base_pool);
    return_shared(quote_pool);

    abort
}

#[test, expected_failure(abort_code = pool_proxy::ENoLiquidityInOrderbook)]
fun test_market_sell_order_no_liquidity() {
    // Test that market sell orders fail when there's no liquidity (base_used == 0)
    let (
        mut scenario,
        clock,
        _admin_cap,
        _maintainer_cap,
        base_pool_id,
        quote_pool_id,
        pool_id,
        registry_id,
    ) = setup_pool_proxy_test_env<USDC, USDT>();

    // Don't set up any orderbook liquidity

    scenario.next_tx(test_constants::user1());
    let mut pool = scenario.take_shared_by_id<Pool<USDC, USDT>>(pool_id);
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
        mint_coin<USDC>(10000 * test_constants::usdc_multiplier(), scenario.ctx()),
        &clock,
        scenario.ctx(),
    );
    destroy_2!(usdc_price, usdt_price);

    // Market sell with no liquidity - base_used will be 0
    // Should fail with EPriceDeviationTooHigh
    let base_pool = scenario.take_shared_by_id<MarginPool<USDC>>(base_pool_id);
    let quote_pool = scenario.take_shared_by_id<MarginPool<USDT>>(quote_pool_id);
    test_helpers::place_market_order_v2_for_test<USDC, USDT>(
        &mut scenario,
        &registry,
        &base_pool,
        &quote_pool,
        &mut mm,
        &mut pool,
        1,
        constants::self_matching_allowed(),
        100 * test_constants::usdc_multiplier(),
        false,
        // is_bid = false (sell)
        false,
        &clock,
    );
    return_shared(base_pool);
    return_shared(quote_pool);

    abort
}

#[test, expected_failure(abort_code = margin_registry::EPriceNotInitialized)]
fun test_limit_order_price_not_initialized() {
    // Test that placing an order fails if current price has never been updated
    let (mut scenario, clock, admin_cap, maintainer_cap) = setup_margin_registry();

    let base_pool_id = create_margin_pool<USDC>(
        &mut scenario,
        &maintainer_cap,
        default_protocol_config(),
        &clock,
    );
    let quote_pool_id = create_margin_pool<USDT>(
        &mut scenario,
        &maintainer_cap,
        default_protocol_config(),
        &clock,
    );

    let (base_pool_cap, quote_pool_cap) = get_margin_pool_caps(&mut scenario, base_pool_id);

    let (pool_id, registry_id) = create_pool_for_testing<USDC, USDT>(&mut scenario);

    // Enable pool but DON'T initialize price (skip initialize_pool_price call)
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

    // Setup liquidity for margin pools (so margin manager can be created)
    scenario.next_tx(test_constants::admin());
    let mut base_pool = scenario.take_shared_by_id<MarginPool<USDC>>(base_pool_id);
    let mut quote_pool = scenario.take_shared_by_id<MarginPool<USDT>>(quote_pool_id);
    let registry = scenario.take_shared<MarginRegistry>();
    let supplier_cap = margin_pool::mint_supplier_cap(&registry, &clock, scenario.ctx());

    base_pool.supply(
        &registry,
        &supplier_cap,
        mint_coin<USDC>(1_000_000 * test_constants::usdc_multiplier(), scenario.ctx()),
        option::none(),
        &clock,
    );
    quote_pool.supply(
        &registry,
        &supplier_cap,
        mint_coin<USDT>(1_000_000 * test_constants::usdt_multiplier(), scenario.ctx()),
        option::none(),
        &clock,
    );

    base_pool.enable_deepbook_pool_for_loan(&registry, pool_id, &base_pool_cap, &clock);
    quote_pool.enable_deepbook_pool_for_loan(&registry, pool_id, &quote_pool_cap, &clock);

    return_shared_2!(base_pool, quote_pool);
    return_shared(registry);
    destroy_2!(base_pool_cap, quote_pool_cap);
    destroy(supplier_cap);

    scenario.next_tx(test_constants::user1());
    let mut pool = scenario.take_shared_by_id<Pool<USDC, USDT>>(pool_id);
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
        mint_coin<USDC>(10000 * test_constants::usdc_multiplier(), scenario.ctx()),
        &clock,
        scenario.ctx(),
    );
    destroy_2!(usdc_price, usdt_price);

    // Try to place limit order without initializing price
    // Should fail with EPriceNotInitialized
    let base_pool = scenario.take_shared_by_id<MarginPool<USDC>>(base_pool_id);
    let quote_pool = scenario.take_shared_by_id<MarginPool<USDT>>(quote_pool_id);
    test_helpers::place_limit_order_v2_for_test<USDC, USDT>(
        &mut scenario,
        &registry,
        &base_pool,
        &quote_pool,
        &mut mm,
        &mut pool,
        1,
        constants::no_restriction(),
        constants::self_matching_allowed(),
        1_000_000_000,
        // $1.00
        100 * test_constants::usdc_multiplier(),
        false,
        false,
        18446744073709551615,
        &clock,
    );
    return_shared(base_pool);
    return_shared(quote_pool);

    abort
}

#[test, expected_failure(abort_code = margin_registry::EPriceUpdateRequired)]
fun test_limit_order_price_stale() {
    // Test that placing an order fails if current price is stale
    let (
        mut scenario,
        mut clock,
        _admin_cap,
        _maintainer_cap,
        base_pool_id,
        quote_pool_id,
        pool_id,
        registry_id,
    ) = setup_pool_proxy_test_env<USDC, USDT>();

    scenario.next_tx(test_constants::user1());
    let mut pool = scenario.take_shared_by_id<Pool<USDC, USDT>>(pool_id);
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
        mint_coin<USDC>(10000 * test_constants::usdc_multiplier(), scenario.ctx()),
        &clock,
        scenario.ctx(),
    );
    destroy_2!(usdc_price, usdt_price);

    // Advance clock past max_price_age (default is 5 minutes, advance 6 minutes)
    clock.increment_for_testing(6 * 60 * 1000);

    // Try to place limit order with stale price
    // Should fail with EPriceUpdateRequired
    let base_pool = scenario.take_shared_by_id<MarginPool<USDC>>(base_pool_id);
    let quote_pool = scenario.take_shared_by_id<MarginPool<USDT>>(quote_pool_id);
    test_helpers::place_limit_order_v2_for_test<USDC, USDT>(
        &mut scenario,
        &registry,
        &base_pool,
        &quote_pool,
        &mut mm,
        &mut pool,
        1,
        constants::no_restriction(),
        constants::self_matching_allowed(),
        1_000_000_000,
        // $1.00
        100 * test_constants::usdc_multiplier(),
        false,
        false,
        18446744073709551615,
        &clock,
    );
    return_shared(base_pool);
    return_shared(quote_pool);

    abort
}

#[test]
/// Test that market sell order at min_size works with input fee (no DEEP in manager).
/// This verifies the fix for get_quote_quantity_out_input_fee min_size issue.
fun test_market_sell_min_size_input_fee_ok() {
    let (
        mut scenario,
        clock,
        _admin_cap,
        _maintainer_cap,
        base_pool_id,
        quote_pool_id,
        pool_id,
        registry_id,
    ) = setup_pool_proxy_test_env<USDC, USDT>();

    // Set up orderbook with bids to match against
    setup_orderbook_liquidity_stablecoin<USDC, USDT>(&mut scenario, pool_id, &clock);

    scenario.next_tx(test_constants::user1());
    let pool = scenario.take_shared_by_id<Pool<USDC, USDT>>(pool_id);
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
    return_shared(registry);
    return_shared(pool);

    scenario.next_tx(test_constants::user1());
    let mut pool = scenario.take_shared_by_id<Pool<USDC, USDT>>(pool_id);
    let registry = scenario.take_shared<MarginRegistry>();
    let mut mm = scenario.take_shared<MarginManager<USDC, USDT>>();
    let usdc_price = build_demo_usdc_price_info_object(&mut scenario, &clock);
    let usdt_price = build_demo_usdt_price_info_object(&mut scenario, &clock);

    // Deposit enough USDC to sell min_size (no DEEP deposited - will use input fee).
    // When using input fee, fee is deducted from the sell amount, so we need slightly more.
    // Deposit min_size + 10% to cover the taker fee.
    mm.deposit<USDC, USDT, USDC>(
        &registry,
        &usdc_price,
        &usdt_price,
        mint_coin<USDC>(constants::min_size() + constants::min_size() / 10, scenario.ctx()),
        &clock,
        scenario.ctx(),
    );
    destroy_2!(usdc_price, usdt_price);

    // Market sell exactly min_size USDC with input fee (pay_with_deep = false)
    let base_pool = scenario.take_shared_by_id<MarginPool<USDC>>(base_pool_id);
    let quote_pool = scenario.take_shared_by_id<MarginPool<USDT>>(quote_pool_id);
    let order_info = test_helpers::place_market_order_v2_for_test<USDC, USDT>(
        &mut scenario,
        &registry,
        &base_pool,
        &quote_pool,
        &mut mm,
        &mut pool,
        1,
        constants::self_matching_allowed(),
        constants::min_size(),
        // exactly min_size
        false,
        // is_bid = false (sell)
        false,
        // pay_with_deep = false (use input fee)
        &clock,
    );
    return_shared(base_pool);
    return_shared(quote_pool);

    // Verify order executed
    assert!(order_info.status() == constants::filled());

    return_shared_2!(mm, pool);
    cleanup_margin_test(registry, _admin_cap, _maintainer_cap, clock, scenario);
}

#[test]
/// Test that market buy order at min_size works with input fee (no DEEP in manager).
/// For bids, input fee is taken from quote, not base, so this should work.
fun test_market_buy_min_size_input_fee_ok() {
    let (
        mut scenario,
        clock,
        _admin_cap,
        _maintainer_cap,
        base_pool_id,
        quote_pool_id,
        pool_id,
        registry_id,
    ) = setup_pool_proxy_test_env<USDC, USDT>();

    // Set up orderbook with asks to match against
    setup_orderbook_liquidity_stablecoin<USDC, USDT>(&mut scenario, pool_id, &clock);

    scenario.next_tx(test_constants::user1());
    let pool = scenario.take_shared_by_id<Pool<USDC, USDT>>(pool_id);
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
    return_shared(registry);
    return_shared(pool);

    scenario.next_tx(test_constants::user1());
    let mut pool = scenario.take_shared_by_id<Pool<USDC, USDT>>(pool_id);
    let registry = scenario.take_shared<MarginRegistry>();
    let mut mm = scenario.take_shared<MarginManager<USDC, USDT>>();
    let usdc_price = build_demo_usdc_price_info_object(&mut scenario, &clock);
    let usdt_price = build_demo_usdt_price_info_object(&mut scenario, &clock);

    // Deposit quote (USDT) to buy base (USDC) - no DEEP deposited (will use input fee)
    // Need enough quote to cover min_size base + fees
    // At $1.01 price, min_size base costs ~10100 quote + fees
    mm.deposit<USDC, USDT, USDT>(
        &registry,
        &usdc_price,
        &usdt_price,
        mint_coin<USDT>(100000, scenario.ctx()), // enough to cover min_size + fees
        &clock,
        scenario.ctx(),
    );
    destroy_2!(usdc_price, usdt_price);

    // Market buy exactly min_size USDC with input fee (pay_with_deep = false)
    // For bids, fee is taken from quote input, not base output
    // So this should work regardless of the fix
    let base_pool = scenario.take_shared_by_id<MarginPool<USDC>>(base_pool_id);
    let quote_pool = scenario.take_shared_by_id<MarginPool<USDT>>(quote_pool_id);
    let order_info = test_helpers::place_market_order_v2_for_test<USDC, USDT>(
        &mut scenario,
        &registry,
        &base_pool,
        &quote_pool,
        &mut mm,
        &mut pool,
        1,
        constants::self_matching_allowed(),
        constants::min_size(),
        // exactly min_size base to buy
        true,
        // is_bid = true (buy)
        false,
        // pay_with_deep = false (use input fee)
        &clock,
    );
    return_shared(base_pool);
    return_shared(quote_pool);

    // Verify order executed
    assert!(order_info.status() == constants::filled());

    return_shared_2!(mm, pool);
    cleanup_margin_test(registry, _admin_cap, _maintainer_cap, clock, scenario);
}

// === V1 deprecation regression tests ===
//
// Each v1 trading entry preserves its on-chain ABI for upgrade compatibility
// but aborts immediately. These tests assert the abort fires with the
// expected named error so a future refactor cannot silently restore a v1
// path.

#[test, expected_failure(abort_code = pool_proxy::EDeprecatedUseV2)]
fun place_limit_order_v1_aborts() {
    let (
        mut scenario,
        clock,
        _admin_cap,
        _maintainer_cap,
        _b,
        _q,
        pool_id,
        registry_id,
    ) = setup_pool_proxy_test_env<USDC, USDT>();

    scenario.next_tx(test_constants::user1());
    let mut pool = scenario.take_shared_by_id<Pool<USDC, USDT>>(pool_id);
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

    let _ = pool_proxy::place_limit_order<USDC, USDT>(
        &registry,
        &mut mm,
        &mut pool,
        1,
        constants::no_restriction(),
        constants::self_matching_allowed(),
        1_000_000_000,
        100 * test_constants::usdc_multiplier(),
        false,
        false,
        2_000_000,
        &clock,
        scenario.ctx(),
    );

    abort 999
}

#[test, expected_failure(abort_code = pool_proxy::EDeprecatedUseV2)]
fun place_market_order_v1_aborts() {
    let (
        mut scenario,
        clock,
        _admin_cap,
        _maintainer_cap,
        _b,
        _q,
        pool_id,
        registry_id,
    ) = setup_pool_proxy_test_env<USDC, USDT>();

    scenario.next_tx(test_constants::user1());
    let mut pool = scenario.take_shared_by_id<Pool<USDC, USDT>>(pool_id);
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

    let _ = pool_proxy::place_market_order<USDC, USDT>(
        &registry,
        &mut mm,
        &mut pool,
        1,
        constants::self_matching_allowed(),
        100 * test_constants::usdc_multiplier(),
        false,
        false,
        &clock,
        scenario.ctx(),
    );

    abort 999
}

#[test, expected_failure(abort_code = pool_proxy::EDeprecatedUseV2)]
fun place_reduce_only_limit_order_v1_aborts() {
    let (
        mut scenario,
        clock,
        _admin_cap,
        _maintainer_cap,
        base_pool_id,
        _q,
        pool_id,
        registry_id,
    ) = setup_pool_proxy_test_env<USDC, USDT>();

    scenario.next_tx(test_constants::user1());
    let mut pool = scenario.take_shared_by_id<Pool<USDC, USDT>>(pool_id);
    let mut registry = scenario.take_shared<MarginRegistry>();
    let base_pool = scenario.take_shared_by_id<MarginPool<USDC>>(base_pool_id);
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

    let _ = pool_proxy::place_reduce_only_limit_order<USDC, USDT, USDC>(
        &registry,
        &mut mm,
        &mut pool,
        &base_pool,
        1,
        constants::no_restriction(),
        constants::self_matching_allowed(),
        1_000_000_000,
        100 * test_constants::usdc_multiplier(),
        true,
        false,
        2_000_000,
        &clock,
        scenario.ctx(),
    );

    abort 999
}

#[test, expected_failure(abort_code = pool_proxy::EDeprecatedUseV2)]
fun place_reduce_only_market_order_v1_aborts() {
    let (
        mut scenario,
        clock,
        _admin_cap,
        _maintainer_cap,
        base_pool_id,
        _q,
        pool_id,
        registry_id,
    ) = setup_pool_proxy_test_env<USDC, USDT>();

    scenario.next_tx(test_constants::user1());
    let mut pool = scenario.take_shared_by_id<Pool<USDC, USDT>>(pool_id);
    let mut registry = scenario.take_shared<MarginRegistry>();
    let base_pool = scenario.take_shared_by_id<MarginPool<USDC>>(base_pool_id);
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

    let _ = pool_proxy::place_reduce_only_market_order<USDC, USDT, USDC>(
        &registry,
        &mut mm,
        &mut pool,
        &base_pool,
        1,
        constants::self_matching_allowed(),
        100 * test_constants::usdc_multiplier(),
        true,
        false,
        &clock,
        scenario.ctx(),
    );

    abort 999
}

// === Post-trade open-floor (min_open_risk_ratio) tests ===
//
// Borrow USDC against USDT collateral right at `min_borrow_risk_ratio` (1.25,
// the borrow floor in test config), then sell the borrowed USDC against the
// standard orderbook bid (0.99). The 1% adverse fill drops `risk_ratio` to
// 1.2475 — below the borrow floor but above the default `min_open_risk_ratio`
// (midpoint of liquidation 1.10 and min_borrow 1.25 = 1.175, in test config).
// The opening trade is allowed, so a max-leverage open can absorb its own spread.
#[test]
fun place_limit_order_v2_borrow_at_floor_then_adverse_fill_ok() {
    let (
        mut scenario,
        clock,
        _admin_cap,
        _maintainer_cap,
        base_pool_id,
        quote_pool_id,
        pool_id,
        registry_id,
    ) = setup_pool_proxy_test_env<USDC, USDT>();
    setup_orderbook_liquidity_stablecoin<USDC, USDT>(&mut scenario, pool_id, &clock);

    scenario.next_tx(test_constants::user1());
    let mut pool = scenario.take_shared_by_id<Pool<USDC, USDT>>(pool_id);
    let mut registry = scenario.take_shared<MarginRegistry>();
    let mut base_pool = scenario.take_shared_by_id<MarginPool<USDC>>(base_pool_id);
    let quote_pool = scenario.take_shared_by_id<MarginPool<USDT>>(quote_pool_id);
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

    // Deposit 100 USDT collateral + DEEP for fees, borrow 400 USDC.
    // Post-borrow: 100 USDT + 400 USDC = 500 USDC-equiv, debt 400 USDC,
    // risk_ratio = 500/400 = 1.25 (exactly at borrow floor). DEEP isn't summed
    // by `calculate_assets`, so it doesn't affect risk_ratio.
    mm.deposit<USDC, USDT, USDT>(
        &registry,
        &usdc_price,
        &usdt_price,
        mint_coin<USDT>(100 * test_constants::usdt_multiplier(), scenario.ctx()),
        &clock,
        scenario.ctx(),
    );
    mm.deposit<USDC, USDT, DEEP>(
        &registry,
        &usdc_price,
        &usdt_price,
        mint_coin<DEEP>(100 * test_constants::deep_multiplier(), scenario.ctx()),
        &clock,
        scenario.ctx(),
    );
    mm.borrow_base<USDC, USDT>(
        &registry,
        &mut base_pool,
        &usdc_price,
        &usdt_price,
        &pool,
        400 * test_constants::usdc_multiplier(),
        &clock,
        scenario.ctx(),
    );
    destroy_2!(usdc_price, usdt_price);

    // Sell 100 USDC at 0.99 — fills against resting bid at 0.99 (pay_with_deep
    // covers fees from the DEEP balance, not the trade output).
    // Pre-trade asset: 400 USDC + 100 USDT = 500 USDC-equiv, debt 400.
    // Post-trade: 300 USDC + 199 USDT = 499 USDC-equiv, debt 400,
    // risk_ratio = 499/400 = 1.2475 < 1.25. Aborts.
    let _ = test_helpers::place_limit_order_v2_for_test<USDC, USDT>(
        &mut scenario,
        &registry,
        &base_pool,
        &quote_pool,
        &mut mm,
        &mut pool,
        1,
        constants::no_restriction(),
        constants::self_matching_allowed(),
        990_000_000,
        100 * test_constants::usdc_multiplier(),
        false, // is_bid = false (sell)
        true, // pay_with_deep
        2_000_000,
        &clock,
    );

    // Post-trade risk_ratio = 499/400 = 1.2475: below the 1.25 borrow floor,
    // above the 1.175 open floor, so the opening order is accepted.
    let usdc_price = build_demo_usdc_price_info_object(&mut scenario, &clock);
    let usdt_price = build_demo_usdt_price_info_object(&mut scenario, &clock);
    let rr = mm.risk_ratio(
        &registry,
        &usdc_price,
        &usdt_price,
        &pool,
        &base_pool,
        &quote_pool,
        &clock,
    );
    assert_eq!(rr, 1_247_500_000);
    assert!(rr < registry.min_borrow_risk_ratio(pool_id));
    assert!(rr >= registry.min_open_risk_ratio(pool_id));

    return_shared_3!(mm, pool, quote_pool);
    return_shared(base_pool);
    destroy_2!(usdc_price, usdt_price);
    cleanup_margin_test(registry, _admin_cap, _maintainer_cap, clock, scenario);
}

// Same scenario, but the admin sets `min_open_risk_ratio` to the borrow floor
// (the strict opt-out), so the 1.2475 fill is now below the open floor and the
// opening order aborts. Exercises the override setter and the abort path.
#[test, expected_failure(abort_code = pool_proxy::EInsufficientRiskRatioAfterTrade)]
fun place_limit_order_v2_adverse_fill_aborts_with_strict_open_floor() {
    let (
        mut scenario,
        clock,
        _admin_cap,
        _maintainer_cap,
        base_pool_id,
        quote_pool_id,
        pool_id,
        registry_id,
    ) = setup_pool_proxy_test_env<USDC, USDT>();
    setup_orderbook_liquidity_stablecoin<USDC, USDT>(&mut scenario, pool_id, &clock);

    scenario.next_tx(test_constants::user1());
    let mut pool = scenario.take_shared_by_id<Pool<USDC, USDT>>(pool_id);
    let mut registry = scenario.take_shared<MarginRegistry>();
    let mut base_pool = scenario.take_shared_by_id<MarginPool<USDC>>(base_pool_id);
    let quote_pool = scenario.take_shared_by_id<MarginPool<USDT>>(quote_pool_id);
    let deepbook_registry = scenario.take_shared_by_id<Registry>(registry_id);
    margin_manager::new<USDC, USDT>(
        &pool,
        &deepbook_registry,
        &mut registry,
        &clock,
        scenario.ctx(),
    );
    return_shared(deepbook_registry);

    // Raise the open floor to the borrow floor: no slippage headroom.
    let borrow_floor = registry.min_borrow_risk_ratio(pool_id);
    registry.set_min_open_risk_ratio<USDC, USDT>(
        &_admin_cap,
        &pool,
        borrow_floor,
        &clock,
    );

    scenario.next_tx(test_constants::user1());
    let mut mm = scenario.take_shared<MarginManager<USDC, USDT>>();
    let usdc_price = build_demo_usdc_price_info_object(&mut scenario, &clock);
    let usdt_price = build_demo_usdt_price_info_object(&mut scenario, &clock);

    mm.deposit<USDC, USDT, USDT>(
        &registry,
        &usdc_price,
        &usdt_price,
        mint_coin<USDT>(100 * test_constants::usdt_multiplier(), scenario.ctx()),
        &clock,
        scenario.ctx(),
    );
    mm.deposit<USDC, USDT, DEEP>(
        &registry,
        &usdc_price,
        &usdt_price,
        mint_coin<DEEP>(100 * test_constants::deep_multiplier(), scenario.ctx()),
        &clock,
        scenario.ctx(),
    );
    mm.borrow_base<USDC, USDT>(
        &registry,
        &mut base_pool,
        &usdc_price,
        &usdt_price,
        &pool,
        400 * test_constants::usdc_multiplier(),
        &clock,
        scenario.ctx(),
    );
    destroy_2!(usdc_price, usdt_price);

    let _ = test_helpers::place_limit_order_v2_for_test<USDC, USDT>(
        &mut scenario,
        &registry,
        &base_pool,
        &quote_pool,
        &mut mm,
        &mut pool,
        1,
        constants::no_restriction(),
        constants::self_matching_allowed(),
        990_000_000,
        100 * test_constants::usdc_multiplier(),
        false, // is_bid = false (sell)
        true, // pay_with_deep
        2_000_000,
        &clock,
    );

    abort 999
}

// === Max Order TTL Tests ===
//
// `clamp_expire_timestamp` bounds margin limit orders to at most
// `now + max_order_ttl_ms`. Default is 3 days; admin can tune in [1h, 30d].
// Test clock is set to 1_000_000 ms in the test scaffolding (see
// `test_helpers::setup_margin_registry`).

#[test, expected_failure(abort_code = margin_registry::EInvalidOrderTtl)]
fun test_set_max_order_ttl_too_low() {
    let (mut scenario, clock, admin_cap, maintainer_cap) = setup_margin_registry();

    let _base_pool_id = create_margin_pool<USDC>(
        &mut scenario,
        &maintainer_cap,
        default_protocol_config(),
        &clock,
    );
    let _quote_pool_id = create_margin_pool<USDT>(
        &mut scenario,
        &maintainer_cap,
        default_protocol_config(),
        &clock,
    );

    let (pool_id, _registry_id) = create_pool_for_testing<USDC, USDT>(&mut scenario);

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
    let pool = scenario.take_shared_by_id<Pool<USDC, USDT>>(pool_id);
    let mut registry = scenario.take_shared<MarginRegistry>();

    registry.set_max_order_ttl<USDC, USDT>(
        &admin_cap,
        &pool,
        30 * 60 * 1000, // 30 minutes — below 1h minimum
        &clock,
    );

    abort 0
}

#[test, expected_failure(abort_code = margin_registry::EInvalidOrderTtl)]
fun test_set_max_order_ttl_too_high() {
    let (mut scenario, clock, admin_cap, maintainer_cap) = setup_margin_registry();

    let _base_pool_id = create_margin_pool<USDC>(
        &mut scenario,
        &maintainer_cap,
        default_protocol_config(),
        &clock,
    );
    let _quote_pool_id = create_margin_pool<USDT>(
        &mut scenario,
        &maintainer_cap,
        default_protocol_config(),
        &clock,
    );

    let (pool_id, _registry_id) = create_pool_for_testing<USDC, USDT>(&mut scenario);

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
    let pool = scenario.take_shared_by_id<Pool<USDC, USDT>>(pool_id);
    let mut registry = scenario.take_shared<MarginRegistry>();

    registry.set_max_order_ttl<USDC, USDT>(
        &admin_cap,
        &pool,
        31 * 24 * 60 * 60 * 1000, // 31 days — above 30d maximum
        &clock,
    );

    abort 0
}

#[test]
fun set_max_order_ttl_within_bounds_ok() {
    let (mut scenario, clock, admin_cap, maintainer_cap) = setup_margin_registry();

    let _base_pool_id = create_margin_pool<USDC>(
        &mut scenario,
        &maintainer_cap,
        default_protocol_config(),
        &clock,
    );
    let _quote_pool_id = create_margin_pool<USDT>(
        &mut scenario,
        &maintainer_cap,
        default_protocol_config(),
        &clock,
    );

    let (pool_id, _registry_id) = create_pool_for_testing<USDC, USDT>(&mut scenario);

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
    let pool = scenario.take_shared_by_id<Pool<USDC, USDT>>(pool_id);
    let mut registry = scenario.take_shared<MarginRegistry>();

    let one_day_ms = 24 * 60 * 60 * 1000;
    registry.set_max_order_ttl<USDC, USDT>(&admin_cap, &pool, one_day_ms, &clock);

    assert!(registry.max_order_ttl_ms(pool_id) == one_day_ms);

    // Update again to exercise the mutable path, not just first-insert.
    let two_days_ms = 2 * one_day_ms;
    registry.set_max_order_ttl<USDC, USDT>(&admin_cap, &pool, two_days_ms, &clock);
    assert!(registry.max_order_ttl_ms(pool_id) == two_days_ms);

    return_shared_2!(registry, pool);
    destroy(admin_cap);
    destroy(maintainer_cap);
    destroy(clock);
    scenario.end();
}

#[test]
fun min_open_risk_ratio_defaults_to_midpoint() {
    let (mut scenario, clock, admin_cap, maintainer_cap) = setup_margin_registry();
    let _base_pool_id = create_margin_pool<USDC>(
        &mut scenario,
        &maintainer_cap,
        default_protocol_config(),
        &clock,
    );
    let _quote_pool_id = create_margin_pool<USDT>(
        &mut scenario,
        &maintainer_cap,
        default_protocol_config(),
        &clock,
    );
    let (pool_id, _registry_id) = create_pool_for_testing<USDC, USDT>(&mut scenario);

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
    let registry = scenario.take_shared<MarginRegistry>();
    // Default = midpoint of liquidation (1.10) and min_borrow (1.25) = 1.175.
    assert_eq!(registry.min_open_risk_ratio(pool_id), 1_175_000_000);

    return_shared(registry);
    destroy(admin_cap);
    destroy(maintainer_cap);
    destroy(clock);
    scenario.end();
}

#[test]
fun set_min_open_risk_ratio_within_band_ok() {
    let (mut scenario, clock, admin_cap, maintainer_cap) = setup_margin_registry();
    let _base_pool_id = create_margin_pool<USDC>(
        &mut scenario,
        &maintainer_cap,
        default_protocol_config(),
        &clock,
    );
    let _quote_pool_id = create_margin_pool<USDT>(
        &mut scenario,
        &maintainer_cap,
        default_protocol_config(),
        &clock,
    );
    let (pool_id, _registry_id) = create_pool_for_testing<USDC, USDT>(&mut scenario);

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
    let pool = scenario.take_shared_by_id<Pool<USDC, USDT>>(pool_id);
    let mut registry = scenario.take_shared<MarginRegistry>();

    // 1.20 is within (liquidation 1.10, min_borrow 1.25].
    registry.set_min_open_risk_ratio<USDC, USDT>(&admin_cap, &pool, 1_200_000_000, &clock);
    assert_eq!(registry.min_open_risk_ratio(pool_id), 1_200_000_000);

    // Update again to exercise the mutable path, not just first-insert.
    registry.set_min_open_risk_ratio<USDC, USDT>(&admin_cap, &pool, 1_150_000_000, &clock);
    assert_eq!(registry.min_open_risk_ratio(pool_id), 1_150_000_000);

    return_shared_2!(registry, pool);
    destroy(admin_cap);
    destroy(maintainer_cap);
    destroy(clock);
    scenario.end();
}

#[test, expected_failure(abort_code = margin_registry::EInvalidRiskParam)]
fun set_min_open_risk_ratio_too_low_aborts() {
    let (mut scenario, clock, admin_cap, maintainer_cap) = setup_margin_registry();
    let _base_pool_id = create_margin_pool<USDC>(
        &mut scenario,
        &maintainer_cap,
        default_protocol_config(),
        &clock,
    );
    let _quote_pool_id = create_margin_pool<USDT>(
        &mut scenario,
        &maintainer_cap,
        default_protocol_config(),
        &clock,
    );
    let (pool_id, _registry_id) = create_pool_for_testing<USDC, USDT>(&mut scenario);

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
    let pool = scenario.take_shared_by_id<Pool<USDC, USDT>>(pool_id);
    let mut registry = scenario.take_shared<MarginRegistry>();

    // Equal to liquidation (1.10) is not strictly above it: out of band.
    registry.set_min_open_risk_ratio<USDC, USDT>(&admin_cap, &pool, 1_100_000_000, &clock);

    abort 999
}

#[test, expected_failure(abort_code = margin_registry::EInvalidRiskParam)]
fun set_min_open_risk_ratio_too_high_aborts() {
    let (mut scenario, clock, admin_cap, maintainer_cap) = setup_margin_registry();
    let _base_pool_id = create_margin_pool<USDC>(
        &mut scenario,
        &maintainer_cap,
        default_protocol_config(),
        &clock,
    );
    let _quote_pool_id = create_margin_pool<USDT>(
        &mut scenario,
        &maintainer_cap,
        default_protocol_config(),
        &clock,
    );
    let (pool_id, _registry_id) = create_pool_for_testing<USDC, USDT>(&mut scenario);

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
    let pool = scenario.take_shared_by_id<Pool<USDC, USDT>>(pool_id);
    let mut registry = scenario.take_shared<MarginRegistry>();

    // Above the borrow floor (1.25): out of band.
    registry.set_min_open_risk_ratio<USDC, USDT>(&admin_cap, &pool, 1_250_000_001, &clock);

    abort 999
}

#[test]
fun max_order_ttl_lazy_default() {
    // Pools that have never had `set_max_order_ttl` called still get the
    // 3-day default (lazy-default read path).
    let (mut scenario, clock, admin_cap, maintainer_cap) = setup_margin_registry();

    let _base_pool_id = create_margin_pool<USDC>(
        &mut scenario,
        &maintainer_cap,
        default_protocol_config(),
        &clock,
    );
    let _quote_pool_id = create_margin_pool<USDT>(
        &mut scenario,
        &maintainer_cap,
        default_protocol_config(),
        &clock,
    );

    let (pool_id, _registry_id) = create_pool_for_testing<USDC, USDT>(&mut scenario);

    scenario.next_tx(test_constants::admin());
    let registry = scenario.take_shared<MarginRegistry>();

    assert!(registry.max_order_ttl_ms(pool_id) == margin_constants::default_max_order_ttl_ms());
    // 3 days = 259_200_000 ms (sanity-check the literal hasn't drifted).
    assert!(registry.max_order_ttl_ms(pool_id) == 3 * 24 * 60 * 60 * 1000);

    return_shared(registry);
    destroy(admin_cap);
    destroy(maintainer_cap);
    destroy(clock);
    scenario.end();
}

#[test]
fun clamp_expire_timestamp_passthrough_and_clamp() {
    // Direct exercise of the clamp helper: small inputs pass, large inputs cap.
    let (mut scenario, clock, admin_cap, maintainer_cap) = setup_margin_registry();

    let _base_pool_id = create_margin_pool<USDC>(
        &mut scenario,
        &maintainer_cap,
        default_protocol_config(),
        &clock,
    );
    let _quote_pool_id = create_margin_pool<USDT>(
        &mut scenario,
        &maintainer_cap,
        default_protocol_config(),
        &clock,
    );

    let (pool_id, _registry_id) = create_pool_for_testing<USDC, USDT>(&mut scenario);

    scenario.next_tx(test_constants::admin());
    let registry = scenario.take_shared<MarginRegistry>();

    // Test clock is at 1_000_000 ms. Default TTL is 3 days = 259_200_000 ms.
    // Cap = 1_000_000 + 259_200_000 = 260_200_000.
    let now = 1_000_000u64;
    let cap = now + margin_constants::default_max_order_ttl_ms();

    // Small expire_timestamp passes through unchanged.
    assert!(registry.clamp_expire_timestamp(pool_id, 2_000_000, &clock) == 2_000_000);
    // Boundary: exact cap passes through.
    assert!(registry.clamp_expire_timestamp(pool_id, cap, &clock) == cap);
    // One past cap clamps.
    assert!(registry.clamp_expire_timestamp(pool_id, cap + 1, &clock) == cap);
    // u64::MAX-ish clamps.
    assert!(registry.clamp_expire_timestamp(pool_id, 1_000_000_000_000_000, &clock) == cap);
    // expire_timestamp = 0 passes through.
    assert!(registry.clamp_expire_timestamp(pool_id, 0, &clock) == 0);

    return_shared(registry);
    destroy(admin_cap);
    destroy(maintainer_cap);
    destroy(clock);
    scenario.end();
}

#[test]
fun clamp_uses_admin_set_ttl_after_update() {
    // After admin tightens per-pool TTL, the clamp uses the new value.
    let (mut scenario, clock, admin_cap, maintainer_cap) = setup_margin_registry();

    let _base_pool_id = create_margin_pool<USDC>(
        &mut scenario,
        &maintainer_cap,
        default_protocol_config(),
        &clock,
    );
    let _quote_pool_id = create_margin_pool<USDT>(
        &mut scenario,
        &maintainer_cap,
        default_protocol_config(),
        &clock,
    );

    let (pool_id, _registry_id) = create_pool_for_testing<USDC, USDT>(&mut scenario);

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
    let pool = scenario.take_shared_by_id<Pool<USDC, USDT>>(pool_id);
    let mut registry = scenario.take_shared<MarginRegistry>();

    // Tighten TTL to 1 hour (the minimum).
    let one_hour_ms = 60 * 60 * 1000;
    registry.set_max_order_ttl<USDC, USDT>(&admin_cap, &pool, one_hour_ms, &clock);

    // Clock = 1_000_000 ms, TTL = 3_600_000 ms → cap = 4_600_000.
    let now = 1_000_000u64;
    let expected_cap = now + one_hour_ms;
    assert!(registry.clamp_expire_timestamp(pool_id, 999_999_999, &clock) == expected_cap);
    assert!(registry.clamp_expire_timestamp(pool_id, 2_000_000, &clock) == 2_000_000);

    return_shared_2!(registry, pool);
    destroy(admin_cap);
    destroy(maintainer_cap);
    destroy(clock);
    scenario.end();
}

#[test]
fun place_limit_order_clamps_expire_timestamp() {
    // End-to-end: a huge expire_timestamp ends up at the 3-day cap on the
    // resting order returned by the proxy entry.
    let (
        mut scenario,
        clock,
        _admin_cap,
        _maintainer_cap,
        base_pool_id,
        quote_pool_id,
        pool_id,
        registry_id,
    ) = setup_pool_proxy_test_env<USDC, USDT>();

    scenario.next_tx(test_constants::user1());
    let mut pool = scenario.take_shared_by_id<Pool<USDC, USDT>>(pool_id);
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
        mint_coin<USDC>(10000 * test_constants::usdc_multiplier(), scenario.ctx()),
        &clock,
        scenario.ctx(),
    );
    destroy_2!(usdc_price, usdt_price);

    let base_pool = scenario.take_shared_by_id<MarginPool<USDC>>(base_pool_id);
    let quote_pool = scenario.take_shared_by_id<MarginPool<USDT>>(quote_pool_id);

    let huge_expire_ts = 1_000_000_000_000_000u64;
    let order_info = test_helpers::place_limit_order_v2_for_test<USDC, USDT>(
        &mut scenario,
        &registry,
        &base_pool,
        &quote_pool,
        &mut mm,
        &mut pool,
        1,
        constants::no_restriction(),
        constants::self_matching_allowed(),
        1_000_000_000,
        100 * test_constants::usdc_multiplier(),
        false, // is_bid (sell)
        false,
        huge_expire_ts,
        &clock,
    );

    let now = 1_000_000u64;
    let expected = now + margin_constants::default_max_order_ttl_ms();
    assert!(order_info.expire_timestamp() == expected);

    return_shared(base_pool);
    return_shared(quote_pool);
    destroy(order_info);

    return_shared_2!(mm, pool);
    cleanup_margin_test(registry, _admin_cap, _maintainer_cap, clock, scenario);
}

#[test]
fun place_limit_order_v2_no_debt_at_oracle_price_ok() {
    // Sanity: with no debt the post-trade invariant short-circuits, so
    // `place_limit_order_v2` succeeds normally.
    let (
        mut scenario,
        clock,
        _admin_cap,
        _maintainer_cap,
        base_pool_id,
        quote_pool_id,
        pool_id,
        registry_id,
    ) = setup_pool_proxy_test_env<USDC, USDT>();

    scenario.next_tx(test_constants::user1());
    let mut pool = scenario.take_shared_by_id<Pool<USDC, USDT>>(pool_id);
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
    destroy_2!(usdc_price, usdt_price);

    let base_pool = scenario.take_shared_by_id<MarginPool<USDC>>(base_pool_id);
    let quote_pool = scenario.take_shared_by_id<MarginPool<USDT>>(quote_pool_id);
    let order_info = test_helpers::place_limit_order_v2_for_test<USDC, USDT>(
        &mut scenario,
        &registry,
        &base_pool,
        &quote_pool,
        &mut mm,
        &mut pool,
        1,
        constants::no_restriction(),
        constants::self_matching_allowed(),
        1_000_000_000,
        100 * test_constants::usdc_multiplier(),
        false,
        false,
        2_000_000,
        &clock,
    );
    return_shared(base_pool);
    return_shared(quote_pool);
    destroy(order_info);

    return_shared_2!(mm, pool);
    cleanup_margin_test(registry, _admin_cap, _maintainer_cap, clock, scenario);
}

// #3: a manager with already-borrowed *free* funds, sitting in the
// [min_open, min_borrow) band, can still place a normal order — the post-trade
// floor is `min_open`, not `min_borrow`. Deposit 100 USDC, borrow 400 USDT
// (ratio 1.25 at $1), then use the free USDT to market-buy 100 USDC. The buy
// pays the $1.01 ask, landing risk_ratio at 1.2475 — below the borrow floor but
// above the open floor — so it is accepted. Under the old min_borrow gate this
// aborted (the #3 regression).
#[test]
fun place_market_order_v2_with_free_borrowed_funds_in_band_ok() {
    let (
        mut scenario,
        clock,
        _admin_cap,
        _maintainer_cap,
        base_pool_id,
        quote_pool_id,
        pool_id,
        registry_id,
    ) = setup_pool_proxy_test_env<USDC, USDT>();
    setup_orderbook_liquidity_stablecoin<USDC, USDT>(&mut scenario, pool_id, &clock);

    scenario.next_tx(test_constants::user1());
    let mut pool = scenario.take_shared_by_id<Pool<USDC, USDT>>(pool_id);
    let mut registry = scenario.take_shared<MarginRegistry>();
    let base_pool = scenario.take_shared_by_id<MarginPool<USDC>>(base_pool_id);
    let mut quote_pool = scenario.take_shared_by_id<MarginPool<USDT>>(quote_pool_id);
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
        mint_coin<USDC>(100 * test_constants::usdc_multiplier(), scenario.ctx()),
        &clock,
        scenario.ctx(),
    );
    mm.deposit<USDC, USDT, DEEP>(
        &registry,
        &usdc_price,
        &usdt_price,
        mint_coin<DEEP>(100 * test_constants::deep_multiplier(), scenario.ctx()),
        &clock,
        scenario.ctx(),
    );
    // Borrow 400 USDT: ratio = (100 + 400) / 400 = 1.25 at $1.
    mm.borrow_quote<USDC, USDT>(
        &registry,
        &mut quote_pool,
        &usdc_price,
        &usdt_price,
        &pool,
        400 * test_constants::usdt_multiplier(),
        &clock,
        scenario.ctx(),
    );
    destroy_2!(usdc_price, usdt_price);

    // Use the free borrowed USDT to market-buy 100 USDC — no new borrow.
    let order_info = test_helpers::place_market_order_v2_for_test<USDC, USDT>(
        &mut scenario,
        &registry,
        &base_pool,
        &quote_pool,
        &mut mm,
        &mut pool,
        1,
        constants::self_matching_allowed(),
        100 * test_constants::usdc_multiplier(),
        true, // is_bid = true (buy)
        true, // pay_with_deep
        &clock,
    );
    destroy(order_info);

    // Post-trade risk_ratio = (200 + 299) / 400 = 1.2475: in the band, accepted.
    let usdc_price = build_demo_usdc_price_info_object(&mut scenario, &clock);
    let usdt_price = build_demo_usdt_price_info_object(&mut scenario, &clock);
    let rr = mm.risk_ratio(
        &registry,
        &usdc_price,
        &usdt_price,
        &pool,
        &base_pool,
        &quote_pool,
        &clock,
    );
    assert_eq!(rr, 1_247_500_000);
    assert!(rr < registry.min_borrow_risk_ratio(pool_id));
    assert!(rr >= registry.min_open_risk_ratio(pool_id));

    destroy_2!(usdc_price, usdt_price);
    return_shared_3!(mm, pool, quote_pool);
    return_shared(base_pool);
    cleanup_margin_test(registry, _admin_cap, _maintainer_cap, clock, scenario);
}

// === place_market_order_and_repay_loan (non-reduce-only close) ===

#[test]
fun place_market_order_and_repay_loan_fully_closes_long() {
    // A long fully closes via the non-reduce-only and-repay: sell base, repay the
    // quote loan, debt -> 0 (risk_ratio MAX), which clears the min_open gate.
    // Deposit 10000 USDC, borrow 500 USDT, withdraw 300 USDT; sell 600 USDC,
    // whose proceeds repay the entire 500 USDT debt.
    let (
        mut scenario,
        clock,
        _admin_cap,
        _maintainer_cap,
        base_pool_id,
        quote_pool_id,
        pool_id,
        registry_id,
    ) = setup_pool_proxy_test_env<USDC, USDT>();
    setup_orderbook_liquidity_stablecoin<USDC, USDT>(&mut scenario, pool_id, &clock);

    scenario.next_tx(test_constants::user1());
    let mut pool = scenario.take_shared_by_id<Pool<USDC, USDT>>(pool_id);
    let mut registry = scenario.take_shared<MarginRegistry>();
    let mut base_pool = scenario.take_shared_by_id<MarginPool<USDC>>(base_pool_id);
    let mut quote_pool = scenario.take_shared_by_id<MarginPool<USDT>>(quote_pool_id);
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
        mint_coin<USDC>(10000 * test_constants::usdc_multiplier(), scenario.ctx()),
        &clock,
        scenario.ctx(),
    );
    mm.borrow_quote<USDC, USDT>(
        &registry,
        &mut quote_pool,
        &usdc_price,
        &usdt_price,
        &pool,
        500 * test_constants::usdt_multiplier(),
        &clock,
        scenario.ctx(),
    );
    let withdrawn = mm.withdraw<USDC, USDT, USDT>(
        &registry,
        &base_pool,
        &quote_pool,
        &usdc_price,
        &usdt_price,
        &pool,
        300 * test_constants::usdt_multiplier(),
        &clock,
        scenario.ctx(),
    );
    destroy(withdrawn);
    destroy_2!(usdc_price, usdt_price);

    let order_info = test_helpers::place_market_order_and_repay_loan_for_test<USDC, USDT>(
        &mut scenario,
        &registry,
        &mut mm,
        &mut pool,
        &mut base_pool,
        &mut quote_pool,
        1,
        constants::self_matching_allowed(),
        600 * test_constants::usdc_multiplier(),
        false, // is_bid = false (sell base to close the long)
        false,
        &clock,
    );
    destroy(order_info);

    // Loan fully repaid -> position closed.
    assert_eq!(mm.borrowed_quote_shares(), 0);

    return_shared_3!(mm, pool, quote_pool);
    return_shared(base_pool);
    cleanup_margin_test(registry, _admin_cap, _maintainer_cap, clock, scenario);
}

#[test]
fun place_market_order_and_repay_loan_overbuys_short_past_debt() {
    // A short (USDC debt, holding USDT) closes with a bid that buys *more* than
    // the debt — there is no reduce-only quantity cap, so it can overshoot to
    // clear the loan (e.g. round past dust). Owe 100 USDC, buy 101, repay 100,
    // debt -> 0 with ~1 USDC surplus. The reduce-only bid (capped at the net
    // short) would reject 101.
    let (
        mut scenario,
        clock,
        _admin_cap,
        _maintainer_cap,
        base_pool_id,
        quote_pool_id,
        pool_id,
        registry_id,
    ) = setup_pool_proxy_test_env<USDC, USDT>();
    setup_orderbook_liquidity_stablecoin<USDC, USDT>(&mut scenario, pool_id, &clock);

    scenario.next_tx(test_constants::user1());
    let mut pool = scenario.take_shared_by_id<Pool<USDC, USDT>>(pool_id);
    let mut registry = scenario.take_shared<MarginRegistry>();
    let mut base_pool = scenario.take_shared_by_id<MarginPool<USDC>>(base_pool_id);
    let mut quote_pool = scenario.take_shared_by_id<MarginPool<USDT>>(quote_pool_id);
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

    mm.deposit<USDC, USDT, USDT>(
        &registry,
        &usdc_price,
        &usdt_price,
        mint_coin<USDT>(250 * test_constants::usdt_multiplier(), scenario.ctx()),
        &clock,
        scenario.ctx(),
    );
    mm.borrow_base<USDC, USDT>(
        &registry,
        &mut base_pool,
        &usdc_price,
        &usdt_price,
        &pool,
        100 * test_constants::usdc_multiplier(),
        &clock,
        scenario.ctx(),
    );
    // Withdraw the borrowed USDC so the manager is a real short: owe 100 USDC,
    // hold 250 USDT (ratio 2.5, above min_withdraw 2.0).
    let withdrawn = mm.withdraw<USDC, USDT, USDC>(
        &registry,
        &base_pool,
        &quote_pool,
        &usdc_price,
        &usdt_price,
        &pool,
        100 * test_constants::usdc_multiplier(),
        &clock,
        scenario.ctx(),
    );
    destroy(withdrawn);
    destroy_2!(usdc_price, usdt_price);

    let order_info = test_helpers::place_market_order_and_repay_loan_for_test<USDC, USDT>(
        &mut scenario,
        &registry,
        &mut mm,
        &mut pool,
        &mut base_pool,
        &mut quote_pool,
        1,
        constants::self_matching_allowed(),
        101 * test_constants::usdc_multiplier(), // buy 101 to cover a 100 debt
        true, // is_bid = true (buy base to cover the short)
        false,
        &clock,
    );
    destroy(order_info);

    // Overbought past the debt and fully closed.
    assert_eq!(mm.borrowed_base_shares(), 0);

    return_shared_3!(mm, pool, base_pool);
    return_shared(quote_pool);
    cleanup_margin_test(registry, _admin_cap, _maintainer_cap, clock, scenario);
}

#[test]
fun reduce_only_bid_allows_min_size_when_net_debt_is_sub_lot() {
    // Reduce-only "not stuck" floor: when the net short is below one min_size
    // order, the bid is still allowed up to min_size so a dust debt can be
    // covered. Borrow 100 USDC, withdraw only min_size/2 (5000) of it, leaving a
    // net short of 5000 — below the 10000 min_size. A reduce-only limit bid for
    // min_size is accepted; the unfloored net cap (5000) would have rejected it.
    let (
        mut scenario,
        clock,
        _admin_cap,
        _maintainer_cap,
        base_pool_id,
        quote_pool_id,
        pool_id,
        registry_id,
    ) = setup_pool_proxy_test_env<USDC, USDT>();
    setup_orderbook_liquidity_stablecoin<USDC, USDT>(&mut scenario, pool_id, &clock);

    scenario.next_tx(test_constants::user1());
    let mut pool = scenario.take_shared_by_id<Pool<USDC, USDT>>(pool_id);
    let mut registry = scenario.take_shared<MarginRegistry>();
    let mut base_pool = scenario.take_shared_by_id<MarginPool<USDC>>(base_pool_id);
    let quote_pool = scenario.take_shared_by_id<MarginPool<USDT>>(quote_pool_id);
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

    mm.deposit<USDC, USDT, USDT>(
        &registry,
        &usdc_price,
        &usdt_price,
        mint_coin<USDT>(200 * test_constants::usdt_multiplier(), scenario.ctx()),
        &clock,
        scenario.ctx(),
    );
    mm.borrow_base<USDC, USDT>(
        &registry,
        &mut base_pool,
        &usdc_price,
        &usdt_price,
        &pool,
        100 * test_constants::usdc_multiplier(),
        &clock,
        scenario.ctx(),
    );
    // Withdraw only half a min_size of the borrowed USDC, leaving net short 5000.
    let withdrawn = mm.withdraw<USDC, USDT, USDC>(
        &registry,
        &base_pool,
        &quote_pool,
        &usdc_price,
        &usdt_price,
        &pool,
        constants::min_size() / 2,
        &clock,
        scenario.ctx(),
    );
    destroy(withdrawn);
    destroy_2!(usdc_price, usdt_price);

    // Reduce-only limit bid for exactly one min_size, resting at $0.99.
    let order_info = test_helpers::place_reduce_only_limit_order_v2_for_test<USDC, USDT>(
        &mut scenario,
        &registry,
        &base_pool,
        &quote_pool,
        &mut mm,
        &mut pool,
        1,
        constants::no_restriction(),
        constants::self_matching_allowed(),
        990_000_000, // $0.99 (rests below the $1.01 ask)
        constants::min_size(),
        true, // is_bid = true
        false,
        2_000_000,
        &clock,
    );

    assert_eq!(order_info.original_quantity(), constants::min_size());
    assert_eq!(order_info.executed_quantity(), 0);

    destroy(order_info);
    return_shared_3!(mm, pool, base_pool);
    return_shared(quote_pool);
    cleanup_margin_test(registry, _admin_cap, _maintainer_cap, clock, scenario);
}

#[test]
fun reduce_only_and_repay_rounds_net_debt_up_to_lot_to_fully_close() {
    // Reduce-only round-up-to-lot floor: a non-lot-aligned net short can be fully
    // closed by buying the next lot up. Borrow 30 USDC, withdraw all but 500 raw,
    // leaving a net short of ~29_999_500 (not lot-aligned, lot = 1000). The
    // reduce-only and-repay bid for 30_000_000 (the net rounded up to the next
    // lot) is accepted and clears the loan; the un-rounded net cap would reject
    // it, stranding the dust.
    let (
        mut scenario,
        clock,
        _admin_cap,
        _maintainer_cap,
        base_pool_id,
        quote_pool_id,
        pool_id,
        registry_id,
    ) = setup_pool_proxy_test_env<USDC, USDT>();
    setup_orderbook_liquidity_stablecoin<USDC, USDT>(&mut scenario, pool_id, &clock);

    scenario.next_tx(test_constants::user1());
    let mut pool = scenario.take_shared_by_id<Pool<USDC, USDT>>(pool_id);
    let mut registry = scenario.take_shared<MarginRegistry>();
    let mut base_pool = scenario.take_shared_by_id<MarginPool<USDC>>(base_pool_id);
    let mut quote_pool = scenario.take_shared_by_id<MarginPool<USDT>>(quote_pool_id);
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

    mm.deposit<USDC, USDT, USDT>(
        &registry,
        &usdc_price,
        &usdt_price,
        mint_coin<USDT>(100 * test_constants::usdt_multiplier(), scenario.ctx()),
        &clock,
        scenario.ctx(),
    );
    mm.borrow_base<USDC, USDT>(
        &registry,
        &mut base_pool,
        &usdc_price,
        &usdt_price,
        &pool,
        30 * test_constants::usdc_multiplier(), // 30 USDC = 30_000_000 (lot-aligned)
        &clock,
        scenario.ctx(),
    );
    // Withdraw all but 500 raw, leaving net short = 30_000_000 - 500 = 29_999_500
    // (not a multiple of lot_size 1000).
    let withdrawn = mm.withdraw<USDC, USDT, USDC>(
        &registry,
        &base_pool,
        &quote_pool,
        &usdc_price,
        &usdt_price,
        &pool,
        30 * test_constants::usdc_multiplier() - 500,
        &clock,
        scenario.ctx(),
    );
    destroy(withdrawn);
    destroy_2!(usdc_price, usdt_price);

    // Buy 30_000_000 — the net short (~29_999_500) rounded up to the next lot.
    let order_info = test_helpers::place_reduce_only_market_order_and_repay_loan_for_test<
        USDC,
        USDT,
    >(
        &mut scenario,
        &registry,
        &mut mm,
        &mut pool,
        &mut base_pool,
        &mut quote_pool,
        1,
        constants::self_matching_allowed(),
        30 * test_constants::usdc_multiplier(),
        true, // is_bid = true (cover the short)
        false,
        &clock,
    );
    destroy(order_info);

    // Rounding up to the lot let the dust debt be fully cleared.
    assert_eq!(mm.borrowed_base_shares(), 0);

    return_shared_3!(mm, pool, base_pool);
    return_shared(quote_pool);
    cleanup_margin_test(registry, _admin_cap, _maintainer_cap, clock, scenario);
}
