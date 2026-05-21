// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module deepbook_predict::mint_cutoff_tests;

use deepbook_predict::{
    config_constants,
    market_oracle::{Self, MarketOracle, MarketOracleCap},
    protocol_config::{Self, ProtocolConfig},
    registry::{Self, AdminCap}
};
use std::unit_test::{assert_eq, destroy};
use sui::clock;

const EXPIRY_MS: u64 = 100_000;
const FRESH_NOW_MS: u64 = 10_000; // 90s remaining
const NEAR_EXPIRY_NOW_MS: u64 = 95_000; // 5s remaining
const CUTOFF_MS: u64 = 30_000; // 30s cutoff

#[test]
fun default_mint_cutoff_is_zero() {
    let ctx = &mut tx_context::dummy();
    let (market, config, cap, admin_cap, clock) = setup(ctx);
    assert_eq!(market.mint_cutoff_ms(), 0);
    // Zero cutoff means assert is a no-op even when near expiry.
    market.assert_mint_allowed_for_cutoff(&clock);
    cleanup(market, config, cap, admin_cap, clock);
}

#[test]
fun cap_can_set_mint_cutoff() {
    let ctx = &mut tx_context::dummy();
    let (mut market, config, cap, admin_cap, clock) = setup(ctx);
    market.set_mint_cutoff_ms(&config, &cap, CUTOFF_MS);
    assert_eq!(market.mint_cutoff_ms(), CUTOFF_MS);
    cleanup(market, config, cap, admin_cap, clock);
}

#[test]
fun admin_can_override_mint_cutoff() {
    let ctx = &mut tx_context::dummy();
    let (mut market, config, cap, admin_cap, clock) = setup(ctx);
    registry::set_market_oracle_mint_cutoff_ms(&mut market, &config, &admin_cap, CUTOFF_MS);
    assert_eq!(market.mint_cutoff_ms(), CUTOFF_MS);
    cleanup(market, config, cap, admin_cap, clock);
}

#[test]
fun mint_assert_passes_outside_cutoff_window() {
    let ctx = &mut tx_context::dummy();
    let (mut market, config, cap, admin_cap, mut clock) = setup(ctx);
    clock.set_for_testing(FRESH_NOW_MS); // 90s remaining > 30s cutoff
    market.set_mint_cutoff_ms(&config, &cap, CUTOFF_MS);
    market.assert_mint_allowed_for_cutoff(&clock);
    cleanup(market, config, cap, admin_cap, clock);
}

#[test, expected_failure(abort_code = market_oracle::EMintCutoffReached)]
fun mint_assert_aborts_inside_cutoff_window() {
    let ctx = &mut tx_context::dummy();
    let (mut market, config, cap, _admin_cap, mut clock) = setup(ctx);
    clock.set_for_testing(NEAR_EXPIRY_NOW_MS); // 5s remaining < 30s cutoff
    market.set_mint_cutoff_ms(&config, &cap, CUTOFF_MS);
    market.assert_mint_allowed_for_cutoff(&clock);
    abort 999
}

#[test, expected_failure(abort_code = config_constants::EInvalidMintCutoffMs)]
fun cap_setter_rejects_value_above_bound() {
    let ctx = &mut tx_context::dummy();
    let (mut market, config, cap, _admin_cap, _clock) = setup(ctx);
    let too_high = config_constants::max_mint_cutoff_ms!() + 1;
    market.set_mint_cutoff_ms(&config, &cap, too_high);
    abort 999
}

#[test, expected_failure(abort_code = market_oracle::EInvalidMarketOracleCap)]
fun unregistered_cap_cannot_set_mint_cutoff() {
    let ctx = &mut tx_context::dummy();
    let (mut market, config, _cap, admin_cap, _clock) = setup(ctx);
    let stranger = registry::create_market_oracle_cap(&admin_cap, ctx);
    market.set_mint_cutoff_ms(&config, &stranger, CUTOFF_MS);
    abort 999
}

fun setup(
    ctx: &mut TxContext,
): (MarketOracle, ProtocolConfig, MarketOracleCap, AdminCap, clock::Clock) {
    let admin_cap = registry::create_admin_cap_for_testing(ctx);
    let cap = registry::create_market_oracle_cap(&admin_cap, ctx);
    let config = protocol_config::new_for_testing(ctx);
    let market = market_oracle::create_test_market_oracle(EXPIRY_MS, &cap, ctx);
    let mut clock = clock::create_for_testing(ctx);
    clock.set_for_testing(FRESH_NOW_MS);
    (market, config, cap, admin_cap, clock)
}

fun cleanup(
    market: MarketOracle,
    config: ProtocolConfig,
    cap: MarketOracleCap,
    admin_cap: AdminCap,
    clock: clock::Clock,
) {
    registry::destroy_market_oracle_cap(cap);
    market.destroy_for_testing();
    config.destroy_for_testing();
    clock.destroy_for_testing();
    destroy(admin_cap);
}
