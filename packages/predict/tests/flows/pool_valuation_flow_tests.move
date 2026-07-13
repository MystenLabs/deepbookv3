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
    protocol_config::{Self, ProtocolConfig},
    test_constants
};
use fixed_math::math::float_scaling as float;
use propbook::{pyth_feed::PythFeed, registry::OracleRegistry};
use std::unit_test::{assert_eq, destroy};
use sui::test_scenario::return_shared;

/// 1x ATM up range, quantity 2e9 (well under the 50e9 cash floor that backs it).
const ONE_X_QUANTITY: u64 = 2_000_000_000;
/// Idle seed large enough to fund several markets to the cash floor.
const IDLE_SEED: u64 = 1_200_000_000_000;
/// `value_expiry` sweeps each minted market back to the 10e9 cash target. With a
/// 5m rebate reserve and 1e9 ATM liability, each active market contributes this NAV.
const POST_VALUATION_MARKET_NAV: u64 = 8_995_000_000;
/// Two markets each sweep 1.01e9 of mint premium + fees back to idle.
const POST_VALUATION_IDLE: u64 = 1_182_020_000_000;
const POST_VALUATION_PROFIT_CREDITS: u64 = 2_020_000_000;
const POST_VALUATION_PROFIT_DEBITS: u64 = 20_000_000_000;
/// Gross pool value is idle + active NAV = 1_200.01e9. Profit basis is 10m, so
/// the protocol's 40% cut excludes 4m from LP NAV.
const TWO_MARKET_POOL_NAV: u64 = 1_200_006_000_000;
/// Leave exactly 1e9 idle after funding a 250e9 expiry. With 251e9 PLP supply,
/// that mark is a very low but executable fair PLP price.
const BELOW_MIN_PRICE_IDLE: u64 = 1_000_000_000;
/// Large 1x order used to drive a fully-funded market underwater after a price jump.
const UNDERWATER_QUANTITY: u64 = 500_000_000_000;
const UNDERWATER_TRADER_DEPOSIT: u64 = 400_000_000_000;
const DEEP_ITM_LIVE_PRICE: u64 = 1_000_000_000_000;
const REPRICE_MS: u64 = 121_000;
const REPRICE_SOURCE_TS: u64 = 119_500;
/// Empty-market cash above the 10e9 target. Valuation sweeps the 1e9 surplus to
/// idle and leaves 10e9 active NAV. With the protocol's 40% profit exclusion on
/// the 11e9 active+returned credit basis, the frozen LP mark is 6.61e9.
const ABOVE_MAX_PRICE_MARKET_CASH: u64 = 11_000_000_000;
const ABOVE_MAX_PRICE_POOL_NAV: u64 = 6_610_000_000;

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
    let bs = fx.take_bs();
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

    // Hand-derived fixture values. This pins `finish_flush` reading the
    // vault-owned ledger fields without copying the private `lp_pool_value` formula.
    let nav1 = fx.current_nav(&m1, &config, &oracle_registry, &pyth, &bs);
    let nav2 = fx.current_nav(&m2, &config, &oracle_registry, &pyth, &bs);
    assert_eq!(nav1, POST_VALUATION_MARKET_NAV);
    assert_eq!(nav2, POST_VALUATION_MARKET_NAV);
    assert_eq!(vault.idle_balance(), POST_VALUATION_IDLE);
    assert_eq!(vault.profit_basis_credits(), POST_VALUATION_PROFIT_CREDITS);
    assert_eq!(vault.profit_basis_debits(), POST_VALUATION_PROFIT_DEBITS);
    assert_eq!(vault.pending_protocol_profit(), 0);
    assert_eq!(pool_nav, TWO_MARKET_POOL_NAV);

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
    let mut market = fx.take_market_bundle(e1);

    let mut val = fx.start_flush_bundle(&mut market);
    fx.value_expiry_bundle(&mut val, &mut market);
    // Snapshot held two markets; only one was valued.
    let _ = fx.finish_flush_bundle(val, &mut market, option::none(), option::none());

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

    let mut val = fx.start_flush_bundle(&mut market);
    fx.value_expiry_bundle(&mut val, &mut market);
    fx.value_expiry_bundle(&mut val, &mut market);

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

    let mut val = fx.start_flush_bundle(&mut market);
    fx.value_expiry_bundle(&mut val, &mut market);
    let pool_nav = fx.finish_flush_bundle(val, &mut market, option::none(), option::none());
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

