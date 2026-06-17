// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Slippage guards for mint flows.
#[test_only]
module deepbook_predict::mint_slippage_flow_tests;

use deepbook_predict::{constants, expiry_market, flow_test_helpers as helpers, test_constants};

/// ATM 1x UP over the default short-expiry fixture:
/// net_premium = floor(0.5 * 1_000_000_000) = 500_000_000
/// fee = min_fee * quantity = 5_000_000
/// no builder fee and EWMA penalty disabled, so all-in cost is 505_000_000.
const ATM_ENTRY_PROBABILITY: u64 = 500_000_000;
const ONE_X_MINT_COST: u64 = 505_000_000;
const POST_FULL_MINT_BALANCE: u64 = 495_000_000;

#[test]
fun mint_exact_quantity_accepts_exact_slippage_guards() {
    let (mut fx, expiry_id, trader) = helpers::setup_live_market(
        test_constants::short_expiry_ms(),
        test_constants::default_live_price(),
    );
    fx.scenario_mut().next_tx(test_constants::alice());
    let (pyth, bs, oracle_registry, vault, mut market, config) = fx.take_market(expiry_id);
    let mut wrapper = fx.take_account(&trader);
    let root = fx.take_root();

    let order_id = fx.mint_exact_quantity(
        &config,
        &oracle_registry,
        &mut wrapper,
        &root,
        &mut market,
        &pyth,
        &bs,
        helpers::strike_tick(),
        constants::pos_inf_tick!(),
        test_constants::mint_quantity(),
        test_constants::leverage_one_x(),
        ONE_X_MINT_COST,
        ATM_ENTRY_PROBABILITY,
    );

    assert!(helpers::has_position(&wrapper, expiry_id, order_id));
    helpers::check_manager(
        &fx,
        &wrapper,
        &root,
        expiry_id,
        helpers::expected_manager_state(POST_FULL_MINT_BALANCE, 5_000_000, 1, 0, 0),
    );

    helpers::return_account(wrapper, root);
    helpers::return_market(pyth, bs, oracle_registry, vault, market, config);
    fx.finish();
}

#[test, expected_failure(abort_code = expiry_market::EMintCostAboveMax)]
fun mint_exact_quantity_aborts_above_max_cost() {
    let (mut fx, expiry_id, trader) = helpers::setup_live_market(
        test_constants::short_expiry_ms(),
        test_constants::default_live_price(),
    );
    fx.scenario_mut().next_tx(test_constants::alice());
    let (pyth, bs, oracle_registry, vault, mut market, config) = fx.take_market(expiry_id);
    let mut wrapper = fx.take_account(&trader);
    let root = fx.take_root();

    fx.mint_exact_quantity(
        &config,
        &oracle_registry,
        &mut wrapper,
        &root,
        &mut market,
        &pyth,
        &bs,
        helpers::strike_tick(),
        constants::pos_inf_tick!(),
        test_constants::mint_quantity(),
        test_constants::leverage_one_x(),
        ONE_X_MINT_COST - 1,
        std::u64::max_value!(),
    );

    helpers::return_account(wrapper, root);
    helpers::return_market(pyth, bs, oracle_registry, vault, market, config);
    fx.finish();
    abort 999
}

#[test, expected_failure(abort_code = expiry_market::EMintProbabilityAboveMax)]
fun mint_exact_quantity_aborts_above_max_probability() {
    let (mut fx, expiry_id, trader) = helpers::setup_live_market(
        test_constants::short_expiry_ms(),
        test_constants::default_live_price(),
    );
    fx.scenario_mut().next_tx(test_constants::alice());
    let (pyth, bs, oracle_registry, vault, mut market, config) = fx.take_market(expiry_id);
    let mut wrapper = fx.take_account(&trader);
    let root = fx.take_root();

    fx.mint_exact_quantity(
        &config,
        &oracle_registry,
        &mut wrapper,
        &root,
        &mut market,
        &pyth,
        &bs,
        helpers::strike_tick(),
        constants::pos_inf_tick!(),
        test_constants::mint_quantity(),
        test_constants::leverage_one_x(),
        std::u64::max_value!(),
        ATM_ENTRY_PROBABILITY - 1,
    );

    helpers::return_account(wrapper, root);
    helpers::return_market(pyth, bs, oracle_registry, vault, market, config);
    fx.finish();
    abort 999
}
