// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Regression for C1: a partial close followed by an in-the-money settle must
/// reserve the settled payout exactly, so the marginal settled redeem pays the
/// winner in full and drains the reserve to zero (no `u64` underflow).
///
/// Before the fix, a partial close removed `close_q - mul(remove_fs, T)` from the
/// payout tree, leaving residual `R = remaining_q - mul(old_fs,T) + mul(remove_fs,T)`,
/// while `close_settled_order` recomputes `P = remaining_q - mul(remaining_fs,T)`.
/// Round-down `mul` is sub-additive (`mul(old_fs,T) >= mul(remove_fs,T) + mul(remaining_fs,T)`,
/// gap in {0,1}), so `R <= P` and `settled_payout_liability - payout` underflowed
/// when the gap was 1, stranding the payout. The fix removes the order's full
/// terms and reinserts the survivor's exact terms, so `R == P` by construction.
///
/// The settlement-independent root-cause proof is the +1 floor-share
/// sub-additivity gap for these mint params, plus the live partial-close survivor
/// reinsertion staying solvent. Passive terminal settlement coverage lives in
/// `flows/settlement_flow_tests.move`; exact live-close cash / payout numbers live
/// in `flows/backing_buffer_flow_tests.move`.
#[test_only]
module deepbook_predict::strike_exposure_c1_tests;

use deepbook_predict::{
    constants,
    flow_test_helpers as helpers,
    order,
    strike_exposure_config,
    test_constants
};
use std::unit_test::assert_eq;

/// 2x leverage gives a non-zero floor (required for the gap to exist).
const LEVERAGE_TWO_X: u64 = 2_000_000_000;
/// 6x is admitted at the ATM default range when the template cap is raised to 7x.
const LEVERAGE_SIX_X: u64 = 6_000_000_000;
const ADMISSION_CAP_SEVEN_X: u64 = 7_000_000_000;
/// 5M DUSDC, enough for the 6x max-quantity mint premium plus fee.
const LARGE_TRADER_DEPOSIT: u64 = 5_000_000_000_000;
/// 30M DUSDC, enough to back the large single-order payout liability.
const LARGE_MARKET_CASH: u64 = 30_000_000_000_000;
/// Single close row for survivor reinsertion coverage.
const SINGLE_CLOSE: u64 = 400_000_000;

/// Double close: 300M then 200M of the 700M survivor exercise sequential survivor
/// reinsertion (the second close must remove terms the tree actually holds).
const FIRST_CLOSE: u64 = 300_000_000;
const SECOND_CLOSE: u64 = 200_000_000;

/// A single partial close must leave the survivor backed after reinsertion.
#[test]
fun partial_close_survivor_stays_backed() {
    run_live_close_schedule(vector[SINGLE_CLOSE]);
}

/// Two sequential closes: the survivor is reinserted each time, so the second close
/// removes terms the tree actually holds and the market stays solvent throughout.
#[test]
fun double_partial_close_survivor_reinsertion_stays_backed() {
    run_live_close_schedule(vector[FIRST_CLOSE, SECOND_CLOSE]);
}

// === Near-expiry no-leverage window (end-to-end through the real entrypoints) ===
//
// The config unit tests pass `time_to_expiry_ms` directly, so they cannot prove the
// mint flow derives it from the clock. These drive the real entrypoints against a
// market ~2 minutes from expiry (`short_expiry_ms - now_ms`), well inside the 1h
// window, and so pin the clock threading itself.

