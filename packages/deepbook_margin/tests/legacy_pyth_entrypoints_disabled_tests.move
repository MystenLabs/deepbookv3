// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Every legacy-Pyth entrypoint aborts.
///
/// The two entrypoint families used to be equally authoritative: `margin_manager` and
/// `pool_proxy` priced off legacy Pyth Core, `margin_manager_upgraded` and
/// `pool_proxy_upgraded` off the upgraded Core, `PythReading` erased which feed produced
/// a price, and both families shared one `_core`. A caller chose per call. The legacy
/// bodies are now `abort EDeprecatedUseUpgradedPyth`.
///
/// One test per retired entry, calling it with a well-formed legacy `PriceInfoObject`.
/// The point of passing a *good* feed is that nothing else can be blamed for the abort:
/// these do not fail on staleness, on a feed id, or on any argument — they fail because
/// the entry no longer prices anything. A test here going green through the entry rather
/// than through the abort means a legacy reader has been wired back in.
///
/// Scenario-level coverage of what the window used to permit lives in
/// `dual_feed_window_tests`; this file is the surface inventory. When a new
/// oracle-taking entry is added to `margin_manager_upgraded` or `pool_proxy_upgraded`,
/// it has no legacy twin and belongs in neither.
#[test_only]
module deepbook_margin::legacy_pyth_entrypoints_disabled_tests;

use deepbook::{constants, pool::Pool, registry::Registry};
use deepbook_margin::{
    margin_manager::{Self, MarginManager},
    margin_pool::MarginPool,
    margin_registry::{MarginRegistry, MarginAdminCap, MaintainerCap},
    pool_proxy,
    test_constants::{Self, USDC, USDT},
    test_helpers::{
        setup_pool_proxy_test_env,
        build_demo_usdc_price_info_object,
        build_demo_usdt_price_info_object,
        mint_coin,
    },
    tpsl
};
use pyth::price_info::PriceInfoObject;
use sui::{clock::Clock, test_scenario::{Self as test, return_shared}};

/// A registered USDC/USDT margin manager plus the ids needed to re-take the shared
/// objects each entry wants. No debt and no orders: every retired body aborts on its
/// first instruction, so manager state cannot change the outcome.
fun env(): (test::Scenario, Clock, MarginAdminCap, MaintainerCap, ID, ID, ID) {
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

    (scenario, clock, admin_cap, maintainer_cap, base_pool_id, quote_pool_id, pool_id)
}

/// Fresh, correctly-configured legacy feeds for the two assets.
fun legacy_feeds(scenario: &mut test::Scenario, clock: &Clock): (PriceInfoObject, PriceInfoObject) {
    let base = build_demo_usdc_price_info_object(scenario, clock);
    let quote = build_demo_usdt_price_info_object(scenario, clock);

    (base, quote)
}

// === margin_manager ===

#[test, expected_failure(abort_code = margin_manager::EDeprecatedUseUpgradedPyth)]
fun legacy_add_conditional_order_aborts() {
    let (mut scenario, clock, _admin_cap, _maintainer_cap, _b, _q, pool_id) = env();

    scenario.next_tx(test_constants::user1());
    let mut mm = scenario.take_shared<MarginManager<USDC, USDT>>();
    let pool = scenario.take_shared_by_id<Pool<USDC, USDT>>(pool_id);
    let registry = scenario.take_shared<MarginRegistry>();
    let (base, quote) = legacy_feeds(&mut scenario, &clock);

    margin_manager::add_conditional_order<USDC, USDT>(
        &mut mm,
        &pool,
        &base,
        &quote,
        &registry,
        1,
        tpsl::new_condition(true, 900_000),
        tpsl::new_pending_market_order(
            1,
            constants::self_matching_allowed(),
            1_000_000,
            false,
            false,
        ),
        &clock,
        scenario.ctx(),
    );

    abort 999
}

#[test, expected_failure(abort_code = margin_manager::EDeprecatedUseUpgradedPyth)]
fun legacy_execute_conditional_orders_v2_aborts() {
    let (
        mut scenario,
        clock,
        _admin_cap,
        _maintainer_cap,
        base_pool_id,
        quote_pool_id,
        pool_id,
    ) = env();

    scenario.next_tx(test_constants::liquidator());
    let mut mm = scenario.take_shared<MarginManager<USDC, USDT>>();
    let mut pool = scenario.take_shared_by_id<Pool<USDC, USDT>>(pool_id);
    let registry = scenario.take_shared<MarginRegistry>();
    let base_pool = scenario.take_shared_by_id<MarginPool<USDC>>(base_pool_id);
    let quote_pool = scenario.take_shared_by_id<MarginPool<USDT>>(quote_pool_id);
    let (base, quote) = legacy_feeds(&mut scenario, &clock);

    let _ = margin_manager::execute_conditional_orders_v2<USDC, USDT>(
        &mut mm,
        &mut pool,
        &base_pool,
        &quote_pool,
        &base,
        &quote,
        &registry,
        10,
        &clock,
        scenario.ctx(),
    );

    abort 999
}

