// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module deepbook_margin::tpsl_tests;

use deepbook::balance_manager;
use deepbook::constants;
use deepbook::pool::Pool;
use deepbook::registry::Registry;
use deepbook_margin::margin_manager::{Self, MarginManager};
use deepbook_margin::margin_registry::MarginRegistry;
use deepbook_margin::test_constants::{Self, USDC, USDT};
use deepbook_margin::test_helpers::{
    setup_usdc_usdt_deepbook_margin,
    cleanup_margin_test,
    mint_coin,
    build_demo_usdc_price_info_object,
    build_pyth_price_info_object,
    destroy_2,
    return_shared_2
};
use deepbook_margin::tpsl;
use std::unit_test::destroy;
use sui::test_scenario::return_shared;
use token::deep::DEEP;

// Helper to create a balance manager and place orders on the pool for liquidity
fun setup_pool_liquidity<BaseAsset, QuoteAsset>(
    scenario: &mut sui::test_scenario::Scenario,
    pool_id: ID,
    clock: &sui::clock::Clock,
    base_amount: u64,
    quote_amount: u64,
): ID {
    scenario.next_tx(test_constants::user2());
    let mut pool = scenario.take_shared_by_id<Pool<BaseAsset, QuoteAsset>>(pool_id);
    let mut balance_manager = balance_manager::new(scenario.ctx());

    // Deposit base and quote assets
    balance_manager.deposit(mint_coin<BaseAsset>(base_amount, scenario.ctx()), scenario.ctx());
    balance_manager.deposit(mint_coin<QuoteAsset>(quote_amount, scenario.ctx()), scenario.ctx());
    balance_manager.deposit(
        mint_coin<DEEP>(1000 * test_constants::deep_multiplier(), scenario.ctx()),
        scenario.ctx(),
    );

    // Generate trade proof before sharing
    let trade_proof = balance_manager.generate_proof_as_owner(scenario.ctx());

    // Place ask order (sell base for quote)
    pool.place_limit_order<BaseAsset, QuoteAsset>(
        &mut balance_manager,
        &trade_proof,
        1,
        constants::no_restriction(),
        constants::self_matching_allowed(),
        2 * constants::float_scaling(), // price: 2
        base_amount / 2, // quantity
        false, // is_bid
        true, // pay_with_deep
        constants::max_u64(),
        clock,
        scenario.ctx(),
    );

    // Place bid order (buy base with quote)
    pool.place_limit_order<BaseAsset, QuoteAsset>(
        &mut balance_manager,
        &trade_proof,
        2,
        constants::no_restriction(),
        constants::self_matching_allowed(),
        1 * constants::float_scaling(), // price: 1
        base_amount / 2, // quantity
        true, // is_bid
        true, // pay_with_deep
        constants::max_u64(),
        clock,
        scenario.ctx(),
    );

    let balance_manager_id = balance_manager.id();
    transfer::public_share_object(balance_manager);

    return_shared(pool);
    balance_manager_id
}

// Helper to build price info objects with specific prices
fun build_usdt_price_info_object_with_price(
    scenario: &mut sui::test_scenario::Scenario,
    price_usd: u64,
    clock: &sui::clock::Clock,
): pyth::price_info::PriceInfoObject {
    build_pyth_price_info_object(
        scenario,
        test_constants::usdt_price_feed_id(),
        price_usd * test_constants::pyth_multiplier(),
        50000,
        test_constants::pyth_decimals(),
        clock.timestamp_ms() / 1000,
    )
}

