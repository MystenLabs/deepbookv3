// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module deepbook::ewma_tests;

use deepbook::{constants, ewma::{Self, EWMAState}};
use std::unit_test::assert_eq;
use sui::test_scenario::{begin, end, Scenario};

#[test_only]
public fun test_init_ewma_state(ctx: &TxContext): EWMAState {
    ewma::init_ewma_state(ctx)
}

#[test]
fun test_init_ewma_init_values() {
    let mut test = begin(@0xF);
    let alice = @0xA;
    test.next_tx(alice);
    let ewma_state = test_init_ewma_state(test.ctx());
    assert!(ewma_state.enabled() == true, 0);
    assert!(ewma_state.mean() == test.ctx().gas_price(), 1);
    assert!(ewma_state.variance() == 0, 2);
    assert!(ewma_state.last_updated_timestamp() == 0, 3);

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
    // variance = 0.99 * 0 + 0.01 * 980100 = 9801
    let gas_price2 = 2_000;
    advance_scenario_with_gas_price(&mut test, gas_price2);
    ewma_state.update(test.ctx());
    assert_eq!(ewma_state.mean(), 1_010 * constants::float_scaling());
    assert_eq!(ewma_state.variance(), 9801 * constants::float_scaling());

    end(test);
}

fun advance_scenario_with_gas_price(test: &mut Scenario, gas_price: u64) {
    let ts = test.ctx().epoch_timestamp_ms() + 1000;
    let ctx = test.ctx_builder().set_gas_price(gas_price).set_epoch_timestamp(ts);
    test.next_with_context(ctx);
}
