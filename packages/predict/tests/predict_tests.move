// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module deepbook_predict::predict_tests;

use deepbook_predict::{
    market_key,
    oracle::{Self, new_price_data, new_svi_params},
    predict::{Self, Predict},
    predict_manager::PredictManager
};
use std::unit_test::{assert_eq, destroy};
use sui::{clock, coin, sui::SUI, test_scenario::{Self, Scenario}};

const FLOAT: u64 = 1_000_000_000;
const ALICE: address = @0xA;

// === Helpers ===

// Create a non-shared Predict<SUI> for testing.
fun create_predict(ctx: &mut TxContext): Predict<SUI> {
    predict::create_test_predict<SUI>(ctx)
}

// Create a live (non-settled) oracle with simple params.
// Uses a=0, b=1, rho=0, m=0, sigma=0.25, rate=0.
// expiry far in the future, timestamp=0 (not stale when clock=0).
fun create_live_oracle(ctx: &mut TxContext): oracle::OracleSVI {
    let svi = new_svi_params(0, FLOAT, 0, false, 0, false, 250_000_000);
    let prices = new_price_data(100 * FLOAT, 100 * FLOAT);
    oracle::create_test_oracle(
        b"BTC".to_string(),
        svi,
        prices,
        0,
        1_000_000_000, // 1M seconds expiry
        0,
        ctx,
    )
}

// Create a settled oracle at the given settlement price.
fun create_settled_oracle(settlement_price: u64, ctx: &mut TxContext): oracle::OracleSVI {
    let svi = new_svi_params(0, 0, 0, false, 0, false, 0);
    let prices = new_price_data(0, 0);
    let mut oracle = oracle::create_test_oracle(
        b"BTC".to_string(),
        svi,
        prices,
        0,
        100_000,
        0,
        ctx,
    );
    oracle::settle_test_oracle(&mut oracle, settlement_price);
    oracle
}

// Setup: create PredictManager for ALICE via test_scenario,
// deposit funds, then return the scenario.
fun setup_with_manager(funds: u64): Scenario {
    let mut scenario = test_scenario::begin(ALICE);
    {
        predict::create_manager(scenario.ctx());
    };
    scenario.next_tx(ALICE);
    if (funds > 0) {
        let mut manager = scenario.take_shared<PredictManager>();
        let coin = coin::mint_for_testing<SUI>(funds, scenario.ctx());
        manager.deposit(coin, scenario.ctx());
        test_scenario::return_shared(manager);
        scenario.next_tx(ALICE);
    };
    scenario
}

// ============================================================
// Supply / Withdraw
// ============================================================

#[test]
fun supply_first_deposit_one_to_one_shares() {
    let ctx = &mut tx_context::dummy();
    let mut predict = create_predict(ctx);

    let coin = coin::mint_for_testing<SUI>(1_000_000, ctx);
    let shares = predict.supply(coin, ctx);

    // First depositor: shares = amount = 1_000_000
    assert_eq!(shares, 1_000_000);
    assert_eq!(predict::vault_balance(&predict), 1_000_000);

    destroy(predict);
}

#[test]
fun supply_second_deposit_proportional_shares() {
    let ctx = &mut tx_context::dummy();
    let mut predict = create_predict(ctx);

    let coin1 = coin::mint_for_testing<SUI>(1_000_000, ctx);
    predict.supply(coin1, ctx);

    // vault_value = 1_000_000. Deposit another 500_000.
    // shares = mul(500_000, div(1_000_000, 1_000_000)) = 500_000
    let coin2 = coin::mint_for_testing<SUI>(500_000, ctx);
    let shares2 = predict.supply(coin2, ctx);
    assert_eq!(shares2, 500_000);
    assert_eq!(predict::vault_balance(&predict), 1_500_000);

    destroy(predict);
}

#[test]
fun withdraw_returns_correct_amount() {
    let mut scenario = test_scenario::begin(ALICE);
    let mut predict = create_predict(scenario.ctx());

    let coin = coin::mint_for_testing<SUI>(1_000_000, scenario.ctx());
    predict.supply(coin, scenario.ctx());

    scenario.next_tx(ALICE);
    let withdrawn = predict.withdraw(500_000, scenario.ctx());
    assert_eq!(withdrawn.value(), 500_000);
    assert_eq!(predict::vault_balance(&predict), 500_000);

    destroy(withdrawn);
    destroy(predict);
    scenario.end();
}

