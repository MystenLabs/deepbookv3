// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Main entry point for the DeepBook Predict protocol.
///
/// This module orchestrates all operations:
/// - Coordinates between Vault (state), Oracle (data), and config
/// - Exposes public functions for trading and LP operations
/// - Handles pricing (spread calculation)
module deepbook_predict::predict;

use deepbook::math;
use deepbook_predict::{
    constants,
    lp_config::{Self, LPConfig},
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
const EInvalidCollateralPair: u64 = 2;
const EWithdrawalsPaused: u64 = 3;

// === Structs ===

/// Main shared object for the DeepBook Predict protocol.
/// Quote is the collateral asset (e.g., USDC).
public struct Predict<phantom Quote> has key {
    id: UID,
    /// Vault holding USDC and tracking exposure
    vault: Vault<Quote>,
    /// Pricing configuration (admin-controlled)
    pricing_config: PricingConfig,
    /// LP configuration (admin-controlled)
    lp_config: LPConfig,
    /// Risk limits (admin-controlled)
    risk_config: RiskConfig,
    /// Whether trading (mint) is globally paused
    trading_paused: bool,
    /// Whether LP withdrawals are globally paused
    withdrawals_paused: bool,
}

// === Public Functions ===

/// Create a new PredictManager for the caller.
public fun create_manager(ctx: &mut TxContext): ID {
    predict_manager::new(ctx)
}

/// Get the cost to mint a position (for UI/preview).
public fun get_mint_cost<Underlying, Quote>(
    predict: &Predict<Quote>,
    oracle: &OracleSVI<Underlying>,
    key: MarketKey,
    quantity: u64,
    clock: &Clock,
): u64 {
    let (_bid, ask) = get_quote(predict, oracle, key, clock);
    math::mul(ask, quantity)
}

/// Get the payout for redeeming a position (for UI/preview).
public fun get_redeem_payout<Underlying, Quote>(
    predict: &Predict<Quote>,
    oracle: &OracleSVI<Underlying>,
    key: MarketKey,
    quantity: u64,
    clock: &Clock,
): u64 {
    let (bid, _ask) = get_quote(predict, oracle, key, clock);
    math::mul(bid, quantity)
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

    let cost = predict.get_mint_cost(oracle, key, quantity, clock);
    let payment = manager.withdraw<Quote>(cost, ctx);
    predict.vault.execute_mint(key.is_up(), quantity, payment);
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

    let payout = predict.get_redeem_payout(oracle, key, quantity, clock);
    let payout_balance = predict.vault.execute_redeem(key.is_up(), quantity, payout);

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
    predict.vault.execute_mint_collateralized(quantity);
    manager.increase_position(minted_key, quantity);
}

/// Redeem a collateralized position, releasing the locked collateral.
public fun redeem_collateralized<Quote>(
    predict: &mut Predict<Quote>,
    manager: &mut PredictManager,
    locked_key: MarketKey,
    minted_key: MarketKey,
    quantity: u64,
) {
    manager.decrease_position(minted_key, quantity);
    manager.release_collateral(locked_key, minted_key, quantity);
    predict.vault.execute_redeem_collateralized(quantity);
}

/// Supply USDC to the vault, receive shares.
public fun supply<Quote>(
    predict: &mut Predict<Quote>,
    coin: Coin<Quote>,
    clock: &Clock,
    ctx: &TxContext,
): u64 {
    predict.vault.supply(coin, clock, ctx)
}

/// Withdraw USDC from the vault by burning shares.
/// Fails if lockup period has not elapsed since last supply.
public fun withdraw<Quote>(
    predict: &mut Predict<Quote>,
    shares: u64,
    clock: &Clock,
    ctx: &mut TxContext,
): Coin<Quote> {
    assert!(!predict.withdrawals_paused, EWithdrawalsPaused);
    let lockup_period_ms = predict.lp_config.lockup_period_ms();
    predict.vault.withdraw(shares, lockup_period_ms, clock, ctx).into_coin(ctx)
}

// === Public-Package Functions ===

/// Create and share the Predict object. Returns its ID.
public(package) fun create<Quote>(ctx: &mut TxContext): ID {
    let predict = Predict<Quote> {
        id: object::new(ctx),
        vault: vault::new<Quote>(ctx),
        pricing_config: pricing_config::new(),
        lp_config: lp_config::new(),
        risk_config: risk_config::new(),
        trading_paused: false,
        withdrawals_paused: false,
    };
    let predict_id = object::id(&predict);
    transfer::share_object(predict);

    predict_id
}

/// Set trading pause state.
public(package) fun set_trading_paused<Quote>(predict: &mut Predict<Quote>, paused: bool) {
    predict.trading_paused = paused;
}

/// Set withdrawals pause state.
public(package) fun set_withdrawals_paused<Quote>(predict: &mut Predict<Quote>, paused: bool) {
    predict.withdrawals_paused = paused;
}

/// Set LP lockup period.
public(package) fun set_lockup_period<Quote>(predict: &mut Predict<Quote>, period_ms: u64) {
    predict.lp_config.set_lockup_period(period_ms);
}

/// Set base spread.
public(package) fun set_base_spread<Quote>(predict: &mut Predict<Quote>, spread: u64) {
    predict.pricing_config.set_base_spread(spread);
}

/// Set max skew multiplier.
public(package) fun set_max_skew_multiplier<Quote>(predict: &mut Predict<Quote>, multiplier: u64) {
    predict.pricing_config.set_max_skew_multiplier(multiplier);
}

/// Set max total exposure percentage.
public(package) fun set_max_total_exposure_pct<Quote>(predict: &mut Predict<Quote>, pct: u64) {
    predict.risk_config.set_max_total_exposure_pct(pct);
}

// === Private Functions ===

/// Get bid and ask prices for a market.
/// If oracle is settled, returns settlement prices (100% for winner, 0% for loser).
/// Returns (bid, ask) in FLOAT_SCALING (1e9).
fun get_quote<Underlying, Quote>(
    predict: &Predict<Quote>,
    oracle: &OracleSVI<Underlying>,
    key: MarketKey,
    clock: &Clock,
): (u64, u64) {
    let strike = key.strike();
    let is_up = key.is_up();
    let up_short = predict.vault.total_up_short();
    let down_short = predict.vault.total_down_short();

    // After settlement, return definitive prices
    if (oracle.is_settled()) {
        let settlement_price = oracle.settlement_price().destroy_some();
        let up_wins = settlement_price > strike;
        let won = if (is_up) { up_wins } else { !up_wins };
        let price = if (won) { constants::float_scaling!() } else { 0 };
        return (price, price)
    };

    let price = oracle.get_binary_price(strike, is_up, clock);

    // Dynamic spread: widen on the heavy side, tighten on the light side.
    // ratio = this_side / total (0 to 1), multiplier = 2 * ratio (0x to 2x)
    let spread = if (up_short == 0 && down_short == 0) {
        math::mul(price, predict.pricing_config.base_spread())
    } else {
        let this_side = if (is_up) { up_short } else { down_short };
        let total = up_short + down_short;
        let ratio = math::div(this_side, total);
        let multiplier = math::mul(2 * ratio, predict.pricing_config.max_skew_multiplier());
        math::mul(price, math::mul(predict.pricing_config.base_spread(), multiplier))
    };
    let bid = if (price > spread) { price - spread } else { 0 };
    let ask = price + spread;

    (bid, ask)
}
