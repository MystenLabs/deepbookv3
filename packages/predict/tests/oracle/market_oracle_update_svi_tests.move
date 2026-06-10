// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module deepbook_predict::market_oracle_update_svi_tests;

use deepbook_predict::{admin, i64, market_oracle, protocol_config};
use std::unit_test::{assert_eq, destroy};
use sui::clock;

const EXPIRY_MS: u64 = 100_000;
const NOW_MS: u64 = 10_000;
const FIRST_SVI_SOURCE_TIMESTAMP_MS: u64 = 1_000;
const SECOND_SVI_SOURCE_TIMESTAMP_MS: u64 = 2_000;
const AFTER_EXPIRY_MS: u64 = 200_000;

// Cap-authorization paths (success / unregistered / register / unregister /
// self_unregister) are covered in oracle_cap_tests.move; this file focuses on
// staleness, future-source-timestamp, and lifecycle aborts plus the assertion
// that updated values land in the stored state.

#[test]
fun update_svi_stores_values_and_advances_timestamps() {
    let ctx = &mut tx_context::dummy();
    let admin_cap = admin::create_admin_cap_for_testing(ctx);
    let cap = market_oracle::create_writer_cap(&admin_cap, ctx);
    let config = protocol_config::new_for_testing(ctx);
    let mut market = market_oracle::create_test_market_oracle(EXPIRY_MS, &cap, ctx);
    let mut clock = clock::create_for_testing(ctx);
    clock.set_for_testing(NOW_MS);

    let svi = market_oracle::new_svi_params(11, 22, i64::from_u64(33), i64::from_u64(44), 55);
    market.update_svi(&config, &cap, svi, FIRST_SVI_SOURCE_TIMESTAMP_MS, &clock);

    let stored = market.block_scholes_svi();
    assert_eq!(stored.a(), 11);
    assert_eq!(stored.b(), 22);
    assert_eq!(stored.rho().magnitude(), 33);
    assert_eq!(stored.m().magnitude(), 44);
    assert_eq!(stored.sigma(), 55);
    assert_eq!(market.block_scholes_svi_source_timestamp_ms(), FIRST_SVI_SOURCE_TIMESTAMP_MS);
    assert_eq!(market.block_scholes_svi_update_timestamp_ms(), NOW_MS);

    cleanup(market, config, cap, admin_cap, clock);
}

#[test]
fun update_svi_strictly_advances_source_timestamp() {
    // After a first update at FIRST_SVI_SOURCE_TIMESTAMP_MS, a second update
    // with a strictly greater source timestamp must succeed.
    let ctx = &mut tx_context::dummy();
    let admin_cap = admin::create_admin_cap_for_testing(ctx);
    let cap = market_oracle::create_writer_cap(&admin_cap, ctx);
    let config = protocol_config::new_for_testing(ctx);
    let mut market = market_oracle::create_test_market_oracle(EXPIRY_MS, &cap, ctx);
    let mut clock = clock::create_for_testing(ctx);
    clock.set_for_testing(NOW_MS);

    let svi = market_oracle::new_svi_params(1, 2, i64::zero(), i64::zero(), 3);
    market.update_svi(&config, &cap, svi, FIRST_SVI_SOURCE_TIMESTAMP_MS, &clock);
    market.update_svi(&config, &cap, svi, SECOND_SVI_SOURCE_TIMESTAMP_MS, &clock);

    assert_eq!(market.block_scholes_svi_source_timestamp_ms(), SECOND_SVI_SOURCE_TIMESTAMP_MS);

    cleanup(market, config, cap, admin_cap, clock);
}

#[test, expected_failure(abort_code = market_oracle::EStaleSVISourceUpdate)]
fun update_svi_equal_source_timestamp_aborts() {
    // The check is `source_timestamp_ms > previous`; equal is rejected.
    let ctx = &mut tx_context::dummy();
    let admin_cap = admin::create_admin_cap_for_testing(ctx);
    let cap = market_oracle::create_writer_cap(&admin_cap, ctx);
    let config = protocol_config::new_for_testing(ctx);
    let mut market = market_oracle::create_test_market_oracle(EXPIRY_MS, &cap, ctx);
    let mut clock = clock::create_for_testing(ctx);
    clock.set_for_testing(NOW_MS);
    let svi = market_oracle::new_svi_params(1, 2, i64::zero(), i64::zero(), 3);
    market.update_svi(&config, &cap, svi, FIRST_SVI_SOURCE_TIMESTAMP_MS, &clock);

    market.update_svi(&config, &cap, svi, FIRST_SVI_SOURCE_TIMESTAMP_MS, &clock);
    abort 999
}

