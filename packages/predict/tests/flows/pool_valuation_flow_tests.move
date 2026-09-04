// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Flow coverage for the staged pool NAV flush (`start_pool_valuation` opens the
/// atomic snapshot stage under the `SnapshotStage` potato, `seal_valuation_snapshot`
/// closes it, per-market `value_expiry` transactions fold each frozen mark in, and
/// `finish_flush` proves completeness before draining the LP queues) and its
/// unified per-market cash flush. Tests build production-valid markets through the
/// real creation + funding path, then assert: the aggregated pool NAV equals an
/// independently assembled reference from the vault's ledger fields and per-market
/// `current_nav`, valuation split across transactions marks at the snapshot
/// instant, the exactly-once completeness proof fires on a missed / double-valued
/// market, and the valuation flag gates keeper cash ops, market creation, and
/// settlement of a snapshotted-but-unvalued market — trading itself stays open
/// during a flush and is covered separately. Passive settled-market sweep and
/// pending-profit exclusion coverage live in `settlement_flow_tests` and
/// `protocol_profit_deferral_tests`.
#[test_only]
module deepbook_predict::pool_valuation_flow_tests;

use deepbook_predict::{
    admin,
    block_scholes_feed::BlockScholesFeed,
    config_constants,
    constants,
    expiry_market::{Self, ExpiryMarket},
    flow_test_helpers as helpers,
    plp::{Self, PoolVault},
    pricing,
    pricing_reference_data as ref_data,
    protocol_config::{Self, ProtocolConfig},
    range_codec,
    test_constants,
    vault_events
};
use fixed_math::math::{Self, float_scaling as float};
use propbook::{pyth_feed::PythFeed, registry::OracleRegistry};
use std::unit_test::{assert_eq, destroy};
use sui::{event, test_scenario::return_shared};

/// Standard ATM up-range quantity, well under the 50e9 cash floor that backs it.
const STANDARD_QUANTITY: u64 = 2_000_000_000;
/// Idle seed large enough to fund several markets to the cash floor.
const IDLE_SEED: u64 = 1_200_000_000_000;
/// Expiry inside the finish window: the clock starts at 120_000 and the window ships
/// at 5 minutes, so a member with this expiry can cross it, settle, and be swept while
/// the flush is still open.
const MID_FLUSH_EXPIRY_MS: u64 = 360_000;
/// `value_expiry` sweeps each minted market back to its 10e9 cash target, so each
/// market's NAV is that target less its live liability, and the
/// swept premium plus fees land in idle. Both markets are identical, so the two
/// sides of the aggregation are pinned against each other and the pool mark is
/// pinned against the ledger fields — none of it restates the digital, which is
/// checked independently at each mint.
const MARKET_CASH_TARGET: u64 = 10_000_000_000;
const MINT_MIN_FEE: u64 = 10_000_000;
/// Leave exactly 1e9 idle after funding a 250e9 expiry. With 251e9 PLP supply,
/// that mark is a very low but executable fair PLP price.
const BELOW_MIN_PRICE_IDLE: u64 = 1_000_000_000;
/// Large order used to drive a fully-funded market underwater after a price jump.
const UNDERWATER_QUANTITY: u64 = 500_000_000_000;
/// Allocation that leaves the market's cash EXACTLY equal to the liability the
/// deep-ITM reprice creates, so the market contributes a zero NAV. This is a
/// knife edge by necessity: the mint's backing requirement and the
/// deep-ITM liability are the same number, so cash below it cannot be minted and
/// cash above it cannot value to zero. It is `UNDERWATER_QUANTITY` minus the
/// at-the-money premium. This is a fixture INPUT, tuned to the exact integer the
/// fixed-point pricer lands on (one unit above the true digital, well inside the
/// documented budget) the same way a quantity is tuned to the lot size — the
/// price itself is checked independently against `pricing_reference_data` before
/// the mint, and the `cash_balance == UNDERWATER_QUANTITY` assertion below makes
/// the tuning self-verifying rather than a silent assumption.
const UNDERWATER_MARKET_ALLOCATION: u64 = 250_003_154_500;
const UNDERWATER_TRADER_DEPOSIT: u64 = 400_000_000_000;
const DEEP_ITM_LIVE_PRICE: u64 = 1_000_000_000_000;
const REPRICE_MS: u64 = 121_000;
const REPRICE_SOURCE_TS: u64 = 119_500;
/// Empty-market cash above the 10e9 target. Valuation sweeps the 1e9 surplus to
/// idle and leaves 10e9 active NAV. With the protocol's 10% profit exclusion on
/// the 11e9 active+returned credit basis, the frozen LP mark is 9.91e9.
const ABOVE_MAX_PRICE_MARKET_CASH: u64 = 11_000_000_000;
const ABOVE_MAX_PRICE_POOL_NAV: u64 = 9_910_000_000;
/// Adjacent $10-grid ticks whose committed scenario-0 UP prices rise by one raw
/// unit, and a shared upper boundary near that surface's forward.
const DUST_LOWER_TICK: u64 = 55_240;
const DUST_HIGHER_TICK: u64 = 55_250;
const DUST_SHARED_TICK: u64 = 75_800;
const DUST_QUANTITY: u64 = 2_000_000_000;
/// The first provider-native magnitude that cannot be represented by Predict's u64 pricing domain.
const FIRST_UNREPRESENTABLE_U64: u128 = 18_446_744_073_709_551_616;

// === Happy path: aggregation ===

#[test]
fun multi_market_pool_nav_is_idle_plus_sum_of_navs() {
    let mut fx = helpers::setup_market_default();
    let trader = fx.create_funded_manager(test_constants::default_manager_deposit());
    bootstrap_pool(&mut fx, IDLE_SEED);
    let e1 = fx.create_expiry(test_constants::default_expiry_ms());
    let e2 = fx.create_expiry(test_constants::default_expiry_ms() + 86_400_000);
    let premium = fund_market_with_order(&mut fx, &trader, e1);
    assert_eq!(fund_market_with_order(&mut fx, &trader, e2), premium);

    fx.scenario_mut().next_tx(test_constants::alice());
    let mut config = fx.scenario_mut().take_shared<ProtocolConfig>();
    let pyth = fx.scenario_mut().take_shared_by_id<PythFeed>(fx.pyth_id());
    let bs = fx.take_bs();
    let oracle_registry = fx.scenario_mut().take_shared<OracleRegistry>();
    let mut vault = fx.scenario_mut().take_shared_by_id<PoolVault>(fx.vault_id());
    let mut m1 = fx.scenario_mut().take_shared_by_id<ExpiryMarket>(e1);
    let mut m2 = fx.scenario_mut().take_shared_by_id<ExpiryMarket>(e2);

    // Cash maintenance is decoupled from the flush: the keeper rebalances each
    // market to its band BEFORE starting; the flush itself moves no live cash.
    fx.rebalance_expiry_cash(&mut vault, &mut m1, &config);
    fx.rebalance_expiry_cash(&mut vault, &mut m2, &config);
    let stage = fx.start_flush(&mut config, &mut vault);
    fx.snapshot_expiry_pricer(&stage, &mut vault, &mut m1, &config, &oracle_registry, &pyth, &bs);
    fx.snapshot_expiry_pricer(&stage, &mut vault, &mut m2, &config, &oracle_registry, &pyth, &bs);
    helpers::seal_snapshot(stage, &mut vault, &mut config);
    fx.value_expiry(&mut vault, &mut m1, &config);
    fx.value_expiry(&mut vault, &mut m2, &config);
    let pool_nav = fx.finish_flush(&mut vault, &mut config);

    // Every expected value below is built from the fixture's own arithmetic and
    // the mint premium, which was checked against the independent reference at
    // mint time — nothing is read back out of the vault to predict itself.
    //
    // An order's live worth is the same product as its premium, so a swept
    // market holds its cash target less that worth.
    let expected_nav = MARKET_CASH_TARGET - premium;
    let mint_cost = premium + MINT_MIN_FEE;
    let nav1 = fx.current_nav(&m1, &config, &oracle_registry, &pyth, &bs);
    let nav2 = fx.current_nav(&m2, &config, &oracle_registry, &pyth, &bs);
    assert_eq!(nav1, expected_nav);
    assert_eq!(nav2, expected_nav);

    // Each market swept its premium and fee to idle; the funding it drew is the
    // debit side of the profit basis.
    assert_eq!(vault.profit_basis_credits(), 2 * mint_cost);
    assert_eq!(vault.profit_basis_debits(), 2 * MARKET_CASH_TARGET);
    assert_eq!(vault.idle_balance(), IDLE_SEED - 2 * MARKET_CASH_TARGET + 2 * mint_cost);
    assert_eq!(vault.pending_protocol_profit(), 0);

    // The pool mark is gross value less the protocol's share of realised profit.
    // This is the one line that mirrors `lp_pool_value`; every input to it is
    // pinned above against fixture arithmetic, so the composition is all that is
    // taken from the implementation.
    let active = 2 * expected_nav;
    let expected_exclusion = math::mul_down(
        2 * mint_cost + active - 2 * MARKET_CASH_TARGET,
        config_constants::default_protocol_reserve_profit_share!(),
    );
    assert_eq!(
        pool_nav,
        IDLE_SEED - 2 * MARKET_CASH_TARGET + 2 * mint_cost + active - expected_exclusion,
    );

    return_shared(config);
    return_shared(pyth);
    helpers::return_bs(bs);
    return_shared(oracle_registry);
    return_shared(vault);
    return_shared(m1);
    return_shared(m2);
    fx.finish();
}

