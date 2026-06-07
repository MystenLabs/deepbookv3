// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// End-to-end bring-up smoke test for the Predict trade flow.
///
/// Validates that a tradeable market can be stood up through the production
/// creation path, funded through the real PLP supply + sync rebalance, and
/// minted against. Foundation for the restored flow/error-path tests (C2).
#[test_only]
module deepbook_predict::flow_bringup_tests;

use deepbook_predict::{
    constants,
    expiry_market::ExpiryMarket,
    flow_test_helpers as helpers,
    market_oracle::{Self, MarketOracle},
    plp::PoolVault,
    pyth_source::PythSource
};
use std::unit_test::{assert_eq, destroy};
use sui::test_scenario::return_shared;

const EXPIRY_MS: u64 = 200_000;
const LIVE_PRICE: u64 = 100_000_000_000;
const MINT_QUANTITY: u64 = 1_000_000_000;
const MINT_DEPOSIT: u64 = 1_000_000_000;
const MINT_MIN_FEE: u64 = 5_000_000;
/// 1x leverage in FLOAT_SCALING; the floor schedule is flat (no leverage).
const LEVERAGE_ONE_X: u64 = 1_000_000_000;

#[test]
fun bringup_funds_expiry_and_allows_mint() {
    let mut fx = helpers::setup_pool_with_pyth();
    let (expiry_id, oracle_id) = fx.create_expiry(EXPIRY_MS);
    let mut manager = fx.create_funded_manager(MINT_DEPOSIT);
    let (mut pyth, mut vault, mut market, mut oracle) = fx.take_market(expiry_id, oracle_id);

    fx.prepare_live_oracle(&mut oracle, &mut pyth, LIVE_PRICE);
    fx.sync_expiry(&mut vault, &mut market, &oracle, &pyth);

    // The funding sync rebalanced idle pool cash up to the per-expiry cash floor.
    assert_eq!(market.cash_balance(), constants::expiry_cash_floor!());
    assert!(!oracle.is_settled());
    assert_eq!(oracle.status(fx.clock()), market_oracle::status_active());

    let order_id = fx.mint(
        &mut manager,
        &mut market,
        &oracle,
        &pyth,
        helpers::min_strike(),
        constants::pos_inf!(),
        MINT_QUANTITY,
        LEVERAGE_ONE_X,
    );

    assert!(manager.has_position(expiry_id, order_id));
    // base_fee floored to 1 in setup, so the per-trade fee floors at min_fee.
    assert_eq!(manager.trading_fees_paid(expiry_id), MINT_MIN_FEE);

    return_shared(oracle);
    return_shared(market);
    return_shared(vault);
    return_shared(pyth);
    destroy(manager);
    fx.finish();
}
