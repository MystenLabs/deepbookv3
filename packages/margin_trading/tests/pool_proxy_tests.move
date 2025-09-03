// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module margin_trading::pool_proxy_tests;

use deepbook::{constants, pool::Pool};
use margin_trading::{
    margin_manager::{Self, MarginManager},
    margin_pool::MarginPool,
    margin_registry::MarginRegistry,
    pool_proxy,
    test_constants::{Self, USDC, USDT},
    test_helpers::{
        setup_pool_proxy_test_env,
        create_wrong_pool,
        cleanup_margin_test,
        mint_coin,
        destroy_2,
        return_shared_2
    }
};
use sui::test_utils::destroy;
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
    ) = setup_pool_proxy_test_env<USDC, USDT>();

    scenario.next_tx(test_constants::user1());
    let mut pool = scenario.take_shared_by_id<Pool<USDC, USDT>>(pool_id);
    let registry = scenario.take_shared<MarginRegistry>();
    margin_manager::new<USDC, USDT>(&pool, &registry, &clock, scenario.ctx());

    scenario.next_tx(test_constants::user1());
    let mut mm = scenario.take_shared<MarginManager<USDC, USDT>>();

    // Deposit some collateral
    mm.deposit<USDC, USDT, USDC>(
        &registry,
        mint_coin<USDC>(10000 * test_constants::usdc_multiplier(), scenario.ctx()),
        scenario.ctx(),
    );

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
    ) = setup_pool_proxy_test_env<USDC, USDT>();

    // Create a wrong pool
    let wrong_pool_id = create_wrong_pool<USDC, USDT>(&mut scenario);

    scenario.next_tx(test_constants::user1());
    let mut pool = scenario.take_shared_by_id<Pool<USDC, USDT>>(pool_id);
    let mut wrong_pool = scenario.take_shared_by_id<Pool<USDC, USDT>>(wrong_pool_id);
    let registry = scenario.take_shared<MarginRegistry>();
    margin_manager::new<USDC, USDT>(&pool, &registry, &clock, scenario.ctx());

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

#[test, expected_failure(abort_code = pool_proxy::EPoolNotEnabledForMarginTrading)]
fun test_place_limit_order_pool_not_enabled() {
    let (
        mut scenario,
        clock,
        _admin_cap,
        _maintainer_cap,
        _base_pool_id,
        _quote_pool_id,
        _pool_id,
    ) = setup_pool_proxy_test_env<USDC, USDT>();

    // Create a new pool that is NOT enabled for margin trading
    let non_margin_pool_id = create_wrong_pool<USDC, USDT>(&mut scenario);

    scenario.next_tx(test_constants::user1());
    let mut non_margin_pool = scenario.take_shared_by_id<Pool<USDC, USDT>>(non_margin_pool_id);
    let registry = scenario.take_shared<MarginRegistry>();

    // Create margin manager with the non-margin pool
    margin_manager::new<USDC, USDT>(&non_margin_pool, &registry, &clock, scenario.ctx());

    scenario.next_tx(test_constants::user1());
    let mut mm = scenario.take_shared<MarginManager<USDC, USDT>>();

    // Try to place order - should fail because pool not enabled for margin trading
    pool_proxy::place_limit_order<USDC, USDT>(
        &registry,
        &mut mm,
        &mut non_margin_pool,
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
    ) = setup_pool_proxy_test_env<USDC, USDT>();

    scenario.next_tx(test_constants::user1());
    let mut pool = scenario.take_shared_by_id<Pool<USDC, USDT>>(pool_id);
    let registry = scenario.take_shared<MarginRegistry>();
    margin_manager::new<USDC, USDT>(&pool, &registry, &clock, scenario.ctx());

    scenario.next_tx(test_constants::user1());
    let mut mm = scenario.take_shared<MarginManager<USDC, USDT>>();

    mm.deposit<USDC, USDT, USDC>(
        &registry,
        mint_coin<USDC>(10000 * test_constants::usdc_multiplier(), scenario.ctx()),
        scenario.ctx(),
    );

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
    ) = setup_pool_proxy_test_env<USDC, USDT>();

    let wrong_pool_id = create_wrong_pool<USDC, USDT>(&mut scenario);

    scenario.next_tx(test_constants::user1());
    let mut pool = scenario.take_shared_by_id<Pool<USDC, USDT>>(pool_id);
    let mut wrong_pool = scenario.take_shared_by_id<Pool<USDC, USDT>>(wrong_pool_id);
    let registry = scenario.take_shared<MarginRegistry>();
    margin_manager::new<USDC, USDT>(&pool, &registry, &clock, scenario.ctx());

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

