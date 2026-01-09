// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Pricing module - calculates binary option prices.
///
/// Key responsibilities:
/// - Black-Scholes pricing for binary options
/// - Interpolate implied volatility from oracle's volatility surface
/// - Apply dynamic spread based on vault inventory/exposure
///
/// Binary option pricing formula:
///   Binary Call (UP) = e^(-rT) * N(d2)
///   Binary Put (DOWN) = e^(-rT) * N(-d2)
///
///   where:
///   d2 = [ln(S/K) + (r - 0.5*σ²)*T] / (σ*√T)
///   S = spot price (from oracle)
///   K = strike price
///   r = risk-free rate (from oracle)
///   σ = implied volatility (interpolated from oracle surface)
///   T = time to expiry
///   N() = cumulative normal distribution
///
/// Dynamic spread adjustment:
///   exposure_ratio = net_exposure / max_exposure  (-1 to +1)
///   adjustment = exposure_ratio * max_spread_adjustment
///
///   If vault is long UP (positive exposure):
///   - UP becomes more expensive to buy (higher ask)
///   - DOWN becomes cheaper to buy (incentivized)
///
/// This encourages balanced order flow and reduces vault risk.
module deepbook_predict::pricing;

use deepbook_predict::{constants, oracle::Oracle};
use sui::clock::Clock;

// === Structs ===

/// Pricing configuration stored in the Predict object.
public struct Pricing has store {
    /// Base spread in basis points (e.g., 100 = 1%)
    base_spread_bps: u64,
}

// === Public Functions ===

/// Get bid and ask prices for a market.
/// Underlying is the oracle's asset (BTC, ETH).
/// Returns (bid, ask) in PRICE_SCALING (1e6).
public fun get_quote<Underlying>(
    pricing: &Pricing,
    oracle: &Oracle<Underlying>,
    strike: u64,
    is_up: bool,
    clock: &Clock,
): (u64, u64) {
    let (spot, iv, rfr, tte) = oracle.get_pricing_data(strike, clock);

    let theoretical = calculate_binary_price(spot, strike, iv, rfr, tte, is_up);

    let spread = (theoretical * pricing.base_spread_bps) / constants::bps_scaling();
    let bid = if (theoretical > spread) { theoretical - spread } else { 0 };
    let ask = theoretical + spread;

    (bid, ask)
}

// === Public-Package Functions ===

/// Create a new Pricing config with default values.
public(package) fun new(): Pricing {
    Pricing {
        base_spread_bps: constants::default_base_spread_bps(),
    }
}

// === Private Functions ===

/// Calculate theoretical binary option price.
/// Returns price in PRICE_SCALING (1e6), where 1_000_000 = $1.
fun calculate_binary_price(
    _spot: u64,
    _strike: u64,
    _iv: u64,
    _rfr: u64,
    _tte_ms: u64,
    _is_up: bool,
): u64 {
    // TODO: Implement Black-Scholes for binary options
    // For now, return 50 cents as placeholder
    500_000
}