/// A 2x mint through `mint_exact_quantity` is refused inside the window.
#[test, expected_failure(abort_code = strike_exposure_config::ELeverageAboveAdmissionCap)]
fun near_expiry_leverage_exact_quantity_mint_rejected() {
    let mut fx = helpers::setup_market_default();
    // Re-enable the block (flow fixtures disable it) BEFORE market creation so the
    // market snapshots the 1h window.
    fx.set_template_no_leverage_window_ms(constants::one_hour_ms!());
    let expiry_id = fx.create_expiry(test_constants::short_expiry_ms());
    let trader = fx.create_funded_manager(test_constants::mint_deposit());
    let mut market = fx.take_market_bundle(expiry_id);
    let mut account = fx.take_account_bundle(&trader);
    fx.prepare_live_oracle_bundle(&mut market, test_constants::default_live_price());
    fx.mint_bundle(
        &mut market,
        &mut account,
        helpers::strike_tick(),
        constants::pos_inf_tick!(),
        test_constants::mint_quantity(),
        LEVERAGE_TWO_X,
    );
    abort 999
}

/// The sizing path reaches the cap through a different interior gate than the
/// exact path — `quote_mint_terms` runs the pre-probe policy assert before its
/// budget search — so it needs its own end-to-end proof: a 2x sized mint inside
/// the window is refused through `mint_exact_amount` too.
#[test, expected_failure(abort_code = strike_exposure_config::ELeverageAboveAdmissionCap)]
fun near_expiry_leverage_exact_amount_mint_rejected() {
    let mut fx = helpers::setup_market_default();
    fx.set_template_no_leverage_window_ms(constants::one_hour_ms!());
    let expiry_id = fx.create_expiry(test_constants::short_expiry_ms());
    let trader = fx.create_funded_manager(test_constants::mint_deposit());
    let mut market = fx.take_market_bundle(expiry_id);
    let mut account = fx.take_account_bundle(&trader);
    fx.prepare_live_oracle_bundle(&mut market, test_constants::default_live_price());
    fx.mint_exact_amount_bundle(
        &mut market,
        &mut account,
        helpers::strike_tick(),
        constants::pos_inf_tick!(),
        test_constants::mint_deposit(),
        constants::position_lot_size!(),
        LEVERAGE_TWO_X,
    );
    abort 999
}

/// The window withholds leverage, it does not halt trading: an unleveraged mint on
/// the same near-expiry market still succeeds end-to-end and opens a real position
/// with a zero floor.
///
/// Needs more market cash than the leveraged tests above: payout backing is
/// `quantity - floor_shares`, and a 1x order's floor is zero, so it backs its full
/// quantity where a 2x order of the same size backs only half.
#[test]
fun near_expiry_one_x_mint_still_succeeds() {
    let mut fx = helpers::setup_market_default();
    fx.set_template_no_leverage_window_ms(constants::one_hour_ms!());
    fx.set_default_cadence_allocation(LARGE_MARKET_CASH, constants::expiry_cash_floor!());
    let expiry_id = fx.create_expiry(test_constants::short_expiry_ms());
    let trader = fx.create_funded_manager(test_constants::mint_deposit());
    let mut market = fx.take_market_bundle(expiry_id);
    let mut account = fx.take_account_bundle(&trader);
    fx.prepare_live_oracle_bundle(&mut market, test_constants::default_live_price());
    fx.seed_market_cash(helpers::market_mut(&mut market), LARGE_MARKET_CASH);

    let order_id = fx.mint_bundle(
        &mut market,
        &mut account,
        helpers::strike_tick(),
        constants::pos_inf_tick!(),
        test_constants::mint_quantity(),
        test_constants::leverage_one_x(),
    );

    // 1x carries no financed amount, so the minted order's static floor is zero.
    let minted = order::from_order_id(order_id);
    assert_eq!(minted.quantity(), test_constants::mint_quantity());
    assert_eq!(minted.floor_shares(), 0);
    assert!(!minted.is_leveraged());
    assert!(helpers::has_position_bundle(&account, expiry_id, order_id));

    helpers::return_account_bundle(account);
    helpers::return_market_bundle(market);
    fx.finish();
}