#[test]
fun test_tpsl_trigger_below_limit_order_executed() {
    let (
        mut scenario,
        clock,
        admin_cap,
        maintainer_cap,
        _usdc_pool_id,
        _usdt_pool_id,
        pool_id,
        registry_id,
    ) = setup_usdc_usdt_deepbook_margin();

    // Set up pool liquidity from another user
    setup_pool_liquidity<USDT, USDC>(
        &mut scenario,
        pool_id,
        &clock,
        10000 * test_constants::usdt_multiplier(),
        20000 * test_constants::usdc_multiplier(),
    );

    scenario.next_tx(test_constants::user1());
    let mut margin_registry = scenario.take_shared<MarginRegistry>();
    let pool = scenario.take_shared<Pool<USDT, USDC>>();
    let deepbook_registry = scenario.take_shared_by_id<Registry>(registry_id);
    margin_manager::new<USDT, USDC>(
        &pool,
        &deepbook_registry,
        &mut margin_registry,
        &clock,
        scenario.ctx(),
    );
    return_shared(deepbook_registry);
    return_shared(pool);

    scenario.next_tx(test_constants::user1());
    let mut mm = scenario.take_shared<MarginManager<USDT, USDC>>();

    // Initial prices: USDT = $1.00, USDC = $1.00, so price = 1.0 (in float_scaling)
    let usdt_price_high = build_usdt_price_info_object_with_price(&mut scenario, 1, &clock); // $1.00
    let usdc_price = build_demo_usdc_price_info_object(&mut scenario, &clock); // $1.00

    // Deposit collateral
    mm.deposit<USDT, USDC, USDT>(
        &margin_registry,
        &usdt_price_high,
        &usdc_price,
        mint_coin<USDT>(10000 * test_constants::usdt_multiplier(), scenario.ctx()),
        &clock,
        scenario.ctx(),
    );

    // Current price is 1.0 (1 USDT = 1 USDC)
    // Add conditional order: trigger_is_below = true, trigger_price = 0.8
    // This means: trigger when price drops below 0.8
    // Condition: trigger_price (0.8) < current_price (1.0) ✓
    let condition = tpsl::new_condition(true, (8 * constants::float_scaling()) / 10); // 0.8
    let pending_order = tpsl::new_pending_limit_order(
        1, // client_order_id
        constants::no_restriction(),
        constants::self_matching_allowed(),
        1 * constants::float_scaling(), // price
        100 * test_constants::usdt_multiplier(), // quantity
        true, // is_bid (buy USDT with USDC)
        false, // pay_with_deep
        constants::max_u64(), // expire_timestamp
    );

    mm.add_conditional_order<USDT, USDC>(
        &usdt_price_high,
        &usdc_price,
        &margin_registry,
        1, // conditional_order_identifier
        condition,
        pending_order,
        &clock,
    );

    // Verify conditional order was added
    assert!(margin_manager::conditional_orders(&mm).length() == 1);

    destroy_2!(usdt_price_high, usdc_price);
    return_shared(margin_registry);

    // Update price to trigger: USDT drops to $0.75, so price = 0.75 < 0.8 trigger
    scenario.next_tx(test_constants::admin());
    let usdt_price_low = build_usdt_price_info_object_with_price(&mut scenario, 75, &clock); // $0.75
    let usdc_price = build_demo_usdc_price_info_object(&mut scenario, &clock);

    scenario.next_tx(test_constants::user1());
    let mut pool = scenario.take_shared<Pool<USDT, USDC>>();
    let margin_registry = scenario.take_shared<MarginRegistry>();

    // Execute pending orders - should trigger and place order
    let order_infos = mm.execute_pending_orders<USDT, USDC>(
        &mut pool,
        &usdt_price_low,
        &usdc_price,
        &margin_registry,
        &clock,
        scenario.ctx(),
    );

    // Verify order was executed
    assert!(order_infos.length() == 1);
    destroy(order_infos[0]);

    // Verify conditional order was removed
    assert!(margin_manager::conditional_orders(&mm).length() == 0);

    destroy_2!(usdt_price_low, usdc_price);
    return_shared_2!(mm, pool);

    let deepbook_registry = scenario.take_shared_by_id<Registry>(registry_id);
    return_shared(deepbook_registry);
    cleanup_margin_test(margin_registry, admin_cap, maintainer_cap, clock, scenario);
}

