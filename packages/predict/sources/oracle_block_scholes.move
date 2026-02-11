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
module deepbook_predict::oracle_block_scholes;

use deepbook::math as deepbook_math;
use deepbook_predict::{constants, math};
use sui::clock::Clock;

// === Errors ===

const EInvalidOracleCap: u64 = 0;
const EOracleStale: u64 = 1;
const EOracleNotActive: u64 = 2;
const EOracleAlreadyActive: u64 = 3;
const EOracleExpired: u64 = 4;
const ECannotBeNegative: u64 = 5;

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
public struct OracleSVI<phantom Underlying> has key {
    id: UID,
    /// ID of the OracleCap authorized to update this oracle
    oracle_cap_id: ID,
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

// === Public Functions (Block Scholes operator calls) ===

/// Activate the oracle. Must be called before oracle can be used for pricing.
public fun activate<Underlying>(
    oracle: &mut OracleSVI<Underlying>,
    cap: &OracleCapSVI,
    clock: &Clock,
) {
    assert!(oracle.oracle_cap_id == cap.id.to_inner(), EInvalidOracleCap);
    assert!(!oracle.active, EOracleAlreadyActive);
    assert!(clock.timestamp_ms() < oracle.expiry, EOracleExpired);

    oracle.active = true;
}

/// Push spot and forward prices (high frequency ~1s).
/// If past expiry and not settled, freezes settlement price and deactivates.
public fun update_prices<Underlying>(
    oracle: &mut OracleSVI<Underlying>,
    cap: &OracleCapSVI,
    prices: PriceData,
    clock: &Clock,
) {
    assert!(oracle.oracle_cap_id == cap.id.to_inner(), EInvalidOracleCap);

    let now = clock.timestamp_ms();

    // If past expiry and not yet settled, freeze settlement price and deactivate
    if (now > oracle.expiry && oracle.settlement_price.is_none()) {
        oracle.settlement_price = option::some(prices.spot);
        oracle.active = false;
    };

    oracle.prices = prices;
    oracle.timestamp = now;
}

/// Push SVI parameters and risk-free rate (low frequency ~10-20s).
public fun update_svi<Underlying>(
    oracle: &mut OracleSVI<Underlying>,
    cap: &OracleCapSVI,
    svi: SVIParams,
    risk_free_rate: u64,
    clock: &Clock,
) {
    assert!(oracle.oracle_cap_id == cap.id.to_inner(), EInvalidOracleCap);

    oracle.svi = svi;
    oracle.risk_free_rate = risk_free_rate;
    oracle.timestamp = clock.timestamp_ms();
}

// === Public View Functions (getters) ===

/// Get the oracle ID.
public fun id<Underlying>(oracle: &OracleSVI<Underlying>): ID {
    oracle.id.to_inner()
}

/// Get the current spot price.
public fun spot_price<Underlying>(oracle: &OracleSVI<Underlying>): u64 {
    oracle.prices.spot
}

/// Get the forward price for this expiry.
public fun forward_price<Underlying>(oracle: &OracleSVI<Underlying>): u64 {
    oracle.prices.forward
}

/// Get the price data.
public fun prices<Underlying>(oracle: &OracleSVI<Underlying>): PriceData {
    oracle.prices
}

/// Get the SVI parameters.
public fun svi<Underlying>(oracle: &OracleSVI<Underlying>): SVIParams {
    oracle.svi
}

/// Get the expiry timestamp.
public fun expiry<Underlying>(oracle: &OracleSVI<Underlying>): u64 {
    oracle.expiry
}

/// Get the risk-free rate.
public fun risk_free_rate<Underlying>(oracle: &OracleSVI<Underlying>): u64 {
    oracle.risk_free_rate
}

/// Get the last update timestamp.
public fun timestamp<Underlying>(oracle: &OracleSVI<Underlying>): u64 {
    oracle.timestamp
}

/// Get the settlement price (only valid after settlement).
public fun settlement_price<Underlying>(oracle: &OracleSVI<Underlying>): Option<u64> {
    oracle.settlement_price
}

/// Check if the oracle data is stale (> 30s since last update).
public fun is_stale<Underlying>(oracle: &OracleSVI<Underlying>, clock: &Clock): bool {
    let now = clock.timestamp_ms();
    now > oracle.timestamp + 30_000
}

/// Check if the oracle has been settled.
public fun is_settled<Underlying>(oracle: &OracleSVI<Underlying>): bool {
    oracle.settlement_price.is_some()
}

/// Check if the oracle is active.
public fun is_active<Underlying>(oracle: &OracleSVI<Underlying>): bool {
    oracle.active
}

// === Public-Package Functions ===

/// Create a new OracleCap. Called by registry during setup.
public(package) fun create_oracle_cap(ctx: &mut TxContext): OracleCapSVI {
    OracleCapSVI { id: object::new(ctx) }
}

/// Create a new SVI Oracle for an underlying + expiry. Returns the oracle ID.
public(package) fun create_oracle<Underlying>(
    cap: &OracleCapSVI,
    expiry: u64,
    ctx: &mut TxContext,
): ID {
    let oracle_uid = object::new(ctx);
    let oracle_id = oracle_uid.to_inner();

    let oracle = OracleSVI<Underlying> {
        id: oracle_uid,
        oracle_cap_id: cap.id.to_inner(),
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

/// Compute implied volatility for a given strike using SVI formula.
///
/// SVI formula:
///   k = ln(strike / forward)
///   total_var = a + b * (rho * (k - m) + sqrt((k - m)² + sigma²))
///   iv = sqrt(total_var / time_to_expiry)
///
/// Requires: ln() and sqrt() math utilities
public(package) fun compute_iv<Underlying>(
    oracle: &OracleSVI<Underlying>,
    strike: u64,
    clock: &Clock,
): u64 {
    let ratio = deepbook::math::div(strike, oracle.prices.forward);
    let (k, k_negative) = math::ln(ratio);
    let (k_minus_m, k_minus_m_negative) = math::sub_signed_u64(
        k,
        k_negative,
        oracle.svi.m,
        oracle.svi.m_negative,
    );
    let sq = deepbook_math::sqrt(
        deepbook_math::mul(k_minus_m, k_minus_m) + deepbook_math::mul(oracle.svi.sigma, oracle.svi.sigma),
        1_000_000_000,
    );
    let rho_k_minus_m = deepbook_math::mul(oracle.svi.rho, k_minus_m);
    let (inner, inner_negative) = math::add_signed_u64(
        rho_k_minus_m,
        k_minus_m_negative,
        sq,
        false,
    );
    assert!(!inner_negative, ECannotBeNegative); // SVI formula should not produce negative variance
    let total_var = oracle.svi.a + deepbook_math::mul(oracle.svi.b, inner);
    let iv = deepbook_math::sqrt(
        deepbook_math::div(
            total_var,
            deepbook_math::div(oracle.expiry - clock.timestamp_ms(), 1000 * 60 * 60 * 24),
        ),
        1_000_000_000,
    );

    iv
}

/// Get all pricing data in one call for efficiency.
/// Returns (forward_price, implied_vol, risk_free_rate, time_to_expiry_ms).
/// Computes IV on-demand using SVI formula.
public(package) fun get_pricing_data<Underlying>(
    oracle: &OracleSVI<Underlying>,
    strike: u64,
    clock: &Clock,
): (u64, u64, u64, u64) {
    let iv = compute_iv(oracle, strike, clock);
    let tte_ms = oracle.expiry - clock.timestamp_ms();
    (oracle.prices.forward, iv, oracle.risk_free_rate, tte_ms)
}

/// Calculate binary option price for a given strike and direction.
/// Uses Black-Scholes: Binary Call = e^(-rT) * N(d2), Binary Put = e^(-rT) * N(-d2)
/// Returns price in FLOAT_SCALING (1e9), where 1_000_000_000 = 100%.
public(package) fun get_binary_price<Underlying>(
    oracle: &OracleSVI<Underlying>,
    strike: u64,
    is_up: bool,
    clock: &Clock,
): u64 {
    let (forward, iv, rfr, tte_ms) = get_pricing_data(oracle, strike, clock);
    let t = deepbook_math::div(tte_ms, constants::ms_per_year());
    let (ln_fk, ln_fk_neg) = math::ln(deepbook_math::div(forward, strike));
    let half_vol_sq_t = deepbook_math::mul(deepbook_math::mul(iv, iv), t) / 2;
    let (d2_num, d2_num_neg) = math::sub_signed_u64(
        ln_fk,
        ln_fk_neg,
        half_vol_sq_t,
        false,
    );
    let sqrt_t = deepbook_math::sqrt(t, constants::float_scaling());
    let d2_den = deepbook_math::mul(iv, sqrt_t);
    let d2 = deepbook_math::div(d2_num, d2_den);
    let cdf_neg = if (is_up) { d2_num_neg } else { !d2_num_neg };
    let nd2 = math::normal_cdf(d2, cdf_neg);
    let rt = deepbook_math::mul(rfr, t);
    let discount = math::exp(rt, true);

    deepbook_math::mul(discount, nd2)
}

/// Assert that the oracle is not stale. Aborts if stale.
public(package) fun assert_not_stale<Underlying>(oracle: &OracleSVI<Underlying>, clock: &Clock) {
    assert!(!is_stale(oracle, clock), EOracleStale);
}

/// Assert that the oracle is active. Aborts if not active.
public(package) fun assert_active<Underlying>(oracle: &OracleSVI<Underlying>) {
    assert!(oracle.active, EOracleNotActive);
}

// === Helper Functions for Creating Structs ===

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
