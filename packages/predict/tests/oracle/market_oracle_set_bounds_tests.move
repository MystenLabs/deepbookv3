// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module deepbook_predict::market_oracle_set_bounds_tests;

use deepbook_predict::{admin, config_constants, market_oracle, protocol_config};
use std::unit_test::destroy;

const EXPIRY_MS: u64 = 100_000;
const VALID_FRESHNESS_MS: u64 = 5_000;
const VALID_MAX_SPOT_DEVIATION: u64 = 50_000_000;
const VALID_MAX_BASIS_DEVIATION: u64 = 60_000_000;
const VALID_MIN_BASIS: u64 = 950_000_000;
const VALID_MAX_BASIS: u64 = 1_050_000_000;

// === set_settlement_freshness_ms ===

#[test]
fun set_settlement_freshness_ms_round_trip_succeeds() {
    let ctx = &mut tx_context::dummy();
    let admin_cap = admin::create_admin_cap_for_testing(ctx);
    let cap = market_oracle::create_writer_cap(&admin_cap, ctx);
    let config = protocol_config::new_for_testing(ctx);
    let mut market = market_oracle::create_test_market_oracle(EXPIRY_MS, &cap, ctx);

    // No abort -> the setter accepted the value and emitted bounds-updated.
    market.set_settlement_freshness_ms(&config, &cap, VALID_FRESHNESS_MS);

    cleanup(market, config, cap, admin_cap);
}

#[test, expected_failure(abort_code = config_constants::EInvalidSettlementFreshnessMs)]
fun set_settlement_freshness_ms_below_min_aborts() {
    // Envelope min = 1; 0 must be rejected by the config_constants guard.
    let ctx = &mut tx_context::dummy();
    let admin_cap = admin::create_admin_cap_for_testing(ctx);
    let cap = market_oracle::create_writer_cap(&admin_cap, ctx);
    let config = protocol_config::new_for_testing(ctx);
    let mut market = market_oracle::create_test_market_oracle(EXPIRY_MS, &cap, ctx);
    market.set_settlement_freshness_ms(&config, &cap, 0);
    abort 999
}

#[test, expected_failure(abort_code = config_constants::EInvalidSettlementFreshnessMs)]
fun set_settlement_freshness_ms_above_max_aborts() {
    let ctx = &mut tx_context::dummy();
    let admin_cap = admin::create_admin_cap_for_testing(ctx);
    let cap = market_oracle::create_writer_cap(&admin_cap, ctx);
    let config = protocol_config::new_for_testing(ctx);
    let mut market = market_oracle::create_test_market_oracle(EXPIRY_MS, &cap, ctx);
    market.set_settlement_freshness_ms(&config, &cap, 60_001);
    abort 999
}

#[test, expected_failure(abort_code = market_oracle::EInvalidMarketOracleWriterCap)]
fun set_settlement_freshness_ms_with_unregistered_cap_aborts() {
    let ctx = &mut tx_context::dummy();
    let admin_cap = admin::create_admin_cap_for_testing(ctx);
    let cap = market_oracle::create_writer_cap(&admin_cap, ctx);
    let unregistered_cap = market_oracle::create_writer_cap(&admin_cap, ctx);
    let config = protocol_config::new_for_testing(ctx);
    let mut market = market_oracle::create_test_market_oracle(EXPIRY_MS, &cap, ctx);
    market.set_settlement_freshness_ms(&config, &unregistered_cap, VALID_FRESHNESS_MS);
    abort 999
}

#[test, expected_failure(abort_code = protocol_config::EValuationInProgress)]
fun set_settlement_freshness_ms_during_valuation_aborts() {
    let ctx = &mut tx_context::dummy();
    let admin_cap = admin::create_admin_cap_for_testing(ctx);
    let cap = market_oracle::create_writer_cap(&admin_cap, ctx);
    let mut config = protocol_config::new_for_testing(ctx);
    let mut market = market_oracle::create_test_market_oracle(EXPIRY_MS, &cap, ctx);
    config.begin_valuation();

    market.set_settlement_freshness_ms(&config, &cap, VALID_FRESHNESS_MS);
    abort 999
}

