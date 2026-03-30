// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module deepbook_predict::predict_tests;

use deepbook_predict::{
    constants,
    generated_oracle as go,
    generated_predict as gp,
    market_key,
    oracle::{Self, new_price_data, new_svi_params},
    oracle_helper,
    precision,
    predict::{Self, Predict},
    predict_manager::{Self as predict_manager, PredictManager},
    supply_manager,
    vault
};
use std::unit_test::{assert_eq, destroy};
use sui::{clock, coin, sui::SUI, test_scenario::{Self, Scenario}};

const ALICE: address = @0xA;
const BOB: address = @0xB;

fun create_predict(ctx: &mut TxContext): Predict<SUI> {
    predict::create_test_predict<SUI>(ctx)
}

fun create_live_oracle(ctx: &mut TxContext): oracle::OracleSVI {
    // Flat 25% vol SVI around a 100 strike / 100 forward market.
    let svi = new_svi_params(0, constants::float_scaling!(), 0, false, 0, false, 250_000_000);
    let prices = new_price_data(
        100 * constants::float_scaling!(),
        100 * constants::float_scaling!(),
    );
    oracle::create_test_oracle(
        b"BTC".to_string(),
        svi,
        prices,
        0,
        // Arbitrary far-future expiry for synthetic live-oracle tests.
        1_000_000_000,
        0,
        ctx,
    )
}

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

/// Read cached vault MTM from the test predict object.
fun vault_mtm(predict: &mut Predict<SUI>): u64 {
    vault::total_mtm(predict.vault_mut())
}

/// Read cached max payout from the test predict object.
fun vault_max_payout(predict: &mut Predict<SUI>): u64 {
    vault::total_max_payout(predict.vault_mut())
}

#[test]
/// First LP deposit sees an empty vault, so shares mint 1:1 with assets.
fun supply_first_deposit_one_to_one_shares() {
    let ctx = &mut tx_context::dummy();
    let mut predict = create_predict(ctx);

    let coin = coin::mint_for_testing<SUI>(1_000_000, ctx);
    let shares = predict.supply(coin, ctx);

    assert_eq!(shares, 1_000_000);
    assert_eq!(predict::vault_balance(&predict), 1_000_000);

    destroy(predict);
}

#[test]
/// Second LP deposit into an idle vault should mint proportionally at the same rate.
fun supply_second_deposit_proportional_shares() {
    let ctx = &mut tx_context::dummy();
    let mut predict = create_predict(ctx);

    let coin1 = coin::mint_for_testing<SUI>(1_000_000, ctx);
    predict.supply(coin1, ctx);

    let coin2 = coin::mint_for_testing<SUI>(500_000, ctx);
    let shares2 = predict.supply(coin2, ctx);
    assert_eq!(shares2, 500_000);
    assert_eq!(predict::vault_balance(&predict), 1_500_000);

    destroy(predict);
}

#[test, expected_failure(abort_code = vault::EMtmExceedsBalance)]
/// Public supply currently cannot recapitalize a vault once cached MTM already exceeds balance.
fun supply_aborts_when_vault_is_underwater() {
    let ctx = &mut tx_context::dummy();
    let mut predict = create_predict(ctx);

    let initial_liq = coin::mint_for_testing<SUI>(10 * constants::float_scaling!(), ctx);
    predict.supply(initial_liq, ctx);

    let oracle = oracle_helper::create_settled_oracle(200 * constants::float_scaling!(), ctx);
    let clock = clock::create_for_testing(ctx);

    predict
        .vault_mut()
        .insert_position(
            &oracle,
            true,
            50 * constants::float_scaling!(),
            11 * constants::float_scaling!(),
            &clock,
            ctx,
        );

    let recapitalization = coin::mint_for_testing<SUI>(5 * constants::float_scaling!(), ctx);
    let _shares = predict.supply(recapitalization, ctx);

    abort
}

#[test]
/// Withdrawing from an idle vault should return the exact requested amount.
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
/// Withdrawing all shares from an idle vault should empty the vault balance.
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
/// Settled winning exposure reserves max payout, blocking withdrawals above free capital.
fun withdraw_blocked_by_max_payout() {
    let mut scenario = test_scenario::begin(ALICE);
    let mut predict = create_predict(scenario.ctx());

    let coin = coin::mint_for_testing<SUI>(100 * constants::float_scaling!(), scenario.ctx());
    predict.supply(coin, scenario.ctx());

    let oracle = oracle_helper::create_settled_oracle(
        200 * constants::float_scaling!(),
        scenario.ctx(),
    );
    let clock = clock::create_for_testing(scenario.ctx());
    predict
        .vault_mut()
        .insert_position(
            &oracle,
            true,
            50 * constants::float_scaling!(),
            80 * constants::float_scaling!(),
            &clock,
            scenario.ctx(),
        );

    scenario.next_tx(ALICE);
    let _coin = predict.withdraw(30 * constants::float_scaling!(), scenario.ctx());

    abort
}

#[test]
/// Withdrawing exactly the unencumbered balance should succeed even with reserved payout.
fun withdraw_up_to_available_succeeds() {
    let mut scenario = test_scenario::begin(ALICE);
    let mut predict = create_predict(scenario.ctx());

    let coin = coin::mint_for_testing<SUI>(100 * constants::float_scaling!(), scenario.ctx());
    predict.supply(coin, scenario.ctx());

    let oracle = oracle_helper::create_settled_oracle(
        200 * constants::float_scaling!(),
        scenario.ctx(),
    );
    let clock = clock::create_for_testing(scenario.ctx());
    predict
        .vault_mut()
        .insert_position(
            &oracle,
            true,
            50 * constants::float_scaling!(),
            80 * constants::float_scaling!(),
            &clock,
            scenario.ctx(),
        );

    scenario.next_tx(ALICE);
    let withdrawn = predict.withdraw(20 * constants::float_scaling!(), scenario.ctx());
    assert_eq!(withdrawn.value(), 20 * constants::float_scaling!());

    destroy(withdrawn);
    destroy(predict);
    destroy(oracle);
    destroy(clock);
    scenario.end();
}

#[test, expected_failure(abort_code = predict::EWithdrawExceedsAvailable)]
/// Live exposure also reserves capital via max payout, so withdraw_all can be blocked.
fun withdraw_all_blocked_by_live_max_payout() {
    let mut scenario = test_scenario::begin(ALICE);
    let mut predict = create_predict(scenario.ctx());

    let coin = coin::mint_for_testing<SUI>(100 * constants::float_scaling!(), scenario.ctx());
    predict.supply(coin, scenario.ctx());

    let oracle = create_live_oracle(scenario.ctx());
    let clock = clock::create_for_testing(scenario.ctx());
    predict
        .vault_mut()
        .insert_position(
            &oracle,
            true,
            150 * constants::float_scaling!(),
            80 * constants::float_scaling!(),
            &clock,
            scenario.ctx(),
        );

    scenario.next_tx(ALICE);
    let _coin = predict.withdraw_all(scenario.ctx());

    abort
}