#[test]
fun multi_market_pool_nav_is_exact_with_a_mid_flush_rebalance() {
    let mut fx = helpers::setup_market_default();
    let trader = fx.create_funded_manager(test_constants::default_manager_deposit());
    bootstrap_pool(&mut fx, IDLE_SEED);
    let e1 = fx.create_expiry(test_constants::default_expiry_ms());
    let e2 = fx.create_expiry(test_constants::default_expiry_ms() + 86_400_000);
    let premium = fund_market_with_order(&mut fx, &trader, e1);
    assert_eq!(fund_market_with_order(&mut fx, &trader, e2), premium);

    fx.scenario_mut().next_tx(test_constants::alice());
    let mut config = fx.scenario_mut().take_shared<ProtocolConfig>();
    let pyth = fx.scenario_mut().take_shared_by_id<PythFeed>(fx.pyth_id());
    let bs = fx.take_bs();
    let oracle_registry = fx.scenario_mut().take_shared<OracleRegistry>();
    let mut vault = fx.scenario_mut().take_shared_by_id<PoolVault>(fx.vault_id());
    let mut m1 = fx.scenario_mut().take_shared_by_id<ExpiryMarket>(e1);
    let mut m2 = fx.scenario_mut().take_shared_by_id<ExpiryMarket>(e2);

    // m1 rebalances BEFORE the window, m2 DURING it: m2's in-window move lands
    // after its stamp and the seal, so it cannot reach the mark, and every exact
    // expected value below must be identical to the rebalance-before-the-window
    // case.
    fx.rebalance_expiry_cash(&mut vault, &mut m1, &config);
    let stage = fx.start_flush(&mut config, &mut vault);
    fx.snapshot_expiry_pricer(&stage, &mut vault, &mut m1, &config, &oracle_registry, &pyth, &bs);
    fx.snapshot_expiry_pricer(&stage, &mut vault, &mut m2, &config, &oracle_registry, &pyth, &bs);
    helpers::seal_snapshot(stage, &mut vault, &mut config);
    fx.value_expiry(&mut vault, &mut m1, &config);
    // Mid-window maintenance on the still-pending m2, guarded as a real move.
    let idle_before = vault.idle_balance();
    fx.rebalance_expiry_cash(&mut vault, &mut m2, &config);
    assert!(vault.idle_balance() != idle_before);
    fx.value_expiry(&mut vault, &mut m2, &config);
    let pool_nav = fx.finish_flush(&mut vault, &mut config);

    // Every expected value below is built from the fixture's own arithmetic and
    // the mint premium, which was checked against the independent reference at
    // mint time — nothing is read back out of the vault to predict itself.
    //
    // An order's live worth is the same product as its premium, so a swept
    // market holds its cash target less that worth.
    let expected_nav = MARKET_CASH_TARGET - premium;
    let mint_cost = premium + MINT_MIN_FEE;
    let nav1 = fx.current_nav(&m1, &config, &oracle_registry, &pyth, &bs);
    let nav2 = fx.current_nav(&m2, &config, &oracle_registry, &pyth, &bs);
    assert_eq!(nav1, expected_nav);
    assert_eq!(nav2, expected_nav);

    // Each market swept its premium and fee to idle; the funding it drew is the
    // debit side of the profit basis.
    assert_eq!(vault.profit_basis_credits(), 2 * mint_cost);
    assert_eq!(vault.profit_basis_debits(), 2 * MARKET_CASH_TARGET);
    assert_eq!(vault.idle_balance(), IDLE_SEED - 2 * MARKET_CASH_TARGET + 2 * mint_cost);
    assert_eq!(vault.pending_protocol_profit(), 0);

    // The pool mark is gross value less the protocol's share of realised profit.
    // This is the one line that mirrors `lp_pool_value`; every input to it is
    // pinned above against fixture arithmetic, so the composition is all that is
    // taken from the implementation.
    let active = 2 * expected_nav;
    let expected_exclusion = math::mul_down(
        2 * mint_cost + active - 2 * MARKET_CASH_TARGET,
        config_constants::default_protocol_reserve_profit_share!(),
    );
    assert_eq!(
        pool_nav,
        IDLE_SEED - 2 * MARKET_CASH_TARGET + 2 * mint_cost + active - expected_exclusion,
    );

    return_shared(config);
    return_shared(pyth);
    helpers::return_bs(bs);
    return_shared(oracle_registry);
    return_shared(vault);
    return_shared(m1);
    return_shared(m2);
    fx.finish();
}

#[test]
fun empty_funded_markets_pool_nav_equals_total_idle() {
    let mut fx = helpers::setup_market_default();
    let _trader = fx.create_funded_manager(0);
    bootstrap_pool(&mut fx, IDLE_SEED);
    let e1 = fx.create_expiry(test_constants::default_expiry_ms());
    let e2 = fx.create_expiry(test_constants::default_expiry_ms() + 86_400_000);
    fund_empty_market(&mut fx, e1);
    fund_empty_market(&mut fx, e2);

    fx.scenario_mut().next_tx(test_constants::admin());
    let mut config = fx.scenario_mut().take_shared<ProtocolConfig>();
    let pyth = fx.scenario_mut().take_shared_by_id<PythFeed>(fx.pyth_id());
    let bs = fx.take_bs();
    let oracle_registry = fx.scenario_mut().take_shared<OracleRegistry>();
    let mut vault = fx.scenario_mut().take_shared_by_id<PoolVault>(fx.vault_id());
    let mut m1 = fx.scenario_mut().take_shared_by_id<ExpiryMarket>(e1);
    let mut m2 = fx.scenario_mut().take_shared_by_id<ExpiryMarket>(e2);

    let stage = fx.start_flush(&mut config, &mut vault);
    fx.snapshot_expiry_pricer(&stage, &mut vault, &mut m1, &config, &oracle_registry, &pyth, &bs);
    fx.snapshot_expiry_pricer(&stage, &mut vault, &mut m2, &config, &oracle_registry, &pyth, &bs);
    helpers::seal_snapshot(stage, &mut vault, &mut config);
    fx.value_expiry(&mut vault, &mut m1, &config);
    fx.value_expiry(&mut vault, &mut m2, &config);
    let pool_nav = fx.finish_flush(&mut vault, &mut config);

    // Each funded empty market holds exactly the cash floor as NAV (no liability),
    // so the entire pool NAV is the total idle originally seeded (cash conserved).
    assert_eq!(
        fx.current_nav(&m1, &config, &oracle_registry, &pyth, &bs),
        constants::expiry_cash_floor!(),
    );
    assert_eq!(
        fx.current_nav(&m2, &config, &oracle_registry, &pyth, &bs),
        constants::expiry_cash_floor!(),
    );
    assert_eq!(vault.profit_basis_debits(), 2 * constants::expiry_cash_floor!());
    assert_eq!(vault.profit_basis_credits(), 0);
    assert_eq!(pool_nav, IDLE_SEED);

    return_shared(config);
    return_shared(pyth);
    helpers::return_bs(bs);
    return_shared(oracle_registry);
    return_shared(vault);
    return_shared(m1);
    return_shared(m2);
    fx.finish();
}

#[test]
fun empty_pool_valuation_returns_idle() {
    let idle_seed = constants::min_supply_request!();
    let mut fx = helpers::setup_market_default();
    let _trader = fx.create_funded_manager(0);
    bootstrap_pool(&mut fx, idle_seed);

    fx.scenario_mut().next_tx(test_constants::admin());
    let mut config = fx.scenario_mut().take_shared<ProtocolConfig>();
    let mut vault = fx.scenario_mut().take_shared_by_id<PoolVault>(fx.vault_id());

    // No active markets: start, seal an empty snapshot, then finish with no value
    // steps returns idle.
    let stage = fx.start_flush(&mut config, &mut vault);
    helpers::seal_snapshot(stage, &mut vault, &mut config);
    let pool_nav = fx.finish_flush(&mut vault, &mut config);
    assert_eq!(pool_nav, idle_seed);

    return_shared(config);
    return_shared(vault);
    fx.finish();
}

// === Oracle-width propagation and recovery ===

/// Freezing the pricer is the mandatory per-market leg of a pool-wide flush, so an over-wide
/// active market observation must surface the named pricing-boundary error there rather than a
/// VM cast. The oracle read happens in the atomic snapshot stage rather than in `value_expiry`,
/// so the abort lands inside the flush's first transaction.
#[test, expected_failure(abort_code = pricing::EBlockScholesInputTooWide)]
fun overwide_block_scholes_spot_aborts_pool_valuation_flush() {
    let mut fx = helpers::setup_market_default();
    bootstrap_pool(&mut fx, IDLE_SEED);
    let e = new_funded_empty_market(&mut fx, test_constants::default_expiry_ms());

    fx.scenario_mut().next_tx(test_constants::admin());
    let mut market = fx.take_market_bundle(e);
    fx.set_bs_spot_raw_for_testing_bundle(
        &mut market,
        test_constants::live_source_timestamp_ms() + 1,
        FIRST_UNREPRESENTABLE_U64,
    );

    fx.start_flush_bundle(&mut market);
    abort 999
}

