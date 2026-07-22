// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Expiry-cash config snapshot independence.
#[test_only]
module deepbook_predict::scope_structure__intent_behavior__expiry_cash_config_tests;

use deepbook_predict::expiry_cash_config;
use std::unit_test::{assert_eq, destroy};

const SNAPSHOT_RATE: u64 = 250_000_000;
const MUTATED_RATE: u64 = 750_000_000;

#[test]
fun snapshot_is_independent_of_later_template_mutation() {
    let mut template = expiry_cash_config::new();
    template.set_trading_loss_rebate_rate(SNAPSHOT_RATE);
    let snapshot = template.snapshot();
    template.set_trading_loss_rebate_rate(MUTATED_RATE);
    assert_eq!(snapshot.trading_loss_rebate_rate(), SNAPSHOT_RATE);
    assert_eq!(template.trading_loss_rebate_rate(), MUTATED_RATE);
    destroy(snapshot);
    destroy(template);
}