#[test]
fun withdraw_all_returns_full_amount() {
    let mut scenario = test_scenario::begin(ALICE);
    let mut predict = create_predict(scenario.ctx());

    let coin = coin::mint_for_testing<SUI>(1_000_000, scenario.ctx());
    predict.supply(coin, scenario.ctx());

    scenario.next_tx(ALICE);
    let withdrawn = predict.withdraw_all(scenario.ctx());
    assert_eq!(withdrawn.value(), 1_000_000);
    assert_eq!(predict::vault_balance(&predict), 0);

    destroy(withdrawn);
    destroy(predict);
    scenario.end();
}

#[test, expected_failure(abort_code = predict::EWithdrawExceedsAvailable)]
fun withdraw_blocked_by_max_payout() {
    let mut scenario = test_scenario::begin(ALICE);
    let mut predict = create_predict(scenario.ctx());

    // Supply 100
    let coin = coin::mint_for_testing<SUI>(100 * FLOAT, scenario.ctx());
    predict.supply(coin, scenario.ctx());

    // Insert a settled winning position to create max_payout
    let oracle = create_settled_oracle(200 * FLOAT, scenario.ctx());
    let clock = clock::create_for_testing(scenario.ctx());
    predict
        .vault_mut()
        .insert_position(
            &oracle,
            true,
            50 * FLOAT,
            80 * FLOAT,
            &clock,
            scenario.ctx(),
        );
    // max_payout = 80*FLOAT. available = 100*FLOAT - 80*FLOAT = 20*FLOAT

    scenario.next_tx(ALICE);
    // Try to withdraw 30*FLOAT > available 20*FLOAT
    let _coin = predict.withdraw(30 * FLOAT, scenario.ctx());

    abort
}

#[test]
fun withdraw_up_to_available_succeeds() {
    let mut scenario = test_scenario::begin(ALICE);
    let mut predict = create_predict(scenario.ctx());

    let coin = coin::mint_for_testing<SUI>(100 * FLOAT, scenario.ctx());
    predict.supply(coin, scenario.ctx());

    let oracle = create_settled_oracle(200 * FLOAT, scenario.ctx());
    let clock = clock::create_for_testing(scenario.ctx());
    predict
        .vault_mut()
        .insert_position(
            &oracle,
            true,
            50 * FLOAT,
            80 * FLOAT,
            &clock,
            scenario.ctx(),
        );
    // available = 100 - 80 = 20*FLOAT

    scenario.next_tx(ALICE);
    let withdrawn = predict.withdraw(20 * FLOAT, scenario.ctx());
    assert_eq!(withdrawn.value(), 20 * FLOAT);

    destroy(withdrawn);
    destroy(predict);
    destroy(oracle);
    destroy(clock);
    scenario.end();
}

// ============================================================
// Redeem with settled oracle (deterministic)
// ============================================================

#[test]
fun redeem_settled_up_wins_full_payout() {
    let mut scenario = setup_with_manager(100 * FLOAT);
    let mut predict = create_predict(scenario.ctx());

    // Supply vault liquidity
    let liq = coin::mint_for_testing<SUI>(1000 * FLOAT, scenario.ctx());
    predict.supply(liq, scenario.ctx());

    // Settle oracle: settlement 200 > strike 50, UP wins
    let mut oracle = create_live_oracle(scenario.ctx());
    let clock = clock::create_for_testing(scenario.ctx());
    let oracle_id = oracle::id(&oracle);
    let key = market_key::up(oracle_id, oracle.expiry(), 50 * FLOAT);

    // We need to give Alice a position to redeem.
    // Use increase_position directly (test_only workaround since mint requires live oracle)
    scenario.next_tx(ALICE);
    {
        let mut manager = scenario.take_shared<PredictManager>();
        manager.increase_position(key, 10 * FLOAT);

        // Also insert into vault so remove_position works
        predict
            .vault_mut()
            .insert_position(
                &oracle,
                true,
                50 * FLOAT,
                10 * FLOAT,
                &clock,
                scenario.ctx(),
            );

        // Now settle the oracle
        oracle::settle_test_oracle(&mut oracle, 200 * FLOAT);

        // Redeem: settled UP wins at strike 50. bid = 1e9. payout = mul(1e9, 10*FLOAT) = 10*FLOAT
        let balance_before = predict::vault_balance(&predict);
        predict.redeem(&mut manager, &oracle, key, 10 * FLOAT, &clock, scenario.ctx());
        let balance_after = predict::vault_balance(&predict);

        // Payout dispensed = 10*FLOAT
        assert_eq!(balance_before - balance_after, 10 * FLOAT);
        // Position fully redeemed
        let (free, locked) = manager.position(key);
        assert_eq!(free, 0);
        assert_eq!(locked, 0);

        test_scenario::return_shared(manager);
    };

    destroy(predict);
    destroy(oracle);
    destroy(clock);
    scenario.end();
}

