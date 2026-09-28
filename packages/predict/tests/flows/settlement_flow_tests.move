// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Terminal settlement flow coverage: exact Propbook timestamp settlement,
/// settled redeem, and the settled-market PLP sweep.
#[test_only]
module deepbook_predict::settlement_flow_tests;

use account::account_registry;
use deepbook_predict::{
    config_events,
    constants,
    expiry_market,
    flow_test_helpers as helpers,
    predict_account,
    pricing,
    test_constants,
    vault_events
};
use propbook::{
    block_scholes_store::BlockScholesValueStore,
    pyth_feed::PythFeed,
    registry::{Self as propbook_registry, OracleRegistry}
};
use std::{bcs, unit_test::assert_eq};
use sui::{event, test_scenario::return_shared};

const SECOND_SOURCE_ID: u32 = 2;
const FOREIGN_UNDERLYING_ID: u32 = 9_002;
const IDLE_SEED: u64 = 1_200_000_000_000;
const ONE_MS: u64 = 1;
const ZERO_SPOT: u128 = 0;
const ONE_U128: u128 = 1;

/// Two per-leg fee floors for the finite-range flow fixture.
const MINT_MIN_FEE: u64 = 10_000_000;
const MARKET_SETTLED_EVENT_COUNT: u64 = 1;
const ACTIVE_MARKET_COUNT: u64 = 1;
const EXPIRY_PNL_EVENT_COUNT: u64 = 1;
/// Sponsor subsidy on `MINT_MIN_FEE`: the default 20% subsidy rate (the fixture never
/// changes it) of 10 USDC, well inside the incentives one minimum sponsorship allocates.
const MIN_FEE_SUBSIDY: u64 = 2_000_000;

/// BCS mirror used to assert the public `vault_events::ExpiryPnl` schema without
/// adding production getters solely for tests.
public struct ExpectedExpiryPnl has copy, drop {
    pool_vault_id: ID,
    expiry_market_id: ID,
    propbook_underlying_id: u32,
    period_start_ms: u64,
    expiry: u64,
    settlement_price: u64,
    sent_to_expiry: u64,
    received_from_expiry: u64,
    in_profit: bool,
    amount: u64,
}

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
    deepbook_predict::range_test_helpers::prepare_range(&mut fx, &mut market);

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
    deepbook_predict::range_test_helpers::prepare_range(&mut fx, &mut market);

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
    deepbook_predict::range_test_helpers::prepare_range(&mut fx, &mut market);

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
    deepbook_predict::range_test_helpers::prepare_range(&mut fx, &mut market);

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
    deepbook_predict::range_test_helpers::prepare_range(&mut fx, &mut market);

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
    deepbook_predict::range_test_helpers::prepare_range(&mut fx, &mut market);

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
    deepbook_predict::range_test_helpers::prepare_range(&mut fx, &mut market);

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
    deepbook_predict::range_test_helpers::prepare_range(&mut fx, &mut market);

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

/// The keeper path is closed to senders admin has not allowlisted: bob holds no
/// grant, so redeeming alice's settled winner aborts before any state moves.
#[test, expected_failure(abort_code = expiry_market::ENotSettledRedeemKeeper)]
fun unlisted_sender_cannot_redeem_settled_permissionless() {
    let settlement_price = settlement_inside_default_finite_range();
    let (mut fx, expiry_id, trader) = helpers::setup_live_market(
        test_constants::short_expiry_ms(),
        test_constants::default_live_price(),
    );
    fx.scenario_mut().next_tx(test_constants::alice());
    let mut market = fx.take_market_bundle(expiry_id);
    let mut account = fx.take_account_bundle(&trader);
    deepbook_predict::range_test_helpers::prepare_range(&mut fx, &mut market);

    let order_id = fx.mint_bundle(
        &mut market,
        &mut account,
        helpers::strike_tick(),
        helpers::strike_tick() + 10,
        test_constants::mint_quantity(),
    );
    helpers::return_account_bundle(account);
    helpers::return_market_bundle(market);

    fx.set_clock_for_testing(test_constants::short_expiry_ms());
    fx.scenario_mut().next_tx(test_constants::bob());
    let mut market = fx.take_market_bundle(expiry_id);
    let mut account = fx.take_account_bundle(&trader);
    fx.insert_exact_settlement_spot_bundle(&mut market, settlement_price);
    assert_eq!(fx.try_settle_bundle(&mut market), true);

    fx.redeem_settled_bundle(&mut market, &mut account, order_id);

    abort 999
}

