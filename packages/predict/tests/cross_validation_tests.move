// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module deepbook_predict::cross_validation_tests;

use deepbook_predict::{constants, market_key, range_key};

#[test]
fun test_key_range_consistency() {
    let oracle_id = @0x123.to_id();
    let expiry = 10000;
    let strike = 50000;

    // UP key consistency
    let up_key = market_key::new(oracle_id, expiry, strike, true);
    let range_up = market_key::to_range(&up_key);
    
    assert!(range_up.oracle_id() == oracle_id, 0);
    assert!(range_up.expiry() == expiry, 1);
    assert!(range_up.lower_strike() == strike, 2);
    assert!(range_up.higher_strike() == constants::pos_inf!(), 3);

    // DOWN key consistency
    let down_key = market_key::new(oracle_id, expiry, strike, false);
    let range_down = market_key::to_range(&down_key);

    assert!(range_down.oracle_id() == oracle_id, 4);
    assert!(range_down.expiry() == expiry, 5);
    assert!(range_down.lower_strike() == constants::neg_inf!(), 6);
    assert!(range_down.higher_strike() == strike, 7);

    // Paired range consistency
    let up_range = market_key::to_range(&up_key);
    let down_range = market_key::to_range(&down_key);

    // Sum of UP (strike, inf] and DOWN (neg_inf, strike] is the full range
    // In settlement, if price > strike, UP pays 1, DOWN pays 0. Total = 1.
    // If price <= strike, UP pays 0, DOWN pays 1. Total = 1.
    
    let settlement_high = 60000;
    let settlement_low = 40000;

    assert!(up_range.settled_payout(settlement_high, 100) == 100, 8);
    assert!(down_range.settled_payout(settlement_high, 100) == 0, 9);

    assert!(up_range.settled_payout(settlement_low, 100) == 0, 10);
    assert!(down_range.settled_payout(settlement_low, 100) == 100, 11);
}
