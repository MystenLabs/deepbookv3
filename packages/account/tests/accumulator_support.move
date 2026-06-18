// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// The single home of `sui::accumulator` test plumbing for the account suite.
///
/// DISABLED on the stable/testnet framework: `sui::accumulator::create_for_testing`
/// (the only `AccumulatorRoot` constructor) ships ONLY in the nightly framework, so
/// this branch constructs NO root and the root-dependent custody tests in
/// `account_tests.move` are commented out (see `ACCUMULATOR_TESTING_STATUS.md`). To
/// re-enable when a stable Sui ships the constructor: restore the nightly body of
/// `create_shared_root` (`accumulator::create_for_testing(scenario.ctx())`) and
/// uncomment the custody tests.
#[test_only]
module account::accumulator_support;

use sui::accumulator::AccumulatorRoot;
use sui::test_scenario::Scenario;

/// No-op on the testnet framework (the nightly `create_for_testing` is unavailable).
public fun create_shared_root(_scenario: &mut Scenario) {}

/// Reachable only from root-dependent tests, which are disabled on this branch; with
/// no root constructed it aborts (no shared `AccumulatorRoot`).
public fun take_root(scenario: &Scenario): AccumulatorRoot {
    scenario.take_shared<AccumulatorRoot>()
}
