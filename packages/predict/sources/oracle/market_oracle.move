// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Per-expiry Predict market oracle state and write API.
///
/// This module owns market-specific state: expiry, settlement, operator
/// authorization, Pyth source binding, bounds, and inline Block Scholes data.
/// It reads Pyth only on terminal Block Scholes price updates to choose the
/// settlement spot without making trade flows mutate the oracle.
module deepbook_predict::market_oracle;

use deepbook::math;
use deepbook_predict::{i64, pyth_source::PythSource, tuning_constants};
use std::string::String;
use sui::{clock::Clock, event};

const EInvalidMarketOracleCap: u64 = 0;
const EMarketExpired: u64 = 1;
const EMarketSettled: u64 = 3;
const EInvalidFreshnessThreshold: u64 = 5;
const EInvalidBasisBounds: u64 = 6;
const ESpotDeviationTooLarge: u64 = 7;
const EBasisDeviationTooLarge: u64 = 8;
const EBasisOutOfRange: u64 = 9;
const EZeroSpot: u64 = 10;
const EZeroForward: u64 = 11;
const EStalePriceSourceUpdate: u64 = 12;
const EStaleSVISourceUpdate: u64 = 13;
const EWrongPythSource: u64 = 14;
const EBlockScholesSettlementStale: u64 = 15;

const STATUS_ACTIVE: u8 = 1;
const STATUS_PENDING_SETTLEMENT: u8 = 2;
const STATUS_SETTLED: u8 = 3;

const SOURCE_PYTH: u8 = 1;
const SOURCE_BLOCK_SCHOLES: u8 = 2;

/// SVI volatility surface parameters supplied by Block Scholes.
public struct SVIParams has copy, drop, store {
    a: u64,
    b: u64,
    rho: i64::I64,
    m: i64::I64,
    sigma: u64,
}

public struct BlockScholesPricesUpdated has copy, drop, store {
    market_oracle_id: ID,
    spot: u64,
    forward: u64,
    basis: u64,
    source_timestamp_ms: u64,
    update_timestamp_ms: u64,
}

public struct BlockScholesSVIUpdated has copy, drop, store {
    market_oracle_id: ID,
    a: u64,
    b: u64,
    rho: i64::I64,
    m: i64::I64,
    sigma: u64,
    source_timestamp_ms: u64,
    update_timestamp_ms: u64,
}

public struct MarketOracleBoundsUpdated has copy, drop, store {
    market_oracle_id: ID,
    pyth_spot_freshness_ms: u64,
    block_scholes_prices_freshness_ms: u64,
    block_scholes_svi_freshness_ms: u64,
    max_spot_deviation: u64,
    max_basis_deviation: u64,
    min_basis: u64,
    max_basis: u64,
}

public struct MarketOracleSettled has copy, drop, store {
    market_oracle_id: ID,
    expiry: u64,
    settlement_price: u64,
    spot_source: u8,
    source_timestamp_ms: u64,
    update_timestamp_ms: u64,
}

public struct MarketOracleBounds has copy, drop, store {
    pyth_spot_freshness_ms: u64,
    block_scholes_prices_freshness_ms: u64,
    block_scholes_svi_freshness_ms: u64,
    max_spot_deviation: u64,
    max_basis_deviation: u64,
    min_basis: u64,
    max_basis: u64,
}

public struct MarketOracle has key {
    id: UID,
    cap_id: ID,
    underlying_asset: String,
    pyth_source_id: ID,
    expiry: u64,
    block_scholes_spot: u64,
    block_scholes_forward: u64,
    block_scholes_price_source_timestamp_ms: u64,
    block_scholes_price_update_timestamp_ms: u64,
    block_scholes_svi: SVIParams,
    block_scholes_svi_source_timestamp_ms: u64,
    block_scholes_svi_update_timestamp_ms: u64,
    bounds: MarketOracleBounds,
    settlement_price: Option<u64>,
}

public struct MarketOracleCap has key, store {
    id: UID,
}

// === Public Functions ===

public fun new_svi_params(a: u64, b: u64, rho: i64::I64, m: i64::I64, sigma: u64): SVIParams {
    SVIParams { a, b, rho, m, sigma }
}

public fun id(market: &MarketOracle): ID {
    market.id.to_inner()
}

public fun cap_id(cap: &MarketOracleCap): ID {
    cap.id.to_inner()
}

public fun authorized_cap_id(market: &MarketOracle): ID {
    market.cap_id
}

public fun underlying_asset(market: &MarketOracle): String {
    market.underlying_asset
}

