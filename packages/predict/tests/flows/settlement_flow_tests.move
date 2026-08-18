// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Terminal settlement flow coverage: exact Propbook timestamp settlement,
/// settled redeem, and the settled-market PLP sweep.
#[test_only]
module deepbook_predict::settlement_flow_tests;

use account::account_registry;
use deepbook_predict::{
    config_constants,
    config_events,
    expiry_market,
    flow_test_helpers as helpers,
    plp,
    predict_account,
    pricing,
    test_constants
};
use propbook::{pyth_feed::PythFeed, registry::{Self as propbook_registry, OracleRegistry}};
use std::unit_test::assert_eq;
use sui::{event, test_scenario::return_shared};
use token::deep::DEEP;

const SECOND_SOURCE_ID: u32 = 2;
const IDLE_SEED: u64 = 1_200_000_000_000;

/// Per-trade fee floor for the default flow fixture.
const MINT_MIN_FEE: u64 = 5_000_000;
/// Rebate reserve after one 5e6 trading fee at the default 50% rebate rate.
const REBATE_AFTER_MINT: u64 = 2_500_000;
const MARKET_SETTLED_EVENT_COUNT: u64 = 1;
const ACTIVE_MARKET_COUNT: u64 = 1;

/// Even with the exact Propbook spot recorded, permissionless `redeem_settled`
/// requires the explicit settlement transition instead of settling implicitly.
#[test, expected_failure(abort_code = expiry_market::EMarketNotSettled)]
fun settled_redeem_requires_explicit_settlement() {
    let (mut fx, expiry_id, trader) = helpers::setup_live_market(
        test_constants::short_expiry_ms(),
        test_constants::default_live_price(),
    );
    fx.scenario_mut().next_tx(test_constants::alice());
    let mut market = fx.take_market_bundle(expiry_id);
    let mut account = fx.take_account_bundle(&trader);

    let order_id = fx.mint_bundle(
        &mut market,
        &mut account,
        helpers::strike_tick(),
        helpers::strike_tick() + 10,
        test_constants::mint_quantity(),
    );

    fx.set_clock_for_testing(test_constants::short_expiry_ms());
    fx.insert_exact_settlement_spot_bundle(
        &mut market,
        settlement_inside_default_finite_range(),
    );
    fx.redeem_settled_bundle(
        &mut market,
        &mut account,
        order_id,
    );

    abort 999
}

#[test]
fun try_settle_before_expiry_returns_false_without_mutation() {
    let mut fx = helpers::setup_market_default();
    let expiry_id = fx.create_expiry(test_constants::default_expiry_ms());

    fx.scenario_mut().next_tx(test_constants::admin());
    let mut oracle_registry = fx.scenario_mut().take_shared<OracleRegistry>();
    let wrong_pyth_id = propbook_registry::create_and_share_pyth_feed(
        &mut oracle_registry,
        SECOND_SOURCE_ID,
        fx.scenario_mut().ctx(),
    );
    return_shared(oracle_registry);

    fx.scenario_mut().next_tx(test_constants::admin());
    let mut market = fx.take_market_bundle(expiry_id);
    let wrong_pyth = fx.scenario_mut().take_shared_by_id<PythFeed>(wrong_pyth_id);
    // Expiry is checked before the pricing-owned oracle binding check.
    assert_eq!(fx.try_settle_bundle_with_pyth(&mut market, &wrong_pyth), false);
    assert!(!helpers::market(&market).is_settled());
    assert_eq!(helpers::market(&market).try_settlement_price(), option::none());

    helpers::return_market_bundle(market);
    return_shared(wrong_pyth);
    fx.finish();
}

#[test]
fun try_settle_without_exact_expiry_spot_returns_false_without_mutation() {
    let mut fx = helpers::setup_market_default();
    let expiry_id = fx.create_expiry(test_constants::default_expiry_ms());
    fx.set_clock_for_testing(test_constants::default_expiry_ms());

    fx.scenario_mut().next_tx(test_constants::admin());
    let mut market = fx.take_market_bundle(expiry_id);
    assert_eq!(fx.try_settle_bundle(&mut market), false);
    assert!(!helpers::market(&market).is_settled());
    assert_eq!(helpers::market(&market).try_settlement_price(), option::none());

    helpers::return_market_bundle(market);
    fx.finish();
}

