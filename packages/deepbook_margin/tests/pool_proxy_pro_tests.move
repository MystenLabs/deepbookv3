// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Behavioural coverage for `pool_proxy_pro`.
///
/// Mirrors the legacy `pool_proxy_tests` happy paths through the Pyth Pro feed. The
/// Pro entrypoints are a distinct Move type surface, so nothing in the legacy suite
/// reaches them; without these, a wrong `_core` target or a downgraded reader would
/// still compile and still pass CI.
#[test_only]
module deepbook_margin::pool_proxy_pro_tests;

use deepbook::{constants, pool::Pool, registry::Registry};
use deepbook_margin::{
    margin_manager::{Self, MarginManager},
    margin_manager_pro,
    margin_pool::MarginPool,
    margin_registry::MarginRegistry,
    pool_proxy_pro,
    test_constants::{Self, USDC, USDT},
    test_helpers::{
        setup_pool_proxy_test_env,
        cleanup_margin_test,
        mint_coin,
        destroy_2,
        return_shared_2,
        build_demo_usdc_price_info_object_pro,
        build_demo_usdt_price_info_object_pro,
        build_stale_usdc_price_info_object_pro,
        setup_orderbook_liquidity_stablecoin,
    }
};
use std::unit_test::destroy;
use sui::test_scenario::return_shared;

/// `update_current_price` is the permissionless refresh the order-validation path
/// depends on. Without a Pro twin, price updates would stop at the cutover.
#[test]
fun update_current_price_pro_refreshes_the_registry() {
    let (
        mut scenario,
        clock,
        admin_cap,
        maintainer_cap,
        _b,
        _q,
        pool_id,
        _r,
    ) = setup_pool_proxy_test_env<USDC, USDT>();

    scenario.next_tx(test_constants::user1());
    let pool = scenario.take_shared_by_id<Pool<USDC, USDT>>(pool_id);
    let mut registry = scenario.take_shared<MarginRegistry>();

    let usdc_price = build_demo_usdc_price_info_object_pro(&mut scenario, &clock);
    let usdt_price = build_demo_usdt_price_info_object_pro(&mut scenario, &clock);

    pool_proxy_pro::update_current_price<USDC, USDT>(
        &mut registry,
        &pool,
        &usdc_price,
        &usdt_price,
        &clock,
    );

    destroy_2!(usdc_price, usdt_price);
    return_shared(pool);
    cleanup_margin_test(registry, admin_cap, maintainer_cap, clock, scenario);
}

