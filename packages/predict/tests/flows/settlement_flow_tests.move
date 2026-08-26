// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Terminal settlement flow coverage: exact Propbook timestamp settlement,
/// settled redeem, and the settled-market PLP sweep.
#[test_only]
module deepbook_predict::settlement_flow_tests;

use deepbook_predict::{
    config_events,
    constants,
    expiry_market,
    flow_test_helpers as helpers,
    predict_account,
    pricing,
    test_constants
};
use propbook::{
    block_scholes_store::BlockScholesValueStore,
    pyth_feed::PythFeed,
    registry::{Self as propbook_registry, OracleRegistry}
};
use std::unit_test::assert_eq;
use sui::{event, test_scenario::return_shared};

const SECOND_SOURCE_ID: u32 = 2;
const FOREIGN_UNDERLYING_ID: u32 = 9_002;
const IDLE_SEED: u64 = 1_200_000_000_000;
const ONE_MS: u64 = 1;
const ZERO_SPOT: u128 = 0;
const ONE_U128: u128 = 1;

/// Per-trade fee floor for the default flow fixture.
const MINT_MIN_FEE: u64 = 5_000_000;
const MARKET_SETTLED_EVENT_COUNT: u64 = 1;
const ACTIVE_MARKET_COUNT: u64 = 1;

/// Even with the exact Propbook spot recorded, `redeem_settled` requires the
/// explicit settlement transition instead of settling implicitly.
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

#[test]
fun block_scholes_fallback_arms_at_exact_grace_boundary() {
    let expiry = test_constants::default_expiry_ms();
    let settlement_price = settlement_inside_default_finite_range();
    let mut fx = helpers::setup_market_default();
    let expiry_id = fx.create_expiry(expiry);
    fx.set_clock_for_testing(expiry + constants::settlement_fallback_grace_ms!() - ONE_MS);

    fx.scenario_mut().next_tx(test_constants::admin());
    let mut market = fx.take_market_bundle(expiry_id);
    fx.insert_exact_block_scholes_settlement_spot_bundle(
        &mut market,
        settlement_price as u128,
    );

    assert_eq!(fx.try_settle_bundle(&mut market), false);
    assert!(!helpers::market(&market).is_settled());

    fx.set_clock_for_testing(expiry + constants::settlement_fallback_grace_ms!());
    assert_eq!(fx.try_settle_bundle(&mut market), true);
    assert_eq!(helpers::market(&market).settlement_price(), settlement_price);

    helpers::return_market_bundle(market);
    fx.finish();
}

#[test]
fun block_scholes_fallback_missing_after_grace_remains_retryable() {
    let expiry = test_constants::default_expiry_ms();
    let mut fx = helpers::setup_market_default();
    let expiry_id = fx.create_expiry(expiry);
    fx.set_clock_for_testing(expiry + constants::settlement_fallback_grace_ms!());

    fx.scenario_mut().next_tx(test_constants::admin());
    let mut market = fx.take_market_bundle(expiry_id);
    assert_eq!(fx.try_settle_bundle(&mut market), false);
    assert!(!helpers::market(&market).is_settled());
    assert_eq!(helpers::market(&market).try_settlement_price(), option::none());

    helpers::return_market_bundle(market);
    fx.finish();
}

#[test]
fun pyth_wins_after_grace_when_both_exact_spots_exist() {
    let expiry = test_constants::default_expiry_ms();
    let pyth_price = settlement_inside_default_finite_range();
    let block_scholes_price = settlement_below_default_finite_range();
    let mut fx = helpers::setup_market_default();
    let expiry_id = fx.create_expiry(expiry);
    fx.set_clock_for_testing(expiry + constants::settlement_fallback_grace_ms!());

    fx.scenario_mut().next_tx(test_constants::admin());
    let mut market = fx.take_market_bundle(expiry_id);
    fx.insert_exact_block_scholes_settlement_spot_bundle(
        &mut market,
        block_scholes_price as u128,
    );
    fx.insert_exact_settlement_spot_bundle(&mut market, pyth_price);

    assert_eq!(fx.try_settle_bundle(&mut market), true);
    assert_eq!(helpers::market(&market).settlement_price(), pyth_price);

    helpers::return_market_bundle(market);
    fx.finish();
}

#[test]
fun zero_block_scholes_fallback_spot_remains_retryable() {
    let expiry = test_constants::default_expiry_ms();
    let recovery_price = settlement_inside_default_finite_range();
    let mut fx = helpers::setup_market_default();
    let expiry_id = fx.create_expiry(expiry);
    fx.set_clock_for_testing(expiry + constants::settlement_fallback_grace_ms!());

    fx.scenario_mut().next_tx(test_constants::admin());
    let mut market = fx.take_market_bundle(expiry_id);
    fx.insert_exact_block_scholes_settlement_spot_bundle(&mut market, ZERO_SPOT);

    assert_eq!(fx.try_settle_bundle(&mut market), false);
    assert!(!helpers::market(&market).is_settled());

    fx.insert_exact_block_scholes_settlement_spot_bundle(&mut market, recovery_price as u128);
    assert_eq!(fx.try_settle_bundle(&mut market), true);
    assert_eq!(helpers::market(&market).settlement_price(), recovery_price);

    helpers::return_market_bundle(market);
    fx.finish();
}

