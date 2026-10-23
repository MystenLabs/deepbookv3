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
// Test curve at 100% utilization: 5% base + 80% * 10% base slope + 20% * 200% excess slope.
const FULL_UTILIZATION_RATE: u64 = 530_000_000;
// One year at 53% on 500 tokens of borrow with zero supply, at the 10% protocol spread:
// interest 265, fees 26.5, supply 0 + 265 - 26.5 = 238.5, borrow 500 + 265 = 765.
const WRITE_OFF_YEAR_ONE_PROTOCOL_FEES: u64 = 26_500_000_000;
const WRITE_OFF_YEAR_ONE_SUPPLY: u64 = 238_500_000_000;
const WRITE_OFF_YEAR_ONE_BORROW: u64 = 765_000_000_000;
// Borrow still exceeds supply, so year two is also 53%: interest 765 * 53% = 405.45,
// fees 40.545, supply 238.5 + 405.45 - 40.545 = 603.405, borrow 765 + 405.45 = 1,170.45.
const WRITE_OFF_YEAR_TWO_PROTOCOL_FEES: u64 = 40_545_000_000;
const WRITE_OFF_YEAR_TWO_SUPPLY: u64 = 603_405_000_000;
const WRITE_OFF_YEAR_TWO_BORROW: u64 = 1_170_450_000_000;
const TEN_DAYS_MS: u64 = 10 * 24 * 60 * 60 * 1000;
// An odd remainder on a day of interest, so the borrow ratio isn't round and a full repay
// leaves dust.
const ODD_REMAINDER_MS: u64 = 7;
const DUST_BORROW_SHARES: u64 = 3;
// One year on 500 tokens + 3 raw units of borrow against 1,000 tokens of supply. Utilization
// floors to 50%, so the rate is 5% base + 50% * 10% slope = 10%:
// interest floor(500.000000003 * 10%) = 50, fees 5, supply 1,000 + 45 = 1,045,
// borrow 500.000000003 + 50 = 550.000000003.
const HELD_DUST_YEAR_PROTOCOL_FEES: u64 = 5_000_000_000;
const HELD_DUST_YEAR_SUPPLY: u64 = 1_045_000_000_000;
const HELD_DUST_YEAR_BORROW: u64 = 550_000_000_003;
// A 250-token borrow 31ms into a held window on 500 tokens, then 33ms more. Only the 33ms
// after the new borrow count: one year-fraction quantum at 750 / 1,000 = 75% utilization,
// rate 5% + 75% * 10% = 12.5%, interest floor(750 * 12.5% * 1e-9 tokens) = 93 raw units,
// fees floor(93 * 10%) = 9. Counting the held 31ms too would make it two quanta (64ms).
const SECOND_BORROW_TOKENS: u64 = 250;
const HELD_WINDOW_MS: u64 = 31;
const AFTER_SECOND_BORROW_MS: u64 = 33;
const SECOND_BORROW_QUANTUM_INTEREST: u64 = 93;
const SECOND_BORROW_QUANTUM_PROTOCOL_FEES: u64 = 9;
// Repaying 250 of 500 tokens 31ms into a held window keeps the hold, so 1ms later the update
// covers all 32ms on the remaining 250 tokens: utilization 25%, rate 5% + 25% * 10% = 7.5%,
// interest floor(250 * 7.5% * 1e-9 tokens) = 18 raw units, fees floor(18 * 10%) = 1.
const REPAY_DURING_HOLD_QUANTUM_INTEREST: u64 = 18;
const REPAY_DURING_HOLD_QUANTUM_PROTOCOL_FEES: u64 = 1;

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

