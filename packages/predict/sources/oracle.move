// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Core oracle state, lifecycle, and exact pricing primitives.
///
/// This module owns the shared oracle object, update capabilities, settlement,
/// and the plain data structs used to update and read oracle state. It also
/// exposes exact binary pricing helpers derived directly from oracle state.
/// Predict-specific strike-grid and curve-sampling logic live outside this module.
module deepbook_predict::oracle;

use deepbook::math;
use deepbook_predict::{constants::{Self, float_scaling}, i64, math as predict_math};
use pyth_lazer::{
    i16::{Self as lazer_i16, I16 as LazerI16},
    i64::{Self as lazer_i64, I64 as LazerI64},
    update::Update as LazerUpdate
};
use std::string::String;
use sui::{clock::Clock, event, vec_set::{Self, VecSet}};

// === Errors ===

const EInvalidOracleCap: u64 = 0;
const EOracleAlreadyActive: u64 = 1;
const EOracleExpired: u64 = 2;
const EZeroForward: u64 = 3;
const ECannotBeNegative: u64 = 4;
const EZeroVariance: u64 = 5;
const EOracleSettled: u64 = 6;
const EZeroSpot: u64 = 7;
const EBasisNotSeeded: u64 = 8;
const EBasisStale: u64 = 9;
const ELazerStaleUpdate: u64 = 10;
const ELazerFeedNotFound: u64 = 11;
const ELazerPriceUnavailable: u64 = 12;
const ELazerNegativePrice: u64 = 13;
const ELazerExponentOutOfRange: u64 = 14;
const ELazerPriceOverflow: u64 = 15;
const EInvalidStalenessThreshold: u64 = 16;
const EInvalidBasisBounds: u64 = 17;
const EBasisSpotDeviationTooLarge: u64 = 18;
const EBasisDeviationTooLarge: u64 = 19;
const EBasisOutOfRange: u64 = 20;
const EOracleStale: u64 = 21;
const EOracleInactive: u64 = 22;

// Pre-expiry oracle that has not been activated yet.
const STATUS_INACTIVE: u8 = 0;
// Pre-expiry oracle that is active and can accept live updates.
const STATUS_ACTIVE: u8 = 1;
// Expired oracle that has not yet been settled by a price push.
const STATUS_PENDING_SETTLEMENT: u8 = 2;
// Oracle with a frozen settlement price.
const STATUS_SETTLED: u8 = 3;

// === Events ===

public struct OracleActivated has copy, drop, store {
    oracle_id: ID,
    expiry: u64,
    spot_timestamp_ms: u64,
}

public struct OracleSettled has copy, drop, store {
    oracle_id: ID,
    expiry: u64,
    settlement_price: u64,
    spot_timestamp_ms: u64,
}

public struct OraclePricesUpdated has copy, drop, store {
    oracle_id: ID,
    spot: u64,
    forward: u64,
    basis: u64,
    spot_timestamp_ms: u64,
}

public struct OracleSVIUpdated has copy, drop, store {
    oracle_id: ID,
    a: u64,
    b: u64,
    rho: i64::I64,
    m: i64::I64,
    sigma: u64,
    timestamp: u64,
}

public struct OracleSpotUpdatedFromLazer has copy, drop, store {
    oracle_id: ID,
    spot: u64,
    forward: u64,
    basis: u64,
    lazer_published_at_us: u64,
    spot_timestamp_ms: u64,
}

/// Emitted when `update_basis` finds Lazer stale and the operator spot takes
/// over the master spot. Indexers can track Lazer outages off this event.
public struct OracleSpotFallbackEngaged has copy, drop, store {
    oracle_id: ID,
    operator_spot: u64,
    last_lazer_spot_timestamp_ms: u64,
    spot_timestamp_ms: u64,
}

/// Emitted whenever any field on `OracleSVI.bounds` is updated. Carries the
/// full post-update snapshot so indexers can track the current live
/// configuration off a single event.
public struct OracleBoundsUpdated has copy, drop, store {
    oracle_id: ID,
    spot_staleness_threshold_ms: u64,
    basis_staleness_threshold_ms: u64,
    lazer_authoritative_threshold_ms: u64,
    max_spot_deviation: u64,
    max_basis_deviation: u64,
    min_basis: u64,
    max_basis: u64,
}

// === Structs ===

/// SVI volatility surface parameters.
/// All values scaled by FLOAT_SCALING (1e9).
public struct SVIParams has copy, drop, store {
    /// Overall variance level (always >= 0)
    a: u64,
    /// Slope of the smile wings (always >= 0)
    b: u64,
    /// Signed skew parameter (typically negative - puts more expensive)
    rho: i64::I64,
    /// Signed horizontal shift parameter
    m: i64::I64,
    /// ATM curvature / smoothness (always >= 0)
    sigma: u64,
}

