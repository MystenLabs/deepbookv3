// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Oracle behaviour of the vault's liquidation entrypoints.
///
/// The existing `liquidation_vault_tests` cover deposits, withdrawals, trader
/// authorisation and swaps, but never call `liquidate_base`/`liquidate_quote` — so
/// neither the legacy pair nor the upgraded pair added for the Pyth cutover had any
/// coverage of the two things that can silently go wrong: which oracle generation an
/// entry reads, and whether the `can_liquidate` gate actually holds.
#[test_only]
module margin_liquidation::liquidation_vault_oracle_tests;

use deepbook::pool::Pool;
use deepbook_margin::{
    margin_manager::{Self, MarginManager},
    margin_pool::MarginPool,
    margin_registry::MarginRegistry,
    test_constants::{Self, USDC, BTC, btc_multiplier},
    test_helpers::{
        setup_btc_usd_deepbook_margin,
        build_btc_price_info_object,
        build_demo_usdc_price_info_object,
        build_btc_price_info_object_upgraded,
        build_demo_usdc_price_info_object_upgraded,
        build_stale_btc_price_info_object,
        build_stale_btc_price_info_object_upgraded,
        mint_coin,
    }
};
use margin_liquidation::liquidation_vault::{Self, LiquidationByVault};
use std::unit_test::destroy;
use sui::{clock::Clock, test_scenario::{Self as test, return_shared}};

/// A healthy BTC/USDC manager: 1 BTC of collateral against a 40k USDC loan at $50k.
/// Every test here starts from it, then varies only the feed handed to the vault.
fun healthy_manager(): (test::Scenario, Clock, ID, ID, ID) {
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
    let deepbook_registry = scenario.take_shared_by_id<deepbook::registry::Registry>(registry_id);
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
    let btc = build_btc_price_info_object(&mut scenario, 50000, &clock);
    let usdc = build_demo_usdc_price_info_object(&mut scenario, &clock);

    margin_manager::deposit<BTC, USDC, BTC>(
        &mut mm,
        &registry,
        &btc,
        &usdc,
        mint_coin<BTC>(btc_multiplier(), scenario.ctx()),
        &clock,
        scenario.ctx(),
    );
    margin_manager::borrow_quote<BTC, USDC>(
        &mut mm,
        &registry,
        &mut usdc_pool,
        &btc,
        &usdc,
        &pool,
        40_000 * test_constants::usdc_multiplier(),
        &clock,
        scenario.ctx(),
    );

    destroy(btc);
    destroy(usdc);
    destroy(admin_cap);
    destroy(maintainer_cap);
    return_shared(usdc_pool);
    return_shared(registry);
    return_shared(pool);
    return_shared(mm);
    (scenario, clock, btc_pool_id, usdc_pool_id, registry_id)
}

