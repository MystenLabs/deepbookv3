// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Flow coverage for the pool NAV hot potato (`start_flush` /
/// `value_expiry` / `finish_flush`) and its unified per-market cash
/// flush. Tests build production-valid markets through the real creation + funding
/// path, then assert: the aggregated pool NAV equals an independently assembled
/// reference from the vault's ledger fields and per-market `current_nav`,
/// the exactly-once completeness proof fires on a missed / double-valued market,
/// and the valuation lock blocks NAV-changing ops between start and finish.
/// Passive settled-market sweep and pending-profit exclusion coverage live in
/// `settlement_flow_tests` and `protocol_profit_deferral_tests`.
#[test_only]
module deepbook_predict::pool_valuation_flow_tests;

use deepbook_predict::{
    admin,
    block_scholes_feed::BlockScholesFeed,
    config_constants,
    constants,
    expiry_market::ExpiryMarket,
    flow_test_helpers as helpers,
    plp::{Self, PoolVault},
    pricing,
    protocol_config::{Self, ProtocolConfig},
    test_constants
};
use fixed_math::math::{Self, float_scaling as float};
use propbook::{pyth_feed::PythFeed, registry::OracleRegistry};
use std::unit_test::{assert_eq, destroy};
use sui::test_scenario::return_shared;

/// 1x ATM up range, quantity 2e9 (well under the 50e9 cash floor that backs it).
const ONE_X_QUANTITY: u64 = 2_000_000_000;
/// Idle seed large enough to fund several markets to the cash floor.
const IDLE_SEED: u64 = 1_200_000_000_000;
/// `value_expiry` sweeps each minted market back to its 10e9 cash target, so each
/// market's NAV is that target less its live liability and rebate reserve, and the
/// swept premium plus fees land in idle. Both markets are identical, so the two
/// sides of the aggregation are pinned against each other and the pool mark is
/// pinned against the ledger fields — none of it restates the digital, which is
/// checked independently at each mint.
const MARKET_CASH_TARGET: u64 = 10_000_000_000;
const MINT_MIN_FEE: u64 = 10_000_000;
const REBATE_AFTER_MINT: u64 = 5_000_000;
/// Leave exactly 1e9 idle after funding a 250e9 expiry. With 251e9 PLP supply,
/// that mark is a very low but executable fair PLP price.
const BELOW_MIN_PRICE_IDLE: u64 = 1_000_000_000;
/// Large 1x order used to drive a fully-funded market underwater after a price jump.
const UNDERWATER_QUANTITY: u64 = 500_000_000_000;
/// Allocation that leaves the market's cash EXACTLY equal to the liability the
/// deep-ITM reprice creates, so the market contributes a zero NAV. This is a
/// knife edge by necessity: for a 1x order the mint's backing requirement and the
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
/// idle and leaves 10e9 active NAV. With the protocol's 40% profit exclusion on
/// the 11e9 active+returned credit basis, the frozen LP mark is 6.61e9.
const ABOVE_MAX_PRICE_MARKET_CASH: u64 = 11_000_000_000;
const ABOVE_MAX_PRICE_POOL_NAV: u64 = 6_610_000_000;
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

    let stage = fx.start_flush(&mut config, &mut vault);
    fx.snapshot_expiry_pricer(&stage, &mut vault, &m1, &config, &oracle_registry, &pyth, &bs);
    fx.snapshot_expiry_pricer(&stage, &mut vault, &m2, &config, &oracle_registry, &pyth, &bs);
    helpers::seal_snapshot(stage, &mut vault, &config);
    fx.value_expiry(&mut vault, &mut m1, &config);
    fx.value_expiry(&mut vault, &mut m2, &config);
    let pool_nav = vault.finish_flush(
        &mut config,
        option::none(),
        option::none(),
        fx.scenario_mut().ctx(),
    );

    // Every expected value below is built from the fixture's own arithmetic and
    // the mint premium, which was checked against the independent reference at
    // mint time — nothing is read back out of the vault to predict itself.
    //
    // A 1x order's live worth is the same product as its premium, so a swept
    // market holds its cash target less that worth and less the rebate withheld
    // from the fee.
    let expected_nav = MARKET_CASH_TARGET - premium - REBATE_AFTER_MINT;
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
    fx.snapshot_expiry_pricer(&stage, &mut vault, &m1, &config, &oracle_registry, &pyth, &bs);
    fx.snapshot_expiry_pricer(&stage, &mut vault, &m2, &config, &oracle_registry, &pyth, &bs);
    helpers::seal_snapshot(stage, &mut vault, &config);
    fx.value_expiry(&mut vault, &mut m1, &config);
    fx.value_expiry(&mut vault, &mut m2, &config);
    let pool_nav = vault.finish_flush(
        &mut config,
        option::none(),
        option::none(),
        fx.scenario_mut().ctx(),
    );

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
    helpers::seal_snapshot(stage, &mut vault, &config);
    let pool_nav = vault.finish_flush(
        &mut config,
        option::none(),
        option::none(),
        fx.scenario_mut().ctx(),
    );
    assert_eq!(pool_nav, idle_seed);

    return_shared(config);
    return_shared(vault);
    fx.finish();
}

