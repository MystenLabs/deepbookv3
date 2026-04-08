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
use deepbook_predict::{constants::Self, i64, math as predict_math};
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
    rho: i64::I64,
    m: i64::I64,
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
    /// Signed skew parameter (typically negative - puts more expensive)
    rho: i64::I64,
    /// Signed horizontal shift parameter
    m: i64::I64,
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
    /// IDs of oracle caps authorized to update this oracle
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

/// Capability for Block Scholes operator to create and update SVI oracles.
public struct OracleSVICap has key, store {
    id: UID,
}

// === Public Functions ===

/// Activate the oracle. Must be called before oracle can be used for pricing.
public fun activate(oracle: &mut OracleSVI, cap: &OracleSVICap, clock: &Clock) {
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

// TODO: Add validation on pushed spot/forward data so obviously bad oracle
// updates are rejected before they mutate state.
/// Push spot and forward prices (high frequency ~1s).
/// If past expiry and not yet settled, freezes settlement price and deactivates.
public fun update_prices(
    oracle: &mut OracleSVI,
    cap: &OracleSVICap,
    prices: PriceData,
    clock: &Clock,
) {
    assert_authorized_cap(oracle, cap);

    let now = clock.timestamp_ms();
    let oracle_id = oracle.id.to_inner();

    // If past expiry and not yet settled, freeze settlement price and deactivate.
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

// TODO: Add validation on pushed SVI params and risk-free rate so obviously
// bad updates are rejected before they mutate state.
/// Push SVI parameters and risk-free rate (low frequency ~10-20s).
public fun update_svi(
    oracle: &mut OracleSVI,
    cap: &OracleSVICap,
    svi: SVIParams,
    risk_free_rate: u64,
    clock: &Clock,
) {
    assert_authorized_cap(oracle, cap);
    assert!(!is_settled(oracle), EOracleSettled);

    let now = clock.timestamp_ms();

    oracle.svi = svi;
    oracle.risk_free_rate = risk_free_rate;

    event::emit(OracleSVIUpdated {
        oracle_id: oracle.id.to_inner(),
        a: svi.a,
        b: svi.b,
        rho: svi.rho,
        m: svi.m,
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
public fun new_svi_params(a: u64, b: u64, rho: i64::I64, m: i64::I64, sigma: u64): SVIParams {
    SVIParams { a, b, rho, m, sigma }
}

// === Public-Package Functions ===

/// Compute the conditional UP share within one binary pair.
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

/// Register an additional cap as authorized to update an oracle.
public(package) fun register_cap(oracle: &mut OracleSVI, cap: &OracleSVICap) {
    oracle.authorized_caps.insert(cap.id.to_inner());
}

/// Create a new OracleCap. Called by registry during setup.
public(package) fun create_oracle_cap(ctx: &mut TxContext): OracleSVICap {
    OracleSVICap { id: object::new(ctx) }
}

/// Create a new SVI Oracle for an underlying + expiry. Returns the oracle ID.
public(package) fun create_oracle(underlying_asset: String, expiry: u64, ctx: &mut TxContext): ID {
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
            rho: i64::zero(),
            m: i64::zero(),
            sigma: 0,
        },
        risk_free_rate: 0,
        timestamp: 0,
        settlement_price: option::none(),
    };

    transfer::share_object(oracle);
    oracle_id
}

// === Private Functions ===

fun assert_authorized_cap(oracle: &OracleSVI, cap: &OracleSVICap) {
    assert!(oracle.authorized_caps.contains(&cap.id.to_inner()), EInvalidOracleCap);
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
    let k_minus_m = i64::sub(k, svi.m);
    let k_minus_m_squared = i64::square_scaled(k_minus_m);
    let sigma_squared = math::mul(svi.sigma, svi.sigma);
    let sq = predict_math::sqrt(k_minus_m_squared + sigma_squared, constants::float_scaling!());
    let sq_i64 = i64::from_u64(sq);

    let rho_km = i64::mul_scaled(svi.rho, k_minus_m);
    let inner = i64::add(rho_km, sq_i64);
    assert!(!i64::is_negative(inner), ECannotBeNegative);
    let total_var = svi.a + math::mul(svi.b, i64::magnitude(inner));
    assert!(total_var > 0, EZeroVariance);

    // d2 = -((k + total_var/2) / sqrt(total_var)), then N(±d2).
    let sqrt_var = predict_math::sqrt(total_var, constants::float_scaling!());
    let sqrt_var_i64 = i64::from_u64(sqrt_var);
    let half_var_i64 = i64::from_u64(total_var / 2);
    let d2_numerator = i64::add(k, half_var_i64);
    let d2 = i64::div_scaled(d2_numerator, sqrt_var_i64);
    let d2 = i64::neg(d2);

    predict_math::normal_cdf(d2)
}
