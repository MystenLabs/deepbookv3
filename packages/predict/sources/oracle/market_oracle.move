// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Per-expiry Predict market oracle state and write API.
///
/// This module owns market-specific state: expiry, settlement, operator
/// authorization, Pyth source binding, admin-tunable snapshotted bounds, and
/// inline Block Scholes data. It stores oracle updates and terminal settlement
/// state. Live oracle reads are resolved by `pricing.move`.
module deepbook_predict::market_oracle;

use deepbook::math;
use deepbook_predict::{
    admin::AdminCap,
    config_events,
    constants,
    i64,
    market_oracle_config::{Self, MarketOracleConfig},
    oracle_events,
    protocol_config::ProtocolConfig,
    pyth_source::PythSource,
    settlement_state::{Self, SettlementState}
};
use sui::{clock::Clock, random::{Self, Random, RandomGenerator}, vec_set::{Self, VecSet}};

const EInvalidMarketOracleCap: u64 = 0;
const EMarketNotActive: u64 = 1;
const EMarketSettled: u64 = 2;
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
const EInvalidSviB: u64 = 14;
const EInvalidSviRho: u64 = 15;
const EInvalidSviSigma: u64 = 16;
const EPackageVersionDisabled: u64 = 17;

const STATUS_ACTIVE: u8 = 1;
const STATUS_PENDING_SETTLEMENT: u8 = 2;
const STATUS_SETTLED: u8 = 3;

/// SVI volatility surface parameters supplied by Block Scholes.
public struct SVIParams has copy, drop, store {
    a: u64,
    b: u64,
    rho: i64::I64,
    m: i64::I64,
    sigma: u64,
}

/// Shared per-expiry oracle object storing live source data and settlement state.
public struct MarketOracle has key {
    id: UID,
    /// MarketOracleCap IDs authorized to write Block Scholes data.
    authorized_cap_ids: VecSet<ID>,
    /// Mirror of `ProtocolConfig.allowed_versions`; synced permissionlessly.
    allowed_versions: VecSet<u64>,
    pyth_source_id: ID,
    expiry: u64,
    block_scholes_spot: u64,
    block_scholes_forward: u64,
    block_scholes_price_source_timestamp_ms: u64,
    block_scholes_price_update_timestamp_ms: u64,
    block_scholes_svi: SVIParams,
    block_scholes_svi_source_timestamp_ms: u64,
    block_scholes_svi_update_timestamp_ms: u64,
    config: MarketOracleConfig,
    settlement: SettlementState,
}

/// Capability authorized to write Block Scholes data.
public struct MarketOracleCap has key, store {
    id: UID,
}

// === Public Functions ===

/// Construct a Block Scholes SVI parameter set.
public fun new_svi_params(a: u64, b: u64, rho: i64::I64, m: i64::I64, sigma: u64): SVIParams {
    SVIParams { a, b, rho, m, sigma }
}

/// Return the market oracle object ID.
public fun id(market: &MarketOracle): ID {
    market.id.to_inner()
}

/// Return this oracle's mirrored set of allowed package versions.
public fun allowed_versions(market: &MarketOracle): VecSet<u64> {
    market.allowed_versions
}

/// Return the MarketOracleCap object ID.
public fun cap_id(cap: &MarketOracleCap): ID {
    cap.id.to_inner()
}

/// Return the Pyth source object bound to this oracle.
public fun pyth_source_id(market: &MarketOracle): ID {
    market.pyth_source_id
}

/// Return the expiry timestamp in milliseconds.
public fun expiry(market: &MarketOracle): u64 {
    market.expiry
}

/// Return whether terminal settlement has been recorded.
public fun is_settled(market: &MarketOracle): bool {
    market.settlement.is_settled()
}

/// Return active, pending-settlement, or settled status for the current clock.
public fun status(market: &MarketOracle, clock: &Clock): u8 {
    if (market.is_settled()) {
        STATUS_SETTLED
    } else if (clock.timestamp_ms() >= market.expiry) {
        STATUS_PENDING_SETTLEMENT
    } else {
        STATUS_ACTIVE
    }
}