#[test, expected_failure(abort_code = margin_manager::EDeprecatedUseUpgradedPyth)]
fun legacy_execute_conditional_orders_v3_aborts() {
    let (
        mut scenario,
        clock,
        _admin_cap,
        _maintainer_cap,
        base_pool_id,
        quote_pool_id,
        pool_id,
    ) = env();

    scenario.next_tx(test_constants::liquidator());
    let mut mm = scenario.take_shared<MarginManager<USDC, USDT>>();
    let mut pool = scenario.take_shared_by_id<Pool<USDC, USDT>>(pool_id);
    let registry = scenario.take_shared<MarginRegistry>();
    let mut base_pool = scenario.take_shared_by_id<MarginPool<USDC>>(base_pool_id);
    let mut quote_pool = scenario.take_shared_by_id<MarginPool<USDT>>(quote_pool_id);
    let (base, quote) = legacy_feeds(&mut scenario, &clock);

    let _ = margin_manager::execute_conditional_orders_v3<USDC, USDT>(
        &mut mm,
        &mut pool,
        &mut base_pool,
        &mut quote_pool,
        &base,
        &quote,
        &registry,
        10,
        &clock,
        scenario.ctx(),
    );

    abort 999
}

#[test, expected_failure(abort_code = margin_manager::EDeprecatedUseUpgradedPyth)]
fun legacy_deposit_aborts() {
    let (mut scenario, clock, _admin_cap, _maintainer_cap, _b, _q, _pool_id) = env();

    scenario.next_tx(test_constants::user1());
    let mut mm = scenario.take_shared<MarginManager<USDC, USDT>>();
    let registry = scenario.take_shared<MarginRegistry>();
    let (base, quote) = legacy_feeds(&mut scenario, &clock);

    margin_manager::deposit<USDC, USDT, USDC>(
        &mut mm,
        &registry,
        &base,
        &quote,
        mint_coin<USDC>(1_000 * test_constants::usdc_multiplier(), scenario.ctx()),
        &clock,
        scenario.ctx(),
    );

    abort 999
}

#[test, expected_failure(abort_code = margin_manager::EDeprecatedUseUpgradedPyth)]
fun legacy_withdraw_aborts() {
    let (
        mut scenario,
        clock,
        _admin_cap,
        _maintainer_cap,
        base_pool_id,
        quote_pool_id,
        pool_id,
    ) = env();

    scenario.next_tx(test_constants::user1());
    let mut mm = scenario.take_shared<MarginManager<USDC, USDT>>();
    let pool = scenario.take_shared_by_id<Pool<USDC, USDT>>(pool_id);
    let registry = scenario.take_shared<MarginRegistry>();
    let base_pool = scenario.take_shared_by_id<MarginPool<USDC>>(base_pool_id);
    let quote_pool = scenario.take_shared_by_id<MarginPool<USDT>>(quote_pool_id);
    let (base, quote) = legacy_feeds(&mut scenario, &clock);

    let coin = margin_manager::withdraw<USDC, USDT, USDC>(
        &mut mm,
        &registry,
        &base_pool,
        &quote_pool,
        &base,
        &quote,
        &pool,
        1,
        &clock,
        scenario.ctx(),
    );
    std::unit_test::destroy(coin);

    abort 999
}

#[test, expected_failure(abort_code = margin_manager::EDeprecatedUseUpgradedPyth)]
fun legacy_borrow_base_aborts() {
    let (mut scenario, clock, _admin_cap, _maintainer_cap, base_pool_id, _q, pool_id) = env();

    scenario.next_tx(test_constants::user1());
    let mut mm = scenario.take_shared<MarginManager<USDC, USDT>>();
    let pool = scenario.take_shared_by_id<Pool<USDC, USDT>>(pool_id);
    let registry = scenario.take_shared<MarginRegistry>();
    let mut base_pool = scenario.take_shared_by_id<MarginPool<USDC>>(base_pool_id);
    let (base, quote) = legacy_feeds(&mut scenario, &clock);

    margin_manager::borrow_base<USDC, USDT>(
        &mut mm,
        &registry,
        &mut base_pool,
        &base,
        &quote,
        &pool,
        1_000 * test_constants::usdc_multiplier(),
        &clock,
        scenario.ctx(),
    );

    abort 999
}

