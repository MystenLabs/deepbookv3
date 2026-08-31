// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module deepbook_margin::margin_state_tests;

use deepbook::{constants, math};
use deepbook_margin::{margin_constants, margin_state, protocol_config_tests, test_constants};
use std::unit_test::{assert_eq, destroy};
use sui::{clock, test_scenario::begin};

// floor(year_ms / 1e9) + 1: `math::div(elapsed, year_ms)` is 0 below this.
const YEAR_FRACTION_QUANTUM_MS: u64 = 32;
const ZERO_INTEREST_STEP_MS: u64 = 1;
const ZERO_INTEREST_STEPS: u64 = 31;
const THIRTY_DAYS_MS: u64 = 30 * 24 * 60 * 60 * 1000;
const SUPPLY_TOKENS: u64 = 1000;
const BORROW_TOKENS: u64 = 500;
const FIRST_QUANTUM_INTEREST: u64 = 50;
const FIRST_QUANTUM_PROTOCOL_FEES: u64 = 5;
const THIRTY_DAY_PLUS_HELD_INTEREST: u64 = 4_109_589_050;
const THIRTY_DAY_PLUS_HELD_PROTOCOL_FEES: u64 = 410_958_905;

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

#[test]
fun zero_interest_update_holds_timestamp_while_borrowed() {
    let mut test = begin(test_constants::admin());
    let mut clock = clock::create_for_testing(test.ctx());
    let mut state = margin_state::default(&clock);
    let config = protocol_config_tests::create_test_protocol_config();
    let supply_amount = SUPPLY_TOKENS * constants::float_scaling();
    let borrow_amount = BORROW_TOKENS * constants::float_scaling();

    state.increase_supply(&config, supply_amount, &clock);
    state.increase_borrow(&config, borrow_amount, &clock);
    let timestamp_at_borrow = state.last_update_timestamp();
    assert_eq!(timestamp_at_borrow, clock.timestamp_ms());

    // 1ms is below the year-fraction quantum (ceil(year_ms / 1e9) = 32), so
    // incremental interest is independently 0 for any borrow size.
    assert_eq!(
        YEAR_FRACTION_QUANTUM_MS,
        margin_constants::year_ms() / constants::float_scaling() + 1,
    );
    assert!(ZERO_INTEREST_STEP_MS < YEAR_FRACTION_QUANTUM_MS);
    clock.increment_for_testing(ZERO_INTEREST_STEP_MS);
    let protocol_fees = state.update(&config, &clock);
    assert_eq!(protocol_fees, 0);
    assert_eq!(state.last_update_timestamp(), timestamp_at_borrow);
    assert_eq!(state.total_supply(), supply_amount);
    assert_eq!(state.total_borrow(), borrow_amount);

    destroy(clock);
    test.end();
}

#[test]
fun zero_interest_update_advances_timestamp_when_idle() {
    let mut test = begin(test_constants::admin());
    let mut clock = clock::create_for_testing(test.ctx());
    let mut state = margin_state::default(&clock);
    let config = protocol_config_tests::create_test_protocol_config();
    let supply_amount = SUPPLY_TOKENS * constants::float_scaling();

    state.increase_supply(&config, supply_amount, &clock);
    assert_eq!(state.total_borrow(), 0);
    let timestamp_at_supply = state.last_update_timestamp();

    clock.increment_for_testing(ZERO_INTEREST_STEP_MS);
    let protocol_fees = state.update(&config, &clock);
    assert_eq!(protocol_fees, 0);
    assert_eq!(state.last_update_timestamp(), clock.timestamp_ms());
    assert!(state.last_update_timestamp() > timestamp_at_supply);
    assert_eq!(state.total_supply(), supply_amount);
    assert_eq!(state.total_borrow(), 0);

    destroy(clock);
    test.end();
}