/// The gate holds on the upgraded path: a healthy manager is not liquidated, and the
/// vault's funds are untouched. Without this, a broken `can_liquidate` check would
/// drain solvent users through the new entrypoint with nothing to catch it.
#[test]
fun liquidate_quote_upgraded_leaves_a_healthy_manager_alone() {
    let (mut scenario, clock, btc_pool_id, usdc_pool_id, _r) = healthy_manager();

    scenario.next_tx(test_constants::admin());
    let mut vault = liquidation_vault::create_liquidation_vault_for_testing(scenario.ctx());
    let cap = liquidation_vault::create_admin_cap_for_testing(scenario.ctx());
    vault.deposit(
        &cap,
        mint_coin<USDC>(50_000 * test_constants::usdc_multiplier(), scenario.ctx()),
    );
    let funded = vault.balance<USDC>();

    scenario.next_tx(test_constants::admin());
    let mut mm = scenario.take_shared<MarginManager<BTC, USDC>>();
    let mut pool = scenario.take_shared<Pool<BTC, USDC>>();
    let registry = scenario.take_shared<MarginRegistry>();
    let mut btc_pool = scenario.take_shared_by_id<MarginPool<BTC>>(btc_pool_id);
    let mut usdc_pool = scenario.take_shared_by_id<MarginPool<USDC>>(usdc_pool_id);

    // BTC still at $50k, so the manager is nowhere near the liquidation floor.
    let btc = build_btc_price_info_object_upgraded(&mut scenario, 50000, &clock);
    let usdc = build_demo_usdc_price_info_object_upgraded(&mut scenario, &clock);

    vault.liquidate_quote_upgraded<BTC, USDC>(
        &mut mm,
        &registry,
        &btc,
        &usdc,
        &mut btc_pool,
        &mut usdc_pool,
        &mut pool,
        option::none(),
        &clock,
        scenario.ctx(),
    );

    assert!(vault.balance<USDC>() == funded);
    assert!(vault.balance<BTC>() == 0);
    assert!(mm.borrowed_quote_shares() > 0);

    destroy(btc);
    destroy(usdc);
    destroy(vault);
    destroy(cap);
    return_shared(btc_pool);
    return_shared(usdc_pool);
    return_shared(registry);
    return_shared(pool);
    return_shared(mm);
    destroy(clock);
    scenario.end();
}

/// The upgraded entry must read through the *validated* upgraded reader. A stale feed
/// has to abort rather than be tolerated — otherwise the entry would price a
/// liquidation off an arbitrarily old price after the Pyth cutover.
#[test, expected_failure(abort_code = pyth_upgraded::pyth::E_STALE_PRICE_UPDATE)]
fun liquidate_quote_upgraded_rejects_a_stale_feed() {
    let (mut scenario, clock, btc_pool_id, usdc_pool_id, _r) = healthy_manager();

    scenario.next_tx(test_constants::admin());
    let mut vault = liquidation_vault::create_liquidation_vault_for_testing(scenario.ctx());
    let cap = liquidation_vault::create_admin_cap_for_testing(scenario.ctx());
    vault.deposit(
        &cap,
        mint_coin<USDC>(50_000 * test_constants::usdc_multiplier(), scenario.ctx()),
    );

    scenario.next_tx(test_constants::admin());
    let mut mm = scenario.take_shared<MarginManager<BTC, USDC>>();
    let mut pool = scenario.take_shared<Pool<BTC, USDC>>();
    let registry = scenario.take_shared<MarginRegistry>();
    let mut btc_pool = scenario.take_shared_by_id<MarginPool<BTC>>(btc_pool_id);
    let mut usdc_pool = scenario.take_shared_by_id<MarginPool<USDC>>(usdc_pool_id);

    let stale_btc = build_stale_btc_price_info_object_upgraded(&mut scenario, 50000, 600, &clock);
    let usdc = build_demo_usdc_price_info_object_upgraded(&mut scenario, &clock);

    vault.liquidate_quote_upgraded<BTC, USDC>(
        &mut mm,
        &registry,
        &stale_btc,
        &usdc,
        &mut btc_pool,
        &mut usdc_pool,
        &mut pool,
        option::none(),
        &clock,
        scenario.ctx(),
    );

    destroy(stale_btc);
    destroy(usdc);
    destroy(vault);
    destroy(cap);
    return_shared(btc_pool);
    return_shared(usdc_pool);
    return_shared(registry);
    return_shared(pool);
    return_shared(mm);
    destroy(clock);
    scenario.end();
}

