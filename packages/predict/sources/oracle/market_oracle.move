// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Per-expiry Predict market oracle state and write API.
///
/// This module owns market-specific state: expiry, settlement, operator
/// authorization, Pyth source binding, admin-tunable settlement freshness, and
/// inline Block Scholes data. It stores oracle updates and terminal settlement
/// state. Live oracle reads are resolved by `pricing.move`.
module deepbook_predict::market_oracle;

use deepbook_predict::{
    admin::AdminCap,
    config_events,
    constants,
    market_oracle_config::MarketOracleConfig,
    market_oracle_writer_cap::MarketOracleWriterCap,
    oracle_events,
    protocol_config::ProtocolConfig,
    pyth_source::PythSource,
    settlement_state::{Self, SettlementState}
};
use predict_math::{i64, math};
use sui::{clock::Clock, random::{Self, Random, RandomGenerator}, vec_set::{Self, VecSet}};

const EInvalidMarketOracleWriterCap: u64 = 0;
const EMarketNotActive: u64 = 1;
const EZeroSpot: u64 = 6;
const EZeroForward: u64 = 7;
const EWrongPythSource: u64 = 10;
const EFuturePriceSourceUpdate: u64 = 11;
const EFutureSVISourceUpdate: u64 = 12;
const EInvalidSviRho: u64 = 13;
const EInvalidSviSigma: u64 = 14;
const EPackageVersionDisabled: u64 = 15;

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
    /// MarketOracleWriterCap IDs authorized to write Block Scholes data.
    authorized_writer_cap_ids: VecSet<ID>,
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