// === Oracle-width propagation and recovery ===

/// `value_expiry` is the mandatory per-market leg of a pool-wide flush, so an over-wide active
/// market observation must surface the named pricing-boundary error here rather than a VM cast.
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

    let mut valuation = fx.start_flush_bundle(&mut market);
    fx.value_expiry_bundle(&mut valuation, &mut market);
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

    let mut valuation = fx.start_flush_bundle(&mut market);
    fx.value_expiry_bundle(&mut valuation, &mut market);
    let pool_nav = fx.finish_flush_bundle(
        valuation,
        &mut market,
        option::none(),
        option::none(),
    );
    assert_eq!(pool_nav, IDLE_SEED);

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
    let m2 = fx.scenario_mut().take_shared_by_id<ExpiryMarket>(e2);

    // Both markets sealed into the snapshot, then only one valued.
    let stage = fx.start_flush(&mut config, &mut vault);
    fx.snapshot_expiry_pricer(&stage, &mut vault, &m1, &config, &oracle_registry, &pyth, &bs);
    fx.snapshot_expiry_pricer(&stage, &mut vault, &m2, &config, &oracle_registry, &pyth, &bs);
    helpers::seal_snapshot(stage, &mut vault, &config);
    fx.value_expiry(&mut vault, &mut m1, &config);
    let _ = vault.finish_flush(
        &mut config,
        option::none(),
        option::none(),
        fx.scenario_mut().ctx(),
    );

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
    fx.snapshot_expiry_pricer(&stage, &mut vault, &m1, &config, &oracle_registry, &pyth, &bs);
    fx.snapshot_expiry_pricer(&stage, &mut vault, &m2, &config, &oracle_registry, &pyth, &bs);
    helpers::seal_snapshot(stage, &mut vault, &config);

    // Valuation stage, transaction 1 of 2.
    fx.value_expiry(&mut vault, &mut m1, &config);

    // Move the oracle between valuation transactions.
    fx.scenario_mut().next_tx(test_constants::alice());
    let now_ms = fx.clock().timestamp_ms();
    fx.set_pyth_price_for_testing(&mut pyth, test_constants::default_live_price() * 2, now_ms);

    // Guard against a vacuous test: prove the move is load-bearing. A pricer loaded
    // live at this moment marks m2 differently from its frozen one, so if
    // `value_expiry` re-read the oracle the pool mark below could not still match.
    let expected_nav = MARKET_CASH_TARGET - premium - REBATE_AFTER_MINT;
    let live_nav_after_move = fx.current_nav(&m2, &config, &oracle_registry, &pyth, &bs);
    assert!(live_nav_after_move != expected_nav);

    // Valuation stage, transaction 2 of 2 — priced off the frozen snapshot.
    fx.value_expiry(&mut vault, &mut m2, &config);

    fx.scenario_mut().next_tx(test_constants::alice());
    let pool_nav = vault.finish_flush(
        &mut config,
        option::none(),
        option::none(),
        fx.scenario_mut().ctx(),
    );

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
    let m1 = fx.scenario_mut().take_shared_by_id<ExpiryMarket>(e1);

    // Two markets are active but only one is frozen: sealing here would let the
    // flush value a market at an oracle state read after the snapshot instant.
    let stage = fx.start_flush(&mut config, &mut vault);
    fx.snapshot_expiry_pricer(&stage, &mut vault, &m1, &config, &oracle_registry, &pyth, &bs);
    helpers::seal_snapshot(stage, &mut vault, &config);

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
    fx.snapshot_expiry_pricer(&stage, &mut vault, &m, &config, &oracle_registry, &pyth, &bs);
    fx.value_expiry(&mut vault, &mut m, &config);

    abort 999
}

