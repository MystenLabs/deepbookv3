// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Behaviour of the window in which BOTH Pyth feeds are live and authoritative.
///
/// Between this upgrade and Pyth's Core cutover, `read_price*` and `read_price_upgraded*`
/// each validate against the same feed id, staleness window, confidence and EWMA
/// bounds - but independently, with no cross-feed comparison. `PythReading` erases
/// which feed produced it and both entrypoint families share one `_core`, so a caller
/// chooses per call. These tests pin what that does and does not permit.
///
/// Prices cannot be forged, but the divergence is still *selectable*: an attacker
/// chooses which signed update lands on which object and when, so they pick a moment
/// inside the window rather than merely finding one. The bound is each feed's own
/// staleness allowance — one leg may be fresh while the other is `max_age_secs` old,
/// so the two prices can sit a full window apart. This suite runs the test config's
/// 60s; live mainnet is configured at 70s.
///
/// The exposed set is wider than liquidation. Liquidating on the lower feed needs the
/// manager in the danger band and the caller to post a repay coin. Firing a
/// conditional order needs neither: `execute_conditional_orders_v2`/`v3` are
/// permissionless, take no capital, and act on healthy debt-free managers — see
/// `dual_feed_window_fires_a_stop_on_the_lower_feed_alone`.
///
/// If a mitigation lands (an admin switch making exactly one reader family
/// authoritative, say) `dual_feed_window_permits_liquidating_on_the_lower_feed` is the
/// test that should start failing - update it deliberately, do not delete it.
#[test_only]
module deepbook_margin::dual_feed_window_tests;

use deepbook::{constants, order_info::OrderInfo, pool::Pool, registry::Registry};
use deepbook_margin::{
    margin_manager::{Self, MarginManager},
    margin_manager_upgraded,
    margin_pool::MarginPool,
    margin_registry::{MarginRegistry, MarginAdminCap, MaintainerCap},
    test_constants::{Self, USDC, BTC, btc_multiplier},
    test_helpers::{
        cleanup_margin_test,
        mint_coin,
        build_btc_price_info_object,
        build_demo_usdc_price_info_object,
        build_btc_price_info_object_upgraded,
        build_demo_usdc_price_info_object_upgraded,
        build_stale_btc_price_info_object_upgraded,
        setup_btc_usd_deepbook_margin,
        destroy_2,
        destroy_3,
    },
    tpsl
};
use sui::{clock::Clock, test_scenario::{Self as test, return_shared}};

/// Borrows 40k USDC against 1 BTC (opened at $50k) and shares the manager.
/// Returns the scenario plus the ids needed to re-take the shared objects.
fun open_1btc_40k_usdc(): (test::Scenario, Clock, MarginAdminCap, MaintainerCap, ID, ID, ID) {
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
    return_shared(pool);
    return_shared(registry);

    scenario.next_tx(test_constants::user1());
    let mut mm = scenario.take_shared<MarginManager<BTC, USDC>>();
    let pool = scenario.take_shared<Pool<BTC, USDC>>();
    let registry = scenario.take_shared<MarginRegistry>();
    let mut usdc_pool = scenario.take_shared_by_id<MarginPool<USDC>>(usdc_pool_id);
    let btc_price = build_btc_price_info_object(&mut scenario, 50000, &clock);
    let usdc_price = build_demo_usdc_price_info_object(&mut scenario, &clock);

    mm.deposit<BTC, USDC, BTC>(
        &registry,
        &btc_price,
        &usdc_price,
        mint_coin<BTC>(btc_multiplier(), scenario.ctx()),
        &clock,
        scenario.ctx(),
    );
    mm.borrow_quote<BTC, USDC>(
        &registry,
        &mut usdc_pool,
        &btc_price,
        &usdc_price,
        &pool,
        40_000_000_000, // 40k USDC (6 decimals)
        &clock,
        scenario.ctx(),
    );

    destroy_2!(btc_price, usdc_price);
    return_shared(mm);
    return_shared(pool);
    return_shared(registry);
    return_shared(usdc_pool);

    (scenario, clock, admin_cap, maintainer_cap, btc_pool_id, usdc_pool_id, registry_id)
}

