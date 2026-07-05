// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Quote/trade parity for `quote_mint`: the quote must equal what the mint
/// actually charges, pinned from BOTH sides of the `max_cost` boundary — a mint
/// bounded at exactly `quote.all_in_cost` succeeds and withdraws exactly that
/// amount; one unit below aborts. Probability parity uses `max_probability` the
/// same way. Gate parity: a paused market aborts the quote with the mint's own
/// code. The account-aware variant equals the anonymous quote for an account
/// with no stake and no builder code.
#[test_only]
module deepbook_predict::quote_mint_tests;

use deepbook_predict::{constants, expiry_market, flow_test_helpers as helpers, test_constants};
use dusdc::dusdc::DUSDC;
use std::unit_test::assert_eq;

const LEVERAGE_ONE_X: u64 = 1_000_000_000;
/// Independently derived in mint_redeem_guard_tests for the same fixture mint:
/// ATM digital Φ(0) premium 500_000_000 + min-fee-bound fee 5_000_000.
const ALL_IN_MINT_COST: u64 = 505_000_000;
const ATM_ENTRY_PROBABILITY: u64 = 500_000_000;

#[test]
fun quote_matches_charged_all_in_cost_exactly() {
    let (mut fx, expiry_id, trader) = helpers::setup_live_market(
        test_constants::default_expiry_ms(),
        test_constants::default_live_price(),
    );
    fx.scenario_mut().next_tx(test_constants::alice());
    let mut market = fx.take_market_bundle(expiry_id);
    let mut account = fx.take_account_bundle(&trader);

    let quote = fx.quote_mint_bundle(
        &market,
        helpers::strike_tick(),
        constants::pos_inf_tick!(),
        test_constants::mint_quantity(),
        LEVERAGE_ONE_X,
    );
    // Pinned against the independently derived constant…
    assert_eq!(quote.quote_all_in_cost(), ALL_IN_MINT_COST);
    assert_eq!(quote.quote_entry_probability(), ATM_ENTRY_PROBABILITY);
    assert_eq!(
        quote.quote_net_premium() + quote.quote_trading_fee()
            - quote.quote_fee_incentive_subsidy()
            + quote.quote_builder_fee() + quote.quote_penalty_fee(),
        quote.quote_all_in_cost(),
    );

    // …and against the trade itself: max_cost bound at exactly the quote
    // succeeds, and the account is debited exactly the quoted amount.
    let balance_before = fx.account_balance_bundle<DUSDC>(&account);
    let order = fx.mint_exact_quantity_bundle(
        &mut market,
        &mut account,
        helpers::strike_tick(),
        constants::pos_inf_tick!(),
        test_constants::mint_quantity(),
        LEVERAGE_ONE_X,
        quote.quote_all_in_cost(),
        quote.quote_entry_probability(),
    );
    assert!(helpers::has_position_bundle(&account, expiry_id, order));
    assert_eq!(
        fx.account_balance_bundle<DUSDC>(&account),
        balance_before - quote.quote_all_in_cost(),
    );

    helpers::return_market_bundle(market);
    helpers::return_account_bundle(account);
    fx.finish();
}

#[test, expected_failure(abort_code = expiry_market::EMintCostAboveMax)]
fun mint_one_below_quoted_cost_aborts() {
    let (mut fx, expiry_id, trader) = helpers::setup_live_market(
        test_constants::default_expiry_ms(),
        test_constants::default_live_price(),
    );
    fx.scenario_mut().next_tx(test_constants::alice());
    let mut market = fx.take_market_bundle(expiry_id);
    let mut account = fx.take_account_bundle(&trader);

    let quote = fx.quote_mint_bundle(
        &market,
        helpers::strike_tick(),
        constants::pos_inf_tick!(),
        test_constants::mint_quantity(),
        LEVERAGE_ONE_X,
    );
    fx.mint_exact_quantity_bundle(
        &mut market,
        &mut account,
        helpers::strike_tick(),
        constants::pos_inf_tick!(),
        test_constants::mint_quantity(),
        LEVERAGE_ONE_X,
        quote.quote_all_in_cost() - 1,
        std::u64::max_value!(),
    );

    abort 999
}

#[test, expected_failure(abort_code = expiry_market::EMintProbabilityAboveMax)]
fun mint_one_below_quoted_probability_aborts() {
    let (mut fx, expiry_id, trader) = helpers::setup_live_market(
        test_constants::default_expiry_ms(),
        test_constants::default_live_price(),
    );
    fx.scenario_mut().next_tx(test_constants::alice());
    let mut market = fx.take_market_bundle(expiry_id);
    let mut account = fx.take_account_bundle(&trader);

    let quote = fx.quote_mint_bundle(
        &market,
        helpers::strike_tick(),
        constants::pos_inf_tick!(),
        test_constants::mint_quantity(),
        LEVERAGE_ONE_X,
    );
    fx.mint_exact_quantity_bundle(
        &mut market,
        &mut account,
        helpers::strike_tick(),
        constants::pos_inf_tick!(),
        test_constants::mint_quantity(),
        LEVERAGE_ONE_X,
        std::u64::max_value!(),
        quote.quote_entry_probability() - 1,
    );

    abort 999
}

#[test, expected_failure(abort_code = expiry_market::EMintPaused)]
fun quote_on_paused_market_aborts_like_the_mint() {
    let (mut fx, expiry_id, _trader) = helpers::setup_live_market(
        test_constants::default_expiry_ms(),
        test_constants::default_live_price(),
    );
    fx.scenario_mut().next_tx(test_constants::alice());
    let mut market = fx.take_market_bundle(expiry_id);
    fx.set_expiry_mint_paused_bundle(&mut market, true);

    fx.quote_mint_bundle(
        &market,
        helpers::strike_tick(),
        constants::pos_inf_tick!(),
        test_constants::mint_quantity(),
        LEVERAGE_ONE_X,
    );

    abort 999
}

#[test]
fun account_quote_equals_anonymous_without_stake_or_builder() {
    let (mut fx, expiry_id, trader) = helpers::setup_live_market(
        test_constants::default_expiry_ms(),
        test_constants::default_live_price(),
    );
    fx.scenario_mut().next_tx(test_constants::alice());
    let market = fx.take_market_bundle(expiry_id);
    let account = fx.take_account_bundle(&trader);

    let anonymous = fx.quote_mint_bundle(
        &market,
        helpers::strike_tick(),
        constants::pos_inf_tick!(),
        test_constants::mint_quantity(),
        LEVERAGE_ONE_X,
    );
    let for_account = fx.quote_mint_for_account_bundle(
        &market,
        &account,
        helpers::strike_tick(),
        constants::pos_inf_tick!(),
        test_constants::mint_quantity(),
        LEVERAGE_ONE_X,
    );
    assert_eq!(for_account.quote_all_in_cost(), anonymous.quote_all_in_cost());
    assert_eq!(for_account.quote_trading_fee(), anonymous.quote_trading_fee());
    assert_eq!(for_account.quote_builder_fee(), 0);

    helpers::return_market_bundle(market);
    helpers::return_account_bundle(account);
    fx.finish();
}

#[test]
fun settlement_readability_on_live_market() {
    let (mut fx, expiry_id, _trader) = helpers::setup_live_market(
        test_constants::default_expiry_ms(),
        test_constants::default_live_price(),
    );
    fx.scenario_mut().next_tx(test_constants::alice());
    let market = fx.take_market_bundle(expiry_id);

    assert!(!market.market_ref().is_settled());
    assert!(market.market_ref().try_settlement_price().is_none());

    helpers::return_market_bundle(market);
    fx.finish();
}
