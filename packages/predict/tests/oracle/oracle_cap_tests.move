// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module deepbook_predict::oracle_cap_tests;

use deepbook_predict::{
    admin,
    i64,
    market_oracle::{Self, MarketOracle, MarketOracleWriterCap, MarketOracleLifecycleCap},
    protocol_config::{Self, ProtocolConfig}
};
use std::unit_test::destroy;
use sui::clock;

const NOW_MS: u64 = 10_000;
const EXPIRY_MS: u64 = 100_000;
const FIRST_SVI_SOURCE_TIMESTAMP_MS: u64 = 1_000;
const SECOND_SVI_SOURCE_TIMESTAMP_MS: u64 = 2_000;
const PYTH_FEED_ID: u32 = 1;

#[test]
fun admin_can_create_multiple_market_oracle_caps() {
    let ctx = &mut tx_context::dummy();
    let admin_cap = admin::create_admin_cap_for_testing(ctx);
    let cap_1 = market_oracle::create_writer_cap(&admin_cap, ctx);
    let cap_2 = market_oracle::create_writer_cap(&admin_cap, ctx);

    assert!(cap_1.cap_id() != cap_2.cap_id());
    market_oracle::destroy_writer_cap(cap_1);
    market_oracle::destroy_writer_cap(cap_2);
    destroy(admin_cap);
}

#[test]
fun writer_cap_can_create_multiple_market_oracle_lifecycle_caps() {
    let ctx = &mut tx_context::dummy();
    let admin_cap = admin::create_admin_cap_for_testing(ctx);
    let oracle_writer_cap = market_oracle::create_writer_cap(&admin_cap, ctx);
    let cap_1 = market_oracle::create_lifecycle_cap(
        &oracle_writer_cap,
        PYTH_FEED_ID,
        ctx,
    );
    let cap_2 = market_oracle::create_lifecycle_cap(
        &oracle_writer_cap,
        PYTH_FEED_ID,
        ctx,
    );

    assert!(cap_1.lifecycle_cap_id() != cap_2.lifecycle_cap_id());
    assert!(cap_1.lifecycle_pyth_lazer_feed_id() == PYTH_FEED_ID);
    market_oracle::destroy_lifecycle_cap(cap_1);
    market_oracle::destroy_lifecycle_cap(cap_2);
    market_oracle::destroy_writer_cap(oracle_writer_cap);
    destroy(admin_cap);
}

#[test]
fun creator_cap_can_update_market_oracle() {
    let ctx = &mut tx_context::dummy();
    let (mut market, config, cap, admin_cap, clock) = setup(ctx);

    write_svi(&mut market, &config, &cap, FIRST_SVI_SOURCE_TIMESTAMP_MS, &clock);
    assert!(market.block_scholes_svi_source_timestamp_ms() == FIRST_SVI_SOURCE_TIMESTAMP_MS);

    cleanup(market, config, vector[cap], vector[], admin_cap, clock);
}

#[test]
fun registered_lifecycle_cap_authorizes_market_lifecycle() {
    let ctx = &mut tx_context::dummy();
    let (market, config, cap, admin_cap, clock) = setup(ctx);
    let mut lifecycle_cap = market_oracle::create_lifecycle_cap(
        &cap,
        PYTH_FEED_ID,
        ctx,
    );

    market_oracle::register_lifecycle_cap(&market, &admin_cap, &mut lifecycle_cap);
    market.assert_authorized_lifecycle_cap(&lifecycle_cap);

    cleanup(market, config, vector[cap], vector[lifecycle_cap], admin_cap, clock);
}

#[test, expected_failure(abort_code = market_oracle::EInvalidMarketOracleLifecycleCap)]
fun admin_unregistered_lifecycle_cap_loses_market_lifecycle_access() {
    let ctx = &mut tx_context::dummy();
    let (market, _config, _cap, admin_cap, _clock) = setup(ctx);
    let oracle_writer_cap = market_oracle::create_writer_cap(&admin_cap, ctx);
    let mut lifecycle_cap = market_oracle::create_lifecycle_cap(
        &oracle_writer_cap,
        PYTH_FEED_ID,
        ctx,
    );
    let market_oracle_id = market.id();

    market_oracle::register_lifecycle_cap(&market, &admin_cap, &mut lifecycle_cap);
    market_oracle::unregister_lifecycle_cap(
        &mut lifecycle_cap,
        &admin_cap,
        market_oracle_id,
    );
    market.assert_authorized_lifecycle_cap(&lifecycle_cap);
    abort 999
}

#[test, expected_failure(abort_code = market_oracle::EInvalidMarketOracleLifecycleCap)]
fun unregistered_lifecycle_cap_cannot_authorize_market_lifecycle() {
    let ctx = &mut tx_context::dummy();
    let (market, _config, cap, _admin_cap, _clock) = setup(ctx);
    let lifecycle_cap = market_oracle::create_lifecycle_cap(
        &cap,
        PYTH_FEED_ID,
        ctx,
    );

    market.assert_authorized_lifecycle_cap(&lifecycle_cap);
    abort 999
}