/// Return the active status code.
public fun status_active(): u8 {
    STATUS_ACTIVE
}

/// Return the pending-settlement status code.
public fun status_pending_settlement(): u8 {
    STATUS_PENDING_SETTLEMENT
}

/// Return the settled status code.
public fun status_settled(): u8 {
    STATUS_SETTLED
}

/// Return the settlement source code for Pyth.
public fun source_pyth(): u8 {
    settlement_state::source_pyth()
}

/// Return the settlement source code for a random-average of sampled Pyth spots.
public fun source_pyth_sampled_average(): u8 {
    settlement_state::source_pyth_sampled_average()
}

/// Return the settlement source code for Block Scholes.
public fun source_block_scholes(): u8 {
    settlement_state::source_block_scholes()
}

/// Return the settlement source code for a random-average of sampled Block Scholes spots.
public fun source_block_scholes_sampled_average(): u8 {
    settlement_state::source_block_scholes_sampled_average()
}

/// Return the latest Block Scholes spot in Predict's 1e9 scaling.
public fun block_scholes_spot(market: &MarketOracle): u64 {
    market.block_scholes_spot
}

/// Return the latest Block Scholes forward in Predict's 1e9 scaling.
public fun block_scholes_forward(market: &MarketOracle): u64 {
    market.block_scholes_forward
}

/// Return the source timestamp for the latest Block Scholes spot/forward update.
public fun block_scholes_price_source_timestamp_ms(market: &MarketOracle): u64 {
    market.block_scholes_price_source_timestamp_ms
}

/// Return the on-chain timestamp for the latest Block Scholes spot/forward update.
public fun block_scholes_price_update_timestamp_ms(market: &MarketOracle): u64 {
    market.block_scholes_price_update_timestamp_ms
}

/// Return the latest Block Scholes SVI parameters.
public fun block_scholes_svi(market: &MarketOracle): SVIParams {
    market.block_scholes_svi
}

/// Return SVI parameter `a`.
public fun a(params: &SVIParams): u64 {
    params.a
}

/// Return SVI parameter `b`.
public fun b(params: &SVIParams): u64 {
    params.b
}

/// Return SVI parameter `rho`.
public fun rho(params: &SVIParams): i64::I64 {
    params.rho
}

/// Return SVI parameter `m`.
public fun m(params: &SVIParams): i64::I64 {
    params.m
}

/// Return SVI parameter `sigma`.
public fun sigma(params: &SVIParams): u64 {
    params.sigma
}

/// Return the source timestamp for the latest Block Scholes SVI update.
public fun block_scholes_svi_source_timestamp_ms(market: &MarketOracle): u64 {
    market.block_scholes_svi_source_timestamp_ms
}

/// Return the on-chain timestamp for the latest Block Scholes SVI update.
public fun block_scholes_svi_update_timestamp_ms(market: &MarketOracle): u64 {
    market.block_scholes_svi_update_timestamp_ms
}

/// Update authorized Block Scholes spot/forward data.
///
/// Aborts during valuation or after settlement. While within the final
/// `settlement_sample_window_ms` before expiry, this records the accepted Block
/// Scholes spot into its settlement sample buffer. After expiry, this latches the
/// first fresh post-expiry Block Scholes price observed by this oracle. Terminal
/// settlement is performed separately by `settle_with_randomness`.
public fun update_block_scholes_prices(
    market: &mut MarketOracle,
    config: &ProtocolConfig,
    cap: &MarketOracleCap,
    block_scholes_spot: u64,
    block_scholes_forward: u64,
    block_scholes_source_timestamp_ms: u64,
    clock: &Clock,
) {
    market.assert_version_allowed();
    market.assert_authorized_cap(cap);
    config.assert_not_valuation_in_progress();

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
    market
        .settlement
        .record_block_scholes_observation(
            &market.config,
            market.block_scholes_spot,
            market.block_scholes_price_source_timestamp_ms,
            market.block_scholes_price_update_timestamp_ms,
            market.expiry,
            clock.timestamp_ms(),
        );
}