#[test, expected_failure(abort_code = pool_proxy::EPoolNotEnabledForMarginTrading)]
fun test_place_market_order_pool_not_enabled() {
    let (
        mut scenario,
        clock,
        _admin_cap,
        _maintainer_cap,
        _base_pool_id,
        _quote_pool_id,
        _pool_id,
    ) = setup_pool_proxy_test_env<USDC, USDT>();

    let non_margin_pool_id = create_wrong_pool<USDC, USDT>(&mut scenario);

    scenario.next_tx(test_constants::user1());
    let mut non_margin_pool = scenario.take_shared_by_id<Pool<USDC, USDT>>(non_margin_pool_id);
    let registry = scenario.take_shared<MarginRegistry>();

    margin_manager::new<USDC, USDT>(&non_margin_pool, &registry, &clock, scenario.ctx());

    scenario.next_tx(test_constants::user1());
    let mut mm = scenario.take_shared<MarginManager<USDC, USDT>>();

    pool_proxy::place_market_order<USDC, USDT>(
        &registry,
        &mut mm,
        &mut non_margin_pool,
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

// === Place Reduce Only Limit Order Tests ===

#[test]
fun test_place_reduce_only_limit_order_ok() {}

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
    ) = setup_pool_proxy_test_env<USDC, USDT>();

    let wrong_pool_id = create_wrong_pool<USDC, USDT>(&mut scenario);

    scenario.next_tx(test_constants::user1());
    let mut pool = scenario.take_shared_by_id<Pool<USDC, USDT>>(pool_id);
    let mut wrong_pool = scenario.take_shared_by_id<Pool<USDC, USDT>>(wrong_pool_id);
    let registry = scenario.take_shared<MarginRegistry>();
    let quote_pool = scenario.take_shared_by_id<MarginPool<USDT>>(quote_pool_id);

    margin_manager::new<USDC, USDT>(&pool, &registry, &clock, scenario.ctx());

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
    ) = setup_pool_proxy_test_env<USDC, USDT>();

    scenario.next_tx(test_constants::user1());
    let mut pool = scenario.take_shared_by_id<Pool<USDC, USDT>>(pool_id);
    let registry = scenario.take_shared<MarginRegistry>();
    let quote_pool = scenario.take_shared_by_id<MarginPool<USDT>>(quote_pool_id);

    margin_manager::new<USDC, USDT>(&pool, &registry, &clock, scenario.ctx());

    scenario.next_tx(test_constants::user1());
    let mut mm = scenario.take_shared<MarginManager<USDC, USDT>>();

    // Don't create any debt, so any order would not be reduce-only
    mm.deposit<USDC, USDT, USDC>(
        &registry,
        mint_coin<USDC>(10000 * test_constants::usdc_multiplier(), scenario.ctx()),
        scenario.ctx(),
    );

    // Try to place reduce-only order without debt - should fail
    pool_proxy::place_reduce_only_limit_order<USDC, USDT, USDT>(
        &registry,
        &mut mm,
        &mut pool,
        &quote_pool,
        3,
        constants::no_restriction(),
        constants::self_matching_allowed(),
        1_000_000,
        500 * test_constants::usdt_multiplier(),
        false,
        false,
        0,
        &clock,
        scenario.ctx(),
    );

    abort
}

// === Place Reduce Only Market Order Tests ===

