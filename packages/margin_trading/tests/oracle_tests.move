// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module margin_trading::oracle_tests;

use margin_trading::oracle::{
    calculate_usd_currency_amount,
    calculate_target_currency_amount,
    test_conversion_config
};

#[test]
fun test_calculate_usd_currency() {
    let target_decimals: u8 = 9;
    let base_decimals: u8 = 9;
    let pyth_price = 380000000; // SUI price 3.8
    let pyth_decimals: u8 = 8;
    let base_currency_amount = 100 * 1_000_000_000; // 100 SUI

    let config = test_conversion_config(
        target_decimals,
        base_decimals,
        pyth_price,
        pyth_decimals,
    );
    let target_currency_amount = calculate_usd_currency_amount(
        config,
        base_currency_amount,
    );

    assert!(target_currency_amount == 380 * 1_000_000_000, 0); // 380 USDC
}

#[test]
fun test_calculate_usd_currency_usdc() {
    let target_decimals: u8 = 9;
    let base_decimals: u8 = 6;
    let pyth_price = 100000000;
    let pyth_decimals: u8 = 8;
    let base_currency_amount = 100 * 1_000_000; // 100 USDC

    let config = test_conversion_config(
        target_decimals,
        base_decimals,
        pyth_price,
        pyth_decimals,
    );
    let target_currency_amount = calculate_usd_currency_amount(
        config,
        base_currency_amount,
    );

    assert!(target_currency_amount == 100 * 1_000_000_000, 0); // 100 USDC
}

#[test]
fun test_calculate_usd_currency_2() {
    let target_decimals: u8 = 9;
    let base_decimals: u8 = 0; // TOKEN has no decimals
    let pyth_price = 3800; // TOKEN price 3.8
    let pyth_decimals: u8 = 3;
    let base_currency_amount = 100; // 100 TOKEN

    let config = test_conversion_config(
        target_decimals,
        base_decimals,
        pyth_price,
        pyth_decimals,
    );
    let target_currency_amount = calculate_usd_currency_amount(
        config,
        base_currency_amount,
    );

    assert!(target_currency_amount == 380 * 1_000_000_000, 0); // 380 USDC
}

#[test, expected_failure(abort_code = ::margin_trading::oracle::EInvalidPythPrice)]
fun test_calculate_usd_currency_invalid_pyth_price() {
    let target_decimals: u8 = 9;
    let base_decimals: u8 = 6;
    let pyth_price = 0; // Price 0
    let pyth_decimals: u8 = 8;
    let base_currency_amount = 100 * 1_000_000;

    let config = test_conversion_config(
        target_decimals,
        base_decimals,
        pyth_price,
        pyth_decimals,
    );
    calculate_usd_currency_amount(
        config,
        base_currency_amount,
    );
}

#[test]
fun test_calculate_target_currency() {
    let target_decimals: u8 = 9;
    let base_decimals: u8 = 9;
    let pyth_price = 380000000; // SUI price 3.8
    let pyth_decimals: u8 = 8;
    let base_currency_amount = 100 * 1_000_000_000; // 100 USDC

    let config = test_conversion_config(
        target_decimals,
        base_decimals,
        pyth_price,
        pyth_decimals,
    );
    let target_currency_amount = calculate_target_currency_amount(
        config,
        base_currency_amount,
    );

    assert!(target_currency_amount == 26315789474, 1); // 26.315789474 SUI
}

#[test]
fun test_calculate_target_currency_2() {
    let target_decimals: u8 = 0; // TOKEN has no decimals
    let base_decimals: u8 = 9;
    let pyth_price = 3800; // TOKEN price 3.8
    let pyth_decimals: u8 = 3;

    let base_currency_amount = 100 * 1_000_000_000; // 100 USDC

    let config = test_conversion_config(
        target_decimals,
        base_decimals,
        pyth_price,
        pyth_decimals,
    );
    let target_currency_amount = calculate_target_currency_amount(
        config,
        base_currency_amount,
    );

    assert!(target_currency_amount == 27, 1); // 27 TOKEN
}

#[test, expected_failure(abort_code = ::margin_trading::oracle::EInvalidPythPrice)]
fun test_calculate_target_currency_invalid_pyth_price() {
    let target_decimals: u8 = 9;
    let base_decimals: u8 = 9;
    let pyth_price = 0; // Price 0
    let pyth_decimals: u8 = 8;
    let base_currency_amount = 100 * 1_000_000_000;

    let config = test_conversion_config(
        target_decimals,
        base_decimals,
        pyth_price,
        pyth_decimals,
    );
    calculate_target_currency_amount(
        config,
        base_currency_amount,
    );
}