/// Price data updated at high frequency (~200ms via Pyth Lazer) and ~10s
/// (basis, via operator push).
/// All values scaled by FLOAT_SCALING (1e9).
/// Forward is intentionally NOT cached — derive it as `spot * basis` via
/// `forward_price()`. Two-of-three storage avoids the "must stay consistent"
/// invariant that any third cached value would impose on every write site.
public struct PriceData has copy, drop, store {
    /// Current spot price of the underlying
    spot: u64,
    /// Cached forward/spot carry ratio from the most recent `update_basis`.
    /// Consumed by `update_spot_from_lazer` to rederive forward when a new
    /// spot arrives without recomputing the ratio (which would compound
    /// integer-division rounding).
    basis: u64,
}

/// Per-oracle staleness thresholds and basis circuit-breaker bounds. Snapshot
/// at `create_oracle` from the admin-tuned configuration on
/// `Predict.oracle_config`; tuned post-creation by the oracle's operator via
/// `OracleSVICap`-authorized setters. Consumed by `update_basis`,
/// `update_spot_from_lazer`, `assert_live_oracle`, and
/// `assert_quoteable_oracle`.
public struct OracleBounds has copy, drop, store {
    /// Maximum age (ms) of `spot_timestamp_ms` before `assert_live_oracle` /
    /// `assert_quoteable_oracle` reject it.
    spot_staleness_threshold_ms: u64,
    /// Maximum age (ms) of the cached operator basis before
    /// `assert_live_oracle` / `assert_quoteable_oracle` reject it and before
    /// `update_spot_from_lazer` refuses to derive a fresh forward against it.
    basis_staleness_threshold_ms: u64,
    /// Window (ms) within which Pyth Lazer's last spot push is treated as the
    /// authoritative master spot. While Lazer is within this window,
    /// `update_basis` refreshes basis/forward but does NOT overwrite
    /// `prices.spot`. Beyond it, the operator's spot flows through as a
    /// fallback. Independent of `spot_staleness_threshold_ms` (the hard halt
    /// gate, always checked on top).
    lazer_authoritative_threshold_ms: u64,
    /// Per-push spot deviation cap enforced in `validate_basis_push`.
    /// 1e9-scaled fraction; skipped on first push (no prior baseline).
    max_spot_deviation: u64,
    /// Per-push basis deviation cap enforced in `validate_basis_push`.
    /// 1e9-scaled fraction; skipped on first push (no prior baseline).
    max_basis_deviation: u64,
    /// Absolute lower bound on `forward / spot`. Always checked.
    min_basis: u64,
    /// Absolute upper bound on `forward / spot`. Always checked.
    max_basis: u64,
}

/// Shared oracle object storing SVI volatility surface data.
/// One oracle per underlying + expiry combination.
public struct OracleSVI has key {
    id: UID,
    /// IDs of oracle caps authorized to update this oracle
    authorized_caps: VecSet<ID>,
    /// The underlying asset this oracle tracks (e.g., "BTC", "ETH")
    underlying_asset: String,
    /// Pyth Lazer feed id for high-frequency spot updates. Initial deploy
    /// uses id `1` (BTC/USD). Linear-scanned on every `update_spot_from_lazer`
    /// to pick the right `Feed` out of the multi-feed `Update` payload.
    pyth_lazer_feed_id: u32,
    /// Expiration timestamp in milliseconds
    expiry: u64,
    /// Whether the oracle is active
    active: bool,
    /// Spot and cached basis ratio (forward derived on access).
    prices: PriceData,
    /// SVI volatility surface parameters (low frequency updates)
    svi: SVIParams,
    /// Clock ms of the most recent update to `prices.spot`. Bumped by
    /// `apply_lazer_spot` always, and by `update_basis` only when the
    /// operator is falling back in because Lazer has gone stale. Consumed
    /// by `assert_live_oracle` / `assert_quoteable_oracle` as the hard
    /// spot-staleness halt gate.
    spot_timestamp_ms: u64,
    /// Clock ms of the most recent successful `apply_lazer_spot` call. Used
    /// by `update_basis` to decide whether Lazer currently owns the master
    /// spot: while `now <= lazer_spot_timestamp_ms +
    /// lazer_authoritative_threshold_ms`, operator pushes update
    /// basis/forward but leave `prices.spot` alone. Zero until the first
    /// Lazer push lands.
    lazer_spot_timestamp_ms: u64,
    /// Clock ms of the most recent `update_basis`. Gates how stale the
    /// cached basis can be before `update_spot_from_lazer` refuses to
    /// rederive a forward against it, and before the live/quoteable asserts
    /// permit quoting. Enforces operator liveness independent of Lazer
    /// cadence.
    basis_timestamp_ms: u64,
    /// Pyth Lazer publisher's own microsecond timestamp (source-data time,
    /// not on-chain landing time) from the most recent
    /// `update_spot_from_lazer`. Enforces monotonic Lazer updates
    /// independent of operator basis cadence. Not used for the user-facing
    /// staleness window.
    lazer_published_at_us: u64,
    /// Per-oracle staleness thresholds and basis circuit-breaker bounds.
    bounds: OracleBounds,
    /// Settlement price, frozen on first update after expiry
    settlement_price: Option<u64>,
}

