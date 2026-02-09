// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Pricing module - calculates binary option prices.
///
/// Scaling conventions (aligned with DeepBook):
/// - Prices are in FLOAT_SCALING (1e9): 500_000_000 = 50 cents
/// - Quantities are in Quote units (USDC): 1_000_000 = 1 contract = $1
/// - cost = math::mul(price, quantity) returns Quote units
/// - At settlement, winners receive `quantity` directly
///
/// Binary option pricing formula:
///   Binary Call (UP) = e^(-rT) * N(d2)
///   Binary Put (DOWN) = e^(-rT) * N(-d2)
///
///   where:
///   d2 = [ln(S/K) + (r - 0.5*σ²)*T] / (σ*√T)
///   S = spot price, K = strike, r = risk-free rate
///   σ = implied volatility, T = time to expiry, N() = CDF
///
/// Dynamic spread adjustment:
///   spread = math::mul(theoretical, base_spread)
///   If vault has imbalanced exposure, adjust spread to incentivize balance.
module deepbook_predict::pricing;

use deepbook::math;
use deepbook_predict::{constants, market_key::MarketKey, oracle_block_scholes::OracleSVI};
use sui::clock::Clock;

// === Structs ===

/// Pricing configuration stored in the Vault.
public struct Pricing has store {
    /// Base spread in FLOAT_SCALING (e.g., 10_000_000 = 1%)
    base_spread: u64,
}

// === Public Functions ===

/// Get bid and ask prices for a market.
/// If oracle is settled, returns settlement prices (100% for winner, 0% for loser).
/// Returns (bid, ask) in FLOAT_SCALING (1e9).
public fun get_quote<Underlying>(
    pricing: &Pricing,
    oracle: &OracleSVI<Underlying>,
    key: MarketKey,
    _up_short: u64,
    _down_short: u64,
    clock: &Clock,
): (u64, u64) {
    let strike = key.strike();
    let is_up = key.is_up();

    // After settlement, return definitive prices
    if (oracle.is_settled()) {
        let settlement_price = oracle.settlement_price().destroy_some();
        let up_wins = settlement_price > strike;
        let won = if (is_up) { up_wins } else { !up_wins };
        // Winner: 100%, Loser: 0%
        let price = if (won) { constants::float_scaling() } else { 0 };
        return (price, price)
    };

    let (spot, iv, rfr, tte) = oracle.get_pricing_data(strike, clock);
    let theoretical = calculate_binary_price(spot, strike, iv, rfr, tte, is_up);

    // TODO: Apply dynamic spread based on net exposure
    let spread = math::mul(theoretical, pricing.base_spread);
    let bid = if (theoretical > spread) { theoretical - spread } else { 0 };
    let ask = theoretical + spread;

    (bid, ask)
}

/// Calculate the cost to mint (buy) a position.
/// Returns cost in Quote units (USDC).
public fun get_mint_cost<Underlying>(
    pricing: &Pricing,
    oracle: &OracleSVI<Underlying>,
    key: MarketKey,
    quantity: u64,
    up_short: u64,
    down_short: u64,
    clock: &Clock,
): u64 {
    let (_bid, ask) = get_quote(pricing, oracle, key, up_short, down_short, clock);
    // cost = ask_price * quantity / FLOAT_SCALING
    math::mul(ask, quantity)
}

/// Calculate the payout for redeeming (selling) a position.
/// Returns payout in Quote units (USDC).
/// After settlement, get_quote returns 100%/0% so this returns quantity or 0.
public fun get_redeem_payout<Underlying>(
    pricing: &Pricing,
    oracle: &OracleSVI<Underlying>,
    key: MarketKey,
    quantity: u64,
    up_short: u64,
    down_short: u64,
    clock: &Clock,
): u64 {
    let (bid, _ask) = get_quote(pricing, oracle, key, up_short, down_short, clock);
    math::mul(bid, quantity)
}

// === Public-Package Functions ===

/// Create a new Pricing config with default values.
public(package) fun new(): Pricing {
    Pricing { base_spread: constants::default_base_spread() }
}

// === Private Functions ===

/// Calculate theoretical binary option price.
/// Returns price in FLOAT_SCALING (1e9), where 1_000_000_000 = $1 = 100%.
fun calculate_binary_price(
    _spot: u64,
    _strike: u64,
    _iv: u64,
    _rfr: u64,
    _tte_ms: u64,
    _is_up: bool,
): u64 {
    // TODO: Implement Black-Scholes for binary options
    // For now, return 50% as placeholder (500_000_000 in FLOAT_SCALING)
    500_000_000
}