/// EXPLOIT ATTEMPT — dual-feed liquidation.
/// The same manager is priced through two live feeds in the same block: the
/// legacy Core feed puts BTC at $4100 (risk 1.1025, NOT liquidatable) while the
/// Pyth's upgraded Core feed puts BTC at $3900 (risk 1.0975, liquidatable). If the upgraded feed
/// alone suffices to liquidate a manager the Core feed calls healthy, the
/// liquidation goes through and the liquidator walks away with collateral.
#[test]
fun dual_feed_window_permits_liquidating_on_the_lower_feed() {
    let (
        mut scenario,
        clock,
        admin_cap,
        maintainer_cap,
        btc_pool_id,
        usdc_pool_id,
        _registry_id,
    ) = open_1btc_40k_usdc();

    scenario.next_tx(test_constants::liquidator());
    let mut mm = scenario.take_shared<MarginManager<BTC, USDC>>();
    let mut pool = scenario.take_shared<Pool<BTC, USDC>>();
    let registry = scenario.take_shared<MarginRegistry>();
    let btc_pool = scenario.take_shared_by_id<MarginPool<BTC>>(btc_pool_id);
    let mut usdc_pool = scenario.take_shared_by_id<MarginPool<USDC>>(usdc_pool_id);

    // Core feed: BTC $4100. Legacy risk query must call it healthy.
    let core_btc = build_btc_price_info_object(&mut scenario, 4100, &clock);
    let core_usdc = build_demo_usdc_price_info_object(&mut scenario, &clock);
    let core_risk = mm.risk_ratio<BTC, USDC>(
        &registry,
        &core_btc,
        &core_usdc,
        &pool,
        &btc_pool,
        &usdc_pool,
        &clock,
    );
    let liq_threshold = registry.liquidation_risk_ratio(pool.id());
    assert!(core_risk >= liq_threshold, 100); // Core: NOT liquidatable
    assert!(!registry.can_liquidate(pool.id(), core_risk), 101);

    // Upgraded feed: BTC $3900. Liquidate through the upgraded entrypoint in the same block.
    let upgraded_btc = build_btc_price_info_object_upgraded(&mut scenario, 3900, &clock);
    let upgraded_usdc = build_demo_usdc_price_info_object_upgraded(&mut scenario, &clock);
    let repay = mint_coin<USDC>(100_000_000_000, scenario.ctx());

    let (base_coin, quote_coin, remaining) = margin_manager_upgraded::liquidate<BTC, USDC, USDC>(
        &mut mm,
        &registry,
        &upgraded_btc,
        &upgraded_usdc,
        &mut usdc_pool,
        &mut pool,
        repay,
        &clock,
        scenario.ctx(),
    );

    // Liquidator profited: received collateral back from a Core-healthy manager.
    let extracted = base_coin.value();
    let quote_back = quote_coin.value();
    assert!(extracted > 0 || quote_back > 0, 102);

    destroy_3!(base_coin, quote_coin, remaining);
    destroy_2!(core_btc, core_usdc);
    destroy_2!(upgraded_btc, upgraded_usdc);
    return_shared(btc_pool);
    return_shared(usdc_pool);
    return_shared(pool);
    return_shared(mm);
    cleanup_margin_test(registry, admin_cap, maintainer_cap, clock, scenario);
}

/// GUARD — a debt-carrying position cannot be evaluated on a stale upgraded feed.
/// Liquidation through the upgraded entrypoint with a stale BTC feed must abort in the
/// upgraded reader's staleness check (get_price_no_older_than).
#[test, expected_failure(abort_code = pyth_upgraded::pyth::E_STALE_PRICE_UPDATE)]
fun dual_feed_window_still_enforces_staleness_on_each_feed() {
    let (
        mut scenario,
        clock,
        admin_cap,
        maintainer_cap,
        _btc_pool_id,
        usdc_pool_id,
        _registry_id,
    ) = open_1btc_40k_usdc();

    scenario.next_tx(test_constants::liquidator());
    let mut mm = scenario.take_shared<MarginManager<BTC, USDC>>();
    let mut pool = scenario.take_shared<Pool<BTC, USDC>>();
    let registry = scenario.take_shared<MarginRegistry>();
    let mut usdc_pool = scenario.take_shared_by_id<MarginPool<USDC>>(usdc_pool_id);

    // Stale by 10 minutes; max age is 60s.
    let upgraded_btc = build_stale_btc_price_info_object_upgraded(&mut scenario, 3900, 600, &clock);
    let upgraded_usdc = build_demo_usdc_price_info_object_upgraded(&mut scenario, &clock);
    let repay = mint_coin<USDC>(100_000_000_000, scenario.ctx());

    let (base_coin, quote_coin, remaining) = margin_manager_upgraded::liquidate<BTC, USDC, USDC>(
        &mut mm,
        &registry,
        &upgraded_btc,
        &upgraded_usdc,
        &mut usdc_pool,
        &mut pool,
        repay,
        &clock,
        scenario.ctx(),
    );

    destroy_3!(base_coin, quote_coin, remaining);
    destroy_2!(upgraded_btc, upgraded_usdc);
    return_shared(usdc_pool);
    return_shared(pool);
    return_shared(mm);
    cleanup_margin_test(registry, admin_cap, maintainer_cap, clock, scenario);
}

