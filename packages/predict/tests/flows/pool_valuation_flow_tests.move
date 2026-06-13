// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Flow coverage for the pool NAV hot potato (`plp::start_pool_valuation` /
/// `value_expiry` / `finish_flush`) and its unified per-market cash
/// flush. Tests build production-valid markets through the real creation + funding
/// path, then assert: the aggregated pool NAV equals an INDEPENDENT reference
/// (idle + Σ current_nav, with a zero profit-basis exclusion — unit-tests rule 1),
/// the exactly-once completeness proof fires on a missed / non-snapshot /
/// double-valued market, the valuation lock blocks NAV-changing ops between
/// start and finish, settled markets are swept (cash → idle, profit → reserve,
/// deactivated, 0 NAV) and the sweep is idempotent, and the `lp_pool_value`
/// pricing primitive excludes the protocol profit share and floors at zero.
#[test_only]
module deepbook_predict::pool_valuation_flow_tests;

use deepbook_predict::{
    config_constants,
    constants,
    expiry_market::ExpiryMarket,
    flow_test_helpers as helpers,
    market_oracle::MarketOracle,
    plp::{Self, PoolVault, PLP},
    predict_manager::PredictManager,
    protocol_config::{Self, ProtocolConfig},
    pyth_source::PythSource,
    test_constants
};
use dusdc::dusdc::DUSDC;
use predict_math::math::float_scaling as float;
use std::unit_test::{assert_eq, destroy};
use sui::{coin, test_scenario::return_shared};

/// 1x ATM up range, quantity 2e9 (well under the 50e9 cash floor that backs it).
const ONE_X_QUANTITY: u64 = 2_000_000_000;
/// Idle seed large enough to fund several markets to the cash floor.
const IDLE_SEED: u64 = 1_200_000_000_000;
/// Pure profit seeded onto the settled market (bypasses the ledger, so it shows
/// up as terminal profit on the sweep). Divisible by 10 so the 40% cut is exact.
const SETTLED_EXTRA_CASH: u64 = 1_000_000;

// === Happy path: aggregation ===

#[test]
fun multi_market_pool_nav_is_idle_plus_sum_of_navs() {
    let mut fx = helpers::setup_market_default();
    let mut manager = fx.create_funded_manager(test_constants::default_manager_deposit());
    seed_idle(&mut fx, IDLE_SEED);
    // Create both markets first (grids centered on the creation spot), then fund.
    let (e1, o1) = fx.create_expiry(test_constants::default_expiry_ms());
    let (e2, o2) = fx.create_expiry(test_constants::default_expiry_ms() + 86_400_000);
    fund_market_with_order(&mut fx, &mut manager, e1, o1);
    fund_market_with_order(&mut fx, &mut manager, e2, o2);

    fx.scenario_mut().next_tx(test_constants::alice());
    let mut config = fx.scenario_mut().take_shared<ProtocolConfig>();
    let pyth = fx.scenario_mut().take_shared_by_id<PythSource>(fx.pyth_id());
    let mut vault = fx.scenario_mut().take_shared_by_id<PoolVault>(fx.vault_id());
    let mut m1 = fx.scenario_mut().take_shared_by_id<ExpiryMarket>(e1);
    let oc1 = fx.scenario_mut().take_shared_by_id<MarketOracle>(o1);
    let mut m2 = fx.scenario_mut().take_shared_by_id<ExpiryMarket>(e2);
    let oc2 = fx.scenario_mut().take_shared_by_id<MarketOracle>(o2);

    let mut val = plp::start_pool_valuation(&mut config, &vault);
    val.value_expiry(&mut vault, &mut m1, &config, &oc1, &pyth, fx.clock());
    val.value_expiry(&mut vault, &mut m2, &config, &oc2, &pyth, fx.clock());
    let pool_nav = val.finish_flush(&mut vault, &mut config, fx.scenario_mut().ctx());

    // Independent reference: each market's NAV is read DIRECTLY (not via the
    // potato) and summed by hand, then priced by the separately unit-tested
    // `lp_pool_value` over independently-read idle + profit basis. If the potato
    // skipped a market or threaded the wrong idle/basis, this mismatches.
    let nav1 = m1.current_nav(&config, &oc1, &pyth, fx.clock());
    let nav2 = m2.current_nav(&config, &oc2, &pyth, fx.clock());
    let expected = plp::lp_pool_value(
        vault.idle_balance(),
        vault.profit_basis_credits(),
        vault.profit_basis_debits(),
        config.protocol_reserve_profit_share(),
        nav1 + nav2,
    );
    assert_eq!(pool_nav, expected);
    // The orders took effect: each market's NAV is liability-reduced below its
    // funded cash floor.
    assert!(nav1 < constants::expiry_cash_floor!());
    assert!(nav2 < constants::expiry_cash_floor!());

    return_shared(config);
    return_shared(pyth);
    return_shared(vault);
    return_shared(m1);
    return_shared(oc1);
    return_shared(m2);
    return_shared(oc2);
    destroy(manager);
    fx.finish();
}