#[test]
fun repeated_zero_interest_updates_match_one_shot_accrual() {
    let mut test = begin(test_constants::admin());
    let mut grind_clock = clock::create_for_testing(test.ctx());
    let mut oneshot_clock = clock::create_for_testing(test.ctx());
    let mut grind = margin_state::default(&grind_clock);
    let mut oneshot = margin_state::default(&oneshot_clock);
    let config = protocol_config_tests::create_test_protocol_config();
    let supply_amount = SUPPLY_TOKENS * constants::float_scaling();
    let borrow_amount = BORROW_TOKENS * constants::float_scaling();

    grind.increase_supply(&config, supply_amount, &grind_clock);
    grind.increase_borrow(&config, borrow_amount, &grind_clock);
    oneshot.increase_supply(&config, supply_amount, &oneshot_clock);
    oneshot.increase_borrow(&config, borrow_amount, &oneshot_clock);
    let timestamp_at_borrow = grind.last_update_timestamp();
    assert_eq!(ZERO_INTEREST_STEPS, YEAR_FRACTION_QUANTUM_MS - 1);

    let mut step = 0;
    while (step < ZERO_INTEREST_STEPS) {
        grind_clock.increment_for_testing(ZERO_INTEREST_STEP_MS);
        let protocol_fees = grind.update(&config, &grind_clock);
        assert_eq!(protocol_fees, 0);
        assert_eq!(grind.last_update_timestamp(), timestamp_at_borrow);
        step = step + 1;
    };
    assert_eq!(grind.total_supply(), supply_amount);
    assert_eq!(grind.total_borrow(), borrow_amount);

    let held_ms = ZERO_INTEREST_STEPS * ZERO_INTEREST_STEP_MS;
    grind_clock.increment_for_testing(THIRTY_DAYS_MS);
    oneshot_clock.increment_for_testing(held_ms + THIRTY_DAYS_MS);

    let grind_fees = grind.update(&config, &grind_clock);
    let oneshot_fees = oneshot.update(&config, &oneshot_clock);
    assert_eq!(grind_fees, oneshot_fees);
    assert_eq!(grind.total_supply(), oneshot.total_supply());
    assert_eq!(grind.total_borrow(), oneshot.total_borrow());
    assert_eq!(grind.last_update_timestamp(), oneshot.last_update_timestamp());
    assert_eq!(grind.last_update_timestamp(), grind_clock.timestamp_ms());

    // 500 tokens at 10% for (30d + 31ms):
    // time_factor = floor(2_592_000_031 * 1e9 / 31_536_000_000) = 82_191_781
    // interest = floor(50e9 * 82_191_781 / 1e9) = 4_109_589_050
    // protocol fees = floor(4_109_589_050 * 0.1) = 410_958_905
    assert_eq!(oneshot_fees, THIRTY_DAY_PLUS_HELD_PROTOCOL_FEES);
    assert_eq!(oneshot.total_borrow(), borrow_amount + THIRTY_DAY_PLUS_HELD_INTEREST);
    assert_eq!(
        oneshot.total_supply(),
        supply_amount + THIRTY_DAY_PLUS_HELD_INTEREST - THIRTY_DAY_PLUS_HELD_PROTOCOL_FEES,
    );

    destroy(grind_clock);
    destroy(oneshot_clock);
    test.end();
}

#[test]
fun first_year_fraction_quantum_accrues_and_advances() {
    let mut test = begin(test_constants::admin());
    let mut clock = clock::create_for_testing(test.ctx());
    let mut state = margin_state::default(&clock);
    let config = protocol_config_tests::create_test_protocol_config();
    let supply_amount = SUPPLY_TOKENS * constants::float_scaling();
    let borrow_amount = BORROW_TOKENS * constants::float_scaling();

    state.increase_supply(&config, supply_amount, &clock);
    state.increase_borrow(&config, borrow_amount, &clock);

    clock.increment_for_testing(YEAR_FRACTION_QUANTUM_MS - 1);
    assert_eq!(state.update(&config, &clock), 0);
    assert_eq!(state.last_update_timestamp(), 0);
    assert_eq!(state.total_supply(), supply_amount);
    assert_eq!(state.total_borrow(), borrow_amount);

    // 500 tokens at 10% for 32ms: time_factor = 1, interest = 50, fees = 5
    clock.increment_for_testing(1);
    assert_eq!(clock.timestamp_ms(), YEAR_FRACTION_QUANTUM_MS);
    let protocol_fees = state.update(&config, &clock);
    assert_eq!(protocol_fees, FIRST_QUANTUM_PROTOCOL_FEES);
    assert_eq!(state.last_update_timestamp(), YEAR_FRACTION_QUANTUM_MS);
    assert_eq!(state.total_borrow(), borrow_amount + FIRST_QUANTUM_INTEREST);
    assert_eq!(
        state.total_supply(),
        supply_amount + FIRST_QUANTUM_INTEREST - FIRST_QUANTUM_PROTOCOL_FEES,
    );

    destroy(clock);
    test.end();
}