#[test, expected_failure(abort_code = margin_manager::EDeprecatedUseUpgradedPyth)]
fun legacy_borrow_quote_aborts() {
    let (mut scenario, clock, _admin_cap, _maintainer_cap, _b, quote_pool_id, pool_id) = env();

    scenario.next_tx(test_constants::user1());
    let mut mm = scenario.take_shared<MarginManager<USDC, USDT>>();
    let pool = scenario.take_shared_by_id<Pool<USDC, USDT>>(pool_id);
    let registry = scenario.take_shared<MarginRegistry>();
    let mut quote_pool = scenario.take_shared_by_id<MarginPool<USDT>>(quote_pool_id);
    let (base, quote) = legacy_feeds(&mut scenario, &clock);

    margin_manager::borrow_quote<USDC, USDT>(
        &mut mm,
        &registry,
        &mut quote_pool,
        &base,
        &quote,
        &pool,
        1_000 * test_constants::usdt_multiplier(),
        &clock,
        scenario.ctx(),
    );

    abort 999
}

#[test, expected_failure(abort_code = margin_manager::EDeprecatedUseUpgradedPyth)]
fun legacy_liquidate_aborts() {
    let (mut scenario, clock, _admin_cap, _maintainer_cap, _b, quote_pool_id, pool_id) = env();

    scenario.next_tx(test_constants::liquidator());
    let mut mm = scenario.take_shared<MarginManager<USDC, USDT>>();
    let mut pool = scenario.take_shared_by_id<Pool<USDC, USDT>>(pool_id);
    let registry = scenario.take_shared<MarginRegistry>();
    let mut quote_pool = scenario.take_shared_by_id<MarginPool<USDT>>(quote_pool_id);
    let (base, quote) = legacy_feeds(&mut scenario, &clock);

    let (base_coin, quote_coin, remaining) = margin_manager::liquidate<USDC, USDT, USDT>(
        &mut mm,
        &registry,
        &base,
        &quote,
        &mut quote_pool,
        &mut pool,
        mint_coin<USDT>(1_000 * test_constants::usdt_multiplier(), scenario.ctx()),
        &clock,
        scenario.ctx(),
    );
    std::unit_test::destroy(base_coin);
    std::unit_test::destroy(quote_coin);
    std::unit_test::destroy(remaining);

    abort 999
}

/// Read-only, but retired with the rest: an off-chain liquidator reading a ratio off
/// one feed while acting on the other is the same divergence, one step removed.
#[test, expected_failure(abort_code = margin_manager::EDeprecatedUseUpgradedPyth)]
fun legacy_risk_ratio_aborts() {
    let (
        mut scenario,
        clock,
        _admin_cap,
        _maintainer_cap,
        base_pool_id,
        quote_pool_id,
        pool_id,
    ) = env();

    scenario.next_tx(test_constants::user1());
    let mm = scenario.take_shared<MarginManager<USDC, USDT>>();
    let pool = scenario.take_shared_by_id<Pool<USDC, USDT>>(pool_id);
    let registry = scenario.take_shared<MarginRegistry>();
    let base_pool = scenario.take_shared_by_id<MarginPool<USDC>>(base_pool_id);
    let quote_pool = scenario.take_shared_by_id<MarginPool<USDT>>(quote_pool_id);
    let (base, quote) = legacy_feeds(&mut scenario, &clock);

    let _ = margin_manager::risk_ratio<USDC, USDT>(
        &mm,
        &registry,
        &base,
        &quote,
        &pool,
        &base_pool,
        &quote_pool,
        &clock,
    );

    abort 999
}

