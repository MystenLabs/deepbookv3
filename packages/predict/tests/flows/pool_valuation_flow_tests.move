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

    fx.start_flush(&mut config, &mut vault);
    fx.snapshot_expiry_pricer(&mut vault, &m1, &config, &oracle_registry, &pyth, &bs);
    fx.snapshot_expiry_pricer(&mut vault, &m2, &config, &oracle_registry, &pyth, &bs);
    helpers::seal_snapshot(&mut vault, &config);
    helpers::value_expiry(&mut vault, &mut m1, &config);
    helpers::value_expiry(&mut vault, &mut m2, &config);
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

    fx.start_flush(&mut config, &mut vault);
    fx.snapshot_expiry_pricer(&mut vault, &m1, &config, &oracle_registry, &pyth, &bs);
    fx.snapshot_expiry_pricer(&mut vault, &m2, &config, &oracle_registry, &pyth, &bs);
    helpers::seal_snapshot(&mut vault, &config);
    helpers::value_expiry(&mut vault, &mut m1, &config);
    helpers::value_expiry(&mut vault, &mut m2, &config);
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
    fx.start_flush(&mut config, &mut vault);
    helpers::seal_snapshot(&mut vault, &config);
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
    fx.start_flush(&mut config, &mut vault);
    fx.snapshot_expiry_pricer(&mut vault, &m1, &config, &oracle_registry, &pyth, &bs);
    fx.snapshot_expiry_pricer(&mut vault, &m2, &config, &oracle_registry, &pyth, &bs);
    helpers::seal_snapshot(&mut vault, &config);
    helpers::value_expiry(&mut vault, &mut m1, &config);
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
    fx.start_flush(&mut config, &mut vault);
    fx.snapshot_expiry_pricer(&mut vault, &m1, &config, &oracle_registry, &pyth, &bs);
    fx.snapshot_expiry_pricer(&mut vault, &m2, &config, &oracle_registry, &pyth, &bs);
    helpers::seal_snapshot(&mut vault, &config);

    // Valuation stage, transaction 1 of 2.
    helpers::value_expiry(&mut vault, &mut m1, &config);

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
    helpers::value_expiry(&mut vault, &mut m2, &config);

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
    fx.start_flush(&mut config, &mut vault);
    fx.snapshot_expiry_pricer(&mut vault, &m1, &config, &oracle_registry, &pyth, &bs);
    helpers::seal_snapshot(&mut vault, &config);

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

    fx.start_flush(&mut config, &mut vault);
    fx.snapshot_expiry_pricer(&mut vault, &m, &config, &oracle_registry, &pyth, &bs);
    helpers::value_expiry(&mut vault, &mut m, &config);

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
    helpers::value_expiry_bundle(&mut market);
    helpers::value_expiry_bundle(&mut market);

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
    helpers::value_expiry_bundle(&mut market);
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
    assert!(fx.try_settle_bundle(&mut market));
    fx.rebalance_expiry_cash_bundle(&mut market);
    helpers::return_market_bundle(market);

    fx.scenario_mut().next_tx(test_constants::admin());
    let mut market = fx.take_market_bundle(e);
    fx.start_flush_bundle(&mut market);
    helpers::value_expiry_bundle(&mut market);

    abort 999
}

#[test]
fun finish_flush_with_zero_pool_nav_and_empty_queues_succeeds() {
    let (mut fx, e) = setup_underwater_market(0);

    fx.scenario_mut().next_tx(test_constants::admin());
    let mut market = fx.take_market_bundle(e);
    fx.start_flush_bundle(&mut market);
    helpers::value_expiry_bundle(&mut market);
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
    helpers::value_expiry_bundle(&mut market);
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
    helpers::value_expiry_bundle(&mut market);
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