#[test, expected_failure(abort_code = plp::EWrongPoolVault)]
fun finish_with_wrong_vault_aborts() {
    let mut fx = helpers::setup_market_default();
    fx.bootstrap_lock(constants::min_bootstrap_liquidity!()); // flush start requires a bootstrapped pool

    fx.scenario_mut().next_tx(test_constants::admin());
    let wrong_vault_id = plp::init_for_testing(fx.scenario_mut().ctx());

    fx.scenario_mut().next_tx(test_constants::admin());
    let mut config = fx.scenario_mut().take_shared<ProtocolConfig>();
    let vault = fx.scenario_mut().take_shared_by_id<PoolVault>(fx.vault_id());

    let val = fx.start_flush(&mut config, &vault);
    // A second, unrelated vault created through the normal test init path:
    // finishing against it must fail the binding check.
    let mut wrong_vault = fx.scenario_mut().take_shared_by_id<PoolVault>(wrong_vault_id);
    let _ = val.finish_flush(
        &mut wrong_vault,
        &mut config,
        option::none(),
        option::none(),
        fx.scenario_mut().ctx(),
    );

    abort 999
}

#[test, expected_failure(abort_code = plp::EExpiryMarketNotActive)]
fun value_expiry_for_inactive_market_aborts() {
    let mut fx = helpers::setup_market_default();
    let _trader = fx.create_funded_manager(0);
    bootstrap_pool(&mut fx, IDLE_SEED);
    let e = new_funded_empty_market(&mut fx, test_constants::default_expiry_ms());

    fx.set_clock_for_testing(test_constants::default_expiry_ms());
    fx.scenario_mut().next_tx(test_constants::admin());
    let mut market = fx.take_market_bundle(e);
    fx.insert_exact_settlement_spot_bundle(
        &mut market,
        test_constants::default_live_price(),
    );
    fx.rebalance_expiry_cash_bundle(&mut market);
    helpers::return_market_bundle(market);

    fx.scenario_mut().next_tx(test_constants::admin());
    let mut market = fx.take_market_bundle(e);
    let mut val = fx.start_flush_bundle(&mut market);
    fx.value_expiry_bundle(&mut val, &mut market);

    abort 999
}

#[test]
fun finish_flush_with_zero_pool_nav_and_empty_queues_succeeds() {
    let (mut fx, e) = setup_underwater_market(0);

    fx.scenario_mut().next_tx(test_constants::admin());
    let mut market = fx.take_market_bundle(e);
    let mut val = fx.start_flush_bundle(&mut market);
    fx.value_expiry_bundle(&mut val, &mut market);
    let pool_nav = fx.finish_flush_bundle(val, &mut market, option::none(), option::none());
    assert_eq!(pool_nav, 0);

    helpers::return_market_bundle(market);
    fx.finish();
}

#[test]
fun finish_flush_with_low_plp_price_and_empty_queues_succeeds() {
    let (mut fx, e) = setup_underwater_market(BELOW_MIN_PRICE_IDLE);

    fx.scenario_mut().next_tx(test_constants::admin());
    let mut market = fx.take_market_bundle(e);
    let mut val = fx.start_flush_bundle(&mut market);
    fx.value_expiry_bundle(&mut val, &mut market);
    let pool_nav = fx.finish_flush_bundle(val, &mut market, option::none(), option::none());
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

    let mut val = fx.start_flush_bundle(&mut market);
    fx.value_expiry_bundle(&mut val, &mut market);
    let pool_nav = fx.finish_flush_bundle(val, &mut market, option::none(), option::none());
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
fun fund_market_with_order(fx: &mut helpers::Fixture, trader: &helpers::Trader, e: ID) {
    fx.scenario_mut().next_tx(test_constants::alice());
    let mut market = fx.take_market_bundle(e);
    let mut account = fx.take_account_bundle(trader);
    fx.prepare_live_oracle_bundle(&mut market, test_constants::default_live_price());
    fx.rebalance_expiry_cash_bundle(&mut market);
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
}

/// Build a production-created market whose full pool allocation is deployed into
/// expiry cash, then mint an ATM UP order and reprice it deep in the money. The
/// repriced live liability exceeds free cash, so the market contributes zero NAV;
/// `idle_remainder` is the only pool NAV left for `finish_flush`.
fun setup_underwater_market(idle_remainder: u64): (helpers::Fixture, ID) {
    let mut fx = helpers::setup_market_default();
    let market_allocation = test_constants::default_max_expiry_allocation();
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
    fx.mint_bundle(
        &mut market,
        &mut account,
        helpers::strike_tick(),
        constants::pos_inf_tick!(),
        UNDERWATER_QUANTITY,
        test_constants::leverage_one_x(),
    );
    fx.set_clock_for_testing(REPRICE_MS);
    fx.prepare_live_oracle_bundle_at(&mut market, DEEP_ITM_LIVE_PRICE, REPRICE_SOURCE_TS);

    helpers::return_account_bundle(account);
    helpers::return_market_bundle(market);
    (fx, e)
}