/// A newer representable observation replaces the rejected provider row and restores the same
/// mandatory valuation path without configuration or package changes.
#[test]
fun newer_representable_block_scholes_spot_restores_pool_valuation_flush() {
    let mut fx = helpers::setup_market_default();
    bootstrap_pool(&mut fx, IDLE_SEED);
    let e = new_funded_empty_market(&mut fx, test_constants::default_expiry_ms());

    fx.scenario_mut().next_tx(test_constants::admin());
    let mut market = fx.take_market_bundle(e);
    let overwide_timestamp_ms = test_constants::live_source_timestamp_ms() + 1;
    fx.set_bs_spot_raw_for_testing_bundle(
        &mut market,
        overwide_timestamp_ms,
        FIRST_UNREPRESENTABLE_U64,
    );
    fx.prepare_live_oracle_bundle_at(
        &mut market,
        test_constants::default_live_price(),
        overwide_timestamp_ms + 1,
    );

    fx.start_flush_bundle(&mut market);
    fx.value_expiry_bundle(&mut market);
    let pool_nav = fx.finish_flush_bundle(&mut market);
    assert_eq!(pool_nav, IDLE_SEED);

    helpers::return_market_bundle(market);
    fx.finish();
}

/// A book carrying the pricer's own fixed-point dust must not stall the flush.
///
/// Regression for the reachable-abort class: two ordinary wide ranges, admitted on
/// the market's own $10 grid and quoted near a coin flip, put adjacent boundaries
/// either side of a one-unit UP-price rise on committed real scenario 0 — a valid,
/// butterfly-free provider surface. Before `price_monotonicity_tolerance` this
/// aborted `value_expiry`, and because `finish_flush` proves completeness over the
/// snapshotted set with no skip, the pool-wide flush stalled until the market
/// expired. The live NAV read the SDK composes aborted with it.
#[test]
fun a_fixed_point_dust_inversion_does_not_stall_the_flush() {
    let mut fx = helpers::setup_market_default();
    fx.bootstrap_lock(IDLE_SEED);
    let e = fx.create_expiry(test_constants::default_expiry_ms());
    let trader = fx.create_funded_manager(test_constants::default_manager_deposit());

    fx.scenario_mut().next_tx(test_constants::alice());
    let mut market = fx.take_market_bundle(e);
    let mut account = fx.take_account_bundle(&trader);
    fx.prepare_live_oracle_bundle(&mut market, test_constants::default_live_price());
    fx.rebalance_expiry_cash_bundle(&mut market);
    seed_real_scenario_surface(&mut fx, &mut market);

    // Both ranges are ordinary: on the admission grid, and priced near 0.5.
    let quote = fx.quote_mint_bundle(&market, DUST_LOWER_TICK, DUST_SHARED_TICK, DUST_QUANTITY);
    assert!(quote.entry_probability() > 400_000_000);
    assert!(quote.entry_probability() < 600_000_000);
    let id_low = fx.mint_bundle(
        &mut market,
        &mut account,
        DUST_LOWER_TICK,
        DUST_SHARED_TICK,
        DUST_QUANTITY,
    );
    let id_high = fx.mint_bundle(
        &mut market,
        &mut account,
        DUST_HIGHER_TICK,
        DUST_SHARED_TICK,
        DUST_QUANTITY,
    );
    helpers::return_account_bundle(account);

    // The two lower boundaries invert, so this book drives the guard.
    let pricer = fx.load_pricer_bundle(&market);
    assert!(
        pricer.up_price(range_codec::strike_from_tick(DUST_HIGHER_TICK, test_constants::default_tick_size()))
            > pricer.up_price(range_codec::strike_from_tick(DUST_LOWER_TICK, test_constants::default_tick_size())),
    );

    // Live NAV is free cash less the independent per-order sum (`live_order_value`
    // prices each order through `range_price`, not the walk's `up_price`).
    let per_order_liability =
        fx.live_order_value_bundle(&market, id_low) + fx.live_order_value_bundle(&market, id_high);
    let free_cash =
        helpers::market(&market).cash_balance() - helpers::market(&market).inventory_impact_reserve();
    assert_eq!(fx.current_nav_bundle(&market), free_cash - per_order_liability);

    // ... and the flush runs to completion over that same book.
    fx.start_flush_bundle(&mut market);
    fx.value_expiry_bundle(&mut market);
    let pool_nav = fx.finish_flush_bundle(&mut market);
    assert!(pool_nav > 0);

    helpers::return_market_bundle(market);
    fx.finish();
}

// === Completeness proof ===

#[test, expected_failure(abort_code = plp::EMissingExpiryValuation)]
fun finish_aborts_when_a_snapshotted_market_is_unvalued() {
    let mut fx = helpers::setup_market_default();
    let _trader = fx.create_funded_manager(0);
    bootstrap_pool(&mut fx, IDLE_SEED);
    let e1 = fx.create_expiry(test_constants::default_expiry_ms());
    let e2 = fx.create_expiry(test_constants::default_expiry_ms() + 86_400_000);
    fund_empty_market(&mut fx, e1);
    fund_empty_market(&mut fx, e2);

    fx.scenario_mut().next_tx(test_constants::admin());
    let mut config = fx.scenario_mut().take_shared<ProtocolConfig>();
    let pyth = fx.scenario_mut().take_shared_by_id<PythFeed>(fx.pyth_id());
    let bs = fx.take_bs();
    let oracle_registry = fx.scenario_mut().take_shared<OracleRegistry>();
    let mut vault = fx.scenario_mut().take_shared_by_id<PoolVault>(fx.vault_id());
    let mut m1 = fx.scenario_mut().take_shared_by_id<ExpiryMarket>(e1);
    let mut m2 = fx.scenario_mut().take_shared_by_id<ExpiryMarket>(e2);

    // Both markets sealed into the snapshot, then only one valued.
    let stage = fx.start_flush(&mut config, &mut vault);
    fx.snapshot_expiry_pricer(&stage, &mut vault, &mut m1, &config, &oracle_registry, &pyth, &bs);
    fx.snapshot_expiry_pricer(&stage, &mut vault, &mut m2, &config, &oracle_registry, &pyth, &bs);
    helpers::seal_snapshot(stage, &mut vault, &mut config);
    fx.value_expiry(&mut vault, &mut m1, &config);
    let _ = fx.finish_flush(&mut vault, &mut config);

    abort 999
}

#[test]
fun a_member_deactivated_mid_flush_still_folds_its_frozen_mark() {
    // Settlement is not gated by the flush, so a member can cross its expiry, settle,
    // and have its standalone settled sweep DEACTIVATE it while the flush is open —
    // it leaves the live active set mid-window. The flush's expected set was committed
    // at the snapshot, so the departed member must still be valued and its frozen mark
    // must still reach the pool mark. Mark invariance under settlement is pinned
    // separately, with real positions, in `valuation_corrections_tests`; what this pins
    // is that the expected SET does not drift when the live active set shrinks.
    let mut fx = helpers::setup_market_default();
    let _trader = fx.create_funded_manager(0);
    bootstrap_pool(&mut fx, IDLE_SEED);
    let e1 = fx.create_expiry(MID_FLUSH_EXPIRY_MS);
    let e2 = fx.create_expiry(test_constants::default_expiry_ms());
    fund_empty_market(&mut fx, e1);
    fund_empty_market(&mut fx, e2);

    fx.scenario_mut().next_tx(test_constants::admin());
    let mut config = fx.scenario_mut().take_shared<ProtocolConfig>();
    let mut pyth = fx.scenario_mut().take_shared_by_id<PythFeed>(fx.pyth_id());
    let bs = fx.take_bs();
    let oracle_registry = fx.scenario_mut().take_shared<OracleRegistry>();
    let mut vault = fx.scenario_mut().take_shared_by_id<PoolVault>(fx.vault_id());
    let mut m1 = fx.scenario_mut().take_shared_by_id<ExpiryMarket>(e1);
    let mut m2 = fx.scenario_mut().take_shared_by_id<ExpiryMarket>(e2);

    let stage = fx.start_flush(&mut config, &mut vault);
    fx.snapshot_expiry_pricer(&stage, &mut vault, &mut m1, &config, &oracle_registry, &pyth, &bs);
    fx.snapshot_expiry_pricer(&stage, &mut vault, &mut m2, &config, &oracle_registry, &pyth, &bs);
    helpers::seal_snapshot(stage, &mut vault, &mut config);

    // m1 crosses its expiry inside the window, settles, and is swept out of the
    // active set. m2 is untouched and values live.
    fx.set_clock_for_testing(MID_FLUSH_EXPIRY_MS + 1);
    fx.insert_exact_settlement_spot(
        &mut pyth,
        MID_FLUSH_EXPIRY_MS,
        test_constants::default_live_price(),
    );
    assert!(fx.try_settle(&mut m1, &config, &oracle_registry, &pyth, bs.values()));
    fx.rebalance_expiry_cash(&mut vault, &mut m1, &config);
    // Guard: the deactivation is real, so the assertion below is about a member the
    // live active set no longer names.
    let active = vault.active_expiry_markets();
    assert!(!active.contains(&e1));
    assert!(active.contains(&e2));

    fx.value_expiry(&mut vault, &mut m1, &config);
    fx.value_expiry(&mut vault, &mut m2, &config);
    let pool_nav = fx.finish_flush(&mut vault, &mut config);

    // Both frozen marks land. Each funded empty market marks at the cash floor, and
    // the mark reads the idle frozen at the seal, so the cash m1's sweep returned to
    // live idle is counted exactly once — the same total as the undisturbed
    // two-market case in `empty_funded_markets_pool_nav_equals_total_idle`. Dropping
    // the deactivated member's mark would land one cash floor short of this.
    assert_eq!(pool_nav, IDLE_SEED);

    return_shared(config);
    return_shared(pyth);
    helpers::return_bs(bs);
    return_shared(oracle_registry);
    return_shared(vault);
    return_shared(m1);
    return_shared(m2);
    fx.finish();
}