#[test]
fun empty_funded_markets_pool_nav_equals_total_idle() {
    let mut fx = helpers::setup_market_default();
    seed_idle(&mut fx, IDLE_SEED);
    let (e1, o1) = fx.create_expiry(test_constants::default_expiry_ms());
    let (e2, o2) = fx.create_expiry(test_constants::default_expiry_ms() + 86_400_000);
    fund_empty_market(&mut fx, e1, o1);
    fund_empty_market(&mut fx, e2, o2);

    fx.scenario_mut().next_tx(test_constants::admin());
    let mut config = fx.scenario_mut().take_shared<ProtocolConfig>();
    let pyth = fx.scenario_mut().take_shared_by_id<PythSource>(fx.pyth_id());
    let mut vault = fx.scenario_mut().take_shared_by_id<PoolVault>(fx.vault_id());
    let mut m1 = fx.scenario_mut().take_shared_by_id<ExpiryMarket>(e1);
    let oc1 = fx.scenario_mut().take_shared_by_id<MarketOracle>(o1);
    let mut m2 = fx.scenario_mut().take_shared_by_id<ExpiryMarket>(e2);
    let oc2 = fx.scenario_mut().take_shared_by_id<MarketOracle>(o2);

    let mut val = plp::start_pool_valuation(&mut config, &vault);
    val.value_expiry(&mut vault, &mut m1, &config, &oc1, &pyth, fx.clock());
    val.value_expiry(&mut vault, &mut m2, &config, &oc2, &pyth, fx.clock());
    let pool_nav = val.finish_flush(&mut vault, &mut config, fx.scenario_mut().ctx());

    // Each funded empty market holds exactly the cash floor as NAV (no liability),
    // so the entire pool NAV is the total idle originally seeded (cash conserved).
    assert_eq!(m1.current_nav(&config, &oc1, &pyth, fx.clock()), constants::expiry_cash_floor!());
    assert_eq!(m2.current_nav(&config, &oc2, &pyth, fx.clock()), constants::expiry_cash_floor!());
    assert_eq!(vault.profit_basis_debits(), 2 * constants::expiry_cash_floor!());
    assert_eq!(vault.profit_basis_credits(), 0);
    assert_eq!(pool_nav, IDLE_SEED);

    return_shared(config);
    return_shared(pyth);
    return_shared(vault);
    return_shared(m1);
    return_shared(oc1);
    return_shared(m2);
    return_shared(oc2);
    fx.finish();
}