#[test]
fun oversized_block_scholes_fallback_spot_remains_retryable() {
    let expiry = test_constants::default_expiry_ms();
    let recovery_price = settlement_inside_default_finite_range();
    let mut fx = helpers::setup_market_default();
    let expiry_id = fx.create_expiry(expiry);
    fx.set_clock_for_testing(expiry + constants::settlement_fallback_grace_ms!());

    fx.scenario_mut().next_tx(test_constants::admin());
    let mut market = fx.take_market_bundle(expiry_id);
    fx.insert_exact_block_scholes_settlement_spot_bundle(
        &mut market,
        (std::u64::max_value!() as u128) + ONE_U128,
    );

    assert_eq!(fx.try_settle_bundle(&mut market), false);
    assert!(!helpers::market(&market).is_settled());

    fx.insert_exact_block_scholes_settlement_spot_bundle(&mut market, recovery_price as u128);
    assert_eq!(fx.try_settle_bundle(&mut market), true);
    assert_eq!(helpers::market(&market).settlement_price(), recovery_price);

    helpers::return_market_bundle(market);
    fx.finish();
}

#[test, expected_failure(abort_code = pricing::EWrongBlockScholesValueStore)]
fun block_scholes_fallback_rejects_another_underlyings_store() {
    let expiry = test_constants::default_expiry_ms();
    let mut fx = helpers::setup_market_default();
    let expiry_id = fx.create_expiry(expiry);
    let foreign_pair = fx.create_foreign_block_scholes_stores(FOREIGN_UNDERLYING_ID);
    let foreign_values_id = foreign_pair.block_scholes_value_store_id();
    fx.set_clock_for_testing(expiry + constants::settlement_fallback_grace_ms!());

    fx.scenario_mut().next_tx(test_constants::admin());
    let mut market = fx.take_market_bundle(expiry_id);
    let foreign_values = fx
        .scenario_mut()
        .take_shared_by_id<BlockScholesValueStore>(foreign_values_id);
    fx.try_settle_bundle_with_bs_values(&mut market, &foreign_values);

    abort 999
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

/// A settled order can be redeemed exactly once.
///
/// With the settled close-terms token gone, `predict_account::remove_position` is the
/// SOLE mechanism preventing a second redeem from releasing the same payout liability
/// twice. It also runs before the liability is decremented, so the second attempt
/// aborts before touching any accounting.
#[test, expected_failure(abort_code = predict_account::EPositionNotFound)]
fun settled_redeem_twice_aborts() {
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
    assert_eq!(fx.try_settle_bundle(&mut market), true);

    fx.redeem_settled_bundle(&mut market, &mut account, order_id);

    // The position is gone; a replay must abort rather than release the payout again.
    // A fresh transaction is required for the shared registry to be takeable again.
    fx.scenario_mut().next_tx(test_constants::alice());
    fx.redeem_settled_bundle(&mut market, &mut account, order_id);

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
    fx.check_manager_bundle(&account, helpers::expected_manager_state(post_mint_balance(premium)));

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
        helpers::expected_manager_state(post_settled_redeem_balance(premium)),
    );
    helpers::check_market_cash(
        helpers::market(&market),
        helpers::expected_market_cash(cash_after_winning_redeem(premium), 0),
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
        helpers::expected_manager_state(post_settled_redeem_balance(premium)),
    );

    helpers::return_account_bundle(account);
    helpers::return_market_bundle(market);
    return_shared(wrong_pyth);
    fx.finish();
}

#[test]
fun block_scholes_fallback_unblocks_pool_valuation_sweep() {
    let mut fx = helpers::setup_market_default();
    let _trader = fx.create_funded_manager(0);
    bootstrap_pool(&mut fx, IDLE_SEED);
    let expiry = test_constants::default_expiry_ms();
    let expiry_id = fx.create_expiry(expiry);
    fund_empty_market(&mut fx, expiry_id);
    fx.set_clock_for_testing(expiry + constants::settlement_fallback_grace_ms!());

    fx.scenario_mut().next_tx(test_constants::admin());
    let mut market = fx.take_market_bundle(expiry_id);
    fx.insert_exact_block_scholes_settlement_spot_bundle(
        &mut market,
        settlement_inside_default_finite_range() as u128,
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

/// The settled sweep must complete against a market that still owes an unredeemed
/// winner: it deactivates the expiry and returns everything above payout liability,
/// keeping back exactly the payout, and the holder is still paid in full afterwards.
/// Nothing but the holder's own authority can clear the position, so this is the
/// normal terminal state rather than an edge case.
#[test]
fun settled_sweep_retains_payout_backing_for_an_unredeemed_winner() {
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

    fx.set_clock_for_testing(test_constants::short_expiry_ms());
    fx.insert_exact_settlement_spot_bundle(&mut market, settlement_price);
    assert_eq!(fx.try_settle_bundle(&mut market), true);

    // Sweep with the winner still open. A winner's liability is its full quantity,
    // and settlement released the inventory-impact escrow, so the market must keep
    // back exactly the payout and return the rest of the minted premium and fee.
    fx.rebalance_expiry_cash_bundle(&mut market);
    helpers::check_market_cash(
        helpers::market(&market),
        helpers::expected_market_cash(
            test_constants::mint_quantity(),
            test_constants::mint_quantity(),
        ),
    );
    assert_eq!(helpers::vault(&market).active_expiry_markets().length(), 0);

    // The holder is still made whole after the sweep, and the market ends empty.
    fx.redeem_settled_bundle(&mut market, &mut account, order_id);
    fx.check_manager_bundle(
        &account,
        helpers::expected_manager_state(post_settled_redeem_balance(premium)),
    );
    helpers::check_market_cash(helpers::market(&market), helpers::expected_market_cash(0, 0));

    helpers::return_account_bundle(account);
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
