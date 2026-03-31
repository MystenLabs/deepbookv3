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
    supply_manager::{Self, SupplyManager},
    vault::{Self, Vault}
};
use sui::{clock::Clock, coin::Coin, event};

// === Errors ===
const ETradingPaused: u64 = 0;
const EInvalidCollateralPair: u64 = 1;
const ENotOwner: u64 = 2;
const EOracleSettled: u64 = 3;
const EWithdrawExceedsAvailable: u64 = 4;
const EOracleExpired: u64 = 5;
const EZeroQuantity: u64 = 6;

// === Events ===

public struct ManagerCreated has copy, drop, store {
    manager_id: ID,
    owner: address,
}

public struct PositionMinted has copy, drop, store {
    predict_id: ID,
    manager_id: ID,
    trader: address,
    oracle_id: ID,
    expiry: u64,
    strike: u64,
    is_up: bool,
    quantity: u64,
    cost: u64,
    ask_price: u64,
}

public struct PositionRedeemed has copy, drop, store {
    predict_id: ID,
    manager_id: ID,
    trader: address,
    oracle_id: ID,
    expiry: u64,
    strike: u64,
    is_up: bool,
    quantity: u64,
    payout: u64,
    bid_price: u64,
    is_settled: bool,
}

public struct CollateralizedPositionMinted has copy, drop, store {
    predict_id: ID,
    manager_id: ID,
    trader: address,
    oracle_id: ID,
    locked_expiry: u64,
    locked_strike: u64,
    locked_is_up: bool,
    minted_expiry: u64,
    minted_strike: u64,
    minted_is_up: bool,
    quantity: u64,
}

public struct CollateralizedPositionRedeemed has copy, drop, store {
    predict_id: ID,
    manager_id: ID,
    trader: address,
    oracle_id: ID,
    locked_expiry: u64,
    locked_strike: u64,
    locked_is_up: bool,
    minted_expiry: u64,
    minted_strike: u64,
    minted_is_up: bool,
    quantity: u64,
}

public struct TradingPauseUpdated has copy, drop, store {
    predict_id: ID,
    paused: bool,
}

public struct PricingConfigUpdated has copy, drop, store {
    predict_id: ID,
    base_spread: u64,
    min_spread: u64,
    utilization_multiplier: u64,
}

public struct RiskConfigUpdated has copy, drop, store {
    predict_id: ID,
    max_total_exposure_pct: u64,
}

public struct Supplied has copy, drop, store {
    predict_id: ID,
    supplier: address,
    amount: u64,
    shares_minted: u64,
}

public struct Withdrawn has copy, drop, store {
    predict_id: ID,
    supplier: address,
    amount: u64,
    shares_burned: u64,
}

// === Structs ===

/// Main shared object for the DeepBook Predict protocol.
/// Quote is the collateral asset (e.g., USDC).
public struct Predict<phantom Quote> has key {
    id: UID,
    /// Vault holding USDC and tracking exposure
    vault: Vault<Quote>,
    /// Per-user supply share accounting
    supply_manager: SupplyManager,
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
    let manager_id = predict_manager::new(ctx);
    event::emit(ManagerCreated {
        manager_id,
        owner: ctx.sender(),
    });
    manager_id
}

/// Get the amounts for mint/redeem (for UI/preview).
/// Returns (mint_cost, redeem_payout).
public fun get_trade_amounts<Quote>(
    predict: &Predict<Quote>,
    oracle: &OracleSVI,
    key: MarketKey,
    quantity: u64,
    clock: &Clock,
): (u64, u64) {
    let (bid, ask) = predict.get_quote(oracle, key, clock);
    (math::mul(ask, quantity), math::mul(bid, quantity))
}

