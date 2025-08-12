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
    advance_scenario_with_gas_price(&mut test, gas_price1);
    let mut ewma_state = test_init_ewma_state(test.ctx());
    assert_eq!(ewma_state.mean(), 1_000 * constants::float_scaling());
    assert_eq!(ewma_state.variance(), 0);
    assert_eq!(ewma_state.last_updated_timestamp(), 0);

    // default alpha is 0.01, so the mean should be 0.99 * 1_000_000 + 0.01 * 2_000_000 = 1_010_000
    // difference 2000 - 1010 = 990
    // diff squared = 980100
    let gas_price2 = 2_000;
    advance_scenario_with_gas_price(&mut test, gas_price2);
    let mut clock = clock::create_for_testing(test.ctx());
    clock.set_for_testing(1000);
    ewma_state.update(&clock, test.ctx());
    assert_eq!(ewma_state.mean(), 1_010 * constants::float_scaling());
    assert_eq!(ewma_state.variance(), 980100 * constants::float_scaling());

    test_utils::destroy(clock);
    end(test);
}

fun advance_scenario_with_gas_price(test: &mut Scenario, gas_price: u64) {
    let ts = test.ctx().epoch_timestamp_ms() + 1000;
    let ctx = test.ctx_builder().set_gas_price(gas_price).set_epoch_timestamp(ts);
    test.next_with_context(ctx);
}
