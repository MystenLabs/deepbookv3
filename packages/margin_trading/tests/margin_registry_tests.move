// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module margin_trading::margin_registry_tests;

use margin_trading::margin_constants;
use margin_trading::margin_registry::{Self, MarginRegistry, MarginAdminCap, MaintainerCap};
use margin_trading::test_constants::{Self, USDC, USDT};
use margin_trading::test_helpers::{Self, default_protocol_config};
use sui::clock::Clock;
use sui::test_scenario::{Scenario, return_shared};
use sui::test_utils::destroy;

// === Setup helpers ===

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

// === Test mint_maintainer_cap ===

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

// === Test revoke_maintainer_cap ===

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

// === Test register_deepbook_pool ===

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

// === Test new_pool_config ===

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

// === Test new_pool_config_with_leverage ===

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