#[test]
fun decrease_supply_absolute_stops_at_zero() {
    let mut test = begin(test_constants::admin());
    let clock = clock::create_for_testing(test.ctx());
    let mut state = margin_state::default(&clock);
    let config = protocol_config_tests::create_test_protocol_config();

    let supplied = 1000 * constants::float_scaling();
    state.increase_supply(&config, supplied, &clock);

    // A write-off one unit larger than the whole supply leaves suppliers at zero and
    // keeps their shares.
    state.decrease_supply_absolute(supplied + 1);
    assert_eq!(state.total_supply(), 0);
    assert_eq!(state.supply_shares(), supplied);

    // Writing off against an already-empty supply stays at zero.
    state.decrease_supply_absolute(supplied);
    assert_eq!(state.total_supply(), 0);
    assert_eq!(state.supply_shares(), supplied);

    destroy(clock);
    test.end();
}

#[test]
fun utilization_rate_reads_full_once_borrow_reaches_supply() {
    let mut test = begin(test_constants::admin());
    let clock = clock::create_for_testing(test.ctx());
    let mut state = margin_state::default(&clock);
    let config = protocol_config_tests::create_test_protocol_config();

    // No borrow reads zero, with or without supply.
    assert_eq!(state.utilization_rate(), 0);
    let supplied = SUPPLY_TOKENS * constants::float_scaling();
    let borrowed = BORROW_TOKENS * constants::float_scaling();
    state.increase_supply(&config, supplied, &clock);
    assert_eq!(state.utilization_rate(), 0);
    state.increase_borrow(&config, borrowed, &clock);

    // Borrow equal to supply is exactly 100%.
    state.decrease_supply_absolute(supplied - borrowed);
    assert_eq!(state.utilization_rate(), constants::float_scaling());

    // One unit of supply against 500 tokens of borrow: borrow * 1e9 / supply = 5e20 is past
    // u64, and it reads 100%.
    state.decrease_supply_absolute(borrowed - 1);
    assert_eq!(state.total_supply(), 1);
    assert_eq!(state.utilization_rate(), constants::float_scaling());

    // Supply written off to zero with borrow outstanding is fully utilized, not idle.
    state.decrease_supply_absolute(1);
    assert_eq!(state.total_supply(), 0);
    assert_eq!(state.utilization_rate(), constants::float_scaling());
    assert_eq!(config.interest_rate(state.utilization_rate()), FULL_UTILIZATION_RATE);

    destroy(clock);
    test.end();
}

#[test]
fun update_after_supply_write_off_accrues_at_the_full_utilization_rate() {
    let mut test = begin(test_constants::admin());
    let mut clock = clock::create_for_testing(test.ctx());
    let mut state = margin_state::default(&clock);
    let config = protocol_config_tests::create_test_protocol_config();

    let supplied = SUPPLY_TOKENS * constants::float_scaling();
    let borrowed = BORROW_TOKENS * constants::float_scaling();
    state.increase_supply(&config, supplied, &clock);
    state.increase_borrow(&config, borrowed, &clock);
    state.decrease_supply_absolute(supplied);
    assert_eq!(state.total_supply(), 0);

    clock.increment_for_testing(margin_constants::year_ms());
    assert_eq!(state.update(&config, &clock), WRITE_OFF_YEAR_ONE_PROTOCOL_FEES);
    assert_eq!(state.total_supply(), WRITE_OFF_YEAR_ONE_SUPPLY);
    assert_eq!(state.total_borrow(), WRITE_OFF_YEAR_ONE_BORROW);
    assert_eq!(state.last_update_timestamp(), clock.timestamp_ms());

    clock.increment_for_testing(margin_constants::year_ms());
    assert_eq!(state.update(&config, &clock), WRITE_OFF_YEAR_TWO_PROTOCOL_FEES);
    assert_eq!(state.total_supply(), WRITE_OFF_YEAR_TWO_SUPPLY);
    assert_eq!(state.total_borrow(), WRITE_OFF_YEAR_TWO_BORROW);
    assert_eq!(state.supply_shares(), supplied);
    assert_eq!(state.borrow_shares(), borrowed);

    destroy(clock);
    test.end();
}