#[test, expected_failure(abort_code = market_oracle::EStaleSVISourceUpdate)]
fun update_svi_earlier_source_timestamp_aborts() {
    let ctx = &mut tx_context::dummy();
    let admin_cap = admin::create_admin_cap_for_testing(ctx);
    let cap = market_oracle::create_writer_cap(&admin_cap, ctx);
    let config = protocol_config::new_for_testing(ctx);
    let mut market = market_oracle::create_test_market_oracle(EXPIRY_MS, &cap, ctx);
    let mut clock = clock::create_for_testing(ctx);
    clock.set_for_testing(NOW_MS);
    let svi = market_oracle::new_svi_params(1, 2, i64::zero(), i64::zero(), 3);
    market.update_svi(&config, &cap, svi, SECOND_SVI_SOURCE_TIMESTAMP_MS, &clock);

    market.update_svi(&config, &cap, svi, FIRST_SVI_SOURCE_TIMESTAMP_MS, &clock);
    abort 999
}

#[test, expected_failure(abort_code = market_oracle::EFutureSVISourceUpdate)]
fun update_svi_source_timestamp_after_now_aborts() {
    // Source timestamp from the publisher must not be ahead of the on-chain clock.
    let ctx = &mut tx_context::dummy();
    let admin_cap = admin::create_admin_cap_for_testing(ctx);
    let cap = market_oracle::create_writer_cap(&admin_cap, ctx);
    let config = protocol_config::new_for_testing(ctx);
    let mut market = market_oracle::create_test_market_oracle(EXPIRY_MS, &cap, ctx);
    let mut clock = clock::create_for_testing(ctx);
    clock.set_for_testing(NOW_MS);

    let svi = market_oracle::new_svi_params(1, 2, i64::zero(), i64::zero(), 3);
    market.update_svi(&config, &cap, svi, NOW_MS + 1, &clock);
    abort 999
}

#[test]
fun update_svi_source_equal_to_now_is_allowed() {
    // The future-timestamp guard is `<=`, so source_ts == now is permitted.
    let ctx = &mut tx_context::dummy();
    let admin_cap = admin::create_admin_cap_for_testing(ctx);
    let cap = market_oracle::create_writer_cap(&admin_cap, ctx);
    let config = protocol_config::new_for_testing(ctx);
    let mut market = market_oracle::create_test_market_oracle(EXPIRY_MS, &cap, ctx);
    let mut clock = clock::create_for_testing(ctx);
    clock.set_for_testing(NOW_MS);

    let svi = market_oracle::new_svi_params(1, 2, i64::zero(), i64::zero(), 3);
    market.update_svi(&config, &cap, svi, NOW_MS, &clock);
    assert_eq!(market.block_scholes_svi_source_timestamp_ms(), NOW_MS);

    cleanup(market, config, cap, admin_cap, clock);
}

#[test, expected_failure(abort_code = market_oracle::EMarketNotActive)]
fun update_svi_after_expiry_aborts() {
    // Status switches to pending_settlement at expiry; update_svi is
    // active-market-only.
    let ctx = &mut tx_context::dummy();
    let admin_cap = admin::create_admin_cap_for_testing(ctx);
    let cap = market_oracle::create_writer_cap(&admin_cap, ctx);
    let config = protocol_config::new_for_testing(ctx);
    let mut market = market_oracle::create_test_market_oracle(EXPIRY_MS, &cap, ctx);
    let mut clock = clock::create_for_testing(ctx);
    clock.set_for_testing(AFTER_EXPIRY_MS);

    let svi = market_oracle::new_svi_params(1, 2, i64::zero(), i64::zero(), 3);
    market.update_svi(&config, &cap, svi, FIRST_SVI_SOURCE_TIMESTAMP_MS, &clock);
    abort 999
}

#[test, expected_failure(abort_code = protocol_config::EValuationInProgress)]
fun update_svi_during_valuation_aborts() {
    // protocol_config gates this via assert_not_valuation_in_progress.
    let ctx = &mut tx_context::dummy();
    let admin_cap = admin::create_admin_cap_for_testing(ctx);
    let cap = market_oracle::create_writer_cap(&admin_cap, ctx);
    let mut config = protocol_config::new_for_testing(ctx);
    let mut market = market_oracle::create_test_market_oracle(EXPIRY_MS, &cap, ctx);
    let mut clock = clock::create_for_testing(ctx);
    clock.set_for_testing(NOW_MS);
    config.begin_valuation();

    let svi = market_oracle::new_svi_params(1, 2, i64::zero(), i64::zero(), 3);
    market.update_svi(&config, &cap, svi, FIRST_SVI_SOURCE_TIMESTAMP_MS, &clock);
    abort 999
}

fun cleanup(
    market: market_oracle::MarketOracle,
    config: protocol_config::ProtocolConfig,
    cap: market_oracle::MarketOracleWriterCap,
    admin_cap: admin::AdminCap,
    clock: clock::Clock,
) {
    destroy(market);
    destroy(config);
    destroy(cap);
    destroy(admin_cap);
    clock.destroy_for_testing();
}