#[test]
fun empty_pool_valuation_returns_idle() {
    let idle_seed = 7_000_000;
    let mut fx = helpers::setup_market_default();
    seed_idle(&mut fx, idle_seed);

    fx.scenario_mut().next_tx(test_constants::admin());
    let mut config = fx.scenario_mut().take_shared<ProtocolConfig>();
    let mut vault = fx.scenario_mut().take_shared_by_id<PoolVault>(fx.vault_id());

    // No active markets: start then finish with no value steps returns idle.
    let val = plp::start_pool_valuation(&mut config, &vault);
    let pool_nav = val.finish_flush(&mut vault, &mut config, fx.scenario_mut().ctx());
    assert_eq!(pool_nav, idle_seed);

    return_shared(config);
    return_shared(vault);
    fx.finish();
}

// === Completeness proof ===

#[test, expected_failure(abort_code = plp::EMissingExpiryValuation)]
fun finish_aborts_when_a_snapshotted_market_is_unvalued() {
    let mut fx = helpers::setup_market_default();
    seed_idle(&mut fx, IDLE_SEED);
    let (e1, o1) = fx.create_expiry(test_constants::default_expiry_ms());
    let (e2, o2) = fx.create_expiry(test_constants::default_expiry_ms() + 86_400_000);
    fund_empty_market(&mut fx, e1, o1);
    fund_empty_market(&mut fx, e2, o2);

    fx.scenario_mut().next_tx(test_constants::admin());
    let mut config = fx.scenario_mut().take_shared<ProtocolConfig>();
    let pyth = fx.scenario_mut().take_shared_by_id<PythSource>(fx.pyth_id());
    let mut vault = fx.scenario_mut().take_shared_by_id<PoolVault>(fx.vault_id());
    let mut m1 = fx.scenario_mut().take_shared_by_id<ExpiryMarket>(e1);
    let oc1 = fx.scenario_mut().take_shared_by_id<MarketOracle>(o1);

    let mut val = plp::start_pool_valuation(&mut config, &vault);
    val.value_expiry(&mut vault, &mut m1, &config, &oc1, &pyth, fx.clock());
    // Snapshot held two markets; only one was valued.
    let _ = val.finish_flush(&mut vault, &mut config, fx.scenario_mut().ctx());

    abort 999
}

#[test, expected_failure(abort_code = plp::EExpiryMarketAlreadyValued)]
fun value_expiry_aborts_on_double_value() {
    let mut fx = helpers::setup_market_default();
    seed_idle(&mut fx, IDLE_SEED);
    let (e, o) = new_funded_empty_market(&mut fx, test_constants::default_expiry_ms());

    fx.scenario_mut().next_tx(test_constants::admin());
    let mut config = fx.scenario_mut().take_shared<ProtocolConfig>();
    let pyth = fx.scenario_mut().take_shared_by_id<PythSource>(fx.pyth_id());
    let mut vault = fx.scenario_mut().take_shared_by_id<PoolVault>(fx.vault_id());
    let mut market = fx.scenario_mut().take_shared_by_id<ExpiryMarket>(e);
    let oracle = fx.scenario_mut().take_shared_by_id<MarketOracle>(o);

    let mut val = plp::start_pool_valuation(&mut config, &vault);
    val.value_expiry(&mut vault, &mut market, &config, &oracle, &pyth, fx.clock());
    val.value_expiry(&mut vault, &mut market, &config, &oracle, &pyth, fx.clock());

    abort 999
}

#[test, expected_failure(abort_code = plp::EExpiryMarketNotActive)]
fun value_expiry_aborts_for_deactivated_market() {
    let mut fx = helpers::setup_market_default();
    let (e, o) = settle_and_sweep_market(&mut fx);

    fx.scenario_mut().next_tx(test_constants::admin());
    let mut config = fx.scenario_mut().take_shared<ProtocolConfig>();
    let pyth = fx.scenario_mut().take_shared_by_id<PythSource>(fx.pyth_id());
    let mut vault = fx.scenario_mut().take_shared_by_id<PoolVault>(fx.vault_id());
    let mut market = fx.scenario_mut().take_shared_by_id<ExpiryMarket>(e);
    let oracle = fx.scenario_mut().take_shared_by_id<MarketOracle>(o);

    // The market was deactivated by the earlier sweep, so it is not in the snapshot.
    let mut val = plp::start_pool_valuation(&mut config, &vault);
    val.value_expiry(&mut vault, &mut market, &config, &oracle, &pyth, fx.clock());

    abort 999
}