#[test, expected_failure(abort_code = plp::EMissingExpiryValuation)]
fun finish_aborts_when_a_member_deactivated_mid_flush_is_unvalued() {
    // The sharp form of the above: a member that settled and was swept out of the
    // active set mid-window is still owed a `value_expiry`. If the completeness proof
    // re-derived its expected set from the LIVE active set instead of the set committed
    // at the snapshot, valuing only the surviving member would finish cleanly here and
    // silently drop the departed member's mark from the pool NAV.
    let mut fx = helpers::setup_market_default();
    let _trader = fx.create_funded_manager(0);
    bootstrap_pool(&mut fx, IDLE_SEED);
    let e1 = fx.create_expiry(MID_FLUSH_EXPIRY_MS);
    let e2 = fx.create_expiry(test_constants::default_expiry_ms());
    fund_empty_market(&mut fx, e1);
    fund_empty_market(&mut fx, e2);

    fx.scenario_mut().next_tx(test_constants::admin());
    let mut config = fx.scenario_mut().take_shared<ProtocolConfig>();
    let mut pyth = fx.scenario_mut().take_shared_by_id<PythFeed>(fx.pyth_id());
    let bs = fx.take_bs();
    let oracle_registry = fx.scenario_mut().take_shared<OracleRegistry>();
    let mut vault = fx.scenario_mut().take_shared_by_id<PoolVault>(fx.vault_id());
    let mut m1 = fx.scenario_mut().take_shared_by_id<ExpiryMarket>(e1);
    let mut m2 = fx.scenario_mut().take_shared_by_id<ExpiryMarket>(e2);

    let stage = fx.start_flush(&mut config, &mut vault);
    fx.snapshot_expiry_pricer(&stage, &mut vault, &mut m1, &config, &oracle_registry, &pyth, &bs);
    fx.snapshot_expiry_pricer(&stage, &mut vault, &mut m2, &config, &oracle_registry, &pyth, &bs);
    helpers::seal_snapshot(stage, &mut vault, &mut config);

    fx.set_clock_for_testing(MID_FLUSH_EXPIRY_MS + 1);
    fx.insert_exact_settlement_spot(
        &mut pyth,
        MID_FLUSH_EXPIRY_MS,
        test_constants::default_live_price(),
    );
    assert!(fx.try_settle(&mut m1, &config, &oracle_registry, &pyth, bs.values()));
    fx.rebalance_expiry_cash(&mut vault, &mut m1, &config);
    let active = vault.active_expiry_markets();
    assert!(!active.contains(&e1));

    // Only the surviving member is valued.
    fx.value_expiry(&mut vault, &mut m2, &config);
    let _ = fx.finish_flush(&mut vault, &mut config);

    abort 999
}

/// C-1: valuation spread across transactions must mark the pool exactly as a
/// single-transaction flush would have at the snapshot instant.
///
/// The oracle is deliberately moved between the two `value_expiry` transactions. If
/// the second market re-read live oracle state instead of its frozen `Pricer`, its
/// NAV — and the pool mark — would shift off the snapshot instant, which is exactly
/// the audit-L10 single-mark property. The expected value is the same independent
/// fixture arithmetic the single-transaction test asserts, so the two are pinned to
/// one number, not to each other.
#[test]
fun valuation_split_across_transactions_marks_at_the_snapshot_instant() {
    let mut fx = helpers::setup_market_default();
    let trader = fx.create_funded_manager(test_constants::default_manager_deposit());
    bootstrap_pool(&mut fx, IDLE_SEED);
    let e1 = fx.create_expiry(test_constants::default_expiry_ms());
    let e2 = fx.create_expiry(test_constants::default_expiry_ms() + 86_400_000);
    let premium = fund_market_with_order(&mut fx, &trader, e1);
    assert_eq!(fund_market_with_order(&mut fx, &trader, e2), premium);

    fx.scenario_mut().next_tx(test_constants::alice());
    let mut config = fx.scenario_mut().take_shared<ProtocolConfig>();
    let mut pyth = fx.scenario_mut().take_shared_by_id<PythFeed>(fx.pyth_id());
    let bs = fx.take_bs();
    let oracle_registry = fx.scenario_mut().take_shared<OracleRegistry>();
    let mut vault = fx.scenario_mut().take_shared_by_id<PoolVault>(fx.vault_id());
    let mut m1 = fx.scenario_mut().take_shared_by_id<ExpiryMarket>(e1);
    let mut m2 = fx.scenario_mut().take_shared_by_id<ExpiryMarket>(e2);

    // Snapshot stage: one atomic transaction, both markets frozen at one instant.
    let stage = fx.start_flush(&mut config, &mut vault);
    fx.snapshot_expiry_pricer(&stage, &mut vault, &mut m1, &config, &oracle_registry, &pyth, &bs);
    fx.snapshot_expiry_pricer(&stage, &mut vault, &mut m2, &config, &oracle_registry, &pyth, &bs);
    helpers::seal_snapshot(stage, &mut vault, &mut config);

    // Valuation stage, transaction 1 of 2.
    fx.value_expiry(&mut vault, &mut m1, &config);

    // Move the oracle between valuation transactions.
    fx.scenario_mut().next_tx(test_constants::alice());
    let now_ms = fx.clock().timestamp_ms();
    fx.set_pyth_price_for_testing(&mut pyth, test_constants::default_live_price() * 2, now_ms);

    // Guard against a vacuous test: prove the move is load-bearing. A pricer loaded
    // live at this moment marks m2 differently from its frozen one, so if
    // `value_expiry` re-read the oracle the pool mark below could not still match.
    let expected_nav = MARKET_CASH_TARGET - premium;
    let live_nav_after_move = fx.current_nav(&m2, &config, &oracle_registry, &pyth, &bs);
    assert!(live_nav_after_move != expected_nav);

    // Valuation stage, transaction 2 of 2 — priced off the frozen snapshot.
    fx.value_expiry(&mut vault, &mut m2, &config);

    fx.scenario_mut().next_tx(test_constants::alice());
    let pool_nav = fx.finish_flush(&mut vault, &mut config);

    let mint_cost = premium + MINT_MIN_FEE;
    let active = 2 * expected_nav;
    let expected_exclusion = math::mul_down(
        2 * mint_cost + active - 2 * MARKET_CASH_TARGET,
        config_constants::default_protocol_reserve_profit_share!(),
    );
    assert_eq!(
        pool_nav,
        IDLE_SEED - 2 * MARKET_CASH_TARGET + 2 * mint_cost + active - expected_exclusion,
    );

    return_shared(config);
    return_shared(pyth);
    helpers::return_bs(bs);
    return_shared(oracle_registry);
    return_shared(vault);
    return_shared(m1);
    return_shared(m2);
    fx.finish();
}

#[test, expected_failure(abort_code = plp::EIncompleteValuationSnapshot)]
fun seal_aborts_when_an_active_market_has_no_frozen_pricer() {
    let mut fx = helpers::setup_market_default();
    let _trader = fx.create_funded_manager(0);
    bootstrap_pool(&mut fx, IDLE_SEED);
    let e1 = fx.create_expiry(test_constants::default_expiry_ms());
    let e2 = fx.create_expiry(test_constants::default_expiry_ms() + 86_400_000);
    fund_empty_market(&mut fx, e1);
    fund_empty_market(&mut fx, e2);

    fx.scenario_mut().next_tx(test_constants::admin());
    let mut config = fx.scenario_mut().take_shared<ProtocolConfig>();
    let pyth = fx.scenario_mut().take_shared_by_id<PythFeed>(fx.pyth_id());
    let bs = fx.take_bs();
    let oracle_registry = fx.scenario_mut().take_shared<OracleRegistry>();
    let mut vault = fx.scenario_mut().take_shared_by_id<PoolVault>(fx.vault_id());
    let mut m1 = fx.scenario_mut().take_shared_by_id<ExpiryMarket>(e1);

    // Two markets are active but only one is frozen: sealing here would let the
    // flush value a market at an oracle state read after the snapshot instant.
    let stage = fx.start_flush(&mut config, &mut vault);
    fx.snapshot_expiry_pricer(&stage, &mut vault, &mut m1, &config, &oracle_registry, &pyth, &bs);
    helpers::seal_snapshot(stage, &mut vault, &mut config);

    abort 999
}

#[test, expected_failure(abort_code = plp::EValuationSnapshotNotSealed)]
fun value_expiry_before_seal_aborts() {
    let mut fx = helpers::setup_market_default();
    let _trader = fx.create_funded_manager(0);
    bootstrap_pool(&mut fx, IDLE_SEED);
    let e = new_funded_empty_market(&mut fx, test_constants::default_expiry_ms());

    fx.scenario_mut().next_tx(test_constants::admin());
    let mut config = fx.scenario_mut().take_shared<ProtocolConfig>();
    let pyth = fx.scenario_mut().take_shared_by_id<PythFeed>(fx.pyth_id());
    let bs = fx.take_bs();
    let oracle_registry = fx.scenario_mut().take_shared<OracleRegistry>();
    let mut vault = fx.scenario_mut().take_shared_by_id<PoolVault>(fx.vault_id());
    let mut m = fx.scenario_mut().take_shared_by_id<ExpiryMarket>(e);

    let stage = fx.start_flush(&mut config, &mut vault);
    fx.snapshot_expiry_pricer(&stage, &mut vault, &mut m, &config, &oracle_registry, &pyth, &bs);
    fx.value_expiry(&mut vault, &mut m, &config);

    abort 999
}

