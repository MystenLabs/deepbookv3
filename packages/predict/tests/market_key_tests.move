// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module deepbook_predict::market_key_tests;

use deepbook_predict::{constants, market_key};
use sui::object;

#[test]
fun test_market_key_new() {
    let oracle_id = object::id_from_address(@0x123);
    let expiry = 1000;
    let strike = 50000;
    let is_up = true;

    let key = market_key::new(oracle_id, expiry, strike, is_up);
    assert!(market_key::oracle_id(&key) == oracle_id, 0);
    assert!(market_key::expiry(&key) == expiry, 1);
    assert!(market_key::strike(&key) == strike, 2);
    assert!(market_key::is_up(&key) == is_up, 3);
}

#[test]
fun test_to_collateral() {
    let oracle_id = object::id_from_address(@0x123);
    let expiry = 1000;
    let strike = 50000;
    let key = market_key::new(oracle_id, expiry, strike, true);

    let collateral_key = market_key::to_collateral(&key);
    assert!(market_key::c_oracle_id(&collateral_key) == oracle_id, 0);
    assert!(market_key::c_expiry(&collateral_key) == expiry, 1);
    assert!(market_key::c_strike(&collateral_key) == strike, 2);
}

#[test]
fun test_to_range() {
    let oracle_id = object::id_from_address(@0x123);
    let expiry = 1000;
    let strike = 50000;

    // UP key
    let up_key = market_key::new(oracle_id, expiry, strike, true);
    let range_up = market_key::to_range(&up_key);
    assert!(range_up.lower_strike() == strike, 0);
    assert!(range_up.higher_strike() == constants::pos_inf!(), 1);

    // DOWN key
    let down_key = market_key::new(oracle_id, expiry, strike, false);
    let range_down = market_key::to_range(&down_key);
    assert!(range_down.lower_strike() == constants::neg_inf!(), 2);
    assert!(range_down.higher_strike() == strike, 3);
}
