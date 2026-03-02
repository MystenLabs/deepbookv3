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

    let now = clock.timestamp_ms();

    oracle.svi = svi;
    oracle.risk_free_rate = risk_free_rate;
    oracle.timestamp = now;

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
    ctx: &mut TxContext,
): ID {
    let oracle_uid = object::new(ctx);
    let oracle_id = oracle_uid.to_inner();

    let oracle = OracleSVI {
        id: oracle_uid,
        authorized_caps: vec_set::empty(),
        underlying_asset,
        expiry,
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

/// Binary option price using SVI + Black-Scholes, discounted by e^(-r*t).
/// Returns price in FLOAT_SCALING (1e9).
public(package) fun get_binary_price(
    oracle: &OracleSVI,
    strike: u64,
    is_up: bool,
    clock: &Clock,
): u64 {
    let nd2 = compute_nd2(oracle, strike, is_up);

    // Discount: e^(-r * t), time only needed here
    let tte_ms = oracle.expiry - clock.timestamp_ms();
    let t = math::div(tte_ms, constants::ms_per_year!());
    let rt = math::mul(oracle.risk_free_rate, t);
    let discount = predict_math::exp(rt, true);

    math::mul(discount, nd2)
}

/// Binary option price without discount factor (assumes r ≈ 0).
/// No clock needed — time cancels entirely from the formula.
/// Returns price in FLOAT_SCALING (1e9).
public(package) fun get_binary_price_undiscounted(
    oracle: &OracleSVI,
    strike: u64,
    is_up: bool,
): u64 {
    compute_nd2(oracle, strike, is_up)
}

/// Assert that the oracle is not stale. Aborts if stale.
public(package) fun assert_not_stale(oracle: &OracleSVI, clock: &Clock) {
    assert!(!is_stale(oracle, clock), EOracleStale);
}

// === Private Functions ===

/// SVI + Black-Scholes N(d2) in a single pass.
///
/// SVI gives total_variance directly, so IV and time cancel in d2:
///   iv = sqrt(total_var / t), iv * sqrt(t) = sqrt(total_var)
///   d2 = (ln(F/K) - total_var/2) / sqrt(total_var)
fun compute_nd2(oracle: &OracleSVI, strike: u64, is_up: bool): u64 {
    let forward = oracle.prices.forward;

    // SVI: compute total variance from log-moneyness
    let (k, k_neg) = predict_math::ln(math::div(strike, forward));
    let (k_minus_m, km_neg) = predict_math::sub_signed_u64(
        k,
        k_neg,
        oracle.svi.m,
        oracle.svi.m_negative,
    );
    let sq = math::sqrt(
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

    // d2 = (-k - total_var/2) / sqrt(total_var), then N(±d2)
    let sqrt_var = math::sqrt(total_var, constants::float_scaling!());
    let (d2, d2_neg) = predict_math::sub_signed_u64(k, !k_neg, total_var / 2, false);
    let d2 = math::div(d2, sqrt_var);
    let cdf_neg = if (is_up) { d2_neg } else { !d2_neg };

    predict_math::normal_cdf(d2, cdf_neg)
}

fun assert_authorized_cap(oracle: &OracleSVI, cap: &OracleCapSVI) {
    assert!(oracle.authorized_caps.contains(&cap.id.to_inner()), EInvalidOracleCap);
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
        active: true,
        prices,
        svi,
        risk_free_rate,
        timestamp,
        settlement_price: option::none(),
    }
}

#[test_only]
/// Force-settle the oracle at a given price for testing.
public(package) fun settle_test_oracle(oracle: &mut OracleSVI, price: u64) {
    oracle.settlement_price = option::some(price);
    oracle.active = false;
}