/// The debt-free short-circuit used to return `max_risk_ratio()` before touching a
/// feed. It is gone: a retired entry aborts for every manager, debt or not.
#[test, expected_failure(abort_code = margin_manager::EDeprecatedUseUpgradedPyth)]
fun legacy_risk_ratio_unsafe_aborts() {
    let (
        mut scenario,
        clock,
        _admin_cap,
        _maintainer_cap,
        base_pool_id,
        quote_pool_id,
        pool_id,
    ) = env();

    scenario.next_tx(test_constants::user1());
    let mm = scenario.take_shared<MarginManager<USDC, USDT>>();
    let pool = scenario.take_shared_by_id<Pool<USDC, USDT>>(pool_id);
    let registry = scenario.take_shared<MarginRegistry>();
    let base_pool = scenario.take_shared_by_id<MarginPool<USDC>>(base_pool_id);
    let quote_pool = scenario.take_shared_by_id<MarginPool<USDT>>(quote_pool_id);
    let (base, quote) = legacy_feeds(&mut scenario, &clock);

    let _ = margin_manager::risk_ratio_unsafe<USDC, USDT>(
        &mm,
        &registry,
        &base,
        &quote,
        &pool,
        &base_pool,
        &quote_pool,
        &clock,
    );

    abort 999
}

#[test, expected_failure(abort_code = margin_manager::EDeprecatedUseUpgradedPyth)]
fun legacy_manager_state_aborts() {
    let (
        mut scenario,
        clock,
        _admin_cap,
        _maintainer_cap,
        base_pool_id,
        quote_pool_id,
        pool_id,
    ) = env();

    scenario.next_tx(test_constants::user1());
    let mm = scenario.take_shared<MarginManager<USDC, USDT>>();
    let pool = scenario.take_shared_by_id<Pool<USDC, USDT>>(pool_id);
    let registry = scenario.take_shared<MarginRegistry>();
    let base_pool = scenario.take_shared_by_id<MarginPool<USDC>>(base_pool_id);
    let quote_pool = scenario.take_shared_by_id<MarginPool<USDT>>(quote_pool_id);
    let (base, quote) = legacy_feeds(&mut scenario, &clock);

    margin_manager::manager_state<USDC, USDT>(
        &mm,
        &registry,
        &base,
        &quote,
        &pool,
        &base_pool,
        &quote_pool,
        &clock,
    );

    abort 999
}

/// The batch read is the one the off-chain liquidator actually calls, over tens of
/// thousands of managers. An empty vector still aborts — nothing is read per manager.
#[test, expected_failure(abort_code = margin_manager::EDeprecatedUseUpgradedPyth)]
fun legacy_manager_states_aborts() {
    let (
        mut scenario,
        clock,
        _admin_cap,
        _maintainer_cap,
        base_pool_id,
        quote_pool_id,
        pool_id,
    ) = env();

    scenario.next_tx(test_constants::user1());
    let pool = scenario.take_shared_by_id<Pool<USDC, USDT>>(pool_id);
    let registry = scenario.take_shared<MarginRegistry>();
    let base_pool = scenario.take_shared_by_id<MarginPool<USDC>>(base_pool_id);
    let quote_pool = scenario.take_shared_by_id<MarginPool<USDT>>(quote_pool_id);
    let (base, quote) = legacy_feeds(&mut scenario, &clock);
    let managers: vector<MarginManager<USDC, USDT>> = vector[];

    margin_manager::manager_states<USDC, USDT>(
        &managers,
        &registry,
        &base,
        &quote,
        &pool,
        &base_pool,
        &quote_pool,
        &clock,
    );

    abort 999
}

// === pool_proxy ===

/// The price the order-validation band is anchored to. Permissionless, so this was the
/// entry that let a caller re-anchor the band to the feed that suited them before
/// firing anything else.
#[test, expected_failure(abort_code = pool_proxy::EDeprecatedUseUpgradedPyth)]
fun legacy_update_current_price_aborts() {
    let (mut scenario, clock, _admin_cap, _maintainer_cap, _b, _q, pool_id) = env();

    scenario.next_tx(test_constants::liquidator());
    let pool = scenario.take_shared_by_id<Pool<USDC, USDT>>(pool_id);
    let mut registry = scenario.take_shared<MarginRegistry>();
    let (base, quote) = legacy_feeds(&mut scenario, &clock);

    pool_proxy::update_current_price<USDC, USDT>(
        &mut registry,
        &pool,
        &base,
        &quote,
        &clock,
    );

    abort 999
}

