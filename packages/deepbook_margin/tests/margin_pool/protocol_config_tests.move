// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module deepbook_margin::protocol_config_tests;

use deepbook::math;
use deepbook_margin::{
    margin_constants,
    protocol_config::{Self, ProtocolConfig, MarginPoolConfig, InterestConfig},
    test_constants
};
use std::unit_test::{assert_eq, destroy};

/// Create a test protocol config with default values
public fun create_test_protocol_config(): ProtocolConfig {
    let margin_pool_config = protocol_config::new_margin_pool_config(
        test_constants::supply_cap(),
        test_constants::max_utilization_rate(), // 80%
        test_constants::protocol_spread(), // 10%
        test_constants::min_borrow(),
    );
    let interest_config = protocol_config::new_interest_config(
        test_constants::base_rate(), // 5%
        test_constants::base_slope(), // 10%
        test_constants::optimal_utilization(), // 80%
        test_constants::excess_slope(), // 200%
    );
    protocol_config::new_protocol_config(margin_pool_config, interest_config)
}

/// Helper function to create custom interest config
fun create_custom_interest_config(
    base_rate: u64,
    base_slope: u64,
    optimal_utilization: u64,
    excess_slope: u64,
): InterestConfig {
    protocol_config::new_interest_config(base_rate, base_slope, optimal_utilization, excess_slope)
}

/// Helper function to create custom margin pool config
fun create_custom_margin_pool_config(
    supply_cap: u64,
    max_utilization_rate: u64,
    protocol_spread: u64,
    min_borrow: u64,
): MarginPoolConfig {
    protocol_config::new_margin_pool_config(
        supply_cap,
        max_utilization_rate,
        protocol_spread,
        min_borrow,
    )
}

// ===== Interest Rate Tests =====

#[test]
/// Test interest rate calculation when utilization is below optimal
fun test_interest_rate_below_optimal() {
    let config = create_test_protocol_config();

    // Test at 0% utilization - should be base rate only
    let rate_at_0 = config.interest_rate(0);
    assert_eq!(rate_at_0, test_constants::base_rate()); // 5%

    // Test at 40% utilization (half of optimal 80%)
    // Formula: base_rate + (utilization * base_slope)
    // 5% + (40% * 10%) = 5% + 4% = 9%
    let rate_at_40 = config.interest_rate(400_000_000);
    let expected_40 =
        test_constants::base_rate() + math::mul(400_000_000, test_constants::base_slope());
    assert_eq!(rate_at_40, expected_40);
    assert_eq!(rate_at_40, 90_000_000); // 9%

    // Test at 60% utilization (still below optimal)
    let rate_at_60 = config.interest_rate(600_000_000);
    let expected_60 =
        test_constants::base_rate() + math::mul(600_000_000, test_constants::base_slope());
    assert_eq!(rate_at_60, expected_60);
    assert_eq!(rate_at_60, 110_000_000); // 11%

    destroy(config);
}

#[test]
/// Test interest rate calculation exactly at optimal utilization
fun test_interest_rate_at_optimal() {
    let config = create_test_protocol_config();

    // At 80% utilization (optimal)
    // Formula: base_rate + (optimal_utilization * base_slope)
    // 5% + (80% * 10%) = 5% + 8% = 13%
    let rate_at_optimal = config.interest_rate(test_constants::optimal_utilization());
    let expected =
        test_constants::base_rate() +
        math::mul(test_constants::optimal_utilization(), test_constants::base_slope());
    assert_eq!(rate_at_optimal, expected);
    assert_eq!(rate_at_optimal, 130_000_000); // 13%

    destroy(config);
}

#[test]
/// Test interest rate calculation when utilization is above optimal
fun test_interest_rate_above_optimal() {
    let config = create_test_protocol_config();

    // Test at 90% utilization (10% above optimal)
    // Formula: base_rate + (optimal_utilization * base_slope) + ((utilization - optimal) * excess_slope)
    // 5% + (80% * 10%) + (10% * 200%) = 5% + 8% + 20% = 33%
    let rate_at_90 = config.interest_rate(900_000_000);
    let base_plus_optimal =
        test_constants::base_rate() +
        math::mul(test_constants::optimal_utilization(), test_constants::base_slope());
    let excess = math::mul(100_000_000, test_constants::excess_slope()); // 10% * 200%
    let expected_90 = base_plus_optimal + excess;
    assert_eq!(rate_at_90, expected_90);
    assert_eq!(rate_at_90, 330_000_000); // 33%

    // Test at 100% utilization
    // 5% + (80% * 10%) + (20% * 200%) = 5% + 8% + 40% = 53%
    let rate_at_100 = config.interest_rate(1_000_000_000);
    let excess_100 = math::mul(200_000_000, test_constants::excess_slope()); // 20% * 200%
    let expected_100 = base_plus_optimal + excess_100;
    assert_eq!(rate_at_100, expected_100);
    assert_eq!(rate_at_100, 530_000_000); // 53%

    destroy(config);
}