/// Permissionlessly record the current fresh Pyth settlement observation.
///
/// Before expiry this can append a sample inside the final
/// `settlement_sample_window_ms`. After expiry this can latch the first fresh
/// post-expiry Pyth price observed by this market oracle.
public fun record_pyth_settlement_observation(
    market: &mut MarketOracle,
    config: &ProtocolConfig,
    pyth: &PythSource,
    clock: &Clock,
) {
    market.assert_version_allowed();
    config.assert_not_valuation_in_progress();
    market.assert_pyth_source(pyth);
    market
        .settlement
        .record_pyth_observation(
            &market.config,
            pyth.spot(),
            pyth.source_timestamp_ms(),
            pyth.update_timestamp_ms(),
            market.expiry,
            clock.timestamp_ms(),
        );
}

/// Permissionlessly finalize settlement, drawing Sui native randomness to set the
/// settlement price from sampled or fresh Pyth/Block Scholes data.
///
/// Thin entry wrapper: it only builds the generator; `settle` owns
/// the gates and the settlement write.
entry fun settle_with_randomness(
    market: &mut MarketOracle,
    config: &ProtocolConfig,
    pyth: &PythSource,
    clock: &Clock,
    r: &Random,
    ctx: &mut TxContext,
) {
    let mut generator = random::new_generator(r, ctx);
    market.settle(config, pyth, &mut generator, clock);
}

/// Update live SVI data from an authorized Block Scholes writer.
///
/// SVI is live-market-only and must advance the source timestamp.
public fun update_svi(
    market: &mut MarketOracle,
    config: &ProtocolConfig,
    cap: &MarketOracleCap,
    svi: SVIParams,
    source_timestamp_ms: u64,
    clock: &Clock,
) {
    market.assert_version_allowed();
    market.assert_authorized_cap(cap);
    config.assert_not_valuation_in_progress();
    market.assert_active(clock);
    assert!(
        source_timestamp_ms > market.block_scholes_svi_source_timestamp_ms,
        EStaleSVISourceUpdate,
    );
    assert!(source_timestamp_ms <= clock.timestamp_ms(), EFutureSVISourceUpdate);
    assert_valid_svi(&svi);
    market.apply_block_scholes_svi(svi, source_timestamp_ms, clock);
}

/// Set the live settlement freshness threshold for this oracle.
public fun set_settlement_freshness_ms(
    market: &mut MarketOracle,
    config: &ProtocolConfig,
    _admin_cap: &AdminCap,
    value: u64,
) {
    market.assert_version_allowed();
    config.assert_not_valuation_in_progress();
    market.config.set_settlement_freshness_ms(value);
    market.emit_bounds_updated();
}

/// Set the live basis and deviation bounds for this oracle.
public fun set_basis_bounds(
    market: &mut MarketOracle,
    config: &ProtocolConfig,
    _admin_cap: &AdminCap,
    max_spot_deviation: u64,
    max_basis_deviation: u64,
    min_basis: u64,
    max_basis: u64,
) {
    market.assert_version_allowed();
    config.assert_not_valuation_in_progress();
    market
        .config
        .set_basis_bounds(
            max_spot_deviation,
            max_basis_deviation,
            min_basis,
            max_basis,
        );
    market.emit_bounds_updated();
}

/// Create a new oracle writer capability.
public fun create_cap(_admin_cap: &AdminCap, ctx: &mut TxContext): MarketOracleCap {
    MarketOracleCap { id: object::new(ctx) }
}

/// Destroy a MarketOracleCap the holder no longer needs.
public fun destroy_cap(cap: MarketOracleCap) {
    let MarketOracleCap { id } = cap;
    id.delete();
}

/// Authorize an additional cap to write this market oracle.
public fun register_cap(market: &mut MarketOracle, _admin_cap: &AdminCap, cap: &MarketOracleCap) {
    market.register_cap_internal(cap);
}

/// Remove a cap from this market oracle's writer set.
public fun unregister_cap(market: &mut MarketOracle, _admin_cap: &AdminCap, cap_id: ID) {
    market.unregister_cap_internal(cap_id);
}

