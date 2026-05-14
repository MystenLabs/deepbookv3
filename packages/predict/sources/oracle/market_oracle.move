// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Per-expiry Predict market oracle state and write API.
///
/// This module owns market-specific state: expiry, settlement, operator
/// authorization, Pyth source binding, bounds, and inline Block Scholes data.
/// It stores oracle updates and terminal settlement state. Live oracle reads
/// are resolved by `pricing.move`.
module deepbook_predict::market_oracle;

use deepbook::math;
use deepbook_predict::{
    config_constants,
    i64,
    market_oracle_config::MarketOracleConfig,
    protocol_config::ProtocolConfig,
    pyth_source::PythSource
};
use sui::{clock::Clock, event, vec_set::{Self, VecSet}};

const EInvalidMarketOracleCap: u64 = 0;
const EMarketNotActive: u64 = 1;
const EMarketSettled: u64 = 2;
const EInvalidBasisBounds: u64 = 3;
const ESpotDeviationTooLarge: u64 = 4;
const EBasisDeviationTooLarge: u64 = 5;
const EBasisOutOfRange: u64 = 6;
const EZeroSpot: u64 = 7;
const EZeroForward: u64 = 8;
const EStalePriceSourceUpdate: u64 = 9;
const EStaleSVISourceUpdate: u64 = 10;
const EWrongPythSource: u64 = 11;
const EFuturePriceSourceUpdate: u64 = 12;
const EFutureSVISourceUpdate: u64 = 13;
const EPendingSettlement: u64 = 14;
const EMarketNotSettled: u64 = 15;
const EInvalidSettlementTimestamp: u64 = 16;

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

public struct MarketOracle has key {
    id: UID,
    authorized_cap_ids: VecSet<ID>,
    pyth_source_id: ID,
    expiry: u64,
    block_scholes_spot: u64,
    block_scholes_forward: u64,
    block_scholes_price_source_timestamp_ms: u64,
    block_scholes_price_update_timestamp_ms: u64,
    block_scholes_svi: SVIParams,
    block_scholes_svi_source_timestamp_ms: u64,
    block_scholes_svi_update_timestamp_ms: u64,
    settlement_freshness_ms: u64,
    max_spot_deviation: u64,
    max_basis_deviation: u64,
    min_basis: u64,
    max_basis: u64,
    settlement_price: Option<u64>,
    settlement_source: u8,
    settlement_source_timestamp_ms: u64,
    settlement_update_timestamp_ms: u64,
}

public struct MarketOracleCap has key, store {
    id: UID,
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
    settlement_freshness_ms: u64,
    max_spot_deviation: u64,
    max_basis_deviation: u64,
    min_basis: u64,
    max_basis: u64,
}

