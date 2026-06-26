// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Guard tests for `strike_exposure` order-close validation.
#[test_only]
module deepbook_predict::strike_exposure_guard_tests;

use deepbook_predict::{constants, flow_test_helpers as helpers, strike_exposure, test_constants};

/// Closing more than the order's open quantity is rejected on the live redeem
/// path (one extra position lot above the minted quantity).
#[test, expected_failure(abort_code = strike_exposure::EInvalidCloseQuantity)]
fun redeem_above_order_quantity_aborts() {
    let (mut fx, expiry_id, trader) = helpers::setup_everything();
    fx.scenario_mut().next_tx(test_constants::alice());
    let mut market = fx.take_market_bundle(expiry_id);
    let mut account = fx.take_account_bundle(&trader);

    let order_id = fx.mint_bundle(
        &mut market,
        &mut account,
        helpers::strike_tick(),
        constants::pos_inf_tick!(),
        test_constants::mint_quantity(),
        test_constants::leverage_one_x(),
    );
    fx.advance_live_oracle_bundle(&mut market, test_constants::default_live_price());
    fx.redeem_bundle(
        &mut market,
        &mut account,
        order_id,
        test_constants::mint_quantity() + constants::position_lot_size!(),
    );
    abort 999
}