#[test]
fun test_tpsl_trigger_above_limit_order_executed() {
    let (
        mut scenario,
        clock,
        admin_cap,
        maintainer_cap,
        _usdc_pool_id,
        _usdt_pool_id,
        pool_id,
        registry_id,
    ) = setup_usdc_usdt_deepbook_margin();

    setup_pool_liquidity<USDT, USDC>(
        &mut scenario,
        pool_id,
        &clock,
        10000 * test_constants::usdt_multiplier(),
        20000 * test_constants::usdc_multiplier(),
    );

    scenario.next_tx(test_constants::user1());
    let mut margin_registry = scenario.take_shared<MarginRegistry>();
    let pool = scenario.take_shared<Pool<USDT, USDC>>();
    let deepbook_registry = scenario.take_shared_by_id<Registry>(registry_id);
    margin_manager::new<USDT, USDC>(
        &pool,
        &deepbook_registry,
        &mut margin_registry,
        &clock,
        scenario.ctx(),
    );
    return_shared(deepbook_registry);
    return_shared(pool);

    scenario.next_tx(test_constants::user1());
    let mut mm = scenario.take_shared<MarginManager<USDT, USDC>>();

    // Initial prices: USDT = $1.00, USDC = $1.00, so price = 1.0
    let usdt_price_low = build_usdt_price_info_object_with_price(&mut scenario, 1, &clock); // $1.00
    let usdc_price = build_demo_usdc_price_info_object(&mut scenario, &clock); // $1.00

    mm.deposit<USDT, USDC, USDT>(
        &margin_registry,
        &usdt_price_low,
        &usdc_price,
        mint_coin<USDT>(10000 * test_constants::usdt_multiplier(), scenario.ctx()),
        &clock,
        scenario.ctx(),
    );

    // Current price is 1.0
    // Add conditional order: trigger_is_below = false, trigger_price = 1.2
    // This means: trigger when price rises above 1.2
    // Condition: trigger_price (1.2) > current_price (1.0) ✓
    let condition = tpsl::new_condition(false, (12 * constants::float_scaling()) / 10); // 1.2
    let pending_order = tpsl::new_pending_limit_order(
        1,
        constants::no_restriction(),
        constants::self_matching_allowed(),
        1 * constants::float_scaling(),
        100 * test_constants::usdt_multiplier(),
        false, // is_bid (sell USDT for USDC)
        false,
        constants::max_u64(),
    );

    mm.add_conditional_order<USDT, USDC>(
        &usdt_price_low,
        &usdc_price,
        &margin_registry,
        1,
        condition,
        pending_order,
        &clock,
    );

    assert!(margin_manager::conditional_orders(&mm).length() == 1);

    destroy_2!(usdt_price_low, usdc_price);
    return_shared(margin_registry);

    // Update price to trigger: USDT rises to $1.25, so price = 1.25 > 1.2 trigger
    scenario.next_tx(test_constants::admin());
    let usdt_price_high = build_usdt_price_info_object_with_price(&mut scenario, 125, &clock); // $1.25
    let usdc_price = build_demo_usdc_price_info_object(&mut scenario, &clock);

    scenario.next_tx(test_constants::user1());
    let mut pool = scenario.take_shared<Pool<USDT, USDC>>();
    let mut margin_registry = scenario.take_shared<MarginRegistry>();

    let order_infos = mm.execute_pending_orders<USDT, USDC>(
        &mut pool,
        &usdt_price_high,
        &usdc_price,
        &margin_registry,
        &clock,
        scenario.ctx(),
    );

    assert!(order_infos.length() == 1);
    destroy(order_infos[0]);
    assert!(margin_manager::conditional_orders(&mm).length() == 0);

    destroy_2!(usdt_price_high, usdc_price);
    return_shared_2!(mm, pool);

    let deepbook_registry = scenario.take_shared_by_id<Registry>(registry_id);
    return_shared(deepbook_registry);
    cleanup_margin_test(margin_registry, admin_cap, maintainer_cap, clock, scenario);
}

