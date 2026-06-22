// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Flow coverage for the pool NAV hot potato (`start_flush` /
/// `value_expiry` / `finish_flush`) and its unified per-market cash
/// flush. Tests build production-valid markets through the real creation + funding
/// path, then assert: the aggregated pool NAV equals an INDEPENDENT reference
/// (idle + Σ current_nav, with a zero profit-basis exclusion — unit-tests rule 1),
/// the exactly-once completeness proof fires on a missed / double-valued market,
/// the valuation lock blocks NAV-changing ops between start and finish, and the
/// `lp_pool_value` pricing primitive excludes the protocol profit share and floors
/// at zero. Passive settled-market sweep coverage lives in
/// `settlement_flow_tests`.
#[test_only]
module deepbook_predict::pool_valuation_flow_tests;

use deepbook_predict::{
    admin,
    config_constants,
    constants,
    expiry_market::ExpiryMarket,
    flow_test_helpers as helpers,
    plp::{Self, PoolVault, PLP},
    protocol_config::{Self, ProtocolConfig},
    test_constants
};
use dusdc::dusdc::DUSDC;
use fixed_math::math::float_scaling as float;
use propbook::{block_scholes_feed::BlockScholesFeed, pyth_feed::PythFeed, registry::OracleRegistry};
use std::unit_test::{assert_eq, destroy};
use sui::{coin, test_scenario::return_shared};

/// 1x ATM up range, quantity 2e9 (well under the 50e9 cash floor that backs it).
const ONE_X_QUANTITY: u64 = 2_000_000_000;
/// Idle seed large enough to fund several markets to the cash floor.
const IDLE_SEED: u64 = 1_200_000_000_000;

// === Happy path: aggregation ===

