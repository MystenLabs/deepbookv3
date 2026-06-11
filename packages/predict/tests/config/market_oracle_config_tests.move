// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module deepbook_predict::market_oracle_config_tests;

use deepbook_predict::{config_constants, market_oracle_config};
use std::unit_test::{assert_eq, destroy};

const VALID_SETTLEMENT_FRESHNESS_MS: u64 = 5_000;

// === Construction and getters ===

#[test]
fun defaults_match_config_constants() {
    let config = market_oracle_config::new();
    assert_eq!(
        config.settlement_freshness_ms(),
        config_constants::default_settlement_freshness_ms!(),
    );
    destroy(config);
}

// === set_settlement_freshness_ms ===

#[test]
fun set_settlement_freshness_ms_updates() {
    let mut config = market_oracle_config::new();
    config.set_settlement_freshness_ms(VALID_SETTLEMENT_FRESHNESS_MS);
    assert_eq!(config.settlement_freshness_ms(), VALID_SETTLEMENT_FRESHNESS_MS);
    destroy(config);
}

#[test]
fun set_settlement_freshness_ms_accepts_endpoints() {
    // Envelope = [1, 60_000].
    let mut config = market_oracle_config::new();
    config.set_settlement_freshness_ms(1);
    assert_eq!(config.settlement_freshness_ms(), 1);
    config.set_settlement_freshness_ms(60_000);
    assert_eq!(config.settlement_freshness_ms(), 60_000);
    destroy(config);
}

#[test, expected_failure(abort_code = config_constants::EInvalidSettlementFreshnessMs)]
fun set_settlement_freshness_ms_below_min_aborts() {
    // min = 1; 0 is out of range.
    let mut config = market_oracle_config::new();
    config.set_settlement_freshness_ms(0);
    abort 999
}

#[test, expected_failure(abort_code = config_constants::EInvalidSettlementFreshnessMs)]
fun set_settlement_freshness_ms_above_max_aborts() {
    // max = 60_000.
    let mut config = market_oracle_config::new();
    config.set_settlement_freshness_ms(60_001);
    abort 999
}
