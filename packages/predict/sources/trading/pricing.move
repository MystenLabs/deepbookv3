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



// === Imports ===

// === Errors ===

// === Public-Package Functions ===

// === Private Functions ===
