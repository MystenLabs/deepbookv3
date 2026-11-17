// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Guard (gate) tests for the `expiry_market` public flows — closing the
/// happy-path-only coverage gap. Each test drives one production gate to its
/// abort. A gate that fails to fire here is a bug (the `expected_failure` test
/// would itself fail-to-abort). The exception pins a gate that must not fire: the
/// trading pause leaves a live close open.
#[test_only]
module deepbook_predict::expiry_market_gate_tests;

use deepbook_predict::{
    constants,
    expiry_market,
    flow_test_helpers as helpers,
    pricing,
    protocol_config,
    test_constants
};
use propbook::{
    block_scholes_store::{BlockScholesSVIStore, BlockScholesValueStore},
    pyth_feed::PythFeed,
    registry::{Self as propbook_registry, OracleRegistry}
};
use std::unit_test::assert_eq;
use usdc::usdc::USDC;

// A source id distinct from `test_constants::pyth_feed_id()` (= 1), for the
// unrelated second Pyth feed the wrong-feed binding test passes.
// An underlying the market is not for, whose store pair the wrong-store test passes.

/// A permissionless `redeem_settled` against a still-LIVE (unexpired) market must
/// abort: the settled-redeem path requires the market to be terminally settled, and
/// no settlement transition has run.
#[test, expected_failure(abort_code = expiry_market::EMarketNotSettled)]
fun redeem_settled_on_live_order_aborts() {
    let (mut fx, expiry_id, trader) = helpers::setup_everything();
    fx.scenario_mut().next_tx(test_constants::alice());
    let mut market = fx.take_market_bundle(expiry_id);
    let mut account = fx.take_account_bundle(&trader);

    let order_id = fx.mint_bundle(
        &mut market,
        &mut account,
        helpers::strike_tick(),
        constants::pos_inf_tick!(),
        test_constants::mint_quantity(),
    );
    // No settlement transition has run, so the settled-only path rejects it.
    fx.redeem_settled_bundle(
        &mut market,
        &mut account,
        order_id,
    );

    helpers::return_account_bundle(account);

    helpers::return_market_bundle(market);
    fx.finish();
    abort 999
}

/// Minting while this expiry's mint switch is paused must abort: `mint` checks
/// the expiry-local mint pause immediately after the version gate.
#[test, expected_failure(abort_code = expiry_market::EMintPaused)]
fun mint_while_expiry_mint_paused_aborts() {
    let (mut fx, expiry_id, trader) = helpers::setup_everything();
    fx.scenario_mut().next_tx(test_constants::alice());
    let mut market = fx.take_market_bundle(expiry_id);
    let mut account = fx.take_account_bundle(&trader);

    fx.set_expiry_mint_paused_bundle(&mut market, true);
    fx.mint_bundle(
        &mut market,
        &mut account,
        helpers::strike_tick(),
        constants::pos_inf_tick!(),
        test_constants::mint_quantity(),
    );

    helpers::return_account_bundle(account);

    helpers::return_market_bundle(market);
    fx.finish();
    abort 999
}

/// Minting while global trading is paused must abort.
#[test, expected_failure(abort_code = protocol_config::ETradingPaused)]
fun mint_while_trading_paused_aborts() {
    let (mut fx, expiry_id, trader) = helpers::setup_everything();
    fx.scenario_mut().next_tx(test_constants::alice());
    let mut market = fx.take_market_bundle(expiry_id);
    let mut account = fx.take_account_bundle(&trader);

    fx.set_trading_paused_bundle(&mut market, true);
    fx.mint_bundle(
        &mut market,
        &mut account,
        helpers::strike_tick(),
        constants::pos_inf_tick!(),
        test_constants::mint_quantity(),
    );

    helpers::return_account_bundle(account);

    helpers::return_market_bundle(market);
    fx.finish();
    abort 999
}

/// Closing a live position while global trading is paused succeeds: the pause
/// blocks new risk only, so the exit stays open (RP-7). The exit-side twin of
/// `mint_while_trading_paused_aborts`.
#[test]
fun redeem_live_while_trading_paused_closes() {
    let (mut fx, expiry_id, trader) = helpers::setup_everything();
    fx.scenario_mut().next_tx(test_constants::alice());
    let mut market = fx.take_market_bundle(expiry_id);
    let mut account = fx.take_account_bundle(&trader);
    let order_id = fx.mint_bundle(
        &mut market,
        &mut account,
        helpers::strike_tick(),
        constants::pos_inf_tick!(),
        test_constants::mint_quantity(),
    );
    helpers::return_account_bundle(account);
    helpers::return_market_bundle(market);

    fx.scenario_mut().next_tx(test_constants::alice());
    let mut market = fx.take_market_bundle(expiry_id);
    let mut account = fx.take_account_bundle(&trader);
    fx.set_trading_paused_bundle(&mut market, true);
    assert!(helpers::config(&market).trading_paused());
    // Reseed Pyth and the surface one millisecond after the open: the close needs
    // a fresh Pyth spot and a timestamp other than the open's.
    fx.advance_live_oracle_bundle(&mut market, test_constants::default_live_price());
    let balance_before = fx.account_balance_bundle<USDC>(&account);
    let cash_before = helpers::market(&market).cash_balance();

    let remainder = fx.redeem_live_bundle(
        &mut market,
        &mut account,
        order_id,
        test_constants::mint_quantity(),
    );
    assert!(remainder.is_none());
    assert!(!helpers::has_position_bundle(&account, expiry_id, order_id));
    // The proceeds credited to the account are exactly the cash the market paid out.
    let proceeds = fx.account_balance_bundle<USDC>(&account) - balance_before;
    assert!(proceeds > 0);
    assert_eq!(helpers::market(&market).cash_balance(), cash_before - proceeds);
    helpers::assert_market_backed_bundle(&market);

    helpers::return_account_bundle(account);
    helpers::return_market_bundle(market);
    fx.finish();
}
