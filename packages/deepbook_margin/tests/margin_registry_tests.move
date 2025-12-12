// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module deepbook_margin::margin_registry_tests;

use deepbook_margin::{
    margin_constants,
    margin_registry::{Self, MarginRegistry, MarginAdminCap, MaintainerCap},
    oracle,
    test_constants::{Self, USDC, USDT},
    test_helpers::{Self, default_protocol_config}
};
use std::unit_test::destroy;
use sui::{clock::Clock, test_scenario::{Scenario, return_shared}};

fun setup_test_with_margin_pools(): (Scenario, Clock, MarginAdminCap, MaintainerCap, ID, ID) {
    let (mut scenario, admin_cap) = test_helpers::setup_test();

    scenario.next_tx(test_constants::admin());
    let mut registry = scenario.take_shared<MarginRegistry>();
    let clock = scenario.take_shared<Clock>();
    let maintainer_cap = margin_registry::mint_maintainer_cap(
        &mut registry,
        &admin_cap,
        &clock,
        scenario.ctx(),
    );
    return_shared(registry);

    // Create margin pools for USDC and USDT
    let protocol_config = default_protocol_config();
    let usdc_pool_id = test_helpers::create_margin_pool<USDC>(
        &mut scenario,
        &maintainer_cap,
        protocol_config,
        &clock,
    );
    let usdt_pool_id = test_helpers::create_margin_pool<USDT>(
        &mut scenario,
        &maintainer_cap,
        protocol_config,
        &clock,
    );

    (scenario, clock, admin_cap, maintainer_cap, usdc_pool_id, usdt_pool_id)
}

fun create_mock_deepbook_pool_id(): ID {
    sui::object::id_from_address(@0x1234567890abcdef)
}

fun cleanup_test(
    registry: MarginRegistry,
    admin_cap: MarginAdminCap,
    maintainer_cap: MaintainerCap,
    clock: Clock,
    scenario: Scenario,
) {
    destroy(registry);
    destroy(admin_cap);
    destroy(maintainer_cap);
    destroy(clock);
    scenario.end();
}

#[test]
fun test_mint_maintainer_cap_ok() {
    let (
        mut scenario,
        clock,
        admin_cap,
        maintainer_cap,
        _usdc_pool_id,
        _usdt_pool_id,
    ) = setup_test_with_margin_pools();

    scenario.next_tx(test_constants::admin());
    let mut registry = scenario.take_shared<MarginRegistry>();

    // Mint a new maintainer cap
    let new_maintainer_cap = registry.mint_maintainer_cap(&admin_cap, &clock, scenario.ctx());

    // Verify cap was created successfully (just ensure it doesn't abort)
    destroy(new_maintainer_cap);

    cleanup_test(registry, admin_cap, maintainer_cap, clock, scenario);
}

#[test]
fun test_revoke_maintainer_cap_ok() {
    let (
        mut scenario,
        clock,
        admin_cap,
        maintainer_cap,
        _usdc_pool_id,
        _usdt_pool_id,
    ) = setup_test_with_margin_pools();

    scenario.next_tx(test_constants::admin());
    let mut registry = scenario.take_shared<MarginRegistry>();
    let maintainer_cap_id = sui::object::id(&maintainer_cap);

    // Revoke the maintainer cap
    registry.revoke_maintainer_cap(&admin_cap, maintainer_cap_id, &clock);

    cleanup_test(registry, admin_cap, maintainer_cap, clock, scenario);
}

#[test, expected_failure(abort_code = margin_registry::EMaintainerCapNotValid)]
fun test_revoke_random_cap_should_fail() {
    let (
        mut scenario,
        clock,
        admin_cap,
        maintainer_cap,
        _usdc_pool_id,
        _usdt_pool_id,
    ) = setup_test_with_margin_pools();

    scenario.next_tx(test_constants::admin());
    let mut registry = scenario.take_shared<MarginRegistry>();

    // Try to revoke a random ID that was never a maintainer cap
    let random_id = sui::object::id_from_address(@0x123);
    registry.revoke_maintainer_cap(&admin_cap, random_id, &clock);

    cleanup_test(registry, admin_cap, maintainer_cap, clock, scenario);
}

