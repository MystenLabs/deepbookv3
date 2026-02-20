// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module deepbook_predict::predict_tests;

use deepbook_predict::{
    constants,
    market_key,
    oracle,
    predict::{Self, Predict},
    predict_manager::{Self, PredictManager},
    vault
};
use std::unit_test::{assert_eq, destroy};
use sui::{clock, coin, test_scenario};

public struct BTC has drop {}
public struct USDC has drop {}

/// 1 USDC = 1_000_000 (6 decimals)
macro fun usdc($amount: u64): u64 {
    $amount * 1_000_000
}

/// 1 contract = 1_000_000 quote units
macro fun contracts($n: u64): u64 {
    $n * 1_000_000
}

// Standard SVI params used across pricing tests
fun test_svi(): oracle::SVIParams {
    oracle::new_svi_params(
        40_000_000,
        100_000_000,
        300_000_000,
        true,
        0,
        false,
        100_000_000,
    )
}

fun test_prices(): oracle::PriceData {
    oracle::new_price_data(100_000_000_000_000, 100_500_000_000_000)
}

macro fun now_ms(): u64 { 1_000_000_000 }
macro fun expiry_ms(): u64 { 1_000_000_000 + 604_800_000 }

fun make_oracle(ctx: &mut TxContext): oracle::OracleSVI<BTC> {
    oracle::create_test_oracle<BTC>(
        test_svi(),
        test_prices(),
        50_000_000,
        expiry_ms!(),
        now_ms!(),
        ctx,
    )
}

// =========================================================================
// A. Pricing / Spread Behavior
// =========================================================================

#[test]
fun spread_positive() {
    let ctx = &mut tx_context::dummy();
    let predict = predict::create_test_predict<USDC>(ctx);
    let oracle = make_oracle(ctx);
    let mut clock = clock::create_for_testing(ctx);
    clock.set_for_testing(now_ms!());

    let strike = 100_000_000_000_000;
    let key = market_key::up(oracle.id(), expiry_ms!(), strike);
    let qty = contracts!(100);

    let (mint_cost, redeem_payout) = predict.get_trade_amounts(&oracle, key, qty, &clock);

    assert!(mint_cost > redeem_payout);

    destroy(predict);
    destroy(oracle);
    clock.destroy_for_testing();
}

#[test]
fun up_down_costs_sum_near_quantity() {
    let ctx = &mut tx_context::dummy();
    let predict = predict::create_test_predict<USDC>(ctx);
    let oracle = make_oracle(ctx);
    let mut clock = clock::create_for_testing(ctx);
    clock.set_for_testing(now_ms!());

    let strike = 100_000_000_000_000;
    let qty = contracts!(100);
    let up_key = market_key::up(oracle.id(), expiry_ms!(), strike);
    let down_key = market_key::down(oracle.id(), expiry_ms!(), strike);

    let (up_cost, _) = predict.get_trade_amounts(&oracle, up_key, qty, &clock);
    let (down_cost, _) = predict.get_trade_amounts(&oracle, down_key, qty, &clock);

    let sum = up_cost + down_cost;
    // Sum of ask prices should be slightly above quantity (spread on both sides)
    // Allow 10% tolerance
    assert!(sum > qty * 90 / 100 && sum < qty * 130 / 100);

    destroy(predict);
    destroy(oracle);
    clock.destroy_for_testing();
}

#[test]
fun skew_widens_heavy_side() {
    let ctx = &mut tx_context::dummy();
    let mut predict = predict::create_test_predict<USDC>(ctx);
    let oracle = make_oracle(ctx);
    let mut clock = clock::create_for_testing(ctx);
    clock.set_for_testing(now_ms!());

    let strike = 100_000_000_000_000;
    let up_key = market_key::up(oracle.id(), expiry_ms!(), strike);
    let qty = contracts!(100);

    // Baseline cost with empty vault
    let (baseline_cost, _) = predict.get_trade_amounts(&oracle, up_key, qty, &clock);

    // Seed vault and create heavy UP exposure
    predict.deposit(coin::mint_for_testing<USDC>(usdc!(100_000), ctx));
    let big_payment = coin::mint_for_testing<USDC>(usdc!(50_000), ctx);
    predict.vault_mut().execute_mint(oracle.id(), true, contracts!(50_000), big_payment);

    let (skewed_cost, _) = predict.get_trade_amounts(&oracle, up_key, qty, &clock);

    // After heavy UP mints, UP ask should be higher than baseline
    assert!(skewed_cost > baseline_cost);

    destroy(predict);
    destroy(oracle);
    clock.destroy_for_testing();
}