#[test]
fun value_expiry_is_idempotent_on_double_value() {
    let mut fx = helpers::setup_market_default();
    let _trader = fx.create_funded_manager(0);
    bootstrap_pool(&mut fx, IDLE_SEED);
    let e = new_funded_empty_market(&mut fx, test_constants::default_expiry_ms());

    fx.scenario_mut().next_tx(test_constants::admin());
    let mut market = fx.take_market_bundle(e);

    fx.start_flush_bundle(&mut market);
    fx.value_expiry_bundle(&mut market);
    // value_expiry is permissionless, so a stranger can race the keeper. Valuing an
    // already-valued market is a no-op, not an abort: it must not wedge the flush or
    // double-count the market. A second call here is silently absorbed and finish
    // still closes at the empty-pool mark.
    fx.value_expiry_bundle(&mut market);
    let pool_nav = fx.finish_flush_bundle(&mut market);
    assert_eq!(pool_nav, IDLE_SEED);

    helpers::return_market_bundle(market);
    fx.finish();
}

// === Valuation flag ===

// Trading is not gated by the flag on this design: a mint or redeem during a flush
// records its deltas on the market's valuation stamp instead of aborting. That
// behavior is covered by the trading-during-flush tests, not here; this section
// pins the ops the flag still gates.

#[test, expected_failure(abort_code = plp::ESnapshotStageOpen)]
fun a_rebalance_inside_the_open_snapshot_stage_aborts() {
    let mut fx = helpers::setup_market_default();
    let trader = fx.create_funded_manager(test_constants::default_manager_deposit());
    bootstrap_pool(&mut fx, IDLE_SEED);
    let e1 = fx.create_expiry(test_constants::default_expiry_ms());
    fund_market_with_order(&mut fx, &trader, e1);

    // A cross-move between a market's stamp and the seal's vault capture would
    // skew the frozen figures, so the whole open stage refuses maintenance —
    // only the flush-starter's own PTB can even compose this state. Post-seal
    // rebalances are pinned free by the mid-flush metamorphic tests.
    fx.scenario_mut().next_tx(test_constants::alice());
    let mut config = fx.scenario_mut().take_shared<ProtocolConfig>();
    let mut vault = fx.scenario_mut().take_shared_by_id<PoolVault>(fx.vault_id());
    let mut m1 = fx.scenario_mut().take_shared_by_id<ExpiryMarket>(e1);
    let _stage = fx.start_flush(&mut config, &mut vault);
    fx.rebalance_expiry_cash(&mut vault, &mut m1, &config);
    abort 999
}

#[test]
fun the_flush_event_reports_live_pre_drain_idle_apart_from_the_frozen_mark_idle() {
    let mut fx = helpers::setup_market_default();
    let trader = fx.create_funded_manager(test_constants::default_manager_deposit());
    bootstrap_pool(&mut fx, IDLE_SEED);
    let e1 = fx.create_expiry(test_constants::default_expiry_ms());
    fund_market_with_order(&mut fx, &trader, e1);

    fx.scenario_mut().next_tx(test_constants::alice());
    let mut config = fx.scenario_mut().take_shared<ProtocolConfig>();
    let pyth = fx.scenario_mut().take_shared_by_id<PythFeed>(fx.pyth_id());
    let bs = fx.take_bs();
    let oracle_registry = fx.scenario_mut().take_shared<OracleRegistry>();
    let mut vault = fx.scenario_mut().take_shared_by_id<PoolVault>(fx.vault_id());
    let mut m1 = fx.scenario_mut().take_shared_by_id<ExpiryMarket>(e1);

    // Control flush, no mid-window movement, to fix the mark.
    let stage = fx.start_flush(&mut config, &mut vault);
    fx.snapshot_expiry_pricer(&stage, &mut vault, &mut m1, &config, &oracle_registry, &pyth, &bs);
    helpers::seal_snapshot(stage, &mut vault, &mut config);
    fx.value_expiry(&mut vault, &mut m1, &config);
    let control_mark = fx.finish_flush(&mut vault, &mut config);

    // Flush B moves idle BETWEEN the seal and the finish: a post-seal rebalance
    // sweeps the funded market's surplus into idle. The frozen mark idle was
    // captured at the seal (before the sweep), while `idle_balance_before` is a
    // live read at the finish (after it) — the event must report the two apart,
    // and the mark must still equal the control's.
    fx.scenario_mut().next_tx(test_constants::alice());
    let stage = fx.start_flush(&mut config, &mut vault);
    fx.snapshot_expiry_pricer(&stage, &mut vault, &mut m1, &config, &oracle_registry, &pyth, &bs);
    helpers::seal_snapshot(stage, &mut vault, &mut config);
    let idle_at_seal = vault.idle_balance();
    fx.rebalance_expiry_cash(&mut vault, &mut m1, &config);
    // Guard: the mid-window sweep genuinely raised live idle.
    assert!(vault.idle_balance() > idle_at_seal);
    fx.value_expiry(&mut vault, &mut m1, &config);
    let corrected_mark = fx.finish_flush(&mut vault, &mut config);
    assert_eq!(corrected_mark, control_mark);

    let events = event::events_by_type<vault_events::FlushExecuted>();
    let (live_before, frozen_idle) = vault_events::flush_executed_idle_figures(
        &events[events.length() - 1],
    );
    // Telemetry reflects the swept cash; the mark's idle input does not.
    assert!(live_before > frozen_idle);
    assert_eq!(frozen_idle, idle_at_seal);

    return_shared(config);
    return_shared(pyth);
    helpers::return_bs(bs);
    return_shared(oracle_registry);
    return_shared(vault);
    return_shared(m1);
    fx.finish();
}

#[test]
fun a_market_created_and_funded_mid_flush_leaves_the_mark_unchanged() {
    let mut fx = helpers::setup_market_default();
    let trader = fx.create_funded_manager(test_constants::default_manager_deposit());
    bootstrap_pool(&mut fx, IDLE_SEED);
    let e1 = fx.create_expiry(test_constants::default_expiry_ms());
    fund_market_with_order(&mut fx, &trader, e1);

    // Control flush over the one existing market.
    fx.scenario_mut().next_tx(test_constants::alice());
    let mut config = fx.scenario_mut().take_shared<ProtocolConfig>();
    let pyth = fx.scenario_mut().take_shared_by_id<PythFeed>(fx.pyth_id());
    let bs = fx.take_bs();
    let oracle_registry = fx.scenario_mut().take_shared<OracleRegistry>();
    let mut vault = fx.scenario_mut().take_shared_by_id<PoolVault>(fx.vault_id());
    let mut m1 = fx.scenario_mut().take_shared_by_id<ExpiryMarket>(e1);
    fx.rebalance_expiry_cash(&mut vault, &mut m1, &config);
    let stage = fx.start_flush(&mut config, &mut vault);
    fx.snapshot_expiry_pricer(&stage, &mut vault, &mut m1, &config, &oracle_registry, &pyth, &bs);
    helpers::seal_snapshot(stage, &mut vault, &mut config);
    fx.value_expiry(&mut vault, &mut m1, &config);
    let control_mark = fx.finish_flush(&mut vault, &mut config);

    // Flush B: identical books at its snapshot, but a NEW market is created AND
    // funded mid-window. The flush's expected set is frozen at its snapshot, so
    // the new market is simply not part of it; its funding top-up moves idle
    // after the seal, and the mark reads idle frozen at the seal, so it treats
    // that cash as the idle it was at the snapshot instant.
    fx.scenario_mut().next_tx(test_constants::alice());
    let stage = fx.start_flush(&mut config, &mut vault);
    fx.snapshot_expiry_pricer(&stage, &mut vault, &mut m1, &config, &oracle_registry, &pyth, &bs);
    helpers::seal_snapshot(stage, &mut vault, &mut config);
    return_shared(config);
    return_shared(vault);
    return_shared(oracle_registry);
    let e2 = fx.create_expiry(test_constants::default_expiry_ms() + 86_400_000);
    fx.scenario_mut().next_tx(test_constants::alice());
    let mut config = fx.scenario_mut().take_shared<ProtocolConfig>();
    let oracle_registry = fx.scenario_mut().take_shared<OracleRegistry>();
    let mut vault = fx.scenario_mut().take_shared_by_id<PoolVault>(fx.vault_id());
    let mut m2 = fx.scenario_mut().take_shared_by_id<ExpiryMarket>(e2);
    let idle_before = vault.idle_balance();
    fx.rebalance_expiry_cash(&mut vault, &mut m2, &config);
    // Guard: the new market genuinely pulled its initial funding from idle
    // mid-window, so the equality below is the compensation at work.
    assert!(vault.idle_balance() < idle_before);
    fx.value_expiry(&mut vault, &mut m1, &config);
    let corrected_mark = fx.finish_flush(&mut vault, &mut config);
    assert_eq!(corrected_mark, control_mark);
    // The new market is part of the NEXT snapshot, not the one in flight.
    assert_eq!(vault.active_expiry_markets().length(), 2);

    return_shared(config);
    return_shared(pyth);
    helpers::return_bs(bs);
    return_shared(oracle_registry);
    return_shared(vault);
    return_shared(m1);
    return_shared(m2);
    fx.finish();
}

