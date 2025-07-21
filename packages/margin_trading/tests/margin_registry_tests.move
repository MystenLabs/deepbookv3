// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module margin_trading::margin_registry_tests;

use margin_trading::margin_registry::{Self, MarginRegistry};
use sui::{clock, sui::SUI, test_scenario::{Scenario, begin, end, return_shared}, test_utils};

public struct USDC has store {}
public struct USDT has store {}

const OWNER: address = @0x1;

#[test]
fun test_update_risk_params_ok() {
    let min_withdraw_risk_ratio = 2_000_000_000; // 2
    let min_borrow_risk_ratio = 1_250_000_000; // 1.25
    let liquidation_risk_ratio = 1_100_000_000; // 1.10
    let target_liquidation_risk_ratio = 1_250_000_000; // 1.25
    let user_liquidation_reward = 10_000_000; // 1%
    let pool_liquidation_reward = 40_000_000; // 4%

    let mut test = begin(OWNER);
    let registry_id = setup_test(OWNER, &mut test);

    test.next_tx(OWNER);
    let mut registry = test.take_shared_by_id<MarginRegistry>(registry_id);
    let admin_cap = margin_registry::get_margin_admin_cap_for_testing(test.ctx());

    let risk_params = margin_registry::new_risk_params(
        min_withdraw_risk_ratio,
        min_borrow_risk_ratio,
        liquidation_risk_ratio,
        target_liquidation_risk_ratio,
        user_liquidation_reward,
        pool_liquidation_reward,
    );

    margin_registry::add_margin_pair<SUI, USDC>(&mut registry, risk_params, &admin_cap);

    // Liquidation risk ratio is decreased to 1.05
    let liquidation_risk_ratio = 1_050_000_000; // 1.05

    // Min borrow risk ratio is increased to 1.5
    let min_borrow_risk_ratio = 1_500_000_000; // 1.5

    let new_risk_params = margin_registry::new_risk_params(
        min_withdraw_risk_ratio,
        min_borrow_risk_ratio,
        liquidation_risk_ratio,
        target_liquidation_risk_ratio,
        user_liquidation_reward,
        pool_liquidation_reward,
    );
    margin_registry::update_risk_params<SUI, USDC>(
        &mut registry,
        new_risk_params,
        &admin_cap,
    );

    assert!(margin_registry::margin_pair_allowed<SUI, USDC>(&registry) == true, 0);
    assert!(margin_registry::margin_pair_allowed<SUI, USDT>(&registry) == false, 0);

    return_shared(registry);
    test_utils::destroy(admin_cap);

    end(test);
}

#[test, expected_failure(abort_code = ::margin_trading::margin_registry::EPairNotAllowed)]
fun test_update_risk_params_pair_not_allowed_e() {
    let min_withdraw_risk_ratio = 2_000_000_000; // 2
    let min_borrow_risk_ratio = 1_250_000_000; // 1.25
    let liquidation_risk_ratio = 1_100_000_000; // 1.10
    let target_liquidation_risk_ratio = 1_250_000_000; // 1.25
    let user_liquidation_reward = 10_000_000; // 1%
    let pool_liquidation_reward = 40_000_000; // 4%

    let mut test = begin(OWNER);
    let registry_id = setup_test(OWNER, &mut test);

    test.next_tx(OWNER);
    let mut registry = test.take_shared_by_id<MarginRegistry>(registry_id);
    let admin_cap = margin_registry::get_margin_admin_cap_for_testing(test.ctx());

    let risk_params = margin_registry::new_risk_params(
        min_withdraw_risk_ratio,
        min_borrow_risk_ratio,
        liquidation_risk_ratio,
        target_liquidation_risk_ratio,
        user_liquidation_reward,
        pool_liquidation_reward,
    );

    margin_registry::update_risk_params<SUI, USDC>(
        &mut registry,
        risk_params,
        &admin_cap,
    );

    return_shared(registry);
    test_utils::destroy(admin_cap);

    end(test);
}

#[test, expected_failure(abort_code = ::margin_trading::margin_registry::EPairNotAllowed)]
fun test_remove_margin_pair_e() {
    let mut test = begin(OWNER);
    let registry_id = setup_test(OWNER, &mut test);

    test.next_tx(OWNER);
    let mut registry = test.take_shared_by_id<MarginRegistry>(registry_id);
    let admin_cap = margin_registry::get_margin_admin_cap_for_testing(test.ctx());

    margin_registry::remove_margin_pair<SUI, USDC>(&mut registry, &admin_cap);

    return_shared(registry);
    test_utils::destroy(admin_cap);

    end(test);
}

