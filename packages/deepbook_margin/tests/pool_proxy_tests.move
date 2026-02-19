// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module deepbook_margin::pool_proxy_tests;

use deepbook::{constants, pool::Pool, registry::Registry};
use deepbook_margin::{
    margin_manager::{Self, MarginManager},
    margin_pool::{Self, MarginPool},
    margin_registry::{Self, MarginRegistry},
    pool_proxy,
    test_constants::{Self, USDC, USDT},
    test_helpers::{
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
        setup_orderbook_liquidity_stablecoin,
        setup_orderbook_liquidity_out_of_bounds_stablecoin
    }
};
use std::unit_test::destroy;
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
    let order_info = pool_proxy::place_limit_order<USDC, USDT>(
        &registry,
        &mut mm,
        &mut pool,
        1, // client_order_id
        constants::no_restriction(),
        constants::self_matching_allowed(),
        1_000_000_000, // price (1.0 in 9 decimals, within 5% of oracle price)
        100 * test_constants::usdc_multiplier(), // quantity
        false, // is_bid (sell USDC for USDT)
        false, // pay_with_deep
        2000000, // expire_timestamp
        &clock,
        scenario.ctx(),
    );

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

    // Try to place order with wrong pool - should fail
    pool_proxy::place_limit_order<USDC, USDT>(
        &registry,
        &mut mm,
        &mut wrong_pool, // Wrong pool!
        1,
        constants::no_restriction(),
        constants::self_matching_allowed(),
        1_000_000,
        100,
        true,
        false,
        0,
        &clock,
        scenario.ctx(),
    );

    abort
}

#[test, expected_failure(abort_code = pool_proxy::EIncorrectDeepBookPool)]
fun test_place_limit_order_pool_not_enabled() {
    let (mut scenario, clock, admin_cap, maintainer_cap) = setup_margin_registry();

    // Create a margin pool
    create_margin_pool<USDC>(&mut scenario, &maintainer_cap, default_protocol_config(), &clock);
    create_margin_pool<USDT>(&mut scenario, &maintainer_cap, default_protocol_config(), &clock);

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
    pool_proxy::place_limit_order<USDC, USDT>(
        &registry,
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
        scenario.ctx(),
    );

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
        _base_pool_id,
        _quote_pool_id,
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
    let order_info = pool_proxy::place_market_order<USDC, USDT>(
        &registry,
        &mut mm,
        &mut pool,
        2, // client_order_id
        constants::self_matching_allowed(),
        100 * test_constants::usdc_multiplier(), // quantity
        false, // is_bid = false (sell USDC)
        false, // pay_with_deep
        &clock,
        scenario.ctx(),
    );

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
        _base_pool_id,
        _quote_pool_id,
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

    pool_proxy::place_market_order<USDC, USDT>(
        &registry,
        &mut mm,
        &mut wrong_pool, // Wrong pool!
        2,
        constants::self_matching_allowed(),
        100,
        true,
        false,
        &clock,
        scenario.ctx(),
    );

    abort
}