// === set_basis_bounds: happy path and cross-field invariant ===

#[test]
fun set_basis_bounds_round_trip_succeeds() {
    let ctx = &mut tx_context::dummy();
    let admin_cap = admin::create_admin_cap_for_testing(ctx);
    let cap = market_oracle::create_writer_cap(&admin_cap, ctx);
    let config = protocol_config::new_for_testing(ctx);
    let mut market = market_oracle::create_test_market_oracle(EXPIRY_MS, &cap, ctx);

    market.set_basis_bounds(
        &config,
        &cap,
        VALID_MAX_SPOT_DEVIATION,
        VALID_MAX_BASIS_DEVIATION,
        VALID_MIN_BASIS,
        VALID_MAX_BASIS,
    );

    cleanup(market, config, cap, admin_cap);
}

#[test, expected_failure(abort_code = market_oracle::EInvalidBasisBounds)]
fun set_basis_bounds_min_equal_to_max_aborts() {
    // Module-level invariant: min_basis < max_basis strictly.
    let ctx = &mut tx_context::dummy();
    let admin_cap = admin::create_admin_cap_for_testing(ctx);
    let cap = market_oracle::create_writer_cap(&admin_cap, ctx);
    let config = protocol_config::new_for_testing(ctx);
    let mut market = market_oracle::create_test_market_oracle(EXPIRY_MS, &cap, ctx);

    market.set_basis_bounds(
        &config,
        &cap,
        VALID_MAX_SPOT_DEVIATION,
        VALID_MAX_BASIS_DEVIATION,
        VALID_MIN_BASIS,
        VALID_MIN_BASIS, // equal
    );
    abort 999
}

#[test, expected_failure(abort_code = market_oracle::EInvalidBasisBounds)]
fun set_basis_bounds_min_above_max_aborts() {
    let ctx = &mut tx_context::dummy();
    let admin_cap = admin::create_admin_cap_for_testing(ctx);
    let cap = market_oracle::create_writer_cap(&admin_cap, ctx);
    let config = protocol_config::new_for_testing(ctx);
    let mut market = market_oracle::create_test_market_oracle(EXPIRY_MS, &cap, ctx);

    market.set_basis_bounds(
        &config,
        &cap,
        VALID_MAX_SPOT_DEVIATION,
        VALID_MAX_BASIS_DEVIATION,
        VALID_MAX_BASIS, // swapped
        VALID_MIN_BASIS,
    );
    abort 999
}

// === set_basis_bounds: per-field config_constants envelope aborts ===

#[test, expected_failure(abort_code = config_constants::EInvalidMaxSpotDeviation)]
fun set_basis_bounds_max_spot_deviation_zero_aborts() {
    let ctx = &mut tx_context::dummy();
    let admin_cap = admin::create_admin_cap_for_testing(ctx);
    let cap = market_oracle::create_writer_cap(&admin_cap, ctx);
    let config = protocol_config::new_for_testing(ctx);
    let mut market = market_oracle::create_test_market_oracle(EXPIRY_MS, &cap, ctx);

    market.set_basis_bounds(
        &config,
        &cap,
        0,
        VALID_MAX_BASIS_DEVIATION,
        VALID_MIN_BASIS,
        VALID_MAX_BASIS,
    );
    abort 999
}

#[test, expected_failure(abort_code = config_constants::EInvalidMaxBasisDeviation)]
fun set_basis_bounds_max_basis_deviation_zero_aborts() {
    let ctx = &mut tx_context::dummy();
    let admin_cap = admin::create_admin_cap_for_testing(ctx);
    let cap = market_oracle::create_writer_cap(&admin_cap, ctx);
    let config = protocol_config::new_for_testing(ctx);
    let mut market = market_oracle::create_test_market_oracle(EXPIRY_MS, &cap, ctx);

    market.set_basis_bounds(
        &config,
        &cap,
        VALID_MAX_SPOT_DEVIATION,
        0,
        VALID_MIN_BASIS,
        VALID_MAX_BASIS,
    );
    abort 999
}