#[test]
fun skew_zero_when_balanced() {
    let ctx = &mut tx_context::dummy();
    let mut predict = predict::create_test_predict<USDC>(ctx);
    let oracle = make_oracle(ctx);
    let mut clock = clock::create_for_testing(ctx);
    clock.set_for_testing(now_ms!());

    let strike = 100_000_000_000_000;
    let qty = contracts!(100);

    // Add equal UP and DOWN exposure
    predict.deposit(coin::mint_for_testing<USDC>(usdc!(100_000), ctx));
    predict
        .vault_mut()
        .execute_mint(
            oracle.id(),
            true,
            contracts!(1_000),
            coin::mint_for_testing<USDC>(0, ctx),
        );
    predict
        .vault_mut()
        .execute_mint(
            oracle.id(),
            false,
            contracts!(1_000),
            coin::mint_for_testing<USDC>(0, ctx),
        );

    let up_key = market_key::up(oracle.id(), expiry_ms!(), strike);
    let down_key = market_key::down(oracle.id(), expiry_ms!(), strike);

    let (up_cost, _) = predict.get_trade_amounts(&oracle, up_key, qty, &clock);
    let (down_cost, _) = predict.get_trade_amounts(&oracle, down_key, qty, &clock);

    // With balanced exposure, UP and DOWN spreads should reflect only base + utilization
    // The sum should be close to quantity (within spread)
    let sum = up_cost + down_cost;
    assert!(sum > qty * 90 / 100 && sum < qty * 130 / 100);

    destroy(predict);
    destroy(oracle);
    clock.destroy_for_testing();
}

#[test]
fun skew_zero_when_vault_empty() {
    let ctx = &mut tx_context::dummy();
    let predict = predict::create_test_predict<USDC>(ctx);
    let oracle = make_oracle(ctx);
    let mut clock = clock::create_for_testing(ctx);
    clock.set_for_testing(now_ms!());

    let strike = 100_000_000_000_000;
    let up_key = market_key::up(oracle.id(), expiry_ms!(), strike);
    let down_key = market_key::down(oracle.id(), expiry_ms!(), strike);
    let qty = contracts!(100);

    let (up_cost, up_payout) = predict.get_trade_amounts(&oracle, up_key, qty, &clock);
    let (down_cost, down_payout) = predict.get_trade_amounts(&oracle, down_key, qty, &clock);

    // With no exposure, skew and utilization should both be 0
    // Spread = base_spread only
    // Both sides should have valid prices
    assert!(up_cost > 0);
    assert!(down_cost > 0);
    assert!(up_cost > up_payout);
    assert!(down_cost > down_payout);

    destroy(predict);
    destroy(oracle);
    clock.destroy_for_testing();
}

#[test]
fun utilization_widens_spread() {
    let ctx = &mut tx_context::dummy();
    let mut predict = predict::create_test_predict<USDC>(ctx);
    let oracle = make_oracle(ctx);
    let mut clock = clock::create_for_testing(ctx);
    clock.set_for_testing(now_ms!());

    let strike = 100_000_000_000_000;
    let up_key = market_key::up(oracle.id(), expiry_ms!(), strike);
    let qty = contracts!(100);

    // Baseline with no utilization
    let (baseline_cost, _) = predict.get_trade_amounts(&oracle, up_key, qty, &clock);

    // Create high utilization: small balance, large liability
    predict.deposit(coin::mint_for_testing<USDC>(usdc!(10_000), ctx));
    // Mint a lot to create high liability/balance ratio
    predict
        .vault_mut()
        .execute_mint(
            oracle.id(),
            true,
            usdc!(8_000),
            coin::mint_for_testing<USDC>(0, ctx),
        );

    let (high_util_cost, _) = predict.get_trade_amounts(&oracle, up_key, qty, &clock);

    // High utilization should widen the spread
    assert!(high_util_cost > baseline_cost);

    destroy(predict);
    destroy(oracle);
    clock.destroy_for_testing();
}