#[test, expected_failure(abort_code = market_oracle::EInvalidMarketOracleLifecycleCap)]
fun self_unregistered_lifecycle_cap_loses_market_lifecycle_access() {
    let ctx = &mut tx_context::dummy();
    let (market, _config, _cap, admin_cap, _clock) = setup(ctx);
    let oracle_writer_cap = market_oracle::create_writer_cap(&admin_cap, ctx);
    let mut lifecycle_cap = market_oracle::create_lifecycle_cap(
        &oracle_writer_cap,
        PYTH_FEED_ID,
        ctx,
    );
    let market_oracle_id = market.id();

    market_oracle::register_lifecycle_cap(&market, &admin_cap, &mut lifecycle_cap);
    market_oracle::self_unregister_lifecycle_cap(&mut lifecycle_cap, market_oracle_id);
    market.assert_authorized_lifecycle_cap(&lifecycle_cap);
    abort 999
}

#[test, expected_failure(abort_code = market_oracle::EInvalidMarketOracleWriterCap)]
fun unregistered_cap_cannot_update_market_oracle() {
    let ctx = &mut tx_context::dummy();
    let (mut market, config, _cap, admin_cap, clock) = setup(ctx);
    let unregistered_cap = market_oracle::create_writer_cap(&admin_cap, ctx);

    write_svi(
        &mut market,
        &config,
        &unregistered_cap,
        FIRST_SVI_SOURCE_TIMESTAMP_MS,
        &clock,
    );
    abort 999
}

#[test]
fun registered_cap_can_update_market_oracle() {
    let ctx = &mut tx_context::dummy();
    let (mut market, config, cap_1, admin_cap, clock) = setup(ctx);
    let cap_2 = market_oracle::create_writer_cap(&admin_cap, ctx);

    market_oracle::register_writer_cap(&mut market, &admin_cap, &cap_2);
    write_svi(&mut market, &config, &cap_2, FIRST_SVI_SOURCE_TIMESTAMP_MS, &clock);
    assert!(market.block_scholes_svi_source_timestamp_ms() == FIRST_SVI_SOURCE_TIMESTAMP_MS);

    cleanup(market, config, vector[cap_1, cap_2], vector[], admin_cap, clock);
}

#[test, expected_failure(abort_code = market_oracle::EInvalidMarketOracleWriterCap)]
fun unregistered_cap_loses_market_oracle_access() {
    let ctx = &mut tx_context::dummy();
    let (mut market, config, _cap_1, admin_cap, clock) = setup(ctx);
    let cap_2 = market_oracle::create_writer_cap(&admin_cap, ctx);

    market_oracle::register_writer_cap(&mut market, &admin_cap, &cap_2);
    write_svi(&mut market, &config, &cap_2, FIRST_SVI_SOURCE_TIMESTAMP_MS, &clock);
    market_oracle::unregister_writer_cap(&mut market, &admin_cap, cap_2.cap_id());
    write_svi(&mut market, &config, &cap_2, SECOND_SVI_SOURCE_TIMESTAMP_MS, &clock);
    abort 999
}

#[test, expected_failure(abort_code = market_oracle::EInvalidMarketOracleWriterCap)]
fun self_unregistered_cap_loses_market_oracle_access() {
    let ctx = &mut tx_context::dummy();
    let (mut market, config, cap, _admin_cap, clock) = setup(ctx);

    market_oracle::self_unregister_writer_cap(&mut market, &cap);
    write_svi(&mut market, &config, &cap, FIRST_SVI_SOURCE_TIMESTAMP_MS, &clock);
    abort 999
}

fun setup(
    ctx: &mut TxContext,
): (MarketOracle, ProtocolConfig, MarketOracleWriterCap, admin::AdminCap, clock::Clock) {
    let admin_cap = admin::create_admin_cap_for_testing(ctx);
    let cap = market_oracle::create_writer_cap(&admin_cap, ctx);
    let config = protocol_config::new_for_testing(ctx);
    let market = market_oracle::create_test_market_oracle(EXPIRY_MS, &cap, ctx);
    let mut clock = clock::create_for_testing(ctx);
    clock.set_for_testing(NOW_MS);
    (market, config, cap, admin_cap, clock)
}

fun cleanup(
    market: MarketOracle,
    config: ProtocolConfig,
    mut caps: vector<MarketOracleWriterCap>,
    mut lifecycle_caps: vector<MarketOracleLifecycleCap>,
    admin_cap: admin::AdminCap,
    clock: clock::Clock,
) {
    while (!caps.is_empty()) {
        market_oracle::destroy_writer_cap(caps.pop_back());
    };
    caps.destroy_empty();
    while (!lifecycle_caps.is_empty()) {
        market_oracle::destroy_lifecycle_cap(lifecycle_caps.pop_back());
    };
    lifecycle_caps.destroy_empty();
    destroy(market);
    destroy(config);
    clock.destroy_for_testing();
    destroy(admin_cap);
}

fun write_svi(
    market: &mut MarketOracle,
    config: &ProtocolConfig,
    cap: &MarketOracleWriterCap,
    source_timestamp_ms: u64,
    clock: &clock::Clock,
) {
    market.update_svi(
        config,
        cap,
        market_oracle::new_svi_params(1, 2, i64::zero(), i64::zero(), 3),
        source_timestamp_ms,
        clock,
    );
}
