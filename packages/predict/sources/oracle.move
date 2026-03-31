// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Block Scholes Oracle - SVI-based volatility surface oracle.
///
/// Stores SVI (Stochastic Volatility Inspired) parameters that allow
/// computing implied volatility for ANY strike on-chain.
///
/// SVI formula:
///   k = ln(strike / forward)
///   total_variance = a + b * (rho * (k - m) + sqrt((k - m)² + sigma²))
///   implied_vol = sqrt(total_variance / time_to_expiry)
module deepbook_predict::oracle;

use deepbook::math;
use deepbook_predict::{constants, math as predict_math};
use std::string::String;
use sui::{clock::Clock, event, vec_set::{Self, VecSet}};

// === Errors ===

const EInvalidOracleCap: u64 = 0;
const EOracleStale: u64 = 1;
const EOracleAlreadyActive: u64 = 2;
const EOracleExpired: u64 = 3;
const ECannotBeNegative: u64 = 4;
const EZeroVariance: u64 = 5;
const EZeroForward: u64 = 6;
const EInvalidStrikeGrid: u64 = 7;
const EStrikeOutOfRange: u64 = 8;
const EStrikeNotOnTick: u64 = 9;
const EPriceOutOfRange: u64 = 10;
const EInvalidTickSize: u64 = 11;
#[test_only]
const TEST_MAX_STRIKE: u64 = 18_446_744_073_709_551_615;

// === Events ===

public struct OracleActivated has copy, drop, store {
    oracle_id: ID,
    expiry: u64,
    timestamp: u64,
}

public struct OracleSettled has copy, drop, store {
    oracle_id: ID,
    expiry: u64,
    settlement_price: u64,
    timestamp: u64,
}

public struct OraclePricesUpdated has copy, drop, store {
    oracle_id: ID,
    spot: u64,
    forward: u64,
    timestamp: u64,
}

public struct OracleSVIUpdated has copy, drop, store {
    oracle_id: ID,
    a: u64,
    b: u64,
    rho: u64,
    rho_negative: bool,
    m: u64,
    m_negative: bool,
    sigma: u64,
    risk_free_rate: u64,
    timestamp: u64,
}

// === Structs ===

/// SVI volatility surface parameters.
/// All values scaled by FLOAT_SCALING (1e9).
public struct SVIParams has copy, drop, store {
    /// Overall variance level (always >= 0)
    a: u64,
    /// Slope of the smile wings (always >= 0)
    b: u64,
    /// Skew parameter magnitude
    rho: u64,
    /// Whether rho is negative (typically true - puts more expensive)
    rho_negative: bool,
    /// Horizontal shift magnitude
    m: u64,
    /// Whether m is negative
    m_negative: bool,
    /// ATM curvature / smoothness (always >= 0)
    sigma: u64,
}

/// Price data updated at high frequency (~1s).
/// All values scaled by FLOAT_SCALING (1e9).
public struct PriceData has copy, drop, store {
    /// Current spot price of the underlying
    spot: u64,
    /// Forward price for this expiry
    forward: u64,
}

/// Shared oracle object storing SVI volatility surface data.
/// One oracle per underlying + expiry combination.
public struct OracleSVI has key {
    id: UID,
    /// IDs of OracleCaps authorized to update this oracle
    authorized_caps: VecSet<ID>,
    /// The underlying asset this oracle tracks (e.g., "BTC", "ETH")
    underlying_asset: String,
    /// Expiration timestamp in milliseconds
    expiry: u64,
    /// Minimum allowed strike for the lifetime of this oracle
    min_strike: u64,
    /// Maximum allowed strike for the lifetime of this oracle
    max_strike: u64,
    /// Tick size for valid strikes on this oracle
    tick_size: u64,
    /// Whether the oracle is active
    active: bool,
    /// Spot and forward prices (high frequency updates)
    prices: PriceData,
    /// SVI volatility surface parameters (low frequency updates)
    svi: SVIParams,
    /// Risk-free rate for discounting (scaled by FLOAT_SCALING)
    risk_free_rate: u64,
    /// Timestamp of last update in milliseconds
    timestamp: u64,
    /// Settlement price, frozen on first update after expiry
    settlement_price: Option<u64>,
}

/// Curve sample point with strike and both UP/DOWN prices.
public struct CurvePoint has copy, drop, store {
    strike: u64,
    up_price: u64,
    dn_price: u64,
}