public fun pyth_source_id(market: &MarketOracle): ID {
    market.pyth_source_id
}

public fun expiry(market: &MarketOracle): u64 {
    market.expiry
}

public fun is_settled(market: &MarketOracle): bool {
    market.settlement_price.is_some()
}

public fun settlement_price(market: &MarketOracle): Option<u64> {
    market.settlement_price
}

public fun status(market: &MarketOracle, clock: &Clock): u8 {
    if (market.is_settled()) {
        STATUS_SETTLED
    } else if (clock.timestamp_ms() >= market.expiry) {
        STATUS_PENDING_SETTLEMENT
    } else {
        STATUS_ACTIVE
    }
}

public fun status_active(): u8 {
    STATUS_ACTIVE
}

public fun status_pending_settlement(): u8 {
    STATUS_PENDING_SETTLEMENT
}

public fun status_settled(): u8 {
    STATUS_SETTLED
}

public fun source_pyth(): u8 {
    SOURCE_PYTH
}

public fun source_block_scholes(): u8 {
    SOURCE_BLOCK_SCHOLES
}

public fun block_scholes_spot(market: &MarketOracle): u64 {
    market.block_scholes_spot
}

public fun block_scholes_forward(market: &MarketOracle): u64 {
    market.block_scholes_forward
}

public fun block_scholes_basis(market: &MarketOracle): u64 {
    assert!(market.block_scholes_spot > 0, EZeroSpot);
    assert!(market.block_scholes_forward > 0, EZeroForward);
    math::div(market.block_scholes_forward, market.block_scholes_spot)
}

public fun block_scholes_price_source_timestamp_ms(market: &MarketOracle): u64 {
    market.block_scholes_price_source_timestamp_ms
}

public fun block_scholes_price_update_timestamp_ms(market: &MarketOracle): u64 {
    market.block_scholes_price_update_timestamp_ms
}

public fun block_scholes_svi(market: &MarketOracle): SVIParams {
    market.block_scholes_svi
}

public fun svi_a(svi: &SVIParams): u64 {
    svi.a
}

public fun svi_b(svi: &SVIParams): u64 {
    svi.b
}

public fun svi_rho(svi: &SVIParams): i64::I64 {
    svi.rho
}

public fun svi_m(svi: &SVIParams): i64::I64 {
    svi.m
}

public fun svi_sigma(svi: &SVIParams): u64 {
    svi.sigma
}

public fun block_scholes_svi_source_timestamp_ms(market: &MarketOracle): u64 {
    market.block_scholes_svi_source_timestamp_ms
}

public fun block_scholes_svi_update_timestamp_ms(market: &MarketOracle): u64 {
    market.block_scholes_svi_update_timestamp_ms
}

public fun bounds(market: &MarketOracle): MarketOracleBounds {
    market.bounds
}

public fun bounds_pyth_spot_freshness_ms(bounds: &MarketOracleBounds): u64 {
    bounds.pyth_spot_freshness_ms
}

public fun bounds_block_scholes_prices_freshness_ms(bounds: &MarketOracleBounds): u64 {
    bounds.block_scholes_prices_freshness_ms
}

public fun bounds_block_scholes_svi_freshness_ms(bounds: &MarketOracleBounds): u64 {
    bounds.block_scholes_svi_freshness_ms
}

public fun bounds_max_spot_deviation(bounds: &MarketOracleBounds): u64 {
    bounds.max_spot_deviation
}

public fun bounds_max_basis_deviation(bounds: &MarketOracleBounds): u64 {
    bounds.max_basis_deviation
}

public fun bounds_min_basis(bounds: &MarketOracleBounds): u64 {
    bounds.min_basis
}

public fun bounds_max_basis(bounds: &MarketOracleBounds): u64 {
    bounds.max_basis
}

