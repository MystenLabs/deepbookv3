// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// P0-7 liquidation threshold boundary at the flow level, with a genuinely
/// non-flat floor schedule made bit-exact by construction: the expiry sits
/// exactly half the leverage floor window out (floor phase 0.5 at mint, 0.6 at
/// the check time), so every floor-index intermediate is exact under any
/// round-down composition. Pins both sides of the threshold (a clearly-solvent
/// order is left untouched and stays closable at its spec value; a worthless
/// order liquidates), that a failed attempt and a budget-0 budgeted pass are
/// pure no-ops, and the zero-pay liquidated-position cleanup. The exact boundary unit is
/// implementation-defined (the price→probability map is a step function under
/// the degenerate test SVI), so the two sides use a safe gap: p = 0.5 exactly
/// (gross 420e6 ≫ threshold 252_235_294) vs p = 0 (gross 0).
#[test_only]
module deepbook_predict::liquidation_boundary_tests;

use deepbook_predict::{
    config_constants,
    constants,
    flow_test_helpers as helpers,
    order,
    test_constants
};
use dusdc::dusdc::DUSDC;
use fixed_math::math;
use std::unit_test::assert_eq;

/// now (120_000) + leverage_floor_window_ms / 2: floor phase at mint is
/// exactly 0.5, so floor_index(open) = 1 + 0.2 * 0.5² = 1.05 exactly.
/// Grid-aligned (`now` + a multiple of the resolution period).
const EXPIRY_MS: u64 = 15_768_120_000;
/// Check time T1 = EXPIRY_MS − 0.4 * window: floor phase exactly 0.6, so
/// floor_index(T1) = 1 + 0.2 * 0.6² = 1.072 exactly — the schedule is
/// genuinely live between mint and check (1.05 → 1.072).
const T1_MS: u64 = 3_153_720_000;
/// Oracle re-seed source timestamps: strictly after the setup's 119_000 seed
/// and within every freshness window of the T1 clock.
const T1_ATM_SOURCE_TS: u64 = 3_153_719_500;
const T1_DROP_SOURCE_TS: u64 = 3_153_719_700;
const LEVERAGE_TWO_X: u64 = 2_000_000_000;
/// 84_000 lots, chosen so floor_shares = financed_amount / 1.05 = 200_000_000 is an
/// EXACT division (no dependence on the floor_shares rounding direction).
const QUANTITY: u64 = 840_000_000;
/// The 2x net premium, the floor it implies, and the live order value are all
/// read from the quote, the packed order and the public value reader rather than
/// written down: each follows the digital, which `pricing_exact_tests` owns.
/// Per-unit fee RATE floors at min_fee = 5e6 (fixture base_fee = 1):
/// trade fee = floor(5e6 * 840e6 / 1e9) per mint/redeem of this quantity.
const TRADE_FEE: u64 = 4_200_000;

/// floor(cumulative fees * 0.5 default rebate rate): 2 mints, then + redeem.
const REBATE_AFTER_MINTS: u64 = 4_200_000;
const REBATE_AFTER_REDEEM: u64 = 6_300_000;

/// One grid tick below the orders' lower strike: the digital steps to p = 0,
/// gross = 0 <= threshold floor(214_400_000 * 1e9 / 0.85e9) = 252_235_294.
const DROPPED_SPOT: u64 = 99_000_000_000;