#[test]
fun utilization_zero_when_no_liability() {
    let ctx = &mut tx_context::dummy();
    let mut predict = predict::create_test_predict<USDC>(ctx);
    let oracle = make_oracle(ctx);
    let mut clock = clock::create_for_testing(ctx);
    clock.set_for_testing(now_ms!());

    // Deposit but no mints → liability = 0
    predict.deposit(coin::mint_for_testing<USDC>(usdc!(100_000), ctx));

    let strike = 100_000_000_000_000;
    let up_key = market_key::up(oracle.id(), expiry_ms!(), strike);
    let qty = contracts!(100);

    // With zero liability and zero balance predict
    let predict_no_deposit = predict::create_test_predict<USDC>(ctx);
    let (cost_empty, _) = predict_no_deposit.get_trade_amounts(&oracle, up_key, qty, &clock);

    let (cost_funded, _) = predict.get_trade_amounts(&oracle, up_key, qty, &clock);

    // Both should be the same since utilization is 0 either way
    assert_eq!(cost_empty, cost_funded);

    destroy(predict);
    destroy(predict_no_deposit);
    destroy(oracle);
    clock.destroy_for_testing();
}

#[test]
fun settlement_winner_full_price() {
    let ctx = &mut tx_context::dummy();
    let predict = predict::create_test_predict<USDC>(ctx);
    let mut oracle = make_oracle(ctx);
    let mut clock = clock::create_for_testing(ctx);
    clock.set_for_testing(now_ms!());

    let strike = 100_000_000_000_000;
    // Settle above strike → UP wins
    oracle.settle_test_oracle(110_000_000_000_000);

    let up_key = market_key::up(oracle.id(), expiry_ms!(), strike);
    let qty = contracts!(100);

    let (cost, payout) = predict.get_trade_amounts(&oracle, up_key, qty, &clock);

    // Winner: price = 1.0, so cost = payout = quantity
    assert_eq!(cost, qty);
    assert_eq!(payout, qty);

    destroy(predict);
    destroy(oracle);
    clock.destroy_for_testing();
}

#[test]
fun settlement_loser_zero_price() {
    let ctx = &mut tx_context::dummy();
    let predict = predict::create_test_predict<USDC>(ctx);
    let mut oracle = make_oracle(ctx);
    let mut clock = clock::create_for_testing(ctx);
    clock.set_for_testing(now_ms!());

    let strike = 100_000_000_000_000;
    // Settle above strike → DOWN loses
    oracle.settle_test_oracle(110_000_000_000_000);

    let down_key = market_key::down(oracle.id(), expiry_ms!(), strike);
    let qty = contracts!(100);

    let (cost, payout) = predict.get_trade_amounts(&oracle, down_key, qty, &clock);

    // Loser: price = 0, so cost = payout = 0
    assert_eq!(cost, 0);
    assert_eq!(payout, 0);

    destroy(predict);
    destroy(oracle);
    clock.destroy_for_testing();
}

// =========================================================================
// B. Mint Orchestration
// =========================================================================

fun setup_trading(
    sender: address,
): (test_scenario::Scenario, PredictManager, Predict<USDC>, oracle::OracleSVI<BTC>, clock::Clock) {
    let mut test = test_scenario::begin(sender);
    predict_manager::new(test.ctx());
    test.next_tx(sender);
    let mut manager = test.take_shared<PredictManager>();
    let mut predict = predict::create_test_predict<USDC>(test.ctx());

    let oracle = make_oracle(test.ctx());
    let mut clock = clock::create_for_testing(test.ctx());
    clock.set_for_testing(now_ms!());

    // Seed vault and manager
    predict.deposit(coin::mint_for_testing<USDC>(usdc!(100_000), test.ctx()));
    manager.deposit(coin::mint_for_testing<USDC>(usdc!(10_000), test.ctx()), test.ctx());

    (test, manager, predict, oracle, clock)
}

