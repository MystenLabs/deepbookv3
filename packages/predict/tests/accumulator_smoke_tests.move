// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module deepbook_predict::accumulator_smoke_tests;

use account::account::{Self, AccountWrapper};
use account::account_registry::{Self, AccountRegistry};
use dusdc::dusdc::DUSDC;
use std::unit_test::assert_eq;
use sui::{accumulator, accumulator::AccumulatorRoot, clock, coin, test_scenario as test};

const ALICE: address = @0xA;

#[test]
fun root_constructs_and_funds_stored_balance() {
    let mut scenario = test::begin(@0x0);
    // Predict's canonical Sui is the nightly override, so Predict's own root test code
    // constructs the shared AccumulatorRoot directly. It cannot be funded without the
    // system settlement barrier (see ACCUMULATOR_TESTING_STATUS.md); flows that read
    // stored balance only (empty-root settle is a no-op) are fully testable.
    accumulator::create_for_testing(scenario.ctx());
    account_registry::init_for_testing(scenario.ctx());
    scenario.next_tx(ALICE);

    let mut registry = scenario.take_shared<AccountRegistry>();
    let wrapper_id = registry.derived_wrapper_id(ALICE);
    let wrapper = registry.new(scenario.ctx());
    account::share(wrapper);
    test::return_shared(registry);
    scenario.next_tx(ALICE);

    let clk = clock::create_for_testing(scenario.ctx());

    // Hold wrapper + root across the whole tx (return_shared is deferred to next_tx, so
    // a flow tx must hold its shared objects rather than re-take per op).
    let mut wrapper = scenario.take_shared_by_id<AccountWrapper>(wrapper_id);
    let root = scenario.take_shared<AccumulatorRoot>();

    let auth = account::generate_auth(scenario.ctx());
    let acct = wrapper.load_account_mut(auth);
    acct.deposit<DUSDC>(coin::mint_for_testing<DUSDC>(1000, scenario.ctx()), &root, &clk);
    assert_eq!(wrapper.load_account().balance<DUSDC>(&root, &clk), 1000);

    // Second op in the SAME tx, holding the same objects (no re-take).
    let auth = account::generate_auth(scenario.ctx());
    let acct = wrapper.load_account_mut(auth);
    let withdrawn = acct.withdraw<DUSDC>(400, &root, &clk, scenario.ctx());
    assert_eq!(withdrawn.value(), 400);
    assert_eq!(wrapper.load_account().balance<DUSDC>(&root, &clk), 600);

    withdrawn.burn_for_testing();
    test::return_shared(wrapper);
    test::return_shared(root);
    clk.destroy_for_testing();
    scenario.end();
}