/// Capability for Block Scholes operator to create and update oracles.
public struct OracleCapSVI has key, store {
    id: UID,
}

// === Public Functions ===

/// Activate the oracle. Must be called before oracle can be used for pricing.
public fun activate(oracle: &mut OracleSVI, cap: &OracleCapSVI, clock: &Clock) {
    assert_authorized_cap(oracle, cap);
    assert!(!oracle.active, EOracleAlreadyActive);

    let now = clock.timestamp_ms();
    assert!(now < oracle.expiry, EOracleExpired);

    oracle.active = true;

    event::emit(OracleActivated {
        oracle_id: oracle.id.to_inner(),
        expiry: oracle.expiry,
        timestamp: now,
    });
}

/// Push spot and forward prices (high frequency ~1s).
/// If past expiry and not settled, freezes settlement price and deactivates.
public fun update_prices(
    oracle: &mut OracleSVI,
    cap: &OracleCapSVI,
    prices: PriceData,
    clock: &Clock,
) {
    assert_authorized_cap(oracle, cap);
    assert_price_in_range(oracle, prices.spot);
    assert_price_in_range(oracle, prices.forward);

    let now = clock.timestamp_ms();
    let oracle_id = oracle.id.to_inner();

    // If past expiry and not yet settled, freeze settlement price and deactivate
    if (now > oracle.expiry && oracle.settlement_price.is_none()) {
        oracle.settlement_price = option::some(prices.spot);
        oracle.active = false;

        event::emit(OracleSettled {
            oracle_id,
            expiry: oracle.expiry,
            settlement_price: prices.spot,
            timestamp: now,
        });
        return
    };

    oracle.prices = prices;
    oracle.timestamp = now;

    event::emit(OraclePricesUpdated {
        oracle_id,
        spot: prices.spot,
        forward: prices.forward,
        timestamp: now,
    });
}

