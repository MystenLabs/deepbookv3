// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module deepbook::ewma_tests;

use deepbook::{constants, ewma::{Self, EWMAState}};
use std::unit_test::{assert_eq, destroy};
use sui::{clock, test_scenario::{begin, end, Scenario}};

#[test_only]
const TEST_POOL_ID: address = @0x1234;

#[test_only]
public fun test_init_ewma_state(ctx: &TxContext): EWMAState {
    ewma::init_ewma_state(ctx)
}

#[test]
fun test_init_ewma_init_values() {
    let mut test = begin(@0xF);
    let alice = @0xA;
    test.next_tx(alice);
    let mut ewma_state = test_init_ewma_state(test.ctx());
    assert!(ewma_state.enabled() == false);
    assert!(ewma_state.mean() == test.ctx().gas_price());
    assert!(ewma_state.variance() == 0);
    assert!(ewma_state.last_updated_timestamp() == 0);
    assert!(ewma_state.enabled() == false);

    test.next_tx(alice);
    ewma_state.set_alpha(1_000_000_000);
    ewma_state.set_z_score_threshold(100_000_000);
    ewma_state.set_additional_taker_fee(100_000_000);
    ewma_state.enable();
    assert!(ewma_state.enabled() == true);
    assert!(ewma_state.alpha() == 1_000_000_000);
    assert!(ewma_state.z_score_threshold() == 100_000_000);
    assert!(ewma_state.additional_taker_fee() == 100_000_000);

    test.next_tx(alice);
    ewma_state.disable();
    assert!(ewma_state.enabled() == false);

    end(test);
}

#[test]
fun test_update_ewma_state() {
    let mut test = begin(@0xF);
    let gas_price1 = 1_000;
    let taker_fee = 100_000_000;
    advance_scenario_with_gas_price(&mut test, gas_price1, 1000);
    let mut ewma_state = test_init_ewma_state(test.ctx());
    assert_eq!(ewma_state.mean(), 1_000 * constants::float_scaling());
    assert_eq!(ewma_state.variance(), 0);
    assert_eq!(ewma_state.last_updated_timestamp(), 0);

    // default alpha is 0.01, so the mean should be 0.99 * 1_000_000 + 0.01 * 2_000_000 = 1_010_000
    // difference 2000 - 1000 = 1000 (using old mean)
    // diff squared = 1000000
    let gas_price2 = 2_000;
    advance_scenario_with_gas_price(&mut test, gas_price2, 1000);
    let mut clock = clock::create_for_testing(test.ctx());
    clock.set_for_testing(1000);
    ewma_state.update(TEST_POOL_ID.to_id(), &clock, test.ctx());
    assert_eq!(ewma_state.mean(), 1_010 * constants::float_scaling());
    assert_eq!(ewma_state.variance(), 1000000 * constants::float_scaling());

    ewma_state.enable();
    // mean = 1010, variance = 1000000, std_dev = sqrt(1000000) = 1000
    // z_score = (2000 - 1010) / 1000 = 0.99
    assert_eq!(ewma_state.z_score(test.ctx()), 990_000_000);

    let gas_price3 = 3_000;
    advance_scenario_with_gas_price(&mut test, gas_price3, 1000);
    clock.set_for_testing(1000 + 10);
    ewma_state.update(TEST_POOL_ID.to_id(), &clock, test.ctx());
    // mean = 0.99 * 1_010_000_000_000 + 0.01 * 3_000_000_000_000 = 1_029_900_000_000
    // difference = 3_000_000_000_000 - 1_010_000_000_000 = 1_990_000_000_000 (1990, using old mean)
    // diff squared = (1990 * 1990) = 3_960_100 * 10^9
    // variance = 0.99 * 1000000 + 0.01 * 3960100 = 1,029,601 * 10^9
    assert_eq!(ewma_state.mean(), 1_029_900_000_000);
    assert_eq!(ewma_state.variance(), 1_029_601_000_000_000);
    // diff = 3000 - 1029.9 = 1970.1
    // std_dev = sqrt(1_029_601) ≈ 1,014.692836 * 10^9
    // z_score = 1970.1 / 1,014.692836 ≈ 1.941573309 * 10^9
    assert_eq!(ewma_state.z_score(test.ctx()), 1_941_573_309);
    let new_taker_fee = ewma_state.apply_taker_penalty(taker_fee, test.ctx());
    assert_eq!(new_taker_fee, taker_fee);

    let gas_price4 = 4_000;
    advance_scenario_with_gas_price(&mut test, gas_price4, 1000);
    clock.set_for_testing(1000 + 20);
    ewma_state.update(TEST_POOL_ID.to_id(), &clock, test.ctx());
    // mean = 0.99 * 1_029_900_000_000 + 0.01 * 4_000_000_000_000 = 1059.601 * 10^9
    // difference = 4_000_000_000_000 - 1_029_900_000_000 = 2_970_100_000_000 (2970.1, using old mean)
    // diff squared = (2970.1 * 2970.1) = 8,821,494.01 * 10^9
    // variance = 0.99 * 1_029_601_000_000_000 + 0.01 * 8_821_494_010_000_000 = 1,107,519.9301 * 10^9
    assert_eq!(ewma_state.mean(), 1_059_601_000_000);
    assert_eq!(ewma_state.variance(), 1_107_519_930_100_000);
    // diff = 4000 - 1059.601 = 2940.399
    // std_dev = sqrt(1_107_519.9301) ≈ 1,052.387388 * 10^9
    // z_score = 2940.399 / 1,052.387388 ≈ 2.794026309 * 10^9
    assert_eq!(ewma_state.z_score(test.ctx()), 2_794_026_309);
    let new_taker_fee = ewma_state.apply_taker_penalty(taker_fee, test.ctx());
    assert_eq!(new_taker_fee, taker_fee);

    // lower z-score threshold
    ewma_state.set_z_score_threshold(2_000_000_000);
    assert!(ewma_state.enabled());
    assert!(test.ctx().gas_price() * constants::float_scaling() > ewma_state.mean());
    let new_taker_fee = ewma_state.apply_taker_penalty(taker_fee, test.ctx());
    assert_eq!(new_taker_fee, taker_fee + ewma_state.additional_taker_fee());

    // increase taker fee
    ewma_state.set_additional_taker_fee(200_000_000);
    let new_taker_fee = ewma_state.apply_taker_penalty(taker_fee, test.ctx());
    assert_eq!(new_taker_fee, taker_fee + ewma_state.additional_taker_fee());

    // lower gas fee
    let low_gas_fee = 10;
    advance_scenario_with_gas_price(&mut test, low_gas_fee, 1000);
    clock.set_for_testing(1000 + 30);
    ewma_state.update(TEST_POOL_ID.to_id(), &clock, test.ctx());
    let new_taker_fee = ewma_state.apply_taker_penalty(taker_fee, test.ctx());
    assert_eq!(new_taker_fee, taker_fee);

    // disable ewma
    ewma_state.disable();
    let new_taker_fee = ewma_state.apply_taker_penalty(taker_fee, test.ctx());
    assert_eq!(new_taker_fee, taker_fee);

    destroy(clock);
    end(test);
}