#[test]
/// Minting a live position should move funds from manager to vault and add free exposure.
fun mint_live_oracle_updates_manager_and_vault_state() {
    let mut scenario = setup_with_manager(100 * constants::float_scaling!());
    let mut predict = create_predict(scenario.ctx());

    let liq = coin::mint_for_testing<SUI>(1_000 * constants::float_scaling!(), scenario.ctx());
    predict.supply(liq, scenario.ctx());

    let oracle = create_live_oracle(scenario.ctx());
    let clock = clock::create_for_testing(scenario.ctx());
    let oracle_id = oracle::id(&oracle);
    let key = market_key::up(oracle_id, oracle.expiry(), 100 * constants::float_scaling!());

    scenario.next_tx(ALICE);
    {
        let mut manager = scenario.take_shared<PredictManager>();
        let balance_before = manager.balance<SUI>();
        let vault_balance_before = predict::vault_balance(&predict);

        predict.mint(
            &mut manager,
            &oracle,
            key,
            10 * constants::float_scaling!(),
            &clock,
            scenario.ctx(),
        );

        let balance_after = manager.balance<SUI>();
        let vault_balance_after = predict::vault_balance(&predict);
        let actual_cost = balance_before - balance_after;
        let (free, locked) = manager.position(key);

        // Exact quote parity is covered by the generated scenario tests below; here we assert
        // the state transition invariants for a representative live mint path.
        assert_eq!(vault_balance_after - vault_balance_before, actual_cost);
        assert!(actual_cost > 0);
        assert_eq!(free, 10 * constants::float_scaling!());
        assert_eq!(locked, 0);
        assert_eq!(vault::total_max_payout(predict.vault_mut()), 10 * constants::float_scaling!());
        assert!(vault::total_mtm(predict.vault_mut()) > 0);

        test_scenario::return_shared(manager);
    };

    destroy(predict);
    destroy(oracle);
    destroy(clock);
    scenario.end();
}

#[test, expected_failure(abort_code = market_key::EOracleMismatch)]
/// Public mint should reject a key whose oracle id does not match the provided oracle.
fun mint_aborts_on_wrong_oracle_id() {
    let mut scenario = setup_with_manager(100 * constants::float_scaling!());
    let mut predict = create_predict(scenario.ctx());

    let liq = coin::mint_for_testing<SUI>(1_000 * constants::float_scaling!(), scenario.ctx());
    predict.supply(liq, scenario.ctx());

    let oracle = create_live_oracle(scenario.ctx());
    let clock = clock::create_for_testing(scenario.ctx());
    let wrong_key = market_key::up(
        object::id_from_address(@0x1),
        oracle.expiry(),
        100 * constants::float_scaling!(),
    );

    scenario.next_tx(ALICE);
    {
        let mut manager = scenario.take_shared<PredictManager>();
        predict.mint(
            &mut manager,
            &oracle,
            wrong_key,
            10 * constants::float_scaling!(),
            &clock,
            scenario.ctx(),
        );

        abort
    }
}

#[test, expected_failure(abort_code = market_key::EExpiryMismatch)]
/// Public mint should reject a key whose expiry does not match the provided oracle.
fun mint_aborts_on_wrong_expiry() {
    let mut scenario = setup_with_manager(100 * constants::float_scaling!());
    let mut predict = create_predict(scenario.ctx());

    let liq = coin::mint_for_testing<SUI>(1_000 * constants::float_scaling!(), scenario.ctx());
    predict.supply(liq, scenario.ctx());

    let oracle = create_live_oracle(scenario.ctx());
    let clock = clock::create_for_testing(scenario.ctx());
    let wrong_key = market_key::up(
        oracle::id(&oracle),
        oracle.expiry() + 1,
        100 * constants::float_scaling!(),
    );

    scenario.next_tx(ALICE);
    {
        let mut manager = scenario.take_shared<PredictManager>();
        predict.mint(
            &mut manager,
            &oracle,
            wrong_key,
            10 * constants::float_scaling!(),
            &clock,
            scenario.ctx(),
        );

        abort
    }
}

#[test]
/// Repeated minting on the same market should widen quotes and double payout liability.
fun repeated_mint_same_market_increases_ask_and_doubles_max_payout() {
    let mut scenario = setup_with_manager(100 * constants::float_scaling!());
    let mut predict = create_predict(scenario.ctx());

    let liq = coin::mint_for_testing<SUI>(1_000 * constants::float_scaling!(), scenario.ctx());
    predict.supply(liq, scenario.ctx());

    let oracle = create_live_oracle(scenario.ctx());
    let clock = clock::create_for_testing(scenario.ctx());
    let oracle_id = oracle::id(&oracle);
    let key = market_key::up(
        oracle_id,
        oracle.expiry(),
        100 * constants::float_scaling!(),
    );
    let qty = 10 * constants::float_scaling!();
    let (cost_before, _payout_before) = predict.get_trade_amounts(
        &oracle,
        key,
        qty,
        &clock,
    );

    scenario.next_tx(ALICE);
    {
        let mut manager = scenario.take_shared<PredictManager>();

        predict.mint(&mut manager, &oracle, key, qty, &clock, scenario.ctx());
        let mtm_after_first = vault_mtm(&mut predict);
        let max_payout_after_first = vault_max_payout(&mut predict);
        let (cost_after_first, _payout_after_first) = predict.get_trade_amounts(
            &oracle,
            key,
            qty,
            &clock,
        );

        predict.mint(&mut manager, &oracle, key, qty, &clock, scenario.ctx());
        let mtm_after_second = vault_mtm(&mut predict);
        let max_payout_after_second = vault_max_payout(&mut predict);
        let (free, locked) = manager.position(key);

        assert_eq!(max_payout_after_first, qty);
        assert_eq!(max_payout_after_second, 2 * qty);
        assert!(cost_after_first > cost_before);
        assert!(mtm_after_second > mtm_after_first);
        assert_eq!(free, 2 * qty);
        assert_eq!(locked, 0);

        test_scenario::return_shared(manager);
    };

    destroy(predict);
    destroy(oracle);
    destroy(clock);
    scenario.end();
}

#[test]
/// Partial redeem should reduce remaining liability and improve the next redeem quote.
fun partial_redeem_reduces_liability_and_improves_payout() {
    let mut scenario = setup_with_manager(100 * constants::float_scaling!());
    let mut predict = create_predict(scenario.ctx());

    let liq = coin::mint_for_testing<SUI>(1_000 * constants::float_scaling!(), scenario.ctx());
    predict.supply(liq, scenario.ctx());

    let oracle = create_live_oracle(scenario.ctx());
    let clock = clock::create_for_testing(scenario.ctx());
    let oracle_id = oracle::id(&oracle);
    let key = market_key::up(
        oracle_id,
        oracle.expiry(),
        100 * constants::float_scaling!(),
    );
    let total_qty = 20 * constants::float_scaling!();
    let redeem_qty = 10 * constants::float_scaling!();

    scenario.next_tx(ALICE);
    {
        let mut manager = scenario.take_shared<PredictManager>();
        predict.mint(&mut manager, &oracle, key, total_qty, &clock, scenario.ctx());

        let mtm_before = vault_mtm(&mut predict);
        let max_payout_before = vault_max_payout(&mut predict);
        let (_cost_before, payout_before) = predict.get_trade_amounts(
            &oracle,
            key,
            redeem_qty,
            &clock,
        );
        let balance_before = manager.balance<SUI>();

        predict.redeem(&mut manager, &oracle, key, redeem_qty, &clock, scenario.ctx());

        let balance_after = manager.balance<SUI>();
        let actual_payout = balance_after - balance_before;
        let mtm_after = vault_mtm(&mut predict);
        let max_payout_after = vault_max_payout(&mut predict);
        let (_cost_after, payout_after) = predict.get_trade_amounts(
            &oracle,
            key,
            redeem_qty,
            &clock,
        );
        let (free, locked) = manager.position(key);

        assert_eq!(max_payout_before, total_qty);
        assert_eq!(max_payout_after, redeem_qty);
        assert!(mtm_after < mtm_before);
        assert!(payout_after > payout_before);
        assert!(actual_payout > 0);
        assert_eq!(free, redeem_qty);
        assert_eq!(locked, 0);

        test_scenario::return_shared(manager);
    };

    destroy(predict);
    destroy(oracle);
    destroy(clock);
    scenario.end();
}

