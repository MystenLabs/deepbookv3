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
/// One parameterized test walks the shared 2x-mint prologue and drives three
/// close-schedule rows; each row asserts its exact hand-derived survivor payout,
/// `payout_liability == 0`, and the cleared position. The gap==1 row (the
/// fund-stranding trigger) additionally asserts the +1 sub-additivity gap.
#[test_only]
module deepbook_predict::strike_exposure_c1_tests;

use deepbook_predict::{
    constants,
    expiry_market::ExpiryMarket,
    flow_test_helpers as helpers,
    market_oracle::MarketOracle,
    order,
    plp::PoolVault,
    predict_manager::PredictManager,
    protocol_config::ProtocolConfig,
    pyth_source::PythSource,
    test_constants
};
use fixed_math::math;
use std::unit_test::{assert_eq, destroy};

/// Settlement strictly above the order's lower strike => in the money.
const SETTLEMENT_ITM: u64 = 110_000_000_000;
/// 2x leverage gives a non-zero floor (required for the gap to exist).
const LEVERAGE_TWO_X: u64 = 2_000_000_000;
/// Default terminal_floor_index (1.2x); unchanged by the test setup.
const TERMINAL_FLOOR_INDEX: u64 = 1_200_000_000;

/// gap==1 row: tuned so the close/remaining floor-share split loses exactly 1 unit
/// to round-down `mul` (old_floor_shares = 208_333_553, remove lands at ...504,
/// mod 5 = 4 > old mod 5 = 3). Independent (hand) survivor payout:
///   remaining_q  = 1_000_000_000 - 400_010_000 = 599_990_000
///   remaining_fs = 208_333_553 - 83_335_504    = 124_998_049
///   floor(remaining_fs * 1.2)                  = 149_997_658
///   P = remaining_q - floor                    = 449_992_342
const CLOSE_GAP_ONE: u64 = 400_010_000;
const EXPECTED_GAP_ONE_PAYOUT: u64 = 449_992_342;

/// gap==0 control: a close whose split loses nothing to rounding.
///   remaining_q = 599_980_000, remaining_fs = 124_995_966,
///   floor(124_995_966 * 1.2) = 149_995_159, P = 449_984_841.
const CLOSE_GAP_ZERO: u64 = 400_020_000;
const EXPECTED_GAP_ZERO_PAYOUT: u64 = 449_984_841;

/// Double close: 300M then 200M of the 700M survivor; final 500M survivor payout
///   remaining_fs = 104_166_778, floor(* 1.2) = 125_000_133, P = 374_999_867.
const FIRST_CLOSE: u64 = 300_000_000;
const SECOND_CLOSE: u64 = 200_000_000;
const EXPECTED_DOUBLE_CLOSE_PAYOUT: u64 = 374_999_867;

// One parameterized flow (`run_close_schedule`) driven by three close-schedule
// rows. These stay as three `#[test]`s rather than one because each row needs the
// identical short expiry (200_000) on a FRESH pool — `test_scenario` leaks shared
// objects across multiple `begin`/`end` cycles in one test fn, and the same expiry
// can't coexist twice in one registry (and the clock advances past it after each
// settle). The fragmentation that mattered — the copy-pasted bring-up + close +
// settle + assert body — is gone; the rows are now data.

/// Row 1: single close hitting the +1 sub-additivity gap — the C1 fund-stranding
/// regression (the reserve must still drain to exactly zero).
#[test]
fun partial_close_gap_one_settled_redeem_drains_reserve_exactly() {
    run_close_schedule(vector[CLOSE_GAP_ONE], EXPECTED_GAP_ONE_PAYOUT, true);
}

/// Row 2: single close with no rounding gap (the common case must not regress).
#[test]
fun partial_close_gap_zero_settled_redeem_is_exact() {
    run_close_schedule(vector[CLOSE_GAP_ZERO], EXPECTED_GAP_ZERO_PAYOUT, false);
}

/// Row 3: two sequential closes — the survivor must be reinserted each time so the
/// second close removes terms the tree actually holds.
#[test]
fun double_partial_close_settled_redeem_is_exact() {
    run_close_schedule(vector[FIRST_CLOSE, SECOND_CLOSE], EXPECTED_DOUBLE_CLOSE_PAYOUT, false);
}

/// Shared 2x-mint prologue + a row's close schedule + the settled-redeem
/// assertions. Each row is a self-contained fixture lifecycle.
fun run_close_schedule(closes: vector<u64>, expected_payout: u64, check_gap_one: bool) {
    let (mut fx, expiry_id, oracle_id, mut manager) = helpers::setup_live_market(
        test_constants::short_expiry_ms(),
        test_constants::default_live_price(),
    );
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
        test_constants::mint_quantity(),
        LEVERAGE_TWO_X,
    );

    if (check_gap_one) {
        assert_gap_is_one(order_id, closes[0]);
    };

    // Run the close schedule, threading the survivor id through each partial close.
    let mut survivor_id = order_id;
    let mut total_closed = 0;
    let mut i = 0;
    while (i < closes.length()) {
        let (_closed, replacement) = fx.redeem(
            &config,
            &mut manager,
            &mut market,
            &oracle,
            &pyth,
            survivor_id,
            closes[i],
        );
        survivor_id = replacement.destroy_some();
        total_closed = total_closed + closes[i];
        i = i + 1;
    };

    fx.settle_oracle(&config, &mut oracle, &mut pyth, SETTLEMENT_ITM);

    // Marginal settled redeem of the survivor: pays the winner exactly the
    // hand-derived payout, the reserve drains to zero (R == P), position cleared.
    let balance_before = manager.balance();
    fx.redeem_settled(
        &config,
        &mut manager,
        &mut market,
        &oracle,
        &pyth,
        survivor_id,
        test_constants::mint_quantity() - total_closed,
    );

    assert_eq!(manager.balance() - balance_before, expected_payout);
    assert_eq!(market.payout_liability(), 0);
    assert!(!manager.has_position(expiry_id, survivor_id));

    cleanup(fx, pyth, vault, market, oracle, config, manager);
}

/// Confirm a single close hits the +1 floor-share sub-additivity gap that
/// triggered C1 (independent of the close/settle flow).
fun assert_gap_is_one(order_id: u256, close_quantity: u64) {
    let o = order::from_order_id(order_id);
    let old_quantity = o.quantity();
    let old_floor_shares = o.floor_shares();
    let remove_floor_shares = math::mul(old_floor_shares, math::div(close_quantity, old_quantity));
    let remaining_floor_shares = old_floor_shares - remove_floor_shares;
    let gap =
        math::mul(old_floor_shares, TERMINAL_FLOOR_INDEX)
            - math::mul(remove_floor_shares, TERMINAL_FLOOR_INDEX)
            - math::mul(remaining_floor_shares, TERMINAL_FLOOR_INDEX);
    assert_eq!(gap, 1);
}

fun cleanup(
    fx: helpers::Fixture,
    pyth: PythSource,
    vault: PoolVault,
    market: ExpiryMarket,
    oracle: MarketOracle,
    config: ProtocolConfig,
    manager: PredictManager,
) {
    helpers::return_market(pyth, vault, market, oracle, config);
    destroy(manager);
    fx.finish();
}