public fun update_prices(
    market: &mut MarketOracle,
    pyth: &PythSource,
    cap: &MarketOracleCap,
    spot: u64,
    forward: u64,
    source_timestamp_ms: u64,
    clock: &Clock,
) {
    market.assert_authorized_cap(cap);
    market.assert_pyth_source_id(pyth.id());

    let status = market.status(clock);
    assert!(status != STATUS_SETTLED, EMarketSettled);

    if (status == STATUS_PENDING_SETTLEMENT) {
        if (market.pyth_spot_qualifies_for_settlement(pyth, clock)) {
            market.settle(
                pyth.spot(),
                SOURCE_PYTH,
                pyth.source_timestamp_us() / 1000,
                pyth.update_timestamp_ms(),
            );
            return
        };

        let basis = market.validate_block_scholes_price_update(spot, forward, source_timestamp_ms);
        let update_timestamp_ms = clock.timestamp_ms();
        assert!(
            timestamps_are_fresh(
                update_timestamp_ms,
                source_timestamp_ms,
                update_timestamp_ms,
                market.bounds.block_scholes_prices_freshness_ms,
            ),
            EBlockScholesSettlementStale,
        );
        assert!(
            effective_timestamp_ms(source_timestamp_ms, update_timestamp_ms) > market.expiry,
            EBlockScholesSettlementStale,
        );
        market.validate_basis_push(spot, basis);
        market.apply_block_scholes_prices(spot, forward, basis, source_timestamp_ms, clock);
        market.settle(spot, SOURCE_BLOCK_SCHOLES, source_timestamp_ms, update_timestamp_ms);
        return
    };

    let basis = market.validate_block_scholes_price_update(spot, forward, source_timestamp_ms);
    market.validate_basis_push(spot, basis);
    market.apply_block_scholes_prices(spot, forward, basis, source_timestamp_ms, clock);
}

public fun update_svi(
    market: &mut MarketOracle,
    cap: &MarketOracleCap,
    svi: SVIParams,
    source_timestamp_ms: u64,
    clock: &Clock,
) {
    market.assert_authorized_cap(cap);
    assert!(market.status(clock) == STATUS_ACTIVE, EMarketExpired);
    assert!(
        source_timestamp_ms > market.block_scholes_svi_source_timestamp_ms,
        EStaleSVISourceUpdate,
    );
    market.block_scholes_svi = svi;
    market.block_scholes_svi_source_timestamp_ms = source_timestamp_ms;
    market.block_scholes_svi_update_timestamp_ms = clock.timestamp_ms();

    event::emit(BlockScholesSVIUpdated {
        market_oracle_id: market.id.to_inner(),
        a: svi_a(&svi),
        b: svi_b(&svi),
        rho: svi_rho(&svi),
        m: svi_m(&svi),
        sigma: svi_sigma(&svi),
        source_timestamp_ms,
        update_timestamp_ms: clock.timestamp_ms(),
    });
}

public fun set_pyth_spot_freshness_ms(
    market: &mut MarketOracle,
    cap: &MarketOracleCap,
    value: u64,
) {
    market.assert_authorized_cap(cap);
    validate_freshness_ms(value);
    market.bounds.pyth_spot_freshness_ms = value;
    market.emit_bounds_updated();
}

public fun set_block_scholes_prices_freshness_ms(
    market: &mut MarketOracle,
    cap: &MarketOracleCap,
    value: u64,
) {
    market.assert_authorized_cap(cap);
    validate_freshness_ms(value);
    market.bounds.block_scholes_prices_freshness_ms = value;
    market.emit_bounds_updated();
}

public fun set_block_scholes_svi_freshness_ms(
    market: &mut MarketOracle,
    cap: &MarketOracleCap,
    value: u64,
) {
    market.assert_authorized_cap(cap);
    validate_freshness_ms(value);
    market.bounds.block_scholes_svi_freshness_ms = value;
    market.emit_bounds_updated();
}

public fun set_basis_bounds(
    market: &mut MarketOracle,
    cap: &MarketOracleCap,
    max_spot_deviation: u64,
    max_basis_deviation: u64,
    min_basis: u64,
    max_basis: u64,
) {
    market.assert_authorized_cap(cap);
    validate_basis_bounds_inputs(max_spot_deviation, max_basis_deviation, min_basis, max_basis);
    market.bounds.max_spot_deviation = max_spot_deviation;
    market.bounds.max_basis_deviation = max_basis_deviation;
    market.bounds.min_basis = min_basis;
    market.bounds.max_basis = max_basis;
    market.emit_bounds_updated();
}

// === Public-Package Functions ===

public(package) fun create_cap(ctx: &mut TxContext): MarketOracleCap {
    MarketOracleCap { id: object::new(ctx) }
}