#[test, expected_failure(abort_code = ::margin_trading::margin_registry::EPairAlreadyAllowed)]
fun test_add_margin_pair_e() {
    let min_withdraw_risk_ratio = 2_000_000_000; // 2
    let min_borrow_risk_ratio = 1_250_000_000; // 1.25
    let liquidation_risk_ratio = 1_100_000_000; // 1.10
    let target_liquidation_risk_ratio = 1_250_000_000; // 1.25
    let user_liquidation_reward = 10_000_000; // 1%
    let pool_liquidation_reward = 40_000_000; // 4%

    let mut test = begin(OWNER);
    let registry_id = setup_test(OWNER, &mut test);

    test.next_tx(OWNER);
    let mut registry = test.take_shared_by_id<MarginRegistry>(registry_id);
    let admin_cap = margin_registry::get_margin_admin_cap_for_testing(test.ctx());

    let risk_params = margin_registry::new_risk_params(
        min_withdraw_risk_ratio,
        min_borrow_risk_ratio,
        liquidation_risk_ratio,
        target_liquidation_risk_ratio,
        user_liquidation_reward,
        pool_liquidation_reward,
    );

    margin_registry::add_margin_pair<SUI, USDC>(&mut registry, risk_params, &admin_cap);

    let risk_params_2 = margin_registry::new_risk_params(
        min_withdraw_risk_ratio,
        min_borrow_risk_ratio,
        liquidation_risk_ratio,
        target_liquidation_risk_ratio,
        user_liquidation_reward,
        pool_liquidation_reward,
    );
    margin_registry::add_margin_pair<SUI, USDC>(&mut registry, risk_params_2, &admin_cap);

    return_shared(registry);
    test_utils::destroy(admin_cap);

    end(test);
}

#[test, expected_failure(abort_code = ::margin_trading::margin_registry::EInvalidRiskParam)]
fun test_update_risk_params_increase_liquidation_rr_e() {
    let min_withdraw_risk_ratio = 2_000_000_000; // 2
    let min_borrow_risk_ratio = 1_250_000_000; // 1.25
    let liquidation_risk_ratio = 1_100_000_000; // 1.10
    let target_liquidation_risk_ratio = 1_250_000_000; // 1.25
    let user_liquidation_reward = 10_000_000; // 1%
    let pool_liquidation_reward = 40_000_000; // 4%

    let mut test = begin(OWNER);
    let registry_id = setup_test(OWNER, &mut test);

    test.next_tx(OWNER);
    let mut registry = test.take_shared_by_id<MarginRegistry>(registry_id);
    let admin_cap = margin_registry::get_margin_admin_cap_for_testing(test.ctx());

    let risk_params = margin_registry::new_risk_params(
        min_withdraw_risk_ratio,
        min_borrow_risk_ratio,
        liquidation_risk_ratio,
        target_liquidation_risk_ratio,
        user_liquidation_reward,
        pool_liquidation_reward,
    );

    margin_registry::add_margin_pair<SUI, USDC>(&mut registry, risk_params, &admin_cap);

    test.next_tx(OWNER);
    // Liquidation risk ratio is increased to 1.15
    let liquidation_risk_ratio = 1_150_000_000; // 1.15

    let new_risk_params = margin_registry::new_risk_params(
        min_withdraw_risk_ratio,
        min_borrow_risk_ratio,
        liquidation_risk_ratio,
        target_liquidation_risk_ratio,
        user_liquidation_reward,
        pool_liquidation_reward,
    );
    margin_registry::update_risk_params<SUI, USDC>(
        &mut registry,
        new_risk_params,
        &admin_cap,
    );

    return_shared(registry);
    test_utils::destroy(admin_cap);

    end(test);
}

fun setup_test(owner: address, test: &mut Scenario): ID {
    test.next_tx(owner);
    share_clock(test);
    share_registry_for_testing(test)
}

fun share_clock(test: &mut Scenario) {
    test.next_tx(OWNER);
    clock::create_for_testing(test.ctx()).share_for_testing();
}

fun share_registry_for_testing(test: &mut Scenario): ID {
    test.next_tx(OWNER);
    margin_registry::margin_registry_for_testing(test.ctx())
}
