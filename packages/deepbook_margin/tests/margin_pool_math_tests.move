// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module deepbook_margin::margin_pool_math_tests;

use deepbook::{constants, math};
use deepbook_margin::{
    margin_constants,
    margin_pool::MarginPool,
    margin_registry::{Self, MarginRegistry, MarginAdminCap, MaintainerCap},
    test_constants::{Self, USDC},
    test_helpers::{Self, mint_coin, advance_time, interest_rate}
};
use std::unit_test::destroy;
use sui::{clock::Clock, test_scenario::{Self as test, Scenario, return_shared}};

fun setup_test(): (Scenario, Clock, MarginAdminCap, MaintainerCap, ID) {
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
    test::return_shared(registry);

    let protocol_config = test_helpers::default_protocol_config();
    let pool_id = test_helpers::create_margin_pool<USDC>(
        &mut scenario,
        &maintainer_cap,
        protocol_config,
        &clock,
    );

    (scenario, clock, admin_cap, maintainer_cap, pool_id)
}

fun cleanup_test(
    registry: MarginRegistry,
    admin_cap: MarginAdminCap,
    maintainer_cap: MaintainerCap,
    clock: Clock,
    scenario: Scenario,
) {
    return_shared(registry);
    destroy(admin_cap);
    destroy(maintainer_cap);
    destroy(clock);
    scenario.end();
}

#[test]
fun test_borrow_supply_interest_ok() {
    let duration = 1;
    let borrow = 50 * test_constants::usdc_multiplier();
    let supply = 100 * test_constants::usdc_multiplier();
    test_borrow_supply(duration, borrow, supply);
}

#[test]
fun test_borrow_supply_interest_ok_2() {
    let duration = 5;
    let borrow = 20 * test_constants::usdc_multiplier();
    let supply = 100 * test_constants::usdc_multiplier();
    test_borrow_supply(duration, borrow, supply);
}

#[test]
fun test_borrow_supply_interest_ok_3() {
    let duration = 2;
    let borrow = 80 * test_constants::usdc_multiplier();
    let supply = 100 * test_constants::usdc_multiplier();
    test_borrow_supply(duration, borrow, supply);
}

#[test]
fun test_borrow_supply_interest_ok_4() {
    let duration = 3;
    let borrow = 10 * test_constants::usdc_multiplier();
    let supply = 100 * test_constants::usdc_multiplier();
    test_borrow_supply(duration, borrow, supply);
}

#[test]
fun test_borrow_supply_interest_ok_5() {
    let duration = 10;
    let borrow = 50 * test_constants::usdc_multiplier();
    let supply = 100 * test_constants::usdc_multiplier();
    test_borrow_supply(duration, borrow, supply);
}

fun test_borrow_supply(duration: u64, borrow: u64, supply: u64) {
    let duration_ms = duration * margin_constants::year_ms();
    let utilization_rate = math::div(borrow, supply);
    // 100%
    let interest_rate =
        interest_rate(
            utilization_rate,
            test_constants::base_rate(),
            test_constants::base_slope(),
            test_constants::optimal_utilization(),
            test_constants::excess_slope(),
        ) * duration;
    let borrow_multiplier = constants::float_scaling() + interest_rate; // 200%
    // 1 + 1*0.5 = 1.5
    let supply_multiplier =
        constants::float_scaling() + math::mul(test_constants::protocol_spread_inverse(), math::mul(interest_rate, utilization_rate));

    let (mut scenario, mut clock, admin_cap, maintainer_cap, pool_id) = setup_test();
    scenario.next_tx(test_constants::admin());
    let mut pool = scenario.take_shared_by_id<MarginPool<USDC>>(pool_id);
    let registry = scenario.take_shared<MarginRegistry>();

    // At time 0, user1 supplies 100 USDC. User 2 borrows 50 USDC.
    scenario.next_tx(test_constants::user1());
    let supplier_cap = test_helpers::supply_to_pool(
        &mut pool,
        &registry,
        supply,
        &clock,
        scenario.ctx(),
    );

    scenario.next_tx(test_constants::user2());
    let (borrowed_coin, shares) = pool.borrow(
        borrow,
        &clock,
        scenario.ctx(),
    );
    assert!(borrowed_coin.value() == borrow);
    destroy(borrowed_coin);

    // 1 year passes
    // Interest rate 100% on 50 USDC = 50 USDC interest
    // Repayment should be 100 USDC for user 2
    advance_time(&mut clock, duration_ms);
    scenario.next_tx(test_constants::user2());
    let repay_coin = mint_coin<USDC>(math::mul(borrow, borrow_multiplier), scenario.ctx());
    pool.repay(shares, repay_coin, &clock);

    // User 1 withdraws his entire balance, receiving 150 USDC
    scenario.next_tx(test_constants::user1());
    let withdrawn_coin = pool.withdraw(
        &registry,
        &supplier_cap,
        option::none(),
        &clock,
        scenario.ctx(),
    );
    let expected_withdrawn_value = math::mul(supply, supply_multiplier);
    assert!(withdrawn_coin.value() == expected_withdrawn_value);
    destroy(withdrawn_coin);
    destroy(supplier_cap);

    test::return_shared(pool);
    cleanup_test(registry, admin_cap, maintainer_cap, clock, scenario);
}

#[test]
fun test_zero_utilization() {
    let (mut scenario, mut clock, admin_cap, maintainer_cap, pool_id) = setup_test();
    scenario.next_tx(test_constants::admin());
    let mut pool = scenario.take_shared_by_id<MarginPool<USDC>>(pool_id);
    let registry = scenario.take_shared<MarginRegistry>();

    scenario.next_tx(test_constants::user1());
    let supply = 100 * test_constants::usdc_multiplier();
    let supplier_cap = test_helpers::supply_to_pool(
        &mut pool,
        &registry,
        supply,
        &clock,
        scenario.ctx(),
    );

    advance_time(&mut clock, margin_constants::year_ms());

    // Withdraw should give back same amount
    scenario.next_tx(test_constants::user1());
    let withdrawn_coin = pool.withdraw(
        &registry,
        &supplier_cap,
        option::none(),
        &clock,
        scenario.ctx(),
    );
    assert!(withdrawn_coin.value() == supply);
    destroy(withdrawn_coin);
    destroy(supplier_cap);

    test::return_shared(pool);
    cleanup_test(registry, admin_cap, maintainer_cap, clock, scenario);
}

#[test]
fun test_high_utilization_interest() {
    let duration = 1;
    let borrow = 79 * test_constants::usdc_multiplier(); // Just below optimal utilization
    let supply = 100 * test_constants::usdc_multiplier();
    test_borrow_supply(duration, borrow, supply);
}
