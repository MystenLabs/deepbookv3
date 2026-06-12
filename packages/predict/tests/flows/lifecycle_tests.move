// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// One-flow-many-assertions lifecycle test for the 1x (un-leveraged) happy path,
/// mirroring deepbook-core's `test_master`: one order is walked
/// fund -> mint -> settle -> redeem with a full state-sheet (`check_manager`)
/// re-asserted after each action. Merges the former `flow_bringup_tests`
/// (fund + mint smoke) and `settled_payout_tests` (1x in-range winner pays full).
#[test_only]
module deepbook_predict::lifecycle_tests;

use deepbook_predict::{constants, flow_test_helpers as helpers, market_oracle, test_constants};
use std::unit_test::{destroy, assert_eq};

/// Per-trade fee floors at `min_fee` (base_fee floored to 1 in the fixture).
const MINT_MIN_FEE: u64 = 5_000_000;
/// Independent derivation of the post-mint free balance:
///   The order is `[min_strike, +inf)` and the live forward == min_strike, so its
///   entry probability is the at-the-money digital Φ(0) = 0.5 (the SVI wing rounds
///   to zero, leaving d2 = 0). A 1x order fronts its full premium, so
///   net_premium = floor(0.5 * mint_quantity) = 500_000_000, and the fee floors at
///   min_fee = 5_000_000. balance = mint_deposit - net_premium - fee
///           = 1_000_000_000 - 500_000_000 - 5_000_000 = 495_000_000.
const POST_MINT_BALANCE: u64 = 495_000_000;
/// In the money: strictly above the order's lower strike (`min_strike` = 100e9).
const SETTLEMENT_ITM: u64 = 110_000_000_000;
/// A 1x (zero-floor) winner is paid its full notional, so the free balance after
/// the settled redeem is POST_MINT_BALANCE + mint_quantity.
const POST_REDEEM_BALANCE: u64 = 1_495_000_000;

#[test]
fun one_x_lifecycle_fund_mint_settle_redeem() {
    let (mut fx, expiry_id, oracle_id, mut manager) = helpers::setup_live_market(
        test_constants::short_expiry_ms(),
        test_constants::default_live_price(),
    );
    fx.scenario_mut().next_tx(test_constants::alice());
    let (mut pyth, vault, mut market, mut oracle, config) = fx.take_market(expiry_id, oracle_id);

    // --- After the funding sync: idle pool cash rebalanced up to the per-expiry
    // cash floor; oracle live and not settled.
    assert_eq!(market.cash_balance(), constants::expiry_cash_floor!());
    assert!(!oracle.is_settled());
    assert_eq!(oracle.status(fx.clock()), market_oracle::status_active());

    // Pre-trade state sheet: only the deposit has moved.
    let mut expected = helpers::expected_manager_state(test_constants::mint_deposit(), 0, 0, 0, 0);
    helpers::check_manager(&manager, expiry_id, expected);

    // --- Mint one 1x in-range order.
    let order_id = fx.mint(
        &config,
        &mut manager,
        &mut market,
        &oracle,
        &pyth,
        helpers::min_strike(),
        constants::pos_inf!(),
        test_constants::mint_quantity(),
        test_constants::leverage_one_x(),
    );
    assert!(manager.has_position(expiry_id, order_id));
    expected = helpers::expected_manager_state(POST_MINT_BALANCE, MINT_MIN_FEE, 1, 0, 0);
    helpers::check_manager(&manager, expiry_id, expected);

    // --- Settle in the money, then full permissionless settled redeem.
    fx.settle_oracle(&config, &mut oracle, &mut pyth, SETTLEMENT_ITM);
    let balance_before = manager.balance();
    fx.redeem_settled(
        &config,
        &mut manager,
        &mut market,
        &oracle,
        &pyth,
        order_id,
        test_constants::mint_quantity(),
    );

    // 1x (zero-floor) in-range winner is paid its full notional; the settled
    // reserve drains to exactly zero (S3 solvency); the position is cleared.
    assert_eq!(manager.balance() - balance_before, test_constants::mint_quantity());
    assert_eq!(market.payout_liability(), 0);
    assert!(!manager.has_position(expiry_id, order_id));
    expected = helpers::expected_manager_state(POST_REDEEM_BALANCE, MINT_MIN_FEE, 0, 0, 0);
    helpers::check_manager(&manager, expiry_id, expected);

    helpers::return_market(pyth, vault, market, oracle, config);
    destroy(manager);
    fx.finish();
}