#[test, expected_failure(abort_code = pool_proxy::EIncorrectDeepBookPool)]
fun test_place_market_order_pool_not_enabled() {
    let (mut scenario, clock, admin_cap, maintainer_cap) = setup_margin_registry();

    create_margin_pool<USDC>(&mut scenario, &maintainer_cap, default_protocol_config(), &clock);
    create_margin_pool<USDT>(&mut scenario, &maintainer_cap, default_protocol_config(), &clock);

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

    pool_proxy::place_market_order<USDC, USDT>(
        &registry,
        &mut mm,
        &mut non_margin_pool,
        2,
        constants::self_matching_allowed(),
        100 * test_constants::usdc_multiplier(),
        false,
        false,
        &clock,
        scenario.ctx(),
    );

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
    let order_info = pool_proxy::place_reduce_only_limit_order<USDC, USDT, USDC>(
        &registry,
        &mut mm,
        &mut pool,
        &base_pool, // Pass base_pool since we have USDC debt
        1,
        constants::no_restriction(),
        constants::self_matching_allowed(),
        1_000_000_000, // price (1.0 in 9 decimals, within 5% of oracle price)
        100 * test_constants::usdc_multiplier(), // quantity (less than debt)
        true, // is_bid = true (buying USDC to reduce debt)
        false,
        2000000, // expire_timestamp
        &clock,
        scenario.ctx(),
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
    let order_info = pool_proxy::place_reduce_only_limit_order<USDC, USDT, USDT>(
        &registry,
        &mut mm,
        &mut pool,
        &quote_pool,
        1,
        constants::no_restriction(),
        constants::self_matching_allowed(),
        1_000_000_000, // price (1.0 in 9 decimals)
        100 * test_constants::usdc_multiplier(), // quantity (selling 100 USDC to get ~100 USDT, less than 300 debt)
        false, // is_bid = false (selling USDC to get USDT)
        false,
        2000000,
        &clock,
        scenario.ctx(),
    );

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
        _base_pool_id,
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

    pool_proxy::place_reduce_only_limit_order<USDC, USDT, USDT>(
        &registry,
        &mut mm,
        &mut wrong_pool, // Wrong pool!
        &quote_pool,
        3,
        constants::no_restriction(),
        constants::self_matching_allowed(),
        1_000_000,
        500,
        false,
        false,
        0,
        &clock,
        scenario.ctx(),
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
        _base_pool_id,
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
    pool_proxy::place_reduce_only_limit_order<USDC, USDT, USDT>(
        &registry,
        &mut mm,
        &mut pool,
        &quote_pool, // Pass quote_pool since we have USDT debt
        1,
        constants::no_restriction(),
        constants::self_matching_allowed(),
        1_000_000_000, // price (1.0 in 9 decimals, within 5% of oracle price)
        100 * test_constants::usdc_multiplier(), // quantity
        true, // is_bid = true (buying USDC)
        false,
        2000000, // expire_timestamp
        &clock,
        scenario.ctx(),
    );

    return_shared_3!(mm, pool, quote_pool);
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
    pool_proxy::place_reduce_only_limit_order<USDC, USDT, USDC>(
        &registry,
        &mut mm,
        &mut pool,
        &base_pool, // Pass quote_pool since we have USDT debt
        1,
        constants::no_restriction(),
        constants::self_matching_allowed(),
        constants::float_scaling(), // price
        101 * test_constants::usdc_multiplier(), // quantity
        true, // is_bid = true (buying USDC)
        false,
        2000000, // expire_timestamp
        &clock,
        scenario.ctx(),
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

    // User has USDC debt, tries to buy more USDC than debt
    // This should fail because user is trying to buy more USDC than debt
    pool_proxy::place_reduce_only_limit_order<USDC, USDT, USDT>(
        &registry,
        &mut mm,
        &mut pool,
        &quote_pool, // Pass quote_pool since we have USDT debt
        1,
        constants::no_restriction(),
        constants::self_matching_allowed(),
        constants::float_scaling(), // price
        101 * test_constants::usdc_multiplier(), // quantity
        false, // is_bid = false (buying USDT)
        false,
        2000000, // expire_timestamp
        &clock,
        scenario.ctx(),
    );

    return_shared_2!(mm, pool);
    return_shared_2!(base_pool, quote_pool);
    destroy(usdc_price);
    destroy(usdt_price);
    cleanup_margin_test(registry, _admin_cap, _maintainer_cap, clock, scenario);
}

// === Place Reduce Only Market Order Tests ===

#[test]
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
    let order_info = pool_proxy::place_reduce_only_market_order<USDC, USDT, USDC>(
        &registry,
        &mut mm,
        &mut pool,
        &base_pool, // Pass base_pool since we have USDC debt
        2,
        constants::self_matching_allowed(),
        100 * test_constants::usdc_multiplier(), // quantity (less than debt)
        true, // is_bid = true (buying USDC to reduce debt)
        false,
        &clock,
        scenario.ctx(),
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
    let order_info = pool_proxy::place_reduce_only_market_order<USDC, USDT, USDT>(
        &registry,
        &mut mm,
        &mut pool,
        &quote_pool,
        2,
        constants::self_matching_allowed(),
        100 * test_constants::usdc_multiplier(), // quantity (selling 100 USDC to get ~100 USDT, less than 300 debt)
        false, // is_bid = false (selling USDC to get USDT)
        false,
        &clock,
        scenario.ctx(),
    );

    destroy(order_info);
    return_shared_2!(mm, pool);
    return_shared_2!(base_pool, quote_pool);
    destroy(usdc_price);
    destroy(usdt_price);
    cleanup_margin_test(registry, _admin_cap, _maintainer_cap, clock, scenario);
}

#[test, expected_failure(abort_code = pool_proxy::EIncorrectDeepBookPool)]
fun test_place_reduce_only_market_order_incorrect_pool() {
    let (
        mut scenario,
        clock,
        _admin_cap,
        _maintainer_cap,
        _base_pool_id,
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

    pool_proxy::place_reduce_only_market_order<USDC, USDT, USDT>(
        &registry,
        &mut mm,
        &mut wrong_pool, // Wrong pool!
        &quote_pool,
        4,
        constants::self_matching_allowed(),
        500,
        false,
        false,
        &clock,
        scenario.ctx(),
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
        _base_pool_id,
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
    pool_proxy::place_reduce_only_market_order<USDC, USDT, USDT>(
        &registry,
        &mut mm,
        &mut pool,
        &quote_pool, // Pass quote_pool since we have USDT debt
        3,
        constants::self_matching_allowed(),
        100 * test_constants::usdc_multiplier(), // quantity
        true, // is_bid = true (buying USDC)
        false,
        &clock,
        scenario.ctx(),
    );

    return_shared_3!(mm, pool, quote_pool);
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
    pool_proxy::place_reduce_only_market_order<USDC, USDT, USDC>(
        &registry,
        &mut mm,
        &mut pool,
        &base_pool,
        4,
        constants::self_matching_allowed(),
        101 * test_constants::usdc_multiplier(),
        true, // is_bid
        false,
        &clock,
        scenario.ctx(),
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
    pool_proxy::place_reduce_only_market_order<USDC, USDT, USDT>(
        &registry,
        &mut mm,
        &mut pool,
        &quote_pool,
        5,
        constants::self_matching_allowed(),
        150 * test_constants::usdc_multiplier(),
        false, // is_bid = false (selling USDC to get USDT)
        false,
        &clock,
        scenario.ctx(),
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

    // First place an order
    let order_info = pool_proxy::place_limit_order<USDC, USDT>(
        &registry,
        &mut mm,
        &mut pool,
        1,
        constants::no_restriction(),
        constants::self_matching_allowed(),
        1_000_000_000, // price (1.0 in 9 decimals)
        100 * test_constants::usdc_multiplier(),
        false, // is_bid (sell USDC for USDT)
        false,
        2000000, // expire_timestamp
        &clock,
        scenario.ctx(),
    );

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

    let order_info = pool_proxy::place_limit_order<USDC, USDT>(
        &registry,
        &mut mm,
        &mut pool,
        1,
        constants::no_restriction(),
        constants::self_matching_allowed(),
        1_000_000_000, // price (1.0 in 9 decimals)
        100 * test_constants::usdc_multiplier(),
        false, // is_bid (sell USDC for USDT)
        false,
        2000000, // expire_timestamp
        &clock,
        scenario.ctx(),
    );

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

    let order_info1 = pool_proxy::place_limit_order<USDC, USDT>(
        &registry,
        &mut mm,
        &mut pool,
        1,
        constants::no_restriction(),
        constants::self_matching_allowed(),
        1_000_000_000, // price (1.0 in 9 decimals)
        1000 * test_constants::usdc_multiplier(), // Increased quantity to meet minimum size
        false, // is_bid (sell USDC for USDT)
        false,
        2000000, // expire_timestamp
        &clock,
        scenario.ctx(),
    );
    let order_info2 = pool_proxy::place_limit_order<USDC, USDT>(
        &registry,
        &mut mm,
        &mut pool,
        2,
        constants::no_restriction(),
        constants::self_matching_allowed(),
        1_020_000_000, // price (1.02 in 9 decimals, slightly higher)
        1000 * test_constants::usdc_multiplier(), // Increased quantity to meet minimum size
        false, // is_bid (sell USDC for USDT)
        false,
        2000000, // expire_timestamp
        &clock,
        scenario.ctx(),
    );

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
        _base_pool_id,
        _quote_pool_id,
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
    let order_info = pool_proxy::place_limit_order<USDC, USDT>(
        &registry,
        &mut mm,
        &mut pool,
        1, // client_order_id
        constants::no_restriction(),
        constants::self_matching_allowed(),
        1_000_000_000, // price (1.0 in 9 decimals, within 5% of oracle price)
        100 * test_constants::usdc_multiplier(), // quantity
        false, // is_bid (sell USDC for USDT)
        false, // pay_with_deep
        2000000, // expire_timestamp
        &clock,
        scenario.ctx(),
    );

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
    let order_info2 = pool_proxy::place_limit_order<USDC, USDT>(
        &registry,
        &mut mm2,
        &mut pool,
        2, // client_order_id
        constants::no_restriction(),
        constants::self_matching_allowed(),
        1_000_000_000, // same price (1.0 in 9 decimals)
        100 * test_constants::usdc_multiplier(), // same quantity
        true, // is_bid (buy USDC with USDT)
        false, // pay_with_deep
        2000000, // expire_timestamp
        &clock,
        scenario.ctx(),
    );
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
    pool_proxy::place_limit_order<USDC, USDT>(
        &registry,
        &mut mm,
        &mut pool,
        1,
        constants::no_restriction(),
        constants::self_matching_allowed(),
        1_100_000_000, // 10% above oracle - should fail
        100 * test_constants::usdc_multiplier(),
        true,
        false,
        18446744073709551615,
        &clock,
        scenario.ctx(),
    );

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
    pool_proxy::place_limit_order<USDC, USDT>(
        &registry,
        &mut mm,
        &mut pool,
        1,
        constants::no_restriction(),
        constants::self_matching_allowed(),
        900_000_000, // 10% below oracle - should fail for asks
        100 * test_constants::usdc_multiplier(),
        false, // is_bid = false (ask/sell order)
        false,
        18446744073709551615,
        &clock,
        scenario.ctx(),
    );

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
    let order_info = pool_proxy::place_limit_order<USDC, USDT>(
        &registry,
        &mut mm,
        &mut pool,
        1,
        constants::no_restriction(),
        constants::self_matching_allowed(),
        1_050_000_000, // Exactly at upper bound - should succeed
        100 * test_constants::usdc_multiplier(),
        false, // sell USDC for USDT
        false,
        18446744073709551615,
        &clock,
        scenario.ctx(),
    );

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
    let order_info = pool_proxy::place_limit_order<USDC, USDT>(
        &registry,
        &mut mm,
        &mut pool,
        1,
        constants::no_restriction(),
        constants::self_matching_allowed(),
        950_000_000, // Exactly at lower bound - should succeed
        100 * test_constants::usdc_multiplier(),
        false, // sell USDC for USDT
        false,
        18446744073709551615,
        &clock,
        scenario.ctx(),
    );

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
    create_margin_pool<USDC>(&mut scenario, &maintainer_cap, default_protocol_config(), &clock);
    create_margin_pool<USDT>(&mut scenario, &maintainer_cap, default_protocol_config(), &clock);

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
    create_margin_pool<USDC>(&mut scenario, &maintainer_cap, default_protocol_config(), &clock);
    create_margin_pool<USDT>(&mut scenario, &maintainer_cap, default_protocol_config(), &clock);

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
    create_margin_pool<USDC>(&mut scenario, &maintainer_cap, default_protocol_config(), &clock);
    create_margin_pool<USDT>(&mut scenario, &maintainer_cap, default_protocol_config(), &clock);

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

    create_margin_pool<USDC>(&mut scenario, &maintainer_cap, default_protocol_config(), &clock);
    create_margin_pool<USDT>(&mut scenario, &maintainer_cap, default_protocol_config(), &clock);

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

    create_margin_pool<USDC>(&mut scenario, &maintainer_cap, default_protocol_config(), &clock);
    create_margin_pool<USDT>(&mut scenario, &maintainer_cap, default_protocol_config(), &clock);

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

    create_margin_pool<USDC>(&mut scenario, &maintainer_cap, default_protocol_config(), &clock);
    create_margin_pool<USDT>(&mut scenario, &maintainer_cap, default_protocol_config(), &clock);

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

    create_margin_pool<USDC>(&mut scenario, &maintainer_cap, default_protocol_config(), &clock);
    create_margin_pool<USDT>(&mut scenario, &maintainer_cap, default_protocol_config(), &clock);

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

    create_margin_pool<USDC>(&mut scenario, &maintainer_cap, default_protocol_config(), &clock);
    create_margin_pool<USDT>(&mut scenario, &maintainer_cap, default_protocol_config(), &clock);

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
    pool_proxy::place_limit_order<USDC, USDT>(
        &registry,
        &mut mm,
        &mut pool,
        1,
        constants::no_restriction(),
        constants::self_matching_allowed(),
        1_040_000_000, // 4% above oracle
        100 * test_constants::usdc_multiplier(),
        true, // is_bid
        false,
        2000000,
        &clock,
        scenario.ctx(),
    );

    abort 0
}

#[test, expected_failure(abort_code = margin_registry::EPriceUpdateRequired)]
fun test_max_price_age_decrease_rejects_order_e2e() {
    // End-to-end test: order fails after max_price_age is decreased and price becomes stale
    let (mut scenario, mut clock, admin_cap, maintainer_cap) = setup_margin_registry();

    clock.set_for_testing(1_000_000);

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
    pool_proxy::place_limit_order<USDC, USDT>(
        &registry,
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
        scenario.ctx(),
    );

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

    // Oracle price is 1_000_000_000, upper bound = 1_050_000_000
    // Price 1_050_000_001 is just above upper bound - should fail for bids
    pool_proxy::place_limit_order<USDC, USDT>(
        &registry,
        &mut mm,
        &mut pool,
        1,
        constants::no_restriction(),
        constants::self_matching_allowed(),
        1_050_000_001, // Just above upper bound
        100 * test_constants::usdc_multiplier(),
        true, // is_bid = true (buy order)
        false,
        18446744073709551615,
        &clock,
        scenario.ctx(),
    );

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

    // Oracle price is 1_000_000_000, lower bound = 950_000_000
    // Price 949_999_999 is just below lower bound - should fail
    pool_proxy::place_limit_order<USDC, USDT>(
        &registry,
        &mut mm,
        &mut pool,
        1,
        constants::no_restriction(),
        constants::self_matching_allowed(),
        949_999_999, // Just below lower bound
        100 * test_constants::usdc_multiplier(),
        false,
        false,
        18446744073709551615,
        &clock,
        scenario.ctx(),
    );

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
    let order_info = pool_proxy::place_limit_order<USDC, USDT>(
        &registry,
        &mut mm,
        &mut pool,
        1,
        constants::no_restriction(),
        constants::self_matching_allowed(),
        500_000_000, // 50% below oracle - should succeed for bids
        100 * test_constants::usdc_multiplier(),
        true, // is_bid = true (buy order)
        false,
        18446744073709551615,
        &clock,
        scenario.ctx(),
    );

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
    let order_info = pool_proxy::place_limit_order<USDC, USDT>(
        &registry,
        &mut mm,
        &mut pool,
        1,
        constants::no_restriction(),
        constants::self_matching_allowed(),
        1_500_000_000, // 50% above oracle - should succeed for asks
        100 * test_constants::usdc_multiplier(),
        false, // is_bid = false (sell order)
        false,
        18446744073709551615,
        &clock,
        scenario.ctx(),
    );

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
        _base_pool_id,
        _quote_pool_id,
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
    let order_info = pool_proxy::place_market_order<USDC, USDT>(
        &registry,
        &mut mm,
        &mut pool,
        1,
        constants::self_matching_allowed(),
        100 * test_constants::usdc_multiplier(),
        true, // is_bid = true (buy)
        false,
        &clock,
        scenario.ctx(),
    );

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
        _base_pool_id,
        _quote_pool_id,
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
    let order_info = pool_proxy::place_market_order<USDC, USDT>(
        &registry,
        &mut mm,
        &mut pool,
        1,
        constants::self_matching_allowed(),
        100 * test_constants::usdc_multiplier(),
        false, // is_bid = false (sell)
        false,
        &clock,
        scenario.ctx(),
    );

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
        _base_pool_id,
        _quote_pool_id,
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
    pool_proxy::place_market_order<USDC, USDT>(
        &registry,
        &mut mm,
        &mut pool,
        1,
        constants::self_matching_allowed(),
        100 * test_constants::usdc_multiplier(),
        true, // is_bid = true (buy)
        false,
        &clock,
        scenario.ctx(),
    );

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
        _base_pool_id,
        _quote_pool_id,
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
    pool_proxy::place_market_order<USDC, USDT>(
        &registry,
        &mut mm,
        &mut pool,
        1,
        constants::self_matching_allowed(),
        100 * test_constants::usdc_multiplier(),
        false, // is_bid = false (sell)
        false,
        &clock,
        scenario.ctx(),
    );

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
        _base_pool_id,
        _quote_pool_id,
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
    pool_proxy::place_market_order<USDC, USDT>(
        &registry,
        &mut mm,
        &mut pool,
        1,
        constants::self_matching_allowed(),
        100 * test_constants::usdc_multiplier(),
        true, // is_bid = true (buy)
        false,
        &clock,
        scenario.ctx(),
    );

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
        _base_pool_id,
        _quote_pool_id,
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
    pool_proxy::place_market_order<USDC, USDT>(
        &registry,
        &mut mm,
        &mut pool,
        1,
        constants::self_matching_allowed(),
        100 * test_constants::usdc_multiplier(),
        false, // is_bid = false (sell)
        false,
        &clock,
        scenario.ctx(),
    );

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
    pool_proxy::place_limit_order<USDC, USDT>(
        &registry,
        &mut mm,
        &mut pool,
        1,
        constants::no_restriction(),
        constants::self_matching_allowed(),
        1_000_000_000, // $1.00
        100 * test_constants::usdc_multiplier(),
        false,
        false,
        18446744073709551615,
        &clock,
        scenario.ctx(),
    );

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

    // Advance clock past max_price_age (default is 5 minutes, advance 6 minutes)
    clock.increment_for_testing(6 * 60 * 1000);

    // Try to place limit order with stale price
    // Should fail with EPriceUpdateRequired
    pool_proxy::place_limit_order<USDC, USDT>(
        &registry,
        &mut mm,
        &mut pool,
        1,
        constants::no_restriction(),
        constants::self_matching_allowed(),
        1_000_000_000, // $1.00
        100 * test_constants::usdc_multiplier(),
        false,
        false,
        18446744073709551615,
        &clock,
        scenario.ctx(),
    );

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
        _base_pool_id,
        _quote_pool_id,
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
    let order_info = pool_proxy::place_market_order<USDC, USDT>(
        &registry,
        &mut mm,
        &mut pool,
        1,
        constants::self_matching_allowed(),
        constants::min_size(), // exactly min_size
        false, // is_bid = false (sell)
        false, // pay_with_deep = false (use input fee)
        &clock,
        scenario.ctx(),
    );

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
        _base_pool_id,
        _quote_pool_id,
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
    let order_info = pool_proxy::place_market_order<USDC, USDT>(
        &registry,
        &mut mm,
        &mut pool,
        1,
        constants::self_matching_allowed(),
        constants::min_size(), // exactly min_size base to buy
        true, // is_bid = true (buy)
        false, // pay_with_deep = false (use input fee)
        &clock,
        scenario.ctx(),
    );

    // Verify order executed
    assert!(order_info.status() == constants::filled());

    return_shared_2!(mm, pool);
    cleanup_margin_test(registry, _admin_cap, _maintainer_cap, clock, scenario);
}
