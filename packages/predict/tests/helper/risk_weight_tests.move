// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module deepbook_predict::risk_weight_tests;

use deepbook_predict::{constants, oracle};
use std::unit_test::{assert_eq, destroy};
use sui::test_scenario;

#[test]
fun risk_weight_at_pos_inf_is_zero() {
    // The +∞ sentinel is the unbounded upper boundary of `(K, +∞]`. The
    // pricing layer must treat it as zero-weight so that the long-UP
    // portion of a binary contributes only `qty · n(d₂(K))` to the
    // directional aggregate (not `qty · (n(d₂(K)) − w_∞)` for some
    // arbitrary `w_∞`).
    let mut scenario = test_scenario::begin(@0xa);
    let oracle = oracle::create_test_oracle(scenario.ctx());

    assert_eq!(oracle.compute_risk_weight(constants::pos_inf!()), 0);

    destroy(oracle);
    scenario.end();
}

#[test]
fun risk_weight_at_neg_inf_is_zero() {
    // Symmetric for the −∞ boundary of `(−∞, K]`. Combined with the
    // +∞ case, this means a binary on either side has exactly one
    // weighted leg contributing to the aggregate.
    let mut scenario = test_scenario::begin(@0xa);
    let oracle = oracle::create_test_oracle(scenario.ctx());

    assert_eq!(oracle.compute_risk_weight(constants::neg_inf!()), 0);

    destroy(oracle);
    scenario.end();
}