/// Let a cap holder remove its own cap from this market oracle.
public fun self_unregister_cap(market: &mut MarketOracle, cap: &MarketOracleCap) {
    market.unregister_cap_internal(cap.cap_id());
}

// === Public-Package Functions ===

/// Overwrite this oracle's mirrored `allowed_versions`. The only authorized
/// caller is `registry::sync_market_oracle_allowed_versions`, which reads the
/// source of truth from `Registry`.
public(package) fun set_allowed_versions(market: &mut MarketOracle, allowed_versions: VecSet<u64>) {
    market.allowed_versions = allowed_versions;
}

/// Abort unless SVI parameters lie within model-team 1e9 fixed-point bounds.
public(package) fun assert_valid_svi(svi: &SVIParams) {
    let b = svi.b();
    assert!(b >= constants::svi_b_min!() && b <= constants::svi_b_max!(), EInvalidSviB);
    assert!(svi.rho().magnitude() <= constants::float_scaling!(), EInvalidSviRho);
    let sigma = svi.sigma();
    assert!(
        sigma >= constants::svi_sigma_min!() && sigma <= constants::svi_sigma_max!(),
        EInvalidSviSigma,
    );
}

/// Return forward / spot basis, aborting until both values are initialized.
public(package) fun block_scholes_basis(market: &MarketOracle): u64 {
    assert!(market.block_scholes_spot > 0, EZeroSpot);
    assert!(market.block_scholes_forward > 0, EZeroForward);
    math::div(market.block_scholes_forward, market.block_scholes_spot)
}

/// Return the conservative timestamp used for Block Scholes price freshness.
public(package) fun block_scholes_price_freshness_timestamp_ms(market: &MarketOracle): u64 {
    market
        .block_scholes_price_source_timestamp_ms
        .min(market.block_scholes_price_update_timestamp_ms)
}

/// Return the conservative timestamp used for Block Scholes SVI freshness.
public(package) fun block_scholes_svi_freshness_timestamp_ms(market: &MarketOracle): u64 {
    market.block_scholes_svi_source_timestamp_ms.min(market.block_scholes_svi_update_timestamp_ms)
}

/// Return terminal settlement price.
public(package) fun settlement_price(market: &MarketOracle): u64 {
    market.settlement.price()
}

#[test_only]
public(package) fun settle_with_generator_for_testing(
    market: &mut MarketOracle,
    config: &ProtocolConfig,
    pyth: &PythSource,
    gen: &mut RandomGenerator,
    clock: &Clock,
) {
    market.settle(config, pyth, gen, clock);
}

/// Finalize terminal settlement using a caller-provided random generator.
///
/// Source priority is Pyth samples, fresh post-expiry Pyth, Block Scholes samples,
/// then fresh post-expiry Block Scholes. Returns without mutating when none are
/// available.
fun settle(
    market: &mut MarketOracle,
    config: &ProtocolConfig,
    pyth: &PythSource,
    gen: &mut RandomGenerator,
    clock: &Clock,
) {
    market.assert_version_allowed();
    config.assert_not_valuation_in_progress();
    if (market.status(clock) != STATUS_PENDING_SETTLEMENT) return;
    market.assert_pyth_source(pyth);
    market
        .settlement
        .record_pyth_observation(
            &market.config,
            pyth.spot(),
            pyth.source_timestamp_ms(),
            pyth.update_timestamp_ms(),
            market.expiry,
            clock.timestamp_ms(),
        );

    let market_oracle_id = market.id();
    let expiry = market.expiry;
    market.settlement.settle(market_oracle_id, expiry, gen);
}

/// Create and share a market oracle bound to a Pyth source and initial writer cap.
public(package) fun create_and_share(
    pyth: &PythSource,
    config: &ProtocolConfig,
    cap: &MarketOracleCap,
    expiry: u64,
    allowed_versions: VecSet<u64>,
    ctx: &mut TxContext,
): ID {
    let cap_id = cap.cap_id();
    let mut authorized_cap_ids = vec_set::empty();
    authorized_cap_ids.insert(cap_id);
    let market = MarketOracle {
        id: object::new(ctx),
        authorized_cap_ids,
        allowed_versions,
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
        config: config.market_oracle_config_snapshot(),
        settlement: settlement_state::new(),
    };

    let market_oracle_id = market.id();
    market.emit_bounds_updated();
    transfer::share_object(market);
    market_oracle_id
}