fun advance_scenario_with_gas_price(test: &mut Scenario, gas_price: u64, timestamp_advance: u64) {
    let ts = test.ctx().epoch_timestamp_ms() + timestamp_advance;
    let ctx = test.ctx_builder().set_gas_price(gas_price).set_epoch_timestamp(ts);
    test.next_with_context(ctx);
}

#[test]
fun test_apply_taker_penalty_disabled_ewma() {
    let mut test = begin(@0xF);
    let alice = @0xA;
    test.next_tx(alice);

    let base_taker_fee = 1_000_000; // 0.1%
    let mut ewma_state = test_init_ewma_state(test.ctx());
    ewma_state.set_additional_taker_fee(500_000); // 0.05% additional
    ewma_state.set_z_score_threshold(2_000_000_000); // 2 std devs

    // EWMA is disabled, so no penalty should be applied regardless of gas price
    assert!(!ewma_state.enabled());

    // Test with high gas price
    let high_gas_price = 10_000;
    advance_scenario_with_gas_price(&mut test, high_gas_price, 1000);

    let fee_with_penalty = ewma_state.apply_taker_penalty(base_taker_fee, test.ctx());
    assert_eq!(fee_with_penalty, base_taker_fee); // No penalty applied

    end(test);
}

#[test]
fun test_apply_taker_penalty_gas_below_mean() {
    let mut test = begin(@0xF);

    // Start with moderate gas price
    let initial_gas = 1_000;
    advance_scenario_with_gas_price(&mut test, initial_gas, 1000);

    let base_taker_fee = 1_000_000; // 0.1%
    let mut ewma_state = test_init_ewma_state(test.ctx());
    ewma_state.set_additional_taker_fee(500_000); // 0.05% additional
    ewma_state.set_z_score_threshold(1_000_000_000); // 1 std dev
    ewma_state.enable();

    let mut clock = clock::create_for_testing(test.ctx());
    clock.set_for_testing(1000);
    ewma_state.update(TEST_POOL_ID.to_id(), &clock, test.ctx());

    // Now use gas price below mean
    let low_gas = 500;
    advance_scenario_with_gas_price(&mut test, low_gas, 1000);
    clock.set_for_testing(2000);

    // No penalty when gas is below mean
    let fee_with_penalty = ewma_state.apply_taker_penalty(base_taker_fee, test.ctx());
    assert_eq!(fee_with_penalty, base_taker_fee);

    destroy(clock);
    end(test);
}

