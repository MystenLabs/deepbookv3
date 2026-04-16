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
    feed::{Self, Feed as LazerFeed},
    i16::{Self as lazer_i16, I16 as LazerI16},
    i64::{Self as lazer_i64, I64 as LazerI64},
    update::{Self as lazer_update, Update as LazerUpdate}
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
    /// by `oracle_config::assert_live_oracle` / `assert_quoteable_oracle`
    /// as the hard spot-staleness halt gate.
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
/// `lazer_authoritative_threshold_ms`. While inside that window the operator
/// push refreshes the cached basis without touching `prices.spot` or
/// `spot_timestamp_ms` (forward is derived as `spot * basis` on access). Once
/// Lazer has gone stale, the operator spot flows through as a fallback: it
/// overwrites `prices.spot`, bumps `spot_timestamp_ms`, and emits
/// `OracleSpotFallbackEngaged` so indexers can flag Lazer outages.
///
/// If at or past expiry and not yet settled, freezes settlement price and
/// deactivates. Settled oracles reject further updates.
public(package) fun update_basis(
    oracle: &mut OracleSVI,
    cap: &OracleSVICap,
    spot: u64,
    forward: u64,
    lazer_authoritative_threshold_ms: u64,
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
    oracle.basis_timestamp_ms = now;

    let lazer_fresh =
        oracle.lazer_spot_timestamp_ms > 0 &&
        now <= oracle.lazer_spot_timestamp_ms + lazer_authoritative_threshold_ms;

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
/// this value came from Pyth's on-chain verifier. The caller (e.g.
/// `predict::update_spot_from_lazer`) passes `basis_staleness_threshold_ms`
/// read from the admin-controlled `OracleConfig` so the stale-basis check
/// can't be bypassed from a PTB.
public(package) fun update_spot_from_lazer(
    oracle: &mut OracleSVI,
    update: LazerUpdate,
    basis_staleness_threshold_ms: u64,
    clock: &Clock,
) {
    let lazer_published_at_us = lazer_update::timestamp(&update);
    let feed = find_lazer_feed(lazer_update::feeds_ref(&update), oracle.pyth_lazer_feed_id);

    // Both Option layers must be Some: the field must exist in the update,
    // and the value must be present (Lazer returns None if there are not
    // enough publishers).
    let price_outer = feed::price(feed);
    assert!(price_outer.is_some(), ELazerPriceUnavailable);
    let price_inner = price_outer.borrow();
    assert!(price_inner.is_some(), ELazerPriceUnavailable);
    let price = *price_inner.borrow();

    let exp_outer = feed::exponent(feed);
    assert!(exp_outer.is_some(), ELazerPriceUnavailable);
    let exponent = *exp_outer.borrow();

    let spot = normalize_pyth_price(price, exponent);
    oracle.apply_lazer_spot(spot, lazer_published_at_us, basis_staleness_threshold_ms, clock);
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

/// Create a new SVI Oracle for an underlying + expiry. Returns the oracle ID.
public(package) fun create_oracle(
    underlying_asset: String,
    pyth_lazer_feed_id: u32,
    expiry: u64,
    ctx: &mut TxContext,
): ID {
    let oracle_uid = object::new(ctx);
    let oracle_id = oracle_uid.to_inner();

    let oracle = OracleSVI {
        id: oracle_uid,
        authorized_caps: vec_set::empty(),
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
        settlement_price: option::none(),
    };

    transfer::share_object(oracle);
    oracle_id
}

// === Private Functions ===

/// Internal state transition for a verified Lazer spot. Kept separate from
/// `update_spot_from_lazer` so it can be exercised directly by unit tests
/// (verified `Update` values cannot be constructed outside `pyth_lazer`).
/// `basis_staleness_threshold_ms` is threaded from the caller's `OracleConfig`
/// so this primitive does not depend on `oracle_config`, which imports us.
fun apply_lazer_spot(
    oracle: &mut OracleSVI,
    spot: u64,
    lazer_published_at_us: u64,
    basis_staleness_threshold_ms: u64,
    clock: &Clock,
) {
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
    assert!(now <= oracle.basis_timestamp_ms + basis_staleness_threshold_ms, EBasisStale);

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

/// Linear scan through a verified Lazer update's feeds for the one matching
/// `target_id`. Mirrors the reference example; aborts if not found.
fun find_lazer_feed(feeds: &vector<LazerFeed>, target_id: u32): &LazerFeed {
    let len = feeds.length();
    let mut i = 0;
    while (i < len) {
        let f = &feeds[i];
        if (feed::feed_id(f) == target_id) {
            return f
        };
        i = i + 1;
    };
    abort ELazerFeedNotFound
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
    let k_minus_m = i64::sub(&k, &svi.m);
    let k_minus_m_squared = i64::square_scaled(&k_minus_m);
    let sigma_squared = math::mul(svi.sigma, svi.sigma);
    let sq = predict_math::sqrt(k_minus_m_squared + sigma_squared, constants::float_scaling!());
    let sq_i64 = i64::from_u64(sq);

    let rho_km = i64::mul_scaled(&svi.rho, &k_minus_m);
    let inner = i64::add(&rho_km, &sq_i64);
    assert!(!i64::is_negative(&inner), ECannotBeNegative);
    let total_var = svi.a + math::mul(svi.b, i64::magnitude(&inner));
    assert!(total_var > 0, EZeroVariance);

    // d2 = -((k + total_var/2) / sqrt(total_var)), then N(±d2).
    let sqrt_var = predict_math::sqrt(total_var, constants::float_scaling!());
    let sqrt_var_i64 = i64::from_u64(sqrt_var);
    let half_var_i64 = i64::from_u64(total_var / 2);
    let d2_numerator = i64::add(&k, &half_var_i64);
    let d2 = i64::div_scaled(&d2_numerator, &sqrt_var_i64);
    let d2 = i64::neg(&d2);

    predict_math::normal_cdf(&d2)
}