#[test]
fun redeem_settled_up_loses_zero_payout() {
    let mut scenario = setup_with_manager(100 * FLOAT);
    let mut predict = create_predict(scenario.ctx());

    let liq = coin::mint_for_testing<SUI>(1000 * FLOAT, scenario.ctx());
    predict.supply(liq, scenario.ctx());

    let mut oracle = create_live_oracle(scenario.ctx());
    let clock = clock::create_for_testing(scenario.ctx());
    let oracle_id = oracle::id(&oracle);
    let key = market_key::up(oracle_id, oracle.expiry(), 150 * FLOAT);

    scenario.next_tx(ALICE);
    {
        let mut manager = scenario.take_shared<PredictManager>();
        manager.increase_position(key, 10 * FLOAT);

        predict
            .vault_mut()
            .insert_position(
                &oracle,
                true,
                150 * FLOAT,
                10 * FLOAT,
                &clock,
                scenario.ctx(),
            );

        // Settle below strike: 50 < 150, UP loses
        oracle::settle_test_oracle(&mut oracle, 50 * FLOAT);

        // Redeem: bid = 0. payout = 0.
        let balance_before = predict::vault_balance(&predict);
        predict.redeem(&mut manager, &oracle, key, 10 * FLOAT, &clock, scenario.ctx());
        let balance_after = predict::vault_balance(&predict);

        // No payout dispensed
        assert_eq!(balance_before, balance_after);

        test_scenario::return_shared(manager);
    };

    destroy(predict);
    destroy(oracle);
    destroy(clock);
    scenario.end();
}

// ============================================================
// Collateralized mint / redeem
// ============================================================

#[test]
fun collateralized_mint_up_lower_to_higher_strike() {
    let mut scenario = setup_with_manager(100 * FLOAT);
    let mut predict = create_predict(scenario.ctx());

    let oracle = create_live_oracle(scenario.ctx());
    let clock = clock::create_for_testing(scenario.ctx());
    let oracle_id = oracle::id(&oracle);

    let locked_key = market_key::up(oracle_id, oracle.expiry(), 80 * FLOAT);
    let minted_key = market_key::up(oracle_id, oracle.expiry(), 120 * FLOAT);

    scenario.next_tx(ALICE);
    {
        let mut manager = scenario.take_shared<PredictManager>();

        // Give Alice the collateral position
        manager.increase_position(locked_key, 5 * FLOAT);

        // Collateralized mint: UP lower strike → UP higher strike
        predict.mint_collateralized(
            &mut manager,
            &oracle,
            locked_key,
            minted_key,
            5 * FLOAT,
            &clock,
            scenario.ctx(),
        );

        // Locked position: free should be 0, locked should be 5
        let (free, locked) = manager.position(locked_key);
        assert_eq!(free, 0);
        assert_eq!(locked, 5 * FLOAT);

        // Minted position: free should be 5
        let (free_m, locked_m) = manager.position(minted_key);
        assert_eq!(free_m, 5 * FLOAT);
        assert_eq!(locked_m, 0);

        test_scenario::return_shared(manager);
    };

    destroy(predict);
    destroy(oracle);
    destroy(clock);
    scenario.end();
}