#[test]
fun test_register_deepbook_pool_ok() {
    let (
        mut scenario,
        clock,
        admin_cap,
        maintainer_cap,
        _usdc_pool_id,
        _usdt_pool_id,
    ) = setup_test_with_margin_pools();

    scenario.next_tx(test_constants::admin());
    let registry = scenario.take_shared<MarginRegistry>();
    let _mock_pool_id = create_mock_deepbook_pool_id();

    // Create a valid pool config
    let pool_config = registry.new_pool_config<USDC, USDT>(
        2_000_000_000, // min_withdraw_risk_ratio: 2.0
        1_500_000_000, // min_borrow_risk_ratio: 1.5
        1_100_000_000, // liquidation_risk_ratio: 1.1
        1_250_000_000, // target_liquidation_risk_ratio: 1.25
        20_000_000, // user_liquidation_reward: 2%
        30_000_000, // pool_liquidation_reward: 3%
    );

    // Register the pool using mock pool (we can't create a real Pool object easily)
    // This test verifies the pool config creation works
    destroy(pool_config);

    cleanup_test(registry, admin_cap, maintainer_cap, clock, scenario);
}

#[test]
fun test_new_pool_config_ok() {
    let (
        mut scenario,
        clock,
        admin_cap,
        maintainer_cap,
        _usdc_pool_id,
        _usdt_pool_id,
    ) = setup_test_with_margin_pools();

    scenario.next_tx(test_constants::admin());
    let registry = scenario.take_shared<MarginRegistry>();

    // Create a valid pool config
    let pool_config = registry.new_pool_config<USDC, USDT>(
        2_000_000_000, // min_withdraw_risk_ratio: 2.0
        1_500_000_000, // min_borrow_risk_ratio: 1.5
        1_100_000_000, // liquidation_risk_ratio: 1.1
        1_250_000_000, // target_liquidation_risk_ratio: 1.25
        20_000_000, // user_liquidation_reward: 2%
        30_000_000, // pool_liquidation_reward: 3%
    );

    // Verify config was created (it should not abort)
    destroy(pool_config);

    cleanup_test(registry, admin_cap, maintainer_cap, clock, scenario);
}

// Test all the invalid parameter scenarios for new_pool_config
#[test, expected_failure(abort_code = margin_registry::EInvalidRiskParam)]
fun test_new_pool_config_invalid_borrow_vs_withdraw() {
    let (
        mut scenario,
        clock,
        admin_cap,
        maintainer_cap,
        _usdc_pool_id,
        _usdt_pool_id,
    ) = setup_test_with_margin_pools();

    scenario.next_tx(test_constants::admin());
    let registry = scenario.take_shared<MarginRegistry>();

    // Invalid: min_borrow_risk_ratio >= min_withdraw_risk_ratio
    let pool_config = registry.new_pool_config<USDC, USDT>(
        1_500_000_000, // min_withdraw_risk_ratio: 1.5
        1_500_000_000, // min_borrow_risk_ratio: 1.5 (should be < withdraw)
        1_100_000_000,
        1_250_000_000,
        20_000_000,
        30_000_000,
    );

    destroy(pool_config);
    cleanup_test(registry, admin_cap, maintainer_cap, clock, scenario);
}

#[test, expected_failure(abort_code = margin_registry::EInvalidRiskParam)]
fun test_new_pool_config_invalid_liquidation_vs_borrow() {
    let (
        mut scenario,
        clock,
        admin_cap,
        maintainer_cap,
        _usdc_pool_id,
        _usdt_pool_id,
    ) = setup_test_with_margin_pools();

    scenario.next_tx(test_constants::admin());
    let registry = scenario.take_shared<MarginRegistry>();

    // Invalid: liquidation_risk_ratio >= min_borrow_risk_ratio
    let pool_config = registry.new_pool_config<USDC, USDT>(
        2_000_000_000,
        1_500_000_000,
        1_500_000_000, // liquidation_risk_ratio: 1.5 (should be < borrow)
        1_600_000_000,
        20_000_000,
        30_000_000,
    );

    destroy(pool_config);
    cleanup_test(registry, admin_cap, maintainer_cap, clock, scenario);
}