#[test, expected_failure(abort_code = pool_proxy::EDeprecatedUseUpgradedPyth)]
fun legacy_place_limit_order_v2_aborts() {
    let (
        mut scenario,
        clock,
        _admin_cap,
        _maintainer_cap,
        base_pool_id,
        quote_pool_id,
        pool_id,
    ) = env();

    scenario.next_tx(test_constants::user1());
    let mut mm = scenario.take_shared<MarginManager<USDC, USDT>>();
    let mut pool = scenario.take_shared_by_id<Pool<USDC, USDT>>(pool_id);
    let registry = scenario.take_shared<MarginRegistry>();
    let base_pool = scenario.take_shared_by_id<MarginPool<USDC>>(base_pool_id);
    let quote_pool = scenario.take_shared_by_id<MarginPool<USDT>>(quote_pool_id);
    let (base, quote) = legacy_feeds(&mut scenario, &clock);

    let _ = pool_proxy::place_limit_order_v2<USDC, USDT>(
        &registry,
        &mut mm,
        &mut pool,
        &base_pool,
        &quote_pool,
        &base,
        &quote,
        1,
        constants::no_restriction(),
        constants::self_matching_allowed(),
        1_000_000,
        1_000_000,
        true,
        false,
        constants::max_u64(),
        &clock,
        scenario.ctx(),
    );

    abort 999
}

#[test, expected_failure(abort_code = pool_proxy::EDeprecatedUseUpgradedPyth)]
fun legacy_place_market_order_v2_aborts() {
    let (
        mut scenario,
        clock,
        _admin_cap,
        _maintainer_cap,
        base_pool_id,
        quote_pool_id,
        pool_id,
    ) = env();

    scenario.next_tx(test_constants::user1());
    let mut mm = scenario.take_shared<MarginManager<USDC, USDT>>();
    let mut pool = scenario.take_shared_by_id<Pool<USDC, USDT>>(pool_id);
    let registry = scenario.take_shared<MarginRegistry>();
    let base_pool = scenario.take_shared_by_id<MarginPool<USDC>>(base_pool_id);
    let quote_pool = scenario.take_shared_by_id<MarginPool<USDT>>(quote_pool_id);
    let (base, quote) = legacy_feeds(&mut scenario, &clock);

    let _ = pool_proxy::place_market_order_v2<USDC, USDT>(
        &registry,
        &mut mm,
        &mut pool,
        &base_pool,
        &quote_pool,
        &base,
        &quote,
        1,
        constants::self_matching_allowed(),
        1_000_000,
        true,
        false,
        &clock,
        scenario.ctx(),
    );

    abort 999
}

#[test, expected_failure(abort_code = pool_proxy::EDeprecatedUseUpgradedPyth)]
fun legacy_place_reduce_only_limit_order_v2_aborts() {
    let (
        mut scenario,
        clock,
        _admin_cap,
        _maintainer_cap,
        base_pool_id,
        quote_pool_id,
        pool_id,
    ) = env();

    scenario.next_tx(test_constants::user1());
    let mut mm = scenario.take_shared<MarginManager<USDC, USDT>>();
    let mut pool = scenario.take_shared_by_id<Pool<USDC, USDT>>(pool_id);
    let registry = scenario.take_shared<MarginRegistry>();
    let base_pool = scenario.take_shared_by_id<MarginPool<USDC>>(base_pool_id);
    let quote_pool = scenario.take_shared_by_id<MarginPool<USDT>>(quote_pool_id);
    let (base, quote) = legacy_feeds(&mut scenario, &clock);

    let _ = pool_proxy::place_reduce_only_limit_order_v2<USDC, USDT>(
        &registry,
        &mut mm,
        &mut pool,
        &base_pool,
        &quote_pool,
        &base,
        &quote,
        1,
        constants::no_restriction(),
        constants::self_matching_allowed(),
        1_000_000,
        1_000_000,
        true,
        false,
        constants::max_u64(),
        &clock,
        scenario.ctx(),
    );

    abort 999
}

#[test, expected_failure(abort_code = pool_proxy::EDeprecatedUseUpgradedPyth)]
fun legacy_place_reduce_only_market_order_v2_aborts() {
    let (
        mut scenario,
        clock,
        _admin_cap,
        _maintainer_cap,
        base_pool_id,
        quote_pool_id,
        pool_id,
    ) = env();

    scenario.next_tx(test_constants::user1());
    let mut mm = scenario.take_shared<MarginManager<USDC, USDT>>();
    let mut pool = scenario.take_shared_by_id<Pool<USDC, USDT>>(pool_id);
    let registry = scenario.take_shared<MarginRegistry>();
    let base_pool = scenario.take_shared_by_id<MarginPool<USDC>>(base_pool_id);
    let quote_pool = scenario.take_shared_by_id<MarginPool<USDT>>(quote_pool_id);
    let (base, quote) = legacy_feeds(&mut scenario, &clock);

    let _ = pool_proxy::place_reduce_only_market_order_v2<USDC, USDT>(
        &registry,
        &mut mm,
        &mut pool,
        &base_pool,
        &quote_pool,
        &base,
        &quote,
        1,
        constants::self_matching_allowed(),
        1_000_000,
        true,
        false,
        &clock,
        scenario.ctx(),
    );

    abort 999
}

