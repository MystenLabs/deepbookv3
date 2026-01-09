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

use deepbook_predict::{constants, oracle::Oracle, position_key::PositionKey};
use sui::clock::Clock;

// === Structs ===

/// Pricing configuration stored in the Predict object.
public struct Pricing has store {
    /// Base spread in basis points (e.g., 100 = 1%)
    base_spread_bps: u64,
}

// === Public Functions ===

/// Get bid and ask prices for a market.
/// Returns (bid, ask) in PRICE_SCALING (1e6).
public fun get_quote<Underlying>(
    pricing: &Pricing,
    oracle: &Oracle<Underlying>,
    key: &PositionKey,
    clock: &Clock,
): (u64, u64) {
    let strike = key.strike();
    let is_up = key.is_up();
    let (spot, iv, rfr, tte) = oracle.get_pricing_data(strike, clock);

    let theoretical = calculate_binary_price(spot, strike, iv, rfr, tte, is_up);

    let spread = (theoretical * pricing.base_spread_bps) / constants::bps_scaling();
    let bid = if (theoretical > spread) { theoretical - spread } else { 0 };
    let ask = theoretical + spread;

    (bid, ask)
}

/// Calculate the cost to buy a position.
/// Takes vault's current short positions for dynamic spread calculation.
/// Returns cost in Quote units (e.g., USDC with 6 decimals).
public fun get_mint_cost<Underlying>(
    _pricing: &Pricing,
    _oracle: &Oracle<Underlying>,
    _key: &PositionKey,
    quantity: u64,
    _up_short: u64,
    _down_short: u64,
    _clock: &Clock,
): u64 {
    // TODO: Calculate cost based on:
    // 1. Get theoretical price from Black-Scholes
    // 2. Calculate net exposure = up_short - down_short
    // 3. Apply dynamic spread based on net exposure
    // 4. Return ask * quantity

    // Placeholder: 50 cents per contract
    500_000 * quantity
}

/// Calculate the payout for redeeming a position.
/// If oracle is settled, returns settlement value ($1 if won, $0 if lost).
/// If not settled, returns bid price * quantity.
/// Takes vault's current short positions for dynamic spread calculation.
/// Returns payout in Quote units (e.g., USDC with 6 decimals).
public fun get_redeem_payout<Underlying>(
    _pricing: &Pricing,
    oracle: &Oracle<Underlying>,
    key: &PositionKey,
    quantity: u64,
    _up_short: u64,
    _down_short: u64,
    _clock: &Clock,
): u64 {
    let strike = key.strike();
    let is_up = key.is_up();

    if (oracle.is_settled()) {
        let settlement_price = oracle.settlement_price().destroy_some();
        let won = if (is_up) {
            settlement_price > strike
        } else {
            settlement_price <= strike
        };
        // $1 per contract if won, $0 if lost
        if (won) { constants::price_scaling() * quantity } else { 0 }
    } else {
        // TODO: Calculate payout based on:
        // 1. Get theoretical price from Black-Scholes
        // 2. Calculate net exposure = up_short - down_short
        // 3. Apply dynamic spread based on net exposure
        // 4. Return bid * quantity

        // Placeholder: 40 cents per contract (bid = theoretical - spread)
        400_000 * quantity
    }
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