/// Capability for Block Scholes operator to create and update SVI oracles.
public struct OracleSVICap has key, store {
    id: UID,
}

// === Public Functions ===

/// Activate the oracle. Must be called before oracle can be used for pricing.
public fun activate(oracle: &mut OracleSVI, cap: &OracleSVICap, clock: &Clock) {
    oracle.assert_authorized_cap(cap);
    assert!(!oracle.active, EOracleAlreadyActive);

    let now = clock.timestamp_ms();
    assert!(now < oracle.expiry, EOracleExpired);

    oracle.active = true;

    event::emit(OracleActivated {
        oracle_id: oracle.id.to_inner(),
        expiry: oracle.expiry,
        spot_timestamp_ms: now,
    });
}

/// Operator push (~1s): refresh the cached basis from a matched
/// (spot, forward) pair. Basis is computed as `forward / spot` in 1e9 float
/// scaling and is preserved across subsequent Lazer spot pushes to avoid
/// compounding integer-division rounding.
///
/// Lazer is the authoritative master spot whenever it has pushed within
/// `bounds.lazer_authoritative_threshold_ms`. While inside that window the
/// operator push refreshes the cached basis without touching `prices.spot`
/// or `spot_timestamp_ms` (forward is derived as `spot * basis` on access).
/// Once Lazer has gone stale, the operator spot flows through as a fallback:
/// it overwrites `prices.spot`, bumps `spot_timestamp_ms`, and emits
/// `OracleSpotFallbackEngaged` so indexers can flag Lazer outages.
///
/// If at or past expiry and not yet settled, freezes settlement price and
/// deactivates. Settled oracles reject further updates.
public fun update_basis(
    oracle: &mut OracleSVI,
    cap: &OracleSVICap,
    spot: u64,
    forward: u64,
    clock: &Clock,
) {
    oracle.assert_authorized_cap(cap);
    assert!(spot > 0, EZeroSpot);
    assert!(forward > 0, EZeroForward);

    let oracle_status = oracle.status(clock);
    assert!(oracle_status != status_settled(), EOracleSettled);

    let now = clock.timestamp_ms();
    let oracle_id = oracle.id.to_inner();

    // If at or past expiry, freeze settlement price and deactivate instead of
    // recording another live price update.
    if (oracle_status == status_pending_settlement()) {
        oracle.settlement_price = option::some(spot);
        oracle.active = false;

        event::emit(OracleSettled {
            oracle_id,
            expiry: oracle.expiry,
            settlement_price: spot,
            spot_timestamp_ms: oracle.spot_timestamp_ms,
        });
        return
    };

    let new_basis = math::div(forward, spot);
    oracle.validate_basis_push(spot, new_basis);
    oracle.basis_timestamp_ms = now;

    let lazer_fresh =
        oracle.lazer_spot_timestamp_ms > 0 &&
        now <= oracle.lazer_spot_timestamp_ms + oracle.bounds.lazer_authoritative_threshold_ms;

    if (lazer_fresh) {
        // Lazer owns the master spot. Keep `prices.spot` as-is, refresh the
        // cached basis. Do NOT bump `spot_timestamp_ms` — Lazer's own cadence
        // keeps the halt gate passing while it is authoritative.
        let cached_spot = oracle.prices.spot;
        oracle.prices = PriceData { spot: cached_spot, basis: new_basis };

        event::emit(OraclePricesUpdated {
            oracle_id,
            spot: cached_spot,
            forward: math::mul(cached_spot, new_basis),
            basis: new_basis,
            spot_timestamp_ms: oracle.spot_timestamp_ms,
        });
    } else {
        // Fallback: Lazer is stale or has never pushed. Operator takes over
        // the master spot. The operator's pushed `forward` parameter is used
        // only to derive `new_basis`; the emitted `forward` is the canonical
        // `spot * basis` derivation (off by ~1 ulp from the literal push).
        oracle.prices = PriceData { spot, basis: new_basis };
        oracle.spot_timestamp_ms = now;

        event::emit(OracleSpotFallbackEngaged {
            oracle_id,
            operator_spot: spot,
            last_lazer_spot_timestamp_ms: oracle.lazer_spot_timestamp_ms,
            spot_timestamp_ms: now,
        });
        event::emit(OraclePricesUpdated {
            oracle_id,
            spot,
            forward: math::mul(spot, new_basis),
            basis: new_basis,
            spot_timestamp_ms: now,
        });
    };
}