#[test, expected_failure(abort_code = pool_proxy::EDeprecatedUseUpgradedPyth)]
fun legacy_place_reduce_only_market_order_and_repay_loan_aborts() {
    let (
        mut scenario,
        clock,
        _admin_cap,
        _maintainer_cap,
        base_pool_id,
        quote_pool_id,
        pool_id,
    ) = env();

    scenario.next_tx(test_constants::user1());
    let mut mm = scenario.take_shared<MarginManager<USDC, USDT>>();
    let mut pool = scenario.take_shared_by_id<Pool<USDC, USDT>>(pool_id);
    let registry = scenario.take_shared<MarginRegistry>();
    let mut base_pool = scenario.take_shared_by_id<MarginPool<USDC>>(base_pool_id);
    let mut quote_pool = scenario.take_shared_by_id<MarginPool<USDT>>(quote_pool_id);
    let (base, quote) = legacy_feeds(&mut scenario, &clock);

    let _ = pool_proxy::place_reduce_only_market_order_and_repay_loan<USDC, USDT>(
        &registry,
        &mut mm,
        &mut pool,
        &mut base_pool,
        &mut quote_pool,
        &base,
        &quote,
        1,
        constants::self_matching_allowed(),
        1_000_000,
        true,
        false,
        &clock,
        scenario.ctx(),
    );

    abort 999
}

#[test, expected_failure(abort_code = pool_proxy::EDeprecatedUseUpgradedPyth)]
fun legacy_place_reduce_only_limit_order_and_repay_loan_aborts() {
    let (
        mut scenario,
        clock,
        _admin_cap,
        _maintainer_cap,
        base_pool_id,
        quote_pool_id,
        pool_id,
    ) = env();

    scenario.next_tx(test_constants::user1());
    let mut mm = scenario.take_shared<MarginManager<USDC, USDT>>();
    let mut pool = scenario.take_shared_by_id<Pool<USDC, USDT>>(pool_id);
    let registry = scenario.take_shared<MarginRegistry>();
    let mut base_pool = scenario.take_shared_by_id<MarginPool<USDC>>(base_pool_id);
    let mut quote_pool = scenario.take_shared_by_id<MarginPool<USDT>>(quote_pool_id);
    let (base, quote) = legacy_feeds(&mut scenario, &clock);

    let _ = pool_proxy::place_reduce_only_limit_order_and_repay_loan<USDC, USDT>(
        &registry,
        &mut mm,
        &mut pool,
        &mut base_pool,
        &mut quote_pool,
        &base,
        &quote,
        1,
        constants::no_restriction(),
        constants::self_matching_allowed(),
        1_000_000,
        1_000_000,
        true,
        false,
        constants::max_u64(),
        &clock,
        scenario.ctx(),
    );

    abort 999
}

#[test, expected_failure(abort_code = pool_proxy::EDeprecatedUseUpgradedPyth)]
fun legacy_place_market_order_and_repay_loan_aborts() {
    let (
        mut scenario,
        clock,
        _admin_cap,
        _maintainer_cap,
        base_pool_id,
        quote_pool_id,
        pool_id,
    ) = env();

    scenario.next_tx(test_constants::user1());
    let mut mm = scenario.take_shared<MarginManager<USDC, USDT>>();
    let mut pool = scenario.take_shared_by_id<Pool<USDC, USDT>>(pool_id);
    let registry = scenario.take_shared<MarginRegistry>();
    let mut base_pool = scenario.take_shared_by_id<MarginPool<USDC>>(base_pool_id);
    let mut quote_pool = scenario.take_shared_by_id<MarginPool<USDT>>(quote_pool_id);
    let (base, quote) = legacy_feeds(&mut scenario, &clock);

    let _ = pool_proxy::place_market_order_and_repay_loan<USDC, USDT>(
        &registry,
        &mut mm,
        &mut pool,
        &mut base_pool,
        &mut quote_pool,
        &base,
        &quote,
        1,
        constants::self_matching_allowed(),
        1_000_000,
        true,
        false,
        &clock,
        scenario.ctx(),
    );

    abort 999
}