public struct MarketOracleSettled has copy, drop, store {
    market_oracle_id: ID,
    expiry: u64,
    settlement_price: u64,
    /// `1` means Pyth supplied the settlement spot; `2` means Block Scholes fallback did.
    spot_source: u8,
    /// Timestamp from the data source used for settlement, in milliseconds.
    source_timestamp_ms: u64,
    /// On-chain timestamp when that data source update landed, in milliseconds.
    update_timestamp_ms: u64,
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

public fun pyth_source_id(market: &MarketOracle): ID {
    market.pyth_source_id
}

public fun expiry(market: &MarketOracle): u64 {
    market.expiry
}

public fun is_settled(market: &MarketOracle): bool {
    market.settlement_price.is_some()
}

/// Return the raw terminal settlement price field.
///
/// Package execution should prefer `settlement_price`, which also enforces
/// settlement timestamp invariants. External callers can use
/// `pricing::settlement_price`.
public fun raw_settlement_price(market: &MarketOracle): Option<u64> {
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

public fun block_scholes_price_source_timestamp_ms(market: &MarketOracle): u64 {
    market.block_scholes_price_source_timestamp_ms
}

public fun block_scholes_price_update_timestamp_ms(market: &MarketOracle): u64 {
    market.block_scholes_price_update_timestamp_ms
}

public fun block_scholes_svi(market: &MarketOracle): SVIParams {
    market.block_scholes_svi
}

public fun a(params: &SVIParams): u64 {
    params.a
}

public fun b(params: &SVIParams): u64 {
    params.b
}

public fun rho(params: &SVIParams): i64::I64 {
    params.rho
}

public fun m(params: &SVIParams): i64::I64 {
    params.m
}

public fun sigma(params: &SVIParams): u64 {
    params.sigma
}

public fun block_scholes_svi_source_timestamp_ms(market: &MarketOracle): u64 {
    market.block_scholes_svi_source_timestamp_ms
}

public fun block_scholes_svi_update_timestamp_ms(market: &MarketOracle): u64 {
    market.block_scholes_svi_update_timestamp_ms
}

/// Update Block Scholes spot/forward data and settle the market if possible.
public fun update_block_scholes_prices(
    market: &mut MarketOracle,
    config: &ProtocolConfig,
    pyth: &PythSource,
    cap: &MarketOracleCap,
    block_scholes_spot: u64,
    block_scholes_forward: u64,
    block_scholes_source_timestamp_ms: u64,
    clock: &Clock,
) {
    market.assert_authorized_cap(cap);
    config.assert_not_valuation_in_progress();
    market.assert_pyth_source(pyth);

    let status = market.status(clock);
    assert!(status != STATUS_SETTLED, EMarketSettled);

    let basis = market.validate_block_scholes_price_update(
        block_scholes_spot,
        block_scholes_forward,
        block_scholes_source_timestamp_ms,
        clock,
    );
    market.validate_basis_push(block_scholes_spot, basis);
    market.apply_block_scholes_prices(
        block_scholes_spot,
        block_scholes_forward,
        basis,
        block_scholes_source_timestamp_ms,
        clock,
    );
    market.settle_if_possible_internal(pyth, clock);
}

/// Settle from the earliest valid stored source, if one is available.
///
/// This lets oracle operators finalize settlement without making mint/redeem
/// mutate oracle state.
public fun settle_if_possible(
    market: &mut MarketOracle,
    config: &ProtocolConfig,
    pyth: &PythSource,
    cap: &MarketOracleCap,
    clock: &Clock,
): bool {
    market.assert_authorized_cap(cap);
    config.assert_not_valuation_in_progress();
    if (market.status(clock) != STATUS_PENDING_SETTLEMENT) return false;
    market.assert_pyth_source(pyth);
    market.settle_if_possible_internal(pyth, clock)
}

public fun update_svi(
    market: &mut MarketOracle,
    config: &ProtocolConfig,
    cap: &MarketOracleCap,
    svi: SVIParams,
    source_timestamp_ms: u64,
    clock: &Clock,
) {
    market.assert_authorized_cap(cap);
    config.assert_not_valuation_in_progress();
    market.assert_active(clock);
    assert!(
        source_timestamp_ms > market.block_scholes_svi_source_timestamp_ms,
        EStaleSVISourceUpdate,
    );
    assert!(source_timestamp_ms <= clock.timestamp_ms(), EFutureSVISourceUpdate);
    let update_timestamp_ms = clock.timestamp_ms();
    market.block_scholes_svi = svi;
    market.block_scholes_svi_source_timestamp_ms = source_timestamp_ms;
    market.block_scholes_svi_update_timestamp_ms = update_timestamp_ms;

    event::emit(BlockScholesSVIUpdated {
        market_oracle_id: market.id(),
        a: svi.a(),
        b: svi.b(),
        rho: svi.rho(),
        m: svi.m(),
        sigma: svi.sigma(),
        source_timestamp_ms,
        update_timestamp_ms,
    });
}

public fun set_settlement_freshness_ms(
    market: &mut MarketOracle,
    config: &ProtocolConfig,
    cap: &MarketOracleCap,
    value: u64,
) {
    market.assert_authorized_cap(cap);
    config.assert_not_valuation_in_progress();
    config_constants::assert_settlement_freshness_ms(value);
    market.settlement_freshness_ms = value;
    market.emit_bounds_updated();
}

public fun set_basis_bounds(
    market: &mut MarketOracle,
    config: &ProtocolConfig,
    cap: &MarketOracleCap,
    max_spot_deviation: u64,
    max_basis_deviation: u64,
    min_basis: u64,
    max_basis: u64,
) {
    market.assert_authorized_cap(cap);
    config.assert_not_valuation_in_progress();
    validate_basis_bounds_inputs(max_spot_deviation, max_basis_deviation, min_basis, max_basis);
    market.max_spot_deviation = max_spot_deviation;
    market.max_basis_deviation = max_basis_deviation;
    market.min_basis = min_basis;
    market.max_basis = max_basis;
    market.emit_bounds_updated();
}

// === Public-Package Functions ===

public(package) fun block_scholes_basis(market: &MarketOracle): u64 {
    assert!(market.block_scholes_spot > 0, EZeroSpot);
    assert!(market.block_scholes_forward > 0, EZeroForward);
    math::div(market.block_scholes_forward, market.block_scholes_spot)
}

public(package) fun block_scholes_price_freshness_timestamp_ms(market: &MarketOracle): u64 {
    market
        .block_scholes_price_source_timestamp_ms
        .min(market.block_scholes_price_update_timestamp_ms)
}

public(package) fun block_scholes_svi_freshness_timestamp_ms(market: &MarketOracle): u64 {
    market.block_scholes_svi_source_timestamp_ms.min(market.block_scholes_svi_update_timestamp_ms)
}

public(package) fun settlement_price(market: &MarketOracle): u64 {
    market.assert_settled();
    assert!(market.settlement_source_timestamp_ms > market.expiry, EInvalidSettlementTimestamp);
    market.settlement_price.destroy_some()
}

public(package) fun create_cap(ctx: &mut TxContext): MarketOracleCap {
    MarketOracleCap { id: object::new(ctx) }
}

public(package) fun destroy_cap(cap: MarketOracleCap) {
    let MarketOracleCap { id } = cap;
    id.delete();
}

public(package) fun create_and_share(
    pyth: &PythSource,
    config: &MarketOracleConfig,
    cap: &MarketOracleCap,
    expiry: u64,
    ctx: &mut TxContext,
): ID {
    let cap_id = cap.cap_id();
    let mut authorized_cap_ids = vec_set::empty();
    authorized_cap_ids.insert(cap_id);
    let market = MarketOracle {
        id: object::new(ctx),
        authorized_cap_ids,
        pyth_source_id: pyth.id(),
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
        settlement_freshness_ms: config.settlement_freshness_ms(),
        max_spot_deviation: config.max_spot_deviation(),
        max_basis_deviation: config.max_basis_deviation(),
        min_basis: config.min_basis(),
        max_basis: config.max_basis(),
        settlement_price: option::none(),
        settlement_source: 0,
        settlement_source_timestamp_ms: 0,
        settlement_update_timestamp_ms: 0,
    };

    let market_oracle_id = market.id();
    transfer::share_object(market);
    market_oracle_id
}

public(package) fun register_cap(market: &mut MarketOracle, cap: &MarketOracleCap) {
    let cap_id = cap.cap_id();
    assert!(!market.authorized_cap_ids.contains(&cap_id), EInvalidMarketOracleCap);
    market.authorized_cap_ids.insert(cap_id);
}

public(package) fun unregister_cap(market: &mut MarketOracle, cap_id: ID) {
    assert!(market.authorized_cap_ids.contains(&cap_id), EInvalidMarketOracleCap);
    market.authorized_cap_ids.remove(&cap_id);
}

public(package) fun self_unregister_cap(market: &mut MarketOracle, cap: &MarketOracleCap) {
    market.unregister_cap(cap.cap_id());
}

public(package) fun assert_pyth_source(market: &MarketOracle, pyth: &PythSource) {
    assert!(market.pyth_source_id == pyth.id(), EWrongPythSource);
}

public(package) fun assert_active(market: &MarketOracle, clock: &Clock) {
    assert!(market.status(clock) == STATUS_ACTIVE, EMarketNotActive);
}

public(package) fun assert_not_pending_settlement(market: &MarketOracle, clock: &Clock) {
    assert!(market.status(clock) != STATUS_PENDING_SETTLEMENT, EPendingSettlement);
}

// === Private Functions ===

fun assert_authorized_cap(market: &MarketOracle, cap: &MarketOracleCap) {
    assert!(market.authorized_cap_ids.contains(&cap.cap_id()), EInvalidMarketOracleCap);
}

fun assert_settled(market: &MarketOracle) {
    assert!(market.is_settled(), EMarketNotSettled);
}

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
        market_oracle_id: market.id(),
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
    clock: &Clock,
): u64 {
    assert!(spot > 0, EZeroSpot);
    assert!(forward > 0, EZeroForward);
    assert!(
        source_timestamp_ms > market.block_scholes_price_source_timestamp_ms,
        EStalePriceSourceUpdate,
    );
    assert!(source_timestamp_ms <= clock.timestamp_ms(), EFuturePriceSourceUpdate);

    compute_bounded_basis(market, spot, forward)
}

fun settle_if_possible_internal(market: &mut MarketOracle, pyth: &PythSource, clock: &Clock): bool {
    if (market.status(clock) != STATUS_PENDING_SETTLEMENT) return false;

    let spot_source = market.valid_settlement_spot_source(pyth, clock);
    if (spot_source.is_none()) return false;

    market.settle_from_spot_source(pyth, spot_source.destroy_some());
    true
}

fun valid_settlement_spot_source(
    market: &MarketOracle,
    pyth: &PythSource,
    clock: &Clock,
): Option<u8> {
    let now = clock.timestamp_ms();
    let pyth_source_timestamp_ms = pyth.source_timestamp_ms();
    let pyth_timestamp = pyth.freshness_timestamp_ms();
    let block_scholes_source_timestamp_ms = market.block_scholes_price_source_timestamp_ms;
    let block_scholes_update_timestamp_ms = market.block_scholes_price_update_timestamp_ms;
    let block_scholes_timestamp = block_scholes_source_timestamp_ms.min(
        block_scholes_update_timestamp_ms,
    );

    let pyth_valid =
        pyth_timestamp > 0
        && pyth_timestamp <= now
        && now - pyth_timestamp <= market.settlement_freshness_ms
        && pyth_source_timestamp_ms > market.expiry;
    let block_scholes_valid =
        block_scholes_timestamp > 0
        && block_scholes_timestamp <= now
        && now - block_scholes_timestamp <= market.settlement_freshness_ms
        && block_scholes_source_timestamp_ms > market.expiry;
    if (!pyth_valid && !block_scholes_valid) return option::none();

    if (
        pyth_valid
            && (
                !block_scholes_valid
                    || pyth_source_timestamp_ms <= block_scholes_source_timestamp_ms
            )
    ) {
        option::some(SOURCE_PYTH)
    } else {
        option::some(SOURCE_BLOCK_SCHOLES)
    }
}

fun settle_from_spot_source(market: &mut MarketOracle, pyth: &PythSource, spot_source: u8) {
    if (spot_source == SOURCE_PYTH) {
        let pyth_source_timestamp_ms = pyth.source_timestamp_ms();
        market.settle(
            pyth.spot(),
            SOURCE_PYTH,
            pyth_source_timestamp_ms,
            pyth.update_timestamp_ms(),
        );
    } else {
        let block_scholes_spot = market.block_scholes_spot;
        let block_scholes_source_timestamp_ms = market.block_scholes_price_source_timestamp_ms;
        let block_scholes_update_timestamp_ms = market.block_scholes_price_update_timestamp_ms;
        market.settle(
            block_scholes_spot,
            SOURCE_BLOCK_SCHOLES,
            block_scholes_source_timestamp_ms,
            block_scholes_update_timestamp_ms,
        );
    };
}

fun settle(
    market: &mut MarketOracle,
    settlement_price: u64,
    spot_source: u8,
    source_timestamp_ms: u64,
    update_timestamp_ms: u64,
) {
    market.settlement_price = option::some(settlement_price);
    market.settlement_source = spot_source;
    market.settlement_source_timestamp_ms = source_timestamp_ms;
    market.settlement_update_timestamp_ms = update_timestamp_ms;

    event::emit(MarketOracleSettled {
        market_oracle_id: market.id(),
        expiry: market.expiry,
        settlement_price,
        spot_source,
        source_timestamp_ms,
        update_timestamp_ms,
    });
}

fun compute_bounded_basis(market: &MarketOracle, spot: u64, forward: u64): u64 {
    let basis = math::div(forward, spot);
    assert!(basis >= market.min_basis, EBasisOutOfRange);
    assert!(basis <= market.max_basis, EBasisOutOfRange);
    basis
}

fun validate_basis_push(market: &MarketOracle, new_spot: u64, new_basis: u64) {
    let prev_spot = market.block_scholes_spot;
    if (prev_spot > 0) {
        assert!(
            within_deviation(prev_spot, new_spot, market.max_spot_deviation),
            ESpotDeviationTooLarge,
        );
    };

    let prev_forward = market.block_scholes_forward;
    if (prev_spot > 0 && prev_forward > 0) {
        let prev_basis = market.block_scholes_basis();
        assert!(
            within_deviation(prev_basis, new_basis, market.max_basis_deviation),
            EBasisDeviationTooLarge,
        );
    };
}

fun validate_basis_bounds_inputs(
    max_spot_deviation: u64,
    max_basis_deviation: u64,
    min_basis: u64,
    max_basis: u64,
) {
    config_constants::assert_max_spot_deviation(max_spot_deviation);
    config_constants::assert_max_basis_deviation(max_basis_deviation);
    config_constants::assert_min_basis(min_basis);
    config_constants::assert_max_basis(max_basis);
    assert!(min_basis < max_basis, EInvalidBasisBounds);
}

fun within_deviation(prev: u64, next: u64, max_deviation: u64): bool {
    let diff = if (next >= prev) { next - prev } else { prev - next };
    let max_allowed = math::mul(prev, max_deviation);
    diff <= max_allowed
}

fun emit_bounds_updated(market: &MarketOracle) {
    event::emit(MarketOracleBoundsUpdated {
        market_oracle_id: market.id(),
        settlement_freshness_ms: market.settlement_freshness_ms,
        max_spot_deviation: market.max_spot_deviation,
        max_basis_deviation: market.max_basis_deviation,
        min_basis: market.min_basis,
        max_basis: market.max_basis,
    });
}

// === Test-Only Functions ===

#[test_only]
public(package) fun create_test_market_oracle(
    expiry: u64,
    cap: &MarketOracleCap,
    ctx: &mut TxContext,
): MarketOracle {
    let pyth_uid = object::new(ctx);
    let pyth_source_id = pyth_uid.to_inner();
    pyth_uid.delete();

    let mut authorized_cap_ids = vec_set::empty();
    authorized_cap_ids.insert(cap.cap_id());

    MarketOracle {
        id: object::new(ctx),
        authorized_cap_ids,
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
        settlement_freshness_ms: config_constants::default_settlement_freshness_ms!(),
        max_spot_deviation: config_constants::default_max_spot_deviation!(),
        max_basis_deviation: config_constants::default_max_basis_deviation!(),
        min_basis: config_constants::default_min_basis!(),
        max_basis: config_constants::default_max_basis!(),
        settlement_price: option::none(),
        settlement_source: 0,
        settlement_source_timestamp_ms: 0,
        settlement_update_timestamp_ms: 0,
    }
}

#[test_only]
public(package) fun destroy_for_testing(market: MarketOracle) {
    let MarketOracle {
        id,
        authorized_cap_ids: _,
        pyth_source_id: _,
        expiry: _,
        block_scholes_spot: _,
        block_scholes_forward: _,
        block_scholes_price_source_timestamp_ms: _,
        block_scholes_price_update_timestamp_ms: _,
        block_scholes_svi: _,
        block_scholes_svi_source_timestamp_ms: _,
        block_scholes_svi_update_timestamp_ms: _,
        settlement_freshness_ms: _,
        max_spot_deviation: _,
        max_basis_deviation: _,
        min_basis: _,
        max_basis: _,
        settlement_price: _,
        settlement_source: _,
        settlement_source_timestamp_ms: _,
        settlement_update_timestamp_ms: _,
    } = market;
    id.delete();
}