#[test]
fun liquidation_fires_only_below_threshold_and_is_otherwise_a_noop() {
    let (mut fx, expiry_id, trader) = helpers::setup_live_market(
        EXPIRY_MS,
        test_constants::default_live_price(),
    );
    fx.scenario_mut().next_tx(test_constants::alice());
    let mut market = fx.take_market_bundle(expiry_id);
    let mut account = fx.take_account_bundle(&trader);

    // --- Baseline.
    let seeded_cash = test_constants::default_seeded_expiry_cash();
    helpers::check_market_cash_bundle(&market, helpers::expected_market_cash(seeded_cash, 0, 0));
    fx.check_manager_bundle(
        &account,
        expiry_id,
        helpers::expected_manager_state(test_constants::mint_deposit(), 0, 0, 0, 0),
    );

    // --- Two identical 2x semi-infinite orders.
    let quote = fx.quote_mint_bundle(
        &market,
        helpers::strike_tick(),
        constants::pos_inf_tick!(),
        QUANTITY,
        LEVERAGE_TWO_X,
    );
    helpers::assert_atm_entry_probability(quote.entry_probability());
    let contribution = quote.net_premium();
    let order_a = fx.mint_bundle(
        &mut market,
        &mut account,
        helpers::strike_tick(),
        constants::pos_inf_tick!(),
        QUANTITY,
        LEVERAGE_TWO_X,
    );
    let order_b = fx.mint_bundle(
        &mut market,
        &mut account,
        helpers::strike_tick(),
        constants::pos_inf_tick!(),
        QUANTITY,
        LEVERAGE_TWO_X,
    );
    // floor_at_open = financed_amount * the open floor index; live backing per
    // order is the quantity above that floor.
    let live_backing_per_order = QUANTITY - order::from_order_id(order_a).floor_shares();
    let post_mint_balance = test_constants::mint_deposit() - 2 * (contribution + TRADE_FEE);
    let cash_after_mints = seeded_cash + 2 * (contribution + TRADE_FEE);
    helpers::check_market_cash_bundle(
        &market,
        helpers::expected_market_cash(
            cash_after_mints,
            2 * live_backing_per_order,
            REBATE_AFTER_MINTS,
        ),
    );
    fx.check_manager_bundle(
        &account,
        expiry_id,
        helpers::expected_manager_state(post_mint_balance, 2 * TRADE_FEE, 2, 0, 0),
    );

    // --- Advance to T1 and re-seed the oracle at the same ATM price. Both
    // orders are clearly solvent (gross 420e6 > threshold 252_235_294): a
    // failed liquidation attempt must be a pure no-op.
    fx.set_clock_for_testing(T1_MS);
    fx.prepare_live_oracle_bundle_at(
        &mut market,
        test_constants::default_live_price(),
        T1_ATM_SOURCE_TS,
    );
    assert!(!fx.liquidate_order_bundle(&mut market, order_a));
    assert!(!fx.liquidate_order_bundle(&mut market, order_b));
    helpers::check_market_cash_bundle(
        &market,
        helpers::expected_market_cash(
            cash_after_mints,
            2 * live_backing_per_order,
            REBATE_AFTER_MINTS,
        ),
    );
    fx.check_manager_bundle(
        &account,
        expiry_id,
        helpers::expected_manager_state(post_mint_balance, 2 * TRADE_FEE, 2, 0, 0),
    );
    assert!(helpers::has_position_bundle(&account, expiry_id, order_a));
    // The public read is gross of close-side fees, and the two identical orders
    // must value identically; the redeem below pays exactly this less the fee.
    let solvent_order_value = fx.order_value_bundle(&market, order_a);
    assert_eq!(fx.order_value_bundle(&market, order_b), solvent_order_value);

    // --- L1 liveness: the not-liquidatable order closes at its spec value
    // (gross minus the LIVE floor at T1, minus the withheld fee).
    let (_closed, replacement) = fx.redeem_bundle(
        &mut market,
        &mut account,
        order_a,
        QUANTITY,
    );
    assert!(replacement.is_none());
    let redeem_net_payout = solvent_order_value - TRADE_FEE;
    let cash_after_redeem = cash_after_mints - redeem_net_payout;
    helpers::check_market_cash_bundle(
        &market,
        helpers::expected_market_cash(
            cash_after_redeem,
            live_backing_per_order,
            REBATE_AFTER_REDEEM,
        ),
    );
    fx.check_manager_bundle(
        &account,
        expiry_id,
        helpers::expected_manager_state(
            post_mint_balance + redeem_net_payout,
            3 * TRADE_FEE,
            1,
            0,
            0,
        ),
    );
    assert!(!helpers::has_position_bundle(&account, expiry_id, order_a));

    // --- Drop the forward one tick below the lower strike (pyth-only update;
    // basis stays 1.0). order_b is now liquidatable, but a budget-0 budgeted
    // pass selects zero candidates and must change nothing.
    fx.set_pyth_price_for_testing_bundle(&mut market, DROPPED_SPOT, T1_DROP_SOURCE_TS);
    assert_eq!(fx.liquidate_bundle(&mut market, 0), 0);
    helpers::check_market_cash_bundle(
        &market,
        helpers::expected_market_cash(
            cash_after_redeem,
            live_backing_per_order,
            REBATE_AFTER_REDEEM,
        ),
    );
    fx.check_manager_bundle(
        &account,
        expiry_id,
        helpers::expected_manager_state(
            post_mint_balance + redeem_net_payout,
            3 * TRADE_FEE,
            1,
            0,
            0,
        ),
    );
    assert_eq!(fx.order_value_bundle(&market, order_b), 0);

    // --- Targeted liquidation below the threshold: the knockout removes the
    // order's full backing, moves no cash, and never touches the manager.
    assert!(fx.liquidate_order_bundle(&mut market, order_b));
    helpers::check_market_cash_bundle(
        &market,
        helpers::expected_market_cash(cash_after_redeem, 0, REBATE_AFTER_REDEEM),
    );
    fx.check_manager_bundle(
        &account,
        expiry_id,
        helpers::expected_manager_state(
            post_mint_balance + redeem_net_payout,
            3 * TRADE_FEE,
            1,
            0,
            0,
        ),
    );
    assert_eq!(fx.order_value_bundle(&market, order_b), 0);
    assert!(helpers::has_position_bundle(&account, expiry_id, order_b));

    // --- Liquidated-position cleanup: zero payout, zero fee, position cleared.
    let (_closed_b, repl_b) = fx.redeem_bundle(
        &mut market,
        &mut account,
        order_b,
        QUANTITY,
    );
    assert!(repl_b.is_none());
    fx.check_manager_bundle(
        &account,
        expiry_id,
        helpers::expected_manager_state(
            post_mint_balance + redeem_net_payout,
            3 * TRADE_FEE,
            0,
            0,
            0,
        ),
    );
    helpers::check_market_cash_bundle(
        &market,
        helpers::expected_market_cash(cash_after_redeem, 0, REBATE_AFTER_REDEEM),
    );
    assert!(!helpers::has_position_bundle(&account, expiry_id, order_b));

    helpers::return_account_bundle(account);
    helpers::return_market_bundle(market);
    fx.finish();
}

