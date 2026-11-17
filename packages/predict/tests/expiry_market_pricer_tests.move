// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// The public reads that loaded or took a live `Pricer`, retired in version 6.
#[test_only]
module deepbook_predict::expiry_market_pricer_tests;

use deepbook_predict::{expiry_market, oracle_fixture, test_constants};

// === Retired with live pricing in version 6 ===
// Every public read that loads or takes a `Pricer` aborts `EUseV2`: no transaction can
// build a live `Pricer` from Propbook objects any more.

#[test, expected_failure(abort_code = expiry_market::EUseV2)]
fun load_live_pricer_is_retired() {
    let mut fx = oracle_fixture::setup_oracle_default();
    let mut oracle = fx.take_oracle_bundle();
    fx.prepare_live_oracle_bundle(&mut oracle, test_constants::default_live_price());
    let market = fx.take_expiry_market();
    market.load_live_pricer(
        oracle_fixture::config(&oracle),
        oracle_fixture::oracle_registry(&oracle),
        oracle_fixture::pyth(&oracle),
        oracle_fixture::bs(&oracle).values(),
        oracle_fixture::bs(&oracle).svi(),
        fx.clock(),
        &mut sui::tx_context::dummy(),
    );
    abort 999
}

#[test, expected_failure(abort_code = expiry_market::EUseV2)]
fun current_nav_is_retired() {
    let mut fx = oracle_fixture::setup_oracle_default();
    let mut oracle = fx.take_oracle_bundle();
    fx.prepare_live_oracle_bundle(&mut oracle, test_constants::default_live_price());
    let pricer = fx.load_pricer_bundle(&oracle);
    let market = fx.take_expiry_market();
    market.current_nav(&pricer);
    abort 999
}

#[test, expected_failure(abort_code = expiry_market::EUseV2)]
fun quote_mint_is_retired() {
    let mut fx = oracle_fixture::setup_oracle_default();
    let mut oracle = fx.take_oracle_bundle();
    fx.prepare_live_oracle_bundle(&mut oracle, test_constants::default_live_price());
    let pricer = fx.load_pricer_bundle(&oracle);
    let market = fx.take_expiry_market();
    market.quote_mint(
        oracle_fixture::config(&oracle),
        &pricer,
        test_constants::default_strike_tick(),
        deepbook_predict::constants::pos_inf_tick!(),
        0,
        test_constants::mint_quantity(),
        true,
        fx.clock(),
        &mut sui::tx_context::dummy(),
    );
    abort 999
}