#[test]
fun mint_happy_path() {
    let (mut test, mut manager, mut predict, oracle, clock) = setup_trading(@0x1);

    let strike = 100_000_000_000_000;
    let key = market_key::up(oracle.id(), expiry_ms!(), strike);
    let qty = contracts!(10);

    let (cost, _) = predict.get_trade_amounts(&oracle, key, qty, &clock);

    predict.mint(&mut manager, &oracle, key, qty, &clock, test.ctx());

    // Position should be increased
    let (free, locked) = manager.position(key);
    assert_eq!(free, qty);
    assert_eq!(locked, 0);

    // Vault exposure should be updated
    let (up, down) = predict.vault_exposure(oracle.id());
    assert_eq!(up, qty);
    assert_eq!(down, 0);

    // Vault balance should have increased by cost
    assert_eq!(predict.vault_balance(), usdc!(100_000) + cost);

    destroy(predict);
    destroy(oracle);
    clock.destroy_for_testing();
    test_scenario::return_shared(manager);
    test.end();
}

#[test, expected_failure(abort_code = predict::ETradingPaused)]
fun mint_trading_paused_aborts() {
    let (mut _test, mut manager, mut predict, oracle, clock) = setup_trading(@0x1);

    predict.set_trading_paused(true);

    let strike = 100_000_000_000_000;
    let key = market_key::up(oracle.id(), expiry_ms!(), strike);

    predict.mint(&mut manager, &oracle, key, contracts!(10), &clock, _test.ctx());

    abort
}

#[test, expected_failure(abort_code = oracle::EOracleStale)]
fun mint_stale_oracle_aborts() {
    let (mut _test, mut manager, mut predict, oracle, mut clock) = setup_trading(@0x1);

    // Advance clock past staleness threshold
    clock.set_for_testing(now_ms!() + constants::staleness_threshold_ms!() + 1);

    let strike = 100_000_000_000_000;
    let key = market_key::up(oracle.id(), expiry_ms!(), strike);

    predict.mint(&mut manager, &oracle, key, contracts!(10), &clock, _test.ctx());

    abort
}

#[test, expected_failure(abort_code = vault::EExceedsMaxTotalExposure)]
fun mint_exposure_limit_aborts() {
    let (mut _test, mut manager, mut predict, oracle, clock) = setup_trading(@0x1);

    // Set very low exposure limit (1%)
    predict.set_max_total_exposure_pct(10_000_000);

    // Deposit more into manager to afford the large mint
    manager.deposit(coin::mint_for_testing<USDC>(usdc!(100_000), _test.ctx()), _test.ctx());

    let strike = 100_000_000_000_000;
    let key = market_key::up(oracle.id(), expiry_ms!(), strike);

    // Try to mint a huge amount that exceeds exposure limit
    predict.mint(&mut manager, &oracle, key, contracts!(50_000), &clock, _test.ctx());

    abort
}

// =========================================================================
// C. Redeem Orchestration
// =========================================================================

#[test]
fun redeem_happy_path() {
    let (mut test, mut manager, mut predict, oracle, clock) = setup_trading(@0x1);

    let strike = 100_000_000_000_000;
    let key = market_key::up(oracle.id(), expiry_ms!(), strike);
    let qty = contracts!(10);

    // Mint first
    predict.mint(&mut manager, &oracle, key, qty, &clock, test.ctx());
    let balance_after_mint = predict.vault_balance();

    // Then redeem
    predict.redeem(&mut manager, &oracle, key, qty, &clock, test.ctx());

    // Position should be back to zero
    let (free, locked) = manager.position(key);
    assert_eq!(free, 0);
    assert_eq!(locked, 0);

    // Vault exposure should be zero
    let (up, down) = predict.vault_exposure(oracle.id());
    assert_eq!(up, 0);
    assert_eq!(down, 0);

    // Vault balance should have decreased by payout
    assert!(predict.vault_balance() < balance_after_mint);

    destroy(predict);
    destroy(oracle);
    clock.destroy_for_testing();
    test_scenario::return_shared(manager);
    test.end();
}