#[test]
fun finish_flush_releases_the_valuation_flag_and_a_mint_succeeds() {
    let mut fx = helpers::setup_market_default();
    let trader = fx.create_funded_manager(test_constants::default_manager_deposit());
    bootstrap_pool(&mut fx, IDLE_SEED);
    let e = new_funded_empty_market(&mut fx, test_constants::default_expiry_ms());

    fx.scenario_mut().next_tx(test_constants::alice());
    let mut market = fx.take_market_bundle(e);
    let mut account = fx.take_account_bundle(&trader);

    fx.start_flush_bundle(&mut market);
    assert!(helpers::valuation_in_progress_bundle(&market));
    fx.value_expiry_bundle(&mut market);
    let pool_nav = fx.finish_flush_bundle(&mut market);
    assert_eq!(
        pool_nav,
        constants::expiry_cash_floor!() + (IDLE_SEED - constants::expiry_cash_floor!()),
    );

    // Finish releases the flag — asserted on the flag itself, because trading is
    // not blocked by a flush and cannot witness the release. The flag is what
    // still gates keeper cash ops, market creation, and config setters, so it
    // must not survive the flush. The mint then pins that ordinary trading
    // continues after a completed flush.
    assert!(!helpers::valuation_in_progress_bundle(&market));
    let expiry_id = helpers::market(&market).id();
    let order_id = fx.mint_bundle(
        &mut market,
        &mut account,
        helpers::strike_tick(),
        constants::pos_inf_tick!(),
        STANDARD_QUANTITY,
    );
    assert!(helpers::has_position_bundle(&account, expiry_id, order_id));

    helpers::return_account_bundle(account);
    helpers::return_market_bundle(market);
    fx.finish();
}

// `finish_with_wrong_vault_aborts` is gone with `EWrongPoolVault`: the valuation is
// now a field of the vault it belongs to, so finishing one vault's flush against
// another is unrepresentable rather than rejected at runtime.

/// The stale-list regression: a keeper builds its market list off-chain, a market is settled
/// and swept before the flush executes, and the flush is then handed a market that is no
/// longer in the active set. That used to abort and fail the whole flush — observed on
/// testnet as a repeated flush-failing abort. Both stages now skip it, and the flush
/// completes.
#[test]
fun a_swept_market_left_in_the_keepers_list_is_skipped_not_fatal() {
    let mut fx = helpers::setup_market_default();
    let _trader = fx.create_funded_manager(0);
    bootstrap_pool(&mut fx, IDLE_SEED);
    let e = new_funded_empty_market(&mut fx, test_constants::default_expiry_ms());

    // Settle and sweep the market out of the active set, exactly as the keeper's own
    // settlement lane does between reading the list and submitting the flush.
    fx.set_clock_for_testing(test_constants::default_expiry_ms());
    fx.scenario_mut().next_tx(test_constants::admin());
    let mut market = fx.take_market_bundle(e);
    fx.insert_exact_settlement_spot_bundle(
        &mut market,
        test_constants::default_live_price(),
    );
    assert!(fx.try_settle_bundle(&mut market));
    fx.rebalance_expiry_cash_bundle(&mut market);
    helpers::return_market_bundle(market);

    // Flush anyway, with the stale market still in hand.
    fx.scenario_mut().next_tx(test_constants::admin());
    let mut market = fx.take_market_bundle(e);
    fx.start_flush_bundle(&mut market);
    fx.value_expiry_bundle(&mut market);
    let pool_nav = fx.finish_flush_bundle(&mut market);

    // The swept market contributed nothing, so the pool marks at idle — the sweep
    // already returned its cash. Exact, so a silent double-count would fail here.
    assert_eq!(pool_nav, IDLE_SEED);

    helpers::return_market_bundle(market);
    fx.finish();
}

#[test]
fun finish_flush_with_zero_pool_nav_and_empty_queues_succeeds() {
    let (mut fx, e) = setup_underwater_market(0);

    fx.scenario_mut().next_tx(test_constants::admin());
    let mut market = fx.take_market_bundle(e);
    fx.start_flush_bundle(&mut market);
    fx.value_expiry_bundle(&mut market);
    let pool_nav = fx.finish_flush_bundle(&mut market);
    assert_eq!(pool_nav, 0);

    helpers::return_market_bundle(market);
    fx.finish();
}

#[test]
fun finish_flush_with_low_plp_price_and_empty_queues_succeeds() {
    let (mut fx, e) = setup_underwater_market(BELOW_MIN_PRICE_IDLE);

    fx.scenario_mut().next_tx(test_constants::admin());
    let mut market = fx.take_market_bundle(e);
    fx.start_flush_bundle(&mut market);
    fx.value_expiry_bundle(&mut market);
    let pool_nav = fx.finish_flush_bundle(&mut market);
    assert_eq!(pool_nav, BELOW_MIN_PRICE_IDLE);

    helpers::return_market_bundle(market);
    fx.finish();
}

#[test]
fun finish_flush_with_high_plp_price_and_empty_queues_succeeds() {
    let mut fx = helpers::setup_market_default();
    bootstrap_pool(&mut fx, constants::min_bootstrap_liquidity!());
    let e = fx.create_expiry(test_constants::default_expiry_ms());

    fx.scenario_mut().next_tx(test_constants::admin());
    let mut market = fx.take_market_bundle(e);
    fx.prepare_live_oracle_bundle(&mut market, test_constants::default_live_price());
    fx.seed_market_cash(helpers::market_mut(&mut market), ABOVE_MAX_PRICE_MARKET_CASH);

    fx.start_flush_bundle(&mut market);
    fx.value_expiry_bundle(&mut market);
    let pool_nav = fx.finish_flush_bundle(&mut market);
    assert_eq!(pool_nav, ABOVE_MAX_PRICE_POOL_NAV);

    helpers::return_market_bundle(market);
    fx.finish();
}

// === Lock primitives ===

#[test, expected_failure(abort_code = protocol_config::EValuationNotInProgress)]
fun end_valuation_without_start_aborts() {
    let mut fx = helpers::setup_market_default();
    fx.scenario_mut().next_tx(test_constants::admin());
    let mut config = fx.scenario_mut().take_shared<ProtocolConfig>();
    config.end_valuation();

    abort 999
}

// === protocol_reserve_profit_share config ===

#[test]
fun set_protocol_reserve_profit_share_round_trips() {
    let mut fx = helpers::setup_market_default();
    fx.scenario_mut().next_tx(test_constants::admin());
    let mut config = fx.scenario_mut().take_shared<ProtocolConfig>();
    let admin_cap = admin::new(fx.scenario_mut().ctx());

    config.set_protocol_reserve_profit_share(&admin_cap, 123_456_789);
    assert_eq!(config.protocol_reserve_profit_share(), 123_456_789);

    destroy(admin_cap);
    return_shared(config);
    fx.finish();
}

#[test, expected_failure(abort_code = config_constants::EInvalidProtocolReserveProfitShare)]
fun set_protocol_reserve_profit_share_above_max_aborts() {
    let mut fx = helpers::setup_market_default();
    fx.scenario_mut().next_tx(test_constants::admin());
    let mut config = fx.scenario_mut().take_shared<ProtocolConfig>();
    let admin_cap = admin::new(fx.scenario_mut().ctx());

    config.set_protocol_reserve_profit_share(&admin_cap, float!() + 1);

    abort 999
}

// === Helpers ===

/// Bootstrap pool idle via the genesis `lock_capital` so nonzero NAV has matching PLP
/// supply (`idle == total_supply == amount` at a 1.0 mark). The lock is
/// operator-gated and needs no trader account.
/// Install committed real scenario 0 over a prepared market.
fun seed_real_scenario_surface(fx: &mut helpers::Fixture, market: &mut helpers::MarketBundle) {
    let ts = test_constants::live_source_timestamp_ms() + 1;
    fx.set_pyth_price_for_testing_bundle(market, ref_data::spot(0), ts);
    fx.seed_bs_surface_with_svi_bundle(
        market,
        ref_data::spot(0),
        ref_data::forward(0),
        ref_data::svi_a(0),
        false,
        ref_data::svi_b(0),
        ref_data::svi_sigma(0),
        ref_data::svi_rho_magnitude(0),
        ref_data::svi_rho_is_negative(0),
        ref_data::svi_m_magnitude(0),
        ref_data::svi_m_is_negative(0),
        ts,
    );
}

fun bootstrap_pool(fx: &mut helpers::Fixture, amount: u64) {
    fx.bootstrap_lock(amount);
}

/// Create a live market and fund it to the cash floor from idle (no orders).
fun new_funded_empty_market(fx: &mut helpers::Fixture, expiry_ms: u64): ID {
    let e = fx.create_expiry(expiry_ms);
    fund_empty_market(fx, e);
    e
}

/// Prepare an already-created market's oracle live and fund it to the cash floor.
fun fund_empty_market(fx: &mut helpers::Fixture, e: ID) {
    fx.scenario_mut().next_tx(test_constants::admin());
    let mut market = fx.take_market_bundle(e);
    fx.prepare_live_oracle_bundle(&mut market, test_constants::default_live_price());
    fx.rebalance_expiry_cash_bundle(&mut market);
    helpers::return_market_bundle(market);
}

/// Prepare and fund an already-created market and mint one ATM up order into it.
/// Fund a market to its allocation and mint the standard order into it,
/// returning the premium paid. The quoted probability is checked against the
/// independent reference here, so every expected value the caller derives from
/// this premium rests on a verified price.
fun fund_market_with_order(fx: &mut helpers::Fixture, trader: &helpers::Trader, e: ID): u64 {
    fx.scenario_mut().next_tx(test_constants::alice());
    let mut market = fx.take_market_bundle(e);
    let mut account = fx.take_account_bundle(trader);
    fx.prepare_live_oracle_bundle(&mut market, test_constants::default_live_price());
    fx.rebalance_expiry_cash_bundle(&mut market);
    let quote = fx.quote_mint_bundle(
        &market,
        helpers::strike_tick(),
        constants::pos_inf_tick!(),
        STANDARD_QUANTITY,
    );
    helpers::assert_atm_entry_probability(quote.entry_probability());
    fx.mint_bundle(
        &mut market,
        &mut account,
        helpers::strike_tick(),
        constants::pos_inf_tick!(),
        STANDARD_QUANTITY,
    );
    helpers::return_account_bundle(account);
    helpers::return_market_bundle(market);
    quote.premium()
}