#[test, expected_failure(abort_code = pricing::EWrongPythFeed)]
fun try_settle_with_wrong_pyth_feed_aborts() {
    let mut fx = helpers::setup_market_default();
    let expiry_id = fx.create_expiry(test_constants::default_expiry_ms());
    fx.set_clock_for_testing(test_constants::default_expiry_ms());

    fx.scenario_mut().next_tx(test_constants::admin());
    let mut oracle_registry = fx.scenario_mut().take_shared<OracleRegistry>();
    let wrong_pyth_id = propbook_registry::create_and_share_pyth_feed(
        &mut oracle_registry,
        SECOND_SOURCE_ID,
        fx.scenario_mut().ctx(),
    );
    return_shared(oracle_registry);

    fx.scenario_mut().next_tx(test_constants::admin());
    let mut market = fx.take_market_bundle(expiry_id);
    let wrong_pyth = fx.scenario_mut().take_shared_by_id<PythFeed>(wrong_pyth_id);

    fx.try_settle_bundle_with_pyth(&mut market, &wrong_pyth);

    abort 999
}

#[test, expected_failure(abort_code = pricing::EWrongPythFeed)]
fun try_settle_rejects_old_pyth_after_propbook_rebind() {
    let mut fx = helpers::setup_market_default();
    let expiry_id = fx.create_expiry(test_constants::default_expiry_ms());
    let _rebound_pyth_id = fx.create_and_rebind_pyth(SECOND_SOURCE_ID);
    fx.set_clock_for_testing(test_constants::default_expiry_ms());

    fx.scenario_mut().next_tx(test_constants::admin());
    let mut market = fx.take_market_bundle(expiry_id);

    fx.try_settle_bundle(&mut market);

    abort 999
}

#[test]
fun try_settle_uses_rebound_pyth_after_exact_backfill() {
    let settlement_price = settlement_inside_default_finite_range();
    let mut fx = helpers::setup_market_default();
    let expiry_id = fx.create_expiry(test_constants::default_expiry_ms());
    let rebound_pyth_id = fx.create_and_rebind_pyth(SECOND_SOURCE_ID);
    fx.set_clock_for_testing(test_constants::default_expiry_ms());

    fx.scenario_mut().next_tx(test_constants::admin());
    let mut market = fx.take_market_bundle_with_pyth(expiry_id, rebound_pyth_id);
    assert!(!helpers::market(&market).is_settled());
    fx.insert_exact_settlement_spot_bundle(&mut market, settlement_price);

    assert_eq!(fx.try_settle_bundle(&mut market), true);
    assert_eq!(expiry_market::settlement_price(helpers::market(&market)), settlement_price);
    assert!(helpers::market(&market).is_settled());
    assert_eq!(helpers::market(&market).try_settlement_price(), option::some(settlement_price));

    helpers::return_market_bundle(market);
    fx.finish();
}

#[test]
fun try_settle_materializes_exact_terminal_liability() {
    let (mut fx, expiry_id, trader) = helpers::setup_live_market(
        test_constants::short_expiry_ms(),
        test_constants::default_live_price(),
    );
    fx.scenario_mut().next_tx(test_constants::alice());
    let mut market = fx.take_market_bundle(expiry_id);
    let mut account = fx.take_account_bundle(&trader);

    fx.mint_bundle(
        &mut market,
        &mut account,
        helpers::strike_tick(),
        helpers::strike_tick() + 10,
        test_constants::mint_quantity(),
    );
    assert_eq!(helpers::market(&market).payout_liability(), test_constants::mint_quantity());

    fx.set_clock_for_testing(test_constants::short_expiry_ms());
    fx.insert_exact_settlement_spot_bundle(
        &mut market,
        settlement_below_default_finite_range(),
    );
    assert_eq!(fx.try_settle_bundle(&mut market), true);
    assert_eq!(helpers::market(&market).payout_liability(), 0);

    helpers::return_account_bundle(account);
    helpers::return_market_bundle(market);
    fx.finish();
}