/// Permissionless high-frequency push (~200ms): consume a verified Pyth
/// Lazer `Update` and rederive `forward = spot * basis` against the cached
/// basis. Trust root is the fact that `Update` can only be constructed
/// inside the `pyth_lazer` package, so the Move type system enforces that
/// this value came from Pyth's on-chain verifier. The stale-basis check uses
/// `oracle.bounds.basis_staleness_threshold_ms`, so permissionless callers
/// cannot bypass it from a PTB.
public fun update_spot_from_lazer(oracle: &mut OracleSVI, update: LazerUpdate, clock: &Clock) {
    let lazer_published_at_us = update.timestamp();
    let feeds = update.feeds_ref();
    let feed_id = oracle.pyth_lazer_feed_id;
    let idx_opt = feeds.find_index!(|f| f.feed_id() == feed_id);
    assert!(idx_opt.is_some(), ELazerFeedNotFound);
    let feed = &feeds[idx_opt.destroy_some()];

    // Both Option layers must be Some: the field must exist in the update,
    // and the value must be present (Lazer returns None if there are not
    // enough publishers).
    let price_outer = feed.price();
    assert!(price_outer.is_some(), ELazerPriceUnavailable);
    let price_inner = price_outer.borrow();
    assert!(price_inner.is_some(), ELazerPriceUnavailable);
    let price = *price_inner.borrow();

    let exp_outer = feed.exponent();
    assert!(exp_outer.is_some(), ELazerPriceUnavailable);
    let exponent = *exp_outer.borrow();

    let spot = normalize_pyth_price(price, exponent);
    oracle.apply_lazer_spot(spot, lazer_published_at_us, clock);
}

// TODO: Add validation on pushed SVI params so obviously bad updates are
// rejected before they mutate state.
/// Push SVI parameters (low frequency ~10-20s) while the oracle is still
/// unsettled and pre-expiry.
public fun update_svi(oracle: &mut OracleSVI, cap: &OracleSVICap, svi: SVIParams, clock: &Clock) {
    oracle.assert_authorized_cap(cap);
    let oracle_status = oracle.status(clock);
    assert!(oracle_status != status_settled(), EOracleSettled);
    assert!(oracle_status != status_pending_settlement(), EOracleExpired);

    let now = clock.timestamp_ms();

    oracle.svi = svi;

    event::emit(OracleSVIUpdated {
        oracle_id: oracle.id.to_inner(),
        a: svi.a,
        b: svi.b,
        rho: svi.rho,
        m: svi.m,
        sigma: svi.sigma,
        timestamp: now,
    });
}

/// Get the oracle ID.
public fun id(oracle: &OracleSVI): ID {
    oracle.id.to_inner()
}

/// Get the underlying asset name.
public fun underlying_asset(oracle: &OracleSVI): String {
    oracle.underlying_asset
}

/// Get the current spot price.
public fun spot_price(oracle: &OracleSVI): u64 {
    oracle.prices.spot
}

/// Get the forward price for this expiry. Derived as `spot * basis` from the
/// cached `PriceData`; not a stored field.
public fun forward_price(oracle: &OracleSVI): u64 {
    math::mul(oracle.prices.spot, oracle.prices.basis)
}

/// Get the cached basis ratio (forward / spot) from the most recent
/// `update_basis`. Zero until the first operator push lands.
public fun basis(oracle: &OracleSVI): u64 {
    oracle.prices.basis
}

/// Get the price data.
public fun prices(oracle: &OracleSVI): PriceData {
    oracle.prices
}

/// Get the SVI parameters.
public fun svi(oracle: &OracleSVI): SVIParams {
    oracle.svi
}

/// Get the SVI `a` parameter.
public fun svi_a(svi: &SVIParams): u64 {
    svi.a
}

/// Get the SVI `b` parameter.
public fun svi_b(svi: &SVIParams): u64 {
    svi.b
}

/// Get the signed SVI `rho` parameter.
public fun svi_rho(svi: &SVIParams): i64::I64 {
    svi.rho
}

/// Get the signed SVI `m` parameter.
public fun svi_m(svi: &SVIParams): i64::I64 {
    svi.m
}

/// Get the SVI `sigma` parameter.
public fun svi_sigma(svi: &SVIParams): u64 {
    svi.sigma
}

/// Get the expiry timestamp.
public fun expiry(oracle: &OracleSVI): u64 {
    oracle.expiry
}

/// Get the on-chain clock ms of the most recent master-spot update.
public fun spot_timestamp_ms(oracle: &OracleSVI): u64 {
    oracle.spot_timestamp_ms
}

/// Get the on-chain clock ms of the most recent successful Lazer spot push.
public fun lazer_spot_timestamp_ms(oracle: &OracleSVI): u64 {
    oracle.lazer_spot_timestamp_ms
}

/// Get the on-chain clock ms of the most recent `update_basis` call.
public fun basis_timestamp_ms(oracle: &OracleSVI): u64 {
    oracle.basis_timestamp_ms
}

/// Get the Pyth Lazer publisher's microsecond timestamp from the most
/// recent Lazer push (source-data time, not on-chain landing time).
public fun lazer_published_at_us(oracle: &OracleSVI): u64 {
    oracle.lazer_published_at_us
}

/// Get the Pyth Lazer feed id that this oracle tracks.
public fun pyth_lazer_feed_id(oracle: &OracleSVI): u32 {
    oracle.pyth_lazer_feed_id
}