/// Build a production-created market whose full pool allocation is deployed into
/// expiry cash, then mint an ATM UP order and reprice it deep in the money. The
/// repriced live liability exceeds free cash, so the market contributes zero NAV;
/// `idle_remainder` is the only pool NAV left for `finish_flush`.
fun setup_underwater_market(idle_remainder: u64): (helpers::Fixture, ID) {
    let mut fx = helpers::setup_market_default();
    let market_allocation = UNDERWATER_MARKET_ALLOCATION;
    fx.set_template_zero_min_fee();
    fx.set_default_cadence_allocation(market_allocation, market_allocation);
    bootstrap_pool(&mut fx, market_allocation + idle_remainder);
    let e = fx.create_expiry(test_constants::default_expiry_ms());
    let trader = fx.create_funded_manager(UNDERWATER_TRADER_DEPOSIT);

    fx.scenario_mut().next_tx(test_constants::alice());
    let mut market = fx.take_market_bundle(e);
    let mut account = fx.take_account_bundle(&trader);
    fx.prepare_live_oracle_bundle(&mut market, test_constants::default_live_price());
    fx.rebalance_expiry_cash_bundle(&mut market);
    helpers::assert_atm_entry_probability(fx
        .quote_mint_bundle(
            &market,
            helpers::strike_tick(),
            constants::pos_inf_tick!(),
            UNDERWATER_QUANTITY,
        )
        .entry_probability());
    fx.mint_bundle(
        &mut market,
        &mut account,
        helpers::strike_tick(),
        constants::pos_inf_tick!(),
        UNDERWATER_QUANTITY,
    );
    // The knife edge this fixture rests on, stated so it fails loudly rather than
    // drifting: the deep-ITM liability is the full quantity, so a zero NAV needs
    // the market holding exactly that much cash.
    assert_eq!(helpers::market(&market).cash_balance(), UNDERWATER_QUANTITY);
    fx.set_clock_for_testing(REPRICE_MS);
    fx.prepare_live_oracle_bundle_at(&mut market, DEEP_ITM_LIVE_PRICE, REPRICE_SOURCE_TS);

    helpers::return_account_bundle(account);
    helpers::return_market_bundle(market);
    (fx, e)
}

// === Snapshot-stage guards ===

#[test, expected_failure(abort_code = plp::EExpiryPricerAlreadySnapshotted)]
fun snapshotting_one_market_twice_aborts() {
    let mut fx = helpers::setup_market_default();
    bootstrap_pool(&mut fx, IDLE_SEED);
    let e = new_funded_empty_market(&mut fx, test_constants::default_expiry_ms());

    fx.scenario_mut().next_tx(test_constants::admin());
    let mut market = fx.take_market_bundle(e);
    let stage = fx.start_flush_bundle_stage(&mut market);
    fx.snapshot_expiry_pricer_bundle(&stage, &mut market);

    abort 999
}

#[test, expected_failure(abort_code = plp::EExpiredMarketNotSettled)]
fun snapshotting_an_expired_unsettled_market_aborts() {
    let mut fx = helpers::setup_market_default();
    bootstrap_pool(&mut fx, IDLE_SEED);
    let e = new_funded_empty_market(&mut fx, test_constants::default_expiry_ms());

    // Past expiry with no settlement price recorded: the market has no live mark and
    // no settled one, so the snapshot stage refuses it rather than guessing. Because
    // the stage is atomic this abort reverts `start_pool_valuation` too, so the pool is
    // left with no open flush and the operator can settle the market and start again.
    fx.set_clock_for_testing(test_constants::default_expiry_ms());
    fx.scenario_mut().next_tx(test_constants::admin());
    let mut market = fx.take_market_bundle(e);
    fx.start_flush_bundle(&mut market);

    abort 999
}

// === Restart folds into start; completion is deadline-bounded ===

#[test]
fun starting_a_fresh_flush_supersedes_a_stranded_one() {
    let mut fx = helpers::setup_market_default();
    bootstrap_pool(&mut fx, IDLE_SEED);
    let e = new_funded_empty_market(&mut fx, test_constants::default_expiry_ms());

    // Start a flush and walk away without valuing or finishing it: the outer lock
    // survives the transaction boundary (a stranded flush).
    fx.scenario_mut().next_tx(test_constants::admin());
    let mut market = fx.take_market_bundle(e);
    fx.start_flush_bundle(&mut market);
    assert!(helpers::valuation_in_progress_bundle(&market));
    helpers::return_market_bundle(market);

    // There is no abort entrypoint. Recovery is to start again: `start_pool_valuation`
    // discards the stranded valuation (bumping the flush ordinal, which invalidates the
    // prior snapshot's per-market stamps) and begins fresh. The whole flush then
    // completes, proving the stranded valuation left no exactly-once residue — an empty
    // funded market marks the pool at exactly its idle, so `> 0` would not separate
    // "no residue" from "residue but still positive".
    fx.scenario_mut().next_tx(test_constants::admin());
    let mut market = fx.take_market_bundle(e);
    fx.start_flush_bundle(&mut market);
    fx.value_expiry_bundle(&mut market);
    let pool_nav = fx.finish_flush_bundle(&mut market);
    assert_eq!(pool_nav, IDLE_SEED);

    helpers::return_market_bundle(market);
    fx.finish();
}

#[test]
fun finish_one_ms_before_the_window_succeeds() {
    let mut fx = helpers::setup_market_default();
    bootstrap_pool(&mut fx, IDLE_SEED);
    let e = new_funded_empty_market(&mut fx, test_constants::default_expiry_ms());

    fx.scenario_mut().next_tx(test_constants::admin());
    let mut market = fx.take_market_bundle(e);
    let started_at_ms = fx.clock().timestamp_ms();
    fx.start_flush_bundle(&mut market);
    fx.value_expiry_bundle(&mut market);

    // One millisecond inside the window: finish still closes. Paired with the abort
    // test below, this pins the deadline boundary from both sides so it cannot be
    // widened or dropped silently. Finish reads no oracle (the snapshot froze every
    // input), so advancing the clock cannot stale it for any reason but the deadline.
    fx.set_clock_for_testing(
        started_at_ms + config_constants::default_max_valuation_window_ms!() - 1,
    );
    let pool_nav = fx.finish_flush_bundle(&mut market);
    assert_eq!(pool_nav, IDLE_SEED);

    helpers::return_market_bundle(market);
    fx.finish();
}

#[test, expected_failure(abort_code = plp::EValuationWindowExpired)]
fun finish_at_the_window_aborts() {
    let mut fx = helpers::setup_market_default();
    bootstrap_pool(&mut fx, IDLE_SEED);
    let e = new_funded_empty_market(&mut fx, test_constants::default_expiry_ms());

    fx.scenario_mut().next_tx(test_constants::admin());
    let mut market = fx.take_market_bundle(e);
    let started_at_ms = fx.clock().timestamp_ms();
    fx.start_flush_bundle(&mut market);
    fx.value_expiry_bundle(&mut market);

    // Exactly the window: the frozen mark is now too stale to fill queued LP requests,
    // so finish refuses even for the cap owner (the deadline is enforced before the
    // completeness check, and this flush is fully valued, so only the deadline fires).
    // The operator's recourse is to start a fresh flush, not to force this one.
    fx.set_clock_for_testing(
        started_at_ms + config_constants::default_max_valuation_window_ms!(),
    );
    fx.finish_flush_bundle(&mut market);

    abort 999
}

// === Settlement is never gated by the flush ===

#[test]
fun a_snapshotted_unvalued_market_settles_mid_flush() {
    let mut fx = helpers::setup_market_default();
    bootstrap_pool(&mut fx, IDLE_SEED);
    let e = new_funded_empty_market(&mut fx, test_constants::default_expiry_ms());

    fx.scenario_mut().next_tx(test_constants::admin());
    let mut market = fx.take_market_bundle(e);
    // The snapshot stage stamps the market; it stays stamped until its own
    // `value_expiry`. Settlement is no longer gated on that stamp.
    fx.start_flush_bundle(&mut market);

    // The market crosses its expiry mid-flush and SETTLES immediately — settlement is
    // never blocked by a flush. The frozen mark is settlement-invariant, so this
    // market's own `value_expiry` then folds the frozen pre-expiry mark and clears the
    // stamp, leaving the flush to finish normally.
    fx.set_clock_for_testing(test_constants::default_expiry_ms());
    fx.insert_exact_settlement_spot_bundle(&mut market, test_constants::default_live_price());
    assert!(fx.try_settle_bundle(&mut market));
    fx.value_expiry_bundle(&mut market);
    assert!(!helpers::market(&market).is_pending_valuation(helpers::config(&market)));

    helpers::return_market_bundle(market);
    fx.finish();
}

// === Completion is permissionless ===