#[test]
fun test_tpsl_trigger_below_market_order_executed() {
    let (
        mut scenario,
        clock,
        admin_cap,
        maintainer_cap,
        _usdc_pool_id,
        _usdt_pool_id,
        pool_id,
        registry_id,
    ) = setup_usdc_usdt_deepbook_margin();

    setup_pool_liquidity<USDT, USDC>(
        &mut scenario,
        pool_id,
        &clock,
        10000 * test_constants::usdt_multiplier(),
        20000 * test_constants::usdc_multiplier(),
    );

    scenario.next_tx(test_constants::user1());
    let mut margin_registry = scenario.take_shared<MarginRegistry>();
    let pool = scenario.take_shared<Pool<USDT, USDC>>();
    let deepbook_registry = scenario.take_shared_by_id<Registry>(registry_id);
    margin_manager::new<USDT, USDC>(
        &pool,
        &deepbook_registry,
        &mut margin_registry,
        &clock,
        scenario.ctx(),
    );
    return_shared(deepbook_registry);
    return_shared(pool);

    scenario.next_tx(test_constants::user1());
    let mut mm = scenario.take_shared<MarginManager<USDT, USDC>>();

    let usdt_price_high = build_usdt_price_info_object_with_price(&mut scenario, 1, &clock);
    let usdc_price = build_demo_usdc_price_info_object(&mut scenario, &clock);

    mm.deposit<USDT, USDC, USDT>(
        &margin_registry,
        &usdt_price_high,
        &usdc_price,
        mint_coin<USDT>(10000 * test_constants::usdt_multiplier(), scenario.ctx()),
        &clock,
        scenario.ctx(),
    );

    let condition = tpsl::new_condition(true, (8 * constants::float_scaling()) / 10);
    let pending_order = tpsl::new_pending_market_order(
        1,
        constants::self_matching_allowed(),
        100 * test_constants::usdt_multiplier(),
        true, // is_bid
        false,
    );

    mm.add_conditional_order<USDT, USDC>(
        &usdt_price_high,
        &usdc_price,
        &margin_registry,
        1,
        condition,
        pending_order,
        &clock,
    );

    assert!(margin_manager::conditional_orders(&mm).length() == 1);

    destroy_2!(usdt_price_high, usdc_price);
    return_shared(margin_registry);

    scenario.next_tx(test_constants::admin());
    let usdt_price_low = build_usdt_price_info_object_with_price(&mut scenario, 75, &clock);
    let usdc_price = build_demo_usdc_price_info_object(&mut scenario, &clock);

    scenario.next_tx(test_constants::user1());
    let mut pool = scenario.take_shared<Pool<USDT, USDC>>();
    let mut margin_registry = scenario.take_shared<MarginRegistry>();

    let order_infos = mm.execute_pending_orders<USDT, USDC>(
        &mut pool,
        &usdt_price_low,
        &usdc_price,
        &margin_registry,
        &clock,
        scenario.ctx(),
    );

    assert!(order_infos.length() == 1);
    destroy(order_infos[0]);
    assert!(margin_manager::conditional_orders(&mm).length() == 0);

    destroy_2!(usdt_price_low, usdc_price);
    return_shared_2!(mm, pool);

    let deepbook_registry = scenario.take_shared_by_id<Registry>(registry_id);
    return_shared(deepbook_registry);
    cleanup_margin_test(margin_registry, admin_cap, maintainer_cap, clock, scenario);
}

