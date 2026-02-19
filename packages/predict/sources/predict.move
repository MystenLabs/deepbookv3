// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Main entry point for the DeepBook Predict protocol.
///
/// This module orchestrates all operations:
/// - Coordinates between Vault (state), Oracle (data), and config
/// - Exposes public functions for trading
/// - Handles pricing (spread calculation)
module deepbook_predict::predict;

use deepbook::math;
use deepbook_predict::{
    constants,
    market_key::MarketKey,
    oracle::OracleSVI,
    predict_manager::{Self, PredictManager},
    pricing_config::{Self, PricingConfig},
    risk_config::{Self, RiskConfig},
    vault::{Self, Vault}
};
use sui::{clock::Clock, coin::Coin};

// === Errors ===
const ETradingPaused: u64 = 0;
const EInvalidCollateralPair: u64 = 1;

// === Structs ===

/// Main shared object for the DeepBook Predict protocol.
/// Quote is the collateral asset (e.g., USDC).
public struct Predict<phantom Quote> has key {
    id: UID,
    /// Vault holding USDC and tracking exposure
    vault: Vault<Quote>,
    /// Pricing configuration (admin-controlled)
    pricing_config: PricingConfig,
    /// Risk limits (admin-controlled)
    risk_config: RiskConfig,
    /// Whether trading (mint) is globally paused
    trading_paused: bool,
}

// === Public Functions ===

/// Create a new PredictManager for the caller.
public fun create_manager(ctx: &mut TxContext): ID {
    predict_manager::new(ctx)
}

/// Get the amounts for mint/redeem (for UI/preview).
/// Returns (mint_cost, redeem_payout).
public fun get_trade_amounts<Underlying, Quote>(
    predict: &Predict<Quote>,
    oracle: &OracleSVI<Underlying>,
    key: MarketKey,
    quantity: u64,
    clock: &Clock,
): (u64, u64) {
    let (bid, ask) = predict.get_quote(oracle, key, clock);
    (math::mul(ask, quantity), math::mul(bid, quantity))
}

/// Buy a position. Cost is withdrawn from the PredictManager's balance.
/// Position quantity is added to the PredictManager's positions.
public fun mint<Underlying, Quote>(
    predict: &mut Predict<Quote>,
    manager: &mut PredictManager,
    oracle: &OracleSVI<Underlying>,
    key: MarketKey,
    quantity: u64,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    assert!(!predict.trading_paused, ETradingPaused);
    key.assert_matches_oracle(oracle);
    oracle.assert_not_stale(clock);

    let (cost, _payout) = predict.get_trade_amounts(oracle, key, quantity, clock);
    let payment = manager.withdraw<Quote>(cost, ctx);
    predict.vault.execute_mint(oracle.id(), key.is_up(), quantity, payment);
    predict.vault.assert_total_exposure(predict.risk_config.max_total_exposure_pct());
    manager.increase_position(key, quantity);
}

/// Sell a position. Payout is deposited into the PredictManager's balance.
/// Position quantity is removed from the PredictManager's positions.
public fun redeem<Underlying, Quote>(
    predict: &mut Predict<Quote>,
    manager: &mut PredictManager,
    oracle: &OracleSVI<Underlying>,
    key: MarketKey,
    quantity: u64,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    key.assert_matches_oracle(oracle);
    if (!oracle.is_settled()) {
        oracle.assert_not_stale(clock);
    };

    manager.decrease_position(key, quantity);

    let (_cost, payout) = predict.get_trade_amounts(oracle, key, quantity, clock);
    let payout_balance = predict.vault.execute_redeem(oracle.id(), key.is_up(), quantity, payout);

    let payout_coin = payout_balance.into_coin(ctx);
    manager.deposit(payout_coin, ctx);
}

/// Mint a position using another position as collateral (no USDC cost).
/// - UP collateral (lower strike) -> UP minted (higher strike)
/// - DOWN collateral (higher strike) -> DOWN minted (lower strike)
public fun mint_collateralized<Underlying, Quote>(
    predict: &mut Predict<Quote>,
    manager: &mut PredictManager,
    oracle: &OracleSVI<Underlying>,
    locked_key: MarketKey,
    minted_key: MarketKey,
    quantity: u64,
    clock: &Clock,
) {
    assert!(!predict.trading_paused, ETradingPaused);
    locked_key.assert_matches_oracle(oracle);
    minted_key.assert_matches_oracle(oracle);
    oracle.assert_not_stale(clock);

    let valid_pair = if (locked_key.is_up() && minted_key.is_up()) {
        locked_key.strike() < minted_key.strike()
    } else if (locked_key.is_down() && minted_key.is_down()) {
        locked_key.strike() > minted_key.strike()
    } else {
        false
    };
    assert!(valid_pair, EInvalidCollateralPair);

    manager.lock_collateral(locked_key, minted_key, quantity);
    manager.increase_position(minted_key, quantity);
}