#[test, expected_failure(abort_code = plp::EExpiryMarketAlreadyValued)]
fun value_expiry_aborts_on_double_value() {
    let mut fx = helpers::setup_market_default();
    let _trader = fx.create_funded_manager(0);
    bootstrap_pool(&mut fx, IDLE_SEED);
    let e = new_funded_empty_market(&mut fx, test_constants::default_expiry_ms());

    fx.scenario_mut().next_tx(test_constants::admin());
    let mut market = fx.take_market_bundle(e);

    fx.start_flush_bundle(&mut market);
    fx.value_expiry_bundle(&mut market);
    fx.value_expiry_bundle(&mut market);

    abort 999
}

// === Valuation lock ===

#[test, expected_failure(abort_code = protocol_config::EValuationInProgress)]
fun mint_during_valuation_aborts() {
    let mut fx = helpers::setup_market_default();
    let trader = fx.create_funded_manager(test_constants::default_manager_deposit());
    bootstrap_pool(&mut fx, IDLE_SEED);
    let e = new_funded_empty_market(&mut fx, test_constants::default_expiry_ms());

    fx.scenario_mut().next_tx(test_constants::alice());
    let mut market = fx.take_market_bundle(e);
    let mut account = fx.take_account_bundle(&trader);

    helpers::begin_valuation(&mut market);
    fx.mint_bundle(
        &mut market,
        &mut account,
        helpers::strike_tick(),
        constants::pos_inf_tick!(),
        ONE_X_QUANTITY,
        test_constants::leverage_one_x(),
    );

    abort 999
}

#[test, expected_failure(abort_code = protocol_config::EValuationInProgress)]
fun rebalance_during_valuation_aborts() {
    let mut fx = helpers::setup_market_default();
    let _trader = fx.create_funded_manager(0);
    bootstrap_pool(&mut fx, IDLE_SEED);
    let e = new_funded_empty_market(&mut fx, test_constants::default_expiry_ms());

    fx.scenario_mut().next_tx(test_constants::admin());
    let mut market = fx.take_market_bundle(e);

    helpers::begin_valuation(&mut market);
    fx.rebalance_expiry_cash_bundle(&mut market);

    abort 999
}

#[test, expected_failure(abort_code = protocol_config::EValuationInProgress)]
fun create_expiry_market_during_valuation_aborts() {
    let mut fx = helpers::setup_market_default();
    let _trader = fx.create_funded_manager(0);
    bootstrap_pool(&mut fx, IDLE_SEED);

    // Engage the valuation lock on the shared config, then attempt to create a market:
    // create_and_share_expiry_market is an active-set mutation, so it must abort under the lock.
    fx.scenario_mut().next_tx(test_constants::admin());
    let mut config = fx.scenario_mut().take_shared<ProtocolConfig>();
    config.begin_valuation();
    return_shared(config);

    fx.create_expiry(test_constants::default_expiry_ms());

    abort 999
}

#[test]
fun valuation_flow_releases_lock_and_mint_succeeds() {
    let mut fx = helpers::setup_market_default();
    let trader = fx.create_funded_manager(test_constants::default_manager_deposit());
    bootstrap_pool(&mut fx, IDLE_SEED);
    let e = new_funded_empty_market(&mut fx, test_constants::default_expiry_ms());

    fx.scenario_mut().next_tx(test_constants::alice());
    let mut market = fx.take_market_bundle(e);
    let mut account = fx.take_account_bundle(&trader);

    fx.start_flush_bundle(&mut market);
    fx.value_expiry_bundle(&mut market);
    let pool_nav = fx.finish_flush_bundle(&mut market, option::none(), option::none());
    assert_eq!(
        pool_nav,
        constants::expiry_cash_floor!() + (IDLE_SEED - constants::expiry_cash_floor!()),
    );

    // Lock released by finish: the same mint that would have aborted mid-flow now
    // succeeds, adding a position.
    let expiry_id = helpers::market(&market).id();
    let count_before = helpers::position_count_bundle(&account, expiry_id);
    fx.mint_bundle(
        &mut market,
        &mut account,
        helpers::strike_tick(),
        constants::pos_inf_tick!(),
        ONE_X_QUANTITY,
        test_constants::leverage_one_x(),
    );
    assert_eq!(helpers::position_count_bundle(&account, expiry_id), count_before + 1);

    helpers::return_account_bundle(account);
    helpers::return_market_bundle(market);
    fx.finish();
}