/// Get the per-oracle staleness thresholds and basis circuit-breaker bounds.
public fun bounds(oracle: &OracleSVI): OracleBounds {
    oracle.bounds
}

public fun bounds_spot_staleness_threshold_ms(bounds: &OracleBounds): u64 {
    bounds.spot_staleness_threshold_ms
}

public fun bounds_basis_staleness_threshold_ms(bounds: &OracleBounds): u64 {
    bounds.basis_staleness_threshold_ms
}

public fun bounds_lazer_authoritative_threshold_ms(bounds: &OracleBounds): u64 {
    bounds.lazer_authoritative_threshold_ms
}

public fun bounds_max_spot_deviation(bounds: &OracleBounds): u64 {
    bounds.max_spot_deviation
}

public fun bounds_max_basis_deviation(bounds: &OracleBounds): u64 {
    bounds.max_basis_deviation
}

public fun bounds_min_basis(bounds: &OracleBounds): u64 {
    bounds.min_basis
}

public fun bounds_max_basis(bounds: &OracleBounds): u64 {
    bounds.max_basis
}

/// Get the settlement price (only valid after settlement).
public fun settlement_price(oracle: &OracleSVI): Option<u64> {
    oracle.settlement_price
}

/// Check if the oracle has been settled.
public fun is_settled(oracle: &OracleSVI): bool {
    oracle.settlement_price.is_some()
}

/// Check if the oracle is active.
public fun is_active(oracle: &OracleSVI): bool {
    oracle.active
}

/// Return the lifecycle status implied by the oracle's state and the current clock.
public fun status(oracle: &OracleSVI, clock: &Clock): u8 {
    if (oracle.is_settled()) {
        STATUS_SETTLED
    } else if (clock.timestamp_ms() >= oracle.expiry) {
        STATUS_PENDING_SETTLEMENT
    } else if (!oracle.active) {
        STATUS_INACTIVE
    } else {
        STATUS_ACTIVE
    }
}