#[test]
fun test_tpsl_trigger_above_market_order_executed() {
    let (
        mut scenario,
        clock,
        admin_cap,
        maintainer_cap,
        _usdc_pool_id,
        _usdt_pool_id,
        pool_id,
        registry_id,
    ) = setup_usdc_usdt_deepbook_margin();

    setup_pool_liquidity<USDT, USDC>(
        &mut scenario,
        pool_id,
        &clock,
        10000 * test_constants::usdt_multiplier(),
        20000 * test_constants::usdc_multiplier(),
    );

    scenario.next_tx(test_constants::user1());
    let mut margin_registry = scenario.take_shared<MarginRegistry>();
    let pool = scenario.take_shared<Pool<USDT, USDC>>();
    let deepbook_registry = scenario.take_shared_by_id<Registry>(registry_id);
    margin_manager::new<USDT, USDC>(
        &pool,
        &deepbook_registry,
        &mut margin_registry,
        &clock,
        scenario.ctx(),
    );
    return_shared(deepbook_registry);
    return_shared(margin_registry);
    return_shared(pool);

    scenario.next_tx(test_constants::user1());
    let mut mm = scenario.take_shared<MarginManager<USDT, USDC>>();

    let margin_registry = scenario.take_shared<MarginRegistry>();
    let usdt_price_low = build_usdt_price_info_object_with_price(&mut scenario, 1, &clock);
    let usdc_price = build_demo_usdc_price_info_object(&mut scenario, &clock);

    mm.deposit<USDT, USDC, USDT>(
        &margin_registry,
        &usdt_price_low,
        &usdc_price,
        mint_coin<USDT>(10000 * test_constants::usdt_multiplier(), scenario.ctx()),
        &clock,
        scenario.ctx(),
    );

    let condition = tpsl::new_condition(false, (12 * constants::float_scaling()) / 10);
    let pending_order = tpsl::new_pending_market_order(
        1,
        constants::self_matching_allowed(),
        100 * test_constants::usdt_multiplier(),
        false, // is_bid
        false,
    );

    mm.add_conditional_order<USDT, USDC>(
        &usdt_price_low,
        &usdc_price,
        &margin_registry,
        1,
        condition,
        pending_order,
        &clock,
    );

    assert!(margin_manager::conditional_orders(&mm).length() == 1);
    return_shared(margin_registry);

    destroy_2!(usdt_price_low, usdc_price);

    scenario.next_tx(test_constants::admin());
    let usdt_price_high = build_usdt_price_info_object_with_price(&mut scenario, 125, &clock);
    let usdc_price = build_demo_usdc_price_info_object(&mut scenario, &clock);

    scenario.next_tx(test_constants::user1());
    let mut pool = scenario.take_shared<Pool<USDT, USDC>>();
    let margin_registry = scenario.take_shared<MarginRegistry>();

    let order_infos = mm.execute_pending_orders<USDT, USDC>(
        &mut pool,
        &usdt_price_high,
        &usdc_price,
        &margin_registry,
        &clock,
        scenario.ctx(),
    );

    assert!(order_infos.length() == 1);
    destroy(order_infos[0]);
    assert!(margin_manager::conditional_orders(&mm).length() == 0);

    destroy_2!(usdt_price_high, usdc_price);
    return_shared_2!(mm, pool);

    cleanup_margin_test(margin_registry, admin_cap, maintainer_cap, clock, scenario);
}

