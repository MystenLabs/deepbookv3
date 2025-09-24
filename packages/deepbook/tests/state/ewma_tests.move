// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module deepbook::ewma_tests;

use deepbook::{constants, ewma::{Self, EWMAState}};
use std::unit_test::assert_eq;
use sui::{clock, test_scenario::{begin, end, Scenario}, test_utils};

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
    assert!(ewma_state.enabled() == false, 0);
    assert!(ewma_state.mean() == test.ctx().gas_price(), 1);
    assert!(ewma_state.variance() == 0, 2);
    assert!(ewma_state.last_updated_timestamp() == 0, 3);
    assert!(ewma_state.enabled() == false, 4);

    test.next_tx(alice);
    ewma_state.set_alpha(1_000_000_000);
    ewma_state.set_z_score_threshold(100_000_000);
    ewma_state.set_additional_taker_fee(100_000_000);
    ewma_state.enable();
    assert!(ewma_state.enabled() == true, 5);
    assert!(ewma_state.alpha() == 1_000_000_000, 6);
    assert!(ewma_state.z_score_threshold() == 100_000_000, 7);
    assert!(ewma_state.additional_taker_fee() == 100_000_000, 8);

    test.next_tx(alice);
    ewma_state.disable();
    assert!(ewma_state.enabled() == false, 9);

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
    // difference 2000 - 1010 = 990
    // diff squared = 980100
    let gas_price2 = 2_000;
    advance_scenario_with_gas_price(&mut test, gas_price2, 1000);
    let mut clock = clock::create_for_testing(test.ctx());
    clock.set_for_testing(1000);
    ewma_state.update(&clock, test.ctx());
    assert_eq!(ewma_state.mean(), 1_010 * constants::float_scaling());
    assert_eq!(ewma_state.variance(), 980100 * constants::float_scaling());

    ewma_state.enable();
    // mean = 1010, variance = 980100, std_dev = sqrt(980100) = 990
    // z_score = (2000 - 1010) / 990 = 1
    assert_eq!(ewma_state.z_score(test.ctx()), constants::float_scaling());

    let gas_price3 = 3_000;
    advance_scenario_with_gas_price(&mut test, gas_price3, 1000);
    clock.set_for_testing(1000 + 10);
    ewma_state.update(&clock, test.ctx());
    // mean = 0.99 * 1_010_000_000_000 + 0.01 * 3_000_000_000_000 = 1_029_900_000_000
    // difference = 3_000_000_000_000 - 1_029_900_000_000 = 1_970_100_000_000 (1970.1)
    // diff squared = (1970.1 * 1970.1) = 3_881_294_010 * 10^9
    // variance = 0.99 * 980100 + 0.01 * 3881294.01 = 1,009,111.9401 * 10^9
    assert_eq!(ewma_state.mean(), 1_029_900_000_000);
    assert_eq!(ewma_state.variance(), 1_009_111_940_100_000);
    // diff = 3000 - 1029.9 = 1970.1
    // std_dev = sqrt(1_009_111.9401) = 1,004.545638634 * 10^9
    // z_score = 1970.1 / 1,004.545638634 = 1.961185160 * 10^9
    assert_eq!(ewma_state.z_score(test.ctx()), 1_961_185_160);
    let new_taker_fee = ewma_state.apply_taker_penalty(taker_fee, test.ctx());
    assert_eq!(new_taker_fee, taker_fee);

    let gas_price4 = 4_000;
    advance_scenario_with_gas_price(&mut test, gas_price4, 1000);
    clock.set_for_testing(1000 + 20);
    ewma_state.update(&clock, test.ctx());
    // mean = 0.99 * 1_029_900_000_000 + 0.01 * 4_000_000_000_000 = 1059.601 * 10^9
    // difference = 4_000_000_000_000 - 1_059_601_000_000 = 2_940_399_000_000 (2940.399)
    // diff squared = (2940.399 * 2940.399) = 8,645,946.279201 * 10^9
    // variance = 0.99 * 1_009_111_940_100_000 + 0.01 * 8_645_946_279_201_000 = 1,085,480.28349101 * 10^9
    assert_eq!(ewma_state.mean(), 1_059_601_000_000);
    assert_eq!(ewma_state.variance(), 1_085_480_283_491_010);
    // diff = 4000 - 1059.601 = 2940.399
    // std_dev = sqrt(1_085_480_283_491_010) = 1,041.863850745 * 10^9
    // z_score = 2940.399 / 1,041.863850745 = 2.822248797 * 10^9
    assert_eq!(ewma_state.z_score(test.ctx()), 2_822_248_797);
    let new_taker_fee = ewma_state.apply_taker_penalty(taker_fee, test.ctx());
    assert_eq!(new_taker_fee, taker_fee);

    // lower z-score threshold
    ewma_state.set_z_score_threshold(2_000_000_000);
    assert!(ewma_state.enabled(), 0);
    assert!(test.ctx().gas_price() * constants::float_scaling() > ewma_state.mean(), 0);
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
    ewma_state.update(&clock, test.ctx());
    let new_taker_fee = ewma_state.apply_taker_penalty(taker_fee, test.ctx());
    assert_eq!(new_taker_fee, taker_fee);

    // disable ewma
    ewma_state.disable();
    let new_taker_fee = ewma_state.apply_taker_penalty(taker_fee, test.ctx());
    assert_eq!(new_taker_fee, taker_fee);

    test_utils::destroy(clock);
    end(test);
}

fun advance_scenario_with_gas_price(test: &mut Scenario, gas_price: u64, timestamp_advance: u64) {
    let ts = test.ctx().epoch_timestamp_ms() + timestamp_advance;
    let ctx = test.ctx_builder().set_gas_price(gas_price).set_epoch_timestamp(ts);
    test.next_with_context(ctx);
}