public fun status_inactive(): u8 {
    STATUS_INACTIVE
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

/// Create a new SVIParams struct.
public fun new_svi_params(a: u64, b: u64, rho: i64::I64, m: i64::I64, sigma: u64): SVIParams {
    SVIParams { a, b, rho, m, sigma }
}

/// Tune the spot-staleness halt-gate threshold. Authorized by `OracleSVICap`.
/// Bounded by `constants::max_staleness_threshold_ms!()` (60s) — beyond that
/// the liveness gate stops meaningfully protecting quoting.
public fun set_spot_staleness_threshold_ms(oracle: &mut OracleSVI, cap: &OracleSVICap, value: u64) {
    oracle.assert_authorized_cap(cap);
    validate_staleness_ms(value);
    oracle.bounds.spot_staleness_threshold_ms = value;
    oracle.emit_bounds_updated();
}

/// Tune the basis-staleness halt-gate threshold. Authorized by `OracleSVICap`.
/// Bounded by `constants::max_staleness_threshold_ms!()` (60s).
public fun set_basis_staleness_threshold_ms(
    oracle: &mut OracleSVI,
    cap: &OracleSVICap,
    value: u64,
) {
    oracle.assert_authorized_cap(cap);
    validate_staleness_ms(value);
    oracle.bounds.basis_staleness_threshold_ms = value;
    oracle.emit_bounds_updated();
}

/// Tune the window within which Lazer's last spot push is treated as the
/// authoritative master spot. Authorized by `OracleSVICap`. Bounded by
/// `constants::max_staleness_threshold_ms!()` (60s).
public fun set_lazer_authoritative_threshold_ms(
    oracle: &mut OracleSVI,
    cap: &OracleSVICap,
    value: u64,
) {
    oracle.assert_authorized_cap(cap);
    validate_staleness_ms(value);
    oracle.bounds.lazer_authoritative_threshold_ms = value;
    oracle.emit_bounds_updated();
}

/// Tune the four circuit-breaker values applied on every `update_basis`.
/// Authorized by `OracleSVICap`. Validates `min_basis < max_basis` and that
/// both deviation fractions fit within 1.0 (1e9 scale).
public fun set_basis_bounds(
    oracle: &mut OracleSVI,
    cap: &OracleSVICap,
    max_spot_deviation: u64,
    max_basis_deviation: u64,
    min_basis: u64,
    max_basis: u64,
) {
    oracle.assert_authorized_cap(cap);
    validate_basis_bounds_inputs(max_spot_deviation, max_basis_deviation, min_basis, max_basis);
    oracle.bounds.max_spot_deviation = max_spot_deviation;
    oracle.bounds.max_basis_deviation = max_basis_deviation;
    oracle.bounds.min_basis = min_basis;
    oracle.bounds.max_basis = max_basis;
    oracle.emit_bounds_updated();
}

/// Compute the conditional UP price within one binary pair.
/// Settled oracles return exactly `1.0` if UP wins and `0` otherwise. Live
/// oracles return `N(d2)` from the SVI surface.
public(package) fun compute_price(oracle: &OracleSVI, strike: u64): u64 {
    if (oracle.settlement_price.is_some()) {
        let settlement_price = oracle.settlement_price.destroy_some();
        if (settlement_price > strike) {
            constants::float_scaling!()
        } else {
            0
        }
    } else {
        compute_nd2(oracle, strike)
    }
}

/// Return the exact fair prices for both sides of a binary market.
/// The live parity invariant is `UP + DN = 1`.
public(package) fun binary_price_pair(oracle: &OracleSVI, strike: u64, _clock: &Clock): (u64, u64) {
    let up_price = oracle.compute_price(strike);
    (up_price, float_scaling!() - up_price)
}

// === Public-Package Functions ===

/// Register an additional cap as authorized to update an oracle.
public(package) fun register_cap(oracle: &mut OracleSVI, cap: &OracleSVICap) {
    oracle.authorized_caps.insert(cap.id.to_inner());
}

/// Create a new OracleCap. Called by registry during setup.
public(package) fun create_oracle_cap(ctx: &mut TxContext): OracleSVICap {
    OracleSVICap { id: object::new(ctx) }
}

public(package) fun assert_authorized_cap(oracle: &OracleSVI, cap: &OracleSVICap) {
    assert!(oracle.authorized_caps.contains(&cap.id.to_inner()), EInvalidOracleCap);
}

/// Assert that an oracle can still be used for actions that require live
/// pricing. The oracle must be `ACTIVE` and fresh; `INACTIVE`,
/// `PENDING_SETTLEMENT`, `SETTLED`, and stale oracles are rejected.
public(package) fun assert_live_oracle(oracle: &OracleSVI, clock: &Clock) {
    let oracle_status = oracle.status(clock);
    assert!(oracle_status != STATUS_SETTLED, EOracleSettled);
    assert!(oracle_status != STATUS_PENDING_SETTLEMENT, EOracleExpired);
    assert!(oracle_status != STATUS_INACTIVE, EOracleInactive);
    oracle.assert_fresh(clock);
}

/// Assert that an oracle can still be used for actions that accept either live
/// pricing or a finalized settlement price. `SETTLED` oracles are allowed
/// immediately; otherwise the oracle must still be `ACTIVE` and fresh.
/// `PENDING_SETTLEMENT` is intentionally rejected to freeze the
/// expired-but-unsettled gap.
public(package) fun assert_quoteable_oracle(oracle: &OracleSVI, clock: &Clock) {
    let oracle_status = oracle.status(clock);
    if (oracle_status == STATUS_SETTLED) return;
    assert!(oracle_status != STATUS_PENDING_SETTLEMENT, EOracleExpired);
    assert!(oracle_status != STATUS_INACTIVE, EOracleInactive);
    oracle.assert_fresh(clock);
}

/// Create a new SVI Oracle for an underlying + expiry. Returns the oracle ID.
/// `bounds` is a pre-validated snapshot of the admin-tuned staleness
/// thresholds and basis circuit-breaker bounds, built via
/// `new_oracle_bounds(...)` (typically by `oracle_config::build_oracle_bounds`
/// at creation time). The creating `cap` is authorized on the oracle so the
/// operator who created it can immediately activate and push updates;
/// additional caps can be authorized later via `register_cap`.
public(package) fun create_oracle(
    underlying_asset: String,
    pyth_lazer_feed_id: u32,
    expiry: u64,
    bounds: OracleBounds,
    cap: &OracleSVICap,
    ctx: &mut TxContext,
): ID {
    let oracle_uid = object::new(ctx);
    let oracle_id = oracle_uid.to_inner();

    let mut authorized_caps = vec_set::empty();
    authorized_caps.insert(cap.id.to_inner());

    let oracle = OracleSVI {
        id: oracle_uid,
        authorized_caps,
        underlying_asset,
        pyth_lazer_feed_id,
        expiry,
        active: false,
        prices: PriceData { spot: 0, basis: 0 },
        svi: SVIParams {
            a: 0,
            b: 0,
            rho: i64::zero(),
            m: i64::zero(),
            sigma: 0,
        },
        spot_timestamp_ms: 0,
        lazer_spot_timestamp_ms: 0,
        basis_timestamp_ms: 0,
        lazer_published_at_us: 0,
        bounds,
        settlement_price: option::none(),
    };

    transfer::share_object(oracle);
    oracle_id
}

/// Construct and validate an `OracleBounds` from explicit field values. Used
/// by `oracle_config::build_oracle_bounds` to snapshot admin-tuned Predict
/// config onto a new oracle at creation. Staleness fields are bounded by
/// `constants::max_staleness_threshold_ms!()`; basis bounds must satisfy
/// `min_basis < max_basis` and both deviation fractions must fit within 1.0
/// (1e9 scale).
public(package) fun new_oracle_bounds(
    spot_staleness_threshold_ms: u64,
    basis_staleness_threshold_ms: u64,
    lazer_authoritative_threshold_ms: u64,
    max_spot_deviation: u64,
    max_basis_deviation: u64,
    min_basis: u64,
    max_basis: u64,
): OracleBounds {
    validate_staleness_ms(spot_staleness_threshold_ms);
    validate_staleness_ms(basis_staleness_threshold_ms);
    validate_staleness_ms(lazer_authoritative_threshold_ms);
    validate_basis_bounds_inputs(max_spot_deviation, max_basis_deviation, min_basis, max_basis);

    OracleBounds {
        spot_staleness_threshold_ms,
        basis_staleness_threshold_ms,
        lazer_authoritative_threshold_ms,
        max_spot_deviation,
        max_basis_deviation,
        min_basis,
        max_basis,
    }
}

// === Private Functions ===

/// Internal state transition for a verified Lazer spot. Kept separate from
/// `update_spot_from_lazer` so it can be exercised directly by unit tests
/// (verified `Update` values cannot be constructed outside `pyth_lazer`).
/// Reads `bounds.basis_staleness_threshold_ms` directly from the oracle.
fun apply_lazer_spot(oracle: &mut OracleSVI, spot: u64, lazer_published_at_us: u64, clock: &Clock) {
    assert!(spot > 0, EZeroSpot);
    assert!(lazer_published_at_us > oracle.lazer_published_at_us, ELazerStaleUpdate);

    let oracle_status = oracle.status(clock);
    assert!(oracle_status != status_settled(), EOracleSettled);

    let now = clock.timestamp_ms();
    let oracle_id = oracle.id.to_inner();

    // Lazer is the authoritative level source at expiry, so freeze the
    // normalized Lazer spot as the settlement price.
    if (oracle_status == status_pending_settlement()) {
        oracle.settlement_price = option::some(spot);
        oracle.active = false;
        oracle.lazer_published_at_us = lazer_published_at_us;

        event::emit(OracleSettled {
            oracle_id,
            expiry: oracle.expiry,
            settlement_price: spot,
            spot_timestamp_ms: now,
        });
        return
    };

    assert!(oracle.prices.basis > 0, EBasisNotSeeded);
    assert!(
        now <= oracle.basis_timestamp_ms + oracle.bounds.basis_staleness_threshold_ms,
        EBasisStale,
    );

    let basis = oracle.prices.basis;
    let forward = math::mul(spot, basis);
    oracle.prices = PriceData { spot, basis };
    oracle.spot_timestamp_ms = now;
    oracle.lazer_spot_timestamp_ms = now;
    oracle.lazer_published_at_us = lazer_published_at_us;

    event::emit(OracleSpotUpdatedFromLazer {
        oracle_id,
        spot,
        forward,
        basis,
        lazer_published_at_us,
        spot_timestamp_ms: now,
    });
}

/// Convert a Pyth Lazer `(price, exponent)` pair to the predict package's
/// 1e9-scaled u64. Target scaling is `price_1e9 = magnitude * 10^(exponent + 9)`.
/// Aborts on negative price (crypto spot is always positive) or on a shift
/// magnitude > 18 (10^19 overflows u64; real feeds use exponents in [-12, -4]).
fun normalize_pyth_price(price: LazerI64, exponent: LazerI16): u64 {
    assert!(!lazer_i64::get_is_negative(&price), ELazerNegativePrice);
    let magnitude = lazer_i64::get_magnitude_if_positive(&price);

    let exp_is_neg = lazer_i16::get_is_negative(&exponent);
    let exp_mag = if (exp_is_neg) {
        lazer_i16::get_magnitude_if_negative(&exponent) as u64
    } else {
        lazer_i16::get_magnitude_if_positive(&exponent) as u64
    };

    let target: u64 = 9;

    if (exp_is_neg) {
        if (exp_mag <= target) {
            let shift = target - exp_mag;
            assert!(shift <= 18, ELazerExponentOutOfRange);
            checked_scale_up(magnitude, shift)
        } else {
            let shift = exp_mag - target;
            assert!(shift <= 18, ELazerExponentOutOfRange);
            magnitude / predict_math::pow10(shift)
        }
    } else {
        let shift = target + exp_mag;
        assert!(shift <= 18, ELazerExponentOutOfRange);
        checked_scale_up(magnitude, shift)
    }
}

/// Multiply `magnitude * 10^shift`, aborting with `ELazerPriceOverflow` if
/// the result would exceed `u64::MAX` instead of letting the VM raise an
/// unnamed arithmetic abort.
fun checked_scale_up(magnitude: u64, shift: u64): u64 {
    let factor = predict_math::pow10(shift);
    assert!(magnitude == 0 || magnitude <= std::u64::max_value!() / factor, ELazerPriceOverflow);
    magnitude * factor
}

/// Shared freshness gate for `assert_live_oracle` / `assert_quoteable_oracle`.
/// Reads the per-oracle thresholds from `bounds`.
fun assert_fresh(oracle: &OracleSVI, clock: &Clock) {
    let now = clock.timestamp_ms();
    assert!(
        now <= oracle.spot_timestamp_ms + oracle.bounds.spot_staleness_threshold_ms,
        EOracleStale,
    );
    assert!(
        now <= oracle.basis_timestamp_ms + oracle.bounds.basis_staleness_threshold_ms,
        EOracleStale,
    );
}

/// Circuit-breaker guard called at the head of `update_basis` before any
/// state mutation. Rejects obviously-bad operator pushes (decimal errors,
/// fat-finger values, BS outages returning garbage):
///
/// 1. Absolute basis range `[min_basis, max_basis]`. Always checked — for
///    short-dated expiries basis stays near 1.0 so this is a hard sanity rail.
/// 2. Per-push spot deviation vs the previously stored `prices.spot`. Skipped
///    on the first push after activation (no baseline).
/// 3. Per-push basis deviation vs the previously stored `prices.basis`.
///    Basis moves slowly; a large per-push move is always suspicious. Also
///    skipped on the first push.
fun validate_basis_push(oracle: &OracleSVI, new_spot: u64, new_basis: u64) {
    let bounds = &oracle.bounds;
    assert!(new_basis >= bounds.min_basis && new_basis <= bounds.max_basis, EBasisOutOfRange);

    let prev_spot = oracle.prices.spot;
    if (prev_spot > 0) {
        assert!(
            within_deviation(prev_spot, new_spot, bounds.max_spot_deviation),
            EBasisSpotDeviationTooLarge,
        );
    };

    let prev_basis = oracle.prices.basis;
    if (prev_basis > 0) {
        assert!(
            within_deviation(prev_basis, new_basis, bounds.max_basis_deviation),
            EBasisDeviationTooLarge,
        );
    };
}

fun validate_staleness_ms(value: u64) {
    assert!(
        value > 0 && value <= constants::max_staleness_threshold_ms!(),
        EInvalidStalenessThreshold,
    );
}

fun validate_basis_bounds_inputs(
    max_spot_deviation: u64,
    max_basis_deviation: u64,
    min_basis: u64,
    max_basis: u64,
) {
    assert!(min_basis < max_basis, EInvalidBasisBounds);
    assert!(max_spot_deviation <= constants::float_scaling!(), EInvalidBasisBounds);
    assert!(max_basis_deviation <= constants::float_scaling!(), EInvalidBasisBounds);
}

/// Return true iff `|next - prev| <= prev * max_deviation`, where
/// `max_deviation` is 1e9-scaled (1e9 = 100%). Caller must ensure `prev > 0`.
fun within_deviation(prev: u64, next: u64, max_deviation: u64): bool {
    let diff = if (next >= prev) { next - prev } else { prev - next };
    let max_allowed = math::mul(prev, max_deviation);
    diff <= max_allowed
}

fun emit_bounds_updated(oracle: &OracleSVI) {
    let b = &oracle.bounds;
    event::emit(OracleBoundsUpdated {
        oracle_id: oracle.id.to_inner(),
        spot_staleness_threshold_ms: b.spot_staleness_threshold_ms,
        basis_staleness_threshold_ms: b.basis_staleness_threshold_ms,
        lazer_authoritative_threshold_ms: b.lazer_authoritative_threshold_ms,
        max_spot_deviation: b.max_spot_deviation,
        max_basis_deviation: b.max_basis_deviation,
        min_basis: b.min_basis,
        max_basis: b.max_basis,
    });
}

/// Binary pricing from SVI total variance:
/// - k = ln(strike / forward)
/// - w(k) = a + b * (rho * (k - m) + sqrt((k - m)^2 + sigma^2))
/// - d2 = -((k + w(k) / 2) / sqrt(w(k)))
fun compute_nd2(oracle: &OracleSVI, strike: u64): u64 {
    let forward = oracle.forward_price();
    assert!(forward > 0, EZeroForward);

    let svi = oracle.svi;

    // SVI: compute total variance from log-moneyness.
    let k = predict_math::ln(math::div(strike, forward));
    let k_minus_m = k.sub(&svi.m);
    let k_minus_m_squared = k_minus_m.square_scaled();
    let sigma_squared = math::mul(svi.sigma, svi.sigma);
    let sq = predict_math::sqrt(k_minus_m_squared + sigma_squared, constants::float_scaling!());
    let sq_i64 = i64::from_u64(sq);

    let rho_km = svi.rho.mul_scaled(&k_minus_m);
    let inner = rho_km.add(&sq_i64);
    assert!(!inner.is_negative(), ECannotBeNegative);
    let total_var = svi.a + math::mul(svi.b, inner.magnitude());
    assert!(total_var > 0, EZeroVariance);

    // d2 = -((k + total_var/2) / sqrt(total_var)), then N(±d2).
    let sqrt_var = predict_math::sqrt(total_var, constants::float_scaling!());
    let sqrt_var_i64 = i64::from_u64(sqrt_var);
    let half_var_i64 = i64::from_u64(total_var / 2);
    let d2_numerator = k.add(&half_var_i64);
    let d2 = d2_numerator.div_scaled(&sqrt_var_i64);
    let d2 = d2.neg();

    predict_math::normal_cdf(&d2)
}
