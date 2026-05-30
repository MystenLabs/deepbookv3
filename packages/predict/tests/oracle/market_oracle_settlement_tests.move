// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

#[test_only]
#[allow(unused_variable)]
module deepbook_predict::market_oracle_settlement_tests;

use deepbook_predict::{market_oracle, protocol_config, pyth_source};
use std::unit_test::{assert_eq, destroy};
use sui::clock;

const EXPIRY_MS: u64 = 100_000;
const SETTLE_TS: u64 = 150_000;
const NOW_MS: u64 = 151_000; // settlement_freshness default is 3000 ms
const ACTIVE_NOW_MS: u64 = 50_000;
const SPOT_1000: u64 = 1_000_000_000_000;
const FORWARD_AT_BASIS_1: u64 = 1_000_000_000_000;

// === settle_if_possible: status gating ===

#[test]
fun settle_if_possible_returns_false_when_active() {
    let (mut market, config, cap, pyth, clock) = setup(ACTIVE_NOW_MS);

    assert!(!market.settle_if_possible(&config, &pyth, &cap, &clock));
    assert!(!market.is_settled());

    cleanup(market, config, cap, pyth, clock);
}

#[test]
fun settle_if_possible_returns_false_when_no_valid_source() {
    // Pending settlement (clock > expiry) but neither Pyth nor BS has data.
    let (mut market, config, cap, pyth, clock) = setup(NOW_MS);
    assert_eq!(market.status(&clock), market_oracle::status_pending_settlement());

    assert!(!market.settle_if_possible(&config, &pyth, &cap, &clock));
    assert!(!market.is_settled());

    cleanup(market, config, cap, pyth, clock);
}

// === settle_if_possible: Pyth path ===

#[test]
fun settle_if_possible_uses_pyth_when_fresh() {
    let (mut market, config, cap, mut pyth, clock) = setup(NOW_MS);
    // Drive pyth state so its source_ts > expiry and freshness is within
    // settlement_freshness (3000ms default).
    pyth.set_state_for_testing(SPOT_1000, SETTLE_TS, NOW_MS);

    assert!(market.settle_if_possible(&config, &pyth, &cap, &clock));
    assert!(market.is_settled());
    let raw = market.raw_settlement_price();
    assert!(raw.is_some());
    assert_eq!(*raw.borrow(), SPOT_1000);

    cleanup(market, config, cap, pyth, clock);
}

#[test]
fun settle_if_possible_returns_false_when_pyth_stale() {
    // Pyth update too old relative to settlement_freshness (3000 ms default).
    let (mut market, config, cap, mut pyth, clock) = setup(NOW_MS);
    // freshness_timestamp = min(source_ts, update_ts) = 100_001. now - 100_001
    // = 50_999 > 3_000, so Pyth fails the freshness check.
    pyth.set_state_for_testing(SPOT_1000, 100_001, 100_001);

    assert!(!market.settle_if_possible(&config, &pyth, &cap, &clock));
    assert!(!market.is_settled());

    cleanup(market, config, cap, pyth, clock);
}

#[test]
fun settle_if_possible_returns_false_when_pyth_source_at_expiry() {
    // source_ts must be strictly greater than expiry, not equal.
    let (mut market, config, cap, mut pyth, clock) = setup(NOW_MS);
    pyth.set_state_for_testing(SPOT_1000, EXPIRY_MS, NOW_MS);

    assert!(!market.settle_if_possible(&config, &pyth, &cap, &clock));

    cleanup(market, config, cap, pyth, clock);
}

// === settle_if_possible: Block Scholes fallback via update_block_scholes_prices ===

#[test]
fun update_prices_at_pending_settles_via_block_scholes_when_pyth_empty() {
    // Pyth has no data, but a Block Scholes update lands after expiry with
    // source_ts > expiry. The internal settle_if_possible_internal at the end
    // of update_block_scholes_prices uses the BS fallback.
    let (mut market, config, cap, pyth, clock) = setup(NOW_MS);
    market.update_block_scholes_prices(
        &config,
        &pyth,
        &cap,
        SPOT_1000,
        FORWARD_AT_BASIS_1,
        SETTLE_TS,
        &clock,
    );

    assert!(market.is_settled());
    let raw = market.raw_settlement_price();
    assert!(raw.is_some());
    assert_eq!(*raw.borrow(), SPOT_1000);

    cleanup(market, config, cap, pyth, clock);
}

