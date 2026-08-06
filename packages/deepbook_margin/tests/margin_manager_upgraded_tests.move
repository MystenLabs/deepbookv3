// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Behavioural coverage for `margin_manager_upgraded`.
///
/// Pyth's upgraded Core is a separately published package, so its `PriceInfoObject` is a distinct
/// Move type and no legacy test reaches these entrypoints. Each test drives the same
/// flow as its legacy twin through the upgraded feed, so a wrong `_core` target, a swapped
/// base/quote argument, or a downgraded reader fails here rather than merely
/// compiling.
#[test_only]
module deepbook_margin::margin_manager_upgraded_tests;

use deepbook::{constants, order_info::OrderInfo, pool::Pool, registry::Registry};
use deepbook_margin::{
    margin_constants,
    margin_manager::{Self, MarginManager},
    margin_manager_upgraded,
    margin_pool::MarginPool,
    margin_registry::MarginRegistry,
    test_constants::{Self, USDC, BTC, btc_multiplier},
    test_helpers::{
        cleanup_margin_test,
        mint_coin,
        build_demo_usdc_price_info_object_upgraded,
        build_btc_price_info_object_upgraded,
        build_wide_conf_btc_price_info_object_upgraded,
        build_stale_btc_price_info_object_upgraded,
        build_stale_usdc_price_info_object_upgraded,
        setup_btc_usd_deepbook_margin,
        return_shared_2,
        destroy_2,
    },
    tpsl
};
use sui::test_scenario::{Self as test, return_shared};

/// Deposits USDC collateral through the upgraded entrypoint and asserts it landed.
#[test]
fun deposit_upgraded_credits_collateral() {
    let (
        mut scenario,
        clock,
        admin_cap,
        maintainer_cap,
        _btc_pool_id,
        _usdc_pool_id,
        _pool_id,
        registry_id,
    ) = setup_btc_usd_deepbook_margin();

    let btc_price = build_btc_price_info_object_upgraded(&mut scenario, 100000, &clock);
    let usdc_price = build_demo_usdc_price_info_object_upgraded(&mut scenario, &clock);

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

    margin_manager_upgraded::deposit<BTC, USDC, USDC>(
        &mut mm,
        &registry,
        &btc_price,
        &usdc_price,
        mint_coin<USDC>(100_000 * test_constants::usdc_multiplier(), scenario.ctx()),
        &clock,
        scenario.ctx(),
    );

    assert!(mm.quote_balance() == 100_000 * test_constants::usdc_multiplier());

    return_shared_2!(mm, pool);
    destroy_2!(btc_price, usdc_price);
    cleanup_margin_test(registry, admin_cap, maintainer_cap, clock, scenario);
}