// === Valuation lock ===

#[test, expected_failure(abort_code = protocol_config::EValuationInProgress)]
fun mint_during_valuation_aborts() {
    let mut fx = helpers::setup_market_default();
    let mut manager = fx.create_funded_manager(test_constants::default_manager_deposit());
    seed_idle(&mut fx, IDLE_SEED);
    let (e, o) = new_funded_empty_market(&mut fx, test_constants::default_expiry_ms());

    fx.scenario_mut().next_tx(test_constants::alice());
    let mut config = fx.scenario_mut().take_shared<ProtocolConfig>();
    let pyth = fx.scenario_mut().take_shared_by_id<PythSource>(fx.pyth_id());
    let mut market = fx.scenario_mut().take_shared_by_id<ExpiryMarket>(e);
    let oracle = fx.scenario_mut().take_shared_by_id<MarketOracle>(o);

    config.begin_valuation();
    fx.mint(
        &config,
        &mut manager,
        &mut market,
        &oracle,
        &pyth,
        helpers::min_strike(),
        constants::pos_inf!(),
        ONE_X_QUANTITY,
        test_constants::leverage_one_x(),
    );

    abort 999
}

#[test, expected_failure(abort_code = protocol_config::EValuationInProgress)]
fun rebalance_during_valuation_aborts() {
    let mut fx = helpers::setup_market_default();
    seed_idle(&mut fx, IDLE_SEED);
    let (e, o) = new_funded_empty_market(&mut fx, test_constants::default_expiry_ms());

    fx.scenario_mut().next_tx(test_constants::admin());
    let mut config = fx.scenario_mut().take_shared<ProtocolConfig>();
    let oracle = fx.scenario_mut().take_shared_by_id<MarketOracle>(o);
    let mut vault = fx.scenario_mut().take_shared_by_id<PoolVault>(fx.vault_id());
    let mut market = fx.scenario_mut().take_shared_by_id<ExpiryMarket>(e);

    config.begin_valuation();
    vault.rebalance_expiry_cash(&mut market, &config, &oracle);

    abort 999
}

#[test, expected_failure(abort_code = protocol_config::EValuationInProgress)]
fun oracle_price_update_during_valuation_aborts() {
    // Part 5: oracle writes are blocked under the valuation lock so the flush prices
    // every market at one frozen oracle snapshot. (The SVI and Pyth update gates are
    // the identical one-line assert; Pyth's `update_from_lazer` has no Move test
    // constructor for `LazerUpdate`, so this covers the market-oracle write path.)
    let mut fx = helpers::setup_market_default();
    let (_e, o) = fx.create_expiry(test_constants::default_expiry_ms());

    fx.scenario_mut().next_tx(test_constants::admin());
    let mut config = fx.scenario_mut().take_shared<ProtocolConfig>();
    let mut oracle = fx.scenario_mut().take_shared_by_id<MarketOracle>(o);

    config.begin_valuation();
    fx.update_block_scholes_prices_for_testing(
        &config,
        &mut oracle,
        test_constants::default_live_price(),
        test_constants::default_live_price(),
        test_constants::live_source_timestamp_ms(),
    );

    abort 999
}

