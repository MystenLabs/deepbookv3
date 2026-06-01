// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

// `expected_failure` tests abort before reaching cleanup, leaving some
// bindings unused on the abort path. Suppress the per-test warning at the
// module level; happy-path tests still consume every returned value.
#[test_only]
#[allow(unused_variable)]
module deepbook_predict::market_oracle_update_prices_tests;

use deepbook_predict::{
    admin,
    constants::float_scaling as float,
    market_oracle,
    protocol_config,
    pyth_source
};
use std::unit_test::{assert_eq, destroy};
use sui::clock;

// Strikes/prices use the package's 1e9 scaling. SPOT = $1000.
const EXPIRY_MS: u64 = 100_000;
const NOW_MS: u64 = 10_000;
const FIRST_SOURCE_TIMESTAMP_MS: u64 = 1_000;
const SECOND_SOURCE_TIMESTAMP_MS: u64 = 2_000;

const SPOT_1000: u64 = 1_000_000_000_000; // 1000.0
const FORWARD_AT_BASIS_1: u64 = 1_000_000_000_000; // basis = 1.0
const FORWARD_AT_BASIS_0_95: u64 = 950_000_000_000;
const FORWARD_AT_BASIS_1_05: u64 = 1_050_000_000_000;
// 1100 spot * 0.95 basis = 1045 forward
const SPOT_1100: u64 = 1_100_000_000_000;
const FORWARD_FOR_1100_AT_BASIS_0_95: u64 = 1_045_000_000_000;

// === update_block_scholes_prices: happy path ===

#[test]
fun update_prices_stores_values_and_emits_basis_one() {
    // basis = forward/spot = 1.0 falls inside the default envelope [0.9, 1.1].
    let (mut market, config, cap, admin_cap, pyth, clock) = setup_active(NOW_MS);

    market.update_block_scholes_prices(
        &config,
        &pyth,
        &cap,
        SPOT_1000,
        FORWARD_AT_BASIS_1,
        FIRST_SOURCE_TIMESTAMP_MS,
        &clock,
    );

    assert_eq!(market.block_scholes_spot(), SPOT_1000);
    assert_eq!(market.block_scholes_forward(), FORWARD_AT_BASIS_1);
    assert_eq!(market.block_scholes_price_source_timestamp_ms(), FIRST_SOURCE_TIMESTAMP_MS);
    assert_eq!(market.block_scholes_price_update_timestamp_ms(), NOW_MS);
    // Once both spot and forward are stored, basis() returns forward/spot in 1e9 scale.
    assert_eq!(market.block_scholes_basis(), float!());

    cleanup(market, config, cap, admin_cap, pyth, clock);
}

#[test]
fun update_prices_accepts_envelope_endpoint_basis() {
    // Default basis envelope is [0.9, 1.1]; both endpoints must be valid.
    let (mut market, config, cap, admin_cap, pyth, clock) = setup_active(NOW_MS);

    market.update_block_scholes_prices(
        &config,
        &pyth,
        &cap,
        SPOT_1000,
        FORWARD_AT_BASIS_0_95,
        FIRST_SOURCE_TIMESTAMP_MS,
        &clock,
    );
    assert_eq!(market.block_scholes_basis(), 950_000_000);

    cleanup(market, config, cap, admin_cap, pyth, clock);
}

#[test]
fun update_prices_strictly_advances_source_timestamp() {
    let (mut market, config, cap, admin_cap, pyth, clock) = setup_active(NOW_MS);

    market.update_block_scholes_prices(
        &config,
        &pyth,
        &cap,
        SPOT_1000,
        FORWARD_AT_BASIS_1,
        FIRST_SOURCE_TIMESTAMP_MS,
        &clock,
    );
    market.update_block_scholes_prices(
        &config,
        &pyth,
        &cap,
        SPOT_1000,
        FORWARD_AT_BASIS_1,
        SECOND_SOURCE_TIMESTAMP_MS,
        &clock,
    );
    assert_eq!(market.block_scholes_price_source_timestamp_ms(), SECOND_SOURCE_TIMESTAMP_MS);

    cleanup(market, config, cap, admin_cap, pyth, clock);
}

// === Validation aborts ===