/// A settled loser (settlement below its range) has zero terminal payout.
#[test]
fun settled_order_payout_reads_loser_as_zero() {
    let (mut fx, expiry_id, trader) = helpers::setup_live_market(
        test_constants::short_expiry_ms(),
        test_constants::default_live_price(),
    );
    fx.scenario_mut().next_tx(test_constants::alice());
    let mut market = fx.take_market_bundle(expiry_id);
    let mut account = fx.take_account_bundle(&trader);

    let order_id = fx.mint_bundle(
        &mut market,
        &mut account,
        helpers::strike_tick(),
        helpers::strike_tick() + 10,
        test_constants::mint_quantity(),
    );

    fx.set_clock_for_testing(test_constants::short_expiry_ms());
    fx.insert_exact_settlement_spot_bundle(&mut market, settlement_below_default_finite_range());
    assert_eq!(fx.try_settle_bundle(&mut market), true);

    assert_eq!(helpers::settled_order_payout_bundle(&market, order_id), 0);

    helpers::return_account_bundle(account);
    helpers::return_market_bundle(market);
    fx.finish();
}

/// The settled payout reader rejects a live market before decoding its order.
#[test, expected_failure(abort_code = expiry_market::EMarketNotSettled)]
fun settled_order_payout_of_live_market_aborts() {
    let (mut fx, expiry_id, trader) = helpers::setup_live_market(
        test_constants::short_expiry_ms(),
        test_constants::default_live_price(),
    );
    fx.scenario_mut().next_tx(test_constants::alice());
    let mut market = fx.take_market_bundle(expiry_id);
    let mut account = fx.take_account_bundle(&trader);

    let order_id = fx.mint_bundle(
        &mut market,
        &mut account,
        helpers::strike_tick(),
        helpers::strike_tick() + 10,
        test_constants::mint_quantity(),
    );

    helpers::settled_order_payout_bundle(&market, order_id);
    abort 999
}

#[test]
fun explicitly_settled_redeem_pays_terminal_payout() {
    let settlement_price = settlement_inside_default_finite_range();
    let (mut fx, expiry_id, trader) = helpers::setup_live_market(
        test_constants::short_expiry_ms(),
        test_constants::default_live_price(),
    );
    fx.scenario_mut().next_tx(test_constants::alice());
    let mut market = fx.take_market_bundle(expiry_id);
    let mut account = fx.take_account_bundle(&trader);

    let premium = finite_range_premium(&mut fx, &market);
    let order_id = fx.mint_bundle(
        &mut market,
        &mut account,
        helpers::strike_tick(),
        helpers::strike_tick() + 10,
        test_constants::mint_quantity(),
    );
    fx.check_manager_bundle(
        &account,
        expiry_id,
        helpers::expected_manager_state(post_mint_balance(premium), MINT_MIN_FEE, 1, 0, 0),
    );

    fx.set_clock_for_testing(test_constants::short_expiry_ms());
    fx.insert_exact_settlement_spot_bundle(&mut market, settlement_price);
    assert_eq!(fx.try_settle_bundle(&mut market), true);

    fx.redeem_settled_bundle(
        &mut market,
        &mut account,
        order_id,
    );
    fx.check_manager_bundle(
        &account,
        expiry_id,
        helpers::expected_manager_state(
            post_settled_redeem_balance(premium),
            MINT_MIN_FEE,
            0,
            0,
            0,
        ),
    );
    helpers::check_market_cash(
        helpers::market(&market),
        helpers::expected_market_cash(cash_after_winning_redeem(premium), 0, REBATE_AFTER_MINT),
    );

    helpers::return_account_bundle(account);
    helpers::return_market_bundle(market);
    fx.finish();
}

#[test, expected_failure(abort_code = account_registry::EAppNotAuthorized)]
fun deauthorized_predict_app_blocks_permissionless_settled_redeem() {
    let settlement_price = settlement_inside_default_finite_range();
    let (mut fx, expiry_id, trader) = helpers::setup_live_market(
        test_constants::short_expiry_ms(),
        test_constants::default_live_price(),
    );
    fx.scenario_mut().next_tx(test_constants::alice());
    let mut market = fx.take_market_bundle(expiry_id);
    let mut account = fx.take_account_bundle(&trader);

    let order_id = fx.mint_bundle(
        &mut market,
        &mut account,
        helpers::strike_tick(),
        helpers::strike_tick() + 10,
        test_constants::mint_quantity(),
    );
    helpers::return_account_bundle(account);
    helpers::return_market_bundle(market);

    fx.deauthorize_predict_app();
    fx.set_clock_for_testing(test_constants::short_expiry_ms());
    fx.scenario_mut().next_tx(test_constants::alice());
    let mut market = fx.take_market_bundle(expiry_id);
    let mut account = fx.take_account_bundle(&trader);
    fx.insert_exact_settlement_spot_bundle(&mut market, settlement_price);
    assert_eq!(fx.try_settle_bundle(&mut market), true);

    fx.redeem_settled_bundle(
        &mut market,
        &mut account,
        order_id,
    );

    abort 999
}