/// Redeem a collateralized position, releasing the locked collateral.
public fun redeem_collateralized<Quote>(
    _predict: &mut Predict<Quote>,
    manager: &mut PredictManager,
    locked_key: MarketKey,
    minted_key: MarketKey,
    quantity: u64,
) {
    manager.decrease_position(minted_key, quantity);
    manager.release_collateral(locked_key, minted_key, quantity);
}

// === Public-Package Functions ===

/// Create and share the Predict object. Returns its ID.
public(package) fun create<Quote>(ctx: &mut TxContext): ID {
    let predict = Predict<Quote> {
        id: object::new(ctx),
        vault: vault::new<Quote>(ctx),
        pricing_config: pricing_config::new(),
        risk_config: risk_config::new(),
        trading_paused: false,
    };
    let predict_id = object::id(&predict);
    transfer::share_object(predict);

    predict_id
}

/// Admin deposits USDC into the vault.
public(package) fun deposit<Quote>(predict: &mut Predict<Quote>, coin: Coin<Quote>) {
    predict.vault.deposit(coin);
}

/// Admin withdraws USDC from the vault.
public(package) fun withdraw<Quote>(
    predict: &mut Predict<Quote>,
    amount: u64,
    ctx: &mut TxContext,
): Coin<Quote> {
    predict.vault.withdraw(amount).into_coin(ctx)
}

/// Set trading pause state.
public(package) fun set_trading_paused<Quote>(predict: &mut Predict<Quote>, paused: bool) {
    predict.trading_paused = paused;
}

/// Set base spread.
public(package) fun set_base_spread<Quote>(predict: &mut Predict<Quote>, spread: u64) {
    predict.pricing_config.set_base_spread(spread);
}

/// Set max skew multiplier.
public(package) fun set_max_skew_multiplier<Quote>(predict: &mut Predict<Quote>, multiplier: u64) {
    predict.pricing_config.set_max_skew_multiplier(multiplier);
}

/// Set utilization multiplier.
public(package) fun set_utilization_multiplier<Quote>(
    predict: &mut Predict<Quote>,
    multiplier: u64,
) {
    predict.pricing_config.set_utilization_multiplier(multiplier);
}

/// Set max total exposure percentage.
public(package) fun set_max_total_exposure_pct<Quote>(predict: &mut Predict<Quote>, pct: u64) {
    predict.risk_config.set_max_total_exposure_pct(pct);
}

// === Private Functions ===

/// Get bid and ask prices for a market.
/// If oracle is settled, returns settlement prices (100% for winner, 0% for loser).
/// Returns (bid, ask) in FLOAT_SCALING (1e9).
///
/// Spread formula (additive components):
///   effective_spread = base_spread
///     + base_spread × skew_multiplier × imbalance    (heavy side only)
///     + base_spread × util_multiplier × util²         (both sides)
fun get_quote<Underlying, Quote>(
    predict: &Predict<Quote>,
    oracle: &OracleSVI<Underlying>,
    key: MarketKey,
    clock: &Clock,
): (u64, u64) {
    let strike = key.strike();
    let is_up = key.is_up();

    // After settlement, return definitive prices
    if (oracle.is_settled()) {
        let settlement_price = oracle.settlement_price().destroy_some();
        let up_wins = settlement_price > strike;
        let won = if (is_up) { up_wins } else { !up_wins };
        let price = if (won) { constants::float_scaling!() } else { 0 };
        return (price, price)
    };

    let price = oracle.get_binary_price(strike, is_up, clock);
    let base_spread = predict.pricing_config.base_spread();

    let spread =
        base_spread
        + predict.inventory_skew(oracle.id(), is_up)
        + predict.utilization_spread();

    let bid = if (price > spread) { price - spread } else { 0 };
    let ask = price + spread;

    (bid, ask)
}

/// Skew spread: penalizes the heavy side using per-oracle quantity imbalance.
fun inventory_skew<Quote>(predict: &Predict<Quote>, oracle_id: ID, is_up: bool): u64 {
    let (up_qty, down_qty) = predict.vault.oracle_exposure(oracle_id);
    let total = up_qty + down_qty;
    if (total == 0) return 0;

    let this_qty = if (is_up) { up_qty } else { down_qty };
    let other_qty = if (is_up) { down_qty } else { up_qty };
    if (this_qty <= other_qty) return 0;

    let imbalance = math::div(this_qty - other_qty, total);
    math::mul(
        predict.pricing_config.base_spread(),
        math::mul(predict.pricing_config.max_skew_multiplier(), imbalance),
    )
}

/// Utilization spread: penalizes both sides as vault approaches capacity.
/// Uses util² for a gentle-then-aggressive curve.
/// Utilization is based on worst-case liability vs balance.
fun utilization_spread<Quote>(predict: &Predict<Quote>): u64 {
    let liability = predict.vault.max_liability();
    let balance = predict.vault.balance();
    if (balance == 0 || liability == 0) return 0;

    let util = if (liability >= balance) {
        constants::float_scaling!()
    } else {
        math::div(liability, balance)
    };
    let util_sq = math::mul(util, util);
    math::mul(
        predict.pricing_config.base_spread(),
        math::mul(predict.pricing_config.utilization_multiplier(), util_sq),
    )
}