#[test, expected_failure(abort_code = margin_registry::EInvalidRiskParam)]
fun test_new_pool_config_invalid_liquidation_vs_target() {
    let (
        mut scenario,
        clock,
        admin_cap,
        maintainer_cap,
        _usdc_pool_id,
        _usdt_pool_id,
    ) = setup_test_with_margin_pools();

    scenario.next_tx(test_constants::admin());
    let registry = scenario.take_shared<MarginRegistry>();

    // Invalid: liquidation_risk_ratio >= target_liquidation_risk_ratio
    let pool_config = registry.new_pool_config<USDC, USDT>(
        2_000_000_000,
        1_500_000_000,
        1_200_000_000, // liquidation_risk_ratio: 1.2
        1_200_000_000, // target_liquidation_risk_ratio: 1.2 (should be > liquidation)
        20_000_000,
        30_000_000,
    );

    destroy(pool_config);
    cleanup_test(registry, admin_cap, maintainer_cap, clock, scenario);
}

#[test, expected_failure(abort_code = margin_registry::EInvalidRiskParam)]
fun test_new_pool_config_liquidation_too_low() {
    let (
        mut scenario,
        clock,
        admin_cap,
        maintainer_cap,
        _usdc_pool_id,
        _usdt_pool_id,
    ) = setup_test_with_margin_pools();

    scenario.next_tx(test_constants::admin());
    let registry = scenario.take_shared<MarginRegistry>();

    // Invalid: liquidation_risk_ratio < constants::float_scaling() (1.0)
    let pool_config = registry.new_pool_config<USDC, USDT>(
        2_000_000_000,
        1_500_000_000,
        900_000_000, // liquidation_risk_ratio: 0.9 (should be >= 1.0)
        1_250_000_000,
        20_000_000,
        30_000_000,
    );

    destroy(pool_config);
    cleanup_test(registry, admin_cap, maintainer_cap, clock, scenario);
}

#[test, expected_failure(abort_code = margin_registry::EInvalidRiskParam)]
fun test_new_pool_config_user_reward_too_high() {
    let (
        mut scenario,
        clock,
        admin_cap,
        maintainer_cap,
        _usdc_pool_id,
        _usdt_pool_id,
    ) = setup_test_with_margin_pools();

    scenario.next_tx(test_constants::admin());
    let registry = scenario.take_shared<MarginRegistry>();

    // Invalid: user_liquidation_reward > constants::float_scaling() (100%)
    let pool_config = registry.new_pool_config<USDC, USDT>(
        2_000_000_000,
        1_500_000_000,
        1_100_000_000,
        1_250_000_000,
        1_100_000_000, // user_liquidation_reward: 110% (should be <= 100%)
        30_000_000,
    );

    destroy(pool_config);
    cleanup_test(registry, admin_cap, maintainer_cap, clock, scenario);
}

#[test, expected_failure(abort_code = margin_registry::EInvalidRiskParam)]
fun test_new_pool_config_pool_reward_too_high() {
    let (
        mut scenario,
        clock,
        admin_cap,
        maintainer_cap,
        _usdc_pool_id,
        _usdt_pool_id,
    ) = setup_test_with_margin_pools();

    scenario.next_tx(test_constants::admin());
    let registry = scenario.take_shared<MarginRegistry>();

    // Invalid: pool_liquidation_reward > constants::float_scaling() (100%)
    let pool_config = registry.new_pool_config<USDC, USDT>(
        2_000_000_000,
        1_500_000_000,
        1_100_000_000,
        1_250_000_000,
        20_000_000,
        1_100_000_000, // pool_liquidation_reward: 110% (should be <= 100%)
    );

    destroy(pool_config);
    cleanup_test(registry, admin_cap, maintainer_cap, clock, scenario);
}

#[test, expected_failure(abort_code = margin_registry::EInvalidRiskParam)]
fun test_new_pool_config_combined_rewards_too_high() {
    let (
        mut scenario,
        clock,
        admin_cap,
        maintainer_cap,
        _usdc_pool_id,
        _usdt_pool_id,
    ) = setup_test_with_margin_pools();

    scenario.next_tx(test_constants::admin());
    let registry = scenario.take_shared<MarginRegistry>();

    // Invalid: user_liquidation_reward + pool_liquidation_reward > 100%
    let pool_config = registry.new_pool_config<USDC, USDT>(
        2_000_000_000,
        1_500_000_000,
        1_100_000_000,
        1_250_000_000,
        600_000_000, // user_liquidation_reward: 60%
        500_000_000, // pool_liquidation_reward: 50% (total 110% > 100%)
    );

    destroy(pool_config);
    cleanup_test(registry, admin_cap, maintainer_cap, clock, scenario);
}