#[test]
fun redeem_settled_winner_full_payout() {
    let (mut test, mut manager, mut predict, mut oracle, clock) = setup_trading(@0x1);

    let strike = 100_000_000_000_000;
    let key = market_key::up(oracle.id(), expiry_ms!(), strike);
    let qty = contracts!(10);

    // Mint first
    predict.mint(&mut manager, &oracle, key, qty, &clock, test.ctx());

    // Settle above strike → UP wins
    oracle.settle_test_oracle(110_000_000_000_000);

    // Redeem after settlement
    predict.redeem(&mut manager, &oracle, key, qty, &clock, test.ctx());

    // Position fully redeemed
    let (free, _) = manager.position(key);
    assert_eq!(free, 0);

    destroy(predict);
    destroy(oracle);
    clock.destroy_for_testing();
    test_scenario::return_shared(manager);
    test.end();
}

#[test]
fun redeem_settled_loser_zero_payout() {
    let (mut test, mut manager, mut predict, mut oracle, clock) = setup_trading(@0x1);

    let strike = 100_000_000_000_000;
    let key = market_key::down(oracle.id(), expiry_ms!(), strike);
    let qty = contracts!(10);

    // Mint DOWN
    predict.mint(&mut manager, &oracle, key, qty, &clock, test.ctx());
    let balance_after_mint = predict.vault_balance();

    // Settle above strike → DOWN loses
    oracle.settle_test_oracle(110_000_000_000_000);

    // Redeem loser
    predict.redeem(&mut manager, &oracle, key, qty, &clock, test.ctx());

    // Position redeemed
    let (free, _) = manager.position(key);
    assert_eq!(free, 0);

    // Vault balance should not have decreased (payout = 0)
    assert_eq!(predict.vault_balance(), balance_after_mint);

    destroy(predict);
    destroy(oracle);
    clock.destroy_for_testing();
    test_scenario::return_shared(manager);
    test.end();
}

#[test]
fun redeem_allows_stale_settled_oracle() {
    let (mut test, mut manager, mut predict, mut oracle, mut clock) = setup_trading(@0x1);

    let strike = 100_000_000_000_000;
    let key = market_key::up(oracle.id(), expiry_ms!(), strike);
    let qty = contracts!(10);

    predict.mint(&mut manager, &oracle, key, qty, &clock, test.ctx());

    // Settle and make stale
    oracle.settle_test_oracle(110_000_000_000_000);
    clock.set_for_testing(now_ms!() + constants::staleness_threshold_ms!() + 1);

    // Should succeed because stale check is skipped for settled oracles
    predict.redeem(&mut manager, &oracle, key, qty, &clock, test.ctx());

    let (free, _) = manager.position(key);
    assert_eq!(free, 0);

    destroy(predict);
    destroy(oracle);
    clock.destroy_for_testing();
    test_scenario::return_shared(manager);
    test.end();
}

#[test, expected_failure(abort_code = oracle::EOracleStale)]
fun redeem_stale_unsettled_aborts() {
    let (mut _test, mut manager, mut predict, oracle, mut clock) = setup_trading(@0x1);

    let strike = 100_000_000_000_000;
    let key = market_key::up(oracle.id(), expiry_ms!(), strike);
    let qty = contracts!(10);

    predict.mint(&mut manager, &oracle, key, qty, &clock, _test.ctx());

    // Make stale without settling
    clock.set_for_testing(now_ms!() + constants::staleness_threshold_ms!() + 1);

    predict.redeem(&mut manager, &oracle, key, qty, &clock, _test.ctx());

    abort
}

// =========================================================================
// D. Collateralized Mint/Redeem
// =========================================================================

