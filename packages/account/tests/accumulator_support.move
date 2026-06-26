// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// The single home of `sui::accumulator` test plumbing for the account suite.
///
/// The current testnet framework exposes `sui::accumulator::create_for_testing`,
/// so package-local tests can construct an empty root. Move unit tests still cannot
/// populate it with nonzero settlement-barrier funds; see
/// `ACCUMULATOR_TESTING_STATUS.md`.
#[test_only]
module account::accumulator_support;

use sui::{accumulator::{Self, AccumulatorRoot}, test_scenario::Scenario};

/// Create the single shared empty accumulator root used by root-dependent tests.
public fun create_shared_root(scenario: &mut Scenario) {
    accumulator::create_for_testing(scenario.ctx());
}

/// Take the shared empty accumulator root.
public fun take_root(scenario: &Scenario): AccumulatorRoot {
    scenario.take_shared<AccumulatorRoot>()
}