// A full repay rounds the repaid amount down and leaves dust in `total_borrow` with no
// shares. The dust accrues zero interest, so `update` holds the timestamp through 10 idle
// days. A new borrow must restart it: right after borrowing, the borrower owes exactly the
// principal and suppliers' claim is unchanged.
#[test]
fun new_borrow_after_idle_dust_is_not_charged_for_the_held_window() {
    let mut test = begin(test_constants::admin());
    let mut clock = clock::create_for_testing(test.ctx());
    let mut state = margin_state::default(&clock);
    let config = protocol_config_tests::create_test_protocol_config();
    let supplied = SUPPLY_TOKENS * constants::float_scaling();
    let borrowed = BORROW_TOKENS * constants::float_scaling();

    state.increase_supply(&config, supplied, &clock);
    let (first_shares, _) = state.increase_borrow(&config, borrowed, &clock);
    clock.increment_for_testing(margin_constants::day_ms() + ODD_REMAINDER_MS);
    state.update(&config, &clock);
    state.decrease_borrow_shares(&config, first_shares, &clock);
    assert_eq!(state.borrow_shares(), 0);
    assert!(state.total_borrow() > 0);

    let held_at = state.last_update_timestamp();
    clock.increment_for_testing(TEN_DAYS_MS);
    assert_eq!(state.update(&config, &clock), 0);
    assert_eq!(state.last_update_timestamp(), held_at);

    let supply_claim = state.supply_shares_to_amount(state.supply_shares(), &config, &clock);
    let (shares, _) = state.increase_borrow(&config, borrowed, &clock);
    assert_eq!(state.last_update_timestamp(), clock.timestamp_ms());
    assert_eq!(state.borrow_shares_to_amount(shares, &config, &clock), borrowed);
    assert_eq!(state.supply_shares_to_amount(state.supply_shares(), &config, &clock), supply_claim);

    destroy(clock);
    test.end();
}

// A borrower repays all but three shares, leaving 3 raw units of debt that accrue zero
// interest, so `update` holds the timestamp through 30 idle days. A new borrow restarts it,
// and the next update a year later charges one year, not 30 days plus a year.
#[test]
fun new_borrow_restarts_a_timestamp_held_on_dust() {
    let mut test = begin(test_constants::admin());
    let mut clock = clock::create_for_testing(test.ctx());
    let mut state = margin_state::default(&clock);
    let config = protocol_config_tests::create_test_protocol_config();
    let supplied = SUPPLY_TOKENS * constants::float_scaling();
    let borrowed = BORROW_TOKENS * constants::float_scaling();

    state.increase_supply(&config, supplied, &clock);
    let (shares, _) = state.increase_borrow(&config, borrowed, &clock);
    state.decrease_borrow_shares(&config, shares - DUST_BORROW_SHARES, &clock);
    assert_eq!(state.borrow_shares(), DUST_BORROW_SHARES);
    assert_eq!(state.total_borrow(), DUST_BORROW_SHARES);

    let held_at = state.last_update_timestamp();
    clock.increment_for_testing(THIRTY_DAYS_MS);
    assert_eq!(state.update(&config, &clock), 0);
    assert_eq!(state.last_update_timestamp(), held_at);

    let (new_shares, _) = state.increase_borrow(&config, borrowed, &clock);
    assert_eq!(state.last_update_timestamp(), clock.timestamp_ms());
    assert_eq!(state.borrow_shares_to_amount(new_shares, &config, &clock), borrowed);

    clock.increment_for_testing(margin_constants::year_ms());
    assert_eq!(state.update(&config, &clock), HELD_DUST_YEAR_PROTOCOL_FEES);
    assert_eq!(state.total_supply(), HELD_DUST_YEAR_SUPPLY);
    assert_eq!(state.total_borrow(), HELD_DUST_YEAR_BORROW);

    destroy(clock);
    test.end();
}