/// Push SVI parameters and risk-free rate (low frequency ~10-20s).
public fun update_svi(
    oracle: &mut OracleSVI,
    cap: &OracleCapSVI,
    svi: SVIParams,
    risk_free_rate: u64,
    clock: &Clock,
) {
    assert_authorized_cap(oracle, cap);
    assert!(!is_settled(oracle), EOracleExpired);

    let now = clock.timestamp_ms();

    oracle.svi = svi;
    oracle.risk_free_rate = risk_free_rate;

    event::emit(OracleSVIUpdated {
        oracle_id: oracle.id.to_inner(),
        a: svi.a,
        b: svi.b,
        rho: svi.rho,
        rho_negative: svi.rho_negative,
        m: svi.m,
        m_negative: svi.m_negative,
        sigma: svi.sigma,
        risk_free_rate,
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

/// Get the forward price for this expiry.
public fun forward_price(oracle: &OracleSVI): u64 {
    oracle.prices.forward
}

/// Get the price data.
public fun prices(oracle: &OracleSVI): PriceData {
    oracle.prices
}

/// Get the SVI parameters.
public fun svi(oracle: &OracleSVI): SVIParams {
    oracle.svi
}

/// Get the expiry timestamp.
public fun expiry(oracle: &OracleSVI): u64 {
    oracle.expiry
}

/// Get the minimum allowed strike.
public fun min_strike(oracle: &OracleSVI): u64 {
    oracle.min_strike
}

/// Get the maximum allowed strike.
public fun max_strike(oracle: &OracleSVI): u64 {
    oracle.max_strike
}

/// Get the oracle tick size.
public fun tick_size(oracle: &OracleSVI): u64 {
    oracle.tick_size
}

/// Get the risk-free rate.
public fun risk_free_rate(oracle: &OracleSVI): u64 {
    oracle.risk_free_rate
}

/// Get the last update timestamp.
public fun timestamp(oracle: &OracleSVI): u64 {
    oracle.timestamp
}

/// Get the settlement price (only valid after settlement).
public fun settlement_price(oracle: &OracleSVI): Option<u64> {
    oracle.settlement_price
}

/// Check if the oracle data is stale (> 30s since last update).
public fun is_stale(oracle: &OracleSVI, clock: &Clock): bool {
    let now = clock.timestamp_ms();
    now > oracle.timestamp + constants::staleness_threshold_ms!()
}

/// Check if the oracle has been settled.
public fun is_settled(oracle: &OracleSVI): bool {
    oracle.settlement_price.is_some()
}

/// Check if the oracle is active.
public fun is_active(oracle: &OracleSVI): bool {
    oracle.active
}

/// Create a new PriceData struct.
public fun new_price_data(spot: u64, forward: u64): PriceData {
    PriceData { spot, forward }
}

/// Create a new SVIParams struct.
public fun new_svi_params(
    a: u64,
    b: u64,
    rho: u64,
    rho_negative: bool,
    m: u64,
    m_negative: bool,
    sigma: u64,
): SVIParams {
    SVIParams { a, b, rho, rho_negative, m, m_negative, sigma }
}

public fun new_curve_point(strike: u64, up_price: u64, dn_price: u64): CurvePoint {
    CurvePoint { strike, up_price, dn_price }
}

public fun strike(point: &CurvePoint): u64 { point.strike }

public fun up_price(point: &CurvePoint): u64 { point.up_price }

public fun dn_price(point: &CurvePoint): u64 { point.dn_price }

// === Public-Package Functions ===

/// Register an additional cap as authorized to update an oracle.
public(package) fun register_cap(oracle: &mut OracleSVI, cap: &OracleCapSVI) {
    oracle.authorized_caps.insert(cap.id.to_inner());
}

/// Create a new OracleCap. Called by registry during setup.
public(package) fun create_oracle_cap(ctx: &mut TxContext): OracleCapSVI {
    OracleCapSVI { id: object::new(ctx) }
}

/// Create a new SVI Oracle for an underlying + expiry. Returns the oracle ID.
public(package) fun create_oracle(
    underlying_asset: String,
    expiry: u64,
    min_strike: u64,
    max_strike: u64,
    tick_size: u64,
    ctx: &mut TxContext,
): ID {
    assert_valid_strike_grid(min_strike, max_strike, tick_size);

    let oracle_uid = object::new(ctx);
    let oracle_id = oracle_uid.to_inner();

    let oracle = OracleSVI {
        id: oracle_uid,
        authorized_caps: vec_set::empty(),
        underlying_asset,
        expiry,
        min_strike,
        max_strike,
        tick_size,
        active: false,
        prices: PriceData { spot: 0, forward: 0 },
        svi: SVIParams {
            a: 0,
            b: 0,
            rho: 0,
            rho_negative: false,
            m: 0,
            m_negative: false,
            sigma: 0,
        },
        risk_free_rate: 0,
        timestamp: 0,
        settlement_price: option::none(),
    };

    transfer::share_object(oracle);
    oracle_id
}

/// Binary option price. If settled, returns deterministic 0/100%.
/// Otherwise uses SVI + Black-Scholes, discounted by e^(-r*t).
/// At-the-money (price == strike) settles as DOWN win.
/// Returns price in FLOAT_SCALING (1e9).
public(package) fun get_binary_price(
    oracle: &OracleSVI,
    strike: u64,
    is_up: bool,
    clock: &Clock,
): u64 {
    assert_valid_strike(oracle, strike);
    if (oracle.settlement_price.is_some()) {
        let settlement_price = oracle.settlement_price.destroy_some();
        let up_wins = settlement_price > strike;
        let won = if (is_up) { up_wins } else { !up_wins };
        return if (won) { constants::float_scaling!() } else { 0 }
    };

    let nd2 = compute_nd2(oracle, strike, is_up);
    let discount = compute_discount(oracle, clock);
    math::mul(discount, nd2)
}

/// Assert that the oracle is not stale. Aborts if stale.
public(package) fun assert_not_stale(oracle: &OracleSVI, clock: &Clock) {
    assert!(!is_stale(oracle, clock), EOracleStale);
}

/// Assert that a strike is inside this oracle's strike grid and aligned to tick size.
public(package) fun assert_valid_strike(oracle: &OracleSVI, strike: u64) {
    assert!(strike >= oracle.min_strike && strike <= oracle.max_strike, EStrikeOutOfRange);
    assert!(strike % oracle.tick_size == 0, EStrikeNotOnTick);
}

/// Build an adaptive piecewise-linear approximation of the pricing curve.
/// Concentrates sample points near ATM where the sigmoid is steepest.
/// For settled oracles, returns a step-function curve at the settlement price.
/// Returns a sorted vector of CurvePoints for use with treap.evaluate().
public(package) fun build_curve(
    oracle: &OracleSVI,
    min_strike: u64,
    max_strike: u64,
    clock: &Clock,
): vector<CurvePoint> {
    if (oracle.is_settled()) {
        let settlement = oracle.settlement_price().destroy_some();
        let full_price = constants::float_scaling!();
        return vector[
            new_curve_point(settlement - 1, full_price, 0),
            new_curve_point(settlement, 0, full_price),
        ]
    };

    let sample_limit = constants::default_curve_samples!();
    let discount = compute_discount(oracle, clock);

    // Single-strike edge case
    if (min_strike == max_strike) {
        return vector[oracle.eval_strike(min_strike, discount)]
    };

    // Seed with min, forward (if in range), max — deduplicating
    let forward = oracle.prices.forward;
    let mut points = vector[oracle.eval_strike(min_strike, discount)];
    let mut used = 1u64;

    if (forward > min_strike && forward < max_strike) {
        points.push_back(oracle.eval_strike(forward, discount));
        used = used + 1;
    };
    points.push_back(oracle.eval_strike(max_strike, discount));
    used = used + 1;

    // Adaptive refinement: pick interval with max error, bisect it
    while (used < sample_limit) {
        let len = points.length();
        let mut best_score = 0u64;
        let mut best_idx = 0u64;
        let mut i = 0;
        while (i < len - 1) {
            let interval = points[i + 1].strike() - points[i].strike();
            if (interval < constants::min_curve_interval!()) {
                i = i + 1;
                continue
            };

            let score = if (i > 0 && i < len - 2) {
                // Interior: second finite difference
                let sum_ends = points[i - 1].up_price() + points[i + 1].up_price();
                let twice_mid = 2 * points[i].up_price();
                math::mul(sum_ends.diff(twice_mid), interval)
            } else {
                // Edge: use slope magnitude
                math::mul(points[i].up_price().diff(points[i + 1].up_price()), interval)
            };

            if (score > best_score) {
                best_score = score;
                best_idx = i;
            };
            i = i + 1;
        };

        // No refineable interval found
        if (best_score == 0) break;

        let mid_strike = (points[best_idx].strike() + points[best_idx + 1].strike()) / 2;
        let new_point = oracle.eval_strike(mid_strike, discount);

        // Insert at sorted position (best_idx + 1)
        points.push_back(new_point); // append to end
        let mut j = points.length() - 1;
        while (j > best_idx + 1) {
            points.swap(j, j - 1);
            j = j - 1;
        };
        used = used + 1;
    };

    points
}

// === Private Functions ===

/// SVI + Black-Scholes N(d2) in a single pass.
///
/// SVI gives total_variance directly, so IV and time cancel in d2:
///   iv = sqrt(total_var / t), iv * sqrt(t) = sqrt(total_var)
///   d2 = (ln(F/K) - total_var/2) / sqrt(total_var)
fun compute_nd2(oracle: &OracleSVI, strike: u64, is_up: bool): u64 {
    let forward = oracle.prices.forward;
    assert!(forward > 0, EZeroForward);

    // SVI: compute total variance from log-moneyness
    let (k, k_neg) = predict_math::ln(math::div(strike, forward));
    let (k_minus_m, km_neg) = predict_math::sub_signed_u64(
        k,
        k_neg,
        oracle.svi.m,
        oracle.svi.m_negative,
    );
    let sq = predict_math::sqrt(
        math::mul(k_minus_m, k_minus_m) + math::mul(oracle.svi.sigma, oracle.svi.sigma),
        constants::float_scaling!(),
    );
    let (rho_km, rho_km_neg) = predict_math::mul_signed_u64(
        oracle.svi.rho,
        oracle.svi.rho_negative,
        k_minus_m,
        km_neg,
    );
    let (inner, inner_neg) = predict_math::add_signed_u64(rho_km, rho_km_neg, sq, false);
    assert!(!inner_neg, ECannotBeNegative);
    let total_var = oracle.svi.a + math::mul(oracle.svi.b, inner);
    assert!(total_var > 0, EZeroVariance);

    // d2 = (-k - total_var/2) / sqrt(total_var), then N(±d2)
    let sqrt_var = predict_math::sqrt(total_var, constants::float_scaling!());
    let (d2, d2_neg) = predict_math::sub_signed_u64(k, !k_neg, total_var / 2, false);
    let d2 = math::div(d2, sqrt_var);
    let cdf_neg = if (is_up) { d2_neg } else { !d2_neg };

    predict_math::normal_cdf(d2, cdf_neg)
}

/// Compute discount factor e^(-r * t).
/// Past expiry returns 1.0 (no discounting) to handle the window between
/// expiry and settlement.
fun compute_discount(oracle: &OracleSVI, clock: &Clock): u64 {
    let now = clock.timestamp_ms();
    if (now >= oracle.expiry) return constants::float_scaling!();
    let tte_ms = oracle.expiry - now;
    let t = math::div(tte_ms, constants::ms_per_year!());
    let rt = math::mul(oracle.risk_free_rate, t);
    predict_math::exp(rt, true)
}

/// Evaluate one strike, returning a CurvePoint with both UP and DOWN prices.
/// Uses the complement property: dn = discount - up, costing only 1 compute_nd2 call.
fun eval_strike(oracle: &OracleSVI, strike: u64, discount: u64): CurvePoint {
    let nd2 = compute_nd2(oracle, strike, true);
    let up = math::mul(discount, nd2);
    let dn = if (discount > up) { discount - up } else { 0 };
    new_curve_point(strike, up, dn)
}

fun assert_authorized_cap(oracle: &OracleSVI, cap: &OracleCapSVI) {
    assert!(oracle.authorized_caps.contains(&cap.id.to_inner()), EInvalidOracleCap);
}

fun assert_valid_strike_grid(min_strike: u64, max_strike: u64, tick_size: u64) {
    assert!(tick_size > 0, EInvalidTickSize);
    assert!(tick_size % 10_000 == 0, EInvalidTickSize);
    assert!(min_strike % tick_size == 0, EInvalidStrikeGrid);
    assert!(max_strike % tick_size == 0, EInvalidStrikeGrid);
    assert!(max_strike > min_strike, EInvalidStrikeGrid);
    assert!(max_strike - min_strike == tick_size * 100_000, EInvalidStrikeGrid);
}

fun assert_price_in_range(oracle: &OracleSVI, price: u64) {
    assert!(price >= oracle.min_strike && price <= oracle.max_strike, EPriceOutOfRange);
}

#[test_only]
/// Create a test oracle with given params. Bypasses cap/share requirements.
public(package) fun create_test_oracle(
    underlying_asset: String,
    svi: SVIParams,
    prices: PriceData,
    risk_free_rate: u64,
    expiry: u64,
    timestamp: u64,
    ctx: &mut TxContext,
): OracleSVI {
    OracleSVI {
        id: object::new(ctx),
        authorized_caps: vec_set::empty(),
        underlying_asset,
        expiry,
        min_strike: 0,
        max_strike: TEST_MAX_STRIKE,
        tick_size: 1,
        active: true,
        prices,
        svi,
        risk_free_rate,
        timestamp,
        settlement_price: option::none(),
    }
}

#[test_only]
/// Create a test oracle with an explicit strike grid. Mirrors production validation.
public(package) fun create_test_oracle_with_grid(
    underlying_asset: String,
    svi: SVIParams,
    prices: PriceData,
    risk_free_rate: u64,
    expiry: u64,
    timestamp: u64,
    min_strike: u64,
    max_strike: u64,
    tick_size: u64,
    ctx: &mut TxContext,
): OracleSVI {
    assert_valid_strike_grid(min_strike, max_strike, tick_size);
    assert!(prices.spot >= min_strike && prices.spot <= max_strike, EPriceOutOfRange);
    assert!(prices.forward >= min_strike && prices.forward <= max_strike, EPriceOutOfRange);
    OracleSVI {
        id: object::new(ctx),
        authorized_caps: vec_set::empty(),
        underlying_asset,
        expiry,
        min_strike,
        max_strike,
        tick_size,
        active: true,
        prices,
        svi,
        risk_free_rate,
        timestamp,
        settlement_price: option::none(),
    }
}

#[test_only]
/// Set oracle active state for testing.
public(package) fun set_active_for_testing(oracle: &mut OracleSVI, active: bool) {
    oracle.active = active;
}

#[test_only]
/// Force-settle the oracle at a given price for testing.
public(package) fun settle_test_oracle(oracle: &mut OracleSVI, price: u64) {
    oracle.settlement_price = option::some(price);
    oracle.active = false;
}