/// Closing a max-sized 6x ATM order down to one lot must leave a valid replacement.
///
/// The old two-step split left `ceil(floor_shares / 1e9) = 17_896` floor shares on
/// a `10_000`-quantity survivor, so `order::replacement` aborted
/// `EInvalidFloorShares`. The fixed split derives the survivor floor directly:
/// `floor(floor(5 * max_quantity / 12) * position_lot_size / max_quantity)`.
#[test]
fun partial_close_to_last_lot_keeps_survivor_floor_within_quantity() {
    let mut fx = helpers::setup_market_default();
    let max_order_quantity = order::max_quantity_lots() * constants::position_lot_size!();
    // Independently computed (not via the production split formula): with
    // max_order_quantity = (2^32 - 1) * 10_000 = 42_949_672_950_000, the 6x ATM
    // floor is floor(5 * Q / 12) = 17_895_697_062_500, and the one-lot survivor
    // floor is floor(17_895_697_062_500 * 10_000 / Q) = 4_166.
    let expected_last_lot_floor = 4_166;
    fx.set_template_max_admission_leverage(ADMISSION_CAP_SEVEN_X);
    fx.set_default_cadence_allocation(
        LARGE_MARKET_CASH,
        constants::expiry_cash_floor!(),
    );
    let expiry_id = fx.create_expiry(test_constants::default_expiry_ms());
    let trader = fx.create_funded_manager(LARGE_TRADER_DEPOSIT);
    let mut market = fx.take_market_bundle(expiry_id);
    let mut account = fx.take_account_bundle(&trader);

    fx.prepare_live_oracle_bundle(&mut market, test_constants::default_live_price());
    fx.seed_market_cash(helpers::market_mut(&mut market), LARGE_MARKET_CASH);
    let order_id = fx.mint_bundle(
        &mut market,
        &mut account,
        helpers::strike_tick(),
        constants::pos_inf_tick!(),
        max_order_quantity,
        LEVERAGE_SIX_X,
    );

    fx.advance_live_oracle_bundle(&mut market, test_constants::default_live_price());
    let (_closed, replacement) = fx.redeem_bundle(
        &mut market,
        &mut account,
        order_id,
        max_order_quantity - constants::position_lot_size!(),
    );
    let survivor_id = replacement.destroy_some();
    let survivor = order::from_order_id(survivor_id);
    assert_eq!(survivor.quantity(), constants::position_lot_size!());
    assert_eq!(survivor.floor_shares(), expected_last_lot_floor);
    assert!(helpers::has_position_bundle(&account, expiry_id, survivor_id));
    helpers::assert_market_backed_bundle(&market);

    helpers::return_account_bundle(account);
    helpers::return_market_bundle(market);
    fx.finish();
}

/// Shared 2x-mint prologue + a row's live close schedule + the reachable solvency /
/// position assertions. Each row is a self-contained fixture lifecycle.
fun run_live_close_schedule(closes: vector<u64>) {
    let (mut fx, expiry_id, trader) = helpers::setup_live_market(
        test_constants::short_expiry_ms(),
        test_constants::default_live_price(),
    );
    fx.scenario_mut().next_tx(test_constants::alice());
    let mut market = fx.take_market_bundle(expiry_id);
    let mut account = fx.take_account_bundle(&trader);

    let order_id = fx.mint_bundle(
        &mut market,
        &mut account,
        helpers::strike_tick(),
        constants::pos_inf_tick!(),
        test_constants::mint_quantity(),
        LEVERAGE_TWO_X,
    );

    // Run the live close schedule, threading the survivor id through each partial
    // close. After every close the survivor position must exist and the market must
    // stay backed (cash >= payout liability + rebate reserve).
    let mut survivor_id = order_id;
    let mut i = 0;
    while (i < closes.length()) {
        fx.advance_live_oracle_bundle(&mut market, test_constants::default_live_price());
        let (_closed, replacement) = fx.redeem_bundle(
            &mut market,
            &mut account,
            survivor_id,
            closes[i],
        );
        survivor_id = replacement.destroy_some();
        assert!(helpers::has_position_bundle(&account, expiry_id, survivor_id));
        helpers::assert_market_backed_bundle(&market);
        i = i + 1;
    };

    helpers::return_account_bundle(account);
    helpers::return_market_bundle(market);
    fx.finish();
}
