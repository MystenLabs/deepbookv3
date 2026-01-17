// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module deepbook_margin::margin_state_tests;

use deepbook::{constants, math};
use deepbook_margin::{margin_constants, margin_state, protocol_config_tests, test_constants};
use std::unit_test::{assert_eq, destroy};
use sui::{clock, test_scenario::begin};

#[test]
fun margin_state_operations_work() {
    let mut test = begin(test_constants::admin());
    let mut clock = clock::create_for_testing(test.ctx());
    let mut state = margin_state::default(&clock);
    assert_eq!(state.total_supply(), 0);
    assert_eq!(state.total_borrow(), 0);
    assert_eq!(state.supply_shares(), 0);
    assert_eq!(state.borrow_shares(), 0);
    assert_eq!(state.last_update_timestamp(), clock.timestamp_ms());

    let config = protocol_config_tests::create_test_protocol_config();

    clock.increment_for_testing(1000);
    state.increase_supply(&config, 1000 * constants::float_scaling(), &clock);
    assert_eq!(state.total_supply(), 1000 * constants::float_scaling());
    assert_eq!(state.supply_shares(), 1000 * constants::float_scaling());
    assert_eq!(state.total_borrow(), 0);
    assert_eq!(state.borrow_shares(), 0);
    assert_eq!(state.last_update_timestamp(), clock.timestamp_ms());

    clock.increment_for_testing(1000);
    state.increase_supply(&config, 1000 * constants::float_scaling(), &clock);
    assert_eq!(state.total_supply(), 2000 * constants::float_scaling());
    assert_eq!(state.supply_shares(), 2000 * constants::float_scaling());
    assert_eq!(state.total_borrow(), 0);
    assert_eq!(state.borrow_shares(), 0);
    assert_eq!(state.last_update_timestamp(), clock.timestamp_ms());

    state.increase_supply_absolute(1000 * constants::float_scaling());
    assert_eq!(state.total_supply(), 3000 * constants::float_scaling());
    assert_eq!(state.supply_shares(), 2000 * constants::float_scaling());
    assert_eq!(state.total_borrow(), 0);
    assert_eq!(state.borrow_shares(), 0);

    clock.increment_for_testing(1000);
    let (withdraw_amount, protocol_fees) = state.decrease_supply_shares(
        &config,
        1000 * constants::float_scaling(),
        &clock,
    );
    assert_eq!(withdraw_amount, 1500 * constants::float_scaling());
    assert_eq!(protocol_fees, 0);
    assert_eq!(state.total_supply(), 1500 * constants::float_scaling());
    assert_eq!(state.supply_shares(), 1000 * constants::float_scaling());
    assert_eq!(state.total_borrow(), 0);
    assert_eq!(state.borrow_shares(), 0);
    assert_eq!(state.last_update_timestamp(), clock.timestamp_ms());

    state.decrease_supply_absolute(1000 * constants::float_scaling());
    assert_eq!(state.total_supply(), 500 * constants::float_scaling());
    assert_eq!(state.supply_shares(), 1000 * constants::float_scaling());
    assert_eq!(state.total_borrow(), 0);
    assert_eq!(state.borrow_shares(), 0);

    clock.increment_for_testing(1000);
    let (withdraw_amount, protocol_fees) = state.decrease_supply_shares(
        &config,
        1000 * constants::float_scaling(),
        &clock,
    );
    assert_eq!(withdraw_amount, 500 * constants::float_scaling());
    assert_eq!(protocol_fees, 0);
    assert_eq!(state.total_supply(), 0);
    assert_eq!(state.supply_shares(), 0);
    assert_eq!(state.total_borrow(), 0);
    assert_eq!(state.borrow_shares(), 0);
    assert_eq!(state.last_update_timestamp(), clock.timestamp_ms());

    destroy(clock);
    test.end();
}

#[test]
fun margin_state_with_supply_and_borrow_accrues_interest() {
    let mut test = begin(test_constants::admin());
    let mut clock = clock::create_for_testing(test.ctx());
    let mut state = margin_state::default(&clock);

    let config = protocol_config_tests::create_test_protocol_config();

    clock.increment_for_testing(1000);
    state.increase_supply(&config, 1000 * constants::float_scaling(), &clock);
    assert_eq!(state.total_supply(), 1000 * constants::float_scaling());
    assert_eq!(state.supply_shares(), 1000 * constants::float_scaling());
    assert_eq!(state.total_borrow(), 0);
    assert_eq!(state.borrow_shares(), 0);
    assert_eq!(state.last_update_timestamp(), clock.timestamp_ms());

    clock.increment_for_testing(1000);
    state.increase_borrow(&config, 500 * constants::float_scaling(), &clock);
    assert_eq!(state.total_supply(), 1000 * constants::float_scaling());
    assert_eq!(state.supply_shares(), 1000 * constants::float_scaling());
    assert_eq!(state.total_borrow(), 500 * constants::float_scaling());
    assert_eq!(state.borrow_shares(), 500 * constants::float_scaling());
    assert_eq!(state.last_update_timestamp(), clock.timestamp_ms());

    // so far 1000 supplied, 500 borrowed.
    // incremeent time by 30 days
    let elapsed = 30 * 24 * 60 * 60 * 1000;
    clock.increment_for_testing(elapsed);
    let interest_rate = config.interest_rate(constants::half());
    assert_eq!(state.utilization_rate(), constants::half());
    assert_eq!(interest_rate, 100_000_000); // 10% when 50% utilization

    // 10% interest for 30 days = 500 * 0.1 * 30 / 365 = 4.1095890411
    let interest = math::mul(
        math::mul(interest_rate, 500 * constants::float_scaling()),
        math::div(elapsed, margin_constants::year_ms()),
    );
    let protocol_fees = math::mul(interest, config.protocol_spread());
    assert_eq!(interest, 4_109_589_000);
    assert_eq!(protocol_fees, 410_958_900);

    let supply_ratio = math::div(
        1000 * constants::float_scaling() + interest - protocol_fees,
        1000 * constants::float_scaling(),
    );
    let borrow_ratio = math::div(
        500 * constants::float_scaling() + interest,
        500 * constants::float_scaling(),
    );
    let calc_supply_amount = math::mul(state.supply_shares(), supply_ratio);
    let calc_borrow_amount = math::mul(state.borrow_shares(), borrow_ratio);
    let supply_amount = state.supply_shares_to_amount(state.supply_shares(), &config, &clock);
    let borrow_amount = state.borrow_shares_to_amount(state.borrow_shares(), &config, &clock);
    assert_eq!(supply_amount, calc_supply_amount);
    assert_eq!(borrow_amount, calc_borrow_amount);

    let (withdraw_borrow_amount, withdraw_protocol_fees) = state.decrease_borrow_shares(
        &config,
        500 * constants::float_scaling(),
        &clock,
    );
    assert_eq!(withdraw_borrow_amount, calc_borrow_amount);
    assert_eq!(withdraw_protocol_fees, protocol_fees);
    let (withdraw_supply_amount, withdraw_protocol_fees) = state.decrease_supply_shares(
        &config,
        1000 * constants::float_scaling(),
        &clock,
    );
    assert_eq!(withdraw_supply_amount, calc_supply_amount);
    assert_eq!(withdraw_protocol_fees, 0);

    // rounding leaves 100 in supply
    assert_eq!(state.total_supply(), 100);
    assert_eq!(state.total_borrow(), 0);
    assert_eq!(state.supply_shares(), 0);
    assert_eq!(state.borrow_shares(), 0);
    assert_eq!(state.last_update_timestamp(), clock.timestamp_ms());

    destroy(clock);
    test.end();
}