/// Buy a position. Cost is withdrawn from the PredictManager's balance.
/// Position quantity is added to the PredictManager's positions.
public fun mint<Quote>(
    predict: &mut Predict<Quote>,
    manager: &mut PredictManager,
    oracle: &OracleSVI,
    key: MarketKey,
    quantity: u64,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    assert!(ctx.sender() == manager.owner(), ENotOwner);
    assert!(!predict.trading_paused, ETradingPaused);
    assert!(quantity > 0, EZeroQuantity);
    key.assert_matches_oracle(oracle);
    assert!(!oracle.is_settled(), EOracleSettled);
    assert!(clock.timestamp_ms() < oracle.expiry(), EOracleExpired);
    oracle.assert_not_stale(clock);

    let strike = key.strike();
    let is_up = key.is_up();

    predict.vault.insert_position(oracle, is_up, strike, quantity, clock, ctx);

    let (_bid, ask) = predict.get_quote(oracle, key, clock);
    let cost = math::mul(ask, quantity);

    let payment = manager.withdraw<Quote>(cost, ctx).into_balance();
    predict.vault.accept_payment(payment);
    predict.vault.assert_total_exposure(predict.risk_config.max_total_exposure_pct());
    manager.increase_position(key, quantity);

    event::emit(PositionMinted {
        predict_id: object::id(predict),
        manager_id: object::id(manager),
        trader: manager.owner(),
        oracle_id: key.oracle_id(),
        expiry: key.expiry(),
        strike,
        is_up,
        quantity,
        cost,
        ask_price: ask,
    });
}

/// Sell a position. Payout is deposited into the PredictManager's balance.
/// Position quantity is removed from the PredictManager's positions.
public fun redeem<Quote>(
    predict: &mut Predict<Quote>,
    manager: &mut PredictManager,
    oracle: &OracleSVI,
    key: MarketKey,
    quantity: u64,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    assert!(ctx.sender() == manager.owner(), ENotOwner);
    assert!(quantity > 0, EZeroQuantity);
    key.assert_matches_oracle(oracle);
    if (!oracle.is_settled()) oracle.assert_not_stale(clock);
    manager.decrease_position(key, quantity);

    let strike = key.strike();
    let is_up = key.is_up();

    predict.vault.remove_position(oracle, is_up, strike, quantity, clock);

    let (bid, _ask) = predict.get_quote(oracle, key, clock);
    let payout = math::mul(bid, quantity);

    let payout_balance = predict.vault.dispense_payout(payout);
    let payout_coin = payout_balance.into_coin(ctx);
    manager.deposit(payout_coin, ctx);

    event::emit(PositionRedeemed {
        predict_id: object::id(predict),
        manager_id: object::id(manager),
        trader: manager.owner(),
        oracle_id: key.oracle_id(),
        expiry: key.expiry(),
        strike,
        is_up,
        quantity,
        payout,
        bid_price: bid,
        is_settled: oracle.is_settled(),
    });
}

/// Mint a position using another position as collateral (no USDC cost).
/// - UP collateral (lower strike) -> UP minted (higher strike)
/// - DOWN collateral (higher strike) -> DOWN minted (lower strike)
public fun mint_collateralized<Quote>(
    predict: &mut Predict<Quote>,
    manager: &mut PredictManager,
    oracle: &OracleSVI,
    locked_key: MarketKey,
    minted_key: MarketKey,
    quantity: u64,
    clock: &Clock,
    ctx: &TxContext,
) {
    assert!(ctx.sender() == manager.owner(), ENotOwner);
    assert!(!predict.trading_paused, ETradingPaused);
    assert!(quantity > 0, EZeroQuantity);
    locked_key.assert_matches_oracle(oracle);
    minted_key.assert_matches_oracle(oracle);
    assert!(!oracle.is_settled(), EOracleSettled);
    assert!(clock.timestamp_ms() < oracle.expiry(), EOracleExpired);
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

    event::emit(CollateralizedPositionMinted {
        predict_id: object::id(predict),
        manager_id: object::id(manager),
        trader: manager.owner(),
        oracle_id: locked_key.oracle_id(),
        locked_expiry: locked_key.expiry(),
        locked_strike: locked_key.strike(),
        locked_is_up: locked_key.is_up(),
        minted_expiry: minted_key.expiry(),
        minted_strike: minted_key.strike(),
        minted_is_up: minted_key.is_up(),
        quantity,
    });
}

