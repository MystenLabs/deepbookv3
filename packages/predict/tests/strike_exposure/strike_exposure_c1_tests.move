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
/// This scenario is tuned to hit the gap == 1 case (asserted below).
#[test_only]
module deepbook_predict::strike_exposure_c1_tests;

use deepbook::math;
use deepbook_predict::{constants, expiry_market::ExpiryMarket, flow_test_helpers as helpers, order};
use std::unit_test::{assert_eq, destroy};
use sui::test_scenario::return_shared;

const EXPIRY_MS: u64 = 200_000;
const LIVE_PRICE: u64 = 100_000_000_000;
/// Settlement strictly above the order's lower strike => in the money.
const SETTLEMENT_ITM: u64 = 110_000_000_000;
const MINT_QUANTITY: u64 = 1_000_000_000;
const MINT_DEPOSIT: u64 = 1_000_000_000;
/// 2x leverage gives a non-zero floor (required for the gap to exist).
const LEVERAGE_TWO_X: u64 = 2_000_000_000;
/// Tuned so the close/remaining floor-share split loses exactly 1 unit to
/// round-down `mul`: with old_floor_shares = 208_333_553, remove_floor_shares
/// lands at ...504 (mod 5 = 4 > old mod 5 = 3), so the gap is 1.
const CLOSE_QUANTITY: u64 = 400_010_000;
/// Default terminal_floor_index (1.2x); unchanged by the test setup.
const TERMINAL_FLOOR_INDEX: u64 = 1_200_000_000;
/// Independent (hand) derivation of the survivor's settled payout:
///   remaining_q  = 1_000_000_000 - 400_010_000          = 599_990_000
///   remaining_fs = 208_333_553 - 83_335_504             = 124_998_049
///   floor(remaining_fs * 1.2)                            = 149_997_658
///   P = remaining_q - floor                              = 449_992_342
const EXPECTED_SETTLED_PAYOUT: u64 = 449_992_342;

/// gap == 0 control: close where the split loses nothing to rounding.
///   remaining_q = 599_980_000, remaining_fs = 124_995_966,
///   floor(124_995_966 * 1.2) = 149_995_159, P = 449_984_841.
const CLOSE_QUANTITY_GAP_ZERO: u64 = 400_020_000;
const EXPECTED_GAP_ZERO_PAYOUT: u64 = 449_984_841;

/// Two sequential partial closes of one order (300M then 200M of the 700M
/// survivor). The pre-fix code never reinserted the survivor into the payout
/// tree, so the second close removed terms the tree no longer held; the reinsert
/// makes each survivor's terms exact. Final 500M survivor settled payout:
///   remaining_fs = 104_166_778, floor(* 1.2) = 125_000_133, P = 374_999_867.
const FIRST_CLOSE: u64 = 300_000_000;
const SECOND_CLOSE: u64 = 200_000_000;
const EXPECTED_DOUBLE_CLOSE_PAYOUT: u64 = 374_999_867;

#[test]
fun partial_close_then_settled_redeem_drains_reserve_exactly() {
    let mut fx = helpers::setup_pool_with_pyth();
    let (expiry_id, oracle_id) = fx.create_expiry(EXPIRY_MS);
    let mut manager = fx.create_funded_manager(MINT_DEPOSIT);
    let (mut pyth, mut vault, mut market, mut oracle, mut config) = fx.take_market(
        expiry_id,
        oracle_id,
    );

    fx.prepare_live_oracle(&config, &mut oracle, &mut pyth, LIVE_PRICE);
    fx.sync_expiry(&mut config, &mut vault, &mut market, &oracle, &pyth);

    let order_id = fx.mint(
        &config,
        &mut manager,
        &mut market,
        &oracle,
        &pyth,
        helpers::min_strike(),
        constants::pos_inf!(),
        MINT_QUANTITY,
        LEVERAGE_TWO_X,
    );

    // Confirm this close hits the +1 sub-additivity gap that triggered C1.
    let o = order::from_order_id(order_id);
    let old_quantity = o.quantity();
    let old_floor_shares = o.floor_shares();
    let remove_floor_shares = math::mul(old_floor_shares, math::div(CLOSE_QUANTITY, old_quantity));
    let remaining_floor_shares = old_floor_shares - remove_floor_shares;
    let gap =
        math::mul(old_floor_shares, TERMINAL_FLOOR_INDEX)
            - math::mul(remove_floor_shares, TERMINAL_FLOOR_INDEX)
            - math::mul(remaining_floor_shares, TERMINAL_FLOOR_INDEX);
    assert_eq!(gap, 1);

    let (_closed, replacement) = fx.redeem(
        &config,
        &mut manager,
        &mut market,
        &oracle,
        &pyth,
        order_id,
        CLOSE_QUANTITY,
    );
    let replacement_id = replacement.destroy_some();

    fx.settle_oracle(&config, &mut oracle, &mut pyth, SETTLEMENT_ITM);

    // Marginal settled redeem of the survivor: pays the winner in full and the
    // reserve drains to exactly zero (R == P, no underflow).
    let balance_before = manager.balance();
    fx.redeem_settled(
        &config,
        &mut manager,
        &mut market,
        &oracle,
        &pyth,
        replacement_id,
        old_quantity - CLOSE_QUANTITY,
    );

    assert_eq!(manager.balance() - balance_before, EXPECTED_SETTLED_PAYOUT);
    assert_eq!(market.payout_liability(), 0);
    assert!(!manager.has_position(expiry_id, replacement_id));

    return_shared(config);
    return_shared(oracle);
    return_shared(market);
    return_shared(vault);
    return_shared(pyth);
    destroy(manager);
    fx.finish();
}