// A new borrow inside a held sub-quantum window restarts the clock, which drops only that
// window's interest on the old borrow (it was zero once floored). The next update charges the
// combined borrow for the time since the new borrow alone.
#[test]
fun new_borrow_drops_only_the_held_sub_quantum_window() {
    let mut test = begin(test_constants::admin());
    let mut clock = clock::create_for_testing(test.ctx());
    let mut state = margin_state::default(&clock);
    let config = protocol_config_tests::create_test_protocol_config();
    let supplied = SUPPLY_TOKENS * constants::float_scaling();
    let borrowed = BORROW_TOKENS * constants::float_scaling();
    let second_borrow = SECOND_BORROW_TOKENS * constants::float_scaling();

    state.increase_supply(&config, supplied, &clock);
    state.increase_borrow(&config, borrowed, &clock);
    assert!(HELD_WINDOW_MS < YEAR_FRACTION_QUANTUM_MS);
    clock.increment_for_testing(HELD_WINDOW_MS);
    let (_, protocol_fees) = state.increase_borrow(&config, second_borrow, &clock);
    assert_eq!(protocol_fees, 0);
    assert_eq!(state.last_update_timestamp(), HELD_WINDOW_MS);
    assert_eq!(state.total_borrow(), borrowed + second_borrow);

    clock.increment_for_testing(AFTER_SECOND_BORROW_MS);
    assert_eq!(state.update(&config, &clock), SECOND_BORROW_QUANTUM_PROTOCOL_FEES);
    assert_eq!(state.last_update_timestamp(), HELD_WINDOW_MS + AFTER_SECOND_BORROW_MS);
    assert_eq!(state.total_borrow(), borrowed + second_borrow + SECOND_BORROW_QUANTUM_INTEREST);
    assert_eq!(
        state.total_supply(),
        supplied + SECOND_BORROW_QUANTUM_INTEREST - SECOND_BORROW_QUANTUM_PROTOCOL_FEES,
    );

    destroy(clock);
    test.end();
}

// A repay inside a held window leaves the hold in place: only new principal restarts the clock.
// The next update charges the remaining borrow for the whole window, so no time is lost.
#[test]
fun repay_during_a_hold_keeps_the_held_window() {
    let mut test = begin(test_constants::admin());
    let mut clock = clock::create_for_testing(test.ctx());
    let mut state = margin_state::default(&clock);
    let config = protocol_config_tests::create_test_protocol_config();
    let supplied = SUPPLY_TOKENS * constants::float_scaling();
    let borrowed = BORROW_TOKENS * constants::float_scaling();
    let repaid = SECOND_BORROW_TOKENS * constants::float_scaling();

    state.increase_supply(&config, supplied, &clock);
    state.increase_borrow(&config, borrowed, &clock);
    clock.increment_for_testing(HELD_WINDOW_MS);
    let (repaid_amount, protocol_fees) = state.decrease_borrow_shares(&config, repaid, &clock);
    assert_eq!(repaid_amount, repaid);
    assert_eq!(protocol_fees, 0);
    assert_eq!(state.last_update_timestamp(), 0);

    clock.increment_for_testing(YEAR_FRACTION_QUANTUM_MS - HELD_WINDOW_MS);
    assert_eq!(state.update(&config, &clock), REPAY_DURING_HOLD_QUANTUM_PROTOCOL_FEES);
    assert_eq!(state.last_update_timestamp(), YEAR_FRACTION_QUANTUM_MS);
    assert_eq!(state.total_borrow(), borrowed - repaid + REPAY_DURING_HOLD_QUANTUM_INTEREST);
    assert_eq!(
        state.total_supply(),
        supplied + REPAY_DURING_HOLD_QUANTUM_INTEREST - REPAY_DURING_HOLD_QUANTUM_PROTOCOL_FEES,
    );

    destroy(clock);
    test.end();
}