#[test]
fun test_apply_taker_penalty_gas_above_mean_below_threshold() {
    let mut test = begin(@0xF);

    // Initialize with gas price = 1000
    let initial_gas = 1_000;
    advance_scenario_with_gas_price(&mut test, initial_gas, 1000);

    let base_taker_fee = 2_000_000; // 0.2%
    let additional_fee = 1_000_000; // 0.1% additional
    let mut ewma_state = test_init_ewma_state(test.ctx());
    ewma_state.set_additional_taker_fee(additional_fee);
    ewma_state.set_z_score_threshold(5_000_000_000); // 5 std devs (very high threshold)
    ewma_state.enable();

    let mut clock = clock::create_for_testing(test.ctx());
    clock.set_for_testing(1000);
    ewma_state.update(TEST_POOL_ID.to_id(), &clock, test.ctx());

    // Use gas price moderately above mean
    let moderate_gas = 1_500;
    advance_scenario_with_gas_price(&mut test, moderate_gas, 1000);
    clock.set_for_testing(2000);
    ewma_state.update(TEST_POOL_ID.to_id(), &clock, test.ctx());

    // Gas is above mean but z-score is below threshold, no penalty
    let fee_with_penalty = ewma_state.apply_taker_penalty(base_taker_fee, test.ctx());
    assert_eq!(fee_with_penalty, base_taker_fee);

    destroy(clock);
    end(test);
}

#[test]
fun test_apply_taker_penalty_z_score_above_threshold() {
    let mut test = begin(@0xF);

    // Initialize with low gas price
    let initial_gas = 100;
    advance_scenario_with_gas_price(&mut test, initial_gas, 1000);

    let base_taker_fee = 1_000_000; // 0.1%
    let additional_fee = 500_000; // 0.05% additional
    let mut ewma_state = test_init_ewma_state(test.ctx());
    ewma_state.set_additional_taker_fee(additional_fee);
    ewma_state.set_z_score_threshold(1_000_000_000); // 1 std dev
    ewma_state.enable();

    let mut clock = clock::create_for_testing(test.ctx());
    clock.set_for_testing(1000);
    ewma_state.update(TEST_POOL_ID.to_id(), &clock, test.ctx());

    // Gradually increase gas price to build up variance
    let gas_price_2 = 200;
    advance_scenario_with_gas_price(&mut test, gas_price_2, 1000);
    clock.set_for_testing(2000);
    ewma_state.update(TEST_POOL_ID.to_id(), &clock, test.ctx());

    let gas_price_3 = 400;
    advance_scenario_with_gas_price(&mut test, gas_price_3, 1000);
    clock.set_for_testing(3000);
    ewma_state.update(TEST_POOL_ID.to_id(), &clock, test.ctx());

    // Now spike the gas price significantly
    let spike_gas = 10_000;
    advance_scenario_with_gas_price(&mut test, spike_gas, 1000);
    clock.set_for_testing(4000);
    ewma_state.update(TEST_POOL_ID.to_id(), &clock, test.ctx());

    // Z-score should be high enough to trigger penalty
    let z_score = ewma_state.z_score(test.ctx());
    assert!(z_score > ewma_state.z_score_threshold());

    let fee_with_penalty = ewma_state.apply_taker_penalty(base_taker_fee, test.ctx());
    assert_eq!(fee_with_penalty, base_taker_fee + additional_fee);

    destroy(clock);
    end(test);
}

#[test]
fun test_dynamic_additional_taker_fee_changes() {
    let mut test = begin(@0xF);

    let initial_gas = 100;
    advance_scenario_with_gas_price(&mut test, initial_gas, 1000);

    let base_taker_fee = 1_000_000; // 0.1%
    let mut ewma_state = test_init_ewma_state(test.ctx());
    ewma_state.set_additional_taker_fee(250_000); // 0.025% initially
    ewma_state.set_z_score_threshold(500_000_000); // 0.5 std dev (low threshold for testing)
    ewma_state.enable();

    let mut clock = clock::create_for_testing(test.ctx());
    clock.set_for_testing(1000);
    ewma_state.update(TEST_POOL_ID.to_id(), &clock, test.ctx());

    // Spike gas price
    let spike_gas = 5_000;
    advance_scenario_with_gas_price(&mut test, spike_gas, 1000);
    clock.set_for_testing(2000);
    ewma_state.update(TEST_POOL_ID.to_id(), &clock, test.ctx());

    // Apply penalty with first additional fee
    let fee_1 = ewma_state.apply_taker_penalty(base_taker_fee, test.ctx());
    assert_eq!(fee_1, base_taker_fee + 250_000);

    // Change additional taker fee
    ewma_state.set_additional_taker_fee(750_000); // 0.075%

    // Same conditions, different penalty
    let fee_2 = ewma_state.apply_taker_penalty(base_taker_fee, test.ctx());
    assert_eq!(fee_2, base_taker_fee + 750_000);

    // Set to maximum allowed
    ewma_state.set_additional_taker_fee(constants::max_additional_taker_fee());
    let fee_3 = ewma_state.apply_taker_penalty(base_taker_fee, test.ctx());
    assert_eq!(fee_3, base_taker_fee + constants::max_additional_taker_fee());

    destroy(clock);
    end(test);
}

