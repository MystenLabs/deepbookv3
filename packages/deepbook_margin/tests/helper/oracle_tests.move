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
use pyth::{i64, price, price_feed, price_identifier, price_info::{Self, PriceInfoObject}};
use std::unit_test::destroy;
use sui::{clock::{Self, Clock}, test_scenario::{Self, Scenario}};

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

    assert!(target_currency_amount == 380 * 1_000_000_000); // 380 USDC
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

    assert!(target_currency_amount == 100 * 1_000_000_000); // 100 USDC
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

    assert!(target_currency_amount == 380 * 1_000_000_000); // 380 USDC
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

    assert!(target_currency_amount == 26315789474); // 26.315789474 SUI
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

    assert!(target_currency_amount == 27); // 27 TOKEN
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
    let pyth_config = create_test_pyth_config(); // max_conf_bps = 1000 (10%)
    registry.add_config(&admin_cap, pyth_config);

    // Create price info with confidence that exceeds 10%
    // Price = $100 (10000000000 with 8 decimals: 100 * 10^8)
    // Max allowed conf = 1000 * 10000000000 / 10_000 = 1_000_000_000
    // We set conf = 1_500_000_000 which is > 10% (15%)
    let price_info = build_pyth_price_info_object(
        &mut scenario,
        test_constants::usdc_price_feed_id(),
        10000000000, // $100 price (100 * 10^8)
        1500000000, // 15% confidence (exceeds 10% threshold)
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
    let pyth_config = create_test_pyth_config(); // max_conf_bps = 1000 (10%)
    registry.add_config(&admin_cap, pyth_config);

    // Create price info with confidence exactly at 10% limit
    // Price = $100 (10000000000 with 8 decimals: 100 * 10^8)
    // Max allowed conf = 1000 * 10000000000 / 10_000 = 1_000_000_000
    // We set conf = 1_000_000_000 which is exactly at 10%
    let price_info = build_pyth_price_info_object(
        &mut scenario,
        test_constants::usdc_price_feed_id(),
        10000000000, // $100 price (100 * 10^8)
        1000000000, // 10% confidence (exactly at threshold)
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
    assert!(usd_price == 100_000_000_000);

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
    let pyth_config = create_test_pyth_config(); // max_conf_bps = 1000 (10%)
    registry.add_config(&admin_cap, pyth_config);

    // Create price info with high confidence
    // Price = $50 (5000000000 with 8 decimals: 50 * 10^8)
    // Max allowed conf = 1000 * 5000000000 / 10_000 = 500_000_000
    // We set conf = 750_000_000 which is 15% (exceeds 10% threshold)
    let price_info = build_pyth_price_info_object(
        &mut scenario,
        test_constants::usdc_price_feed_id(),
        5000000000, // $50 price (50 * 10^8)
        750000000, // 15% confidence (exceeds 10% threshold)
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

/// Helper to build a price info object with separate pyth price and EWMA price
fun build_pyth_price_info_with_ewma(
    scenario: &mut Scenario,
    id: vector<u8>,
    price_value: u64,
    ewma_price_value: u64,
    conf_value: u64,
    exp_value: u64,
    timestamp: u64,
): PriceInfoObject {
    let price_id = price_identifier::from_byte_vec(id);
    let price = price::new(
        i64::new(price_value, false), // positive price
        conf_value,
        i64::new(exp_value, true), // negative exponent
        timestamp,
    );
    let ewma_price = price::new(
        i64::new(ewma_price_value, false), // positive EWMA price
        conf_value,
        i64::new(exp_value, true), // negative exponent
        timestamp,
    );
    let price_feed = price_feed::new(price_id, price, ewma_price);
    let price_info = price_info::new_price_info(
        timestamp - 2, // attestation_time
        timestamp - 1, // arrival_time
        price_feed,
    );
    price_info::new_price_info_object_for_test(price_info, scenario.ctx())
}

#[test, expected_failure(abort_code = ::deepbook_margin::oracle::EInvalidPythPrice)]
fun test_ewma_price_difference_too_high() {
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
    let pyth_config = create_test_pyth_config(); // max_ewma_difference_bps = 1500 (15%)
    registry.add_config(&admin_cap, pyth_config);

    // Create price info where pyth price is 20% higher than EWMA (exceeds 15% threshold)
    // EWMA price = $100 (10000000000 with 8 decimals)
    // Pyth price = $120 (12000000000 with 8 decimals) - 20% higher
    let price_info = build_pyth_price_info_with_ewma(
        &mut scenario,
        test_constants::usdc_price_feed_id(),
        12000000000, // $120 pyth price
        10000000000, // $100 EWMA price
        50000, // 0.05% confidence
        8, // decimals
        clock.timestamp_ms() / 1000,
    );

    // This should fail with EInvalidPythPrice
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

#[test, expected_failure(abort_code = ::deepbook_margin::oracle::EInvalidPythPrice)]
fun test_ewma_price_difference_too_low() {
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
    let pyth_config = create_test_pyth_config(); // max_ewma_difference_bps = 1500 (15%)
    registry.add_config(&admin_cap, pyth_config);

    // Create price info where pyth price is 20% lower than EWMA (exceeds 15% threshold)
    // EWMA price = $100 (10000000000 with 8 decimals)
    // Pyth price = $80 (8000000000 with 8 decimals) - 20% lower
    let price_info = build_pyth_price_info_with_ewma(
        &mut scenario,
        test_constants::usdc_price_feed_id(),
        8000000000, // $80 pyth price
        10000000000, // $100 EWMA price
        50000, // 0.05% confidence
        8, // decimals
        clock.timestamp_ms() / 1000,
    );

    // This should fail with EInvalidPythPrice
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
fun test_ewma_price_difference_at_upper_limit() {
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
    let pyth_config = create_test_pyth_config(); // max_ewma_difference_bps = 1500 (15%)
    registry.add_config(&admin_cap, pyth_config);

    // Create price info where pyth price is exactly 15% higher than EWMA
    // EWMA price = $100 (10000000000 with 8 decimals)
    // Pyth price = $115 (11500000000 with 8 decimals) - exactly 15% higher
    let price_info = build_pyth_price_info_with_ewma(
        &mut scenario,
        test_constants::usdc_price_feed_id(),
        11500000000, // $115 pyth price
        10000000000, // $100 EWMA price
        50000, // 0.05% confidence
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

    // 1 USDC at $115 = $115 (with 9 decimals for USD representation)
    assert!(usd_price == 115_000_000_000);

    destroy(admin_cap);
    destroy(price_info);
    test_scenario::return_shared(registry);
    test_scenario::return_shared(clock);
    scenario.end();
}

#[test]
fun test_ewma_price_difference_at_lower_limit() {
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
    let pyth_config = create_test_pyth_config(); // max_ewma_difference_bps = 1500 (15%)
    registry.add_config(&admin_cap, pyth_config);

    // Create price info where pyth price is exactly 15% lower than EWMA
    // EWMA price = $100 (10000000000 with 8 decimals)
    // Pyth price = $85 (8500000000 with 8 decimals) - exactly 15% lower
    let price_info = build_pyth_price_info_with_ewma(
        &mut scenario,
        test_constants::usdc_price_feed_id(),
        8500000000, // $85 pyth price
        10000000000, // $100 EWMA price
        50000, // 0.05% confidence
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

    // 1 USDC at $85 = $85 (with 9 decimals for USD representation)
    assert!(usd_price == 85_000_000_000);

    destroy(admin_cap);
    destroy(price_info);
    test_scenario::return_shared(registry);
    test_scenario::return_shared(clock);
    scenario.end();
}

#[test]
fun test_confidence_check_with_high_price_no_overflow() {
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
    let pyth_config = create_test_pyth_config(); // max_conf_bps = 1000 (10%)
    registry.add_config(&admin_cap, pyth_config);

    // Test with very high price that could overflow with old u64 multiplication
    // Price = $1,000,000 (100000000000000 with 8 decimals: 1M * 10^8)
    // With u64, max_conf_bps * pyth_price = 1000 * 100000000000000 = 10^17 (safe)
    // Max allowed conf = 1000 * 100000000000000 / 10_000 = 10_000_000_000_000
    // We set conf = 5_000_000_000_000 which is 5% (within 10% threshold)
    let price_info = build_pyth_price_info_object(
        &mut scenario,
        test_constants::usdc_price_feed_id(),
        100000000000000, // $1M price (1M * 10^8)
        5000000000000, // 5% confidence
        8, // decimals
        clock.timestamp_ms() / 1000,
    );

    // This should succeed with u128 casting preventing overflow
    let usd_price = calculate_usd_price<USDC>(
        &price_info,
        &registry,
        1000000, // 1 USDC (6 decimals)
        &clock,
    );

    // 1 USDC at $1M = $1M (with 9 decimals for USD representation)
    assert!(usd_price == 1_000_000_000_000_000);

    destroy(admin_cap);
    destroy(price_info);
    test_scenario::return_shared(registry);
    test_scenario::return_shared(clock);
    scenario.end();
}

#[test]
fun test_ewma_check_with_high_price_no_overflow() {
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
    let pyth_config = create_test_pyth_config(); // max_ewma_difference_bps = 1500 (15%)
    registry.add_config(&admin_cap, pyth_config);

    // Test with very high price that could overflow with old u64 multiplication
    // EWMA price = $1,000,000 (100000000000000 with 8 decimals)
    // With u64: ewma_price * (10_000 + 1500) = 100000000000000 * 11500
    // = 1.15 * 10^18 which exceeds u64 max (~1.8 * 10^19) but is close
    // Pyth price = $1,100,000 (110000000000000) - 10% higher (within 15%)
    let price_info = build_pyth_price_info_with_ewma(
        &mut scenario,
        test_constants::usdc_price_feed_id(),
        110000000000000, // $1.1M pyth price
        100000000000000, // $1M EWMA price
        50000, // 0.005% confidence
        8, // decimals
        clock.timestamp_ms() / 1000,
    );

    // This should succeed with u128 casting preventing overflow
    let usd_price = calculate_usd_price<USDC>(
        &price_info,
        &registry,
        1000000, // 1 USDC (6 decimals)
        &clock,
    );

    // 1 USDC at $1.1M = $1.1M (with 9 decimals for USD representation)
    assert!(usd_price == 1_100_000_000_000_000);

    destroy(admin_cap);
    destroy(price_info);
    test_scenario::return_shared(registry);
    test_scenario::return_shared(clock);
    scenario.end();
}