#[test]
/// Test edge case with zero base rate
fun test_interest_rate_zero_base_rate() {
    let margin_pool_config = create_custom_margin_pool_config(
        test_constants::supply_cap(),
        test_constants::max_utilization_rate(),
        test_constants::protocol_spread(),
        test_constants::min_borrow(),
    );
    let interest_config = create_custom_interest_config(
        0, // Zero base rate
        100_000_000, // 10% base slope
        800_000_000, // 80% optimal
        2_000_000_000, // 200% excess slope
    );
    let config = protocol_config::new_protocol_config(margin_pool_config, interest_config);

    // At 0% utilization - should be 0
    assert_eq!(config.interest_rate(0), 0);

    // At 50% utilization - should be 50% * 10% = 5%
    assert_eq!(config.interest_rate(500_000_000), 50_000_000);

    // At 90% utilization - 80% * 10% + 10% * 200% = 8% + 20% = 28%
    assert_eq!(config.interest_rate(900_000_000), 280_000_000);

    destroy(config);
}

#[test]
/// Test interest rate with different slopes
fun test_interest_rate_different_slopes() {
    let margin_pool_config = create_custom_margin_pool_config(
        test_constants::supply_cap(),
        test_constants::max_utilization_rate(),
        test_constants::protocol_spread(),
        test_constants::min_borrow(),
    );
    let interest_config = create_custom_interest_config(
        20_000_000, // 2% base rate
        50_000_000, // 5% base slope
        600_000_000, // 60% optimal
        3_000_000_000, // 300% excess slope
    );
    let config = protocol_config::new_protocol_config(margin_pool_config, interest_config);

    // At 30% utilization - 2% + (30% * 5%) = 2% + 1.5% = 3.5%
    assert_eq!(config.interest_rate(300_000_000), 35_000_000);

    // At 60% utilization (optimal) - 2% + (60% * 5%) = 2% + 3% = 5%
    assert_eq!(config.interest_rate(600_000_000), 50_000_000);

    // At 80% utilization - 2% + (60% * 5%) + (20% * 300%) = 2% + 3% + 60% = 65%
    assert_eq!(config.interest_rate(800_000_000), 650_000_000);

    destroy(config);
}

#[test]
/// Test calculate_interest_with_borrow precision with small time intervals
fun test_calculate_interest_with_borrow_precision() {
    let config = create_test_protocol_config();
    let year_ms = margin_constants::year_ms();
    let second_ms = 1000; // 1 second
    let minute_ms = 60 * 1000; // 1 minute
    let total_borrow = 1_000_000_000_000; // 1M tokens with 6 decimals

    // Test with high utilization for very short time periods
    let utilization = 950_000_000; // 95% utilization
    let interest_rate = config.interest_rate(utilization);

    // Test for 1 second
    let interest_1_second = config.calculate_interest_with_borrow(
        utilization,
        second_ms,
        total_borrow,
    );
    let expected_1_second = math::mul(
        math::mul(total_borrow, interest_rate),
        math::div(second_ms, year_ms),
    );
    assert_eq!(interest_1_second, expected_1_second);

    // Test for 1 minute
    let interest_1_minute = config.calculate_interest_with_borrow(
        utilization,
        minute_ms,
        total_borrow,
    );
    let expected_1_minute = math::mul(
        math::mul(total_borrow, interest_rate),
        math::div(minute_ms, year_ms),
    );
    assert_eq!(interest_1_minute, expected_1_minute);

    // Verify that 60 seconds equals 1 minute
    let interest_60_seconds = config.calculate_interest_with_borrow(
        utilization,
        60 * second_ms,
        total_borrow,
    );
    assert_eq!(interest_60_seconds, interest_1_minute);

    destroy(config);
}