#[test, expected_failure(abort_code = market_key::EExpiryMismatch)]
/// Public redeem should reject a key whose expiry no longer matches the provided oracle.
fun redeem_aborts_on_wrong_expiry() {
    let mut scenario = setup_with_manager(100 * constants::float_scaling!());
    let mut predict = create_predict(scenario.ctx());

    let liq = coin::mint_for_testing<SUI>(1_000 * constants::float_scaling!(), scenario.ctx());
    predict.supply(liq, scenario.ctx());

    let oracle = create_live_oracle(scenario.ctx());
    let clock = clock::create_for_testing(scenario.ctx());
    let key = market_key::up(oracle::id(&oracle), oracle.expiry(), 100 * constants::float_scaling!());
    let wrong_key = market_key::up(
        oracle::id(&oracle),
        oracle.expiry() + 1,
        100 * constants::float_scaling!(),
    );

    scenario.next_tx(ALICE);
    {
        let mut manager = scenario.take_shared<PredictManager>();
        predict.mint(
            &mut manager,
            &oracle,
            key,
            10 * constants::float_scaling!(),
            &clock,
            scenario.ctx(),
        );
        predict.redeem(
            &mut manager,
            &oracle,
            wrong_key,
            10 * constants::float_scaling!(),
            &clock,
            scenario.ctx(),
        );

        abort
    }
}

#[test, expected_failure(abort_code = vault::EExceedsMaxTotalExposure)]
/// Mint should fail once the vault MTM exceeds the configured total exposure budget.
fun mint_aborts_when_total_exposure_limit_exceeded() {
    let mut scenario = setup_with_manager(100 * constants::float_scaling!());
    let mut predict = create_predict(scenario.ctx());

    let liq = coin::mint_for_testing<SUI>(10 * constants::float_scaling!(), scenario.ctx());
    predict.supply(liq, scenario.ctx());
    predict.set_max_total_exposure_pct(1);

    let oracle = create_live_oracle(scenario.ctx());
    let clock = clock::create_for_testing(scenario.ctx());
    let oracle_id = oracle::id(&oracle);
    let key = market_key::up(oracle_id, oracle.expiry(), 100 * constants::float_scaling!());

    scenario.next_tx(ALICE);
    {
        let mut manager = scenario.take_shared<PredictManager>();
        predict.mint(
            &mut manager,
            &oracle,
            key,
            10 * constants::float_scaling!(),
            &clock,
            scenario.ctx(),
        );

        abort
    }
}

#[test]
/// Buying and immediately selling the same live market should lose spread and clear exposure.
fun round_trip_trade_loses_spread() {
    let mut scenario = setup_with_manager(100 * constants::float_scaling!());
    let mut predict = create_predict(scenario.ctx());

    let lp_deposit = 1_000 * constants::float_scaling!();
    let liq = coin::mint_for_testing<SUI>(lp_deposit, scenario.ctx());
    predict.supply(liq, scenario.ctx());

    let oracle = create_live_oracle(scenario.ctx());
    let clock = clock::create_for_testing(scenario.ctx());
    let oracle_id = oracle::id(&oracle);
    let key = market_key::up(
        oracle_id,
        oracle.expiry(),
        100 * constants::float_scaling!(),
    );
    let qty = 10 * constants::float_scaling!();

    scenario.next_tx(ALICE);
    {
        let mut manager = scenario.take_shared<PredictManager>();
        let manager_balance_before = manager.balance<SUI>();
        let vault_balance_before = predict::vault_balance(&predict);

        predict.mint(&mut manager, &oracle, key, qty, &clock, scenario.ctx());
        predict.redeem(&mut manager, &oracle, key, qty, &clock, scenario.ctx());

        let manager_balance_after = manager.balance<SUI>();
        let vault_balance_after = predict::vault_balance(&predict);
        let (free, locked) = manager.position(key);

        assert!(manager_balance_after < manager_balance_before);
        assert!(vault_balance_after > vault_balance_before);
        assert_eq!(free, 0);
        assert_eq!(locked, 0);
        assert_eq!(vault_max_payout(&mut predict), 0);
        assert_eq!(vault_mtm(&mut predict), 0);

        test_scenario::return_shared(manager);
    };

    destroy(predict);
    destroy(oracle);
    destroy(clock);
    scenario.end();
}

#[test]
/// Once an oracle is settled, preview quotes should collapse to the same payout on both sides.
fun get_trade_amounts_settled_has_no_spread() {
    let ctx = &mut tx_context::dummy();
    let mut predict = create_predict(ctx);

    let liq = coin::mint_for_testing<SUI>(1_000 * constants::float_scaling!(), ctx);
    predict.supply(liq, ctx);

    let mut oracle = create_live_oracle(ctx);
    let clock = clock::create_for_testing(ctx);
    let key = market_key::up(oracle::id(&oracle), oracle.expiry(), 50 * constants::float_scaling!());
    let qty = 10 * constants::float_scaling!();

    oracle::settle_test_oracle(&mut oracle, 200 * constants::float_scaling!());

    let (mint_cost, redeem_payout) = predict.get_trade_amounts(&oracle, key, qty, &clock);
    assert_eq!(mint_cost, qty);
    assert_eq!(redeem_payout, qty);

    destroy(predict);
    destroy(oracle);
    destroy(clock);
}

#[test]
/// Removing one leg should leave the other leg active and still impacted by remaining liability.
fun removing_one_leg_keeps_other_leg_exposure_active() {
    let mut scenario = setup_with_manager(100 * constants::float_scaling!());
    let mut predict = create_predict(scenario.ctx());

    let liq = coin::mint_for_testing<SUI>(1_000 * constants::float_scaling!(), scenario.ctx());
    predict.supply(liq, scenario.ctx());

    let oracle = create_live_oracle(scenario.ctx());
    let clock = clock::create_for_testing(scenario.ctx());
    let oracle_id = oracle::id(&oracle);
    let atm_key = market_key::up(
        oracle_id,
        oracle.expiry(),
        100 * constants::float_scaling!(),
    );
    let otm_key = market_key::up(
        oracle_id,
        oracle.expiry(),
        120 * constants::float_scaling!(),
    );
    let atm_qty = 10 * constants::float_scaling!();
    let otm_qty = 5 * constants::float_scaling!();
    let (fresh_otm_cost, _fresh_otm_payout) = predict.get_trade_amounts(
        &oracle,
        otm_key,
        otm_qty,
        &clock,
    );

    scenario.next_tx(ALICE);
    {
        let mut manager = scenario.take_shared<PredictManager>();
        predict.mint(&mut manager, &oracle, atm_key, atm_qty, &clock, scenario.ctx());
        predict.mint(&mut manager, &oracle, otm_key, otm_qty, &clock, scenario.ctx());

        let mtm_with_both = vault_mtm(&mut predict);
        let max_payout_with_both = vault_max_payout(&mut predict);
        let (cost_with_both, _payout_with_both) = predict.get_trade_amounts(
            &oracle,
            otm_key,
            otm_qty,
            &clock,
        );
        predict.redeem(&mut manager, &oracle, atm_key, atm_qty, &clock, scenario.ctx());
        let mtm_after_remove_atm = vault_mtm(&mut predict);
        let (cost_after_remove_atm, _payout_after_remove_atm) = predict.get_trade_amounts(
            &oracle,
            otm_key,
            otm_qty,
            &clock,
        );
        let (otm_free, otm_locked) = manager.position(otm_key);

        assert!(cost_with_both > fresh_otm_cost);
        assert!(cost_after_remove_atm < cost_with_both);
        assert!(cost_after_remove_atm > fresh_otm_cost);
        assert_eq!(max_payout_with_both, atm_qty + otm_qty);
        assert_eq!(otm_free, otm_qty);
        assert_eq!(otm_locked, 0);
        assert_eq!(vault_max_payout(&mut predict), otm_qty);
        assert!(mtm_after_remove_atm < mtm_with_both);
        assert!(vault_mtm(&mut predict) > 0);

        test_scenario::return_shared(manager);
    };

    destroy(predict);
    destroy(oracle);
    destroy(clock);
    scenario.end();
}