#[test]
fun test_ewma_state_timestamping() {
    let mut test = begin(@0xF);
    let alice = @0xA;
    test.next_tx(alice);

    let mut ewma_state = test_init_ewma_state(test.ctx());
    assert_eq!(ewma_state.last_updated_timestamp(), 0);

    let mut clock = clock::create_for_testing(test.ctx());
    clock.set_for_testing(5000);
    ewma_state.update(TEST_POOL_ID.to_id(), &clock, test.ctx());
    assert_eq!(ewma_state.last_updated_timestamp(), 5000);

    // Update at same timestamp should be no-op
    let mean_before = ewma_state.mean();
    let variance_before = ewma_state.variance();
    ewma_state.update(TEST_POOL_ID.to_id(), &clock, test.ctx());
    assert_eq!(ewma_state.mean(), mean_before);
    assert_eq!(ewma_state.variance(), variance_before);
    assert_eq!(ewma_state.last_updated_timestamp(), 5000);

    // Update with new timestamp
    clock.set_for_testing(10000);
    ewma_state.update(TEST_POOL_ID.to_id(), &clock, test.ctx());
    assert_eq!(ewma_state.last_updated_timestamp(), 10000);

    destroy(clock);
    end(test);
}

#[test]
fun test_z_score_with_zero_variance() {
    let mut test = begin(@0xF);
    let alice = @0xA;
    test.next_tx(alice);

    let ewma_state = test_init_ewma_state(test.ctx());
    // Initial variance is 0
    assert_eq!(ewma_state.variance(), 0);

    // Z-score should be 0 when variance is 0
    let z = ewma_state.z_score(test.ctx());
    assert_eq!(z, 0);

    end(test);
}

#[test]
fun test_alpha_parameter_effect() {
    let mut test = begin(@0xF);

    // Test with high alpha (more weight on current price)
    let initial_gas = 1_000;
    advance_scenario_with_gas_price(&mut test, initial_gas, 1000);

    let mut ewma_high_alpha = test_init_ewma_state(test.ctx());
    ewma_high_alpha.set_alpha(500_000_000); // 50% weight on current

    let mut clock = clock::create_for_testing(test.ctx());
    clock.set_for_testing(1000);
    ewma_high_alpha.update(TEST_POOL_ID.to_id(), &clock, test.ctx());

    let new_gas = 2_000;
    advance_scenario_with_gas_price(&mut test, new_gas, 1000);
    clock.set_for_testing(2000);
    ewma_high_alpha.update(TEST_POOL_ID.to_id(), &clock, test.ctx());

    // With alpha = 0.5: new_mean = 0.5 * 2000 + 0.5 * 1000 = 1500 * float_scaling
    assert_eq!(ewma_high_alpha.mean(), 1_500 * constants::float_scaling());

    // Test with low alpha (more weight on historical)
    let initial_gas_2 = 1_000;
    advance_scenario_with_gas_price(&mut test, initial_gas_2, 1000);

    let mut ewma_low_alpha = test_init_ewma_state(test.ctx());
    ewma_low_alpha.set_alpha(10_000_000); // 1% weight on current (default)

    clock.set_for_testing(3000);
    ewma_low_alpha.update(TEST_POOL_ID.to_id(), &clock, test.ctx());

    let new_gas_2 = 2_000;
    advance_scenario_with_gas_price(&mut test, new_gas_2, 1000);
    clock.set_for_testing(4000);
    ewma_low_alpha.update(TEST_POOL_ID.to_id(), &clock, test.ctx());

    // With alpha = 0.01: new_mean = 0.01 * 2000 + 0.99 * 1000 = 1010 * float_scaling
    assert_eq!(ewma_low_alpha.mean(), 1_010 * constants::float_scaling());

    destroy(clock);
    end(test);
}
