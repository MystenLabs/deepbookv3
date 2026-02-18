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
    predict.vault.execute_mint(key.is_up(), quantity, key.strike(), payment);
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
    let payout_balance = predict.vault.execute_redeem(key.is_up(), quantity, key.strike(), payout);

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
///
/// Skew uses oracle-weighted expected liability per side:
///   expected_up = total_up_short × oracle.price(avg_up_strike, UP)
///   expected_down = total_down_short × oracle.price(avg_down_strike, DOWN)
/// This captures moneyness: deep ITM positions contribute more to skew than OTM.
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

    let spread = base_spread
        + inventory_skew(predict, oracle, is_up, clock)
        + utilization_spread(predict);

    let bid = if (price > spread) { price - spread } else { 0 };
    let ask = price + spread;

    (bid, ask)
}

/// Skew spread: penalizes the heavy side using oracle-weighted expected liability.
/// Evaluates oracle at weighted-average strike per side so deep ITM positions
/// contribute more to imbalance than OTM.
fun inventory_skew<Underlying, Quote>(
    predict: &Predict<Quote>,
    oracle: &OracleSVI<Underlying>,
    is_up: bool,
    clock: &Clock,
): u64 {
    let up_short = predict.vault.total_up_short();
    let down_short = predict.vault.total_down_short();
    if (up_short + down_short == 0) return 0;

    let expected_up = expected_liability(predict, oracle, true, clock);
    let expected_down = expected_liability(predict, oracle, false, clock);
    let expected_total = expected_up + expected_down;
    if (expected_total == 0) return 0;

    let this_expected = if (is_up) { expected_up } else { expected_down };
    let other_expected = if (is_up) { expected_down } else { expected_up };
    if (this_expected <= other_expected) return 0;

    let imbalance = math::div(this_expected - other_expected, expected_total);
    math::mul(
        predict.pricing_config.base_spread(),
        math::mul(predict.pricing_config.max_skew_multiplier(), imbalance),
    )
}

/// Utilization spread: penalizes both sides as vault approaches capacity.
/// Uses util² for a gentle-then-aggressive curve.
fun utilization_spread<Quote>(predict: &Predict<Quote>): u64 {
    let total = predict.vault.total_up_short() + predict.vault.total_down_short();
    let balance = predict.vault.balance();
    if (balance == 0 || total == 0) return 0;

    let util = if (total >= balance) {
        constants::float_scaling!()
    } else {
        math::div(total, balance)
    };
    let util_sq = math::mul(util, util);
    math::mul(
        predict.pricing_config.base_spread(),
        math::mul(predict.pricing_config.utilization_multiplier(), util_sq),
    )
}

/// Expected liability for one side: total_short × oracle.price(avg_strike, is_up).
fun expected_liability<Underlying, Quote>(
    predict: &Predict<Quote>,
    oracle: &OracleSVI<Underlying>,
    is_up: bool,
    clock: &Clock,
): u64 {
    let (qty, sum_strike_qty) = if (is_up) {
        (predict.vault.total_up_short(), predict.vault.sum_up_strike_qty())
    } else {
        (predict.vault.total_down_short(), predict.vault.sum_down_strike_qty())
    };
    if (qty == 0) return 0;
    let avg_strike = (sum_strike_qty / (qty as u128) as u64);
    math::mul(qty, oracle.get_binary_price(avg_strike, is_up, clock))
}