#[test]
fun update_prices_at_pending_does_not_settle_when_source_ts_at_expiry() {
    // source_ts must be strictly greater than expiry to qualify as settlement data.
    let (mut market, config, cap, pyth, clock) = setup(NOW_MS);
    market.update_block_scholes_prices(
        &config,
        &pyth,
        &cap,
        SPOT_1000,
        FORWARD_AT_BASIS_1,
        EXPIRY_MS,
        &clock,
    );

    assert!(!market.is_settled());

    cleanup(market, config, cap, pyth, clock);
}

// === update_block_scholes_prices aborts EMarketSettled after settle ===

#[test, expected_failure(abort_code = market_oracle::EMarketSettled)]
fun update_prices_after_settle_aborts() {
    let (mut market, config, cap, mut pyth, clock) = setup(NOW_MS);
    pyth.set_state_for_testing(SPOT_1000, SETTLE_TS, NOW_MS);
    market.settle_if_possible(&config, &pyth, &cap, &clock);
    assert!(market.is_settled());

    // Second price push is now an attempt to mutate a settled market.
    market.update_block_scholes_prices(
        &config,
        &pyth,
        &cap,
        SPOT_1000,
        FORWARD_AT_BASIS_1,
        SETTLE_TS + 1,
        &clock,
    );
    abort 999
}

// === assert_not_pending_settlement ===

#[test]
fun assert_not_pending_settlement_passes_when_active() {
    let (market, config, cap, pyth, clock) = setup(ACTIVE_NOW_MS);
    market.assert_not_pending_settlement(&clock);
    cleanup(market, config, cap, pyth, clock);
}

#[test]
fun assert_not_pending_settlement_passes_when_settled() {
    let (mut market, config, cap, mut pyth, clock) = setup(NOW_MS);
    pyth.set_state_for_testing(SPOT_1000, SETTLE_TS, NOW_MS);
    market.settle_if_possible(&config, &pyth, &cap, &clock);

    market.assert_not_pending_settlement(&clock);

    cleanup(market, config, cap, pyth, clock);
}

#[test, expected_failure(abort_code = market_oracle::EPendingSettlement)]
fun assert_not_pending_settlement_aborts_when_pending() {
    let (market, config, cap, pyth, clock) = setup(NOW_MS);
    assert_eq!(market.status(&clock), market_oracle::status_pending_settlement());

    market.assert_not_pending_settlement(&clock);
    abort 999
}

// === settlement_price ===

#[test, expected_failure(abort_code = market_oracle::EMarketNotSettled)]
fun settlement_price_on_unsettled_aborts() {
    let (market, config, cap, pyth, clock) = setup(NOW_MS);
    let _ = market.settlement_price();
    abort 999
}

#[test]
fun settlement_price_returns_settled_value() {
    let (mut market, config, cap, mut pyth, clock) = setup(NOW_MS);
    pyth.set_state_for_testing(SPOT_1000, SETTLE_TS, NOW_MS);
    market.settle_if_possible(&config, &pyth, &cap, &clock);

    assert_eq!(market.settlement_price(), SPOT_1000);

    cleanup(market, config, cap, pyth, clock);
}

// EInvalidSettlementTimestamp guards against a settled state where
// settlement_source_timestamp_ms <= expiry. valid_settlement_spot_source
// always requires source_ts > expiry before calling settle(), so this is
// defense-in-depth that cannot be triggered through any production path
// without a test-only bypass — not exercised here.

fun setup(
    now_ms: u64,
): (
    market_oracle::MarketOracle,
    protocol_config::ProtocolConfig,
    market_oracle::MarketOracleCap,
    pyth_source::PythSource,
    clock::Clock,
) {
    let ctx = &mut tx_context::dummy();
    let cap = market_oracle::create_cap(ctx);
    let config = protocol_config::new_for_testing(ctx);
    let pyth = pyth_source::new_for_testing(ctx);
    let market = market_oracle::create_test_market_oracle_with_pyth(&pyth, EXPIRY_MS, &cap, ctx);
    let mut clock = clock::create_for_testing(ctx);
    clock.set_for_testing(now_ms);
    (market, config, cap, pyth, clock)
}

fun cleanup(
    market: market_oracle::MarketOracle,
    config: protocol_config::ProtocolConfig,
    cap: market_oracle::MarketOracleCap,
    pyth: pyth_source::PythSource,
    clock: clock::Clock,
) {
    destroy(market);
    destroy(config);
    destroy(cap);
    destroy(pyth);
    clock.destroy_for_testing();
}