#[test]
fun redeem_live_target_liquidates_order_missed_by_budgeted_sweep() {
    let (mut fx, expiry_id, trader) = helpers::setup_everything();
    fx.scenario_mut().next_tx(test_constants::alice());
    let mut market = fx.take_market_bundle(expiry_id);
    let mut account = fx.take_account_bundle(&trader);

    let budget = config_constants::default_trade_liquidation_budget!();
    // The mint costs below are measured, but the price behind them still has to
    // be right, so both sides are pinned against the independent reference.
    helpers::assert_atm_complement_entry_probability(fx
        .quote_mint_bundle(
            &market,
            constants::neg_inf!(),
            helpers::strike_tick(),
            QUANTITY,
            LEVERAGE_TWO_X,
        )
        .entry_probability());
    helpers::assert_atm_entry_probability(fx
        .quote_mint_bundle(
            &market,
            helpers::strike_tick(),
            constants::pos_inf_tick!(),
            QUANTITY,
            LEVERAGE_TWO_X,
        )
        .entry_probability());
    let first_filler = fx.mint_bundle(
        &mut market,
        &mut account,
        constants::neg_inf!(),
        helpers::strike_tick(),
        QUANTITY,
        LEVERAGE_TWO_X,
    );
    let mut i = 1;
    while (i < budget) {
        fx.mint_bundle(
            &mut market,
            &mut account,
            constants::neg_inf!(),
            helpers::strike_tick(),
            QUANTITY,
            LEVERAGE_TWO_X,
        );
        i = i + 1;
    };
    let target_order = fx.mint_bundle(
        &mut market,
        &mut account,
        helpers::strike_tick(),
        constants::pos_inf_tick!(),
        QUANTITY,
        LEVERAGE_TWO_X,
    );
    // The fillers price the DOWN complement and the target prices the UP range,
    // so their premiums — and therefore the floors they finance — are two
    // different numbers; each side's backing is read off its own packed order.
    let live_backing_per_order = QUANTITY - order::from_order_id(first_filler).floor_shares();
    let target_live_backing = QUANTITY - order::from_order_id(target_order).floor_shares();
    let mint_count = budget + 1;
    let total_fees = mint_count * TRADE_FEE;
    // What the manager paid is measured, not derived: the fillers price the DOWN
    // complement and the target prices the UP range, so their premiums are two
    // different numbers that this file has no business restating. The market-cash
    // assertion below then reads as conservation — every unit the manager paid
    // landed in expiry cash.
    let balance_after_mints = fx.account_balance_bundle<DUSDC>(&account);
    let total_mint_cost = test_constants::default_manager_deposit() - balance_after_mints;
    let cash_after_mints = test_constants::default_seeded_expiry_cash() + total_mint_cost;
    let rebate_after_mints = math::mul_down(
        total_fees,
        config_constants::default_trading_loss_rebate_rate!(),
    );
    let target_disjoint_buffer = math::mul_down(
        target_live_backing,
        config_constants::default_backing_buffer_lambda!(),
    );
    helpers::check_market_cash_bundle(
        &market,
        helpers::expected_market_cash(
            cash_after_mints,
            budget * live_backing_per_order + target_disjoint_buffer,
            rebate_after_mints,
        ),
    );
    fx.check_manager_bundle(
        &account,
        expiry_id,
        helpers::expected_manager_state(
            balance_after_mints,
            total_fees,
            mint_count,
            0,
            0,
        ),
    );

    fx.set_clock_for_testing(T1_MS);
    fx.prepare_live_oracle_bundle_at(&mut market, DROPPED_SPOT, T1_DROP_SOURCE_TS);
    assert_eq!(fx.order_value_bundle(&market, first_filler), live_backing_per_order);
    assert_eq!(fx.order_value_bundle(&market, target_order), 0);

    let balance_before = fx.account_balance_bundle<DUSDC>(&account);
    let (closed_id, replacement) = fx.redeem_bundle(
        &mut market,
        &mut account,
        target_order,
        QUANTITY,
    );

    assert_eq!(closed_id, target_order);
    assert!(replacement.is_none());
    assert_eq!(fx.account_balance_bundle<DUSDC>(&account), balance_before);
    assert!(helpers::has_position_bundle(&account, expiry_id, first_filler));
    assert!(!helpers::has_position_bundle(&account, expiry_id, target_order));
    helpers::check_market_cash_bundle(
        &market,
        helpers::expected_market_cash(
            cash_after_mints,
            budget * live_backing_per_order,
            rebate_after_mints,
        ),
    );
    fx.check_manager_bundle(
        &account,
        expiry_id,
        helpers::expected_manager_state(
            balance_after_mints,
            total_fees,
            budget,
            0,
            0,
        ),
    );
    assert!(!fx.liquidate_order_bundle(&mut market, target_order));

    helpers::return_account_bundle(account);
    helpers::return_market_bundle(market);
    fx.finish();
}
