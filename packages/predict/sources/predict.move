// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Main entry point for the DeepBook Predict protocol.
///
/// This module orchestrates all operations:
/// - Coordinates between Vault (state), Oracle (data), and config
/// - Exposes public functions for trading and LP operations
/// - Handles pricing (spread calculation) and mark-to-market
module deepbook_predict::predict;

use deepbook::math;
use deepbook_predict::{
    constants,
    lp_config::{Self, LPConfig},
    market_key::MarketKey,
    market_manager::{Self, Markets},
    oracle_block_scholes::OracleSVI,
    predict_manager::PredictManager,
    pricing_config::{Self, PricingConfig},
    risk_config::{Self, RiskConfig},
    vault::{Self, Vault}
};
use sui::{clock::Clock, coin::Coin};

// === Errors ===
const ETradingPaused: u64 = 1;
const EMarketNotSettled: u64 = 2;
const EInvalidCollateralPair: u64 = 5;
const EWithdrawalsPaused: u64 = 6;

// === Structs ===

/// Main shared object for the DeepBook Predict protocol.
/// Quote is the collateral asset (e.g., USDC).
public struct Predict<phantom Quote> has key {
    id: UID,
    /// Enabled markets tracker
    markets: Markets,
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
    predict.markets.assert_enabled(&key);

    // Calculate cost and withdraw payment from manager
    let cost = predict.get_mint_cost(oracle, key, quantity, clock);
    let payment = manager.withdraw<Quote>(cost, ctx);

    // Execute trade
    predict.vault.execute_mint(key, quantity, payment);

    // Risk checks
    predict.vault.assert_exposure(
        key,
        predict.risk_config.max_total_exposure_pct(),
        predict.risk_config.max_per_market_exposure_pct(),
    );

    // Mark-to-market using post-trade exposure
    predict.mark_to_market(oracle, key, clock);

    // Manager records long position
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

    // Manager reduces long position first
    manager.decrease_position(key, quantity);

    // Calculate payout and execute trade
    let payout = predict.get_redeem_payout(oracle, key, quantity, clock);
    let payout_balance = predict.vault.execute_redeem(key, quantity, payout);

    // Mark-to-market using post-trade exposure
    predict.mark_to_market(oracle, key, clock);

    // Deposit payout into manager
    let payout_coin = payout_balance.into_coin(ctx);
    manager.deposit(payout_coin, ctx);
}

/// Mint a position using another position as collateral (no USDC cost).
/// - UP collateral (lower strike) → UP minted (higher strike)
/// - DOWN collateral (higher strike) → DOWN minted (lower strike)
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
    predict.markets.assert_enabled(&locked_key);
    predict.markets.assert_enabled(&minted_key);

    // Validate collateral pair
    let valid_pair = if (locked_key.is_up() && minted_key.is_up()) {
        // UP collateral must have lower strike than minted UP
        locked_key.strike() < minted_key.strike()
    } else if (locked_key.is_down() && minted_key.is_down()) {
        // DOWN collateral must have higher strike than minted DOWN
        locked_key.strike() > minted_key.strike()
    } else {
        false
    };
    assert!(valid_pair, EInvalidCollateralPair);

    // Lock collateral in manager (moves from free to locked)
    manager.lock_collateral(locked_key, minted_key, quantity);

    // Record collateralized mint in vault (no risk impact)
    predict.vault.execute_mint_collateralized(minted_key, quantity);

    // Manager records minted position
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
    // Reduce minted position
    manager.decrease_position(minted_key, quantity);

    // Release collateral (moves from locked to free)
    manager.release_collateral(locked_key, minted_key, quantity);

    // Update vault accounting
    predict.vault.execute_redeem_collateralized(minted_key, quantity);
}

/// Settle a market after expiry. Updates vault accounting to reflect actual outcome.
/// Anyone can call this once the oracle has a settlement price.
/// Idempotent - calling multiple times has no effect after first call.
public fun settle<Underlying, Quote>(
    predict: &mut Predict<Quote>,
    oracle: &OracleSVI<Underlying>,
    key: MarketKey,
    clock: &Clock,
) {
    key.assert_matches_oracle(oracle);
    assert!(oracle.is_settled(), EMarketNotSettled);

    // Mark-to-market uses settlement prices (100%/0%)
    predict.mark_to_market(oracle, key, clock);

    // Determine winner and finalize
    let settlement_price = oracle.settlement_price().destroy_some();
    let up_wins = settlement_price > key.strike();
    predict.vault.finalize_settlement(key, up_wins);
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
        markets: market_manager::new(),
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

/// Enable a market for trading.
public(package) fun enable_market<Underlying, Quote>(
    predict: &mut Predict<Quote>,
    oracle: &OracleSVI<Underlying>,
    key: MarketKey,
) {
    predict.markets.enable_market(oracle, key);
}

/// Set trading pause state.
public(package) fun set_trading_paused<Quote>(predict: &mut Predict<Quote>, paused: bool) {
    predict.trading_paused = paused;
}

/// Set withdrawals pause state.
public(package) fun set_withdrawals_paused<Quote>(predict: &mut Predict<Quote>, paused: bool) {
    predict.withdrawals_paused = paused;
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
    let (up_short, down_short) = predict.vault.pair_position(key);

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

/// Mark-to-market: calculate cost to close each position and update unrealized.
/// Short positions have unrealized_liability, long positions have unrealized_assets.
fun mark_to_market<Underlying, Quote>(
    predict: &mut Predict<Quote>,
    oracle: &OracleSVI<Underlying>,
    key: MarketKey,
    clock: &Clock,
) {
    let (up_key, down_key) = key.up_down_pair();

    update_position_mtm(predict, oracle, up_key, clock);
    update_position_mtm(predict, oracle, down_key, clock);
}

fun update_position_mtm<Underlying, Quote>(
    predict: &mut Predict<Quote>,
    oracle: &OracleSVI<Underlying>,
    key: MarketKey,
    clock: &Clock,
) {
    let (minted, redeemed) = predict.vault.position_quantities(key);
    let (bid, ask) = get_quote(predict, oracle, key, clock);

    let (liability, assets) = if (minted > redeemed) {
        let qty = minted - redeemed;
        (math::mul(ask, qty), 0)
    } else if (redeemed > minted) {
        let qty = redeemed - minted;
        (0, math::mul(bid, qty))
    } else {
        (0, 0)
    };

    predict.vault.update_unrealized(key, liability, assets);
}

