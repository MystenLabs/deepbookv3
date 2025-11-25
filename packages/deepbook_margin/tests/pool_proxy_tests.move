// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module deepbook_margin::pool_proxy_tests;

use deepbook::{constants, pool::Pool, registry::Registry};
use deepbook_margin::{
    margin_manager::{Self, MarginManager},
    margin_pool::MarginPool,
    margin_registry::MarginRegistry,
    pool_proxy,
    test_constants::{Self, USDC, USDT},
    test_helpers::{
        setup_pool_proxy_test_env,
        setup_margin_registry,
        create_margin_pool,
        create_pool_for_testing,
        enable_deepbook_margin_on_pool,
        default_protocol_config,
        cleanup_margin_test,
        mint_coin,
        destroy_2,
        return_shared_2,
        return_shared_3,
        build_demo_usdc_price_info_object,
        build_demo_usdt_price_info_object
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
    let order_info = pool_proxy::place_limit_order<USDC, USDT>(
        &registry,
        &mut mm,
        &mut pool,
        1, // client_order_id
        constants::no_restriction(),
        constants::self_matching_allowed(),
        1_000_000, // price
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

    let order_info = pool_proxy::place_market_order<USDC, USDT>(
        &registry,
        &mut mm,
        &mut pool,
        2, // client_order_id
        constants::self_matching_allowed(),
        100 * test_constants::usdc_multiplier(), // quantity
        true, // is_bid
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
    let order_info = pool_proxy::place_reduce_only_limit_order<USDC, USDT, USDC>(
        &registry,
        &mut mm,
        &mut pool,
        &base_pool, // Pass base_pool since we have USDC debt
        1,
        constants::no_restriction(),
        constants::self_matching_allowed(),
        1_100_000, // price
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
    pool_proxy::place_reduce_only_limit_order<USDC, USDT, USDT>(
        &registry,
        &mut mm,
        &mut pool,
        &quote_pool, // Pass quote_pool since we have USDT debt
        1,
        constants::no_restriction(),
        constants::self_matching_allowed(),
        1_100_000, // price
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
        1_000_000,
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
        1_000_000,
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
        1_000_000,
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
        1_100_000,
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
    let order_info = pool_proxy::place_limit_order<USDC, USDT>(
        &registry,
        &mut mm,
        &mut pool,
        1, // client_order_id
        constants::no_restriction(),
        constants::self_matching_allowed(),
        1_000_000, // price
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
        1_000_000, // same price
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