#[test]
fun valuation_flow_releases_lock_and_mint_succeeds() {
    let mut fx = helpers::setup_market_default();
    let mut manager = fx.create_funded_manager(test_constants::default_manager_deposit());
    seed_idle(&mut fx, IDLE_SEED);
    let (e, o) = new_funded_empty_market(&mut fx, test_constants::default_expiry_ms());

    fx.scenario_mut().next_tx(test_constants::alice());
    let mut config = fx.scenario_mut().take_shared<ProtocolConfig>();
    let pyth = fx.scenario_mut().take_shared_by_id<PythSource>(fx.pyth_id());
    let mut vault = fx.scenario_mut().take_shared_by_id<PoolVault>(fx.vault_id());
    let mut market = fx.scenario_mut().take_shared_by_id<ExpiryMarket>(e);
    let oracle = fx.scenario_mut().take_shared_by_id<MarketOracle>(o);

    let mut val = plp::start_pool_valuation(&mut config, &vault);
    val.value_expiry(&mut vault, &mut market, &config, &oracle, &pyth, fx.clock());
    let pool_nav = val.finish_flush(&mut vault, &mut config, fx.scenario_mut().ctx());
    assert_eq!(
        pool_nav,
        constants::expiry_cash_floor!() + (IDLE_SEED - constants::expiry_cash_floor!()),
    );

    // Lock released by finish: the same mint that would have aborted mid-flow now
    // succeeds, adding a position.
    let count_before = manager.expiry_position_count(market.id());
    fx.mint(
        &config,
        &mut manager,
        &mut market,
        &oracle,
        &pyth,
        helpers::min_strike(),
        constants::pos_inf!(),
        ONE_X_QUANTITY,
        test_constants::leverage_one_x(),
    );
    assert_eq!(manager.expiry_position_count(market.id()), count_before + 1);

    return_shared(config);
    return_shared(pyth);
    return_shared(vault);
    return_shared(market);
    return_shared(oracle);
    destroy(manager);
    fx.finish();
}

#[test, expected_failure(abort_code = plp::EWrongPoolVault)]
fun finish_with_wrong_vault_aborts() {
    let mut fx = helpers::setup_market_default();

    fx.scenario_mut().next_tx(test_constants::admin());
    let mut config = fx.scenario_mut().take_shared<ProtocolConfig>();
    let vault = fx.scenario_mut().take_shared_by_id<PoolVault>(fx.vault_id());

    let val = plp::start_pool_valuation(&mut config, &vault);
    // A second, unrelated vault: finishing against it must fail the binding check.
    let cap = coin::create_treasury_cap_for_testing<PLP>(fx.scenario_mut().ctx());
    let mut wrong_vault = plp::new(cap, fx.scenario_mut().ctx());
    let _ = val.finish_flush(&mut wrong_vault, &mut config, fx.scenario_mut().ctx());

    abort 999
}

// === Settled-market sweep ===

#[test]
fun settled_market_is_swept_materialized_and_contributes_zero() {
    let mut fx = helpers::setup_market_default();
    let (e, o) = new_settled_market_with_profit(&mut fx);

    fx.scenario_mut().next_tx(test_constants::admin());
    let mut config = fx.scenario_mut().take_shared<ProtocolConfig>();
    let pyth = fx.scenario_mut().take_shared_by_id<PythSource>(fx.pyth_id());
    let mut vault = fx.scenario_mut().take_shared_by_id<PoolVault>(fx.vault_id());
    let mut market = fx.scenario_mut().take_shared_by_id<ExpiryMarket>(e);
    let oracle = fx.scenario_mut().take_shared_by_id<MarketOracle>(o);

    let mut val = plp::start_pool_valuation(&mut config, &vault);
    val.value_expiry(&mut vault, &mut market, &config, &oracle, &pyth, fx.clock());
    let pool_nav = val.finish_flush(&mut vault, &mut config, fx.scenario_mut().ctx());

    // The 1_000_000 of pure profit splits 40/60: protocol cut to the reserve, LP
    // cut left in idle. The market's cash is fully swept and it deactivates.
    let protocol_cut = 400_000; // mul(1_000_000, 0.4 * float)
    let lp_cut = SETTLED_EXTRA_CASH - protocol_cut; // 600_000
    assert_eq!(vault.protocol_reserve_balance(), protocol_cut);
    assert_eq!(vault.idle_balance(), lp_cut);
    assert_eq!(market.cash_balance(), 0);
    assert!(vault.active_expiry_markets().is_empty());
    // Settled market contributes 0 active NAV, so pool NAV is just the LP cut in idle.
    assert_eq!(pool_nav, lp_cut);

    return_shared(config);
    return_shared(pyth);
    return_shared(vault);
    return_shared(market);
    return_shared(oracle);
    fx.finish();
}