#[test]
/// Test calculate_interest_with_borrow with exact mathematical equivalence
fun test_calculate_interest_with_borrow_exact() {
    let config = create_test_protocol_config();
    let utilization = 500_000_000; // 50% utilization
    let time_elapsed = 3600000; // 1 hour in ms
    let total_borrow = 1_000_000_000_000; // 1M tokens with 6 decimals
    let interest_rate = config.interest_rate(utilization);

    let interest_result = config.calculate_interest_with_borrow(
        utilization,
        time_elapsed,
        total_borrow,
    );

    // Expected calculation: (total_borrow * interest_rate) * (time_elapsed / year_ms)
    let expected = math::mul(
        math::mul(total_borrow, interest_rate),
        math::div(time_elapsed, margin_constants::year_ms()),
    );

    assert_eq!(interest_result, expected);

    destroy(config);
}

#[test]
/// Test calculate_interest_with_borrow with various time periods
fun test_calculate_interest_with_borrow_time_periods() {
    let config = create_test_protocol_config();
    let utilization = 200_000_000; // 20% utilization
    let total_borrow = 500_000_000_000; // 500K tokens
    let interest_rate = config.interest_rate(utilization);

    // Test different time periods
    let hour_ms = 3600000; // 1 hour
    let day_ms = 86400000; // 1 day
    let week_ms = 604800000; // 1 week

    // Test 1 hour
    let interest_hour = config.calculate_interest_with_borrow(utilization, hour_ms, total_borrow);
    let expected_hour = math::mul(
        math::mul(total_borrow, interest_rate),
        math::div(hour_ms, margin_constants::year_ms()),
    );
    assert_eq!(interest_hour, expected_hour);

    // Test 1 day
    let interest_day = config.calculate_interest_with_borrow(utilization, day_ms, total_borrow);
    let expected_day = math::mul(
        math::mul(total_borrow, interest_rate),
        math::div(day_ms, margin_constants::year_ms()),
    );
    assert_eq!(interest_day, expected_day);

    // Test 1 week
    let interest_week = config.calculate_interest_with_borrow(utilization, week_ms, total_borrow);
    let expected_week = math::mul(
        math::mul(total_borrow, interest_rate),
        math::div(week_ms, margin_constants::year_ms()),
    );
    assert_eq!(interest_week, expected_week);

    // Verify proportional scaling: 24 hours should equal 1 day
    let interest_24_hours = config.calculate_interest_with_borrow(
        utilization,
        24 * hour_ms,
        total_borrow,
    );
    assert_eq!(interest_24_hours, interest_day);

    destroy(config);
}

// ===== Getter Function Tests =====

#[test]
/// Test all getter functions return correct values
fun test_protocol_config_getters() {
    let config = create_test_protocol_config();

    // Test margin pool config getters
    assert_eq!(config.supply_cap(), test_constants::supply_cap());
    assert_eq!(config.max_utilization_rate(), test_constants::max_utilization_rate());
    assert_eq!(config.protocol_spread(), test_constants::protocol_spread());
    assert_eq!(config.min_borrow(), test_constants::min_borrow());

    // Test interest config getters
    assert_eq!(config.base_rate(), test_constants::base_rate());
    assert_eq!(config.base_slope(), test_constants::base_slope());
    assert_eq!(config.optimal_utilization(), test_constants::optimal_utilization());
    assert_eq!(config.excess_slope(), test_constants::excess_slope());

    destroy(config);
}

// ===== Setter Function Tests =====

#[test, expected_failure(abort_code = protocol_config::EInvalidRiskParam)]
/// Test that setting interest config with optimal > max utilization fails
fun test_set_interest_config_invalid_optimal() {
    let mut config = create_test_protocol_config();

    // Try to set optimal utilization higher than max utilization (80%)
    let invalid_interest_config = create_custom_interest_config(
        50_000_000,
        100_000_000,
        900_000_000, // 90% optimal > 80% max utilization
        2_000_000_000,
    );

    config.set_interest_config(invalid_interest_config);
    destroy(config);
}

#[test, expected_failure(abort_code = protocol_config::EInvalidRiskParam)]
/// Test that setting invalid protocol spread fails
fun test_set_margin_pool_config_invalid_spread() {
    let mut config = create_test_protocol_config();

    // Try to set protocol spread > 100%
    let invalid_config = create_custom_margin_pool_config(
        test_constants::supply_cap(),
        test_constants::max_utilization_rate(),
        1_100_000_000, // 110% > 100%
        test_constants::min_borrow(),
    );

    config.set_margin_pool_config(invalid_config);
    destroy(config);
}