public(package) fun create(
    underlying_asset: String,
    pyth_source_id: ID,
    expiry: u64,
    bounds: MarketOracleBounds,
    cap: &MarketOracleCap,
    ctx: &mut TxContext,
): ID {
    let uid = object::new(ctx);
    let market_oracle_id = uid.to_inner();
    let cap_id = cap.id.to_inner();
    let market = MarketOracle {
        id: uid,
        cap_id,
        underlying_asset,
        pyth_source_id,
        expiry,
        block_scholes_spot: 0,
        block_scholes_forward: 0,
        block_scholes_price_source_timestamp_ms: 0,
        block_scholes_price_update_timestamp_ms: 0,
        block_scholes_svi: SVIParams {
            a: 0,
            b: 0,
            rho: i64::zero(),
            m: i64::zero(),
            sigma: 0,
        },
        block_scholes_svi_source_timestamp_ms: 0,
        block_scholes_svi_update_timestamp_ms: 0,
        bounds,
        settlement_price: option::none(),
    };

    transfer::share_object(market);
    market_oracle_id
}

public(package) fun new_bounds(
    pyth_spot_freshness_ms: u64,
    block_scholes_prices_freshness_ms: u64,
    block_scholes_svi_freshness_ms: u64,
    max_spot_deviation: u64,
    max_basis_deviation: u64,
    min_basis: u64,
    max_basis: u64,
): MarketOracleBounds {
    validate_freshness_ms(pyth_spot_freshness_ms);
    validate_freshness_ms(block_scholes_prices_freshness_ms);
    validate_freshness_ms(block_scholes_svi_freshness_ms);
    validate_basis_bounds_inputs(max_spot_deviation, max_basis_deviation, min_basis, max_basis);

    MarketOracleBounds {
        pyth_spot_freshness_ms,
        block_scholes_prices_freshness_ms,
        block_scholes_svi_freshness_ms,
        max_spot_deviation,
        max_basis_deviation,
        min_basis,
        max_basis,
    }
}

public(package) fun assert_authorized_cap(market: &MarketOracle, cap: &MarketOracleCap) {
    assert!(market.cap_id == cap.id.to_inner(), EInvalidMarketOracleCap);
}

public(package) fun assert_pyth_source_id(market: &MarketOracle, pyth_source_id: ID) {
    assert!(market.pyth_source_id == pyth_source_id, EWrongPythSource);
}

public(package) fun pyth_spot_is_live_fresh(
    market: &MarketOracle,
    pyth: &PythSource,
    clock: &Clock,
): bool {
    market.assert_pyth_source_id(pyth.id());
    pyth_spot_is_fresh(pyth, clock, market.bounds.pyth_spot_freshness_ms)
}

public(package) fun block_scholes_price_is_fresh(market: &MarketOracle, clock: &Clock): bool {
    timestamps_are_fresh(
        clock.timestamp_ms(),
        market.block_scholes_price_source_timestamp_ms,
        market.block_scholes_price_update_timestamp_ms,
        market.bounds.block_scholes_prices_freshness_ms,
    )
}

public(package) fun block_scholes_svi_is_fresh(market: &MarketOracle, clock: &Clock): bool {
    timestamps_are_fresh(
        clock.timestamp_ms(),
        market.block_scholes_svi_source_timestamp_ms,
        market.block_scholes_svi_update_timestamp_ms,
        market.bounds.block_scholes_svi_freshness_ms,
    )
}

// === Private Functions ===

fun apply_block_scholes_prices(
    market: &mut MarketOracle,
    spot: u64,
    forward: u64,
    basis: u64,
    source_timestamp_ms: u64,
    clock: &Clock,
) {
    let update_timestamp_ms = clock.timestamp_ms();
    market.block_scholes_spot = spot;
    market.block_scholes_forward = forward;
    market.block_scholes_price_source_timestamp_ms = source_timestamp_ms;
    market.block_scholes_price_update_timestamp_ms = update_timestamp_ms;

    event::emit(BlockScholesPricesUpdated {
        market_oracle_id: market.id.to_inner(),
        spot,
        forward,
        basis,
        source_timestamp_ms,
        update_timestamp_ms,
    });
}

fun validate_block_scholes_price_update(
    market: &MarketOracle,
    spot: u64,
    forward: u64,
    source_timestamp_ms: u64,
): u64 {
    assert!(spot > 0, EZeroSpot);
    assert!(forward > 0, EZeroForward);
    assert!(
        source_timestamp_ms > market.block_scholes_price_source_timestamp_ms,
        EStalePriceSourceUpdate,
    );

    math::div(forward, spot)
}

fun pyth_spot_qualifies_for_settlement(
    market: &MarketOracle,
    pyth: &PythSource,
    clock: &Clock,
): bool {
    pyth_spot_is_fresh(pyth, clock, market.bounds.pyth_spot_freshness_ms)
        && pyth_effective_timestamp_ms(pyth) > market.expiry
}

