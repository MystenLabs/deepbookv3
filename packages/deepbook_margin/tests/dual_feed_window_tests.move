// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// The window in which BOTH Pyth feeds were live and authoritative, and its closure.
///
/// `read_price` and `read_price_upgraded` each enforced the same feed id, staleness
/// window and EWMA bound, and each carried the confidence interval for `price_config` to
/// check at pricing time — but they did so independently, with no cross-feed comparison.
/// `PythReading` erases which feed produced it and both entrypoint families shared one
/// `_core`, so a caller chose per call. Prices could not be forged, but the divergence
/// was *selectable*: an attacker chose which signed update landed on which object and
/// when, so they picked a moment inside the window rather than merely finding one. The
/// bound was each feed's own staleness allowance — one leg fresh while the other sat
/// `max_age_secs` old, so the two prices could sit a full window apart.
///
/// The exposed set was wider than liquidation. Liquidating on the lower feed needs the
/// manager in the danger band, and calling `margin_manager::liquidate` directly needs the
/// caller to post a repay coin — though `margin_liquidation`'s vault entries are
/// permissionless and fund the repay themselves, so the capital half of that never really
/// bound. Firing a conditional order needed neither: `execute_conditional_orders_v2`/`v3`
/// are permissionless, take no capital, and act on a manager that is merely healthy.
///
/// The window did not self-close at Pyth's cutover: legacy objects for most configured
/// currencies stayed fresh past it, refreshed by third parties DeepBook does not control.
/// It is closed here instead, by retiring the legacy readers and the entrypoints that
/// called them. These tests are the scenario-level record of that: each one replays a
/// path that used to succeed and pins where it now stops. The surface inventory — one
/// abort test per retired entry — is `legacy_pyth_entrypoints_disabled_tests`.
///
/// These tests are load-bearing in one direction: if any of them starts passing *through*
/// the legacy entry rather than through its abort, a second authoritative reader has been
/// reintroduced. Update them deliberately, do not delete them.
#[test_only]
module deepbook_margin::dual_feed_window_tests;