#[test]
fun owner_auth_settled_redeem_survives_predict_app_deauth() {
    let settlement_price = settlement_inside_default_finite_range();
    let (mut fx, expiry_id, trader) = helpers::setup_live_market(
        test_constants::short_expiry_ms(),
        test_constants::default_live_price(),
    );
    fx.scenario_mut().next_tx(test_constants::alice());
    let mut market = fx.take_market_bundle(expiry_id);
    let mut account = fx.take_account_bundle(&trader);

    let premium = finite_range_premium(&mut fx, &market);
    let order_id = fx.mint_bundle(
        &mut market,
        &mut account,
        helpers::strike_tick(),
        helpers::strike_tick() + 10,
        test_constants::mint_quantity(),
    );
    helpers::return_account_bundle(account);
    helpers::return_market_bundle(market);

    fx.deauthorize_predict_app();
    fx.set_clock_for_testing(test_constants::short_expiry_ms());
    fx.scenario_mut().next_tx(test_constants::alice());
    let mut market = fx.take_market_bundle(expiry_id);
    let mut account = fx.take_account_bundle(&trader);
    fx.insert_exact_settlement_spot_bundle(&mut market, settlement_price);
    assert_eq!(fx.try_settle_bundle(&mut market), true);

    fx.redeem_settled_with_owner_auth_bundle(
        &mut market,
        &mut account,
        order_id,
    );
    fx.check_manager_bundle(
        &account,
        expiry_id,
        helpers::expected_manager_state(
            post_settled_redeem_balance(premium),
            MINT_MIN_FEE,
            0,
            0,
            0,
        ),
    );
    helpers::check_market_cash(
        helpers::market(&market),
        helpers::expected_market_cash(cash_after_winning_redeem(premium), 0, REBATE_AFTER_MINT),
    );

    helpers::return_account_bundle(account);
    helpers::return_market_bundle(market);
    fx.finish();
}

#[test, expected_failure(abort_code = account_registry::EAppNotAuthorized)]
fun deauthorized_predict_app_blocks_permissionless_rebate_claim() {
    let (mut fx, expiry_id, trader, _premium) = prepare_settled_loss_with_inactive_rebate_stake();

    fx.deauthorize_predict_app();
    fx.scenario_mut().next_epoch(test_constants::alice());
    let mut market = fx.take_market_bundle(expiry_id);
    let mut account = fx.take_account_bundle(&trader);

    fx.claim_trading_loss_rebate_permissionless_bundle(&mut market, &mut account);

    abort 999
}

#[test]
fun owner_auth_rebate_claim_survives_predict_app_deauth() {
    let (mut fx, expiry_id, trader, premium) = prepare_settled_loss_with_inactive_rebate_stake();

    fx.deauthorize_predict_app();
    fx.scenario_mut().next_epoch(test_constants::alice());
    let mut market = fx.take_market_bundle(expiry_id);
    let mut account = fx.take_account_bundle(&trader);

    fx.claim_trading_loss_rebate_bundle(&mut market, &mut account);
    fx.check_manager_bundle(
        &account,
        expiry_id,
        helpers::expected_manager_state(
            post_mint_balance(premium) + REBATE_AFTER_MINT,
            0,
            0,
            config_constants::default_upper_benefit_power!(),
            0,
        ),
    );
    helpers::check_market_cash(
        helpers::market(&market),
        helpers::expected_market_cash(cash_after_rebate_claim(premium), 0, 0),
    );

    helpers::return_account_bundle(account);
    helpers::return_market_bundle(market);
    fx.finish();
}