#[test]
/// A settled winning UP position should redeem for the full contract quantity.
fun redeem_settled_up_wins_full_payout() {
    let mut scenario = setup_with_manager(100 * constants::float_scaling!());
    let mut predict = create_predict(scenario.ctx());

    let liq = coin::mint_for_testing<SUI>(1000 * constants::float_scaling!(), scenario.ctx());
    predict.supply(liq, scenario.ctx());

    let mut oracle = create_live_oracle(scenario.ctx());
    let clock = clock::create_for_testing(scenario.ctx());
    let oracle_id = oracle::id(&oracle);
    let key = market_key::up(oracle_id, oracle.expiry(), 50 * constants::float_scaling!());

    scenario.next_tx(ALICE);
    {
        let mut manager = scenario.take_shared<PredictManager>();
        manager.increase_position(key, 10 * constants::float_scaling!());

        predict
            .vault_mut()
            .insert_position(
                &oracle,
                true,
                50 * constants::float_scaling!(),
                10 * constants::float_scaling!(),
                &clock,
                scenario.ctx(),
            );

        oracle::settle_test_oracle(&mut oracle, 200 * constants::float_scaling!());

        let balance_before = predict::vault_balance(&predict);
        predict.redeem(
            &mut manager,
            &oracle,
            key,
            10 * constants::float_scaling!(),
            &clock,
            scenario.ctx(),
        );
        let balance_after = predict::vault_balance(&predict);

        assert_eq!(balance_before - balance_after, 10 * constants::float_scaling!());
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
/// A settled losing UP position should redeem for zero and leave vault balance unchanged.
fun redeem_settled_up_loses_zero_payout() {
    let mut scenario = setup_with_manager(100 * constants::float_scaling!());
    let mut predict = create_predict(scenario.ctx());

    let liq = coin::mint_for_testing<SUI>(1000 * constants::float_scaling!(), scenario.ctx());
    predict.supply(liq, scenario.ctx());

    let mut oracle = create_live_oracle(scenario.ctx());
    let clock = clock::create_for_testing(scenario.ctx());
    let oracle_id = oracle::id(&oracle);
    let key = market_key::up(oracle_id, oracle.expiry(), 150 * constants::float_scaling!());

    scenario.next_tx(ALICE);
    {
        let mut manager = scenario.take_shared<PredictManager>();
        manager.increase_position(key, 10 * constants::float_scaling!());

        predict
            .vault_mut()
            .insert_position(
                &oracle,
                true,
                150 * constants::float_scaling!(),
                10 * constants::float_scaling!(),
                &clock,
                scenario.ctx(),
            );

        oracle::settle_test_oracle(&mut oracle, 50 * constants::float_scaling!());

        let balance_before = predict::vault_balance(&predict);
        predict.redeem(
            &mut manager,
            &oracle,
            key,
            10 * constants::float_scaling!(),
            &clock,
            scenario.ctx(),
        );
        let balance_after = predict::vault_balance(&predict);

        assert_eq!(balance_before, balance_after);

        test_scenario::return_shared(manager);
    };

    destroy(predict);
    destroy(oracle);
    destroy(clock);
    scenario.end();
}

#[test]
/// Once the oracle is settled, redeem should succeed even if the last live update is stale.
fun redeem_settled_oracle_ignores_staleness() {
    let mut scenario = setup_with_manager(100 * constants::float_scaling!());
    let mut predict = create_predict(scenario.ctx());

    let liq = coin::mint_for_testing<SUI>(1_000 * constants::float_scaling!(), scenario.ctx());
    predict.supply(liq, scenario.ctx());

    let mut oracle = create_live_oracle(scenario.ctx());
    let mut clock = clock::create_for_testing(scenario.ctx());
    let oracle_id = oracle::id(&oracle);
    let key = market_key::up(oracle_id, oracle.expiry(), 50 * constants::float_scaling!());
    let qty = 10 * constants::float_scaling!();

    scenario.next_tx(ALICE);
    {
        let mut manager = scenario.take_shared<PredictManager>();
        predict.mint(&mut manager, &oracle, key, qty, &clock, scenario.ctx());
        test_scenario::return_shared(manager);
    };

    oracle::settle_test_oracle(&mut oracle, 200 * constants::float_scaling!());
    clock.set_for_testing(constants::staleness_threshold_ms!() + 1);

    scenario.next_tx(ALICE);
    {
        let mut manager = scenario.take_shared<PredictManager>();
        let balance_before = manager.balance<SUI>();
        predict.redeem(&mut manager, &oracle, key, qty, &clock, scenario.ctx());
        let balance_after = manager.balance<SUI>();

        assert_eq!(balance_after - balance_before, qty);
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

#[test, expected_failure(abort_code = predict::ETradingPaused)]
/// Trading pause should block minting even with healthy manager/vault state.
fun mint_when_paused_aborts() {
    let mut scenario = setup_with_manager(100 * constants::float_scaling!());
    let mut predict = create_predict(scenario.ctx());

    let liq = coin::mint_for_testing<SUI>(1_000 * constants::float_scaling!(), scenario.ctx());
    predict.supply(liq, scenario.ctx());
    predict.set_trading_paused(true);

    let oracle = create_live_oracle(scenario.ctx());
    let clock = clock::create_for_testing(scenario.ctx());
    let oracle_id = oracle::id(&oracle);
    let key = market_key::up(oracle_id, oracle.expiry(), 100 * constants::float_scaling!());

    scenario.next_tx(ALICE);
    {
        let mut manager = scenario.take_shared<PredictManager>();
        predict.mint(
            &mut manager,
            &oracle,
            key,
            10 * constants::float_scaling!(),
            &clock,
            scenario.ctx(),
        );

        abort
    }
}

#[test, expected_failure(abort_code = oracle::EOracleStale)]
/// Mint should reject live quotes once the oracle timestamp is beyond staleness threshold.
fun mint_against_stale_oracle_aborts() {
    let mut scenario = setup_with_manager(100 * constants::float_scaling!());
    let mut predict = create_predict(scenario.ctx());

    let liq = coin::mint_for_testing<SUI>(1_000 * constants::float_scaling!(), scenario.ctx());
    predict.supply(liq, scenario.ctx());

    let (oracle, mut clock) = oracle_helper::create_simple_oracle(
        100 * constants::float_scaling!(),
        100 * constants::float_scaling!(),
        100_000,
        0,
        scenario.ctx(),
    );
    clock.set_for_testing(constants::staleness_threshold_ms!() + 1);
    let oracle_id = oracle::id(&oracle);
    let key = market_key::up(oracle_id, oracle.expiry(), 100 * constants::float_scaling!());

    scenario.next_tx(ALICE);
    {
        let mut manager = scenario.take_shared<PredictManager>();
        predict.mint(
            &mut manager,
            &oracle,
            key,
            10 * constants::float_scaling!(),
            &clock,
            scenario.ctx(),
        );

        abort
    }
}

#[test, expected_failure(abort_code = predict::ENotOwner)]
/// Only the manager owner can mint against a Predict manager.
fun mint_aborts_if_not_owner() {
    let mut scenario = setup_with_manager(100 * constants::float_scaling!());
    let mut predict = create_predict(scenario.ctx());

    let liq = coin::mint_for_testing<SUI>(1_000 * constants::float_scaling!(), scenario.ctx());
    predict.supply(liq, scenario.ctx());

    let oracle = create_live_oracle(scenario.ctx());
    let clock = clock::create_for_testing(scenario.ctx());
    let oracle_id = oracle::id(&oracle);
    let key = market_key::up(oracle_id, oracle.expiry(), 100 * constants::float_scaling!());

    scenario.next_tx(BOB);
    {
        let mut manager = scenario.take_shared<PredictManager>();
        predict.mint(
            &mut manager,
            &oracle,
            key,
            10 * constants::float_scaling!(),
            &clock,
            scenario.ctx(),
        );

        abort
    }
}

#[test, expected_failure(abort_code = oracle::EOracleStale)]
/// Redeem should enforce staleness checks for live oracles until settlement occurs.
fun redeem_against_stale_live_oracle_aborts() {
    let mut scenario = setup_with_manager(100 * constants::float_scaling!());
    let mut predict = create_predict(scenario.ctx());

    let liq = coin::mint_for_testing<SUI>(1_000 * constants::float_scaling!(), scenario.ctx());
    predict.supply(liq, scenario.ctx());

    let oracle = create_live_oracle(scenario.ctx());
    let mut clock = clock::create_for_testing(scenario.ctx());
    let oracle_id = oracle::id(&oracle);
    let key = market_key::up(oracle_id, oracle.expiry(), 100 * constants::float_scaling!());

    scenario.next_tx(ALICE);
    {
        let mut manager = scenario.take_shared<PredictManager>();
        predict.mint(
            &mut manager,
            &oracle,
            key,
            10 * constants::float_scaling!(),
            &clock,
            scenario.ctx(),
        );
        test_scenario::return_shared(manager);
    };

    clock.set_for_testing(constants::staleness_threshold_ms!() + 1);
    scenario.next_tx(ALICE);
    {
        let mut manager = scenario.take_shared<PredictManager>();
        predict.redeem(
            &mut manager,
            &oracle,
            key,
            10 * constants::float_scaling!(),
            &clock,
            scenario.ctx(),
        );

        abort
    }
}

#[test, expected_failure(abort_code = predict::ENotOwner)]
/// Only the manager owner can redeem a live position.
fun redeem_aborts_if_not_owner() {
    let mut scenario = setup_with_manager(100 * constants::float_scaling!());
    let mut predict = create_predict(scenario.ctx());

    let liq = coin::mint_for_testing<SUI>(1_000 * constants::float_scaling!(), scenario.ctx());
    predict.supply(liq, scenario.ctx());

    let oracle = create_live_oracle(scenario.ctx());
    let clock = clock::create_for_testing(scenario.ctx());
    let oracle_id = oracle::id(&oracle);
    let key = market_key::up(oracle_id, oracle.expiry(), 100 * constants::float_scaling!());

    scenario.next_tx(ALICE);
    {
        let mut manager = scenario.take_shared<PredictManager>();
        predict.mint(
            &mut manager,
            &oracle,
            key,
            10 * constants::float_scaling!(),
            &clock,
            scenario.ctx(),
        );
        test_scenario::return_shared(manager);
    };

    scenario.next_tx(BOB);
    {
        let mut manager = scenario.take_shared<PredictManager>();
        predict.redeem(
            &mut manager,
            &oracle,
            key,
            10 * constants::float_scaling!(),
            &clock,
            scenario.ctx(),
        );

        abort
    }
}

#[test]
/// UP collateral can only mint a higher-strike UP leg from the same oracle/expiry.
fun collateralized_mint_up_lower_to_higher_strike() {
    let mut scenario = setup_with_manager(100 * constants::float_scaling!());
    let mut predict = create_predict(scenario.ctx());

    let oracle = create_live_oracle(scenario.ctx());
    let clock = clock::create_for_testing(scenario.ctx());
    let oracle_id = oracle::id(&oracle);

    let locked_key = market_key::up(oracle_id, oracle.expiry(), 80 * constants::float_scaling!());
    let minted_key = market_key::up(oracle_id, oracle.expiry(), 120 * constants::float_scaling!());

    scenario.next_tx(ALICE);
    {
        let mut manager = scenario.take_shared<PredictManager>();
        manager.increase_position(locked_key, 5 * constants::float_scaling!());

        predict.mint_collateralized(
            &mut manager,
            &oracle,
            locked_key,
            minted_key,
            5 * constants::float_scaling!(),
            &clock,
            scenario.ctx(),
        );

        let (free, locked) = manager.position(locked_key);
        assert_eq!(free, 0);
        assert_eq!(locked, 5 * constants::float_scaling!());

        let (free_m, locked_m) = manager.position(minted_key);
        assert_eq!(free_m, 5 * constants::float_scaling!());
        assert_eq!(locked_m, 0);

        test_scenario::return_shared(manager);
    };

    destroy(predict);
    destroy(oracle);
    destroy(clock);
    scenario.end();
}

#[test]
/// DOWN collateral can only mint a lower-strike DOWN leg from the same oracle/expiry.
fun collateralized_mint_dn_higher_to_lower_strike() {
    let mut scenario = setup_with_manager(100 * constants::float_scaling!());
    let mut predict = create_predict(scenario.ctx());

    let oracle = create_live_oracle(scenario.ctx());
    let clock = clock::create_for_testing(scenario.ctx());
    let oracle_id = oracle::id(&oracle);

    let locked_key = market_key::down(
        oracle_id,
        oracle.expiry(),
        120 * constants::float_scaling!(),
    );
    let minted_key = market_key::down(oracle_id, oracle.expiry(), 80 * constants::float_scaling!());

    scenario.next_tx(ALICE);
    {
        let mut manager = scenario.take_shared<PredictManager>();
        manager.increase_position(locked_key, 3 * constants::float_scaling!());

        predict.mint_collateralized(
            &mut manager,
            &oracle,
            locked_key,
            minted_key,
            3 * constants::float_scaling!(),
            &clock,
            scenario.ctx(),
        );

        let (free, locked) = manager.position(locked_key);
        assert_eq!(free, 0);
        assert_eq!(locked, 3 * constants::float_scaling!());

        let (free_m, locked_m) = manager.position(minted_key);
        assert_eq!(free_m, 3 * constants::float_scaling!());
        assert_eq!(locked_m, 0);

        test_scenario::return_shared(manager);
    };

    destroy(predict);
    destroy(oracle);
    destroy(clock);
    scenario.end();
}

#[test]
/// Redeeming a collateralized mint should burn the minted leg and release the locked leg.
fun collateralized_redeem_releases_collateral() {
    let mut scenario = setup_with_manager(100 * constants::float_scaling!());
    let mut predict = create_predict(scenario.ctx());

    let oracle = create_live_oracle(scenario.ctx());
    let clock = clock::create_for_testing(scenario.ctx());
    let oracle_id = oracle::id(&oracle);

    let locked_key = market_key::up(oracle_id, oracle.expiry(), 80 * constants::float_scaling!());
    let minted_key = market_key::up(oracle_id, oracle.expiry(), 120 * constants::float_scaling!());

    scenario.next_tx(ALICE);
    {
        let mut manager = scenario.take_shared<PredictManager>();
        manager.increase_position(locked_key, 5 * constants::float_scaling!());

        predict.mint_collateralized(
            &mut manager,
            &oracle,
            locked_key,
            minted_key,
            5 * constants::float_scaling!(),
            &clock,
            scenario.ctx(),
        );

        predict.redeem_collateralized(
            &mut manager,
            locked_key,
            minted_key,
            5 * constants::float_scaling!(),
            scenario.ctx(),
        );

        let (free, locked) = manager.position(locked_key);
        assert_eq!(free, 5 * constants::float_scaling!());
        assert_eq!(locked, 0);

        let (free_m, _) = manager.position(minted_key);
        assert_eq!(free_m, 0);

        test_scenario::return_shared(manager);
    };

    destroy(predict);
    destroy(oracle);
    destroy(clock);
    scenario.end();
}

#[test, expected_failure(abort_code = market_key::EOracleMismatch)]
/// Collateralized mint should reject a locked key whose oracle id does not match the oracle.
fun collateralized_mint_wrong_oracle_id_aborts() {
    let mut scenario = setup_with_manager(100 * constants::float_scaling!());
    let mut predict = create_predict(scenario.ctx());

    let oracle = create_live_oracle(scenario.ctx());
    let clock = clock::create_for_testing(scenario.ctx());
    let minted_key = market_key::up(oracle::id(&oracle), oracle.expiry(), 120 * constants::float_scaling!());
    let wrong_locked_key = market_key::up(
        object::id_from_address(@0x1),
        oracle.expiry(),
        80 * constants::float_scaling!(),
    );

    scenario.next_tx(ALICE);
    {
        let mut manager = scenario.take_shared<PredictManager>();
        manager.increase_position(wrong_locked_key, 5 * constants::float_scaling!());

        predict.mint_collateralized(
            &mut manager,
            &oracle,
            wrong_locked_key,
            minted_key,
            5 * constants::float_scaling!(),
            &clock,
            scenario.ctx(),
        );

        abort
    }
}

#[test, expected_failure(abort_code = predict::ENotOwner)]
/// Only the manager owner can mint a collateralized position.
fun collateralized_mint_not_owner_aborts() {
    let mut scenario = setup_with_manager(100 * constants::float_scaling!());
    let mut predict = create_predict(scenario.ctx());

    let oracle = create_live_oracle(scenario.ctx());
    let clock = clock::create_for_testing(scenario.ctx());
    let oracle_id = oracle::id(&oracle);

    let locked_key = market_key::up(oracle_id, oracle.expiry(), 80 * constants::float_scaling!());
    let minted_key = market_key::up(oracle_id, oracle.expiry(), 120 * constants::float_scaling!());

    scenario.next_tx(ALICE);
    {
        let mut manager = scenario.take_shared<PredictManager>();
        manager.increase_position(locked_key, 5 * constants::float_scaling!());
        test_scenario::return_shared(manager);
    };

    scenario.next_tx(BOB);
    {
        let mut manager = scenario.take_shared<PredictManager>();
        predict.mint_collateralized(
            &mut manager,
            &oracle,
            locked_key,
            minted_key,
            5 * constants::float_scaling!(),
            &clock,
            scenario.ctx(),
        );

        abort
    }
}

#[test, expected_failure(abort_code = supply_manager::EZeroAmount)]
/// Public withdraw should propagate zero-amount rejection from the supply manager.
fun withdraw_zero_amount_aborts_via_predict() {
    let mut scenario = test_scenario::begin(ALICE);
    let mut predict = create_predict(scenario.ctx());

    let coin = coin::mint_for_testing<SUI>(1_000_000, scenario.ctx());
    predict.supply(coin, scenario.ctx());

    scenario.next_tx(ALICE);
    let _withdrawn = predict.withdraw(0, scenario.ctx());

    abort
}

#[test, expected_failure(abort_code = supply_manager::EZeroAmount)]
/// Public withdraw_all should abort when the caller owns no shares.
fun withdraw_all_without_shares_aborts_via_predict() {
    let mut scenario = test_scenario::begin(ALICE);
    let mut predict = create_predict(scenario.ctx());

    let coin = coin::mint_for_testing<SUI>(1_000_000, scenario.ctx());
    predict.supply(coin, scenario.ctx());

    scenario.next_tx(BOB);
    let _withdrawn = predict.withdraw_all(scenario.ctx());

    abort
}

#[test, expected_failure(abort_code = oracle::EOracleStale)]
/// Collateralized mint should reject stale live oracles just like regular mint.
fun collateralized_mint_stale_oracle_aborts() {
    let mut scenario = setup_with_manager(100 * constants::float_scaling!());
    let mut predict = create_predict(scenario.ctx());

    let oracle = create_live_oracle(scenario.ctx());
    let mut clock = clock::create_for_testing(scenario.ctx());
    clock.set_for_testing(constants::staleness_threshold_ms!() + 1);
    let oracle_id = oracle::id(&oracle);

    let locked_key = market_key::up(oracle_id, oracle.expiry(), 80 * constants::float_scaling!());
    let minted_key = market_key::up(oracle_id, oracle.expiry(), 120 * constants::float_scaling!());

    scenario.next_tx(ALICE);
    {
        let mut manager = scenario.take_shared<PredictManager>();
        manager.increase_position(locked_key, 5 * constants::float_scaling!());

        predict.mint_collateralized(
            &mut manager,
            &oracle,
            locked_key,
            minted_key,
            5 * constants::float_scaling!(),
            &clock,
            scenario.ctx(),
        );

        abort
    }
}

#[test, expected_failure(abort_code = predict::EOracleSettled)]
/// Collateralized mint should reject already settled markets just like regular mint.
fun collateralized_mint_settled_oracle_aborts() {
    let mut scenario = setup_with_manager(100 * constants::float_scaling!());
    let mut predict = create_predict(scenario.ctx());

    let mut oracle = create_live_oracle(scenario.ctx());
    let clock = clock::create_for_testing(scenario.ctx());
    let oracle_id = oracle::id(&oracle);

    let locked_key = market_key::up(oracle_id, oracle.expiry(), 80 * constants::float_scaling!());
    let minted_key = market_key::up(oracle_id, oracle.expiry(), 120 * constants::float_scaling!());

    oracle::settle_test_oracle(&mut oracle, 100 * constants::float_scaling!());

    scenario.next_tx(ALICE);
    {
        let mut manager = scenario.take_shared<PredictManager>();
        manager.increase_position(locked_key, 5 * constants::float_scaling!());

        predict.mint_collateralized(
            &mut manager,
            &oracle,
            locked_key,
            minted_key,
            5 * constants::float_scaling!(),
            &clock,
            scenario.ctx(),
        );

        abort
    }
}

#[test, expected_failure(abort_code = predict::ENotOwner)]
/// Only the manager owner can redeem a collateralized position.
fun collateralized_redeem_not_owner_aborts() {
    let mut scenario = setup_with_manager(100 * constants::float_scaling!());
    let mut predict = create_predict(scenario.ctx());

    let oracle = create_live_oracle(scenario.ctx());
    let clock = clock::create_for_testing(scenario.ctx());
    let oracle_id = oracle::id(&oracle);

    let locked_key = market_key::up(oracle_id, oracle.expiry(), 80 * constants::float_scaling!());
    let minted_key = market_key::up(oracle_id, oracle.expiry(), 120 * constants::float_scaling!());

    scenario.next_tx(ALICE);
    {
        let mut manager = scenario.take_shared<PredictManager>();
        manager.increase_position(locked_key, 5 * constants::float_scaling!());
        predict.mint_collateralized(
            &mut manager,
            &oracle,
            locked_key,
            minted_key,
            5 * constants::float_scaling!(),
            &clock,
            scenario.ctx(),
        );
        test_scenario::return_shared(manager);
    };

    scenario.next_tx(BOB);
    {
        let mut manager = scenario.take_shared<PredictManager>();
        predict.redeem_collateralized(
            &mut manager,
            locked_key,
            minted_key,
            5 * constants::float_scaling!(),
            scenario.ctx(),
        );

        abort
    }
}

#[test, expected_failure(abort_code = predict_manager::EInsufficientCollateral)]
/// Redeeming a collateralized leg without a tracked collateral relation should abort.
fun collateralized_redeem_without_collateral_relation_aborts() {
    let mut scenario = setup_with_manager(100 * constants::float_scaling!());
    let mut predict = create_predict(scenario.ctx());

    let oracle = create_live_oracle(scenario.ctx());
    let oracle_id = oracle::id(&oracle);
    let locked_key = market_key::up(oracle_id, oracle.expiry(), 80 * constants::float_scaling!());
    let minted_key = market_key::up(oracle_id, oracle.expiry(), 120 * constants::float_scaling!());

    scenario.next_tx(ALICE);
    {
        let mut manager = scenario.take_shared<PredictManager>();
        manager.increase_position(minted_key, 5 * constants::float_scaling!());

        predict.redeem_collateralized(
            &mut manager,
            locked_key,
            minted_key,
            5 * constants::float_scaling!(),
            scenario.ctx(),
        );

        abort
    }
}

#[test, expected_failure(abort_code = predict::EInvalidCollateralPair)]
/// UP collateral cannot mint a lower-strike UP leg.
fun collateralized_mint_up_wrong_direction_aborts() {
    let mut scenario = setup_with_manager(100 * constants::float_scaling!());
    let mut predict = create_predict(scenario.ctx());

    let oracle = create_live_oracle(scenario.ctx());
    let clock = clock::create_for_testing(scenario.ctx());
    let oracle_id = oracle::id(&oracle);

    let locked_key = market_key::up(oracle_id, oracle.expiry(), 120 * constants::float_scaling!());
    let minted_key = market_key::up(oracle_id, oracle.expiry(), 80 * constants::float_scaling!());

    scenario.next_tx(ALICE);
    {
        let mut manager = scenario.take_shared<PredictManager>();
        manager.increase_position(locked_key, 5 * constants::float_scaling!());

        predict.mint_collateralized(
            &mut manager,
            &oracle,
            locked_key,
            minted_key,
            5 * constants::float_scaling!(),
            &clock,
            scenario.ctx(),
        );

        abort
    }
}

#[test, expected_failure(abort_code = predict::EInvalidCollateralPair)]
/// Collateralization only supports same-direction vertical spreads.
fun collateralized_mint_mixed_directions_aborts() {
    let mut scenario = setup_with_manager(100 * constants::float_scaling!());
    let mut predict = create_predict(scenario.ctx());

    let oracle = create_live_oracle(scenario.ctx());
    let clock = clock::create_for_testing(scenario.ctx());
    let oracle_id = oracle::id(&oracle);

    let locked_key = market_key::up(oracle_id, oracle.expiry(), 80 * constants::float_scaling!());
    let minted_key = market_key::down(
        oracle_id,
        oracle.expiry(),
        120 * constants::float_scaling!(),
    );

    scenario.next_tx(ALICE);
    {
        let mut manager = scenario.take_shared<PredictManager>();
        manager.increase_position(locked_key, 5 * constants::float_scaling!());

        predict.mint_collateralized(
            &mut manager,
            &oracle,
            locked_key,
            minted_key,
            5 * constants::float_scaling!(),
            &clock,
            scenario.ctx(),
        );

        abort
    }
}

#[test, expected_failure(abort_code = predict::ETradingPaused)]
/// Trading pause should also block collateralized mints.
fun mint_collateralized_when_paused_aborts() {
    let mut scenario = setup_with_manager(100 * constants::float_scaling!());
    let mut predict = create_predict(scenario.ctx());

    predict.set_trading_paused(true);

    let oracle = create_live_oracle(scenario.ctx());
    let clock = clock::create_for_testing(scenario.ctx());
    let oracle_id = oracle::id(&oracle);

    let locked_key = market_key::up(oracle_id, oracle.expiry(), 80 * constants::float_scaling!());
    let minted_key = market_key::up(oracle_id, oracle.expiry(), 120 * constants::float_scaling!());

    scenario.next_tx(ALICE);
    {
        let mut manager = scenario.take_shared<PredictManager>();
        manager.increase_position(locked_key, 5 * constants::float_scaling!());

        predict.mint_collateralized(
            &mut manager,
            &oracle,
            locked_key,
            minted_key,
            5 * constants::float_scaling!(),
            &clock,
            scenario.ctx(),
        );

        abort
    }
}

#[test, expected_failure(abort_code = predict::EOracleSettled)]
/// Minting should reject an oracle that has already been force-settled.
fun mint_against_settled_oracle_aborts() {
    let mut scenario = setup_with_manager(100 * constants::float_scaling!());
    let mut predict = create_predict(scenario.ctx());

    let liq = coin::mint_for_testing<SUI>(1000 * constants::float_scaling!(), scenario.ctx());
    predict.supply(liq, scenario.ctx());

    let mut oracle = create_live_oracle(scenario.ctx());
    let clock = clock::create_for_testing(scenario.ctx());
    let oracle_id = oracle::id(&oracle);
    let key = market_key::up(oracle_id, oracle.expiry(), 50 * constants::float_scaling!());

    oracle::settle_test_oracle(&mut oracle, 200 * constants::float_scaling!());

    scenario.next_tx(ALICE);
    {
        let mut manager = scenario.take_shared<PredictManager>();
        predict.mint(
            &mut manager,
            &oracle,
            key,
            10 * constants::float_scaling!(),
            &clock,
            scenario.ctx(),
        );

        abort
    }
}

#[test, expected_failure(abort_code = predict::EInvalidCollateralPair)]
/// Equal strikes do not define a valid collateralized vertical spread.
fun collateralized_mint_equal_strikes_aborts() {
    let mut scenario = setup_with_manager(100 * constants::float_scaling!());
    let mut predict = create_predict(scenario.ctx());

    let oracle = create_live_oracle(scenario.ctx());
    let clock = clock::create_for_testing(scenario.ctx());
    let oracle_id = oracle::id(&oracle);

    let locked_key = market_key::up(oracle_id, oracle.expiry(), 100 * constants::float_scaling!());
    let minted_key = market_key::up(oracle_id, oracle.expiry(), 100 * constants::float_scaling!());

    scenario.next_tx(ALICE);
    {
        let mut manager = scenario.take_shared<PredictManager>();
        manager.increase_position(locked_key, 5 * constants::float_scaling!());

        predict.mint_collateralized(
            &mut manager,
            &oracle,
            locked_key,
            minted_key,
            5 * constants::float_scaling!(),
            &clock,
            scenario.ctx(),
        );

        abort
    }
}

#[test, expected_failure(abort_code = predict::EZeroQuantity)]
/// Zero-quantity mint should be rejected before it can create an empty position entry.
fun mint_zero_quantity_aborts() {
    let mut scenario = setup_with_manager(100 * constants::float_scaling!());
    let mut predict = create_predict(scenario.ctx());

    let oracle = create_live_oracle(scenario.ctx());
    let clock = clock::create_for_testing(scenario.ctx());
    let oracle_id = oracle::id(&oracle);
    let key = market_key::up(oracle_id, oracle.expiry(), 100 * constants::float_scaling!());

    scenario.next_tx(ALICE);
    {
        let mut manager = scenario.take_shared<PredictManager>();
        predict.mint(
            &mut manager,
            &oracle,
            key,
            0,
            &clock,
            scenario.ctx(),
        );

        abort
    }
}

#[test, expected_failure(abort_code = predict::EZeroQuantity)]
/// Zero-quantity redeem should be rejected even when the caller holds a valid position.
fun redeem_zero_quantity_aborts() {
    let mut scenario = setup_with_manager(100 * constants::float_scaling!());
    let mut predict = create_predict(scenario.ctx());
    let liq = coin::mint_for_testing<SUI>(1_000_000 * constants::float_scaling!(), scenario.ctx());
    predict.supply(liq, scenario.ctx());

    let oracle = create_live_oracle(scenario.ctx());
    let clock = clock::create_for_testing(scenario.ctx());
    let oracle_id = oracle::id(&oracle);
    let key = market_key::up(oracle_id, oracle.expiry(), 100 * constants::float_scaling!());

    scenario.next_tx(ALICE);
    {
        let mut manager = scenario.take_shared<PredictManager>();
        predict.mint(
            &mut manager,
            &oracle,
            key,
            5 * constants::float_scaling!(),
            &clock,
            scenario.ctx(),
        );

        predict.redeem(
            &mut manager,
            &oracle,
            key,
            0,
            &clock,
            scenario.ctx(),
        );

        abort
    }
}

#[test, expected_failure(abort_code = predict::EZeroQuantity)]
/// Zero-quantity collateralized mint should be rejected before locking collateral.
fun collateralized_mint_zero_quantity_aborts() {
    let mut scenario = setup_with_manager(100 * constants::float_scaling!());
    let mut predict = create_predict(scenario.ctx());

    let oracle = create_live_oracle(scenario.ctx());
    let clock = clock::create_for_testing(scenario.ctx());
    let oracle_id = oracle::id(&oracle);

    let locked_key = market_key::up(oracle_id, oracle.expiry(), 80 * constants::float_scaling!());
    let minted_key = market_key::up(oracle_id, oracle.expiry(), 120 * constants::float_scaling!());

    scenario.next_tx(ALICE);
    {
        let mut manager = scenario.take_shared<PredictManager>();
        manager.increase_position(locked_key, 5 * constants::float_scaling!());

        predict.mint_collateralized(
            &mut manager,
            &oracle,
            locked_key,
            minted_key,
            0,
            &clock,
            scenario.ctx(),
        );

        abort
    }
}

#[test, expected_failure(abort_code = predict::EZeroQuantity)]
/// Zero-quantity collateralized redeem should be rejected before touching position state.
fun collateralized_redeem_zero_quantity_aborts() {
    let mut scenario = setup_with_manager(100 * constants::float_scaling!());
    let mut predict = create_predict(scenario.ctx());

    let oracle = create_live_oracle(scenario.ctx());
    let clock = clock::create_for_testing(scenario.ctx());
    let oracle_id = oracle::id(&oracle);

    let locked_key = market_key::up(oracle_id, oracle.expiry(), 80 * constants::float_scaling!());
    let minted_key = market_key::up(oracle_id, oracle.expiry(), 120 * constants::float_scaling!());

    scenario.next_tx(ALICE);
    {
        let mut manager = scenario.take_shared<PredictManager>();
        manager.increase_position(locked_key, 5 * constants::float_scaling!());
        predict.mint_collateralized(
            &mut manager,
            &oracle,
            locked_key,
            minted_key,
            5 * constants::float_scaling!(),
            &clock,
            scenario.ctx(),
        );

        predict.redeem_collateralized(
            &mut manager,
            locked_key,
            minted_key,
            0,
            scenario.ctx(),
        );

        abort
    }
}

/// Compare fresh-state preview quotes against generated Python fixtures for selected live snapshots.
fun run_predict_scenario(idx: u64) {
    let scenarios = gp::scenarios();
    let scenario = &scenarios[idx];
    let oracle_scenarios = go::scenarios();
    let oracle_scenario = &oracle_scenarios[scenario.oracle_scenario_idx()];
    let ctx = &mut tx_context::dummy();

    let (oracle, clock) = oracle_helper::create_from_scenario(oracle_scenario, ctx);
    let mut predict = predict::create_test_predict<SUI>(ctx);
    let liq = coin::mint_for_testing<SUI>(1_000_000 * constants::float_scaling!(), ctx);
    predict.supply(liq, ctx);

    // Generated predict fixtures model fresh-state previews with zero utilization.
    scenario.trade_cases().do_ref!(|tc| {
        let oracle_id = oracle::id(&oracle);
        let key = if (tc.is_up()) {
            market_key::up(oracle_id, oracle.expiry(), tc.strike())
        } else {
            market_key::down(oracle_id, oracle.expiry(), tc.strike())
        };
        let (mint_cost, redeem_payout) = predict.get_trade_amounts(
            &oracle,
            key,
            tc.quantity(),
            &clock,
        );
        // Fixtures come from independent Python/Scipy math, while the contract uses fixed-point
        // integer approximations, so we compare through the shared bounded-tolerance helper.
        precision::assert_approx(mint_cost, tc.expected_cost());
        precision::assert_approx(redeem_payout, tc.expected_redeem_payout());
    });

    destroy(predict);
    destroy(oracle);
    destroy(clock);
}

#[test]
/// Real-world snapshot S0: fresh-state quote previews should match generated expectations.
fun predict_scenario_s0() { run_predict_scenario(0); }

#[test]
/// Real-world snapshot S1: fresh-state quote previews should match generated expectations.
fun predict_scenario_s1() { run_predict_scenario(1); }

#[test]
/// Real-world snapshot S3: fresh-state quote previews should match generated expectations.
fun predict_scenario_s3() { run_predict_scenario(2); }

#[test]
/// Real-world snapshot S4: fresh-state quote previews should match generated expectations.
fun predict_scenario_s4() { run_predict_scenario(3); }

#[test]
/// Real-world snapshot S5: fresh-state quote previews should match generated expectations.
fun predict_scenario_s5() { run_predict_scenario(4); }