/// The window's exposed set is wider than liquidation.
///
/// Liquidating on the lower feed needs the manager in the danger band and the caller
/// to post a repay coin. Firing a conditional order needs neither: the v2 executor is
/// permissionless, takes no capital, and acts on a healthy debt-free manager. The
/// trigger is evaluated against whichever feed the caller supplies, and nothing on
/// chain compares the two — so a stop the true price never reached can be realised by
/// an arbitrary third party.
#[test]
fun dual_feed_window_fires_a_stop_on_the_lower_feed_alone() {
    let (
        mut scenario,
        clock,
        admin_cap,
        maintainer_cap,
        btc_pool_id,
        usdc_pool_id,
        _registry_id,
    ) = open_1btc_40k_usdc();

    // A stop-loss at $45k while BTC trades at $50k.
    scenario.next_tx(test_constants::user1());
    let mut mm = scenario.take_shared<MarginManager<BTC, USDC>>();
    let pool = scenario.take_shared<Pool<BTC, USDC>>();
    let registry = scenario.take_shared<MarginRegistry>();
    let btc_50k = build_btc_price_info_object(&mut scenario, 50000, &clock);
    let usdc = build_demo_usdc_price_info_object(&mut scenario, &clock);

    margin_manager::add_conditional_order<BTC, USDC>(
        &mut mm,
        &pool,
        &btc_50k,
        &usdc,
        &registry,
        1,
        tpsl::new_condition(true, 450_000_000_000),
        tpsl::new_pending_limit_order(
            1,
            constants::no_restriction(),
            constants::self_matching_allowed(),
            440_000_000_000,
            btc_multiplier() / 10,
            false,
            false,
            constants::max_u64(),
        ),
        &clock,
        scenario.ctx(),
    );
    assert!(mm.conditional_order_ids().length() == 1);
    return_shared(registry);
    return_shared(pool);
    return_shared(mm);

    // An arbitrary caller — not the owner — runs the executor twice in the same block.
    scenario.next_tx(test_constants::liquidator());
    let mut mm = scenario.take_shared<MarginManager<BTC, USDC>>();
    let mut pool = scenario.take_shared<Pool<BTC, USDC>>();
    let mut registry = scenario.take_shared<MarginRegistry>();
    let btc_pool = scenario.take_shared_by_id<MarginPool<BTC>>(btc_pool_id);
    let usdc_pool = scenario.take_shared_by_id<MarginPool<USDC>>(usdc_pool_id);

    // Legacy feed at $48k is above the stop: the order must stay queued.
    let legacy_48k = build_btc_price_info_object(&mut scenario, 48000, &clock);
    let legacy_usdc = build_demo_usdc_price_info_object(&mut scenario, &clock);
    let legacy_filled: vector<OrderInfo> = margin_manager::execute_conditional_orders_v2<BTC, USDC>(
        &mut mm,
        &mut pool,
        &btc_pool,
        &usdc_pool,
        &legacy_48k,
        &legacy_usdc,
        &registry,
        10,
        &clock,
        scenario.ctx(),
    );
    assert!(legacy_filled.is_empty());
    assert!(mm.conditional_order_ids().length() == 1);

    // Upgraded feed at $44k, same block, same manager. Re-anchoring the order-validation
    // band is itself permissionless, so the same caller does it with the same feed.
    let upgraded_44k = build_btc_price_info_object_upgraded(&mut scenario, 44000, &clock);
    let upgraded_usdc = build_demo_usdc_price_info_object_upgraded(&mut scenario, &clock);
    deepbook_margin::pool_proxy_upgraded::update_current_price<BTC, USDC>(
        &mut registry,
        &pool,
        &upgraded_44k,
        &upgraded_usdc,
        &clock,
    );
    let upgraded_filled: vector<OrderInfo> = margin_manager_upgraded::execute_conditional_orders_v2<
        BTC,
        USDC,
    >(
        &mut mm,
        &mut pool,
        &btc_pool,
        &usdc_pool,
        &upgraded_44k,
        &upgraded_usdc,
        &registry,
        10,
        &clock,
        scenario.ctx(),
    );
    assert!(upgraded_filled.length() == 1);
    assert!(mm.conditional_order_ids().is_empty());

    std::unit_test::destroy(legacy_filled);
    std::unit_test::destroy(upgraded_filled);
    destroy_2!(legacy_48k, legacy_usdc);
    destroy_2!(upgraded_44k, upgraded_usdc);
    destroy_2!(btc_50k, usdc);
    return_shared(btc_pool);
    return_shared(usdc_pool);
    return_shared(pool);
    return_shared(mm);
    cleanup_margin_test(registry, admin_cap, maintainer_cap, clock, scenario);
}
