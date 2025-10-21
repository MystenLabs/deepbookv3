// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module deepbook_margin::oracle_tests;

use deepbook_margin::{
    margin_registry::{Self, MarginRegistry},
    oracle::{
        calculate_usd_currency_amount,
        calculate_target_currency_amount,
        calculate_usd_price,
        calculate_target_amount,
        test_conversion_config
    },
    test_constants::{Self, USDC},
    test_helpers::{build_pyth_price_info_object, create_test_pyth_config}
};
use sui::{clock::{Self, Clock}, test_scenario, test_utils::destroy};

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

#[test, expected_failure(abort_code = ::deepbook_margin::oracle::EInvalidPythPrice)]
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

#[test, expected_failure(abort_code = ::deepbook_margin::oracle::EInvalidPythPrice)]
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

#[test, expected_failure(abort_code = ::deepbook_margin::oracle::EInvalidPythPriceConf)]
fun test_calculate_usd_price_invalid_confidence_too_high() {
    let mut scenario = test_scenario::begin(test_constants::admin());

    // Setup registry and clock
    scenario.next_tx(test_constants::admin());
    let admin_cap = margin_registry::new_for_testing(scenario.ctx());
    let mut clock = clock::create_for_testing(scenario.ctx());
    clock.set_for_testing(1000000);
    clock.share_for_testing();

    scenario.next_tx(test_constants::admin());
    let mut registry = scenario.take_shared<MarginRegistry>();
    let clock = scenario.take_shared<Clock>();
    let pyth_config = create_test_pyth_config(); // max_conf_bps = 100 (1%)
    registry.add_config(&admin_cap, pyth_config);

    // Create price info with confidence that exceeds 1%
    // Price = $100 (10000000000 with 8 decimals: 100 * 10^8)
    // Max allowed conf = 100 * 10000000000 / 10_000 = 100_000_000
    // We set conf = 150_000_000 which is > 1% (1.5%)
    let price_info = build_pyth_price_info_object(
        &mut scenario,
        test_constants::usdc_price_feed_id(),
        10000000000, // $100 price (100 * 10^8)
        150000000, // 1.5% confidence (exceeds 1% threshold)
        8, // decimals
        clock.timestamp_ms() / 1000,
    );

    // This should fail with EInvalidPythPriceConf
    calculate_usd_price<USDC>(
        &price_info,
        &registry,
        1000000, // 1 USDC (6 decimals)
        &clock,
    );

    destroy(admin_cap);
    destroy(price_info);
    test_scenario::return_shared(registry);
    test_scenario::return_shared(clock);
    scenario.end();
}

#[test]
fun test_calculate_usd_price_valid_confidence_at_limit() {
    let mut scenario = test_scenario::begin(test_constants::admin());

    // Setup registry and clock
    scenario.next_tx(test_constants::admin());
    let admin_cap = margin_registry::new_for_testing(scenario.ctx());
    let mut clock = clock::create_for_testing(scenario.ctx());
    clock.set_for_testing(1000000);
    clock.share_for_testing();

    scenario.next_tx(test_constants::admin());
    let mut registry = scenario.take_shared<MarginRegistry>();
    let clock = scenario.take_shared<Clock>();
    let pyth_config = create_test_pyth_config(); // max_conf_bps = 100 (1%)
    registry.add_config(&admin_cap, pyth_config);

    // Create price info with confidence exactly at 1% limit
    // Price = $100 (10000000000 with 8 decimals: 100 * 10^8)
    // Max allowed conf = 100 * 10000000000 / 10_000 = 100_000_000
    // We set conf = 100_000_000 which is exactly at 1%
    let price_info = build_pyth_price_info_object(
        &mut scenario,
        test_constants::usdc_price_feed_id(),
        10000000000, // $100 price (100 * 10^8)
        100000000, // 1% confidence (exactly at threshold)
        8, // decimals
        clock.timestamp_ms() / 1000,
    );

    // This should succeed
    let usd_price = calculate_usd_price<USDC>(
        &price_info,
        &registry,
        1000000, // 1 USDC (6 decimals)
        &clock,
    );

    // 1 USDC at $100 = $100 (with 9 decimals for USD representation)
    assert!(usd_price == 100_000_000_000, 0);

    destroy(admin_cap);
    destroy(price_info);
    test_scenario::return_shared(registry);
    test_scenario::return_shared(clock);
    scenario.end();
}

#[test, expected_failure(abort_code = ::deepbook_margin::oracle::EInvalidPythPriceConf)]
fun test_calculate_target_amount_invalid_confidence() {
    let mut scenario = test_scenario::begin(test_constants::admin());

    // Setup registry and clock
    scenario.next_tx(test_constants::admin());
    let admin_cap = margin_registry::new_for_testing(scenario.ctx());
    let mut clock = clock::create_for_testing(scenario.ctx());
    clock.set_for_testing(1000000);
    clock.share_for_testing();

    scenario.next_tx(test_constants::admin());
    let mut registry = scenario.take_shared<MarginRegistry>();
    let clock = scenario.take_shared<Clock>();
    let pyth_config = create_test_pyth_config(); // max_conf_bps = 100 (1%)
    registry.add_config(&admin_cap, pyth_config);

    // Create price info with high confidence
    // Price = $50 (5000000000 with 8 decimals: 50 * 10^8)
    // Max allowed conf = 100 * 5000000000 / 10_000 = 50_000_000
    // We set conf = 200_000_000 which is 4% (exceeds 1% threshold)
    let price_info = build_pyth_price_info_object(
        &mut scenario,
        test_constants::usdc_price_feed_id(),
        5000000000, // $50 price (50 * 10^8)
        200000000, // 4% confidence (exceeds 1% threshold)
        8, // decimals
        clock.timestamp_ms() / 1000,
    );

    // This should fail with EInvalidPythPriceConf
    calculate_target_amount<USDC>(
        &price_info,
        &registry,
        100_000_000_000, // $100 USD (9 decimals)
        &clock,
    );

    destroy(admin_cap);
    destroy(price_info);
    test_scenario::return_shared(registry);
    test_scenario::return_shared(clock);
    scenario.end();
}
