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
    market_oracle::{Self, MarketOracle},
    test_constants
};
use std::unit_test::destroy;

const MINT_QUANTITY: u64 = 1_000_000_000;
const LEVERAGE_ONE_X: u64 = 1_000_000_000;
const SETTLEMENT_PRICE: u64 = 100_000_000_000;
const SECOND_EXPIRY_MS: u64 = 31_536_200_000;

/// Mint after the oracle has expired (pending settlement, not yet settled) must be
/// rejected: `run_liquidation_pass` inside `mint_internal` asserts the oracle is
/// active. The instant `clock == expiry` is the first non-active instant.
#[test, expected_failure(abort_code = market_oracle::EMarketNotActive)]
fun mint_after_expiry_before_settlement_aborts() {
    let (mut fx, expiry_id, oracle_id, mut manager) = helpers::setup_everything();
    fx.scenario_mut().next_tx(test_constants::alice());
    let (pyth, vault, mut market, oracle, config) = fx.take_market(expiry_id, oracle_id);

    // Advance to expiry: status flips active -> pending_settlement.
    fx.set_clock_for_testing(test_constants::default_expiry_ms());
    fx.mint(
        &config,
        &mut manager,
        &mut market,
        &oracle,
        &pyth,
        helpers::min_strike(),
        constants::pos_inf!(),
        MINT_QUANTITY,
        LEVERAGE_ONE_X,
    );

    helpers::return_market(pyth, vault, market, oracle, config);
    destroy(manager);
    fx.finish();
    abort 999
}

/// A settled-market redeem must be a full close: a partial `redeem_settled` aborts.
#[test, expected_failure(abort_code = expiry_market::EFullCloseRequired)]
fun redeem_settled_partial_close_aborts() {
    let (mut fx, expiry_id, oracle_id, mut manager) = helpers::setup_everything();
    fx.scenario_mut().next_tx(test_constants::alice());
    let (mut pyth, vault, mut market, mut oracle, config) = fx.take_market(expiry_id, oracle_id);

    let order_id = fx.mint(
        &config,
        &mut manager,
        &mut market,
        &oracle,
        &pyth,
        helpers::min_strike(),
        constants::pos_inf!(),
        MINT_QUANTITY,
        LEVERAGE_ONE_X,
    );
    fx.settle_oracle(&config, &mut oracle, &mut pyth, SETTLEMENT_PRICE);

    // Partial close (one lot short of full) on a settled order.
    fx.redeem_settled(
        &config,
        &mut manager,
        &mut market,
        &oracle,
        &pyth,
        order_id,
        MINT_QUANTITY - constants::position_lot_size!(),
    );

    helpers::return_market(pyth, vault, market, oracle, config);
    destroy(manager);
    fx.finish();
    abort 999
}

/// A permissionless `redeem_settled` against a still-LIVE order must abort: closing
/// live risk requires a proof.
#[test, expected_failure(abort_code = expiry_market::EProofRequiredForLiveRedeem)]
fun redeem_settled_on_live_order_aborts() {
    let (mut fx, expiry_id, oracle_id, mut manager) = helpers::setup_everything();
    fx.scenario_mut().next_tx(test_constants::alice());
    let (pyth, vault, mut market, oracle, config) = fx.take_market(expiry_id, oracle_id);

    let order_id = fx.mint(
        &config,
        &mut manager,
        &mut market,
        &oracle,
        &pyth,
        helpers::min_strike(),
        constants::pos_inf!(),
        MINT_QUANTITY,
        LEVERAGE_ONE_X,
    );
    // Full close, but no proof and the order is live.
    fx.redeem_settled(&config, &mut manager, &mut market, &oracle, &pyth, order_id, MINT_QUANTITY);

    helpers::return_market(pyth, vault, market, oracle, config);
    destroy(manager);
    fx.finish();
    abort 999
}

/// Redeeming against the WRONG market oracle must abort. `assert_market_oracle`
/// fires before order parsing, so this needs no real order — only two markets and
/// a mismatched oracle. Both expiries are created while the pyth spot is still
/// grid-valid (before any live-price prep moves it).
#[test, expected_failure(abort_code = expiry_market::EWrongMarketOracle)]
fun redeem_with_wrong_oracle_aborts() {
    let mut fx = helpers::setup_market_default();
    let (expiry_a, _oracle_a) = fx.create_expiry(test_constants::default_expiry_ms());
    let (_expiry_b, oracle_b_id) = fx.create_expiry(SECOND_EXPIRY_MS);
    let mut manager = fx.create_funded_manager(test_constants::default_manager_deposit());

    fx.scenario_mut().next_tx(test_constants::alice());
    let (pyth, vault, mut market_a, oracle_a, config) = fx.take_market(expiry_a, _oracle_a);
    let wrong_oracle = fx.scenario_mut().take_shared_by_id<MarketOracle>(oracle_b_id);

    // Redeem on market A but pass oracle B: assert_market_oracle aborts before the
    // (here irrelevant) order id is parsed.
    let dummy_order_id = 0;
    fx.redeem(
        &config,
        &mut manager,
        &mut market_a,
        &wrong_oracle,
        &pyth,
        dummy_order_id,
        MINT_QUANTITY,
    );

    helpers::return_market(pyth, vault, market_a, oracle_a, config);
    sui::test_scenario::return_shared(wrong_oracle);
    destroy(manager);
    fx.finish();
    abort 999
}