#[test, expected_failure(abort_code = market_oracle::EZeroSpot)]
fun update_prices_zero_spot_aborts() {
    let (mut market, config, cap, _admin_cap, pyth, clock) = setup_active(NOW_MS);
    market.update_block_scholes_prices(
        &config,
        &pyth,
        &cap,
        0,
        FORWARD_AT_BASIS_1,
        FIRST_SOURCE_TIMESTAMP_MS,
        &clock,
    );
    abort 999
}

#[test, expected_failure(abort_code = market_oracle::EZeroForward)]
fun update_prices_zero_forward_aborts() {
    let (mut market, config, cap, _admin_cap, pyth, clock) = setup_active(NOW_MS);
    market.update_block_scholes_prices(
        &config,
        &pyth,
        &cap,
        SPOT_1000,
        0,
        FIRST_SOURCE_TIMESTAMP_MS,
        &clock,
    );
    abort 999
}

#[test, expected_failure(abort_code = market_oracle::EStalePriceSourceUpdate)]
fun update_prices_equal_source_timestamp_aborts() {
    let (mut market, config, cap, _admin_cap, pyth, clock) = setup_active(NOW_MS);
    market.update_block_scholes_prices(
        &config,
        &pyth,
        &cap,
        SPOT_1000,
        FORWARD_AT_BASIS_1,
        FIRST_SOURCE_TIMESTAMP_MS,
        &clock,
    );
    market.update_block_scholes_prices(
        &config,
        &pyth,
        &cap,
        SPOT_1000,
        FORWARD_AT_BASIS_1,
        FIRST_SOURCE_TIMESTAMP_MS,
        &clock,
    );
    abort 999
}

#[test, expected_failure(abort_code = market_oracle::EFuturePriceSourceUpdate)]
fun update_prices_source_after_now_aborts() {
    let (mut market, config, cap, _admin_cap, pyth, clock) = setup_active(NOW_MS);
    market.update_block_scholes_prices(
        &config,
        &pyth,
        &cap,
        SPOT_1000,
        FORWARD_AT_BASIS_1,
        NOW_MS + 1,
        &clock,
    );
    abort 999
}

#[test, expected_failure(abort_code = market_oracle::EBasisOutOfRange)]
fun update_prices_basis_below_min_aborts() {
    // forward = 800, spot = 1000 -> basis = 0.8 which is < envelope min 0.9.
    let (mut market, config, cap, _admin_cap, pyth, clock) = setup_active(NOW_MS);
    market.update_block_scholes_prices(
        &config,
        &pyth,
        &cap,
        SPOT_1000,
        800_000_000_000,
        FIRST_SOURCE_TIMESTAMP_MS,
        &clock,
    );
    abort 999
}

#[test, expected_failure(abort_code = market_oracle::EBasisOutOfRange)]
fun update_prices_basis_above_max_aborts() {
    // forward = 1200, spot = 1000 -> basis = 1.2 which is > envelope max 1.1.
    let (mut market, config, cap, _admin_cap, pyth, clock) = setup_active(NOW_MS);
    market.update_block_scholes_prices(
        &config,
        &pyth,
        &cap,
        SPOT_1000,
        1_200_000_000_000,
        FIRST_SOURCE_TIMESTAMP_MS,
        &clock,
    );
    abort 999
}

#[test, expected_failure(abort_code = market_oracle::ESpotDeviationTooLarge)]
fun update_prices_second_push_spot_deviation_too_large_aborts() {
    // Default max_spot_deviation = 2% (20_000_000). Jumping spot by 10%
    // breaches the deviation cap, even though the new basis is still in range.
    let (mut market, config, cap, _admin_cap, pyth, clock) = setup_active(NOW_MS);
    market.update_block_scholes_prices(
        &config,
        &pyth,
        &cap,
        SPOT_1000,
        FORWARD_AT_BASIS_1,
        FIRST_SOURCE_TIMESTAMP_MS,
        &clock,
    );
    // SPOT_1100 is +10% vs SPOT_1000.
    market.update_block_scholes_prices(
        &config,
        &pyth,
        &cap,
        SPOT_1100,
        FORWARD_FOR_1100_AT_BASIS_0_95, // basis stays at 0.95 to isolate the spot check
        SECOND_SOURCE_TIMESTAMP_MS,
        &clock,
    );
    abort 999
}

