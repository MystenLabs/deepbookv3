// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Main entry point for the DeepBook Predict protocol.
///
/// This module orchestrates all operations:
/// - Coordinates between Vault (state), Pricing (calculations), and Oracle (data)
/// - Exposes public functions for trading and LP operations
/// - Handles mark-to-market after each trade
module deepbook_predict::predict;

use deepbook::math;
use deepbook_predict::{
    lp_config::{Self, LPConfig},
    market_key::MarketKey,
    market_manager::{Self, Markets},
    oracle_block_scholes::OracleSVI,
    predict_manager::PredictManager,
    pricing::{Self, Pricing},
    risk_config::{Self, RiskConfig},
    vault::{Self, Vault}
};
use sui::{clock::Clock, coin::Coin};

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
    pricing: Pricing,
    /// LP configuration (admin-controlled)
    lp_config: LPConfig,
    /// Risk limits (admin-controlled)
    risk_config: RiskConfig,
}

// === Errors ===
const EOracleMismatch: u64 = 0;
const EExpiryMismatch: u64 = 1;
const EMarketNotSettled: u64 = 2;
const EExceedsMaxTotalExposure: u64 = 3;
const EExceedsMaxMarketExposure: u64 = 4;
const EInvalidCollateralPair: u64 = 5;

// === Public Functions ===

/// Get the cost to mint a position (for UI/preview).
public fun get_mint_cost<Underlying, Quote>(
    predict: &Predict<Quote>,
    oracle: &OracleSVI<Underlying>,
    key: MarketKey,
    quantity: u64,
    clock: &Clock,
): u64 {
    let (up_short, down_short) = predict.vault.pair_position(key);
    predict.pricing.get_mint_cost(oracle, key, quantity, up_short, down_short, clock)
}

/// Get the payout for redeeming a position (for UI/preview).
public fun get_redeem_payout<Underlying, Quote>(
    predict: &Predict<Quote>,
    oracle: &OracleSVI<Underlying>,
    key: MarketKey,
    quantity: u64,
    clock: &Clock,
): u64 {
    let (up_short, down_short) = predict.vault.pair_position(key);
    predict.pricing.get_redeem_payout(oracle, key, quantity, up_short, down_short, clock)
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
    assert!(key.oracle_id() == oracle.id(), EOracleMismatch);
    assert!(key.expiry() == oracle.expiry(), EExpiryMismatch);
    oracle.assert_not_stale(clock);
    predict.markets.assert_enabled(&key);

    // Calculate cost and withdraw payment from manager
    let cost = predict.get_mint_cost(oracle, key, quantity, clock);
    let payment = manager.withdraw<Quote>(cost, ctx);

    // Execute trade
    predict.vault.execute_mint(key, quantity, payment);

    // Risk checks
    predict.assert_vault_exposure(key);

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
    assert!(key.oracle_id() == oracle.id(), EOracleMismatch);
    assert!(key.expiry() == oracle.expiry(), EExpiryMismatch);
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
    assert!(locked_key.oracle_id() == oracle.id(), EOracleMismatch);
    assert!(locked_key.expiry() == oracle.expiry(), EExpiryMismatch);
    assert!(minted_key.oracle_id() == oracle.id(), EOracleMismatch);
    assert!(minted_key.expiry() == oracle.expiry(), EExpiryMismatch);
    oracle.assert_not_stale(clock);
    predict.markets.assert_enabled(&locked_key);
    predict.markets.assert_enabled(&minted_key);

    // Validate collateral pair
    assert!(locked_key.oracle_id() == minted_key.oracle_id(), EInvalidCollateralPair);
    assert!(locked_key.expiry() == minted_key.expiry(), EInvalidCollateralPair);

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
    assert!(key.oracle_id() == oracle.id(), EOracleMismatch);
    assert!(key.expiry() == oracle.expiry(), EExpiryMismatch);
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
        pricing: pricing::new(),
        lp_config: lp_config::new(),
        risk_config: risk_config::new(),
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

// === Private Functions ===

/// Mark-to-market: calculate cost to close each position and update unrealized.
/// Short positions have unrealized_liability, long positions have unrealized_assets.
fun mark_to_market<Underlying, Quote>(
    predict: &mut Predict<Quote>,
    oracle: &OracleSVI<Underlying>,
    key: MarketKey,
    clock: &Clock,
) {
    let (up_key, down_key) = key.up_down_pair();
    let (up_short, down_short) = predict.vault.pair_position(key);

    update_position_mtm(predict, oracle, up_key, up_short, down_short, clock);
    update_position_mtm(predict, oracle, down_key, up_short, down_short, clock);
}

fun update_position_mtm<Underlying, Quote>(
    predict: &mut Predict<Quote>,
    oracle: &OracleSVI<Underlying>,
    key: MarketKey,
    up_short: u64,
    down_short: u64,
    clock: &Clock,
) {
    let (minted, redeemed) = predict.vault.position_quantities(key);

    let (liability, assets) = if (minted > redeemed) {
        let qty = minted - redeemed;
        (predict.pricing.get_mint_cost(oracle, key, qty, up_short, down_short, clock), 0)
    } else if (redeemed > minted) {
        let qty = redeemed - minted;
        (0, predict.pricing.get_redeem_payout(oracle, key, qty, up_short, down_short, clock))
    } else {
        (0, 0)
    };

    predict.vault.update_unrealized(key, liability, assets);
}

fun assert_vault_exposure<Quote>(predict: &Predict<Quote>, key: MarketKey) {
    let balance = predict.vault.balance();
    let max_liability = predict.vault.max_liability();
    let market_liability = predict.vault.market_liability(key);
    let max_total_pct = predict.risk_config.max_total_exposure_pct();
    let max_market_pct = predict.risk_config.max_per_market_exposure_pct();
    assert!(max_liability <= math::mul(balance, max_total_pct), EExceedsMaxTotalExposure);
    assert!(market_liability <= math::mul(balance, max_market_pct), EExceedsMaxMarketExposure);
}