#[test]
fun retuning_the_stake_benefit_template_cannot_reprice_an_earned_rebate() {
    // A market snapshots its whole benefit policy at creation, so admin retunes
    // afterwards must not reach it. Were either value read live, this one-shot
    // claim would resolve against the new policy and permanently shrink a rebate
    // the trader had already earned: dropping the ratio to zero would erase it,
    // and widening the thresholds would roughly halve it (measured 2_500_000 ->
    // 1_252_551 before the snapshot landed). The claim removes the account's
    // expiry summary, so nothing could recover it afterwards.
    let (mut fx, expiry_id, trader, premium) = prepare_settled_loss_with_inactive_rebate_stake();

    fx.set_template_max_benefit_ratio(0);
    fx.set_template_benefit_powers(
        config_constants::max_lower_benefit_power!(),
        config_constants::max_upper_benefit_power!(),
    );
    fx.scenario_mut().next_epoch(test_constants::alice());
    let mut market = fx.take_market_bundle(expiry_id);
    let mut account = fx.take_account_bundle(&trader);

    fx.claim_trading_loss_rebate_bundle(&mut market, &mut account);
    // Full rebate, identical to the template-untouched claim.
    fx.check_manager_bundle(
        &account,
        expiry_id,
        helpers::expected_manager_state(
            post_mint_balance(premium) + REBATE_AFTER_MINT,
            0,
            0,
            config_constants::default_upper_benefit_power!(),
            0,
        ),
    );
    helpers::check_market_cash(
        helpers::market(&market),
        helpers::expected_market_cash(cash_after_rebate_claim(premium), 0, 0),
    );

    helpers::return_account_bundle(account);
    helpers::return_market_bundle(market);
    fx.finish();
}

#[test]
fun try_settle_is_idempotent_and_keeps_settlement_price() {
    let settlement_price = settlement_inside_default_finite_range();
    let (mut fx, expiry_id, trader) = helpers::setup_live_market(
        test_constants::short_expiry_ms(),
        test_constants::default_live_price(),
    );

    fx.scenario_mut().next_tx(test_constants::admin());
    let mut oracle_registry = fx.scenario_mut().take_shared<OracleRegistry>();
    let wrong_pyth_id = propbook_registry::create_and_share_pyth_feed(
        &mut oracle_registry,
        SECOND_SOURCE_ID,
        fx.scenario_mut().ctx(),
    );
    return_shared(oracle_registry);

    fx.scenario_mut().next_tx(test_constants::alice());
    let mut market = fx.take_market_bundle(expiry_id);
    let mut account = fx.take_account_bundle(&trader);
    let wrong_pyth = fx.scenario_mut().take_shared_by_id<PythFeed>(wrong_pyth_id);

    let premium = finite_range_premium(&mut fx, &market);
    let order_id = fx.mint_bundle(
        &mut market,
        &mut account,
        helpers::strike_tick(),
        helpers::strike_tick() + 10,
        test_constants::mint_quantity(),
    );

    fx.set_clock_for_testing(test_constants::short_expiry_ms());
    fx.insert_exact_settlement_spot_bundle(&mut market, settlement_price);

    // First call records the settlement price from the exact expiry spot.
    assert_eq!(fx.try_settle_bundle(&mut market), true);
    // Second call (clock now far past expiry) must early-return true via the
    // already-settled gate without validating the substituted feed, re-reading
    // the oracle, or changing the price.
    fx.set_clock_for_testing(test_constants::short_expiry_ms() * 2);
    assert_eq!(fx.try_settle_bundle_with_pyth(&mut market, &wrong_pyth), true);
    assert_eq!(
        event::events_by_type<config_events::MarketSettled>().length(),
        MARKET_SETTLED_EVENT_COUNT,
    );

    // The redeem pays the terminal in-range payout, proving the recorded settlement
    // price is unchanged by the second `try_settle`.
    fx.redeem_settled_bundle(
        &mut market,
        &mut account,
        order_id,
    );
    fx.check_manager_bundle(
        &account,
        expiry_id,
        helpers::expected_manager_state(
            post_settled_redeem_balance(premium),
            MINT_MIN_FEE,
            0,
            0,
            0,
        ),
    );

    helpers::return_account_bundle(account);
    helpers::return_market_bundle(market);
    return_shared(wrong_pyth);
    fx.finish();
}