// `finish_with_wrong_vault_aborts` is gone with `EWrongPoolVault`: the valuation is
// now a field of the vault it belongs to, so finishing one vault's flush against
// another is unrepresentable rather than rejected at runtime.

/// The Q18 regression: a keeper builds its market list off-chain, a market is settled
/// and swept before the flush executes, and the flush is then handed a market that is no
/// longer in the active set. That used to abort `EExpiryMarketNotActive` and fail the
/// whole flush — observed on testnet as repeated `assert_expiry_ready_to_value` aborts.
/// Both stages now skip it, and the flush completes.
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
    let pool_nav = fx.finish_flush_bundle(&mut market, option::none(), option::none());

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
    let pool_nav = fx.finish_flush_bundle(&mut market, option::none(), option::none());
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
    let pool_nav = fx.finish_flush_bundle(&mut market, option::none(), option::none());
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
    let pool_nav = fx.finish_flush_bundle(&mut market, option::none(), option::none());
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

/// Prepare + fund an already-created market and mint one 1x ATM up order into it.
/// Fund a market to its allocation and mint the standard 1x order into it,
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
        ONE_X_QUANTITY,
        test_constants::leverage_one_x(),
    );
    helpers::assert_atm_entry_probability(quote.entry_probability());
    fx.mint_bundle(
        &mut market,
        &mut account,
        helpers::strike_tick(),
        constants::pos_inf_tick!(),
        ONE_X_QUANTITY,
        test_constants::leverage_one_x(),
    );
    helpers::return_account_bundle(account);
    helpers::return_market_bundle(market);
    quote.net_premium()
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
            test_constants::leverage_one_x(),
        )
        .entry_probability());
    fx.mint_bundle(
        &mut market,
        &mut account,
        helpers::strike_tick(),
        constants::pos_inf_tick!(),
        UNDERWATER_QUANTITY,
        test_constants::leverage_one_x(),
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
    // the stage is atomic this abort reverts `start_pool_valuation` too, which is what
    // keeps the `try_settle` gate from deadlocking against the flush.
    fx.set_clock_for_testing(test_constants::default_expiry_ms());
    fx.scenario_mut().next_tx(test_constants::admin());
    let mut market = fx.take_market_bundle(e);
    fx.start_flush_bundle(&mut market);

    abort 999
}

// === Abandoned-flush escape ===

#[test]
fun privileged_abort_releases_the_lock_and_a_later_flush_succeeds() {
    let mut fx = helpers::setup_market_default();
    bootstrap_pool(&mut fx, IDLE_SEED);
    let e = new_funded_empty_market(&mut fx, test_constants::default_expiry_ms());

    fx.scenario_mut().next_tx(test_constants::admin());
    let mut market = fx.take_market_bundle(e);
    fx.start_flush_bundle(&mut market);
    helpers::return_market_bundle(market);

    // Abandon it: no market valued, no queue drained. The lock survives the
    // transaction boundary, which is exactly the state the hot potato made
    // unreachable and this escape exists to clear.
    fx.scenario_mut().next_tx(test_constants::admin());
    let mut market = fx.take_market_bundle(e);
    fx.abort_valuation_privileged_bundle(&mut market);
    helpers::return_market_bundle(market);

    // The whole flush is repeatable afterwards — the discarded valuation left no
    // residue on the vault, so a fresh snapshot covers the same market again.
    fx.scenario_mut().next_tx(test_constants::admin());
    let mut market = fx.take_market_bundle(e);
    fx.start_flush_bundle(&mut market);
    fx.value_expiry_bundle(&mut market);
    let pool_nav = fx.finish_flush_bundle(&mut market, option::none(), option::none());
    // Exact, not `> 0`: the claim under test is that the discarded valuation left NO
    // residue on the vault, and only an exact mark separates that from "residue exists
    // but NAV is still positive". An empty funded market marks the pool at its idle.
    assert_eq!(pool_nav, IDLE_SEED);

    helpers::return_market_bundle(market);
    fx.finish();
}