/// An allowlisted keeper redeems another account's settled winner: carol sends the
/// transaction, and the full payout still lands in alice's account, exactly as the
/// owner-auth path would credit it.
#[test]
fun listed_keeper_redeems_another_accounts_settled_order() {
    let settlement_price = settlement_inside_default_finite_range();
    let (mut fx, expiry_id, trader) = helpers::setup_live_market(
        test_constants::short_expiry_ms(),
        test_constants::default_live_price(),
    );
    fx.scenario_mut().next_tx(test_constants::alice());
    let mut market = fx.take_market_bundle(expiry_id);
    let mut account = fx.take_account_bundle(&trader);
    deepbook_predict::range_test_helpers::prepare_range(&mut fx, &mut market);

    let premium = finite_range_premium(&mut fx, &market);
    let order_id = fx.mint_bundle(
        &mut market,
        &mut account,
        helpers::strike_tick(),
        helpers::strike_tick() + 10,
        test_constants::mint_quantity(),
    );
    fx.add_settled_redeem_keeper_bundle(&mut market, test_constants::carol());
    helpers::return_account_bundle(account);
    helpers::return_market_bundle(market);

    fx.set_clock_for_testing(test_constants::short_expiry_ms());
    fx.scenario_mut().next_tx(test_constants::carol());
    let mut market = fx.take_market_bundle(expiry_id);
    let mut account = fx.take_account_bundle(&trader);
    fx.insert_exact_settlement_spot_bundle(&mut market, settlement_price);
    assert_eq!(fx.try_settle_bundle(&mut market), true);

    fx.redeem_settled_bundle(&mut market, &mut account, order_id);
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

/// Revocation takes effect on the next call: the fixture allowlists alice, admin
/// removes her, and her keeper-path redeem then aborts.
#[test, expected_failure(abort_code = expiry_market::ENotSettledRedeemKeeper)]
fun removed_keeper_cannot_redeem_settled_permissionless() {
    let settlement_price = settlement_inside_default_finite_range();
    let (mut fx, expiry_id, trader) = helpers::setup_live_market(
        test_constants::short_expiry_ms(),
        test_constants::default_live_price(),
    );
    fx.scenario_mut().next_tx(test_constants::alice());
    let mut market = fx.take_market_bundle(expiry_id);
    let mut account = fx.take_account_bundle(&trader);
    deepbook_predict::range_test_helpers::prepare_range(&mut fx, &mut market);

    let order_id = fx.mint_bundle(
        &mut market,
        &mut account,
        helpers::strike_tick(),
        helpers::strike_tick() + 10,
        test_constants::mint_quantity(),
    );
    fx.remove_settled_redeem_keeper_bundle(&mut market, test_constants::alice());
    helpers::return_account_bundle(account);
    helpers::return_market_bundle(market);

    fx.set_clock_for_testing(test_constants::short_expiry_ms());
    fx.scenario_mut().next_tx(test_constants::alice());
    let mut market = fx.take_market_bundle(expiry_id);
    let mut account = fx.take_account_bundle(&trader);
    fx.insert_exact_settlement_spot_bundle(&mut market, settlement_price);
    assert_eq!(fx.try_settle_bundle(&mut market), true);

    fx.redeem_settled_bundle(&mut market, &mut account, order_id);

    abort 999
}

/// The allowlist gates only the keeper path. With alice removed from it, her
/// owner-auth redeem still pays the full settled payout, so the allowlist can never
/// strand a user's winnings.
#[test]
fun owner_auth_settled_redeem_ignores_keeper_allowlist() {
    let settlement_price = settlement_inside_default_finite_range();
    let (mut fx, expiry_id, trader) = helpers::setup_live_market(
        test_constants::short_expiry_ms(),
        test_constants::default_live_price(),
    );
    fx.scenario_mut().next_tx(test_constants::alice());
    let mut market = fx.take_market_bundle(expiry_id);
    let mut account = fx.take_account_bundle(&trader);
    deepbook_predict::range_test_helpers::prepare_range(&mut fx, &mut market);

    let premium = finite_range_premium(&mut fx, &market);
    let order_id = fx.mint_bundle(
        &mut market,
        &mut account,
        helpers::strike_tick(),
        helpers::strike_tick() + 10,
        test_constants::mint_quantity(),
    );
    fx.remove_settled_redeem_keeper_bundle(&mut market, test_constants::alice());
    helpers::return_account_bundle(account);
    helpers::return_market_bundle(market);

    fx.set_clock_for_testing(test_constants::short_expiry_ms());
    fx.scenario_mut().next_tx(test_constants::alice());
    let mut market = fx.take_market_bundle(expiry_id);
    let mut account = fx.take_account_bundle(&trader);
    fx.insert_exact_settlement_spot_bundle(&mut market, settlement_price);
    assert_eq!(fx.try_settle_bundle(&mut market), true);

    fx.redeem_settled_with_owner_auth_bundle(&mut market, &mut account, order_id);
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
    deepbook_predict::range_test_helpers::prepare_range(&mut fx, &mut market);
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

    fx.start_flush_bundle(&mut market);
    fx.value_expiry_bundle(&mut market);
    let pool_nav = fx.finish_flush_bundle(&mut market);

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

/// A winning order leaves the pool down on the expiry. The pool funded the market to
/// its initial cash `F` and the trader paid `premium + fee` in; the settled sweep holds
/// back the full-quantity payout and returns the rest, so the pool received
/// `F + premium + fee - quantity` against `F` sent: a loss of `quantity - premium - fee`.
#[test]
fun settled_sweep_reports_expiry_loss() {
    let (mut fx, expiry_id, trader) = setup_pool_funded_live_market();
    fx.scenario_mut().next_tx(test_constants::alice());
    let mut market = fx.take_market_bundle(expiry_id);
    let mut account = fx.take_account_bundle(&trader);
    deepbook_predict::range_test_helpers::prepare_range(&mut fx, &mut market);
    let premium = finite_range_premium(&mut fx, &market);
    fx.mint_bundle(
        &mut market,
        &mut account,
        helpers::strike_tick(),
        helpers::strike_tick() + 10,
        test_constants::mint_quantity(),
    );

    let settlement_price = settlement_inside_default_finite_range();
    fx.set_clock_for_testing(test_constants::short_expiry_ms());
    fx.insert_exact_settlement_spot_bundle(&mut market, settlement_price);
    assert_eq!(fx.try_settle_bundle(&mut market), true);
    fx.rebalance_expiry_cash_bundle(&mut market);

    let sent = test_constants::default_initial_expiry_cash();
    assert_single_expiry_pnl(
        &fx,
        expiry_id,
        test_constants::short_expiry_ms(),
        settlement_price,
        sent,
        sent + premium + MINT_MIN_FEE - test_constants::mint_quantity(),
        false,
        test_constants::mint_quantity() - premium - MINT_MIN_FEE,
    );

    helpers::return_account_bundle(account);
    helpers::return_market_bundle(market);
    fx.finish();
}

/// A losing order leaves the pool up by everything the trader paid: the settled sweep
/// holds back nothing and returns `F + premium + fee` against `F` sent. A repeat sweep
/// returns no cash, so it reports nothing new.
#[test]
fun settled_sweep_reports_expiry_profit_once() {
    let (mut fx, expiry_id, trader) = setup_pool_funded_live_market();
    fx.scenario_mut().next_tx(test_constants::alice());
    let mut market = fx.take_market_bundle(expiry_id);
    let mut account = fx.take_account_bundle(&trader);
    deepbook_predict::range_test_helpers::prepare_range(&mut fx, &mut market);
    let premium = finite_range_premium(&mut fx, &market);
    fx.mint_bundle(
        &mut market,
        &mut account,
        helpers::strike_tick(),
        helpers::strike_tick() + 10,
        test_constants::mint_quantity(),
    );

    let settlement_price = settlement_below_default_finite_range();
    fx.set_clock_for_testing(test_constants::short_expiry_ms());
    fx.insert_exact_settlement_spot_bundle(&mut market, settlement_price);
    assert_eq!(fx.try_settle_bundle(&mut market), true);
    fx.rebalance_expiry_cash_bundle(&mut market);
    fx.rebalance_expiry_cash_bundle(&mut market);

    let sent = test_constants::default_initial_expiry_cash();
    assert_single_expiry_pnl(
        &fx,
        expiry_id,
        test_constants::short_expiry_ms(),
        settlement_price,
        sent,
        sent + premium + MINT_MIN_FEE,
        true,
        premium + MINT_MIN_FEE,
    );

    helpers::return_account_bundle(account);
    helpers::return_market_bundle(market);
    fx.finish();
}

/// The flush sweeps a settled market through the same path as the standalone
/// rebalance. With no trades the market returns exactly the `F` it was sent, which
/// reports as a zero profit.
#[test]
fun flush_sweep_reports_break_even_expiry() {
    let mut fx = helpers::setup_market_default();
    let _trader = fx.create_funded_manager(0);
    bootstrap_pool(&mut fx, IDLE_SEED);
    let expiry = test_constants::default_expiry_ms();
    let expiry_id = fx.create_expiry(expiry);
    fund_empty_market(&mut fx, expiry_id);
    fx.set_clock_for_testing(expiry);

    fx.scenario_mut().next_tx(test_constants::admin());
    let mut market = fx.take_market_bundle(expiry_id);
    let settlement_price = settlement_inside_default_finite_range();
    fx.insert_exact_settlement_spot_bundle(&mut market, settlement_price);
    assert_eq!(fx.try_settle_bundle(&mut market), true);
    fx.start_flush_bundle(&mut market);
    fx.value_expiry_bundle(&mut market);
    fx.finish_flush_bundle(&mut market);

    let sent = test_constants::default_initial_expiry_cash();
    assert_single_expiry_pnl(&fx, expiry_id, expiry, settlement_price, sent, sent, true, 0);

    helpers::return_market_bundle(market);
    fx.finish();
}

/// A market the pool never funded and nobody traded still reports on its first
/// settled sweep, although that sweep returns no cash: nothing was sent and nothing
/// came back, a break-even.
#[test]
fun first_settled_sweep_reports_unfunded_expiry() {
    let mut fx = helpers::setup_market_default();
    let expiry = test_constants::short_expiry_ms();
    let expiry_id = fx.create_expiry(expiry);
    fx.set_clock_for_testing(expiry);

    fx.scenario_mut().next_tx(test_constants::admin());
    let mut market = fx.take_market_bundle(expiry_id);
    let settlement_price = settlement_inside_default_finite_range();
    fx.insert_exact_settlement_spot_bundle(&mut market, settlement_price);
    assert_eq!(fx.try_settle_bundle(&mut market), true);
    fx.rebalance_expiry_cash_bundle(&mut market);

    assert_single_expiry_pnl(&fx, expiry_id, expiry, settlement_price, 0, 0, true, 0);
    assert_eq!(helpers::vault(&market).active_expiry_markets().length(), 0);

    helpers::return_market_bundle(market);
    fx.finish();
}

/// A sponsor subsidy counts as cash the expiry returned. The trader pays the mint
/// fee net of `MIN_FEE_SUBSIDY` and the market's sponsor allocation covers the rest,
/// so expiry cash still gains the full `premium + fee`. A losing order therefore
/// reports `premium + fee` as profit, `MIN_FEE_SUBSIDY` more than the trader paid in.
#[test]
fun settled_sweep_counts_sponsor_subsidy_as_received() {
    let (mut fx, expiry_id, trader) = setup_pool_funded_live_market();
    fx.scenario_mut().next_tx(test_constants::alice());
    let mut market = fx.take_market_bundle(expiry_id);
    let mut account = fx.take_account_bundle(&trader);
    fx.sponsor_fee_incentives_bundle(&mut market, constants::min_fee_incentive_sponsorship!());
    // The market already holds its cash target, so this only allocates incentives;
    // the pool's sent total stays at the initial expiry cash.
    fx.rebalance_expiry_cash_bundle(&mut market);
    deepbook_predict::range_test_helpers::prepare_range(&mut fx, &mut market);
    let quote = fx.quote_mint_bundle(
        &market,
        helpers::strike_tick(),
        helpers::strike_tick() + 10,
        test_constants::mint_quantity(),
    );
    assert_eq!(quote.trading_fee(), MINT_MIN_FEE);
    assert_eq!(quote.fee_incentive_subsidy(), MIN_FEE_SUBSIDY);
    fx.mint_bundle(
        &mut market,
        &mut account,
        helpers::strike_tick(),
        helpers::strike_tick() + 10,
        test_constants::mint_quantity(),
    );

    let settlement_price = settlement_below_default_finite_range();
    fx.set_clock_for_testing(test_constants::short_expiry_ms());
    fx.insert_exact_settlement_spot_bundle(&mut market, settlement_price);
    assert_eq!(fx.try_settle_bundle(&mut market), true);
    fx.rebalance_expiry_cash_bundle(&mut market);

    let sent = test_constants::default_initial_expiry_cash();
    assert_single_expiry_pnl(
        &fx,
        expiry_id,
        test_constants::short_expiry_ms(),
        settlement_price,
        sent,
        sent + quote.premium() + MINT_MIN_FEE,
        true,
        quote.premium() + MINT_MIN_FEE,
    );

    helpers::return_account_bundle(account);
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
    assert_eq!(quote.trading_fee(), MINT_MIN_FEE);
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

/// `setup_live_market`, but the market's cash comes from the pool through the
/// production top-up (so the pool's sent total is the initial expiry cash) rather than
/// the test-only cash seam, which the pool never records as sent.
fun setup_pool_funded_live_market(): (helpers::Fixture, ID, helpers::Trader) {
    let mut fx = helpers::setup_market_default();
    let expiry_id = fx.create_expiry(test_constants::short_expiry_ms());
    let trader = fx.create_funded_manager(test_constants::mint_deposit());
    bootstrap_pool(&mut fx, IDLE_SEED);
    fund_empty_market(&mut fx, expiry_id);
    (fx, expiry_id, trader)
}

/// Assert this transaction emitted exactly one `ExpiryPnl` and that it equals the
/// complete expected event for the default-cadence market at `expiry`.
fun assert_single_expiry_pnl(
    fx: &helpers::Fixture,
    expiry_id: ID,
    expiry: u64,
    settlement_price: u64,
    sent_to_expiry: u64,
    received_from_expiry: u64,
    in_profit: bool,
    amount: u64,
) {
    let events = event::events_by_type<vault_events::ExpiryPnl>();
    assert_eq!(events.length(), EXPIRY_PNL_EVENT_COUNT);
    let expected = ExpectedExpiryPnl {
        pool_vault_id: fx.vault_id(),
        expiry_market_id: expiry_id,
        propbook_underlying_id: test_constants::propbook_underlying_id(),
        period_start_ms: expiry - test_constants::default_cadence_period_ms(),
        expiry,
        settlement_price,
        sent_to_expiry,
        received_from_expiry,
        in_profit,
        amount,
    };
    assert_eq!(bcs::to_bytes(&events[0]), bcs::to_bytes(&expected));
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
    deepbook_predict::range_test_helpers::prepare_range(&mut fx, &mut market);

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
