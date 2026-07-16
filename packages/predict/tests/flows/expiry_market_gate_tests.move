// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Guard (gate) tests for the `expiry_market` public flows — closing the
/// happy-path-only coverage gap. Each test drives one production gate to its
/// abort. A gate that fails to fire here is a bug (the `expected_failure` test
/// would itself fail-to-abort).
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
    block_scholes_forward_feed::BlockScholesForwardFeed,
    block_scholes_spot_feed::BlockScholesSpotFeed,
    block_scholes_svi_feed::BlockScholesSVIFeed,
    pyth_feed::PythFeed,
    registry::{Self as propbook_registry, OracleRegistry}
};

// A source id distinct from `test_constants::pyth_feed_id()` (= 1), for the
// unrelated second feed that the wrong-feed binding tests pass.
const SECOND_SOURCE_ID: u32 = 2;

/// Mint after the market has expired (clock == expiry) must be rejected by the
/// live-pricing boundary before any trade mutation.
#[test, expected_failure(abort_code = pricing::ELivePricingExpired)]
fun mint_after_expiry_aborts() {
    let (mut fx, expiry_id, trader) = helpers::setup_everything();
    fx.scenario_mut().next_tx(test_constants::alice());
    let mut market = fx.take_market_bundle(expiry_id);
    let mut account = fx.take_account_bundle(&trader);

    // Advance to expiry: the market flips active -> not active.
    fx.set_clock_for_testing(test_constants::default_expiry_ms());
    fx.mint_bundle(
        &mut market,
        &mut account,
        helpers::strike_tick(),
        constants::pos_inf_tick!(),
        test_constants::mint_quantity(),
        test_constants::leverage_one_x(),
    );

    helpers::return_account_bundle(account);

    helpers::return_market_bundle(market);
    fx.finish();
    abort 999
}

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
        test_constants::leverage_one_x(),
    );
    // Full close, but no proof and the order is live.
    fx.redeem_settled_bundle(
        &mut market,
        &mut account,
        order_id,
        test_constants::mint_quantity(),
    );

    helpers::return_account_bundle(account);

    helpers::return_market_bundle(market);
    fx.finish();
    abort 999
}

/// Redeeming with the WRONG Pyth feed must abort at the live-pricing binding
/// check. `redeem` decodes the order before loading the pricer, so the test mints
/// a valid order first and then passes a second, unrelated `PythFeed`.
#[test, expected_failure(abort_code = pricing::EWrongPythFeed)]
fun redeem_with_wrong_pyth_feed_aborts() {
    let (mut fx, expiry_id, trader) = helpers::setup_everything();

    fx.scenario_mut().next_tx(test_constants::admin());
    let mut oracle_registry = fx.scenario_mut().take_shared<OracleRegistry>();
    let wrong_pyth_id = propbook_registry::create_and_share_pyth_feed(
        &mut oracle_registry,
        SECOND_SOURCE_ID,
        fx.scenario_mut().ctx(),
    );
    sui::test_scenario::return_shared(oracle_registry);

    fx.scenario_mut().next_tx(test_constants::alice());
    let mut market = fx.take_market_bundle(expiry_id);
    let mut account = fx.take_account_bundle(&trader);
    let wrong_pyth = fx.scenario_mut().take_shared_by_id<PythFeed>(wrong_pyth_id);

    let order_id = fx.mint_bundle(
        &mut market,
        &mut account,
        helpers::strike_tick(),
        constants::pos_inf_tick!(),
        test_constants::mint_quantity(),
        test_constants::leverage_one_x(),
    );
    // Redeem on the real market but pass an unrelated Pyth feed: the live-pricing
    // binding check rejects it after decoding the valid order id.
    fx.redeem_bundle_with_pyth(
        &mut market,
        &mut account,
        &wrong_pyth,
        order_id,
        test_constants::mint_quantity(),
    );

    helpers::return_account_bundle(account);

    helpers::return_market_bundle(market);
    sui::test_scenario::return_shared(wrong_pyth);
    fx.finish();
    abort 999
}

/// Minting with the CORRECT Pyth feed but the WRONG Block Scholes feed must abort:
/// the pricing boundary checks the Pyth binding first, then the BS binding, so a
/// correct Pyth + unrelated BS feed reaches the second assert.
#[test, expected_failure(abort_code = pricing::EWrongBlockScholesSpotFeed)]
fun mint_with_wrong_block_scholes_feed_aborts() {
    let (mut fx, expiry_id, trader) = helpers::setup_everything();

    fx.scenario_mut().next_tx(test_constants::admin());
    let mut oracle_registry = fx.scenario_mut().take_shared<OracleRegistry>();
    let wrong_bs_spot_id = propbook_registry::create_and_share_block_scholes_spot_feed(
        &mut oracle_registry,
        SECOND_SOURCE_ID,
        fx.scenario_mut().ctx(),
    );
    let wrong_bs_forward_id = propbook_registry::create_and_share_block_scholes_forward_feed(
        &mut oracle_registry,
        SECOND_SOURCE_ID,
        fx.scenario_mut().ctx(),
    );
    let wrong_bs_svi_id = propbook_registry::create_and_share_block_scholes_svi_feed(
        &mut oracle_registry,
        SECOND_SOURCE_ID,
        fx.scenario_mut().ctx(),
    );
    sui::test_scenario::return_shared(oracle_registry);

    fx.scenario_mut().next_tx(test_constants::alice());
    let mut market = fx.take_market_bundle(expiry_id);
    let mut account = fx.take_account_bundle(&trader);
    let wrong_bs = helpers::block_scholes_feed_for_testing(
        fx.scenario_mut().take_shared_by_id<BlockScholesSpotFeed>(wrong_bs_spot_id),
        fx.scenario_mut().take_shared_by_id<BlockScholesForwardFeed>(wrong_bs_forward_id),
        fx.scenario_mut().take_shared_by_id<BlockScholesSVIFeed>(wrong_bs_svi_id),
    );

    fx.mint_bundle_with_bs(
        &mut market,
        &mut account,
        &wrong_bs,
        helpers::strike_tick(),
        constants::pos_inf_tick!(),
        test_constants::mint_quantity(),
        test_constants::leverage_one_x(),
    );

    helpers::return_account_bundle(account);

    helpers::return_market_bundle(market);
    helpers::return_bs(wrong_bs);
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
        test_constants::leverage_one_x(),
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
        test_constants::leverage_one_x(),
    );

    helpers::return_account_bundle(account);

    helpers::return_market_bundle(market);
    fx.finish();
    abort 999
}