/// Abort if the running package version is not allowed for this oracle.
fun assert_version_allowed(market: &MarketOracle) {
    assert!(
        market.allowed_versions.contains(&constants::current_version!()),
        EPackageVersionDisabled,
    );
}

/// Abort unless this oracle is bound to the supplied Pyth source.
public(package) fun assert_pyth_source(market: &MarketOracle, pyth: &PythSource) {
    assert!(market.pyth_source_id == pyth.id(), EWrongPythSource);
}

/// Abort unless this oracle is live and not expired.
public(package) fun assert_active(market: &MarketOracle, clock: &Clock) {
    assert!(market.status(clock) == STATUS_ACTIVE, EMarketNotActive);
}

/// Abort unless the cap is authorized for this oracle.
public(package) fun assert_authorized_cap(market: &MarketOracle, cap: &MarketOracleCap) {
    assert!(market.authorized_cap_ids.contains(&cap.cap_id()), EInvalidMarketOracleCap);
}

// === Private Functions ===

fun register_cap_internal(market: &mut MarketOracle, cap: &MarketOracleCap) {
    market.assert_version_allowed();
    let cap_id = cap.cap_id();
    assert!(!market.authorized_cap_ids.contains(&cap_id), EInvalidMarketOracleCap);
    market.authorized_cap_ids.insert(cap_id);
}

fun unregister_cap_internal(market: &mut MarketOracle, cap_id: ID) {
    market.assert_version_allowed();
    assert!(market.authorized_cap_ids.contains(&cap_id), EInvalidMarketOracleCap);
    market.authorized_cap_ids.remove(&cap_id);
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

    oracle_events::emit_block_scholes_prices_updated(
        market.id(),
        spot,
        forward,
        basis,
        source_timestamp_ms,
        update_timestamp_ms,
    );
}

/// Commit one Block Scholes SVI update: stamp the on-chain time, write the SVI
/// fields, and emit. Mirrors `apply_block_scholes_prices`; validation stays in
/// `update_svi`.
fun apply_block_scholes_svi(
    market: &mut MarketOracle,
    svi: SVIParams,
    source_timestamp_ms: u64,
    clock: &Clock,
) {
    let update_timestamp_ms = clock.timestamp_ms();
    market.block_scholes_svi = svi;
    market.block_scholes_svi_source_timestamp_ms = source_timestamp_ms;
    market.block_scholes_svi_update_timestamp_ms = update_timestamp_ms;

    oracle_events::emit_block_scholes_svi_updated(
        market.id(),
        svi.a(),
        svi.b(),
        svi.rho(),
        svi.m(),
        svi.sigma(),
        source_timestamp_ms,
        update_timestamp_ms,
    );
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

fun compute_bounded_basis(market: &MarketOracle, spot: u64, forward: u64): u64 {
    let basis = math::div(forward, spot);
    assert!(market.config.basis_in_range(basis), EBasisOutOfRange);
    basis
}

fun validate_basis_push(market: &MarketOracle, new_spot: u64, new_basis: u64) {
    let prev_spot = market.block_scholes_spot;
    if (prev_spot > 0) {
        assert!(market.config.spot_deviation_allowed(prev_spot, new_spot), ESpotDeviationTooLarge);
    };

    let prev_forward = market.block_scholes_forward;
    if (prev_spot > 0 && prev_forward > 0) {
        let prev_basis = market.block_scholes_basis();
        assert!(
            market.config.basis_deviation_allowed(prev_basis, new_basis),
            EBasisDeviationTooLarge,
        );
    };
}

fun emit_bounds_updated(market: &MarketOracle) {
    config_events::emit_market_oracle_bounds_updated(market.id(), &market.config);
}