/// The legacy entry keeps the same two properties, so the pair cannot drift. This is
/// the coverage `liquidate_quote` never had.
#[test, expected_failure(abort_code = pyth::pyth::E_STALE_PRICE_UPDATE)]
fun liquidate_quote_rejects_a_stale_feed() {
    let (mut scenario, clock, btc_pool_id, usdc_pool_id, _r) = healthy_manager();

    scenario.next_tx(test_constants::admin());
    let mut vault = liquidation_vault::create_liquidation_vault_for_testing(scenario.ctx());
    let cap = liquidation_vault::create_admin_cap_for_testing(scenario.ctx());
    vault.deposit(
        &cap,
        mint_coin<USDC>(50_000 * test_constants::usdc_multiplier(), scenario.ctx()),
    );

    scenario.next_tx(test_constants::admin());
    let mut mm = scenario.take_shared<MarginManager<BTC, USDC>>();
    let mut pool = scenario.take_shared<Pool<BTC, USDC>>();
    let registry = scenario.take_shared<MarginRegistry>();
    let mut btc_pool = scenario.take_shared_by_id<MarginPool<BTC>>(btc_pool_id);
    let mut usdc_pool = scenario.take_shared_by_id<MarginPool<USDC>>(usdc_pool_id);

    let stale_btc = build_stale_btc_price_info_object(&mut scenario, 50000, &clock, 600);
    let usdc = build_demo_usdc_price_info_object(&mut scenario, &clock);

    vault.liquidate_quote<BTC, USDC>(
        &mut mm,
        &registry,
        &stale_btc,
        &usdc,
        &mut btc_pool,
        &mut usdc_pool,
        &mut pool,
        option::none(),
        &clock,
        scenario.ctx(),
    );

    destroy(stale_btc);
    destroy(usdc);
    destroy(vault);
    destroy(cap);
    return_shared(btc_pool);
    return_shared(usdc_pool);
    return_shared(registry);
    return_shared(pool);
    return_shared(mm);
    destroy(clock);
    scenario.end();
}

/// The full settlement path, which nothing else in the package reaches.
///
/// The two `*_rejects_a_stale_feed` tests abort inside `risk_ratio`, and the
/// healthy-manager test returns at the gate — so `settle_quote_liquidation`, the
/// `LiquidationByVault` event fields, and the coin routing back into the vault were
/// entirely unexercised. A transposed `base_out`/`quote_out`, or a repay coin joined
/// into the wrong balance, would ship green.
#[test]
fun liquidate_quote_upgraded_seizes_collateral_and_settles() {
    let (mut scenario, clock, btc_pool_id, usdc_pool_id, _r) = healthy_manager();

    scenario.next_tx(test_constants::admin());
    let mut vault = liquidation_vault::create_liquidation_vault_for_testing(scenario.ctx());
    let cap = liquidation_vault::create_admin_cap_for_testing(scenario.ctx());
    vault.deposit(
        &cap,
        mint_coin<USDC>(50_000 * test_constants::usdc_multiplier(), scenario.ctx()),
    );
    let usdc_before = vault.balance<USDC>();

    scenario.next_tx(test_constants::admin());
    let mut mm = scenario.take_shared<MarginManager<BTC, USDC>>();
    let mut pool = scenario.take_shared<Pool<BTC, USDC>>();
    let registry = scenario.take_shared<MarginRegistry>();
    let mut btc_pool = scenario.take_shared_by_id<MarginPool<BTC>>(btc_pool_id);
    let mut usdc_pool = scenario.take_shared_by_id<MarginPool<USDC>>(usdc_pool_id);
    let shares_before = mm.borrowed_quote_shares();
    assert!(shares_before > 0);

    // 1 BTC of collateral against a 40k USDC loan. At $3,000 the manager holds
    // $43k against $40k of debt - a ratio of 1.075, under the 1.10 floor.
    let btc = build_btc_price_info_object_upgraded(&mut scenario, 3000, &clock);
    let usdc = build_demo_usdc_price_info_object_upgraded(&mut scenario, &clock);

    vault.liquidate_quote_upgraded<BTC, USDC>(
        &mut mm,
        &registry,
        &btc,
        &usdc,
        &mut btc_pool,
        &mut usdc_pool,
        &mut pool,
        option::none(),
        &clock,
        scenario.ctx(),
    );

    // Debt repaid, seized BTC banked, and the USDC actually spent.
    // 87.5% of the loan is repaid: 40,000 -> 5,000 shares.
    assert!(shares_before == 40_000_000_000);
    assert!(mm.borrowed_quote_shares() == 5_000_000_000);

    // The seizure is quote-side, not base-side: the manager's assets are the borrowed
    // USDC plus 1 BTC now worth only $3k, so `calculate_assets` pays out in quote and
    // the vault's BTC balance never moves. The vault ends 700 USDC *up* on the
    // liquidation reward - it spends to repay and is paid more back.
    assert!(vault.balance<BTC>() == 0);
    assert!(usdc_before == 50_000_000_000);
    assert!(vault.balance<USDC>() == 50_700_000_000);

    // The event the off-chain engine accounts from. `base_liquidation: false` and the
    // `quote_in` side carrying the spend are the discriminators; flipping either
    // mis-reports every liquidation downstream while the balances still look right.
    let events = sui::event::events_by_type<LiquidationByVault>();
    assert!(events.length() == 1);
    let (
        base_in,
        quote_in,
        _base_out,
        _quote_out,
        _remaining,
        base_liquidation,
    ) = liquidation_vault::liquidation_event_fields(&events[0]);
    assert!(!base_liquidation);
    assert!(base_in == 0);
    assert!(quote_in > 0);

    destroy(btc);
    destroy(usdc);
    destroy(vault);
    destroy(cap);
    return_shared(btc_pool);
    return_shared(usdc_pool);
    return_shared(registry);
    return_shared(pool);
    return_shared(mm);
    destroy(clock);
    scenario.end();
}