#[test]
fun settled_sweep_is_idempotent() {
    let mut fx = helpers::setup_market_default();
    let (e, o) = new_settled_market_with_profit(&mut fx);

    fx.scenario_mut().next_tx(test_constants::admin());
    let config = fx.scenario_mut().take_shared<ProtocolConfig>();
    let oracle = fx.scenario_mut().take_shared_by_id<MarketOracle>(o);
    let mut vault = fx.scenario_mut().take_shared_by_id<PoolVault>(fx.vault_id());
    let mut market = fx.scenario_mut().take_shared_by_id<ExpiryMarket>(e);

    // First sweep via the public entrypoint (settled branch).
    vault.rebalance_expiry_cash(&mut market, &config, &oracle);
    let idle_after = vault.idle_balance();
    let reserve_after = vault.protocol_reserve_balance();
    assert_eq!(reserve_after, 400_000);
    assert_eq!(idle_after, SETTLED_EXTRA_CASH - 400_000);

    // Second sweep is a safe no-op: no cash returns, no further profit.
    vault.rebalance_expiry_cash(&mut market, &config, &oracle);
    assert_eq!(vault.idle_balance(), idle_after);
    assert_eq!(vault.protocol_reserve_balance(), reserve_after);
    assert_eq!(market.cash_balance(), 0);

    return_shared(config);
    return_shared(oracle);
    return_shared(vault);
    return_shared(market);
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

// === lp_pool_value pricing primitive ===

#[test]
fun lp_pool_value_excludes_protocol_share_and_floors_at_zero() {
    // No unrealized profit (credits + active <= debits): full gross is LP value.
    // gross = 100 + 150 = 250; profit = max(0, (0+150) - 200) = 0; exclusion = 0.
    assert_eq!(plp::lp_pool_value(100, 0, 200, 400_000_000, 150), 250);
    // Unrealized profit excluded at the protocol share.
    // gross = 100 + 100 = 200; profit = (50 + 100) - 0 = 150; exclusion = 150 * 0.5 = 75.
    assert_eq!(plp::lp_pool_value(100, 50, 0, 500_000_000, 100), 125);
    // Sticky exclusion exceeds gross -> floored at 0.
    // gross = 10; profit = (1000 + 0) - 0 = 1000; exclusion = 1000 -> floored to 0.
    assert_eq!(plp::lp_pool_value(10, 1000, 0, 1_000_000_000, 0), 0);
}

// === protocol_reserve_profit_share config ===

#[test]
fun set_protocol_reserve_profit_share_round_trips() {
    let mut fx = helpers::setup_market_default();
    fx.scenario_mut().next_tx(test_constants::admin());
    let mut config = fx.scenario_mut().take_shared<ProtocolConfig>();

    config.set_protocol_reserve_profit_share(123_456_789);
    assert_eq!(config.protocol_reserve_profit_share(), 123_456_789);

    return_shared(config);
    fx.finish();
}

#[test, expected_failure(abort_code = config_constants::EInvalidProtocolReserveProfitShare)]
fun set_protocol_reserve_profit_share_above_max_aborts() {
    let mut fx = helpers::setup_market_default();
    fx.scenario_mut().next_tx(test_constants::admin());
    let mut config = fx.scenario_mut().take_shared<ProtocolConfig>();

    config.set_protocol_reserve_profit_share(float!() + 1);

    abort 999
}

// === Helpers ===

/// Seed pool idle DUSDC directly (the production supply flow is pruned).
fun seed_idle(fx: &mut helpers::Fixture, amount: u64) {
    let vault_id = fx.vault_id();
    fx.scenario_mut().next_tx(test_constants::admin());
    let mut vault = fx.scenario_mut().take_shared_by_id<PoolVault>(vault_id);
    let funds = coin::mint_for_testing<DUSDC>(amount, fx.scenario_mut().ctx());
    vault.receive_idle_for_testing(funds);
    return_shared(vault);
}

/// Create a live market and fund it to the cash floor from idle (no orders).
fun new_funded_empty_market(fx: &mut helpers::Fixture, expiry_ms: u64): (ID, ID) {
    let (e, o) = fx.create_expiry(expiry_ms);
    fund_empty_market(fx, e, o);
    (e, o)
}

/// Prepare an already-created market's oracle live and fund it to the cash floor.
/// Markets must be created (grid centered on the creation spot) BEFORE any oracle
/// is prepared live, because preparing lowers the shared Pyth spot below what
/// grid-centering needs for the next market.
fun fund_empty_market(fx: &mut helpers::Fixture, e: ID, o: ID) {
    fx.scenario_mut().next_tx(test_constants::admin());
    let (mut pyth, mut vault, mut market, mut oracle, config) = fx.take_market(e, o);
    fx.prepare_live_oracle(&config, &mut oracle, &mut pyth, test_constants::default_live_price());
    vault.rebalance_expiry_cash(&mut market, &config, &oracle);
    helpers::return_market(pyth, vault, market, oracle, config);
}

/// Prepare + fund an already-created market and mint one 1x ATM up order into it.
fun fund_market_with_order(fx: &mut helpers::Fixture, manager: &mut PredictManager, e: ID, o: ID) {
    fx.scenario_mut().next_tx(test_constants::alice());
    let (mut pyth, mut vault, mut market, mut oracle, config) = fx.take_market(e, o);
    fx.prepare_live_oracle(&config, &mut oracle, &mut pyth, test_constants::default_live_price());
    vault.rebalance_expiry_cash(&mut market, &config, &oracle);
    fx.mint(
        &config,
        manager,
        &mut market,
        &oracle,
        &pyth,
        helpers::min_strike(),
        constants::pos_inf!(),
        ONE_X_QUANTITY,
        test_constants::leverage_one_x(),
    );
    helpers::return_market(pyth, vault, market, oracle, config);
}

/// Create a market, seed pure profit cash onto it (bypasses the ledger), and
/// settle its oracle so the next sweep returns the cash and materializes profit.
fun new_settled_market_with_profit(fx: &mut helpers::Fixture): (ID, ID) {
    let (e, o) = fx.create_expiry(1_000_000);
    let (mut pyth, vault, mut market, mut oracle, config) = fx.take_market(e, o);
    fx.prepare_live_oracle(&config, &mut oracle, &mut pyth, test_constants::default_live_price());
    fx.seed_market_cash(&mut market, SETTLED_EXTRA_CASH);
    fx.settle_oracle(&config, &mut oracle, &mut pyth, test_constants::default_live_price());
    helpers::return_market(pyth, vault, market, oracle, config);
    (e, o)
}

/// Build a settled market, then sweep + deactivate it through the public flow.
fun settle_and_sweep_market(fx: &mut helpers::Fixture): (ID, ID) {
    let (e, o) = new_settled_market_with_profit(fx);
    fx.scenario_mut().next_tx(test_constants::admin());
    let config = fx.scenario_mut().take_shared<ProtocolConfig>();
    let oracle = fx.scenario_mut().take_shared_by_id<MarketOracle>(o);
    let mut vault = fx.scenario_mut().take_shared_by_id<PoolVault>(fx.vault_id());
    let mut market = fx.scenario_mut().take_shared_by_id<ExpiryMarket>(e);
    vault.rebalance_expiry_cash(&mut market, &config, &oracle);
    return_shared(config);
    return_shared(oracle);
    return_shared(vault);
    return_shared(market);
    (e, o)
}