#[test, expected_failure(abort_code = protocol_config::EInvalidRiskParam)]
/// Test that setting max utilization > 100% fails
fun test_set_margin_pool_config_invalid_utilization() {
    let mut config = create_test_protocol_config();

    let invalid_config = create_custom_margin_pool_config(
        test_constants::supply_cap(),
        1_100_000_000, // 110%
        test_constants::protocol_spread(),
        test_constants::min_borrow(),
    );

    config.set_margin_pool_config(invalid_config);
    destroy(config);
}

#[test, expected_failure(abort_code = protocol_config::EInvalidRiskParam)]
/// Test that setting max utilization < optimal utilization fails
fun test_set_margin_pool_config_utilization_mismatch() {
    let mut config = create_test_protocol_config();

    // Current optimal utilization is 80%, try to set max to 70%
    let invalid_config = create_custom_margin_pool_config(
        test_constants::supply_cap(),
        700_000_000, // 70% < 80% optimal
        test_constants::protocol_spread(),
        test_constants::min_borrow(),
    );

    config.set_margin_pool_config(invalid_config);
    destroy(config);
}

#[test, expected_failure(abort_code = protocol_config::EInvalidRiskParam)]
/// Test that setting min_borrow below minimum fails
fun test_set_margin_pool_config_invalid_min_borrow() {
    let mut config = create_test_protocol_config();

    // Try to set min_borrow below the minimum allowed
    let invalid_config = create_custom_margin_pool_config(
        test_constants::supply_cap(),
        test_constants::max_utilization_rate(),
        test_constants::protocol_spread(),
        100, // Below MIN_MIN_BORROW (1000)
    );

    config.set_margin_pool_config(invalid_config);
    destroy(config);
}

#[test, expected_failure(abort_code = protocol_config::EInvalidRiskParam)]
/// Test sequential config updates
fun test_sequential_config_updates_violating_constraints() {
    let mut config = create_test_protocol_config();

    // First set optimal utilization to 75%
    let interest_config = create_custom_interest_config(
        50_000_000,
        100_000_000,
        750_000_000, // 75% optimal
        2_000_000_000,
    );
    config.set_interest_config(interest_config);

    // Now try to set max utilization to 70% (less than optimal)
    let invalid_margin_config = create_custom_margin_pool_config(
        test_constants::supply_cap(),
        700_000_000, // 70% < 75% optimal
        test_constants::protocol_spread(),
        test_constants::min_borrow(),
    );

    config.set_margin_pool_config(invalid_margin_config);
    destroy(config);
}

#[test, expected_failure(abort_code = protocol_config::EInvalidRiskParam)]
/// Test that protocol spread maximum
fun test_set_margin_pool_config_spread() {
    let mut config = create_test_protocol_config();

    // Try to set protocol spread to just over 100%
    let invalid_config = create_custom_margin_pool_config(
        test_constants::supply_cap(),
        test_constants::max_utilization_rate(),
        1_000_000_001, // > 100%
        test_constants::min_borrow(),
    );

    config.set_margin_pool_config(invalid_config);
    destroy(config);
}

// ===== Constructor Validation Tests =====

#[test, expected_failure(abort_code = protocol_config::EInvalidRiskParam)]
/// Test that creating margin pool config with protocol_spread > 100% fails
fun test_new_margin_pool_config_invalid_protocol_spread_too_high() {
    let _config = protocol_config::new_margin_pool_config(
        test_constants::supply_cap(),
        test_constants::max_utilization_rate(),
        1_100_000_000, // 110% > 100%
        test_constants::min_borrow(),
    );
    abort 0
}

#[test, expected_failure(abort_code = protocol_config::EInvalidRiskParam)]
/// Test that creating margin pool config with max_utilization_rate > 100% fails
fun test_new_margin_pool_config_invalid_max_utilization_rate() {
    let _config = protocol_config::new_margin_pool_config(
        test_constants::supply_cap(),
        1_100_000_000, // 110% > 100%
        test_constants::protocol_spread(),
        test_constants::min_borrow(),
    );
    abort 0
}

#[test, expected_failure(abort_code = protocol_config::EInvalidRiskParam)]
/// Test that creating margin pool config with min_borrow below minimum fails
fun test_new_margin_pool_config_invalid_min_borrow() {
    let _config = protocol_config::new_margin_pool_config(
        test_constants::supply_cap(),
        test_constants::max_utilization_rate(),
        test_constants::protocol_spread(),
        999, // < MIN_MIN_BORROW (1000)
    );
    abort 0
}

