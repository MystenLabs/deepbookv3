// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module deepbook_predict::oracle_tests;

use deepbook_predict::{i64, oracle};
use sui::{clock, test_scenario};
use std::string;

#[test]
fun test_oracle_lifecycle() {
    let operator = @0x09;
    let mut scenario = test_scenario::begin(operator);
    let mut clk = clock::create_for_testing(scenario.ctx());

    let cap = oracle::create_oracle_cap(scenario.ctx());
    let bounds = oracle::new_oracle_bounds(
        3000, 60000, 2000, 60000, // staleness thresholds
        100_000_000, // max spot dev 10%
        100_000_000, // max basis dev 10%
        900_000_000, // min basis 0.9
        1_100_000_000 // max basis 1.1
    );

    let mut oracle = oracle::create_oracle_test(
        string::utf8(b"SUI"),
        1, // feed id
        10000, // expiry
        bounds,
        &cap,
        scenario.ctx()
    );

    assert!(oracle::underlying_asset(&oracle) == string::utf8(b"SUI"), 0);
    assert!(oracle::is_active(&oracle), 1);

    // Update prices
    oracle.update_prices(
        &cap,
        1000, // spot
        1000, // forward
        &clk
    );

    assert!(oracle::spot_price(&oracle) == 1000, 2);

    // Update SVI params (otherwise compute_price aborts with EZeroVariance)
    let svi = oracle::new_svi_params(
        100_000_000, // a = 0.1
        100_000_000, // b = 0.1
        i64::zero(),
        i64::zero(),
        100_000_000 // sigma = 0.1
    );
    oracle.update_svi(&cap, svi, &clk);

    // Test pricing logic
    let price_at_strike_900 = oracle.compute_price(900);
    assert!(price_at_strike_900 > 500_000_000, 3); // UP price at 900 strike when spot 1000 should be > 0.5

    oracle::destroy_oracle_cap(cap);
    test_scenario::return_shared(oracle);
    clk.destroy_for_testing();
    scenario.end();
}

#[test]
#[expected_failure(abort_code = oracle::EInvalidSVIParams)]
fun test_update_svi_invalid_rho() {
    let operator = @0x09;
    let mut scenario = test_scenario::begin(operator);
    let clk = clock::create_for_testing(scenario.ctx());

    let cap = oracle::create_oracle_cap(scenario.ctx());
    let bounds = oracle::new_oracle_bounds(3000, 60000, 2000, 60000, 20_000_000, 20_000_000, 900_000_000, 1_100_000_000);
    
    let mut oracle = oracle::create_oracle_test(
        string::utf8(b"SUI"),
        1,
        10000,
        bounds,
        &cap,
        scenario.ctx()
    );

    let invalid_svi = oracle::new_svi_params(
        0, 
        0, 
        i64::from_u64(1_000_000_000), // rho 1.0 > 0.995
        i64::zero(), 
        0
    );

    oracle.update_svi(&cap, invalid_svi, &clk);

    oracle::destroy_oracle_cap(cap);
    test_scenario::return_shared(oracle);
    clk.destroy_for_testing();
    scenario.end();
}

#[test]
#[expected_failure(abort_code = oracle::EInvalidSVIParams)]
fun test_update_svi_invalid_param_ceiling() {
    let operator = @0x09;
    let mut scenario = test_scenario::begin(operator);
    let clk = clock::create_for_testing(scenario.ctx());

    let cap = oracle::create_oracle_cap(scenario.ctx());
    let bounds = oracle::new_oracle_bounds(3000, 60000, 2000, 60000, 20_000_000, 20_000_000, 900_000_000, 1_100_000_000);
    
    let mut oracle = oracle::create_oracle_test(
        string::utf8(b"SUI"),
        1,
        10000,
        bounds,
        &cap,
        scenario.ctx()
    );

    let invalid_svi = oracle::new_svi_params(
        11_000_000_000, // a 11.0 > 10.0 ceiling
        0, 
        i64::zero(), 
        i64::zero(), 
        0
    );

    oracle.update_svi(&cap, invalid_svi, &clk);

    oracle::destroy_oracle_cap(cap);
    test_scenario::return_shared(oracle);
    clk.destroy_for_testing();
    scenario.end();
}