/// Borrows base through the upgraded entrypoint, then reads the position back through the
/// upgraded `risk_ratio`, `manager_state` and `manager_states` views.
#[test]
fun borrow_base_upgraded_and_upgraded_views_agree() {
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

    let btc_price = build_btc_price_info_object_upgraded(&mut scenario, 100000, &clock);
    let usdc_price = build_demo_usdc_price_info_object_upgraded(&mut scenario, &clock);

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
    let mut btc_pool = scenario.take_shared_by_id<MarginPool<BTC>>(btc_pool_id);
    let usdc_pool = scenario.take_shared_by_id<MarginPool<USDC>>(usdc_pool_id);

    margin_manager_upgraded::deposit<BTC, USDC, USDC>(
        &mut mm,
        &registry,
        &btc_price,
        &usdc_price,
        mint_coin<USDC>(100_000 * test_constants::usdc_multiplier(), scenario.ctx()),
        &clock,
        scenario.ctx(),
    );

    margin_manager_upgraded::borrow_base<BTC, USDC>(
        &mut mm,
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

    // Upgraded views must return a real ratio, not the debt-free MAX short-circuit, and it
    // must be the *right* ratio: $100k USDC collateral plus the 1 BTC drawn at $100k
    // is $200k of assets against $100k of debt, exactly 2.0. A range assertion would
    // sit still while the two feeds were transposed; this does not.
    let ratio = margin_manager_upgraded::risk_ratio<BTC, USDC>(
        &mm,
        &registry,
        &btc_price,
        &usdc_price,
        &pool,
        &btc_pool,
        &usdc_pool,
        &clock,
    );
    assert!(ratio == 2_000_000_000);

    let ratio_unsafe = margin_manager_upgraded::risk_ratio_unsafe<BTC, USDC>(
        &mm,
        &registry,
        &btc_price,
        &usdc_price,
        &pool,
        &btc_pool,
        &usdc_pool,
        &clock,
    );
    assert!(ratio_unsafe == ratio);

    let (
        _,
        _,
        state_ratio,
        _,
        _,
        _,
        _,
        _,
        _,
        _,
        _,
        _,
        _,
        _,
    ) = margin_manager_upgraded::manager_state<BTC, USDC>(
        &mm,
        &registry,
        &btc_price,
        &usdc_price,
        &pool,
        &btc_pool,
        &usdc_pool,
        &clock,
    );
    assert!(state_ratio == ratio);

    // `MarginManager` has no `drop`, so the batch input is built and destroyed
    // explicitly. An empty batch still exercises the delegation into the shared core.
    let managers = vector<MarginManager<BTC, USDC>>[];
    let (ids, _, ratios, _, _, _, _, _, _, _, _, _, _, _) = margin_manager_upgraded::manager_states<
        BTC,
        USDC,
    >(
        &managers,
        &registry,
        &btc_price,
        &usdc_price,
        &pool,
        &btc_pool,
        &usdc_pool,
        &clock,
    );
    assert!(ids.is_empty() && ratios.is_empty());
    managers.destroy_empty();

    test::return_shared(btc_pool);
    test::return_shared(usdc_pool);
    return_shared_2!(mm, pool);
    destroy_2!(btc_price, usdc_price);
    cleanup_margin_test(registry, admin_cap, maintainer_cap, clock, scenario);
}

/// A debt-free manager must be able to withdraw with a stale upgraded feed: the risk check
/// does not run, so no price is needed. Pins the lazy-read fix on the upgraded path.
#[test]
fun withdraw_upgraded_no_debt_tolerates_stale_feed() {
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

    let btc_price = build_btc_price_info_object_upgraded(&mut scenario, 100000, &clock);
    let usdc_price = build_demo_usdc_price_info_object_upgraded(&mut scenario, &clock);

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

    margin_manager_upgraded::deposit<BTC, USDC, USDC>(
        &mut mm,
        &registry,
        &btc_price,
        &usdc_price,
        mint_coin<USDC>(100_000 * test_constants::usdc_multiplier(), scenario.ctx()),
        &clock,
        scenario.ctx(),
    );

    // Both feeds genuinely beyond max_age_secs; no debt, so neither is read. A fresh
    // second leg here would let that leg's read be hoisted back out unnoticed.
    let stale_btc = build_stale_btc_price_info_object_upgraded(&mut scenario, 100000, 600, &clock);
    let stale_usdc = build_stale_usdc_price_info_object_upgraded(&mut scenario, 600, &clock);

    let coin = margin_manager_upgraded::withdraw<BTC, USDC, USDC>(
        &mut mm,
        &registry,
        &btc_pool,
        &usdc_pool,
        &stale_btc,
        &stale_usdc,
        &pool,
        1_000 * test_constants::usdc_multiplier(),
        &clock,
        scenario.ctx(),
    );
    assert!(coin.value() == 1_000 * test_constants::usdc_multiplier());

    sui::coin::burn_for_testing(coin);
    test::return_shared(btc_pool);
    test::return_shared(usdc_pool);
    return_shared_2!(mm, pool);
    destroy_2!(btc_price, usdc_price);
    destroy_2!(stale_btc, stale_usdc);
    cleanup_margin_test(registry, admin_cap, maintainer_cap, clock, scenario);
}

/// A debt-free manager's upgraded `risk_ratio` view returns MAX without touching the feed.
#[test]
fun risk_ratio_upgraded_no_debt_returns_max_with_stale_feed() {
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

    let stale_btc = build_stale_btc_price_info_object_upgraded(&mut scenario, 100000, 600, &clock);
    let usdc_price = build_demo_usdc_price_info_object_upgraded(&mut scenario, &clock);

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

    let ratio = margin_manager_upgraded::risk_ratio<BTC, USDC>(
        &mm,
        &registry,
        &stale_btc,
        &usdc_price,
        &pool,
        &btc_pool,
        &usdc_pool,
        &clock,
    );
    assert!(ratio == margin_constants::max_risk_ratio());

    let ratio_unsafe = margin_manager_upgraded::risk_ratio_unsafe<BTC, USDC>(
        &mm,
        &registry,
        &stale_btc,
        &usdc_price,
        &pool,
        &btc_pool,
        &usdc_pool,
        &clock,
    );
    assert!(ratio_unsafe == margin_constants::max_risk_ratio());

    test::return_shared(btc_pool);
    test::return_shared(usdc_pool);
    return_shared_2!(mm, pool);
    destroy_2!(stale_btc, usdc_price);
    cleanup_margin_test(registry, admin_cap, maintainer_cap, clock, scenario);
}

/// Borrows quote through the upgraded entrypoint. Mirrors `borrow_base_upgraded`, on the other
/// side of the pair, so a base/quote transposition in either wrapper is caught.
#[test]
fun borrow_quote_upgraded_takes_a_loan() {
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

    let btc_price = build_btc_price_info_object_upgraded(&mut scenario, 100000, &clock);
    let usdc_price = build_demo_usdc_price_info_object_upgraded(&mut scenario, &clock);

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

    margin_manager_upgraded::deposit<BTC, USDC, USDC>(
        &mut mm,
        &registry,
        &btc_price,
        &usdc_price,
        mint_coin<USDC>(100_000 * test_constants::usdc_multiplier(), scenario.ctx()),
        &clock,
        scenario.ctx(),
    );

    margin_manager_upgraded::borrow_quote<BTC, USDC>(
        &mut mm,
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

    test::return_shared(usdc_pool);
    return_shared_2!(mm, pool);
    destroy_2!(btc_price, usdc_price);
    cleanup_margin_test(registry, admin_cap, maintainer_cap, clock, scenario);
}

/// A healthy manager cannot be liquidated. Asserts the upgraded `liquidate` reaches the
/// shared core's solvency gate rather than some other path.
#[test, expected_failure(abort_code = deepbook_margin::margin_manager::ECannotLiquidate)]
fun liquidate_upgraded_rejects_a_healthy_manager() {
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

    let btc_price = build_btc_price_info_object_upgraded(&mut scenario, 100000, &clock);
    let usdc_price = build_demo_usdc_price_info_object_upgraded(&mut scenario, &clock);

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

    margin_manager_upgraded::deposit<BTC, USDC, USDC>(
        &mut mm,
        &registry,
        &btc_price,
        &usdc_price,
        mint_coin<USDC>(100_000 * test_constants::usdc_multiplier(), scenario.ctx()),
        &clock,
        scenario.ctx(),
    );
    margin_manager_upgraded::borrow_quote<BTC, USDC>(
        &mut mm,
        &registry,
        &mut usdc_pool,
        &btc_price,
        &usdc_price,
        &pool,
        10_000 * test_constants::usdc_multiplier(),
        &clock,
        scenario.ctx(),
    );

    let (b, q, r) = margin_manager_upgraded::liquidate<BTC, USDC, USDC>(
        &mut mm,
        &registry,
        &btc_price,
        &usdc_price,
        &mut usdc_pool,
        &mut pool,
        mint_coin<USDC>(1_000 * test_constants::usdc_multiplier(), scenario.ctx()),
        &clock,
        scenario.ctx(),
    );

    sui::coin::burn_for_testing(b);
    sui::coin::burn_for_testing(q);
    sui::coin::burn_for_testing(r);
    test::return_shared(usdc_pool);
    return_shared_2!(mm, pool);
    destroy_2!(btc_price, usdc_price);
    cleanup_margin_test(registry, admin_cap, maintainer_cap, clock, scenario);
}

/// With no conditional orders registered, both upgraded executors return an empty batch.
/// Exercises the delegation into the shared cores for v2 and v3.
#[test]
fun execute_conditional_orders_upgraded_with_no_orders_returns_empty() {
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

    let btc_price = build_btc_price_info_object_upgraded(&mut scenario, 100000, &clock);
    let usdc_price = build_demo_usdc_price_info_object_upgraded(&mut scenario, &clock);

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
    let mut usdc_pool = scenario.take_shared_by_id<MarginPool<USDC>>(usdc_pool_id);

    let v2: vector<OrderInfo> = margin_manager_upgraded::execute_conditional_orders_v2<BTC, USDC>(
        &mut mm,
        &mut pool,
        &btc_pool,
        &usdc_pool,
        &btc_price,
        &usdc_price,
        &registry,
        10,
        &clock,
        scenario.ctx(),
    );
    assert!(v2.is_empty());

    let v3: vector<OrderInfo> = margin_manager_upgraded::execute_conditional_orders_v3<BTC, USDC>(
        &mut mm,
        &mut pool,
        &mut btc_pool,
        &mut usdc_pool,
        &btc_price,
        &usdc_price,
        &registry,
        10,
        &clock,
        scenario.ctx(),
    );
    assert!(v3.is_empty());

    test::return_shared(btc_pool);
    test::return_shared(usdc_pool);
    return_shared_2!(mm, pool);
    destroy_2!(btc_price, usdc_price);
    cleanup_margin_test(registry, admin_cap, maintainer_cap, clock, scenario);
}

/// Registers a conditional order through the upgraded entrypoint and reads it back.
#[test]
fun add_conditional_order_upgraded_registers_the_order() {
    let (
        mut scenario,
        clock,
        admin_cap,
        maintainer_cap,
        _btc_pool_id,
        _usdc_pool_id,
        _pool_id,
        registry_id,
    ) = setup_btc_usd_deepbook_margin();

    let btc_price = build_btc_price_info_object_upgraded(&mut scenario, 100000, &clock);
    let usdc_price = build_demo_usdc_price_info_object_upgraded(&mut scenario, &clock);

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

    let condition = tpsl::new_condition(true, 90_000_000_000);
    let pending_order = tpsl::new_pending_limit_order(
        1,
        constants::no_restriction(),
        constants::self_matching_allowed(),
        100_000_000_000,
        1 * btc_multiplier(),
        false,
        false,
        constants::max_u64(),
    );

    margin_manager_upgraded::add_conditional_order<BTC, USDC>(
        &mut mm,
        &pool,
        &btc_price,
        &usdc_price,
        &registry,
        1,
        condition,
        pending_order,
        &clock,
        scenario.ctx(),
    );

    assert!(mm.conditional_order_ids().length() == 1);

    return_shared_2!(mm, pool);
    destroy_2!(btc_price, usdc_price);
    cleanup_margin_test(registry, admin_cap, maintainer_cap, clock, scenario);
}

/// `deposit` prices the collateral event through the *validated* reader, exactly as
/// the legacy entry does. Depositing base with a stale base feed must therefore abort.
///
/// This is the pin for a regression that already happened once: swapping this reader
/// for `read_price_upgraded_unsafe` silently drops staleness, feed-id and EWMA enforcement
/// from every deposit, and without this test nothing in the suite notices.
#[test, expected_failure(abort_code = pyth_upgraded::pyth::E_STALE_PRICE_UPDATE)]
fun deposit_upgraded_rejects_stale_feed() {
    let (
        mut scenario,
        clock,
        admin_cap,
        maintainer_cap,
        _btc_pool_id,
        _usdc_pool_id,
        _pool_id,
        registry_id,
    ) = setup_btc_usd_deepbook_margin();

    let btc_price = build_btc_price_info_object_upgraded(&mut scenario, 100000, &clock);
    let usdc_price = build_demo_usdc_price_info_object_upgraded(&mut scenario, &clock);

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

    let stale_btc = build_stale_btc_price_info_object_upgraded(&mut scenario, 100000, 600, &clock);
    margin_manager_upgraded::deposit<BTC, USDC, BTC>(
        &mut mm,
        &registry,
        &stale_btc,
        &usdc_price,
        mint_coin<BTC>(1 * btc_multiplier(), scenario.ctx()),
        &clock,
        scenario.ctx(),
    );

    return_shared_2!(mm, pool);
    destroy_2!(btc_price, usdc_price);
    std::unit_test::destroy(stale_btc);
    cleanup_margin_test(registry, admin_cap, maintainer_cap, clock, scenario);
}

/// A withdrawal's collateral event is priced through the *unvalidated* reader, whose
/// `PythReading` carries no confidence bound. An arbitrarily wide interval must
/// therefore still emit rather than abort - the bound is a pricing guard, and the
/// event is telemetry. Routing this through the validated reader would break
/// withdrawals whenever a feed widened.
#[test]
fun withdraw_upgraded_with_wide_confidence_still_emits() {
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

    let btc_price = build_btc_price_info_object_upgraded(&mut scenario, 100000, &clock);
    let usdc_price = build_demo_usdc_price_info_object_upgraded(&mut scenario, &clock);

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

    margin_manager_upgraded::deposit<BTC, USDC, USDC>(
        &mut mm,
        &registry,
        &btc_price,
        &usdc_price,
        mint_coin<USDC>(100_000 * test_constants::usdc_multiplier(), scenario.ctx()),
        &clock,
        scenario.ctx(),
    );

    // 50% of the price, far outside any sane `max_conf_bps`.
    let wide_btc = build_wide_conf_btc_price_info_object_upgraded(
        &mut scenario,
        100000,
        50000 * test_constants::pyth_multiplier(),
        &clock,
    );

    let coin = margin_manager_upgraded::withdraw<BTC, USDC, USDC>(
        &mut mm,
        &registry,
        &btc_pool,
        &usdc_pool,
        &wide_btc,
        &usdc_price,
        &pool,
        1_000 * test_constants::usdc_multiplier(),
        &clock,
        scenario.ctx(),
    );
    assert!(coin.value() == 1_000 * test_constants::usdc_multiplier());

    sui::coin::burn_for_testing(coin);
    test::return_shared(btc_pool);
    test::return_shared(usdc_pool);
    return_shared_2!(mm, pool);
    destroy_2!(btc_price, usdc_price);
    std::unit_test::destroy(wide_btc);
    cleanup_margin_test(registry, admin_cap, maintainer_cap, clock, scenario);
}

// === `withdraw` with debt: the solvency gate on the upgraded path ===
// Both shipped upgraded withdraw tests deposit and never borrow, so `withdraw_needs_risk_check`
// is false and the entire risk branch - the gate deciding whether value may leave a
// leveraged manager - never executes. These three run it, either side of the floor.

#[test]
fun withdraw_upgraded_with_debt_succeeds_within_the_ratio() {
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

    let btc_price = build_btc_price_info_object_upgraded(&mut scenario, 100000, &clock);
    let usdc_price = build_demo_usdc_price_info_object_upgraded(&mut scenario, &clock);

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
    let mut btc_pool = scenario.take_shared_by_id<MarginPool<BTC>>(btc_pool_id);
    let usdc_pool = scenario.take_shared_by_id<MarginPool<USDC>>(usdc_pool_id);

    // $100k USDC collateral, then draw 0.5 BTC ($50k): $150k of assets against $50k of
    // debt, a ratio of 3.0. `min_withdraw_risk_ratio` is 2.0, so there is real room
    // both above and below it - drawing a full 1 BTC would sit exactly on the floor and
    // every withdrawal, however small, would abort.
    margin_manager_upgraded::deposit<BTC, USDC, USDC>(
        &mut mm,
        &registry,
        &btc_price,
        &usdc_price,
        mint_coin<USDC>(100_000 * test_constants::usdc_multiplier(), scenario.ctx()),
        &clock,
        scenario.ctx(),
    );
    margin_manager_upgraded::borrow_base<BTC, USDC>(
        &mut mm,
        &registry,
        &mut btc_pool,
        &btc_price,
        &usdc_price,
        &pool,
        btc_multiplier() / 2,
        &clock,
        scenario.ctx(),
    );

    let coin = margin_manager_upgraded::withdraw<BTC, USDC, USDC>(
        &mut mm,
        &registry,
        &btc_pool,
        &usdc_pool,
        &btc_price,
        &usdc_price,
        &pool,
        10_000 * test_constants::usdc_multiplier(),
        &clock,
        scenario.ctx(),
    );
    assert!(coin.value() == 10_000 * test_constants::usdc_multiplier());

    // $140k of assets over $50k of debt.
    let ratio = margin_manager_upgraded::risk_ratio<BTC, USDC>(
        &mm,
        &registry,
        &btc_price,
        &usdc_price,
        &pool,
        &btc_pool,
        &usdc_pool,
        &clock,
    );
    assert!(ratio == 2_800_000_000);

    sui::coin::burn_for_testing(coin);
    test::return_shared(btc_pool);
    test::return_shared(usdc_pool);
    return_shared_2!(mm, pool);
    destroy_2!(btc_price, usdc_price);
    cleanup_margin_test(registry, admin_cap, maintainer_cap, clock, scenario);
}

#[test, expected_failure(abort_code = deepbook_margin::margin_manager::EWithdrawRiskRatioExceeded)]
fun withdraw_upgraded_with_debt_rejects_an_unsafe_withdrawal() {
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

    let btc_price = build_btc_price_info_object_upgraded(&mut scenario, 100000, &clock);
    let usdc_price = build_demo_usdc_price_info_object_upgraded(&mut scenario, &clock);

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
    let mut btc_pool = scenario.take_shared_by_id<MarginPool<BTC>>(btc_pool_id);
    let usdc_pool = scenario.take_shared_by_id<MarginPool<USDC>>(usdc_pool_id);

    // $100k USDC collateral, then draw 0.5 BTC ($50k): $150k of assets against $50k of
    // debt, a ratio of 3.0. `min_withdraw_risk_ratio` is 2.0, so there is real room
    // both above and below it - drawing a full 1 BTC would sit exactly on the floor and
    // every withdrawal, however small, would abort.
    margin_manager_upgraded::deposit<BTC, USDC, USDC>(
        &mut mm,
        &registry,
        &btc_price,
        &usdc_price,
        mint_coin<USDC>(100_000 * test_constants::usdc_multiplier(), scenario.ctx()),
        &clock,
        scenario.ctx(),
    );
    margin_manager_upgraded::borrow_base<BTC, USDC>(
        &mut mm,
        &registry,
        &mut btc_pool,
        &btc_price,
        &usdc_price,
        &pool,
        btc_multiplier() / 2,
        &clock,
        scenario.ctx(),
    );

    // Would leave $90k of assets against $50k of debt - a ratio of 1.8, under the 2.0 floor.
    let coin = margin_manager_upgraded::withdraw<BTC, USDC, USDC>(
        &mut mm,
        &registry,
        &btc_pool,
        &usdc_pool,
        &btc_price,
        &usdc_price,
        &pool,
        60_000 * test_constants::usdc_multiplier(),
        &clock,
        scenario.ctx(),
    );

    sui::coin::burn_for_testing(coin);
    test::return_shared(btc_pool);
    test::return_shared(usdc_pool);
    return_shared_2!(mm, pool);
    destroy_2!(btc_price, usdc_price);
    cleanup_margin_test(registry, admin_cap, maintainer_cap, clock, scenario);
}

#[test, expected_failure(abort_code = pyth_upgraded::pyth::E_STALE_PRICE_UPDATE)]
fun withdraw_upgraded_with_debt_rejects_stale_feed() {
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

    let btc_price = build_btc_price_info_object_upgraded(&mut scenario, 100000, &clock);
    let usdc_price = build_demo_usdc_price_info_object_upgraded(&mut scenario, &clock);

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
    let mut btc_pool = scenario.take_shared_by_id<MarginPool<BTC>>(btc_pool_id);
    let usdc_pool = scenario.take_shared_by_id<MarginPool<USDC>>(usdc_pool_id);

    // $100k USDC collateral, then draw 0.5 BTC ($50k): $150k of assets against $50k of
    // debt, a ratio of 3.0. `min_withdraw_risk_ratio` is 2.0, so there is real room
    // both above and below it - drawing a full 1 BTC would sit exactly on the floor and
    // every withdrawal, however small, would abort.
    margin_manager_upgraded::deposit<BTC, USDC, USDC>(
        &mut mm,
        &registry,
        &btc_price,
        &usdc_price,
        mint_coin<USDC>(100_000 * test_constants::usdc_multiplier(), scenario.ctx()),
        &clock,
        scenario.ctx(),
    );
    margin_manager_upgraded::borrow_base<BTC, USDC>(
        &mut mm,
        &registry,
        &mut btc_pool,
        &btc_price,
        &usdc_price,
        &pool,
        btc_multiplier() / 2,
        &clock,
        scenario.ctx(),
    );

    let stale_btc = build_stale_btc_price_info_object_upgraded(&mut scenario, 100000, 600, &clock);
    let coin = margin_manager_upgraded::withdraw<BTC, USDC, USDC>(
        &mut mm,
        &registry,
        &btc_pool,
        &usdc_pool,
        &stale_btc,
        &usdc_price,
        &pool,
        10_000 * test_constants::usdc_multiplier(),
        &clock,
        scenario.ctx(),
    );

    sui::coin::burn_for_testing(coin);
    std::unit_test::destroy(stale_btc);
    test::return_shared(btc_pool);
    test::return_shared(usdc_pool);
    return_shared_2!(mm, pool);
    destroy_2!(btc_price, usdc_price);
    cleanup_margin_test(registry, admin_cap, maintainer_cap, clock, scenario);
}

// === Reader-choice pins for the remaining upgraded entrypoints ===
// Each of these reads the oracle unconditionally through the *validated* reader. With
// no test standing on that choice, swapping in `read_price_upgraded_unsafe` silently drops
// staleness, EWMA-divergence and confidence enforcement and leaves CI green - on
// `liquidate`, that is enough to seize collateral at an arbitrarily old price. One
// stale-feed rejection per entrypoint closes it.

#[test, expected_failure(abort_code = pyth_upgraded::pyth::E_STALE_PRICE_UPDATE)]
fun risk_ratio_upgraded_with_debt_rejects_stale_feed() {
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

    let btc_price = build_btc_price_info_object_upgraded(&mut scenario, 100000, &clock);
    let usdc_price = build_demo_usdc_price_info_object_upgraded(&mut scenario, &clock);

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
    let mut usdc_pool = scenario.take_shared_by_id<MarginPool<USDC>>(usdc_pool_id);

    margin_manager_upgraded::deposit<BTC, USDC, USDC>(
        &mut mm,
        &registry,
        &btc_price,
        &usdc_price,
        mint_coin<USDC>(100_000 * test_constants::usdc_multiplier(), scenario.ctx()),
        &clock,
        scenario.ctx(),
    );
    margin_manager_upgraded::borrow_base<BTC, USDC>(
        &mut mm,
        &registry,
        &mut btc_pool,
        &btc_price,
        &usdc_price,
        &pool,
        btc_multiplier() / 2,
        &clock,
        scenario.ctx(),
    );

    let stale_btc = build_stale_btc_price_info_object_upgraded(&mut scenario, 100000, 600, &clock);

    let _ = margin_manager_upgraded::risk_ratio<BTC, USDC>(
        &mm,
        &registry,
        &stale_btc,
        &usdc_price,
        &pool,
        &btc_pool,
        &usdc_pool,
        &clock,
    );

    test::return_shared(btc_pool);
    test::return_shared(usdc_pool);
    return_shared_2!(mm, pool);
    destroy_2!(btc_price, usdc_price);
    std::unit_test::destroy(stale_btc);
    cleanup_margin_test(registry, admin_cap, maintainer_cap, clock, scenario);
}

#[test, expected_failure(abort_code = pyth_upgraded::pyth::E_STALE_PRICE_UPDATE)]
fun borrow_base_upgraded_rejects_stale_feed() {
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

    let btc_price = build_btc_price_info_object_upgraded(&mut scenario, 100000, &clock);
    let usdc_price = build_demo_usdc_price_info_object_upgraded(&mut scenario, &clock);

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
    let mut usdc_pool = scenario.take_shared_by_id<MarginPool<USDC>>(usdc_pool_id);

    margin_manager_upgraded::deposit<BTC, USDC, USDC>(
        &mut mm,
        &registry,
        &btc_price,
        &usdc_price,
        mint_coin<USDC>(100_000 * test_constants::usdc_multiplier(), scenario.ctx()),
        &clock,
        scenario.ctx(),
    );
    margin_manager_upgraded::borrow_base<BTC, USDC>(
        &mut mm,
        &registry,
        &mut btc_pool,
        &btc_price,
        &usdc_price,
        &pool,
        btc_multiplier() / 2,
        &clock,
        scenario.ctx(),
    );

    let stale_btc = build_stale_btc_price_info_object_upgraded(&mut scenario, 100000, 600, &clock);

    margin_manager_upgraded::borrow_base<BTC, USDC>(
        &mut mm,
        &registry,
        &mut btc_pool,
        &stale_btc,
        &usdc_price,
        &pool,
        btc_multiplier() / 10,
        &clock,
        scenario.ctx(),
    );

    test::return_shared(btc_pool);
    test::return_shared(usdc_pool);
    return_shared_2!(mm, pool);
    destroy_2!(btc_price, usdc_price);
    std::unit_test::destroy(stale_btc);
    cleanup_margin_test(registry, admin_cap, maintainer_cap, clock, scenario);
}

#[test, expected_failure(abort_code = pyth_upgraded::pyth::E_STALE_PRICE_UPDATE)]
fun borrow_quote_upgraded_rejects_stale_feed() {
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

    let btc_price = build_btc_price_info_object_upgraded(&mut scenario, 100000, &clock);
    let usdc_price = build_demo_usdc_price_info_object_upgraded(&mut scenario, &clock);

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
    let mut usdc_pool = scenario.take_shared_by_id<MarginPool<USDC>>(usdc_pool_id);

    margin_manager_upgraded::deposit<BTC, USDC, USDC>(
        &mut mm,
        &registry,
        &btc_price,
        &usdc_price,
        mint_coin<USDC>(100_000 * test_constants::usdc_multiplier(), scenario.ctx()),
        &clock,
        scenario.ctx(),
    );
    margin_manager_upgraded::borrow_base<BTC, USDC>(
        &mut mm,
        &registry,
        &mut btc_pool,
        &btc_price,
        &usdc_price,
        &pool,
        btc_multiplier() / 2,
        &clock,
        scenario.ctx(),
    );

    let stale_btc = build_stale_btc_price_info_object_upgraded(&mut scenario, 100000, 600, &clock);

    margin_manager_upgraded::borrow_quote<BTC, USDC>(
        &mut mm,
        &registry,
        &mut usdc_pool,
        &stale_btc,
        &usdc_price,
        &pool,
        1_000 * test_constants::usdc_multiplier(),
        &clock,
        scenario.ctx(),
    );

    test::return_shared(btc_pool);
    test::return_shared(usdc_pool);
    return_shared_2!(mm, pool);
    destroy_2!(btc_price, usdc_price);
    std::unit_test::destroy(stale_btc);
    cleanup_margin_test(registry, admin_cap, maintainer_cap, clock, scenario);
}

#[test, expected_failure(abort_code = pyth_upgraded::pyth::E_STALE_PRICE_UPDATE)]
fun liquidate_upgraded_rejects_stale_feed() {
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

    let btc_price = build_btc_price_info_object_upgraded(&mut scenario, 100000, &clock);
    let usdc_price = build_demo_usdc_price_info_object_upgraded(&mut scenario, &clock);

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
    let mut usdc_pool = scenario.take_shared_by_id<MarginPool<USDC>>(usdc_pool_id);

    margin_manager_upgraded::deposit<BTC, USDC, USDC>(
        &mut mm,
        &registry,
        &btc_price,
        &usdc_price,
        mint_coin<USDC>(100_000 * test_constants::usdc_multiplier(), scenario.ctx()),
        &clock,
        scenario.ctx(),
    );
    margin_manager_upgraded::borrow_base<BTC, USDC>(
        &mut mm,
        &registry,
        &mut btc_pool,
        &btc_price,
        &usdc_price,
        &pool,
        btc_multiplier() / 2,
        &clock,
        scenario.ctx(),
    );

    let stale_btc = build_stale_btc_price_info_object_upgraded(&mut scenario, 100000, 600, &clock);

    // The read happens before the health check, so a healthy manager still aborts on
    // staleness rather than on `ECannotLiquidate`.
    let (b, q, r) = margin_manager_upgraded::liquidate<BTC, USDC, USDC>(
        &mut mm,
        &registry,
        &stale_btc,
        &usdc_price,
        &mut usdc_pool,
        &mut pool,
        mint_coin<USDC>(1_000 * test_constants::usdc_multiplier(), scenario.ctx()),
        &clock,
        scenario.ctx(),
    );
    sui::coin::burn_for_testing(b);
    sui::coin::burn_for_testing(q);
    sui::coin::burn_for_testing(r);

    test::return_shared(btc_pool);
    test::return_shared(usdc_pool);
    return_shared_2!(mm, pool);
    destroy_2!(btc_price, usdc_price);
    std::unit_test::destroy(stale_btc);
    cleanup_margin_test(registry, admin_cap, maintainer_cap, clock, scenario);
}

#[test, expected_failure(abort_code = pyth_upgraded::pyth::E_STALE_PRICE_UPDATE)]
fun execute_conditional_orders_v2_upgraded_rejects_stale_feed() {
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

    let btc_price = build_btc_price_info_object_upgraded(&mut scenario, 100000, &clock);
    let usdc_price = build_demo_usdc_price_info_object_upgraded(&mut scenario, &clock);

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
    let mut usdc_pool = scenario.take_shared_by_id<MarginPool<USDC>>(usdc_pool_id);

    margin_manager_upgraded::deposit<BTC, USDC, USDC>(
        &mut mm,
        &registry,
        &btc_price,
        &usdc_price,
        mint_coin<USDC>(100_000 * test_constants::usdc_multiplier(), scenario.ctx()),
        &clock,
        scenario.ctx(),
    );
    margin_manager_upgraded::borrow_base<BTC, USDC>(
        &mut mm,
        &registry,
        &mut btc_pool,
        &btc_price,
        &usdc_price,
        &pool,
        btc_multiplier() / 2,
        &clock,
        scenario.ctx(),
    );

    let stale_btc = build_stale_btc_price_info_object_upgraded(&mut scenario, 100000, 600, &clock);

    let v2: vector<OrderInfo> = margin_manager_upgraded::execute_conditional_orders_v2<BTC, USDC>(
        &mut mm,
        &mut pool,
        &btc_pool,
        &usdc_pool,
        &stale_btc,
        &usdc_price,
        &registry,
        10,
        &clock,
        scenario.ctx(),
    );
    assert!(v2.is_empty());

    test::return_shared(btc_pool);
    test::return_shared(usdc_pool);
    return_shared_2!(mm, pool);
    destroy_2!(btc_price, usdc_price);
    std::unit_test::destroy(stale_btc);
    cleanup_margin_test(registry, admin_cap, maintainer_cap, clock, scenario);
}

#[test, expected_failure(abort_code = pyth_upgraded::pyth::E_STALE_PRICE_UPDATE)]
fun execute_conditional_orders_v3_upgraded_rejects_stale_feed() {
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

    let btc_price = build_btc_price_info_object_upgraded(&mut scenario, 100000, &clock);
    let usdc_price = build_demo_usdc_price_info_object_upgraded(&mut scenario, &clock);

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
    let mut usdc_pool = scenario.take_shared_by_id<MarginPool<USDC>>(usdc_pool_id);

    margin_manager_upgraded::deposit<BTC, USDC, USDC>(
        &mut mm,
        &registry,
        &btc_price,
        &usdc_price,
        mint_coin<USDC>(100_000 * test_constants::usdc_multiplier(), scenario.ctx()),
        &clock,
        scenario.ctx(),
    );
    margin_manager_upgraded::borrow_base<BTC, USDC>(
        &mut mm,
        &registry,
        &mut btc_pool,
        &btc_price,
        &usdc_price,
        &pool,
        btc_multiplier() / 2,
        &clock,
        scenario.ctx(),
    );

    let stale_btc = build_stale_btc_price_info_object_upgraded(&mut scenario, 100000, 600, &clock);

    let v3: vector<OrderInfo> = margin_manager_upgraded::execute_conditional_orders_v3<BTC, USDC>(
        &mut mm,
        &mut pool,
        &mut btc_pool,
        &mut usdc_pool,
        &stale_btc,
        &usdc_price,
        &registry,
        10,
        &clock,
        scenario.ctx(),
    );
    assert!(v3.is_empty());

    test::return_shared(btc_pool);
    test::return_shared(usdc_pool);
    return_shared_2!(mm, pool);
    destroy_2!(btc_price, usdc_price);
    std::unit_test::destroy(stale_btc);
    cleanup_margin_test(registry, admin_cap, maintainer_cap, clock, scenario);
}

#[test, expected_failure(abort_code = pyth_upgraded::pyth::E_STALE_PRICE_UPDATE)]
fun add_conditional_order_upgraded_rejects_stale_feed() {
    let (
        mut scenario,
        clock,
        admin_cap,
        maintainer_cap,
        _btc_pool_id,
        _usdc_pool_id,
        _pool_id,
        registry_id,
    ) = setup_btc_usd_deepbook_margin();

    let btc_price = build_btc_price_info_object_upgraded(&mut scenario, 100000, &clock);
    let usdc_price = build_demo_usdc_price_info_object_upgraded(&mut scenario, &clock);

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

    let condition = tpsl::new_condition(true, 90_000_000_000);
    let pending_order = tpsl::new_pending_limit_order(
        1,
        constants::no_restriction(),
        constants::self_matching_allowed(),
        100_000_000_000,
        1 * btc_multiplier(),
        false,
        false,
        constants::max_u64(),
    );

    let stale_btc = build_stale_btc_price_info_object_upgraded(&mut scenario, 100000, 600, &clock);
    margin_manager_upgraded::add_conditional_order<BTC, USDC>(
        &mut mm,
        &pool,
        &stale_btc,
        &usdc_price,
        &registry,
        1,
        condition,
        pending_order,
        &clock,
        scenario.ctx(),
    );

    std::unit_test::destroy(stale_btc);
    return_shared_2!(mm, pool);
    destroy_2!(btc_price, usdc_price);
    cleanup_margin_test(registry, admin_cap, maintainer_cap, clock, scenario);
}