#[test, expected_failure(abort_code = config_constants::EInvalidMinBasis)]
fun set_basis_bounds_min_basis_below_envelope_aborts() {
    let ctx = &mut tx_context::dummy();
    let admin_cap = admin::create_admin_cap_for_testing(ctx);
    let cap = market_oracle::create_writer_cap(&admin_cap, ctx);
    let config = protocol_config::new_for_testing(ctx);
    let mut market = market_oracle::create_test_market_oracle(EXPIRY_MS, &cap, ctx);

    market.set_basis_bounds(
        &config,
        &cap,
        VALID_MAX_SPOT_DEVIATION,
        VALID_MAX_BASIS_DEVIATION,
        499_999_999, // envelope min is 500_000_000
        VALID_MAX_BASIS,
    );
    abort 999
}

#[test, expected_failure(abort_code = config_constants::EInvalidMaxBasis)]
fun set_basis_bounds_max_basis_above_envelope_aborts() {
    let ctx = &mut tx_context::dummy();
    let admin_cap = admin::create_admin_cap_for_testing(ctx);
    let cap = market_oracle::create_writer_cap(&admin_cap, ctx);
    let config = protocol_config::new_for_testing(ctx);
    let mut market = market_oracle::create_test_market_oracle(EXPIRY_MS, &cap, ctx);

    market.set_basis_bounds(
        &config,
        &cap,
        VALID_MAX_SPOT_DEVIATION,
        VALID_MAX_BASIS_DEVIATION,
        VALID_MIN_BASIS,
        2_000_000_001, // envelope max is 2_000_000_000
    );
    abort 999
}

#[test, expected_failure(abort_code = market_oracle::EInvalidMarketOracleWriterCap)]
fun set_basis_bounds_with_unregistered_cap_aborts() {
    let ctx = &mut tx_context::dummy();
    let admin_cap = admin::create_admin_cap_for_testing(ctx);
    let cap = market_oracle::create_writer_cap(&admin_cap, ctx);
    let unregistered_cap = market_oracle::create_writer_cap(&admin_cap, ctx);
    let config = protocol_config::new_for_testing(ctx);
    let mut market = market_oracle::create_test_market_oracle(EXPIRY_MS, &cap, ctx);

    market.set_basis_bounds(
        &config,
        &unregistered_cap,
        VALID_MAX_SPOT_DEVIATION,
        VALID_MAX_BASIS_DEVIATION,
        VALID_MIN_BASIS,
        VALID_MAX_BASIS,
    );
    abort 999
}

#[test, expected_failure(abort_code = protocol_config::EValuationInProgress)]
fun set_basis_bounds_during_valuation_aborts() {
    let ctx = &mut tx_context::dummy();
    let admin_cap = admin::create_admin_cap_for_testing(ctx);
    let cap = market_oracle::create_writer_cap(&admin_cap, ctx);
    let mut config = protocol_config::new_for_testing(ctx);
    let mut market = market_oracle::create_test_market_oracle(EXPIRY_MS, &cap, ctx);
    config.begin_valuation();

    market.set_basis_bounds(
        &config,
        &cap,
        VALID_MAX_SPOT_DEVIATION,
        VALID_MAX_BASIS_DEVIATION,
        VALID_MIN_BASIS,
        VALID_MAX_BASIS,
    );
    abort 999
}

fun cleanup(
    market: market_oracle::MarketOracle,
    config: protocol_config::ProtocolConfig,
    cap: market_oracle::MarketOracleWriterCap,
    admin_cap: admin::AdminCap,
) {
    destroy(market);
    destroy(config);
    destroy(cap);
    destroy(admin_cap);
}