#[test]
fun multi_market_pool_nav_is_idle_plus_sum_of_navs() {
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
    let bs = fx.scenario_mut().take_shared_by_id<BlockScholesFeed>(fx.bs_id());
    let oracle_registry = fx.scenario_mut().take_shared<OracleRegistry>();
    let mut vault = fx.scenario_mut().take_shared_by_id<PoolVault>(fx.vault_id());
    let mut m1 = fx.scenario_mut().take_shared_by_id<ExpiryMarket>(e1);
    let mut m2 = fx.scenario_mut().take_shared_by_id<ExpiryMarket>(e2);

    let mut val = fx.start_flush(&mut config, &vault);
    fx.value_expiry(&mut val, &mut vault, &mut m1, &config, &oracle_registry, &pyth, &bs);
    fx.value_expiry(&mut val, &mut vault, &mut m2, &config, &oracle_registry, &pyth, &bs);
    let pool_nav = val.finish_flush(
        &mut vault,
        &mut config,
        option::none(),
        option::none(),
        fx.scenario_mut().ctx(),
    );

    // Independent reference: each market's NAV is read DIRECTLY (not via the
    // potato) and summed by hand, then priced by the separately unit-tested
    // `lp_pool_value` over independently-read idle + profit basis. If the potato
    // skipped a market or threaded the wrong idle/basis, this mismatches.
    let nav1 = fx.current_nav(&m1, &config, &oracle_registry, &pyth, &bs);
    let nav2 = fx.current_nav(&m2, &config, &oracle_registry, &pyth, &bs);
    let expected = plp::lp_pool_value(
        vault.idle_balance(),
        vault.profit_basis_credits(),
        vault.profit_basis_debits(),
        config.protocol_reserve_profit_share(),
        nav1 + nav2,
        vault.pending_protocol_profit(),
    );
    assert_eq!(pool_nav, expected);
    // The orders took effect: each market's NAV is liability-reduced below its
    // funded cash floor.
    assert!(nav1 < constants::expiry_cash_floor!());
    assert!(nav2 < constants::expiry_cash_floor!());

    return_shared(config);
    return_shared(pyth);
    return_shared(bs);
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
    let bs = fx.scenario_mut().take_shared_by_id<BlockScholesFeed>(fx.bs_id());
    let oracle_registry = fx.scenario_mut().take_shared<OracleRegistry>();
    let mut vault = fx.scenario_mut().take_shared_by_id<PoolVault>(fx.vault_id());
    let mut m1 = fx.scenario_mut().take_shared_by_id<ExpiryMarket>(e1);
    let mut m2 = fx.scenario_mut().take_shared_by_id<ExpiryMarket>(e2);

    let mut val = fx.start_flush(&mut config, &vault);
    fx.value_expiry(&mut val, &mut vault, &mut m1, &config, &oracle_registry, &pyth, &bs);
    fx.value_expiry(&mut val, &mut vault, &mut m2, &config, &oracle_registry, &pyth, &bs);
    let pool_nav = val.finish_flush(
        &mut vault,
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
    return_shared(bs);
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

    // No active markets: start then finish with no value steps returns idle.
    let val = fx.start_flush(&mut config, &vault);
    let pool_nav = val.finish_flush(
        &mut vault,
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
    let bs = fx.scenario_mut().take_shared_by_id<BlockScholesFeed>(fx.bs_id());
    let oracle_registry = fx.scenario_mut().take_shared<OracleRegistry>();
    let mut vault = fx.scenario_mut().take_shared_by_id<PoolVault>(fx.vault_id());
    let mut m1 = fx.scenario_mut().take_shared_by_id<ExpiryMarket>(e1);

    let mut val = fx.start_flush(&mut config, &vault);
    fx.value_expiry(&mut val, &mut vault, &mut m1, &config, &oracle_registry, &pyth, &bs);
    // Snapshot held two markets; only one was valued.
    let _ = val.finish_flush(
        &mut vault,
        &mut config,
        option::none(),
        option::none(),
        fx.scenario_mut().ctx(),
    );

    abort 999
}

#[test, expected_failure(abort_code = plp::EExpiryMarketAlreadyValued)]
fun value_expiry_aborts_on_double_value() {
    let mut fx = helpers::setup_market_default();
    let _trader = fx.create_funded_manager(0);
    bootstrap_pool(&mut fx, IDLE_SEED);
    let e = new_funded_empty_market(&mut fx, test_constants::default_expiry_ms());

    fx.scenario_mut().next_tx(test_constants::admin());
    let mut config = fx.scenario_mut().take_shared<ProtocolConfig>();
    let pyth = fx.scenario_mut().take_shared_by_id<PythFeed>(fx.pyth_id());
    let bs = fx.scenario_mut().take_shared_by_id<BlockScholesFeed>(fx.bs_id());
    let oracle_registry = fx.scenario_mut().take_shared<OracleRegistry>();
    let mut vault = fx.scenario_mut().take_shared_by_id<PoolVault>(fx.vault_id());
    let mut market = fx.scenario_mut().take_shared_by_id<ExpiryMarket>(e);

    let mut val = fx.start_flush(&mut config, &vault);
    fx.value_expiry(&mut val, &mut vault, &mut market, &config, &oracle_registry, &pyth, &bs);
    fx.value_expiry(&mut val, &mut vault, &mut market, &config, &oracle_registry, &pyth, &bs);

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
    let mut config = fx.scenario_mut().take_shared<ProtocolConfig>();
    let pyth = fx.scenario_mut().take_shared_by_id<PythFeed>(fx.pyth_id());
    let bs = fx.scenario_mut().take_shared_by_id<BlockScholesFeed>(fx.bs_id());
    let oracle_registry = fx.scenario_mut().take_shared<OracleRegistry>();
    let mut market = fx.scenario_mut().take_shared_by_id<ExpiryMarket>(e);
    let mut wrapper = fx.take_account(&trader);
    let root = fx.take_root();

    config.begin_valuation();
    fx.mint(
        &config,
        &oracle_registry,
        &mut wrapper,
        &root,
        &mut market,
        &pyth,
        &bs,
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
    let mut config = fx.scenario_mut().take_shared<ProtocolConfig>();
    let pyth = fx.scenario_mut().take_shared_by_id<PythFeed>(fx.pyth_id());
    let oracle_registry = fx.scenario_mut().take_shared<OracleRegistry>();
    let mut vault = fx.scenario_mut().take_shared_by_id<PoolVault>(fx.vault_id());
    let mut market = fx.scenario_mut().take_shared_by_id<ExpiryMarket>(e);

    config.begin_valuation();
    fx.rebalance_expiry_cash(&mut vault, &mut market, &config, &oracle_registry, &pyth);

    abort 999
}

#[test, expected_failure(abort_code = protocol_config::EValuationInProgress)]
fun create_expiry_market_during_valuation_aborts() {
    let mut fx = helpers::setup_market_default();
    let _trader = fx.create_funded_manager(0);
    bootstrap_pool(&mut fx, IDLE_SEED);

    // Engage the valuation lock on the shared config, then attempt to create a market:
    // create_expiry_market is an active-set mutation, so it must abort under the lock.
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
    let mut config = fx.scenario_mut().take_shared<ProtocolConfig>();
    let pyth = fx.scenario_mut().take_shared_by_id<PythFeed>(fx.pyth_id());
    let bs = fx.scenario_mut().take_shared_by_id<BlockScholesFeed>(fx.bs_id());
    let oracle_registry = fx.scenario_mut().take_shared<OracleRegistry>();
    let mut vault = fx.scenario_mut().take_shared_by_id<PoolVault>(fx.vault_id());
    let mut market = fx.scenario_mut().take_shared_by_id<ExpiryMarket>(e);
    let mut wrapper = fx.take_account(&trader);
    let root = fx.take_root();

    let mut val = fx.start_flush(&mut config, &vault);
    fx.value_expiry(&mut val, &mut vault, &mut market, &config, &oracle_registry, &pyth, &bs);
    let pool_nav = val.finish_flush(
        &mut vault,
        &mut config,
        option::none(),
        option::none(),
        fx.scenario_mut().ctx(),
    );
    assert_eq!(
        pool_nav,
        constants::expiry_cash_floor!() + (IDLE_SEED - constants::expiry_cash_floor!()),
    );

    // Lock released by finish: the same mint that would have aborted mid-flow now
    // succeeds, adding a position.
    let count_before = helpers::position_count(&wrapper, market.id());
    fx.mint(
        &config,
        &oracle_registry,
        &mut wrapper,
        &root,
        &mut market,
        &pyth,
        &bs,
        helpers::strike_tick(),
        constants::pos_inf_tick!(),
        ONE_X_QUANTITY,
        test_constants::leverage_one_x(),
    );
    assert_eq!(helpers::position_count(&wrapper, market.id()), count_before + 1);

    helpers::return_account(wrapper, root);
    return_shared(config);
    return_shared(pyth);
    return_shared(bs);
    return_shared(oracle_registry);
    return_shared(vault);
    return_shared(market);
    fx.finish();
}

#[test, expected_failure(abort_code = plp::EWrongPoolVault)]
fun finish_with_wrong_vault_aborts() {
    let mut fx = helpers::setup_market_default();
    fx.bootstrap_lock(constants::min_bootstrap_liquidity!()); // flush start requires a bootstrapped pool

    fx.scenario_mut().next_tx(test_constants::admin());
    let mut config = fx.scenario_mut().take_shared<ProtocolConfig>();
    let vault = fx.scenario_mut().take_shared_by_id<PoolVault>(fx.vault_id());

    let val = fx.start_flush(&mut config, &vault);
    // A second, unrelated vault: finishing against it must fail the binding check.
    let cap = coin::create_treasury_cap_for_testing<PLP>(fx.scenario_mut().ctx());
    let mut wrong_vault = plp::new(cap, fx.scenario_mut().ctx());
    let _ = val.finish_flush(
        &mut wrong_vault,
        &mut config,
        option::none(),
        option::none(),
        fx.scenario_mut().ctx(),
    );

    abort 999
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
    assert_eq!(plp::lp_pool_value(100, 0, 200, 400_000_000, 150, 0), 250);
    // Unrealized profit excluded at the protocol share.
    // gross = 100 + 100 = 200; profit = (50 + 100) - 0 = 150; exclusion = 150 * 0.5 = 75.
    assert_eq!(plp::lp_pool_value(100, 50, 0, 500_000_000, 100, 0), 125);
    // Sticky exclusion exceeds gross -> floored at 0.
    // gross = 10; profit = (1000 + 0) - 0 = 1000; exclusion = 1000 -> floored to 0.
    assert_eq!(plp::lp_pool_value(10, 1000, 0, 1_000_000_000, 0, 0), 0);
    // Carried pending protocol cut is excluded on top of the unrealized exclusion.
    // gross = 300 + 100 = 400; profit = (0+100) - 0 = 100; exclusion = 100 * 0.5 = 50;
    // pending = 40; 400 - 50 - 40 = 310.
    assert_eq!(plp::lp_pool_value(300, 0, 0, 500_000_000, 100, 40), 310);
    // Pending alone exceeding gross floors LP value at 0.
    // gross = 100; exclusion = 0; pending = 150 > gross -> floored to 0.
    assert_eq!(plp::lp_pool_value(100, 0, 0, 0, 0, 150), 0);
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
    let (mut pyth, mut bs, oracle_registry, mut vault, mut market, config) = fx.take_market(e);
    fx.prepare_live_oracle(&market, &mut pyth, &mut bs, test_constants::default_live_price());
    fx.rebalance_expiry_cash(&mut vault, &mut market, &config, &oracle_registry, &pyth);
    helpers::return_market(pyth, bs, oracle_registry, vault, market, config);
}

/// Prepare + fund an already-created market and mint one 1x ATM up order into it.
fun fund_market_with_order(fx: &mut helpers::Fixture, trader: &helpers::Trader, e: ID) {
    fx.scenario_mut().next_tx(test_constants::alice());
    let (mut pyth, mut bs, oracle_registry, mut vault, mut market, config) = fx.take_market(e);
    let mut wrapper = fx.take_account(trader);
    let root = fx.take_root();
    fx.prepare_live_oracle(&market, &mut pyth, &mut bs, test_constants::default_live_price());
    fx.rebalance_expiry_cash(&mut vault, &mut market, &config, &oracle_registry, &pyth);
    fx.mint(
        &config,
        &oracle_registry,
        &mut wrapper,
        &root,
        &mut market,
        &pyth,
        &bs,
        helpers::strike_tick(),
        constants::pos_inf_tick!(),
        ONE_X_QUANTITY,
        test_constants::leverage_one_x(),
    );
    helpers::return_account(wrapper, root);
    helpers::return_market(pyth, bs, oracle_registry, vault, market, config);
}