#[test]
fun test_place_reduce_only_market_order_ok() {}

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
    ) = setup_pool_proxy_test_env<USDC, USDT>();

    let wrong_pool_id = create_wrong_pool<USDC, USDT>(&mut scenario);

    scenario.next_tx(test_constants::user1());
    let mut pool = scenario.take_shared_by_id<Pool<USDC, USDT>>(pool_id);
    let mut wrong_pool = scenario.take_shared_by_id<Pool<USDC, USDT>>(wrong_pool_id);
    let registry = scenario.take_shared<MarginRegistry>();
    let quote_pool = scenario.take_shared_by_id<MarginPool<USDT>>(quote_pool_id);

    margin_manager::new<USDC, USDT>(&pool, &registry, &clock, scenario.ctx());

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
    ) = setup_pool_proxy_test_env<USDC, USDT>();

    scenario.next_tx(test_constants::user1());
    let mut pool = scenario.take_shared_by_id<Pool<USDC, USDT>>(pool_id);
    let registry = scenario.take_shared<MarginRegistry>();
    let quote_pool = scenario.take_shared_by_id<MarginPool<USDT>>(quote_pool_id);

    margin_manager::new<USDC, USDT>(&pool, &registry, &clock, scenario.ctx());

    scenario.next_tx(test_constants::user1());
    let mut mm = scenario.take_shared<MarginManager<USDC, USDT>>();

    // Don't create any debt, so any order would not be reduce-only
    mm.deposit<USDC, USDT, USDC>(
        &registry,
        mint_coin<USDC>(10000 * test_constants::usdc_multiplier(), scenario.ctx()),
        scenario.ctx(),
    );

    // Try to place reduce-only market order without debt - should fail
    pool_proxy::place_reduce_only_market_order<USDC, USDT, USDT>(
        &registry,
        &mut mm,
        &mut pool,
        &quote_pool,
        4,
        constants::self_matching_allowed(),
        500 * test_constants::usdt_multiplier(),
        false,
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
    ) = setup_pool_proxy_test_env<USDC, USDT>();

    scenario.next_tx(test_constants::user1());
    let mut pool = scenario.take_shared_by_id<Pool<USDC, USDT>>(pool_id);
    let registry = scenario.take_shared<MarginRegistry>();
    margin_manager::new<USDC, USDT>(&pool, &registry, &clock, scenario.ctx());

    scenario.next_tx(test_constants::user1());
    let mut mm = scenario.take_shared<MarginManager<USDC, USDT>>();

    // Deposit DEEP tokens
    mm.deposit<USDC, USDT, DEEP>(
        &registry,
        mint_coin<DEEP>(1000 * 1_000_000_000, scenario.ctx()),
        scenario.ctx(),
    );

    // Stake DEEP tokens - should work since this is not a DEEP margin manager
    pool_proxy::stake<USDC, USDT>(
        &registry,
        &mut mm,
        &mut pool,
        100 * 1_000_000_000, // 100 DEEP
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
    ) = setup_pool_proxy_test_env<DEEP, USDT>();

    scenario.next_tx(test_constants::user1());
    let mut pool = scenario.take_shared_by_id<Pool<DEEP, USDT>>(pool_id);
    let registry = scenario.take_shared<MarginRegistry>();
    margin_manager::new<DEEP, USDT>(&pool, &registry, &clock, scenario.ctx());

    scenario.next_tx(test_constants::user1());
    let mut mm = scenario.take_shared<MarginManager<DEEP, USDT>>();

    // Try to stake with DEEP margin manager - should fail
    pool_proxy::stake<DEEP, USDT>(
        &registry,
        &mut mm,
        &mut pool,
        100 * 1_000_000_000,
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
    ) = setup_pool_proxy_test_env<USDC, USDT>();

    scenario.next_tx(test_constants::user1());
    let mut pool = scenario.take_shared_by_id<Pool<USDC, USDT>>(pool_id);
    let registry = scenario.take_shared<MarginRegistry>();
    margin_manager::new<USDC, USDT>(&pool, &registry, &clock, scenario.ctx());

    scenario.next_tx(test_constants::user1());
    let mut mm = scenario.take_shared<MarginManager<USDC, USDT>>();

    mm.deposit<USDC, USDT, USDC>(
        &registry,
        mint_coin<USDC>(10000 * test_constants::usdc_multiplier(), scenario.ctx()),
        scenario.ctx(),
    );

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
        true,
        false,
        0,
        &clock,
        scenario.ctx(),
    );

    let order_id = order_info.order_id();

    // Now modify the order
    pool_proxy::modify_order<USDC, USDT>(
        &registry,
        &mut mm,
        &mut pool,
        order_id,
        200 * test_constants::usdc_multiplier(), // new quantity
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
    ) = setup_pool_proxy_test_env<USDC, USDT>();

    scenario.next_tx(test_constants::user1());
    let mut pool = scenario.take_shared_by_id<Pool<USDC, USDT>>(pool_id);
    let registry = scenario.take_shared<MarginRegistry>();
    margin_manager::new<USDC, USDT>(&pool, &registry, &clock, scenario.ctx());

    scenario.next_tx(test_constants::user1());
    let mut mm = scenario.take_shared<MarginManager<USDC, USDT>>();

    mm.deposit<USDC, USDT, USDC>(
        &registry,
        mint_coin<USDC>(10000 * test_constants::usdc_multiplier(), scenario.ctx()),
        scenario.ctx(),
    );

    let order_info = pool_proxy::place_limit_order<USDC, USDT>(
        &registry,
        &mut mm,
        &mut pool,
        1,
        constants::no_restriction(),
        constants::self_matching_allowed(),
        1_000_000,
        100 * test_constants::usdc_multiplier(),
        true,
        false,
        0,
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
    ) = setup_pool_proxy_test_env<USDC, USDT>();

    scenario.next_tx(test_constants::user1());
    let mut pool = scenario.take_shared_by_id<Pool<USDC, USDT>>(pool_id);
    let registry = scenario.take_shared<MarginRegistry>();
    margin_manager::new<USDC, USDT>(&pool, &registry, &clock, scenario.ctx());

    scenario.next_tx(test_constants::user1());
    let mut mm = scenario.take_shared<MarginManager<USDC, USDT>>();

    mm.deposit<USDC, USDT, USDC>(
        &registry,
        mint_coin<USDC>(10000 * test_constants::usdc_multiplier(), scenario.ctx()),
        scenario.ctx(),
    );

    let order_info1 = pool_proxy::place_limit_order<USDC, USDT>(
        &registry,
        &mut mm,
        &mut pool,
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
    let order_info2 = pool_proxy::place_limit_order<USDC, USDT>(
        &registry,
        &mut mm,
        &mut pool,
        2,
        constants::no_restriction(),
        constants::self_matching_allowed(),
        1_100_000,
        100,
        true,
        false,
        0,
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
    ) = setup_pool_proxy_test_env<USDC, USDT>();

    scenario.next_tx(test_constants::user1());
    let mut pool = scenario.take_shared_by_id<Pool<USDC, USDT>>(pool_id);
    let registry = scenario.take_shared<MarginRegistry>();
    margin_manager::new<USDC, USDT>(&pool, &registry, &clock, scenario.ctx());

    scenario.next_tx(test_constants::user1());
    let mut mm = scenario.take_shared<MarginManager<USDC, USDT>>();

    mm.deposit<USDC, USDT, USDC>(
        &registry,
        mint_coin<USDC>(10000 * test_constants::usdc_multiplier(), scenario.ctx()),
        scenario.ctx(),
    );

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
    ) = setup_pool_proxy_test_env<USDC, USDT>();

    scenario.next_tx(test_constants::user1());
    let mut pool = scenario.take_shared_by_id<Pool<USDC, USDT>>(pool_id);
    let registry = scenario.take_shared<MarginRegistry>();
    margin_manager::new<USDC, USDT>(&pool, &registry, &clock, scenario.ctx());

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
    ) = setup_pool_proxy_test_env<USDC, USDT>();

    scenario.next_tx(test_constants::user1());
    let mut pool = scenario.take_shared_by_id<Pool<USDC, USDT>>(pool_id);
    let registry = scenario.take_shared<MarginRegistry>();
    margin_manager::new<USDC, USDT>(&pool, &registry, &clock, scenario.ctx());

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
        _admin_cap,
        _maintainer_cap,
        _base_pool_id,
        _quote_pool_id,
        pool_id,
    ) = setup_pool_proxy_test_env<USDC, USDT>();

    scenario.next_tx(test_constants::user1());
    let mut pool = scenario.take_shared_by_id<Pool<USDC, USDT>>(pool_id);
    let registry = scenario.take_shared<MarginRegistry>();
    margin_manager::new<USDC, USDT>(&pool, &registry, &clock, scenario.ctx());

    scenario.next_tx(test_constants::user1());
    let mut mm = scenario.take_shared<MarginManager<USDC, USDT>>();

    pool_proxy::submit_proposal<USDC, USDT>(
        &registry,
        &mut mm,
        &mut pool,
        100000, // taker_fee
        50000, // maker_fee
        1000 * 1_000_000_000, // stake_required
        scenario.ctx(),
    );

    return_shared_2!(mm, pool);
    cleanup_margin_test(registry, _admin_cap, _maintainer_cap, clock, scenario);
}