#[test]
fun collateralized_mint_dn_higher_to_lower_strike() {
    let mut scenario = setup_with_manager(100 * FLOAT);
    let mut predict = create_predict(scenario.ctx());

    let oracle = create_live_oracle(scenario.ctx());
    let clock = clock::create_for_testing(scenario.ctx());
    let oracle_id = oracle::id(&oracle);

    let locked_key = market_key::down(oracle_id, oracle.expiry(), 120 * FLOAT);
    let minted_key = market_key::down(oracle_id, oracle.expiry(), 80 * FLOAT);

    scenario.next_tx(ALICE);
    {
        let mut manager = scenario.take_shared<PredictManager>();
        manager.increase_position(locked_key, 3 * FLOAT);

        predict.mint_collateralized(
            &mut manager,
            &oracle,
            locked_key,
            minted_key,
            3 * FLOAT,
            &clock,
            scenario.ctx(),
        );

        let (free, locked) = manager.position(locked_key);
        assert_eq!(free, 0);
        assert_eq!(locked, 3 * FLOAT);

        let (free_m, locked_m) = manager.position(minted_key);
        assert_eq!(free_m, 3 * FLOAT);
        assert_eq!(locked_m, 0);

        test_scenario::return_shared(manager);
    };

    destroy(predict);
    destroy(oracle);
    destroy(clock);
    scenario.end();
}

#[test]
fun collateralized_redeem_releases_collateral() {
    let mut scenario = setup_with_manager(100 * FLOAT);
    let mut predict = create_predict(scenario.ctx());

    let oracle = create_live_oracle(scenario.ctx());
    let clock = clock::create_for_testing(scenario.ctx());
    let oracle_id = oracle::id(&oracle);

    let locked_key = market_key::up(oracle_id, oracle.expiry(), 80 * FLOAT);
    let minted_key = market_key::up(oracle_id, oracle.expiry(), 120 * FLOAT);

    scenario.next_tx(ALICE);
    {
        let mut manager = scenario.take_shared<PredictManager>();
        manager.increase_position(locked_key, 5 * FLOAT);

        predict.mint_collateralized(
            &mut manager,
            &oracle,
            locked_key,
            minted_key,
            5 * FLOAT,
            &clock,
            scenario.ctx(),
        );

        // Now redeem the collateralized position
        predict.redeem_collateralized(
            &mut manager,
            locked_key,
            minted_key,
            5 * FLOAT,
            scenario.ctx(),
        );

        // Locked position released back to free
        let (free, locked) = manager.position(locked_key);
        assert_eq!(free, 5 * FLOAT);
        assert_eq!(locked, 0);

        // Minted position gone
        let (free_m, _) = manager.position(minted_key);
        assert_eq!(free_m, 0);

        test_scenario::return_shared(manager);
    };

    destroy(predict);
    destroy(oracle);
    destroy(clock);
    scenario.end();
}

// ============================================================
// Abort cases
// ============================================================

#[test, expected_failure(abort_code = predict::EInvalidCollateralPair)]
fun collateralized_mint_up_wrong_direction_aborts() {
    // UP collateral with higher strike than minted — invalid
    let mut scenario = setup_with_manager(100 * FLOAT);
    let mut predict = create_predict(scenario.ctx());

    let oracle = create_live_oracle(scenario.ctx());
    let clock = clock::create_for_testing(scenario.ctx());
    let oracle_id = oracle::id(&oracle);

    // locked strike (120) > minted strike (80) — wrong for UP
    let locked_key = market_key::up(oracle_id, oracle.expiry(), 120 * FLOAT);
    let minted_key = market_key::up(oracle_id, oracle.expiry(), 80 * FLOAT);

    scenario.next_tx(ALICE);
    {
        let mut manager = scenario.take_shared<PredictManager>();
        manager.increase_position(locked_key, 5 * FLOAT);

        predict.mint_collateralized(
            &mut manager,
            &oracle,
            locked_key,
            minted_key,
            5 * FLOAT,
            &clock,
            scenario.ctx(),
        );

        abort
    }
}