/// Control: a partial close whose split loses nothing to rounding (gap == 0)
/// also pays exactly and drains the reserve (the fix must not regress the common case).
#[test]
fun partial_close_gap_zero_settled_redeem_is_exact() {
    let mut fx = helpers::setup_pool_with_pyth();
    let (expiry_id, oracle_id) = fx.create_expiry(EXPIRY_MS);
    let mut manager = fx.create_funded_manager(MINT_DEPOSIT);
    let (mut pyth, mut vault, mut market, mut oracle, mut config) = fx.take_market(
        expiry_id,
        oracle_id,
    );

    fx.prepare_live_oracle(&config, &mut oracle, &mut pyth, LIVE_PRICE);
    fx.sync_expiry(&mut config, &mut vault, &mut market, &oracle, &pyth);

    let order_id = fx.mint(
        &config,
        &mut manager,
        &mut market,
        &oracle,
        &pyth,
        helpers::min_strike(),
        constants::pos_inf!(),
        MINT_QUANTITY,
        LEVERAGE_TWO_X,
    );

    let (_closed, replacement) = fx.redeem(
        &config,
        &mut manager,
        &mut market,
        &oracle,
        &pyth,
        order_id,
        CLOSE_QUANTITY_GAP_ZERO,
    );
    let replacement_id = replacement.destroy_some();

    fx.settle_oracle(&config, &mut oracle, &mut pyth, SETTLEMENT_ITM);

    let balance_before = manager.balance();
    fx.redeem_settled(
        &config,
        &mut manager,
        &mut market,
        &oracle,
        &pyth,
        replacement_id,
        MINT_QUANTITY - CLOSE_QUANTITY_GAP_ZERO,
    );

    assert_eq!(manager.balance() - balance_before, EXPECTED_GAP_ZERO_PAYOUT);
    assert_eq!(market.payout_liability(), 0);

    return_shared(config);
    return_shared(oracle);
    return_shared(market);
    return_shared(vault);
    return_shared(pyth);
    destroy(manager);
    fx.finish();
}

/// Two sequential partial closes on one order, then an in-the-money settled
/// redeem of the final survivor. Exercises the reinsert across repeated closes:
/// pre-fix the survivor was never returned to the payout tree, so the second
/// close removed terms the tree no longer held.
#[test]
fun double_partial_close_then_settled_redeem_is_exact() {
    let mut fx = helpers::setup_pool_with_pyth();
    let (expiry_id, oracle_id) = fx.create_expiry(EXPIRY_MS);
    let mut manager = fx.create_funded_manager(MINT_DEPOSIT);
    let (mut pyth, mut vault, mut market, mut oracle, mut config) = fx.take_market(
        expiry_id,
        oracle_id,
    );

    fx.prepare_live_oracle(&config, &mut oracle, &mut pyth, LIVE_PRICE);
    fx.sync_expiry(&mut config, &mut vault, &mut market, &oracle, &pyth);

    let order_id = fx.mint(
        &config,
        &mut manager,
        &mut market,
        &oracle,
        &pyth,
        helpers::min_strike(),
        constants::pos_inf!(),
        MINT_QUANTITY,
        LEVERAGE_TWO_X,
    );

    let (_c1, replacement1) = fx.redeem(
        &config,
        &mut manager,
        &mut market,
        &oracle,
        &pyth,
        order_id,
        FIRST_CLOSE,
    );
    let replacement1_id = replacement1.destroy_some();
    let (_c2, replacement2) = fx.redeem(
        &config,
        &mut manager,
        &mut market,
        &oracle,
        &pyth,
        replacement1_id,
        SECOND_CLOSE,
    );
    let replacement2_id = replacement2.destroy_some();

    fx.settle_oracle(&config, &mut oracle, &mut pyth, SETTLEMENT_ITM);

    let balance_before = manager.balance();
    fx.redeem_settled(
        &config,
        &mut manager,
        &mut market,
        &oracle,
        &pyth,
        replacement2_id,
        MINT_QUANTITY - FIRST_CLOSE - SECOND_CLOSE,
    );

    assert_eq!(manager.balance() - balance_before, EXPECTED_DOUBLE_CLOSE_PAYOUT);
    assert_eq!(market.payout_liability(), 0);

    return_shared(config);
    return_shared(oracle);
    return_shared(market);
    return_shared(vault);
    return_shared(pyth);
    destroy(manager);
    fx.finish();
}