#[test]
fun test_vote_ok() {
    let (
        mut scenario,
        clock,
        _admin_cap,
        _maintainer_cap,
        _base_pool_id,
        _quote_pool_id,
        pool_id,
    ) = setup_pool_proxy_test_env<USDC, USDT>();

    scenario.next_tx(test_constants::user1());
    let mut pool = scenario.take_shared_by_id<Pool<USDC, USDT>>(pool_id);
    let registry = scenario.take_shared<MarginRegistry>();
    margin_manager::new<USDC, USDT>(&pool, &registry, &clock, scenario.ctx());

    scenario.next_tx(test_constants::user1());
    let mut mm = scenario.take_shared<MarginManager<USDC, USDT>>();

    // Use a dummy proposal ID
    let dummy_proposal_id = sui::object::id_from_address(@0x1);

    pool_proxy::vote<USDC, USDT>(
        &registry,
        &mut mm,
        &mut pool,
        dummy_proposal_id,
        scenario.ctx(),
    );

    return_shared_2!(mm, pool);
    cleanup_margin_test(registry, _admin_cap, _maintainer_cap, clock, scenario);
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
    ) = setup_pool_proxy_test_env<USDC, USDT>();

    scenario.next_tx(test_constants::user1());
    let mut pool = scenario.take_shared_by_id<Pool<USDC, USDT>>(pool_id);
    let registry = scenario.take_shared<MarginRegistry>();
    margin_manager::new<USDC, USDT>(&pool, &registry, &clock, scenario.ctx());

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