use deepbook::{constants, order_info::OrderInfo, pool::Pool, registry::Registry};
use deepbook_margin::{
    margin_manager::{Self, MarginManager},
    margin_manager_upgraded,
    margin_pool::MarginPool,
    margin_registry::{MarginRegistry, MarginAdminCap, MaintainerCap},
    pool_proxy_upgraded,
    test_constants::{Self, USDC, BTC, btc_multiplier},
    test_helpers::{
        cleanup_margin_test,
        mint_coin,
        build_btc_price_info_object,
        build_btc_price_info_object_upgraded,
        build_demo_usdc_price_info_object,
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
    let btc_price = build_btc_price_info_object_upgraded(&mut scenario, 50000, &clock);
    let usdc_price = build_demo_usdc_price_info_object_upgraded(&mut scenario, &clock);

    margin_manager_upgraded::deposit<BTC, USDC, BTC>(
        &mut mm,
        &registry,
        &btc_price,
        &usdc_price,
        mint_coin<BTC>(btc_multiplier(), scenario.ctx()),
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

/// CLOSED — dual-feed liquidation.
///
/// The exploit: price one manager through two live feeds in the same block. The legacy
/// feed puts BTC at $4100 (risk 1.1025, NOT liquidatable) while the upgraded feed puts it
/// at $3900 (risk 1.0975, liquidatable), and the upgraded feed alone sufficed to liquidate
/// a manager the legacy feed called healthy. The liquidator walked away with collateral.
///
/// Both halves are gone. The legacy risk query — the "is it healthy on the other feed?"
/// leg an attacker used to select the moment — aborts before it can price anything, so
/// the divergence is not observable through the protocol, let alone actionable. The
/// second half (that `margin_manager::liquidate` itself aborts) is
/// `legacy_pyth_entrypoints_disabled_tests::legacy_liquidate_aborts`.
#[test, expected_failure(abort_code = margin_manager::EDeprecatedUseUpgradedPyth)]
fun dual_feed_window_no_longer_prices_a_manager_on_the_legacy_feed() {
    let (
        mut scenario,
        clock,
        _admin_cap,
        _maintainer_cap,
        btc_pool_id,
        usdc_pool_id,
        _registry_id,
    ) = open_1btc_40k_usdc();

    scenario.next_tx(test_constants::liquidator());
    let mm = scenario.take_shared<MarginManager<BTC, USDC>>();
    let pool = scenario.take_shared<Pool<BTC, USDC>>();
    let registry = scenario.take_shared<MarginRegistry>();
    let btc_pool = scenario.take_shared_by_id<MarginPool<BTC>>(btc_pool_id);
    let usdc_pool = scenario.take_shared_by_id<MarginPool<USDC>>(usdc_pool_id);

    // The legacy leg of the exploit: BTC at $4100, fresh and correctly configured, so
    // the only thing that can stop this read is the retirement itself.
    let legacy_btc = build_btc_price_info_object(&mut scenario, 4100, &clock);
    let legacy_usdc = build_demo_usdc_price_info_object(&mut scenario, &clock);

    let _ = margin_manager::risk_ratio<BTC, USDC>(
        &mm,
        &registry,
        &legacy_btc,
        &legacy_usdc,
        &pool,
        &btc_pool,
        &usdc_pool,
        &clock,
    );

    abort 999
}

/// The upgraded path still liquidates a genuinely unhealthy manager.
///
/// Closing the window must not close liquidation: the same $3900 mark that the exploit
/// used as its *lower* leg is, on its own, a real liquidation. Without this the abort
/// tests above would pass just as well against a package where liquidation was broken.
#[test]
fun upgraded_feed_alone_still_liquidates_an_unhealthy_manager() {
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

    let btc = build_btc_price_info_object_upgraded(&mut scenario, 3900, &clock);
    let usdc = build_demo_usdc_price_info_object_upgraded(&mut scenario, &clock);

    // 1 BTC at $3900 against 40k USDC of debt is below the pool's liquidation floor.
    let risk = margin_manager_upgraded::risk_ratio<BTC, USDC>(
        &mm,
        &registry,
        &btc,
        &usdc,
        &pool,
        &btc_pool,
        &usdc_pool,
        &clock,
    );
    assert!(registry.can_liquidate(pool.id(), risk), 100);

    let repay = mint_coin<USDC>(100_000_000_000, scenario.ctx());
    let (base_coin, quote_coin, remaining) = margin_manager_upgraded::liquidate<BTC, USDC, USDC>(
        &mut mm,
        &registry,
        &btc,
        &usdc,
        &mut usdc_pool,
        &mut pool,
        repay,
        &clock,
        scenario.ctx(),
    );
    assert!(base_coin.value() > 0 || quote_coin.value() > 0, 101);

    destroy_3!(base_coin, quote_coin, remaining);
    destroy_2!(btc, usdc);
    return_shared(btc_pool);
    return_shared(usdc_pool);
    return_shared(pool);
    return_shared(mm);
    cleanup_margin_test(registry, admin_cap, maintainer_cap, clock, scenario);
}

/// GUARD — a debt-carrying position cannot be evaluated on a stale upgraded feed.
/// Liquidation through the upgraded entrypoint with a stale BTC feed must abort in the
/// upgraded reader's staleness check (get_price_no_older_than). With the legacy family
/// retired this is the only staleness window left, so it is the whole guard.
#[test, expected_failure(abort_code = pyth_upgraded::pyth::E_STALE_PRICE_UPDATE)]
fun upgraded_feed_still_enforces_staleness() {
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

/// CLOSED — the widest leg: a permissionless stop fired on the lower feed alone.
///
/// Liquidating on the lower feed at least needed the manager in the danger band. Firing a
/// conditional order needed nothing: the v2 executor is permissionless, takes no capital,
/// and acts on a manager that is merely healthy. A caller ran the executor with the feed
/// that suited them and realised a stop the true price never reached — an arbitrary third
/// party closing someone else's position at a price of their choosing.
///
/// The stop is placed and confirmed queued through the live path, then the legacy
/// executor is called on it exactly as the exploit did. It aborts, and the ordering
/// matters: the assertions before the call prove the order was genuinely there to fire,
/// so the abort is the retirement and not an empty queue.
#[test, expected_failure(abort_code = margin_manager::EDeprecatedUseUpgradedPyth)]
fun dual_feed_window_no_longer_fires_a_stop_on_the_legacy_feed() {
    let (
        mut scenario,
        clock,
        _admin_cap,
        _maintainer_cap,
        btc_pool_id,
        usdc_pool_id,
        _registry_id,
    ) = open_1btc_40k_usdc();

    // A stop-loss at $45k while BTC trades at $50k.
    scenario.next_tx(test_constants::user1());
    let mut mm = scenario.take_shared<MarginManager<BTC, USDC>>();
    let pool = scenario.take_shared<Pool<BTC, USDC>>();
    let registry = scenario.take_shared<MarginRegistry>();
    let btc_50k = build_btc_price_info_object_upgraded(&mut scenario, 50000, &clock);
    let usdc = build_demo_usdc_price_info_object_upgraded(&mut scenario, &clock);

    margin_manager_upgraded::add_conditional_order<BTC, USDC>(
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
    destroy_2!(btc_50k, usdc);
    return_shared(registry);
    return_shared(pool);
    return_shared(mm);

    // An arbitrary caller — not the owner — brings a legacy feed at $44k, below the stop.
    scenario.next_tx(test_constants::liquidator());
    let mut mm = scenario.take_shared<MarginManager<BTC, USDC>>();
    let mut pool = scenario.take_shared<Pool<BTC, USDC>>();
    let registry = scenario.take_shared<MarginRegistry>();
    let btc_pool = scenario.take_shared_by_id<MarginPool<BTC>>(btc_pool_id);
    let usdc_pool = scenario.take_shared_by_id<MarginPool<USDC>>(usdc_pool_id);

    let legacy_44k = build_btc_price_info_object(&mut scenario, 44000, &clock);
    let legacy_usdc = build_demo_usdc_price_info_object(&mut scenario, &clock);

    let _: vector<OrderInfo> = margin_manager::execute_conditional_orders_v2<BTC, USDC>(
        &mut mm,
        &mut pool,
        &btc_pool,
        &usdc_pool,
        &legacy_44k,
        &legacy_usdc,
        &registry,
        10,
        &clock,
        scenario.ctx(),
    );

    abort 999
}

/// The upgraded executor still fires that same stop, so the abort above is the legacy
/// entry and not a queue that stopped working.
#[test]
fun upgraded_executor_still_fires_a_triggered_stop() {
    let (
        mut scenario,
        clock,
        admin_cap,
        maintainer_cap,
        btc_pool_id,
        usdc_pool_id,
        _registry_id,
    ) = open_1btc_40k_usdc();

    scenario.next_tx(test_constants::user1());
    let mut mm = scenario.take_shared<MarginManager<BTC, USDC>>();
    let pool = scenario.take_shared<Pool<BTC, USDC>>();
    let registry = scenario.take_shared<MarginRegistry>();
    let btc_50k = build_btc_price_info_object_upgraded(&mut scenario, 50000, &clock);
    let usdc = build_demo_usdc_price_info_object_upgraded(&mut scenario, &clock);

    margin_manager_upgraded::add_conditional_order<BTC, USDC>(
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
    destroy_2!(btc_50k, usdc);
    return_shared(registry);
    return_shared(pool);
    return_shared(mm);

    scenario.next_tx(test_constants::liquidator());
    let mut mm = scenario.take_shared<MarginManager<BTC, USDC>>();
    let mut pool = scenario.take_shared<Pool<BTC, USDC>>();
    let mut registry = scenario.take_shared<MarginRegistry>();
    let btc_pool = scenario.take_shared_by_id<MarginPool<BTC>>(btc_pool_id);
    let usdc_pool = scenario.take_shared_by_id<MarginPool<USDC>>(usdc_pool_id);

    // Re-anchoring the order-validation band is permissionless, so the same caller does
    // it — with the same feed the executor then reads.
    let btc_44k = build_btc_price_info_object_upgraded(&mut scenario, 44000, &clock);
    let usdc = build_demo_usdc_price_info_object_upgraded(&mut scenario, &clock);
    pool_proxy_upgraded::update_current_price<BTC, USDC>(
        &mut registry,
        &pool,
        &btc_44k,
        &usdc,
        &clock,
    );

    let filled: vector<OrderInfo> = margin_manager_upgraded::execute_conditional_orders_v2<
        BTC,
        USDC,
    >(
        &mut mm,
        &mut pool,
        &btc_pool,
        &usdc_pool,
        &btc_44k,
        &usdc,
        &registry,
        10,
        &clock,
        scenario.ctx(),
    );
    assert!(filled.length() == 1);
    assert!(mm.conditional_order_ids().is_empty());

    std::unit_test::destroy(filled);
    destroy_2!(btc_44k, usdc);
    return_shared(btc_pool);
    return_shared(usdc_pool);
    return_shared(pool);
    return_shared(mm);
    cleanup_margin_test(registry, admin_cap, maintainer_cap, clock, scenario);
}