#[test, expected_failure(abort_code = market_oracle::EBasisDeviationTooLarge)]
fun update_prices_second_push_basis_deviation_too_large_aborts() {
    // Default max_basis_deviation = 2% (20_000_000). Hold spot constant so
    // the spot-deviation check passes, then jump basis from 0.95 to 1.05.
    let (mut market, config, cap, _admin_cap, pyth, clock) = setup_active(NOW_MS);
    market.update_block_scholes_prices(
        &config,
        &pyth,
        &cap,
        SPOT_1000,
        FORWARD_AT_BASIS_0_95,
        FIRST_SOURCE_TIMESTAMP_MS,
        &clock,
    );
    market.update_block_scholes_prices(
        &config,
        &pyth,
        &cap,
        SPOT_1000,
        FORWARD_AT_BASIS_1_05,
        SECOND_SOURCE_TIMESTAMP_MS,
        &clock,
    );
    abort 999
}

#[test, expected_failure(abort_code = market_oracle::EInvalidMarketOracleCap)]
fun update_prices_with_unregistered_cap_aborts() {
    let (mut market, config, cap, admin_cap, pyth, clock) = setup_active(NOW_MS);
    let unregistered_cap = market_oracle::create_cap(&admin_cap, &mut tx_context::dummy());
    market.update_block_scholes_prices(
        &config,
        &pyth,
        &unregistered_cap,
        SPOT_1000,
        FORWARD_AT_BASIS_1,
        FIRST_SOURCE_TIMESTAMP_MS,
        &clock,
    );
    destroy(unregistered_cap);
    abort 999
}

#[test, expected_failure(abort_code = market_oracle::EWrongPythSource)]
fun update_prices_with_wrong_pyth_source_aborts() {
    let (mut market, config, cap, _admin_cap, pyth, clock) = setup_active(NOW_MS);
    let wrong_pyth = pyth_source::new_for_testing(&mut tx_context::dummy());
    market.update_block_scholes_prices(
        &config,
        &wrong_pyth,
        &cap,
        SPOT_1000,
        FORWARD_AT_BASIS_1,
        FIRST_SOURCE_TIMESTAMP_MS,
        &clock,
    );
    destroy(wrong_pyth);
    abort 999
}

#[test, expected_failure(abort_code = protocol_config::EValuationInProgress)]
fun update_prices_during_valuation_aborts() {
    let ctx = &mut tx_context::dummy();
    let admin_cap = admin::create_admin_cap_for_testing(ctx);
    let cap = market_oracle::create_cap(&admin_cap, ctx);
    let mut config = protocol_config::new_for_testing(ctx);
    let pyth = pyth_source::new_for_testing(ctx);
    let mut market = market_oracle::create_test_market_oracle_with_pyth(
        &pyth,
        EXPIRY_MS,
        &cap,
        ctx,
    );
    let mut clock = clock::create_for_testing(ctx);
    clock.set_for_testing(NOW_MS);
    config.begin_valuation();

    market.update_block_scholes_prices(
        &config,
        &pyth,
        &cap,
        SPOT_1000,
        FORWARD_AT_BASIS_1,
        FIRST_SOURCE_TIMESTAMP_MS,
        &clock,
    );
    abort 999
}

// === Helpers ===

fun setup_active(
    now_ms: u64,
): (
    market_oracle::MarketOracle,
    protocol_config::ProtocolConfig,
    market_oracle::MarketOracleCap,
    admin::AdminCap,
    pyth_source::PythSource,
    clock::Clock,
) {
    let ctx = &mut tx_context::dummy();
    let admin_cap = admin::create_admin_cap_for_testing(ctx);
    let cap = market_oracle::create_cap(&admin_cap, ctx);
    let config = protocol_config::new_for_testing(ctx);
    let pyth = pyth_source::new_for_testing(ctx);
    let market = market_oracle::create_test_market_oracle_with_pyth(&pyth, EXPIRY_MS, &cap, ctx);
    let mut clock = clock::create_for_testing(ctx);
    clock.set_for_testing(now_ms);
    (market, config, cap, admin_cap, pyth, clock)
}

fun cleanup(
    market: market_oracle::MarketOracle,
    config: protocol_config::ProtocolConfig,
    cap: market_oracle::MarketOracleCap,
    admin_cap: admin::AdminCap,
    pyth: pyth_source::PythSource,
    clock: clock::Clock,
) {
    destroy(market);
    destroy(config);
    destroy(cap);
    destroy(admin_cap);
    destroy(pyth);
    clock.destroy_for_testing();
}