#[test]
fun test_tpsl_trigger_below_limit_order_insufficient_balance() {
    let (
        mut scenario,
        clock,
        admin_cap,
        maintainer_cap,
        _usdc_pool_id,
        _usdt_pool_id,
        pool_id,
        registry_id,
    ) = setup_usdc_usdt_deepbook_margin();

    setup_pool_liquidity<USDT, USDC>(
        &mut scenario,
        pool_id,
        &clock,
        10000 * test_constants::usdt_multiplier(),
        20000 * test_constants::usdc_multiplier(),
    );

    scenario.next_tx(test_constants::user1());
    let mut margin_registry = scenario.take_shared<MarginRegistry>();
    let pool = scenario.take_shared<Pool<USDT, USDC>>();
    let deepbook_registry = scenario.take_shared_by_id<Registry>(registry_id);
    margin_manager::new<USDT, USDC>(
        &pool,
        &deepbook_registry,
        &mut margin_registry,
        &clock,
        scenario.ctx(),
    );
    return_shared(deepbook_registry);
    return_shared(pool);

    scenario.next_tx(test_constants::user1());
    let mut mm = scenario.take_shared<MarginManager<USDT, USDC>>();

    let usdt_price_high = build_usdt_price_info_object_with_price(&mut scenario, 1, &clock);
    let usdc_price = build_demo_usdc_price_info_object(&mut scenario, &clock);

    // Deposit minimal collateral - not enough for the order
    mm.deposit<USDT, USDC, USDT>(
        &margin_registry,
        &usdt_price_high,
        &usdc_price,
        mint_coin<USDT>(100 * test_constants::usdt_multiplier(), scenario.ctx()), // Small amount
        &clock,
        scenario.ctx(),
    );

    let condition = tpsl::new_condition(true, (8 * constants::float_scaling()) / 10);
    let pending_order = tpsl::new_pending_limit_order(
        1,
        constants::no_restriction(),
        constants::self_matching_allowed(),
        1 * constants::float_scaling(),
        10000 * test_constants::usdt_multiplier(), // Large quantity - more than available
        true,
        false,
        constants::max_u64(),
    );

    mm.add_conditional_order<USDT, USDC>(
        &usdt_price_high,
        &usdc_price,
        &margin_registry,
        1,
        condition,
        pending_order,
        &clock,
    );

    assert!(margin_manager::conditional_orders(&mm).length() == 1);

    destroy_2!(usdt_price_high, usdc_price);
    return_shared(margin_registry);

    // Trigger condition
    scenario.next_tx(test_constants::admin());
    let usdt_price_low = build_usdt_price_info_object_with_price(&mut scenario, 75, &clock);
    let usdc_price = build_demo_usdc_price_info_object(&mut scenario, &clock);

    scenario.next_tx(test_constants::user1());
    let mut pool = scenario.take_shared<Pool<USDT, USDC>>();
    let mut margin_registry = scenario.take_shared<MarginRegistry>();

    // Execute pending orders - should not place order due to insufficient balance
    let order_infos = mm.execute_pending_orders<USDT, USDC>(
        &mut pool,
        &usdt_price_low,
        &usdc_price,
        &margin_registry,
        &clock,
        scenario.ctx(),
    );

    // No orders executed
    assert!(order_infos.length() == 0);

    // Conditional order should remain
    assert!(margin_manager::conditional_orders(&mm).length() == 1);

    destroy_2!(usdt_price_low, usdc_price);
    return_shared_2!(mm, pool);

    let deepbook_registry = scenario.take_shared_by_id<Registry>(registry_id);
    return_shared(deepbook_registry);
    cleanup_margin_test(margin_registry, admin_cap, maintainer_cap, clock, scenario);
}

#[test]
fun test_tpsl_trigger_above_limit_order_insufficient_balance() {
    let (
        mut scenario,
        clock,
        admin_cap,
        maintainer_cap,
        _usdc_pool_id,
        _usdt_pool_id,
        pool_id,
        registry_id,
    ) = setup_usdc_usdt_deepbook_margin();

    setup_pool_liquidity<USDT, USDC>(
        &mut scenario,
        pool_id,
        &clock,
        10000 * test_constants::usdt_multiplier(),
        20000 * test_constants::usdc_multiplier(),
    );

    scenario.next_tx(test_constants::user1());
    let mut margin_registry = scenario.take_shared<MarginRegistry>();
    let pool = scenario.take_shared<Pool<USDT, USDC>>();
    let deepbook_registry = scenario.take_shared_by_id<Registry>(registry_id);
    margin_manager::new<USDT, USDC>(
        &pool,
        &deepbook_registry,
        &mut margin_registry,
        &clock,
        scenario.ctx(),
    );
    return_shared(deepbook_registry);
    return_shared(pool);

    scenario.next_tx(test_constants::user1());
    let mut mm = scenario.take_shared<MarginManager<USDT, USDC>>();

    let usdt_price_low = build_usdt_price_info_object_with_price(&mut scenario, 1, &clock);
    let usdc_price = build_demo_usdc_price_info_object(&mut scenario, &clock);

    mm.deposit<USDT, USDC, USDT>(
        &margin_registry,
        &usdt_price_low,
        &usdc_price,
        mint_coin<USDT>(100 * test_constants::usdt_multiplier(), scenario.ctx()),
        &clock,
        scenario.ctx(),
    );

    let condition = tpsl::new_condition(false, (12 * constants::float_scaling()) / 10);
    let pending_order = tpsl::new_pending_limit_order(
        1,
        constants::no_restriction(),
        constants::self_matching_allowed(),
        1 * constants::float_scaling(),
        10000 * test_constants::usdt_multiplier(), // Large quantity
        false,
        false,
        constants::max_u64(),
    );

    mm.add_conditional_order<USDT, USDC>(
        &usdt_price_low,
        &usdc_price,
        &margin_registry,
        1,
        condition,
        pending_order,
        &clock,
    );

    assert!(margin_manager::conditional_orders(&mm).length() == 1);

    destroy_2!(usdt_price_low, usdc_price);
    return_shared(margin_registry);

    scenario.next_tx(test_constants::admin());
    let usdt_price_high = build_usdt_price_info_object_with_price(&mut scenario, 125, &clock);
    let usdc_price = build_demo_usdc_price_info_object(&mut scenario, &clock);

    scenario.next_tx(test_constants::user1());
    let mut pool = scenario.take_shared<Pool<USDT, USDC>>();
    let mut margin_registry = scenario.take_shared<MarginRegistry>();

    let order_infos = mm.execute_pending_orders<USDT, USDC>(
        &mut pool,
        &usdt_price_high,
        &usdc_price,
        &margin_registry,
        &clock,
        scenario.ctx(),
    );

    assert!(order_infos.length() == 0);
    assert!(margin_manager::conditional_orders(&mm).length() == 1);

    destroy_2!(usdt_price_high, usdc_price);
    return_shared_2!(mm, pool);

    let deepbook_registry = scenario.take_shared_by_id<Registry>(registry_id);
    return_shared(deepbook_registry);
    cleanup_margin_test(margin_registry, admin_cap, maintainer_cap, clock, scenario);
}

