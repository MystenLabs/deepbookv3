// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Sequential trade tests using real-world Block Scholes data.
/// Each test replays a sequence of mints/redeems against a single vault,
/// advancing the clock and updating oracle params at each step.
/// Expected values are scipy ground truth from generate.py.
#[test_only]
module deepbook_predict::predict_sequence_tests;

use deepbook_predict::{
    generated_scenarios_bulk::{Self as bulk, TradeStep},
    market_key,
    oracle::{Self, new_price_data, new_svi_params},
    precision,
    predict,
    predict_manager::PredictManager
};
use std::unit_test::destroy;
use sui::{clock, coin, sui::SUI, test_scenario};

const ALICE: address = @0xA;

fun run_sequence(steps: vector<TradeStep>, num_trades: u64) {
    let first = &steps[0];

    let mut scenario = test_scenario::begin(ALICE);
    {
        predict::create_manager(scenario.ctx());
    };
    scenario.next_tx(ALICE);

    let mut manager = scenario.take_shared<PredictManager>();

    // Fund manager with enough balance for all mints
    let deposit = coin::mint_for_testing<SUI>(
        bulk::initial_vault_balance(),
        scenario.ctx(),
    );
    manager.deposit(deposit, scenario.ctx());

    // Create funded predict
    let mut predict = predict::create_test_predict<SUI>(scenario.ctx());
    let vault_coin = coin::mint_for_testing<SUI>(
        bulk::initial_vault_balance(),
        scenario.ctx(),
    );
    predict.supply(vault_coin, scenario.ctx());

    // Create oracle with cap from first step's params
    let svi = new_svi_params(
        first.a(),
        first.b(),
        first.rho(),
        first.rho_neg(),
        first.m(),
        first.m_neg(),
        first.sigma(),
    );
    let prices = new_price_data(first.spot(), first.forward());
    let mut oracle = oracle::create_test_oracle(
        b"BTC".to_string(),
        svi,
        prices,
        first.rate(),
        first.expiry_ms(),
        first.now_ms(),
        scenario.ctx(),
    );
    let cap = oracle::create_oracle_cap(scenario.ctx());
    oracle::register_cap(&mut oracle, &cap);

    let mut test_clock = clock::create_for_testing(scenario.ctx());
    test_clock.set_for_testing(first.now_ms());

    scenario.next_tx(ALICE);

    let limit = num_trades.min(steps.length());
    let mut i = 0;
    while (i < limit) {
        let step = &steps[i];

        // Advance clock
        test_clock.set_for_testing(step.now_ms());

        // Update oracle state
        let new_prices = new_price_data(step.spot(), step.forward());
        oracle.update_prices(&cap, new_prices, &test_clock);

        let new_svi = new_svi_params(
            step.a(),
            step.b(),
            step.rho(),
            step.rho_neg(),
            step.m(),
            step.m_neg(),
            step.sigma(),
        );
        oracle.update_svi(&cap, new_svi, step.rate(), &test_clock);

        // Build market key
        let key = if (step.is_up()) {
            market_key::up(oracle::id(&oracle), oracle.expiry(), step.strike())
        } else {
            market_key::down(oracle::id(&oracle), oracle.expiry(), step.strike())
        };

        if (step.is_mint()) {
            let balance_before = manager.balance<SUI>();
            predict.mint(
                &mut manager,
                &oracle,
                key,
                step.quantity(),
                &test_clock,
                scenario.ctx(),
            );
            let cost = balance_before - manager.balance<SUI>();
            precision::assert_approx_abs(cost, step.expected_trade_amount(), 1);
        } else {
            let balance_before = manager.balance<SUI>();
            predict.redeem(
                &mut manager,
                &oracle,
                key,
                step.quantity(),
                &test_clock,
                scenario.ctx(),
            );
            let payout = manager.balance<SUI>() - balance_before;
            precision::assert_approx_abs(payout, step.expected_trade_amount(), 1);
        };

        i = i + 1;
    };

    destroy(predict);
    destroy(oracle);
    destroy(cap);
    destroy(test_clock);
    test_scenario::return_shared(manager);
    scenario.end();
}

#[test]
fun trade_sequence_10() {
    run_sequence(bulk::sequence(), 10);
}
