// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module deepbook_predict::market_oracle_config_tests;

use deepbook_predict::{config_constants, market_oracle_config};
use std::unit_test::{assert_eq, destroy};

// Values inside the config_constants envelope for each setter, used by happy
// paths. Aborts reference each constant's specific min/max to stay self-
// documenting if the envelope ever moves.
const VALID_SETTLEMENT_FRESHNESS_MS: u64 = 5_000;
const VALID_MAX_SPOT_DEVIATION: u64 = 50_000_000;
const VALID_MAX_BASIS_DEVIATION: u64 = 60_000_000;
const VALID_MIN_BASIS: u64 = 950_000_000;
const VALID_MAX_BASIS: u64 = 1_050_000_000;

// === Construction and getters ===

#[test]
fun defaults_match_config_constants() {
    let config = market_oracle_config::new();
    assert_eq!(
        config.settlement_freshness_ms(),
        config_constants::default_settlement_freshness_ms!(),
    );
    assert_eq!(config.max_spot_deviation(), config_constants::default_max_spot_deviation!());
    assert_eq!(config.max_basis_deviation(), config_constants::default_max_basis_deviation!());
    assert_eq!(config.min_basis(), config_constants::default_min_basis!());
    assert_eq!(config.max_basis(), config_constants::default_max_basis!());
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

// === set_basis_bounds: happy path ===

#[test]
fun set_basis_bounds_accepts_envelope_endpoints() {
    // Exercise the exact envelope endpoints for all four fields. min_basis at
    // its envelope min (500e6) and max_basis at its envelope max (2e9) keep
    // the strict min<max invariant satisfied.
    let mut config = market_oracle_config::new();
    config.set_basis_bounds(1, 1, 500_000_000, 2_000_000_000);
    assert_eq!(config.max_spot_deviation(), 1);
    assert_eq!(config.max_basis_deviation(), 1);
    assert_eq!(config.min_basis(), 500_000_000);
    assert_eq!(config.max_basis(), 2_000_000_000);
    config.set_basis_bounds(100_000_000, 100_000_000, 500_000_000, 2_000_000_000);
    assert_eq!(config.max_spot_deviation(), 100_000_000);
    assert_eq!(config.max_basis_deviation(), 100_000_000);
    destroy(config);
}

#[test]
fun set_basis_bounds_updates_all_four() {
    let mut config = market_oracle_config::new();
    config.set_basis_bounds(
        VALID_MAX_SPOT_DEVIATION,
        VALID_MAX_BASIS_DEVIATION,
        VALID_MIN_BASIS,
        VALID_MAX_BASIS,
    );
    assert_eq!(config.max_spot_deviation(), VALID_MAX_SPOT_DEVIATION);
    assert_eq!(config.max_basis_deviation(), VALID_MAX_BASIS_DEVIATION);
    assert_eq!(config.min_basis(), VALID_MIN_BASIS);
    assert_eq!(config.max_basis(), VALID_MAX_BASIS);
    destroy(config);
}

// === set_basis_bounds: per-field config_constants aborts ===

#[test, expected_failure(abort_code = config_constants::EInvalidMaxSpotDeviation)]
fun set_basis_bounds_max_spot_deviation_zero_aborts() {
    // min = 1.
    let mut config = market_oracle_config::new();
    config.set_basis_bounds(0, VALID_MAX_BASIS_DEVIATION, VALID_MIN_BASIS, VALID_MAX_BASIS);
    abort 999
}

#[test, expected_failure(abort_code = config_constants::EInvalidMaxSpotDeviation)]
fun set_basis_bounds_max_spot_deviation_too_large_aborts() {
    // max = 100_000_000.
    let mut config = market_oracle_config::new();
    config.set_basis_bounds(
        100_000_001,
        VALID_MAX_BASIS_DEVIATION,
        VALID_MIN_BASIS,
        VALID_MAX_BASIS,
    );
    abort 999
}

#[test, expected_failure(abort_code = config_constants::EInvalidMaxBasisDeviation)]
fun set_basis_bounds_max_basis_deviation_zero_aborts() {
    let mut config = market_oracle_config::new();
    config.set_basis_bounds(VALID_MAX_SPOT_DEVIATION, 0, VALID_MIN_BASIS, VALID_MAX_BASIS);
    abort 999
}

#[test, expected_failure(abort_code = config_constants::EInvalidMaxBasisDeviation)]
fun set_basis_bounds_max_basis_deviation_too_large_aborts() {
    let mut config = market_oracle_config::new();
    config.set_basis_bounds(
        VALID_MAX_SPOT_DEVIATION,
        100_000_001,
        VALID_MIN_BASIS,
        VALID_MAX_BASIS,
    );
    abort 999
}

#[test, expected_failure(abort_code = config_constants::EInvalidMinBasis)]
fun set_basis_bounds_min_basis_below_envelope_aborts() {
    // min_basis envelope = [500_000_000, 2_000_000_000].
    let mut config = market_oracle_config::new();
    config.set_basis_bounds(
        VALID_MAX_SPOT_DEVIATION,
        VALID_MAX_BASIS_DEVIATION,
        499_999_999,
        VALID_MAX_BASIS,
    );
    abort 999
}

#[test, expected_failure(abort_code = config_constants::EInvalidMinBasis)]
fun set_basis_bounds_min_basis_above_envelope_aborts() {
    let mut config = market_oracle_config::new();
    config.set_basis_bounds(
        VALID_MAX_SPOT_DEVIATION,
        VALID_MAX_BASIS_DEVIATION,
        2_000_000_001,
        VALID_MAX_BASIS,
    );
    abort 999
}

#[test, expected_failure(abort_code = config_constants::EInvalidMaxBasis)]
fun set_basis_bounds_max_basis_below_envelope_aborts() {
    let mut config = market_oracle_config::new();
    config.set_basis_bounds(
        VALID_MAX_SPOT_DEVIATION,
        VALID_MAX_BASIS_DEVIATION,
        VALID_MIN_BASIS,
        499_999_999,
    );
    abort 999
}

#[test, expected_failure(abort_code = config_constants::EInvalidMaxBasis)]
fun set_basis_bounds_max_basis_above_envelope_aborts() {
    let mut config = market_oracle_config::new();
    config.set_basis_bounds(
        VALID_MAX_SPOT_DEVIATION,
        VALID_MAX_BASIS_DEVIATION,
        VALID_MIN_BASIS,
        2_000_000_001,
    );
    abort 999
}

// === set_basis_bounds: cross-field invariant ===

#[test, expected_failure(abort_code = market_oracle_config::EInvalidBasisBounds)]
fun set_basis_bounds_min_equal_to_max_aborts() {
    // Module-level invariant: min_basis must be strictly less than max_basis.
    let mut config = market_oracle_config::new();
    config.set_basis_bounds(
        VALID_MAX_SPOT_DEVIATION,
        VALID_MAX_BASIS_DEVIATION,
        VALID_MIN_BASIS,
        VALID_MIN_BASIS,
    );
    abort 999
}

#[test, expected_failure(abort_code = market_oracle_config::EInvalidBasisBounds)]
fun set_basis_bounds_min_greater_than_max_aborts() {
    let mut config = market_oracle_config::new();
    config.set_basis_bounds(
        VALID_MAX_SPOT_DEVIATION,
        VALID_MAX_BASIS_DEVIATION,
        VALID_MAX_BASIS, // swap min/max
        VALID_MIN_BASIS,
    );
    abort 999
}