/// Redeem a collateralized position, releasing the locked collateral.
public fun redeem_collateralized<Quote>(
    predict: &mut Predict<Quote>,
    manager: &mut PredictManager,
    locked_key: MarketKey,
    minted_key: MarketKey,
    quantity: u64,
    ctx: &TxContext,
) {
    assert!(ctx.sender() == manager.owner(), ENotOwner);
    assert!(quantity > 0, EZeroQuantity);
    manager.decrease_position(minted_key, quantity);
    manager.release_collateral(locked_key, minted_key, quantity);

    event::emit(CollateralizedPositionRedeemed {
        predict_id: object::id(predict),
        manager_id: object::id(manager),
        trader: manager.owner(),
        oracle_id: locked_key.oracle_id(),
        locked_expiry: locked_key.expiry(),
        locked_strike: locked_key.strike(),
        locked_is_up: locked_key.is_up(),
        minted_expiry: minted_key.expiry(),
        minted_strike: minted_key.strike(),
        minted_is_up: minted_key.is_up(),
        quantity,
    });
}

/// Supply USDC into the vault. Returns shares minted.
public fun supply<Quote>(predict: &mut Predict<Quote>, coin: Coin<Quote>, ctx: &TxContext): u64 {
    let amount = coin.value();
    let vault_value = predict.vault.vault_value();
    predict.vault.accept_payment(coin.into_balance());
    let shares_minted = predict.supply_manager.supply(amount, vault_value, ctx.sender());
    event::emit(Supplied {
        predict_id: object::id(predict),
        supplier: ctx.sender(),
        amount,
        shares_minted,
    });
    shares_minted
}

/// Withdraw USDC from the vault by specifying amount.
public fun withdraw<Quote>(
    predict: &mut Predict<Quote>,
    amount: u64,
    ctx: &mut TxContext,
): Coin<Quote> {
    let balance = predict.vault.balance();
    let max_payout = predict.vault.total_max_payout();
    let available = if (balance > max_payout) { balance - max_payout } else { 0 };
    assert!(amount <= available, EWithdrawExceedsAvailable);
    let vault_value = predict.vault.vault_value();
    let shares_burned = predict.supply_manager.withdraw(amount, vault_value, ctx.sender());
    event::emit(Withdrawn {
        predict_id: object::id(predict),
        supplier: ctx.sender(),
        amount,
        shares_burned,
    });
    predict.vault.dispense_payout(amount).into_coin(ctx)
}

/// Withdraw all of sender's supplied USDC from the vault.
public fun withdraw_all<Quote>(predict: &mut Predict<Quote>, ctx: &mut TxContext): Coin<Quote> {
    let vault_value = predict.vault.vault_value();
    let (amount, shares_burned) = predict.supply_manager.withdraw_all(vault_value, ctx.sender());
    let balance = predict.vault.balance();
    let max_payout = predict.vault.total_max_payout();
    let available = if (balance > max_payout) { balance - max_payout } else { 0 };
    assert!(amount <= available, EWithdrawExceedsAvailable);
    event::emit(Withdrawn {
        predict_id: object::id(predict),
        supplier: ctx.sender(),
        amount,
        shares_burned,
    });
    predict.vault.dispense_payout(amount).into_coin(ctx)
}

// === Public-Package Functions ===

/// Create and share the Predict object. Returns its ID.
public(package) fun create<Quote>(ctx: &mut TxContext): ID {
    let predict = Predict<Quote> {
        id: object::new(ctx),
        vault: vault::new<Quote>(ctx),
        supply_manager: supply_manager::new(ctx),
        pricing_config: pricing_config::new(),
        risk_config: risk_config::new(),
        trading_paused: false,
    };
    let predict_id = object::id(&predict);
    transfer::share_object(predict);

    predict_id
}

/// Whether trading is currently paused.
public fun trading_paused<Quote>(predict: &Predict<Quote>): bool {
    predict.trading_paused
}

/// Get the base spread.
public fun base_spread<Quote>(predict: &Predict<Quote>): u64 {
    predict.pricing_config.base_spread()
}

/// Get the min spread.
public fun min_spread<Quote>(predict: &Predict<Quote>): u64 {
    predict.pricing_config.min_spread()
}