#[test, expected_failure(abort_code = predict::EInvalidCollateralPair)]
fun collateralized_mint_mixed_directions_aborts() {
    // UP locked with DN minted — invalid
    let mut scenario = setup_with_manager(100 * FLOAT);
    let mut predict = create_predict(scenario.ctx());

    let oracle = create_live_oracle(scenario.ctx());
    let clock = clock::create_for_testing(scenario.ctx());
    let oracle_id = oracle::id(&oracle);

    let locked_key = market_key::up(oracle_id, oracle.expiry(), 80 * FLOAT);
    let minted_key = market_key::down(oracle_id, oracle.expiry(), 120 * FLOAT);

    scenario.next_tx(ALICE);
    {
        let mut manager = scenario.take_shared<PredictManager>();
        manager.increase_position(locked_key, 5 * FLOAT);

        predict.mint_collateralized(
            &mut manager,
            &oracle,
            locked_key,
            minted_key,
            5 * FLOAT,
            &clock,
            scenario.ctx(),
        );

        abort
    }
}

#[test, expected_failure(abort_code = predict::ETradingPaused)]
fun mint_collateralized_when_paused_aborts() {
    let mut scenario = setup_with_manager(100 * FLOAT);
    let mut predict = create_predict(scenario.ctx());

    predict.set_trading_paused(true);

    let oracle = create_live_oracle(scenario.ctx());
    let clock = clock::create_for_testing(scenario.ctx());
    let oracle_id = oracle::id(&oracle);

    let locked_key = market_key::up(oracle_id, oracle.expiry(), 80 * FLOAT);
    let minted_key = market_key::up(oracle_id, oracle.expiry(), 120 * FLOAT);

    scenario.next_tx(ALICE);
    {
        let mut manager = scenario.take_shared<PredictManager>();
        manager.increase_position(locked_key, 5 * FLOAT);

        predict.mint_collateralized(
            &mut manager,
            &oracle,
            locked_key,
            minted_key,
            5 * FLOAT,
            &clock,
            scenario.ctx(),
        );

        abort
    }
}

// Note: withdraw_all with settled oracle positions always succeeds because
// settled mtm == max_payout, so available == vault_value. To test
// EWithdrawExceedsAvailable on withdraw_all, we'd need live oracle positions
// where max_payout > mtm. The withdraw() test above covers this abort path.

#[test, expected_failure(abort_code = predict::EOracleSettled)]
fun mint_against_settled_oracle_aborts() {
    let mut scenario = setup_with_manager(100 * FLOAT);
    let mut predict = create_predict(scenario.ctx());

    let liq = coin::mint_for_testing<SUI>(1000 * FLOAT, scenario.ctx());
    predict.supply(liq, scenario.ctx());

    let mut oracle = create_live_oracle(scenario.ctx());
    let clock = clock::create_for_testing(scenario.ctx());
    let oracle_id = oracle::id(&oracle);
    let key = market_key::up(oracle_id, oracle.expiry(), 50 * FLOAT);

    // Settle the oracle before minting
    oracle::settle_test_oracle(&mut oracle, 200 * FLOAT);

    scenario.next_tx(ALICE);
    {
        let mut manager = scenario.take_shared<PredictManager>();
        predict.mint(&mut manager, &oracle, key, 10 * FLOAT, &clock, scenario.ctx());

        abort
    }
}

#[test, expected_failure(abort_code = predict::EInvalidCollateralPair)]
fun collateralized_mint_equal_strikes_aborts() {
    let mut scenario = setup_with_manager(100 * FLOAT);
    let mut predict = create_predict(scenario.ctx());

    let oracle = create_live_oracle(scenario.ctx());
    let clock = clock::create_for_testing(scenario.ctx());
    let oracle_id = oracle::id(&oracle);

    // Same strike for both locked and minted — should be rejected
    let locked_key = market_key::up(oracle_id, oracle.expiry(), 100 * FLOAT);
    let minted_key = market_key::up(oracle_id, oracle.expiry(), 100 * FLOAT);

    scenario.next_tx(ALICE);
    {
        let mut manager = scenario.take_shared<PredictManager>();
        manager.increase_position(locked_key, 5 * FLOAT);

        predict.mint_collateralized(
            &mut manager,
            &oracle,
            locked_key,
            minted_key,
            5 * FLOAT,
            &clock,
            scenario.ctx(),
        );

        abort
    }
}