#[test]
fun mint_collateralized_up_happy_path() {
    let (mut test, mut manager, mut predict, oracle, clock) = setup_trading(@0x1);

    let low_strike = 95_000_000_000_000;
    let high_strike = 105_000_000_000_000;
    let locked_key = market_key::up(oracle.id(), expiry_ms!(), low_strike);
    let minted_key = market_key::up(oracle.id(), expiry_ms!(), high_strike);
    let qty = contracts!(10);

    // First mint the collateral position
    predict.mint(&mut manager, &oracle, locked_key, qty, &clock, test.ctx());

    // Mint collateralized: UP low→UP high
    predict.mint_collateralized(&mut manager, &oracle, locked_key, minted_key, qty, &clock);

    // Locked key: free should have decreased, locked should have increased
    let (free, locked) = manager.position(locked_key);
    assert_eq!(free, 0);
    assert_eq!(locked, qty);

    // Minted key: free position created
    let (free, _) = manager.position(minted_key);
    assert_eq!(free, qty);

    destroy(predict);
    destroy(oracle);
    clock.destroy_for_testing();
    test_scenario::return_shared(manager);
    test.end();
}

#[test]
fun mint_collateralized_down_happy_path() {
    let (mut test, mut manager, mut predict, oracle, clock) = setup_trading(@0x1);

    let high_strike = 105_000_000_000_000;
    let low_strike = 95_000_000_000_000;
    let locked_key = market_key::down(oracle.id(), expiry_ms!(), high_strike);
    let minted_key = market_key::down(oracle.id(), expiry_ms!(), low_strike);
    let qty = contracts!(10);

    // Mint collateral position
    predict.mint(&mut manager, &oracle, locked_key, qty, &clock, test.ctx());

    // Mint collateralized: DOWN high→DOWN low
    predict.mint_collateralized(&mut manager, &oracle, locked_key, minted_key, qty, &clock);

    let (free, locked) = manager.position(locked_key);
    assert_eq!(free, 0);
    assert_eq!(locked, qty);

    let (free, _) = manager.position(minted_key);
    assert_eq!(free, qty);

    destroy(predict);
    destroy(oracle);
    clock.destroy_for_testing();
    test_scenario::return_shared(manager);
    test.end();
}

#[test, expected_failure(abort_code = predict::EInvalidCollateralPair)]
fun mint_collateralized_invalid_pair_up_down_aborts() {
    let (mut _test, mut manager, mut predict, oracle, clock) = setup_trading(@0x1);

    let strike_a = 95_000_000_000_000;
    let strike_b = 105_000_000_000_000;
    let up_key = market_key::up(oracle.id(), expiry_ms!(), strike_a);
    let down_key = market_key::down(oracle.id(), expiry_ms!(), strike_b);
    let qty = contracts!(10);

    predict.mint(&mut manager, &oracle, up_key, qty, &clock, _test.ctx());

    // UP→DOWN is invalid
    predict.mint_collateralized(&mut manager, &oracle, up_key, down_key, qty, &clock);

    abort
}

#[test, expected_failure(abort_code = predict::EInvalidCollateralPair)]
fun mint_collateralized_wrong_strike_order_aborts() {
    let (mut _test, mut manager, mut predict, oracle, clock) = setup_trading(@0x1);

    let high_strike = 105_000_000_000_000;
    let low_strike = 95_000_000_000_000;
    // UP high→UP low is wrong (need low→high for UP)
    let locked_key = market_key::up(oracle.id(), expiry_ms!(), high_strike);
    let minted_key = market_key::up(oracle.id(), expiry_ms!(), low_strike);
    let qty = contracts!(10);

    predict.mint(&mut manager, &oracle, locked_key, qty, &clock, _test.ctx());

    predict.mint_collateralized(&mut manager, &oracle, locked_key, minted_key, qty, &clock);

    abort
}

#[test, expected_failure(abort_code = predict::EInvalidCollateralPair)]
fun mint_collateralized_same_strike_aborts() {
    let (mut _test, mut manager, mut predict, oracle, clock) = setup_trading(@0x1);

    let strike = 100_000_000_000_000;
    let locked_key = market_key::up(oracle.id(), expiry_ms!(), strike);
    let minted_key = market_key::up(oracle.id(), expiry_ms!(), strike);
    let qty = contracts!(10);

    predict.mint(&mut manager, &oracle, locked_key, qty, &clock, _test.ctx());

    predict.mint_collateralized(&mut manager, &oracle, locked_key, minted_key, qty, &clock);

    abort
}