/// Get the utilization multiplier.
public fun utilization_multiplier<Quote>(predict: &Predict<Quote>): u64 {
    predict.pricing_config.utilization_multiplier()
}

/// Get the max total exposure percentage.
public fun max_total_exposure_pct<Quote>(predict: &Predict<Quote>): u64 {
    predict.risk_config.max_total_exposure_pct()
}

/// Set trading pause state.
public(package) fun set_trading_paused<Quote>(predict: &mut Predict<Quote>, paused: bool) {
    predict.trading_paused = paused;
    event::emit(TradingPauseUpdated {
        predict_id: object::id(predict),
        paused,
    });
}

/// Set base spread.
public(package) fun set_base_spread<Quote>(predict: &mut Predict<Quote>, spread: u64) {
    predict.pricing_config.set_base_spread(spread);
    predict.emit_pricing_config_updated();
}

/// Set min spread.
public(package) fun set_min_spread<Quote>(predict: &mut Predict<Quote>, spread: u64) {
    predict.pricing_config.set_min_spread(spread);
    predict.emit_pricing_config_updated();
}

/// Set utilization multiplier.
public(package) fun set_utilization_multiplier<Quote>(
    predict: &mut Predict<Quote>,
    multiplier: u64,
) {
    predict.pricing_config.set_utilization_multiplier(multiplier);
    predict.emit_pricing_config_updated();
}

/// Set max total exposure percentage.
public(package) fun set_max_total_exposure_pct<Quote>(predict: &mut Predict<Quote>, pct: u64) {
    predict.risk_config.set_max_total_exposure_pct(pct);
    event::emit(RiskConfigUpdated {
        predict_id: object::id(predict),
        max_total_exposure_pct: predict.risk_config.max_total_exposure_pct(),
    });
}

#[test_only]
/// Create a Predict object for testing without sharing it.
public(package) fun create_test_predict<Quote>(ctx: &mut TxContext): Predict<Quote> {
    Predict<Quote> {
        id: object::new(ctx),
        vault: vault::new<Quote>(ctx),
        supply_manager: supply_manager::new(ctx),
        pricing_config: pricing_config::new(),
        risk_config: risk_config::new(),
        trading_paused: false,
    }
}

#[test_only]
public(package) fun vault_mut<Quote>(predict: &mut Predict<Quote>): &mut Vault<Quote> {
    &mut predict.vault
}

#[test_only]
public(package) fun vault_balance<Quote>(predict: &Predict<Quote>): u64 {
    predict.vault.balance()
}

// === Private Functions ===

fun emit_pricing_config_updated<Quote>(predict: &Predict<Quote>) {
    event::emit(PricingConfigUpdated {
        predict_id: object::id(predict),
        base_spread: predict.pricing_config.base_spread(),
        min_spread: predict.pricing_config.min_spread(),
        utilization_multiplier: predict.pricing_config.utilization_multiplier(),
    });
}

/// Get bid and ask prices for a market.
/// Returns (bid, ask) in FLOAT_SCALING (1e9).
fun get_quote<Quote>(
    predict: &Predict<Quote>,
    oracle: &OracleSVI,
    key: MarketKey,
    clock: &Clock,
): (u64, u64) {
    let strike = key.strike();
    let is_up = key.is_up();
    let price = oracle.get_binary_price(strike, is_up, clock);

    if (oracle.is_settled()) return (price, price);

    let complement = constants::float_scaling!() - price;
    let variance = math::mul(price, complement);
    let bernoulli_factor = math::sqrt(variance, constants::float_scaling!());
    let bernoulli_spread = math::mul(predict.pricing_config.base_spread(), bernoulli_factor);
    let spread =
        bernoulli_spread.max(predict.pricing_config.min_spread())
        + predict.utilization_spread();

    let bid = if (price > spread) { price - spread } else { 0 };
    let ask = (price + spread).min(constants::float_scaling!());

    (bid, ask)
}

/// Utilization spread: penalizes both sides as vault approaches capacity.
/// Uses util^2 for a gentle-then-aggressive curve.
fun utilization_spread<Quote>(predict: &Predict<Quote>): u64 {
    let liability = predict.vault.total_mtm();
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
