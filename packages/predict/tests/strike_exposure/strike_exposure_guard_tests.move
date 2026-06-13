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
    let (mut fx, expiry_id, oracle_id, mut manager) = helpers::setup_everything();
    fx.scenario_mut().next_tx(test_constants::alice());
    let (pyth, _vault, mut market, oracle, config) = fx.take_market(expiry_id, oracle_id);

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
    fx.redeem(
        &config,
        &mut manager,
        &mut market,
        &oracle,
        &pyth,
        order_id,
        test_constants::mint_quantity() + constants::position_lot_size!(),
    );
    abort 999
}