fun settle(
    market: &mut MarketOracle,
    settlement_price: u64,
    spot_source: u8,
    source_timestamp_ms: u64,
    update_timestamp_ms: u64,
) {
    market.settlement_price = option::some(settlement_price);

    event::emit(MarketOracleSettled {
        market_oracle_id: market.id.to_inner(),
        expiry: market.expiry,
        settlement_price,
        spot_source,
        source_timestamp_ms,
        update_timestamp_ms,
    });
}

fun pyth_spot_is_fresh(pyth: &PythSource, clock: &Clock, freshness_ms: u64): bool {
    timestamps_are_fresh(
        clock.timestamp_ms(),
        pyth.source_timestamp_us() / 1000,
        pyth.update_timestamp_ms(),
        freshness_ms,
    )
}

fun pyth_effective_timestamp_ms(pyth: &PythSource): u64 {
    effective_timestamp_ms(pyth.source_timestamp_us() / 1000, pyth.update_timestamp_ms())
}

fun validate_basis_push(market: &MarketOracle, new_spot: u64, new_basis: u64) {
    let bounds = &market.bounds;
    assert!(new_basis >= bounds.min_basis && new_basis <= bounds.max_basis, EBasisOutOfRange);

    let prev_spot = market.block_scholes_spot;
    if (prev_spot > 0) {
        assert!(
            within_deviation(prev_spot, new_spot, bounds.max_spot_deviation),
            ESpotDeviationTooLarge,
        );
    };

    let prev_forward = market.block_scholes_forward;
    if (prev_spot > 0 && prev_forward > 0) {
        let prev_basis = market.block_scholes_basis();
        assert!(
            within_deviation(prev_basis, new_basis, bounds.max_basis_deviation),
            EBasisDeviationTooLarge,
        );
    };
}

fun validate_freshness_ms(value: u64) {
    assert!(
        value > 0 && value <= tuning_constants::max_freshness_threshold_ms!(),
        EInvalidFreshnessThreshold,
    );
}

fun validate_basis_bounds_inputs(
    max_spot_deviation: u64,
    max_basis_deviation: u64,
    min_basis: u64,
    max_basis: u64,
) {
    assert!(min_basis < max_basis, EInvalidBasisBounds);
    assert!(min_basis >= tuning_constants::min_basis_floor!(), EInvalidBasisBounds);
    assert!(max_basis <= tuning_constants::max_basis_ceiling!(), EInvalidBasisBounds);
    assert!(
        max_spot_deviation > 0 && max_spot_deviation <= tuning_constants::max_basis_deviation_ceiling!(),
        EInvalidBasisBounds,
    );
    assert!(
        max_basis_deviation > 0 && max_basis_deviation <= tuning_constants::max_basis_deviation_ceiling!(),
        EInvalidBasisBounds,
    );
}

fun within_deviation(prev: u64, next: u64, max_deviation: u64): bool {
    let diff = if (next >= prev) { next - prev } else { prev - next };
    let max_allowed = math::mul(prev, max_deviation);
    diff <= max_allowed
}

fun timestamps_are_fresh(
    now_ms: u64,
    source_timestamp_ms: u64,
    update_timestamp_ms: u64,
    freshness_ms: u64,
): bool {
    timestamp_is_fresh(
        now_ms,
        effective_timestamp_ms(source_timestamp_ms, update_timestamp_ms),
        freshness_ms,
    )
}

fun timestamp_is_fresh(now_ms: u64, timestamp_ms: u64, freshness_ms: u64): bool {
    if (timestamp_ms == 0) return false;
    now_ms <= timestamp_ms || now_ms - timestamp_ms <= freshness_ms
}

fun effective_timestamp_ms(source_timestamp_ms: u64, update_timestamp_ms: u64): u64 {
    if (source_timestamp_ms < update_timestamp_ms) {
        source_timestamp_ms
    } else {
        update_timestamp_ms
    }
}

fun emit_bounds_updated(market: &MarketOracle) {
    let b = &market.bounds;
    event::emit(MarketOracleBoundsUpdated {
        market_oracle_id: market.id.to_inner(),
        pyth_spot_freshness_ms: b.pyth_spot_freshness_ms,
        block_scholes_prices_freshness_ms: b.block_scholes_prices_freshness_ms,
        block_scholes_svi_freshness_ms: b.block_scholes_svi_freshness_ms,
        max_spot_deviation: b.max_spot_deviation,
        max_basis_deviation: b.max_basis_deviation,
        min_basis: b.min_basis,
        max_basis: b.max_basis,
    });
}