#[test]
fun explicit_settlement_unblocks_pool_valuation_sweep() {
    let mut fx = helpers::setup_market_default();
    let _trader = fx.create_funded_manager(0);
    bootstrap_pool(&mut fx, IDLE_SEED);
    let expiry_id = fx.create_expiry(test_constants::default_expiry_ms());
    fund_empty_market(&mut fx, expiry_id);
    fx.set_clock_for_testing(test_constants::default_expiry_ms());

    fx.scenario_mut().next_tx(test_constants::admin());
    let mut market = fx.take_market_bundle(expiry_id);
    fx.insert_exact_settlement_spot_bundle(
        &mut market,
        settlement_inside_default_finite_range(),
    );
    assert_eq!(fx.try_settle_bundle(&mut market), true);

    let mut valuation = fx.start_flush_bundle(&mut market);
    fx.value_expiry_bundle(&mut valuation, &mut market);
    let pool_nav = fx.finish_flush_bundle(valuation, &mut market, option::none(), option::none());

    assert_eq!(pool_nav, IDLE_SEED);
    assert_eq!(helpers::vault(&market).idle_balance(), IDLE_SEED);
    assert_eq!(helpers::vault(&market).active_expiry_markets().length(), 0);

    helpers::return_market_bundle(market);
    fx.finish();
}

#[test]
fun explicit_settlement_then_standalone_rebalance_sweeps_market() {
    let mut fx = helpers::setup_market_default();
    let _trader = fx.create_funded_manager(0);
    bootstrap_pool(&mut fx, IDLE_SEED);
    let expiry_id = fx.create_expiry(test_constants::default_expiry_ms());
    fund_empty_market(&mut fx, expiry_id);
    fx.set_clock_for_testing(test_constants::default_expiry_ms());

    fx.scenario_mut().next_tx(test_constants::admin());
    let mut market = fx.take_market_bundle(expiry_id);
    fx.insert_exact_settlement_spot_bundle(
        &mut market,
        settlement_inside_default_finite_range(),
    );
    assert_eq!(fx.try_settle_bundle(&mut market), true);

    fx.rebalance_expiry_cash_bundle(&mut market);

    assert_eq!(helpers::vault(&market).idle_balance(), IDLE_SEED);
    assert_eq!(helpers::vault(&market).active_expiry_markets().length(), 0);

    helpers::return_market_bundle(market);
    fx.finish();
}

#[test]
fun expired_unsettled_standalone_rebalance_moves_no_cash() {
    let mut fx = helpers::setup_market_default();
    let _trader = fx.create_funded_manager(0);
    bootstrap_pool(&mut fx, IDLE_SEED);
    let expiry_id = fx.create_expiry(test_constants::default_expiry_ms());
    fund_empty_market(&mut fx, expiry_id);
    fx.set_clock_for_testing(test_constants::default_expiry_ms());

    fx.scenario_mut().next_tx(test_constants::admin());
    let mut market = fx.take_market_bundle(expiry_id);
    let idle_before = helpers::vault(&market).idle_balance();
    let market_cash_before = helpers::market(&market).cash_balance();

    fx.rebalance_expiry_cash_bundle(&mut market);

    assert_eq!(helpers::vault(&market).idle_balance(), idle_before);
    assert_eq!(helpers::market(&market).cash_balance(), market_cash_before);
    assert_eq!(helpers::vault(&market).active_expiry_markets().length(), ACTIVE_MARKET_COUNT);

    helpers::return_market_bundle(market);
    fx.finish();
}

/// Balances and market cash below are stated relative to the mint's premium,
/// read from the quote the mint pays. `quote_mint_tests` owns whether that cost
/// composes correctly and `pricing_exact_tests` owns the price behind it; this
/// file owns settlement, so it should not restate either as a literal.
fun post_mint_balance(premium: u64): u64 {
    test_constants::mint_deposit() - premium - MINT_MIN_FEE
}

/// An in-range settled payout returns the full quantity to the manager.
fun post_settled_redeem_balance(premium: u64): u64 {
    post_mint_balance(premium) + test_constants::mint_quantity()
}

/// Seeded expiry cash plus the mint premium and fee; a losing settled redeem
/// pays zero, so the cash is unchanged by the redeem itself.
fun cash_after_losing_redeem(premium: u64): u64 {
    test_constants::default_seeded_expiry_cash() + premium + MINT_MIN_FEE
}

/// The winning redeem pays the full quantity out of that cash.
fun cash_after_winning_redeem(premium: u64): u64 {
    cash_after_losing_redeem(premium) - test_constants::mint_quantity()
}

/// The rebate claim pays the reserve out of that cash.
fun cash_after_rebate_claim(premium: u64): u64 {
    cash_after_losing_redeem(premium) - REBATE_AFTER_MINT
}