/// Return the terminal settlement price, aborting if the market is unsettled.
public fun settlement_price(market: &MarketOracle): u64 {
    market.settlement.price()
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
/// A settled market or a non-advancing source timestamp is a clean no-op so
/// multi-expiry writer PTBs never revert on a settlement or ordering race;
/// malformed payloads still abort. While within the final
/// `settlement_sample_window_ms` before expiry, this records the accepted Block
/// Scholes spot into its settlement sample buffer. After expiry, this latches
/// the first fresh post-expiry Block Scholes price observed by this oracle.
/// Terminal settlement is performed separately by `settle_with_randomness`.
public fun update_block_scholes_prices(
    market: &mut MarketOracle,
    _config: &ProtocolConfig,
    cap: &MarketOracleWriterCap,
    block_scholes_spot: u64,
    block_scholes_forward: u64,
    block_scholes_source_timestamp_ms: u64,
    clock: &Clock,
) {
    market.assert_version_allowed();
    market.assert_authorized_writer_cap(cap);

    // Batch-race no-ops: skip when there is nothing valid to write.
    if (market.is_settled()) return;
    if (block_scholes_source_timestamp_ms <= market.block_scholes_price_source_timestamp_ms) return;

    // Malformed payloads that would be applied abort: a broken writer, not a race.
    assert!(block_scholes_spot > 0, EZeroSpot);
    assert!(block_scholes_forward > 0, EZeroForward);
    assert!(block_scholes_source_timestamp_ms <= clock.timestamp_ms(), EFuturePriceSourceUpdate);

    let basis = math::div(block_scholes_forward, block_scholes_spot);
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
    _config: &ProtocolConfig,
    pyth: &PythSource,
    clock: &Clock,
) {
    market.assert_version_allowed();
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

/// Update live SVI data from an authorized Block Scholes writer.
///
/// SVI is live-market-only: a non-active market (expired or settled) or a
/// non-advancing source timestamp is a clean no-op so multi-expiry writer
/// PTBs never revert on an expiry or ordering race; malformed payloads still
/// abort.
public fun update_svi(
    market: &mut MarketOracle,
    _config: &ProtocolConfig,
    cap: &MarketOracleWriterCap,
    svi: SVIParams,
    source_timestamp_ms: u64,
    clock: &Clock,
) {
    market.assert_version_allowed();
    market.assert_authorized_writer_cap(cap);

    // Batch-race no-ops: skip when there is nothing valid to write.
    if (market.status(clock) != STATUS_ACTIVE) return;
    if (source_timestamp_ms <= market.block_scholes_svi_source_timestamp_ms) return;

    // Malformed payloads that would be applied abort: a broken writer, not a race.
    assert!(source_timestamp_ms <= clock.timestamp_ms(), EFutureSVISourceUpdate);
    assert_valid_svi(&svi);

    market.apply_block_scholes_svi(svi, source_timestamp_ms, clock);
}

/// Set the live settlement freshness threshold for this oracle.
public fun set_settlement_freshness_ms(
    market: &mut MarketOracle,
    _config: &ProtocolConfig,
    _admin_cap: &AdminCap,
    value: u64,
) {
    market.assert_version_allowed();
    market.config.set_settlement_freshness_ms(value);
    market.emit_config_updated();
}

/// Authorize a writer cap ID to write this market oracle.
public fun register_writer_cap(market: &mut MarketOracle, _admin_cap: &AdminCap, cap_id: ID) {
    market.assert_version_allowed();
    assert!(!market.authorized_writer_cap_ids.contains(&cap_id), EInvalidMarketOracleWriterCap);
    market.authorized_writer_cap_ids.insert(cap_id);
}

/// Remove an oracle writer capability from this market oracle's writer set.
public fun unregister_writer_cap(market: &mut MarketOracle, _admin_cap: &AdminCap, cap_id: ID) {
    market.unregister_writer_cap_internal(cap_id);
}

/// Let an oracle writer capability holder remove its own cap from this market oracle.
public fun self_unregister_writer_cap(market: &mut MarketOracle, cap: &MarketOracleWriterCap) {
    market.unregister_writer_cap_internal(cap.id());
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

// === Public-Package Functions ===

/// Overwrite this oracle's mirrored `allowed_versions`. The only authorized
/// caller is `registry::sync_market_oracle_allowed_versions`, which reads the
/// source of truth from `Registry`.
public(package) fun set_allowed_versions(market: &mut MarketOracle, allowed_versions: VecSet<u64>) {
    market.allowed_versions = allowed_versions;
}

/// Abort unless SVI rho and sigma lie within model-team 1e9 fixed-point bounds.
public(package) fun assert_valid_svi(svi: &SVIParams) {
    assert!(svi.rho().magnitude() <= math::float_scaling!(), EInvalidSviRho);
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
    _config: &ProtocolConfig,
    pyth: &PythSource,
    gen: &mut RandomGenerator,
    clock: &Clock,
) {
    market.assert_version_allowed();
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

/// Create and share a market oracle bound to a Pyth source, seeding its
/// authorized writer set.
public(package) fun create_and_share(
    pyth: &PythSource,
    config: &ProtocolConfig,
    writer_cap_ids: vector<ID>,
    expiry: u64,
    allowed_versions: VecSet<u64>,
    ctx: &mut TxContext,
): ID {
    let market = MarketOracle {
        id: object::new(ctx),
        // Duplicate IDs abort in from_keys; empty is allowed — admin can
        // register a writer later via register_writer_cap.
        authorized_writer_cap_ids: vec_set::from_keys(writer_cap_ids),
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
    market.emit_config_updated();
    transfer::share_object(market);
    market_oracle_id
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
public(package) fun assert_authorized_writer_cap(
    market: &MarketOracle,
    cap: &MarketOracleWriterCap,
) {
    assert!(market.authorized_writer_cap_ids.contains(&cap.id()), EInvalidMarketOracleWriterCap);
}

// === Private Functions ===

/// Abort if the running package version is not allowed for this oracle.
fun assert_version_allowed(market: &MarketOracle) {
    assert!(
        market.allowed_versions.contains(&constants::current_version!()),
        EPackageVersionDisabled,
    );
}

fun unregister_writer_cap_internal(market: &mut MarketOracle, cap_id: ID) {
    market.assert_version_allowed();
    assert!(market.authorized_writer_cap_ids.contains(&cap_id), EInvalidMarketOracleWriterCap);
    market.authorized_writer_cap_ids.remove(&cap_id);
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

fun emit_config_updated(market: &MarketOracle) {
    config_events::emit_market_oracle_config_updated(market.id(), &market.config);
}