/// The legacy entry on the same fixture at the same prices must settle to exactly the
/// same numbers as its upgraded twin above. Asserting identical literals in both tests
/// is what makes the twin invariant executable: `scripts/check_upgraded_parity.py`
/// compares signatures, this compares outcomes. Change one body and one test breaks.
#[test]
fun liquidate_quote_settles_the_same_numbers_on_the_legacy_generation() {
    let (mut scenario, clock, btc_pool_id, usdc_pool_id, _r) = healthy_manager();

    scenario.next_tx(test_constants::admin());
    let mut vault = liquidation_vault::create_liquidation_vault_for_testing(scenario.ctx());
    let cap = liquidation_vault::create_admin_cap_for_testing(scenario.ctx());
    vault.deposit(
        &cap,
        mint_coin<USDC>(50_000 * test_constants::usdc_multiplier(), scenario.ctx()),
    );

    scenario.next_tx(test_constants::admin());
    let mut mm = scenario.take_shared<MarginManager<BTC, USDC>>();
    let mut pool = scenario.take_shared<Pool<BTC, USDC>>();
    let registry = scenario.take_shared<MarginRegistry>();
    let mut btc_pool = scenario.take_shared_by_id<MarginPool<BTC>>(btc_pool_id);
    let mut usdc_pool = scenario.take_shared_by_id<MarginPool<USDC>>(usdc_pool_id);
    let shares_before = mm.borrowed_quote_shares();

    let btc = build_btc_price_info_object(&mut scenario, 3000, &clock);
    let usdc = build_demo_usdc_price_info_object(&mut scenario, &clock);

    vault.liquidate_quote<BTC, USDC>(
        &mut mm,
        &registry,
        &btc,
        &usdc,
        &mut btc_pool,
        &mut usdc_pool,
        &mut pool,
        option::none(),
        &clock,
        scenario.ctx(),
    );

    // Identical to `liquidate_quote_upgraded_seizes_collateral_and_settles`.
    assert!(shares_before == 40_000_000_000);
    assert!(mm.borrowed_quote_shares() == 5_000_000_000);
    assert!(vault.balance<BTC>() == 0);
    assert!(vault.balance<USDC>() == 50_700_000_000);

    destroy(btc);
    destroy(usdc);
    destroy(vault);
    destroy(cap);
    return_shared(btc_pool);
    return_shared(usdc_pool);
    return_shared(registry);
    return_shared(pool);
    return_shared(mm);
    destroy(clock);
    scenario.end();
}