#[test, expected_failure(abort_code = plp::EValuationDeadlineNotReached)]
fun permissionless_abort_before_the_deadline_aborts() {
    let mut fx = helpers::setup_market_default();
    bootstrap_pool(&mut fx, IDLE_SEED);
    let e = new_funded_empty_market(&mut fx, test_constants::default_expiry_ms());

    fx.scenario_mut().next_tx(test_constants::admin());
    let mut market = fx.take_market_bundle(e);
    let started_at_ms = fx.clock().timestamp_ms();
    fx.start_flush_bundle(&mut market);

    // One millisecond short of the window: the operator still owns the flush.
    fx.set_clock_for_testing(
        started_at_ms + config_constants::default_max_valuation_window_ms!() - 1,
    );
    fx.abort_valuation_bundle(&mut market);

    abort 999
}

#[test]
fun permissionless_abort_at_the_deadline_releases_the_lock() {
    let mut fx = helpers::setup_market_default();
    bootstrap_pool(&mut fx, IDLE_SEED);
    let e = new_funded_empty_market(&mut fx, test_constants::default_expiry_ms());

    fx.scenario_mut().next_tx(test_constants::admin());
    let mut market = fx.take_market_bundle(e);
    let started_at_ms = fx.clock().timestamp_ms();
    fx.start_flush_bundle(&mut market);

    // Exactly the window: the escape opens. Paired with the test above, this pins the
    // boundary from both sides, so the deadline cannot be widened or dropped silently.
    fx.set_clock_for_testing(started_at_ms + config_constants::default_max_valuation_window_ms!());
    // Engaged before, released after — asserted on the lock itself rather than inferred
    // from an op that happens not to abort. (A second full flush cannot stand in here:
    // an hour has passed, so the Block Scholes surface is stale and the snapshot would
    // abort for an unrelated reason.)
    assert!(helpers::valuation_in_progress_bundle(&market));
    fx.abort_valuation_bundle(&mut market);
    assert!(!helpers::valuation_in_progress_bundle(&market));

    helpers::return_market_bundle(market);
    fx.finish();
}

// === The settlement gate the resumable flush required ===

#[test, expected_failure(abort_code = protocol_config::EValuationInProgress)]
fun settling_during_a_flush_aborts() {
    let mut fx = helpers::setup_market_default();
    bootstrap_pool(&mut fx, IDLE_SEED);
    let e = new_funded_empty_market(&mut fx, test_constants::default_expiry_ms());

    fx.scenario_mut().next_tx(test_constants::admin());
    let mut market = fx.take_market_bundle(e);
    fx.start_flush_bundle(&mut market);

    // A market that crosses its expiry mid-flush must not settle underneath the frozen
    // snapshot: settling would move it off the sweep-vs-value branch it was frozen on.
    fx.set_clock_for_testing(test_constants::default_expiry_ms());
    fx.insert_exact_settlement_spot_bundle(&mut market, test_constants::default_live_price());
    fx.try_settle_bundle(&mut market);

    abort 999
}

// === Only the starter may complete a flush ===

#[test, expected_failure(abort_code = plp::ENotValuationStarter)]
fun a_third_party_cannot_value_a_flush_it_did_not_start() {
    let mut fx = helpers::setup_market_default();
    bootstrap_pool(&mut fx, IDLE_SEED);
    let e = new_funded_empty_market(&mut fx, test_constants::default_expiry_ms());

    fx.scenario_mut().next_tx(test_constants::admin());
    let mut market = fx.take_market_bundle(e);
    fx.start_flush_bundle(&mut market);
    helpers::return_market_bundle(market);

    // The valuation lock is public state and both completion entrypoints are otherwise
    // permissionless, so without this gate anyone could drive an operator's flush.
    fx.scenario_mut().next_tx(test_constants::alice());
    let mut market = fx.take_market_bundle(e);
    fx.value_expiry_bundle(&mut market);

    abort 999
}