/// Premium for the fixture's finite-range mint, from the anonymous quote.
fun finite_range_premium(fx: &mut helpers::Fixture, market: &helpers::MarketBundle): u64 {
    let quote = fx.quote_mint_bundle(
        market,
        helpers::strike_tick(),
        helpers::strike_tick() + 10,
        test_constants::mint_quantity(),
    );
    // The upper boundary is ~315 sigma out and clamps to zero, so this finite
    // range prices as the at-the-money digital itself.
    helpers::assert_atm_entry_probability_short_expiry(quote.entry_probability());
    quote.premium()
}

fun settlement_inside_default_finite_range(): u64 {
    (helpers::strike_tick() + 1) * test_constants::default_tick_size()
}

fun settlement_below_default_finite_range(): u64 {
    (helpers::strike_tick() - 1) * test_constants::default_tick_size()
}

/// Even with the exact Propbook spot recorded, the rebate claim requires the
/// explicit settlement transition instead of settling implicitly.
#[test, expected_failure(abort_code = plp::EMarketNotSettled)]
fun rebate_claim_requires_settled_market() {
    let (mut fx, expiry_id, trader) = helpers::setup_live_market(
        test_constants::short_expiry_ms(),
        test_constants::default_live_price(),
    );
    fx.scenario_mut().next_tx(test_constants::alice());
    let mut market = fx.take_market_bundle(expiry_id);
    let mut account = fx.take_account_bundle(&trader);

    fx.set_clock_for_testing(test_constants::short_expiry_ms());
    fx.insert_exact_settlement_spot_bundle(
        &mut market,
        settlement_below_default_finite_range(),
    );
    fx.claim_trading_loss_rebate_bundle(&mut market, &mut account);

    abort 999
}

/// A rebate claim resolves the account's expiry summary, which requires every
/// position on the expiry closed: with an order still open after settlement it
/// aborts instead of paying against an incomplete loss picture.
#[test, expected_failure(abort_code = predict_account::EExpirySummaryHasOpenPositions)]
fun rebate_claim_with_open_position_aborts() {
    let (mut fx, expiry_id, trader) = helpers::setup_live_market(
        test_constants::short_expiry_ms(),
        test_constants::default_live_price(),
    );
    fx.scenario_mut().next_tx(test_constants::alice());
    let mut market = fx.take_market_bundle(expiry_id);
    let mut account = fx.take_account_bundle(&trader);

    let _order_id = fx.mint_bundle(
        &mut market,
        &mut account,
        helpers::strike_tick(),
        helpers::strike_tick() + 10,
        test_constants::mint_quantity(),
    );
    fx.set_clock_for_testing(test_constants::short_expiry_ms());
    fx.insert_exact_settlement_spot_bundle(
        &mut market,
        settlement_below_default_finite_range(),
    );
    assert_eq!(fx.try_settle_bundle(&mut market), true);
    // The position is never redeemed, so summary resolution must refuse the claim.
    fx.claim_trading_loss_rebate_bundle(&mut market, &mut account);

    abort 999
}

#[test]
fun unstake_deep_returns_all_staked_custody() {
    let (mut fx, expiry_id, trader) = helpers::setup_live_market(
        test_constants::short_expiry_ms(),
        test_constants::default_live_price(),
    );
    fx.scenario_mut().next_tx(test_constants::alice());
    let mut market = fx.take_market_bundle(expiry_id);
    let mut account = fx.take_account_bundle(&trader);

    fx.fund_deep_bundle(&mut account, config_constants::default_upper_benefit_power!());
    fx.stake_deep_bundle(
        &mut market,
        &mut account,
        config_constants::default_upper_benefit_power!(),
    );
    assert_eq!(
        helpers::vault(&market).staked_deep(),
        config_constants::default_upper_benefit_power!(),
    );

    fx.unstake_deep_bundle(&mut market, &mut account);

    // All staked DEEP custody (active and inactive) left the vault for the account.
    assert_eq!(helpers::vault(&market).staked_deep(), 0);
    // ...and arrived in the account's stored balance — the receiving side, so a vault-debit that
    // failed to credit the account would fail here, not pass silently.
    assert_eq!(
        fx.account_balance_bundle<DEEP>(&account),
        config_constants::default_upper_benefit_power!(),
    );
    fx.check_manager_bundle(
        &account,
        expiry_id,
        helpers::expected_manager_state(test_constants::mint_deposit(), 0, 0, 0, 0),
    );

    helpers::return_account_bundle(account);
    helpers::return_market_bundle(market);
    fx.finish();
}