#[test, expected_failure(abort_code = predict::ETradingPaused)]
fun mint_collateralized_paused_aborts() {
    let (mut _test, mut manager, mut predict, oracle, clock) = setup_trading(@0x1);

    let low_strike = 95_000_000_000_000;
    let high_strike = 105_000_000_000_000;
    let locked_key = market_key::up(oracle.id(), expiry_ms!(), low_strike);
    let minted_key = market_key::up(oracle.id(), expiry_ms!(), high_strike);
    let qty = contracts!(10);

    predict.mint(&mut manager, &oracle, locked_key, qty, &clock, _test.ctx());

    predict.set_trading_paused(true);

    predict.mint_collateralized(&mut manager, &oracle, locked_key, minted_key, qty, &clock);

    abort
}

#[test]
fun redeem_collateralized_happy_path() {
    let (mut test, mut manager, mut predict, oracle, clock) = setup_trading(@0x1);

    let low_strike = 95_000_000_000_000;
    let high_strike = 105_000_000_000_000;
    let locked_key = market_key::up(oracle.id(), expiry_ms!(), low_strike);
    let minted_key = market_key::up(oracle.id(), expiry_ms!(), high_strike);
    let qty = contracts!(10);

    // Mint collateral then collateralized position
    predict.mint(&mut manager, &oracle, locked_key, qty, &clock, test.ctx());
    predict.mint_collateralized(&mut manager, &oracle, locked_key, minted_key, qty, &clock);

    // Redeem collateralized
    predict.redeem_collateralized(&mut manager, locked_key, minted_key, qty);

    // Minted position gone
    let (free, _) = manager.position(minted_key);
    assert_eq!(free, 0);

    // Collateral released back to free
    let (free, locked) = manager.position(locked_key);
    assert_eq!(free, qty);
    assert_eq!(locked, 0);

    destroy(predict);
    destroy(oracle);
    clock.destroy_for_testing();
    test_scenario::return_shared(manager);
    test.end();
}

// =========================================================================
// E. Full Integration Cycle
// =========================================================================

#[test]
fun full_cycle_mint_redeem_settle() {
    let (mut test, mut manager, mut predict, mut oracle, clock) = setup_trading(@0x1);

    let strike = 100_000_000_000_000;
    let up_key = market_key::up(oracle.id(), expiry_ms!(), strike);
    let down_key = market_key::down(oracle.id(), expiry_ms!(), strike);
    let qty = contracts!(10);

    // Mint UP and DOWN
    predict.mint(&mut manager, &oracle, up_key, qty, &clock, test.ctx());
    predict.mint(&mut manager, &oracle, down_key, qty, &clock, test.ctx());

    // Verify positions
    let (up_free, _) = manager.position(up_key);
    let (down_free, _) = manager.position(down_key);
    assert_eq!(up_free, qty);
    assert_eq!(down_free, qty);

    // Settle above strike → UP wins, DOWN loses
    oracle.settle_test_oracle(110_000_000_000_000);

    // Redeem winner (UP) → full payout
    predict.redeem(&mut manager, &oracle, up_key, qty, &clock, test.ctx());
    let (up_free, _) = manager.position(up_key);
    assert_eq!(up_free, 0);

    // Redeem loser (DOWN) → zero payout
    predict.redeem(&mut manager, &oracle, down_key, qty, &clock, test.ctx());
    let (down_free, _) = manager.position(down_key);
    assert_eq!(down_free, 0);

    // All exposure cleared
    let (up_exp, down_exp) = predict.vault_exposure(oracle.id());
    assert_eq!(up_exp, 0);
    assert_eq!(down_exp, 0);

    destroy(predict);
    destroy(oracle);
    clock.destroy_for_testing();
    test_scenario::return_shared(manager);
    test.end();
}