#[test]
fun test_tpsl_trigger_below_market_order_insufficient_balance() {
    let (
        mut scenario,
        clock,
        admin_cap,
        maintainer_cap,
        _usdc_pool_id,
        _usdt_pool_id,
        pool_id,
        registry_id,
    ) = setup_usdc_usdt_deepbook_margin();

    setup_pool_liquidity<USDT, USDC>(
        &mut scenario,
        pool_id,
        &clock,
        10000 * test_constants::usdt_multiplier(),
        20000 * test_constants::usdc_multiplier(),
    );

    scenario.next_tx(test_constants::user1());
    let mut margin_registry = scenario.take_shared<MarginRegistry>();
    let pool = scenario.take_shared<Pool<USDT, USDC>>();
    let deepbook_registry = scenario.take_shared_by_id<Registry>(registry_id);
    margin_manager::new<USDT, USDC>(
        &pool,
        &deepbook_registry,
        &mut margin_registry,
        &clock,
        scenario.ctx(),
    );
    return_shared(deepbook_registry);
    return_shared(pool);

    scenario.next_tx(test_constants::user1());
    let mut mm = scenario.take_shared<MarginManager<USDT, USDC>>();

    let usdt_price_high = build_usdt_price_info_object_with_price(&mut scenario, 1, &clock);
    let usdc_price = build_demo_usdc_price_info_object(&mut scenario, &clock);

    mm.deposit<USDT, USDC, USDT>(
        &margin_registry,
        &usdt_price_high,
        &usdc_price,
        mint_coin<USDT>(100 * test_constants::usdt_multiplier(), scenario.ctx()),
        &clock,
        scenario.ctx(),
    );

    let condition = tpsl::new_condition(true, (8 * constants::float_scaling()) / 10);
    let pending_order = tpsl::new_pending_market_order(
        1,
        constants::self_matching_allowed(),
        10000 * test_constants::usdt_multiplier(), // Large quantity
        true,
        false,
    );

    mm.add_conditional_order<USDT, USDC>(
        &usdt_price_high,
        &usdc_price,
        &margin_registry,
        1,
        condition,
        pending_order,
        &clock,
    );

    assert!(margin_manager::conditional_orders(&mm).length() == 1);

    destroy_2!(usdt_price_high, usdc_price);
    return_shared(margin_registry);

    scenario.next_tx(test_constants::admin());
    let usdt_price_low = build_usdt_price_info_object_with_price(&mut scenario, 75, &clock);
    let usdc_price = build_demo_usdc_price_info_object(&mut scenario, &clock);

    scenario.next_tx(test_constants::user1());
    let mut pool = scenario.take_shared<Pool<USDT, USDC>>();
    let mut margin_registry = scenario.take_shared<MarginRegistry>();

    let order_infos = mm.execute_pending_orders<USDT, USDC>(
        &mut pool,
        &usdt_price_low,
        &usdc_price,
        &margin_registry,
        &clock,
        scenario.ctx(),
    );

    assert!(order_infos.length() == 0);
    assert!(margin_manager::conditional_orders(&mm).length() == 1);

    destroy_2!(usdt_price_low, usdc_price);
    return_shared_2!(mm, pool);

    let deepbook_registry = scenario.take_shared_by_id<Registry>(registry_id);
    return_shared(deepbook_registry);
    cleanup_margin_test(margin_registry, admin_cap, maintainer_cap, clock, scenario);
}