fun prepare_settled_loss_with_inactive_rebate_stake(): (
    helpers::Fixture,
    ID,
    helpers::Trader,
    u64,
) {
    // The rebate this fixture stages is only payable by a market that snapshotted
    // the benefit programme at creation; the switch cannot be flipped afterwards.
    let (mut fx, expiry_id, trader) = helpers::setup_live_market_with_stake_benefits(
        test_constants::short_expiry_ms(),
        test_constants::default_live_price(),
    );
    fx.scenario_mut().next_tx(test_constants::alice());
    let mut market = fx.take_market_bundle(expiry_id);
    let mut account = fx.take_account_bundle(&trader);

    let premium = finite_range_premium(&mut fx, &market);
    let order_id = fx.mint_bundle(
        &mut market,
        &mut account,
        helpers::strike_tick(),
        helpers::strike_tick() + 10,
        test_constants::mint_quantity(),
    );
    fx.set_clock_for_testing(test_constants::short_expiry_ms());
    fx.insert_exact_settlement_spot_bundle(
        &mut market,
        settlement_below_default_finite_range(),
    );
    assert_eq!(fx.try_settle_bundle(&mut market), true);
    fx.redeem_settled_with_owner_auth_bundle(
        &mut market,
        &mut account,
        order_id,
    );
    fx.check_manager_bundle(
        &account,
        expiry_id,
        helpers::expected_manager_state(post_mint_balance(premium), MINT_MIN_FEE, 0, 0, 0),
    );
    helpers::check_market_cash(
        helpers::market(&market),
        helpers::expected_market_cash(cash_after_losing_redeem(premium), 0, REBATE_AFTER_MINT),
    );

    fx.fund_deep_bundle(&mut account, config_constants::default_upper_benefit_power!());
    fx.stake_deep_bundle(
        &mut market,
        &mut account,
        config_constants::default_upper_benefit_power!(),
    );
    fx.check_manager_bundle(
        &account,
        expiry_id,
        helpers::expected_manager_state(
            post_mint_balance(premium),
            MINT_MIN_FEE,
            0,
            0,
            config_constants::default_upper_benefit_power!(),
        ),
    );

    helpers::return_account_bundle(account);
    helpers::return_market_bundle(market);
    (fx, expiry_id, trader, premium)
}

/// Bootstrap pool idle via the genesis `lock_capital` so nonzero NAV has matching PLP
/// supply (`idle == total_supply == amount` at a 1.0 mark). The lock is operator-gated
/// and needs no trader account.
fun bootstrap_pool(fx: &mut helpers::Fixture, amount: u64) {
    fx.bootstrap_lock(amount);
}

fun fund_empty_market(fx: &mut helpers::Fixture, expiry_id: ID) {
    fx.scenario_mut().next_tx(test_constants::admin());
    let mut market = fx.take_market_bundle(expiry_id);
    fx.prepare_live_oracle_bundle(&mut market, test_constants::default_live_price());
    fx.rebalance_expiry_cash_bundle(&mut market);
    helpers::return_market_bundle(market);
}

/// A settled winner's payout reader returns the full quantity that redemption
/// will pay.
#[test]
fun settled_order_payout_reads_winner_terminal_payout() {
    let (mut fx, expiry_id, trader) = helpers::setup_live_market(
        test_constants::short_expiry_ms(),
        test_constants::default_live_price(),
    );
    fx.scenario_mut().next_tx(test_constants::alice());
    let mut market = fx.take_market_bundle(expiry_id);
    let mut account = fx.take_account_bundle(&trader);

    let order_id = fx.mint_bundle(
        &mut market,
        &mut account,
        helpers::strike_tick(),
        helpers::strike_tick() + 10,
        test_constants::mint_quantity(),
    );

    fx.set_clock_for_testing(test_constants::short_expiry_ms());
    fx.insert_exact_settlement_spot_bundle(&mut market, settlement_inside_default_finite_range());
    assert_eq!(fx.try_settle_bundle(&mut market), true);

    assert_eq!(
        helpers::settled_order_payout_bundle(&market, order_id),
        test_constants::mint_quantity(),
    );

    helpers::return_account_bundle(account);
    helpers::return_market_bundle(market);
    fx.finish();
}
