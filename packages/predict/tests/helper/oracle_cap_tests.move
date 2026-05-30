// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module deepbook_predict::oracle_cap_tests;

use deepbook_predict::{
    i64,
    market_oracle::{Self, MarketOracle, MarketOracleCap},
    protocol_config::{Self, ProtocolConfig},
    registry,
    test_helpers
};
use std::unit_test::destroy;
use sui::clock;

const NOW_MS: u64 = 10_000;
const EXPIRY_MS: u64 = 100_000;
const FIRST_SVI_SOURCE_TIMESTAMP_MS: u64 = 1_000;
const SECOND_SVI_SOURCE_TIMESTAMP_MS: u64 = 2_000;

#[test]
fun admin_can_create_multiple_market_oracle_caps() {
    let (mut scenario, registry, admin_cap) = test_helpers::begin_registry_test();
    let cap_1 = registry::create_market_oracle_cap(&admin_cap, scenario.ctx());
    let cap_2 = registry::create_market_oracle_cap(&admin_cap, scenario.ctx());

    assert!(cap_1.cap_id() != cap_2.cap_id());
    registry::destroy_market_oracle_cap(cap_1);
    registry::destroy_market_oracle_cap(cap_2);
    test_helpers::finish_registry_test(scenario, registry, admin_cap);
}

#[test]
fun creator_cap_can_update_market_oracle() {
    let (mut scenario, registry, admin_cap) = test_helpers::begin_registry_test();
    let (mut market, config, cap, clock) = setup(scenario.ctx(), &admin_cap);

    write_svi(&mut market, &config, &cap, FIRST_SVI_SOURCE_TIMESTAMP_MS, &clock);
    assert!(market.block_scholes_svi_source_timestamp_ms() == FIRST_SVI_SOURCE_TIMESTAMP_MS);

    cleanup(market, config, vector[cap], clock);
    test_helpers::finish_registry_test(scenario, registry, admin_cap);
}

#[test, expected_failure(abort_code = market_oracle::EInvalidMarketOracleCap)]
fun unregistered_cap_cannot_update_market_oracle() {
    let (mut scenario, _registry, admin_cap) = test_helpers::begin_registry_test();
    let (mut market, config, _cap, clock) = setup(scenario.ctx(), &admin_cap);
    let unregistered_cap = registry::create_market_oracle_cap(&admin_cap, scenario.ctx());

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
    let (mut scenario, registry, admin_cap) = test_helpers::begin_registry_test();
    let (mut market, config, cap_1, clock) = setup(scenario.ctx(), &admin_cap);
    let cap_2 = registry::create_market_oracle_cap(&admin_cap, scenario.ctx());

    registry::register_market_oracle_cap(&mut market, &admin_cap, &cap_2);
    write_svi(&mut market, &config, &cap_2, FIRST_SVI_SOURCE_TIMESTAMP_MS, &clock);
    assert!(market.block_scholes_svi_source_timestamp_ms() == FIRST_SVI_SOURCE_TIMESTAMP_MS);

    cleanup(market, config, vector[cap_1, cap_2], clock);
    test_helpers::finish_registry_test(scenario, registry, admin_cap);
}

#[test, expected_failure(abort_code = market_oracle::EInvalidMarketOracleCap)]
fun unregistered_cap_loses_market_oracle_access() {
    let (mut scenario, _registry, admin_cap) = test_helpers::begin_registry_test();
    let (mut market, config, _cap_1, clock) = setup(scenario.ctx(), &admin_cap);
    let cap_2 = registry::create_market_oracle_cap(&admin_cap, scenario.ctx());

    registry::register_market_oracle_cap(&mut market, &admin_cap, &cap_2);
    write_svi(&mut market, &config, &cap_2, FIRST_SVI_SOURCE_TIMESTAMP_MS, &clock);
    registry::unregister_market_oracle_cap(&mut market, &admin_cap, cap_2.cap_id());
    write_svi(&mut market, &config, &cap_2, SECOND_SVI_SOURCE_TIMESTAMP_MS, &clock);
    abort 999
}

#[test, expected_failure(abort_code = market_oracle::EInvalidMarketOracleCap)]
fun self_unregistered_cap_loses_market_oracle_access() {
    let (mut scenario, _registry, admin_cap) = test_helpers::begin_registry_test();
    let (mut market, config, cap, clock) = setup(scenario.ctx(), &admin_cap);

    registry::self_unregister_market_oracle_cap(&mut market, &cap);
    write_svi(&mut market, &config, &cap, FIRST_SVI_SOURCE_TIMESTAMP_MS, &clock);
    abort 999
}

fun setup(
    ctx: &mut TxContext,
    admin_cap: &registry::AdminCap,
): (MarketOracle, ProtocolConfig, MarketOracleCap, clock::Clock) {
    let cap = registry::create_market_oracle_cap(admin_cap, ctx);
    let config = protocol_config::new_for_testing(ctx);
    let market = market_oracle::create_test_market_oracle(EXPIRY_MS, &cap, ctx);
    let mut clock = clock::create_for_testing(ctx);
    clock.set_for_testing(NOW_MS);
    (market, config, cap, clock)
}

fun cleanup(
    market: MarketOracle,
    config: ProtocolConfig,
    mut caps: vector<MarketOracleCap>,
    clock: clock::Clock,
) {
    while (!caps.is_empty()) {
        registry::destroy_market_oracle_cap(caps.pop_back());
    };
    caps.destroy_empty();
    destroy(market);
    destroy(config);
    clock.destroy_for_testing();
}

fun write_svi(
    market: &mut MarketOracle,
    config: &ProtocolConfig,
    cap: &MarketOracleCap,
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