#[test, expected_failure(abort_code = margin_registry::EInvalidRiskParam)]
fun test_new_pool_config_target_too_low() {
    let (
        mut scenario,
        clock,
        admin_cap,
        maintainer_cap,
        _usdc_pool_id,
        _usdt_pool_id,
    ) = setup_test_with_margin_pools();

    scenario.next_tx(test_constants::admin());
    let registry = scenario.take_shared<MarginRegistry>();

    // Invalid: target_liquidation_risk_ratio <= 1.0 + user_reward + pool_reward
    let pool_config = registry.new_pool_config<USDC, USDT>(
        2_000_000_000,
        1_500_000_000,
        1_100_000_000,
        1_040_000_000, // target: 1.04, but 1.0 + 0.02 + 0.03 = 1.05, so target should be > 1.05
        20_000_000,
        30_000_000,
    );

    destroy(pool_config);
    cleanup_test(registry, admin_cap, maintainer_cap, clock, scenario);
}

#[test]
fun test_new_pool_config_with_leverage_ok() {
    let (
        mut scenario,
        clock,
        admin_cap,
        maintainer_cap,
        _usdc_pool_id,
        _usdt_pool_id,
    ) = setup_test_with_margin_pools();

    scenario.next_tx(test_constants::admin());
    let registry = scenario.take_shared<MarginRegistry>();

    // Create a valid pool config with 5x leverage
    let pool_config = registry.new_pool_config_with_leverage<USDC, USDT>(5_000_000_000);

    // Verify config was created (it should not abort)
    destroy(pool_config);

    cleanup_test(registry, admin_cap, maintainer_cap, clock, scenario);
}

#[test, expected_failure(abort_code = margin_registry::EInvalidRiskParam)]
fun test_new_pool_config_with_leverage_too_low() {
    let (
        mut scenario,
        clock,
        admin_cap,
        maintainer_cap,
        _usdc_pool_id,
        _usdt_pool_id,
    ) = setup_test_with_margin_pools();

    scenario.next_tx(test_constants::admin());
    let registry = scenario.take_shared<MarginRegistry>();

    // Invalid: leverage <= margin_constants::min_leverage()
    let pool_config = registry.new_pool_config_with_leverage<USDC, USDT>(
        margin_constants::min_leverage(), // Should be > min_leverage
    );

    destroy(pool_config);
    cleanup_test(registry, admin_cap, maintainer_cap, clock, scenario);
}

#[test, expected_failure(abort_code = margin_registry::EInvalidRiskParam)]
fun test_new_pool_config_with_leverage_too_high() {
    let (
        mut scenario,
        clock,
        admin_cap,
        maintainer_cap,
        _usdc_pool_id,
        _usdt_pool_id,
    ) = setup_test_with_margin_pools();

    scenario.next_tx(test_constants::admin());
    let registry = scenario.take_shared<MarginRegistry>();

    // Invalid: leverage > margin_constants::max_leverage()
    let pool_config = registry.new_pool_config_with_leverage<USDC, USDT>(
        margin_constants::max_leverage() + 1, // Should be <= max_leverage
    );

    destroy(pool_config);
    cleanup_test(registry, admin_cap, maintainer_cap, clock, scenario);
}

#[test, expected_failure(abort_code = pyth::pyth::E_STALE_PRICE_UPDATE)]
fun test_oracle_max_age_exceeded() {
    let (
        mut scenario,
        mut clock,
        admin_cap,
        maintainer_cap,
        _usdc_pool_id,
        _usdt_pool_id,
    ) = setup_test_with_margin_pools();

    scenario.next_tx(test_constants::admin());
    let mut registry = scenario.take_shared<MarginRegistry>();

    let pyth_config = test_helpers::create_test_pyth_config();
    registry.add_config<oracle::PythConfig>(&admin_cap, pyth_config);

    let current_time_ms = 10000000; // 10 million milliseconds = 10,000 seconds
    clock.set_for_testing(current_time_ms);

    // Create a price info object with timestamp that's older than 60 seconds
    let old_timestamp_seconds = (current_time_ms / 1000) - 65; // 65 seconds ago

    let old_price_info = test_helpers::build_pyth_price_info_object(
        &mut scenario,
        test_constants::usdc_price_feed_id(),
        1 * test_constants::pyth_multiplier(), // $1.00 price
        50000, // confidence
        test_constants::pyth_decimals(), // exponent
        old_timestamp_seconds, // timestamp 70 seconds ago
    );

    // This should fail with Pyth error because price is older than 60 seconds
    let _usd_value = oracle::calculate_usd_price<USDC>(
        &old_price_info,
        &registry,
        1000000, // 1 USDC (6 decimals)
        &clock,
    );

    destroy(old_price_info);
    cleanup_test(registry, admin_cap, maintainer_cap, clock, scenario);
}