/// A debt-free manager places a limit order through the Pro entrypoint. Also pins the
/// lazy-read fix: the feeds here are stale, and a debt-free manager must not need
/// them, exactly as before the migration.
#[test]
fun place_limit_order_v2_pro_no_debt_tolerates_stale_feed() {
    let (
        mut scenario,
        clock,
        admin_cap,
        maintainer_cap,
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
    let usdc_price = build_demo_usdc_price_info_object_pro(&mut scenario, &clock);
    let usdt_price = build_demo_usdt_price_info_object_pro(&mut scenario, &clock);

    margin_manager_pro::deposit<USDC, USDT, USDC>(
        &mut mm,
        &registry,
        &usdc_price,
        &usdt_price,
        mint_coin<USDC>(10000 * test_constants::usdc_multiplier(), scenario.ctx()),
        &clock,
        scenario.ctx(),
    );

    let base_pool = scenario.take_shared_by_id<MarginPool<USDC>>(base_pool_id);
    let quote_pool = scenario.take_shared_by_id<MarginPool<USDT>>(quote_pool_id);

    // Stale feeds: with no debt the solvency gate short-circuits, so no read happens.
    let stale_usdc = build_stale_usdc_price_info_object_pro(&mut scenario, 600, &clock);
    let stale_usdt = build_demo_usdt_price_info_object_pro(&mut scenario, &clock);

    let order_info = pool_proxy_pro::place_limit_order_v2<USDC, USDT>(
        &registry,
        &mut mm,
        &mut pool,
        &base_pool,
        &quote_pool,
        &stale_usdc,
        &stale_usdt,
        1,
        constants::no_restriction(),
        constants::self_matching_allowed(),
        1_000_000_000,
        100 * test_constants::usdc_multiplier(),
        false,
        false,
        2000000,
        &clock,
        scenario.ctx(),
    );
    destroy(order_info);

    return_shared(base_pool);
    return_shared(quote_pool);
    destroy_2!(usdc_price, usdt_price);
    destroy_2!(stale_usdc, stale_usdt);
    return_shared_2!(mm, pool);
    cleanup_margin_test(registry, admin_cap, maintainer_cap, clock, scenario);
}

/// Market order through the Pro entrypoint, debt-free, with a fresh feed.
#[test]
fun place_market_order_v2_pro_places_an_order() {
    let (
        mut scenario,
        clock,
        admin_cap,
        maintainer_cap,
        base_pool_id,
        quote_pool_id,
        pool_id,
        registry_id,
    ) = setup_pool_proxy_test_env<USDC, USDT>();

    // A market order needs a resting book to cross against.
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
    let usdc_price = build_demo_usdc_price_info_object_pro(&mut scenario, &clock);
    let usdt_price = build_demo_usdt_price_info_object_pro(&mut scenario, &clock);

    margin_manager_pro::deposit<USDC, USDT, USDC>(
        &mut mm,
        &registry,
        &usdc_price,
        &usdt_price,
        mint_coin<USDC>(10000 * test_constants::usdc_multiplier(), scenario.ctx()),
        &clock,
        scenario.ctx(),
    );

    let base_pool = scenario.take_shared_by_id<MarginPool<USDC>>(base_pool_id);
    let quote_pool = scenario.take_shared_by_id<MarginPool<USDT>>(quote_pool_id);

    let order_info = pool_proxy_pro::place_market_order_v2<USDC, USDT>(
        &registry,
        &mut mm,
        &mut pool,
        &base_pool,
        &quote_pool,
        &usdc_price,
        &usdt_price,
        2,
        constants::self_matching_allowed(),
        50 * test_constants::usdc_multiplier(),
        false,
        false,
        &clock,
        scenario.ctx(),
    );
    destroy(order_info);

    return_shared(base_pool);
    return_shared(quote_pool);
    destroy_2!(usdc_price, usdt_price);
    return_shared_2!(mm, pool);
    cleanup_margin_test(registry, admin_cap, maintainer_cap, clock, scenario);
}

/// Reduce-only limit order through the Pro entrypoint. A bid requires base debt, so
/// these entries always read the oracle - unlike the plain v2 entries.
#[test]
fun place_reduce_only_limit_order_v2_pro_places_an_order() {
    let (
        mut scenario,
        clock,
        admin_cap,
        maintainer_cap,
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
    let usdc_price = build_demo_usdc_price_info_object_pro(&mut scenario, &clock);
    let usdt_price = build_demo_usdt_price_info_object_pro(&mut scenario, &clock);
    let mut base_pool = scenario.take_shared_by_id<MarginPool<USDC>>(base_pool_id);
    let quote_pool = scenario.take_shared_by_id<MarginPool<USDT>>(quote_pool_id);

    // Collateral in quote, debt in base: the shape every reduce-only bid needs.
    margin_manager_pro::deposit<USDC, USDT, USDT>(
        &mut mm,
        &registry,
        &usdc_price,
        &usdt_price,
        mint_coin<USDT>(10000 * test_constants::usdt_multiplier(), scenario.ctx()),
        &clock,
        scenario.ctx(),
    );
    margin_manager_pro::borrow_base<USDC, USDT>(
        &mut mm,
        &registry,
        &mut base_pool,
        &usdc_price,
        &usdt_price,
        &pool,
        500 * test_constants::usdc_multiplier(),
        &clock,
        scenario.ctx(),
    );

    let order_info = pool_proxy_pro::place_reduce_only_limit_order_v2<USDC, USDT>(
        &registry,
        &mut mm,
        &mut pool,
        &base_pool,
        &quote_pool,
        &usdc_price,
        &usdt_price,
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
    destroy(order_info);

    return_shared(base_pool);
    return_shared(quote_pool);
    destroy_2!(usdc_price, usdt_price);
    return_shared_2!(mm, pool);
    cleanup_margin_test(registry, admin_cap, maintainer_cap, clock, scenario);
}

/// Reduce-only market order through the Pro entrypoint. Like its legacy twin
/// (`pool_proxy_tests::test_place_reduce_only_market_order_ok`), this is an
/// `expected_failure`: a market close pays the spread, and the monotonic gate fires on
/// the swap-only intermediate state before any repay. Documented in `move.md`.
#[test, expected_failure(abort_code = deepbook_margin::pool_proxy::ERiskRatioMustNotWorsen)]
fun place_reduce_only_market_order_v2_pro_aborts_on_worsened_ratio() {
    let (
        mut scenario,
        clock,
        admin_cap,
        maintainer_cap,
        base_pool_id,
        quote_pool_id,
        pool_id,
        registry_id,
    ) = setup_pool_proxy_test_env<USDC, USDT>();

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
    let usdc_price = build_demo_usdc_price_info_object_pro(&mut scenario, &clock);
    let usdt_price = build_demo_usdt_price_info_object_pro(&mut scenario, &clock);
    let mut base_pool = scenario.take_shared_by_id<MarginPool<USDC>>(base_pool_id);
    let quote_pool = scenario.take_shared_by_id<MarginPool<USDT>>(quote_pool_id);

    // Collateral in quote, debt in base: the shape every reduce-only bid needs.
    margin_manager_pro::deposit<USDC, USDT, USDT>(
        &mut mm,
        &registry,
        &usdc_price,
        &usdt_price,
        mint_coin<USDT>(10000 * test_constants::usdt_multiplier(), scenario.ctx()),
        &clock,
        scenario.ctx(),
    );
    margin_manager_pro::borrow_base<USDC, USDT>(
        &mut mm,
        &registry,
        &mut base_pool,
        &usdc_price,
        &usdt_price,
        &pool,
        500 * test_constants::usdc_multiplier(),
        &clock,
        scenario.ctx(),
    );

    let order_info = pool_proxy_pro::place_reduce_only_market_order_v2<USDC, USDT>(
        &registry,
        &mut mm,
        &mut pool,
        &base_pool,
        &quote_pool,
        &usdc_price,
        &usdt_price,
        2,
        constants::self_matching_allowed(),
        10 * test_constants::usdc_multiplier(),
        true,
        false,
        &clock,
        scenario.ctx(),
    );
    destroy(order_info);

    return_shared(base_pool);
    return_shared(quote_pool);
    destroy_2!(usdc_price, usdt_price);
    return_shared_2!(mm, pool);
    cleanup_margin_test(registry, admin_cap, maintainer_cap, clock, scenario);
}

/// Reduce-only limit close + repay through the Pro entrypoint. A bid requires base
/// debt, which the setup establishes.
#[test]
fun place_reduce_only_limit_order_and_repay_loan_pro_places_an_order() {
    let (
        mut scenario,
        clock,
        admin_cap,
        maintainer_cap,
        base_pool_id,
        quote_pool_id,
        pool_id,
        registry_id,
    ) = setup_pool_proxy_test_env<USDC, USDT>();

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
    let usdc_price = build_demo_usdc_price_info_object_pro(&mut scenario, &clock);
    let usdt_price = build_demo_usdt_price_info_object_pro(&mut scenario, &clock);
    let mut base_pool = scenario.take_shared_by_id<MarginPool<USDC>>(base_pool_id);
    let mut quote_pool = scenario.take_shared_by_id<MarginPool<USDT>>(quote_pool_id);

    margin_manager_pro::deposit<USDC, USDT, USDT>(
        &mut mm,
        &registry,
        &usdc_price,
        &usdt_price,
        mint_coin<USDT>(10000 * test_constants::usdt_multiplier(), scenario.ctx()),
        &clock,
        scenario.ctx(),
    );
    margin_manager_pro::borrow_base<USDC, USDT>(
        &mut mm,
        &registry,
        &mut base_pool,
        &usdc_price,
        &usdt_price,
        &pool,
        500 * test_constants::usdc_multiplier(),
        &clock,
        scenario.ctx(),
    );

    let order_info = pool_proxy_pro::place_reduce_only_limit_order_and_repay_loan<USDC, USDT>(
        &registry,
        &mut mm,
        &mut pool,
        &mut base_pool,
        &mut quote_pool,
        &usdc_price,
        &usdt_price,
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
    destroy(order_info);

    return_shared(base_pool);
    return_shared(quote_pool);
    destroy_2!(usdc_price, usdt_price);
    return_shared_2!(mm, pool);
    cleanup_margin_test(registry, admin_cap, maintainer_cap, clock, scenario);
}

/// Reduce-only market close *with* the repay included. Unlike the swap-only
/// `place_reduce_only_market_order_v2` above - which trips the monotonic gate on the
/// spread - including the repay lifts the ratio, so this succeeds. That contrast is
/// the behaviour `move.md` documents, and it holds on the Pro path too.
#[test]
fun place_reduce_only_market_order_and_repay_loan_pro_closes_and_repays() {
    let (
        mut scenario,
        clock,
        admin_cap,
        maintainer_cap,
        base_pool_id,
        quote_pool_id,
        pool_id,
        registry_id,
    ) = setup_pool_proxy_test_env<USDC, USDT>();

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
    let usdc_price = build_demo_usdc_price_info_object_pro(&mut scenario, &clock);
    let usdt_price = build_demo_usdt_price_info_object_pro(&mut scenario, &clock);
    let mut base_pool = scenario.take_shared_by_id<MarginPool<USDC>>(base_pool_id);
    let mut quote_pool = scenario.take_shared_by_id<MarginPool<USDT>>(quote_pool_id);

    margin_manager_pro::deposit<USDC, USDT, USDT>(
        &mut mm,
        &registry,
        &usdc_price,
        &usdt_price,
        mint_coin<USDT>(10000 * test_constants::usdt_multiplier(), scenario.ctx()),
        &clock,
        scenario.ctx(),
    );
    margin_manager_pro::borrow_base<USDC, USDT>(
        &mut mm,
        &registry,
        &mut base_pool,
        &usdc_price,
        &usdt_price,
        &pool,
        500 * test_constants::usdc_multiplier(),
        &clock,
        scenario.ctx(),
    );

    let order_info = pool_proxy_pro::place_reduce_only_market_order_and_repay_loan<USDC, USDT>(
        &registry,
        &mut mm,
        &mut pool,
        &mut base_pool,
        &mut quote_pool,
        &usdc_price,
        &usdt_price,
        2,
        constants::self_matching_allowed(),
        10 * test_constants::usdc_multiplier(),
        true,
        false,
        &clock,
        scenario.ctx(),
    );
    destroy(order_info);

    return_shared(base_pool);
    return_shared(quote_pool);
    destroy_2!(usdc_price, usdt_price);
    return_shared_2!(mm, pool);
    cleanup_margin_test(registry, admin_cap, maintainer_cap, clock, scenario);
}

/// Non-reduce-only market close + repay through the Pro entrypoint. Shares the
/// monotonic gate with the reduce-only entries; the repay carries it.
#[test]
fun place_market_order_and_repay_loan_pro_closes_and_repays() {
    let (
        mut scenario,
        clock,
        admin_cap,
        maintainer_cap,
        base_pool_id,
        quote_pool_id,
        pool_id,
        registry_id,
    ) = setup_pool_proxy_test_env<USDC, USDT>();

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
    let usdc_price = build_demo_usdc_price_info_object_pro(&mut scenario, &clock);
    let usdt_price = build_demo_usdt_price_info_object_pro(&mut scenario, &clock);
    let mut base_pool = scenario.take_shared_by_id<MarginPool<USDC>>(base_pool_id);
    let mut quote_pool = scenario.take_shared_by_id<MarginPool<USDT>>(quote_pool_id);

    margin_manager_pro::deposit<USDC, USDT, USDT>(
        &mut mm,
        &registry,
        &usdc_price,
        &usdt_price,
        mint_coin<USDT>(10000 * test_constants::usdt_multiplier(), scenario.ctx()),
        &clock,
        scenario.ctx(),
    );
    margin_manager_pro::borrow_base<USDC, USDT>(
        &mut mm,
        &registry,
        &mut base_pool,
        &usdc_price,
        &usdt_price,
        &pool,
        500 * test_constants::usdc_multiplier(),
        &clock,
        scenario.ctx(),
    );

    let order_info = pool_proxy_pro::place_market_order_and_repay_loan<USDC, USDT>(
        &registry,
        &mut mm,
        &mut pool,
        &mut base_pool,
        &mut quote_pool,
        &usdc_price,
        &usdt_price,
        3,
        constants::self_matching_allowed(),
        10 * test_constants::usdc_multiplier(),
        true,
        false,
        &clock,
        scenario.ctx(),
    );
    destroy(order_info);

    return_shared(base_pool);
    return_shared(quote_pool);
    destroy_2!(usdc_price, usdt_price);
    return_shared_2!(mm, pool);
    cleanup_margin_test(registry, admin_cap, maintainer_cap, clock, scenario);
}