#[test, expected_failure(abort_code = protocol_config::EInvalidRiskParam)]
/// Test that creating margin pool config with protocol_spread > max fails
fun test_new_margin_pool_config_invalid_protocol_spread_above_max() {
    let _config = protocol_config::new_margin_pool_config(
        test_constants::supply_cap(),
        test_constants::max_utilization_rate(),
        201_000_000, // 20.1% > MAX_PROTOCOL_SPREAD (20%)
        test_constants::min_borrow(),
    );
    abort 0
}

#[test, expected_failure(abort_code = protocol_config::EInvalidRiskParam)]
/// Test that creating interest config with optimal_utilization > 100% fails
fun test_new_interest_config_invalid_optimal_utilization() {
    let _config = protocol_config::new_interest_config(
        test_constants::base_rate(),
        test_constants::base_slope(),
        1_100_000_000, // 110% > 100%
        test_constants::excess_slope(),
    );
    abort 0
}

#[test, expected_failure(abort_code = protocol_config::EInvalidRiskParam)]
/// Test that creating protocol config with max_utilization < optimal_utilization fails
fun test_new_protocol_config_invalid_utilization_mismatch() {
    let margin_pool_config = protocol_config::new_margin_pool_config(
        test_constants::supply_cap(),
        700_000_000, // 70% max utilization
        test_constants::protocol_spread(),
        test_constants::min_borrow(),
    );
    let interest_config = protocol_config::new_interest_config(
        test_constants::base_rate(),
        test_constants::base_slope(),
        800_000_000, // 80% optimal > 70% max
        test_constants::excess_slope(),
    );
    let _config = protocol_config::new_protocol_config(margin_pool_config, interest_config);
    abort 0
}

#[test]
/// Test that creating valid configs succeeds
fun test_new_configs_valid() {
    // Create valid margin pool config
    let margin_pool_config = protocol_config::new_margin_pool_config(
        test_constants::supply_cap(),
        test_constants::max_utilization_rate(),
        test_constants::protocol_spread(),
        test_constants::min_borrow(),
    );

    // Create valid interest config
    let interest_config = protocol_config::new_interest_config(
        test_constants::base_rate(),
        test_constants::base_slope(),
        test_constants::optimal_utilization(),
        test_constants::excess_slope(),
    );

    // Create valid protocol config
    let config = protocol_config::new_protocol_config(margin_pool_config, interest_config);

    // Verify values
    assert_eq!(config.supply_cap(), test_constants::supply_cap());
    assert_eq!(config.max_utilization_rate(), test_constants::max_utilization_rate());
    assert_eq!(config.protocol_spread(), test_constants::protocol_spread());
    assert_eq!(config.min_borrow(), test_constants::min_borrow());
    assert_eq!(config.base_rate(), test_constants::base_rate());
    assert_eq!(config.base_slope(), test_constants::base_slope());
    assert_eq!(config.optimal_utilization(), test_constants::optimal_utilization());
    assert_eq!(config.excess_slope(), test_constants::excess_slope());

    destroy(config);
}

#[test]
/// Test edge case: max_utilization exactly equals optimal_utilization (valid)
fun test_new_protocol_config_max_equals_optimal() {
    let margin_pool_config = protocol_config::new_margin_pool_config(
        test_constants::supply_cap(),
        800_000_000, // 80%
        test_constants::protocol_spread(),
        test_constants::min_borrow(),
    );
    let interest_config = protocol_config::new_interest_config(
        test_constants::base_rate(),
        test_constants::base_slope(),
        800_000_000, // 80% - exactly equal
        test_constants::excess_slope(),
    );
    let config = protocol_config::new_protocol_config(margin_pool_config, interest_config);
    destroy(config);
}

#[test]
/// Test edge case: protocol_spread at exactly max allowed (valid)
fun test_new_margin_pool_config_spread_at_max() {
    let config = protocol_config::new_margin_pool_config(
        test_constants::supply_cap(),
        test_constants::max_utilization_rate(),
        200_000_000, // Exactly MAX_PROTOCOL_SPREAD (20%)
        test_constants::min_borrow(),
    );
    // Should succeed
    destroy(config);
}

#[test]
/// Test edge case: min_borrow at exactly minimum allowed (valid)
fun test_new_margin_pool_config_min_borrow_at_min() {
    let config = protocol_config::new_margin_pool_config(
        test_constants::supply_cap(),
        test_constants::max_utilization_rate(),
        test_constants::protocol_spread(),
        1000, // Exactly MIN_MIN_BORROW
    );
    // Should succeed
    destroy(config);
}