#[test]
fun test_oracle_max_age_within_limit() {
    let (
        mut scenario,
        mut clock,
        admin_cap,
        maintainer_cap,
        _usdc_pool_id,
        _usdt_pool_id,
    ) = setup_test_with_margin_pools();

    scenario.next_tx(test_constants::admin());
    let mut registry = scenario.take_shared<MarginRegistry>();

    let pyth_config = test_helpers::create_test_pyth_config();
    registry.add_config<oracle::PythConfig>(&admin_cap, pyth_config);

    let current_time_ms = 10000000; // 10 million milliseconds = 10,000 seconds
    clock.set_for_testing(current_time_ms);

    // Create a price info object with recent timestamp (30 seconds ago, within 60 second limit)
    let recent_timestamp_seconds = (current_time_ms / 1000) - 30; // 30 seconds ago

    let recent_price_info = test_helpers::build_pyth_price_info_object(
        &mut scenario,
        test_constants::usdc_price_feed_id(),
        1 * test_constants::pyth_multiplier(), // $1.00 price
        50000, // confidence
        test_constants::pyth_decimals(), // exponent
        recent_timestamp_seconds, // timestamp 30 seconds ago
    );

    // This should succeed because price is within 60 second limit
    let usd_value = oracle::calculate_usd_price<USDC>(
        &recent_price_info,
        &registry,
        1000000, // 1 USDC (6 decimals)
        &clock,
    );
    assert!(usd_value > 900_000_000 && usd_value < 1_100_000_000);

    destroy(recent_price_info);
    cleanup_test(registry, admin_cap, maintainer_cap, clock, scenario);
}

#[test]
fun test_disable_version_with_pause_cap_ok() {
    let (
        mut scenario,
        clock,
        admin_cap,
        maintainer_cap,
        _usdc_pool_id,
        _usdt_pool_id,
    ) = setup_test_with_margin_pools();

    scenario.next_tx(test_constants::admin());
    let mut registry = scenario.take_shared<MarginRegistry>();

    // Mint a pause cap
    let pause_cap = registry.mint_pause_cap(&admin_cap, &clock, scenario.ctx());

    // Enable a new version so we can disable it
    let new_version = margin_constants::margin_version() + 1;
    registry.enable_version(new_version, &admin_cap);

    // Should succeed: disable version with valid pause cap
    registry.disable_version_pause_cap(new_version, &pause_cap);

    destroy(pause_cap);
    cleanup_test(registry, admin_cap, maintainer_cap, clock, scenario);
}

#[test, expected_failure(abort_code = margin_registry::EPauseCapNotValid)]
fun test_disable_version_with_revoked_pause_cap_fails() {
    let (
        mut scenario,
        clock,
        admin_cap,
        maintainer_cap,
        _usdc_pool_id,
        _usdt_pool_id,
    ) = setup_test_with_margin_pools();

    scenario.next_tx(test_constants::admin());
    let mut registry = scenario.take_shared<MarginRegistry>();

    // Mint a pause cap
    let pause_cap = registry.mint_pause_cap(&admin_cap, &clock, scenario.ctx());
    let pause_cap_id = sui::object::id(&pause_cap);

    // Enable a new version so we can disable it
    let new_version = margin_constants::margin_version() + 1;
    registry.enable_version(new_version, &admin_cap);

    // First disable succeeds with valid pause cap
    registry.disable_version_pause_cap(new_version, &pause_cap);

    // Re-enable the version so we can try to disable it again
    registry.enable_version(new_version, &admin_cap);

    // Revoke the pause cap
    registry.revoke_pause_cap(&admin_cap, &clock, pause_cap_id);

    // Should fail: trying to use a revoked pause cap
    registry.disable_version_pause_cap(new_version, &pause_cap);

    destroy(pause_cap);
    cleanup_test(registry, admin_cap, maintainer_cap, clock, scenario);
}
