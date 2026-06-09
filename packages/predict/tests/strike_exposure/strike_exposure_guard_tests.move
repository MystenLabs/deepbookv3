// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Guard tests for `strike_exposure` order-close validation and the compaction
/// sequencing precondition.
#[test_only]
module deepbook_predict::strike_exposure_guard_tests;

use deepbook_predict::{
    constants,
    flow_test_helpers as helpers,
    strike_exposure,
    strike_exposure_config,
    strike_grid,
    test_constants
};

const BTC_SPOT: u64 = 100_000_000_000_000; // $100,000 in 1e9 price scaling
const TICK_SIZE: u64 = 1_000_000_000; // $1.00
const EXPIRY_MS: u64 = 1_000_000;
const EXPIRY_MARKET_ID: address = @0xE1;

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

/// Live-index destruction is only legal after the terminal settled liability has
/// been cached; compacting an unsettled exposure book is rejected.
#[test, expected_failure(abort_code = strike_exposure::ESettledLiabilityNotMaterialized)]
fun destroy_live_indexes_before_materialize_aborts() {
    let ctx = &mut tx_context::dummy();
    let grid = strike_grid::new_centered(BTC_SPOT, TICK_SIZE);
    let mut exposure = strike_exposure::new(
        EXPIRY_MARKET_ID.to_id(),
        EXPIRY_MS,
        grid,
        0,
        strike_exposure_config::new(),
        ctx,
    );
    exposure.destroy_live_indexes();
    abort 999
}