#[test, expected_failure(abort_code = plp::ENotValuationStarter)]
fun a_third_party_cannot_finish_a_flush_it_did_not_start() {
    let mut fx = helpers::setup_market_default();
    bootstrap_pool(&mut fx, IDLE_SEED);
    let e = new_funded_empty_market(&mut fx, test_constants::default_expiry_ms());

    fx.scenario_mut().next_tx(test_constants::admin());
    let mut market = fx.take_market_bundle(e);
    fx.start_flush_bundle(&mut market);
    fx.value_expiry_bundle(&mut market);
    helpers::return_market_bundle(market);

    // The griefing shape this closes: finish with zero drain budgets, which retires the
    // frozen mark with no LP request filled and forces the operator to re-value the
    // whole pool. One cheap transaction, repeatable every flush.
    fx.scenario_mut().next_tx(test_constants::alice());
    let mut market = fx.take_market_bundle(e);
    fx.finish_flush_bundle(&mut market, option::some(0), option::some(0));

    abort 999
}

#[test]
fun aborting_after_a_partial_valuation_keeps_moved_cash_and_lets_a_later_flush_finish() {
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

    // Value ONE market, then abandon the flush. `value_expiry` moved cash for m1, and
    // `abort_valuation`'s doc claims that stays moved because a rebalance is
    // invariant-preserving on its own. This is the test of that claim.
    let stage = fx.start_flush(&mut config, &mut vault);
    fx.snapshot_expiry_pricer(&stage, &mut vault, &m1, &config, &oracle_registry, &pyth, &bs);
    fx.snapshot_expiry_pricer(&stage, &mut vault, &m2, &config, &oracle_registry, &pyth, &bs);
    helpers::seal_snapshot(stage, &mut vault, &config);
    fx.value_expiry(&mut vault, &mut m1, &config);
    let m1_cash_after_partial = m1.cash_balance();
    let idle_after_partial = vault.idle_balance();

    // The abort mints its own lifecycle proof, so it needs a fresh transaction for the
    // shared `Registry` to be takeable again. That is also the realistic shape: an
    // abandoned flush is discarded in a later transaction, not the one that stalled.
    fx.scenario_mut().next_tx(test_constants::admin());
    fx.abort_valuation_privileged(&mut vault, &mut config);
    assert_eq!(m1.cash_balance(), m1_cash_after_partial);
    assert_eq!(vault.idle_balance(), idle_after_partial);

    // A fresh flush covers BOTH markets again: the discarded valuation left no
    // exactly-once residue, so m1 is valuable a second time rather than rejected as
    // already valued. The second pass is a no-op for cash — m1 is already at target.
    fx.scenario_mut().next_tx(test_constants::admin());
    let stage = fx.start_flush(&mut config, &mut vault);
    fx.snapshot_expiry_pricer(&stage, &mut vault, &m1, &config, &oracle_registry, &pyth, &bs);
    fx.snapshot_expiry_pricer(&stage, &mut vault, &m2, &config, &oracle_registry, &pyth, &bs);
    helpers::seal_snapshot(stage, &mut vault, &config);
    fx.value_expiry(&mut vault, &mut m1, &config);
    fx.value_expiry(&mut vault, &mut m2, &config);
    let pool_nav = vault.finish_flush(
        &mut config,
        option::none(),
        option::none(),
        fx.scenario_mut().ctx(),
    );
    assert_eq!(m1.cash_balance(), m1_cash_after_partial);
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
    let stage = fx.start_flush(&mut config, &mut vault);
    fx.snapshot_expiry_pricer(&stage, &mut vault, &m_live, &config, &oracle_registry, &pyth, &bs);
    fx.snapshot_expiry_pricer(&stage, &mut vault, &m_doomed, &config, &oracle_registry, &pyth, &bs);
    helpers::seal_snapshot(stage, &mut vault, &config);
    fx.value_expiry(&mut vault, &mut m_live, &config);
    fx.value_expiry(&mut vault, &mut m_doomed, &config);
    let pool_nav = vault.finish_flush(
        &mut config,
        option::none(),
        option::none(),
        fx.scenario_mut().ctx(),
    );

    // That the flush COMPLETED is already the proof the live market was valued:
    // `expected` is {live}, and `finish_flush` asserts every expected market was valued,
    // so a skip of `live` would have aborted `EMissingExpiryValuation` rather than
    // returning. The skip is therefore precise — it dropped the stale market and only
    // the stale market.
    //
    // Pin it on state the flush itself moved, so this cannot pass on a no-op: only
    // `value_expiry` rebalances a live market, and only for a market inside `expected`,
    // so the live market sitting exactly at its cash target proves it was processed
    // rather than skipped alongside the stale one.
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
