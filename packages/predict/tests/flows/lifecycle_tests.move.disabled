// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// One-flow-many-assertions lifecycle test for the 1x (un-leveraged) live happy
/// path: one order is walked fund -> mint with a full state-sheet
/// (`check_manager`) re-asserted after each action. Terminal settlement coverage
/// lives in `settlement_flow_tests`.
#[test_only]
module deepbook_predict::lifecycle_tests;

use deepbook_predict::{constants, flow_test_helpers as helpers, test_constants};
use std::unit_test::assert_eq;

/// Per-trade fee floors at `min_fee` (base_fee floored to 1 in the fixture).
const MINT_MIN_FEE: u64 = 5_000_000;
/// Independent derivation of the post-mint free balance:
///   The order is `[min_finite_strike, +inf)` and the live forward == the strike,
///   so its entry probability is the at-the-money digital Φ(0) = 0.5 (the SVI wing
///   rounds to zero, leaving d2 = 0). A 1x order fronts its full premium, so
///   net_premium = floor(0.5 * mint_quantity) = 500_000_000, and the fee floors at
///   min_fee = 5_000_000. balance = mint_deposit - net_premium - fee
///           = 1_000_000_000 - 500_000_000 - 5_000_000 = 495_000_000.
const POST_MINT_BALANCE: u64 = 495_000_000;

#[test]
fun one_x_lifecycle_fund_mint() {
    let (mut fx, expiry_id, trader) = helpers::setup_live_market(
        test_constants::short_expiry_ms(),
        test_constants::default_live_price(),
    );
    fx.scenario_mut().next_tx(test_constants::alice());
    let (pyth, bs, oracle_registry, vault, mut market, config) = fx.take_market(expiry_id);
    let mut wrapper = fx.take_account(&trader);
    let root = fx.take_root();

    // --- The fixture seeded expiry cash while pool funding is absent.
    assert_eq!(market.cash_balance(), test_constants::default_seeded_expiry_cash());

    // Pre-trade state sheet: only the deposit has moved.
    let mut expected = helpers::expected_manager_state(test_constants::mint_deposit(), 0, 0, 0, 0);
    fx.check_manager(&wrapper, &root, expiry_id, expected);

    // --- Mint one 1x in-range order.
    let order_id = fx.mint(
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
    );
    assert!(helpers::has_position(&wrapper, expiry_id, order_id));
    expected = helpers::expected_manager_state(POST_MINT_BALANCE, MINT_MIN_FEE, 1, 0, 0);
    fx.check_manager(&wrapper, &root, expiry_id, expected);

    helpers::return_account(wrapper, root);

    helpers::return_market(pyth, bs, oracle_registry, vault, market, config);
    fx.finish();
}