#[test]
fun test_tpsl_trigger_above_market_order_insufficient_balance() {
    let (
        mut scenario,
        clock,
        admin_cap,
        maintainer_cap,
        _usdc_pool_id,
        _usdt_pool_id,
        pool_id,
        registry_id,
    ) = setup_usdc_usdt_deepbook_margin();

    setup_pool_liquidity<USDT, USDC>(
        &mut scenario,
        pool_id,
        &clock,
        10000 * test_constants::usdt_multiplier(),
        20000 * test_constants::usdc_multiplier(),
    );

    scenario.next_tx(test_constants::user1());
    let mut margin_registry = scenario.take_shared<MarginRegistry>();
    let pool = scenario.take_shared<Pool<USDT, USDC>>();
    let deepbook_registry = scenario.take_shared_by_id<Registry>(registry_id);
    margin_manager::new<USDT, USDC>(
        &pool,
        &deepbook_registry,
        &mut margin_registry,
        &clock,
        scenario.ctx(),
    );
    return_shared(deepbook_registry);
    return_shared(pool);

    scenario.next_tx(test_constants::user1());
    let mut mm = scenario.take_shared<MarginManager<USDT, USDC>>();

    let usdt_price_low = build_usdt_price_info_object_with_price(&mut scenario, 1, &clock);
    let usdc_price = build_demo_usdc_price_info_object(&mut scenario, &clock);

    mm.deposit<USDT, USDC, USDT>(
        &margin_registry,
        &usdt_price_low,
        &usdc_price,
        mint_coin<USDT>(100 * test_constants::usdt_multiplier(), scenario.ctx()),
        &clock,
        scenario.ctx(),
    );

    let condition = tpsl::new_condition(false, (12 * constants::float_scaling()) / 10);
    let pending_order = tpsl::new_pending_market_order(
        1,
        constants::self_matching_allowed(),
        10000 * test_constants::usdt_multiplier(), // Large quantity
        false,
        false,
    );

    mm.add_conditional_order<USDT, USDC>(
        &usdt_price_low,
        &usdc_price,
        &margin_registry,
        1,
        condition,
        pending_order,
        &clock,
    );

    assert!(margin_manager::conditional_orders(&mm).length() == 1);

    destroy_2!(usdt_price_low, usdc_price);
    return_shared(margin_registry);

    scenario.next_tx(test_constants::admin());
    let usdt_price_high = build_usdt_price_info_object_with_price(&mut scenario, 125, &clock);
    let usdc_price = build_demo_usdc_price_info_object(&mut scenario, &clock);

    scenario.next_tx(test_constants::user1());
    let mut pool = scenario.take_shared<Pool<USDT, USDC>>();
    let mut margin_registry = scenario.take_shared<MarginRegistry>();

    let order_infos = mm.execute_pending_orders<USDT, USDC>(
        &mut pool,
        &usdt_price_high,
        &usdc_price,
        &margin_registry,
        &clock,
        scenario.ctx(),
    );

    assert!(order_infos.length() == 0);
    assert!(margin_manager::conditional_orders(&mm).length() == 1);

    destroy_2!(usdt_price_high, usdc_price);
    return_shared_2!(mm, pool);

    let deepbook_registry = scenario.take_shared_by_id<Registry>(registry_id);
    return_shared(deepbook_registry);
    cleanup_margin_test(margin_registry, admin_cap, maintainer_cap, clock, scenario);
}
