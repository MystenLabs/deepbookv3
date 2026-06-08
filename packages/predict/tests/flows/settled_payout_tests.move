// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// P0 settled-payout invariant on the hot redeem flow (un-leveraged case).
///
/// A 1x order carries zero floor shares, so an in-the-money settled redeem must
/// pay back EXACTLY the minted quantity — independent derivation:
///   payout = quantity − floor(floor_shares × terminal_floor_index)
///          = quantity − floor(0 × T) = quantity.
/// This is the simplest economic guarantee a binary winner expects. The
/// `strike_exposure_c1` tests cover the leveraged (non-zero floor) case; this
/// covers the un-leveraged case and the S3 solvency drain (reserve → 0).
#[test_only]
module deepbook_predict::settled_payout_tests;

use deepbook_predict::{constants, flow_test_helpers as helpers};
use std::unit_test::{assert_eq, destroy};

const EXPIRY_MS: u64 = 200_000;
const LIVE_PRICE: u64 = 100_000_000_000;
/// In the money: strictly above the order's lower strike (`min_strike` = 100e9).
const SETTLEMENT_ITM: u64 = 110_000_000_000;
const MINT_QUANTITY: u64 = 1_000_000_000;
const MINT_DEPOSIT: u64 = 1_000_000_000;
/// 1x leverage in FLOAT_SCALING; flat floor schedule => zero floor shares.
const LEVERAGE_ONE_X: u64 = 1_000_000_000;

#[test]
fun one_x_order_settled_in_range_pays_full_quantity() {
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
        LEVERAGE_ONE_X,
    );

    fx.settle_oracle(&config, &mut oracle, &mut pyth, SETTLEMENT_ITM);

    let balance_before = manager.balance();
    fx.redeem_settled(
        &config,
        &mut manager,
        &mut market,
        &oracle,
        &pyth,
        order_id,
        MINT_QUANTITY,
    );

    // Independent: a 1x (zero-floor) in-range winner is paid its full notional,
    // and the settled-liability reserve drains to exactly zero (S3 solvency).
    assert_eq!(manager.balance() - balance_before, MINT_QUANTITY);
    assert_eq!(market.payout_liability(), 0);

    helpers::return_market(pyth, vault, market, oracle, config);
    destroy(manager);
    fx.finish();
}