#[test]
fun a_third_party_can_complete_a_flush_the_operator_started() {
    let mut fx = helpers::setup_market_default();
    bootstrap_pool(&mut fx, IDLE_SEED);
    let e = new_funded_empty_market(&mut fx, test_constants::default_expiry_ms());

    // The operator (cap owner) starts the flush — the one permissioned step.
    fx.scenario_mut().next_tx(test_constants::admin());
    let mut market = fx.take_market_bundle(e);
    fx.start_flush_bundle(&mut market);
    helpers::return_market_bundle(market);

    // Once the snapshot is sealed it no longer matters who drives the rest: the frozen
    // mark and the budgets committed at start are fixed, so value and finish are
    // permissionless. A stranger values the market...
    fx.scenario_mut().next_tx(test_constants::alice());
    let mut market = fx.take_market_bundle(e);
    fx.value_expiry_bundle(&mut market);
    helpers::return_market_bundle(market);

    // ...and a different stranger finishes it. The griefing shape that once justified a
    // starter gate — finishing with a zero drain budget to retire the mark with nothing
    // filled — is closed structurally: budgets are committed at start and finish takes
    // none. The flush closes at the empty-pool mark and the lock is released.
    fx.scenario_mut().next_tx(test_constants::bob());
    let mut market = fx.take_market_bundle(e);
    let pool_nav = fx.finish_flush_bundle(&mut market);
    assert_eq!(pool_nav, IDLE_SEED);
    assert!(!helpers::valuation_in_progress_bundle(&market));

    helpers::return_market_bundle(market);
    fx.finish();
}

#[test]
fun superseding_after_a_partial_valuation_leaves_no_residue_and_re_values() {
    let mut fx = helpers::setup_market_default();
    let trader = fx.create_funded_manager(test_constants::default_manager_deposit());
    bootstrap_pool(&mut fx, IDLE_SEED);
    let e1 = fx.create_expiry(test_constants::default_expiry_ms());
    let e2 = fx.create_expiry(test_constants::default_expiry_ms() + 86_400_000);
    fund_market_with_order(&mut fx, &trader, e1);
    fund_market_with_order(&mut fx, &trader, e2);

    fx.scenario_mut().next_tx(test_constants::alice());
    let mut config = fx.scenario_mut().take_shared<ProtocolConfig>();
    let pyth = fx.scenario_mut().take_shared_by_id<PythFeed>(fx.pyth_id());
    let bs = fx.take_bs();
    let oracle_registry = fx.scenario_mut().take_shared<OracleRegistry>();
    let mut vault = fx.scenario_mut().take_shared_by_id<PoolVault>(fx.vault_id());
    let mut m1 = fx.scenario_mut().take_shared_by_id<ExpiryMarket>(e1);
    let mut m2 = fx.scenario_mut().take_shared_by_id<ExpiryMarket>(e2);

    // Value ONE market (measurement-only — value_expiry moves no cash), then walk
    // away. The claim under test is that superseding the partial valuation with a
    // fresh flush leaves no exactly-once residue and moves no cash: m1's cash and the
    // pool idle are unchanged across the restart, and the later flush values m1 again
    // rather than rejecting it as already-valued.
    let stage = fx.start_flush(&mut config, &mut vault);
    fx.snapshot_expiry_pricer(&stage, &mut vault, &mut m1, &config, &oracle_registry, &pyth, &bs);
    fx.snapshot_expiry_pricer(&stage, &mut vault, &mut m2, &config, &oracle_registry, &pyth, &bs);
    helpers::seal_snapshot(stage, &mut vault, &mut config);
    fx.value_expiry(&mut vault, &mut m1, &config);
    let m1_cash_after_partial = m1.cash_balance();
    let idle_after_partial = vault.idle_balance();

    // No abort entrypoint: recovery is to start again. Folding stop into start, the
    // fresh `start_pool_valuation` below discards this partial valuation (bumping the
    // flush ordinal, which staleness-invalidates m1's earlier snapshot stamp) and
    // begins clean. A fresh transaction is needed only so the shared `Registry` is
    // takeable again for the new pool-valuation proof — the realistic shape, where a
    // superseding flush runs in a later transaction than the one that stalled.
    fx.scenario_mut().next_tx(test_constants::admin());
    let stage = fx.start_flush(&mut config, &mut vault);
    fx.snapshot_expiry_pricer(&stage, &mut vault, &mut m1, &config, &oracle_registry, &pyth, &bs);
    fx.snapshot_expiry_pricer(&stage, &mut vault, &mut m2, &config, &oracle_registry, &pyth, &bs);
    helpers::seal_snapshot(stage, &mut vault, &mut config);
    fx.value_expiry(&mut vault, &mut m1, &config);
    fx.value_expiry(&mut vault, &mut m2, &config);
    let pool_nav = fx.finish_flush(&mut vault, &mut config);
    // The superseded partial valuation left no exactly-once residue: m1's cash and the
    // pool idle are unchanged across the restart, and m1 was re-valued rather than
    // rejected as already valued.
    assert_eq!(m1.cash_balance(), m1_cash_after_partial);
    assert_eq!(vault.idle_balance(), idle_after_partial);
    assert!(pool_nav > 0);

    return_shared(config);
    return_shared(pyth);
    return_shared(oracle_registry);
    return_shared(vault);
    return_shared(m1);
    return_shared(m2);
    helpers::return_bs(bs);
    fx.finish();
}

/// The mixed case, which is what actually happens in production: the pool still has a
/// LIVE market to value, and the caller's list additionally carries one that was swept
/// out from under it. The degenerate single-market version above leaves `expected`
/// empty, so it never proves the live market is still valued correctly alongside the
/// skip — this does.
#[test]
fun a_stale_market_alongside_a_live_one_is_skipped_and_the_live_one_still_values() {
    let mut fx = helpers::setup_market_default();
    let trader = fx.create_funded_manager(test_constants::default_manager_deposit());
    bootstrap_pool(&mut fx, IDLE_SEED);
    // `doomed` expires first so the clock can pass it while `live` is still live.
    let doomed = fx.create_expiry(test_constants::default_expiry_ms());
    let live = fx.create_expiry(test_constants::default_expiry_ms() + 86_400_000);
    fund_market_with_order(&mut fx, &trader, live);
    // `doomed` is deliberately left unfunded, so sweeping it moves no cash and the pool
    // arithmetic below is exactly the single-live-market case.

    // Settle and sweep `doomed` only. `live` stays in the active set.
    fx.set_clock_for_testing(test_constants::default_expiry_ms());
    fx.scenario_mut().next_tx(test_constants::admin());
    let mut doomed_bundle = fx.take_market_bundle(doomed);
    fx.insert_exact_settlement_spot_bundle(
        &mut doomed_bundle,
        test_constants::default_live_price(),
    );
    assert!(fx.try_settle_bundle(&mut doomed_bundle));
    fx.rebalance_expiry_cash_bundle(&mut doomed_bundle);
    helpers::return_market_bundle(doomed_bundle);

    fx.scenario_mut().next_tx(test_constants::admin());
    let mut config = fx.scenario_mut().take_shared<ProtocolConfig>();
    let pyth = fx.scenario_mut().take_shared_by_id<PythFeed>(fx.pyth_id());
    let mut bs = fx.take_bs();
    let oracle_registry = fx.scenario_mut().take_shared<OracleRegistry>();
    let mut vault = fx.scenario_mut().take_shared_by_id<PoolVault>(fx.vault_id());
    let mut m_live = fx.scenario_mut().take_shared_by_id<ExpiryMarket>(live);
    let mut m_doomed = fx.scenario_mut().take_shared_by_id<ExpiryMarket>(doomed);

    // The clock moved to reach `doomed`'s expiry, which staled the seeded surface; the
    // live market still has to price, so refresh it at the current instant. In an
    // EARLIER transaction than the snapshot, which RP-24 requires.
    let now_ms = fx.clock().timestamp_ms();
    fx.seed_bs_surface(
        &m_live,
        &mut bs,
        test_constants::default_live_price(),
        test_constants::default_live_price(),
        now_ms,
    );
    fx.scenario_mut().next_tx(test_constants::admin());

    // Drive BOTH through both stages, exactly as a caller holding a stale list would.
    // `expected` is {live}; `doomed` is skipped by each stage without failing the flush.
    // Cash maintenance is decoupled from the flush: rebalance the live market to
    // its band BEFORE starting; the flush itself moves no live cash.
    fx.rebalance_expiry_cash(&mut vault, &mut m_live, &config);
    let stage = fx.start_flush(&mut config, &mut vault);
    fx.snapshot_expiry_pricer(
        &stage,
        &mut vault,
        &mut m_live,
        &config,
        &oracle_registry,
        &pyth,
        &bs,
    );
    fx.snapshot_expiry_pricer(
        &stage,
        &mut vault,
        &mut m_doomed,
        &config,
        &oracle_registry,
        &pyth,
        &bs,
    );
    helpers::seal_snapshot(stage, &mut vault, &mut config);
    fx.value_expiry(&mut vault, &mut m_live, &config);
    fx.value_expiry(&mut vault, &mut m_doomed, &config);
    let pool_nav = fx.finish_flush(&mut vault, &mut config);

    // That the flush COMPLETED is already the proof the live market was valued:
    // `expected` is {live}, and `finish_flush` asserts every expected market was valued,
    // so a skip of `live` would have aborted `EMissingExpiryValuation` rather than
    // returning. The skip is therefore precise — it dropped the stale market and only
    // the stale market.
    //
    // The skip precision is proven by the flush COMPLETING above: finish would
    // have aborted `EMissingExpiryValuation` had the live market been skipped
    // too. `value_expiry` moves no cash, so the assertion below pins only the
    // pre-flush fixture state (the live market rebalanced to target), confirming
    // the fixture, not the skip.
    assert_eq!(m_live.cash_balance(), MARKET_CASH_TARGET);
    assert!(pool_nav > vault.idle_balance());

    return_shared(config);
    return_shared(pyth);
    return_shared(oracle_registry);
    return_shared(vault);
    return_shared(m_live);
    return_shared(m_doomed);
    helpers::return_bs(bs);
    fx.finish();
}
