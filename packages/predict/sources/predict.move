// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Main entry point for the DeepBook Predict protocol.
///
/// This module orchestrates user actions across the vault, oracle config,
/// manager, and pricing layers. It owns public trading and LP flows, while the
/// lower modules provide isolated state machines and pricing primitives.
module deepbook_predict::predict;

use deepbook::math;
use deepbook_predict::{
    constants,
    market_key::MarketKey,
    math::mul_div_round_down,
    oracle::{OracleSVI, OracleSVICap},
    oracle_config::{Self, OracleConfig},
    plp::PLP,
    predict_manager::{Self, PredictManager},
    pricing_config::{Self, PricingConfig},
    range_key::RangeKey,
    risk_config::{Self, RiskConfig},
    treasury_config::{Self, TreasuryConfig},
    vault::{Self, Vault}
};
use std::type_name::{Self, TypeName};
use sui::{
    clock::Clock,
    coin::{Self, Coin, TreasuryCap},
    coin_registry::Currency,
    event,
    vec_set::VecSet
};

// === Errors ===
const ETradingPaused: u64 = 0;
const ENotOwner: u64 = 1;
const EWithdrawExceedsAvailable: u64 = 2;
const EZeroQuantity: u64 = 3;
const EZeroAmount: u64 = 4;
const EZeroVaultValue: u64 = 5;
const EZeroSharesMinted: u64 = 6;
const EAskPriceOutOfBounds: u64 = 7;
const EAskBoundLooserThanGlobal: u64 = 8;
const EOracleNotSettled: u64 = 9;

// === Events ===

public struct ManagerCreated has copy, drop, store {
    manager_id: ID,
    owner: address,
}

public struct PositionMinted has copy, drop, store {
    predict_id: ID,
    manager_id: ID,
    trader: address,
    quote_asset: TypeName,
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
    owner: address,
    executor: address,
    quote_asset: TypeName,
    oracle_id: ID,
    expiry: u64,
    strike: u64,
    is_up: bool,
    quantity: u64,
    payout: u64,
    bid_price: u64,
    is_settled: bool,
}

public struct RangeMinted has copy, drop, store {
    predict_id: ID,
    manager_id: ID,
    trader: address,
    quote_asset: TypeName,
    oracle_id: ID,
    expiry: u64,
    lower_strike: u64,
    higher_strike: u64,
    quantity: u64,
    cost: u64,
    ask_price: u64,
}

public struct RangeRedeemed has copy, drop, store {
    predict_id: ID,
    manager_id: ID,
    trader: address,
    quote_asset: TypeName,
    oracle_id: ID,
    expiry: u64,
    lower_strike: u64,
    higher_strike: u64,
    quantity: u64,
    payout: u64,
    bid_price: u64,
    is_settled: bool,
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
    min_ask_price: u64,
    max_ask_price: u64,
}

public struct OracleAskBoundsSet has copy, drop, store {
    predict_id: ID,
    oracle_id: ID,
    min_ask_price: u64,
    max_ask_price: u64,
}

public struct OracleAskBoundsCleared has copy, drop, store {
    predict_id: ID,
    oracle_id: ID,
}

public struct RiskConfigUpdated has copy, drop, store {
    predict_id: ID,
    max_total_exposure_pct: u64,
}

public struct QuoteAssetEnabled has copy, drop, store {
    predict_id: ID,
    quote_asset: TypeName,
}

public struct QuoteAssetDisabled has copy, drop, store {
    predict_id: ID,
    quote_asset: TypeName,
}

public struct Supplied has copy, drop, store {
    predict_id: ID,
    supplier: address,
    quote_asset: TypeName,
    amount: u64,
    shares_minted: u64,
}

public struct Withdrawn has copy, drop, store {
    predict_id: ID,
    withdrawer: address,
    quote_asset: TypeName,
    amount: u64,
    shares_burned: u64,
}

// === Structs ===

/// Main shared object for the DeepBook Predict protocol.
public struct Predict has key {
    id: UID,
    /// Vault holding treasury balances and tracking exposure
    vault: Vault,
    /// Treasury cap for minting/burning PLP tokens
    treasury_cap: TreasuryCap<PLP>,
    /// Pricing configuration (admin-controlled)
    pricing_config: PricingConfig,
    /// Risk limits (admin-controlled)
    risk_config: RiskConfig,
    /// Treasury asset whitelist and related treasury policy state
    treasury_config: TreasuryConfig,
    /// Oracle strike grid registry, operational checks, and curve builder
    oracle_config: OracleConfig,
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
public fun get_trade_amounts(
    predict: &Predict,
    oracle: &OracleSVI,
    key: MarketKey,
    quantity: u64,
    clock: &Clock,
): (u64, u64) {
    let (ask, bid) = predict.trade_prices(oracle, key, clock);
    (math::mul(ask, quantity), math::mul(bid, quantity))
}

/// Resolved ask-price bounds for an oracle, after intersecting any per-oracle
/// override with the global default. Exposed for UI/preview.
public fun ask_bounds(predict: &Predict, oracle_id: ID): (u64, u64) {
    predict.resolve_ask_bounds(oracle_id)
}

/// Buy a position using an enabled quote asset.
/// Cost is withdrawn from the PredictManager's balance.
/// Position quantity is added to the PredictManager's positions.
public fun mint<Quote>(
    predict: &mut Predict,
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
    predict.treasury_config.assert_quote_asset<Quote>();

    predict.oracle_config.assert_key_matches(oracle, &key);
    oracle_config::assert_live_oracle(oracle, clock);

    let strike = key.strike();
    let is_up = key.is_up();

    predict.vault.insert_position(oracle.id(), is_up, strike, quantity);
    predict.refresh_oracle_risk(oracle);

    // Quote against the post-trade state so the trader pays for the liability
    // their own mint just added to the vault.
    let (ask, _) = predict.trade_prices(oracle, key, clock);
    predict.assert_mintable_ask(oracle.id(), ask);
    let cost = math::mul(ask, quantity);

    let payment = manager.withdraw<Quote>(cost, ctx).into_balance();
    predict.vault.accept_payment(payment);
    predict.vault.assert_total_exposure(predict.risk_config.max_total_exposure_pct());
    manager.increase_position(key, quantity);

    event::emit(PositionMinted {
        predict_id: object::id(predict),
        manager_id: object::id(manager),
        trader: manager.owner(),
        quote_asset: type_name::with_defining_ids<Quote>(),
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
/// Outflows can use any quote asset with concrete vault balance, even if it is
/// disabled for new inflows.
/// Position quantity is removed from the PredictManager's positions.
public fun redeem<Quote>(
    predict: &mut Predict,
    manager: &mut PredictManager,
    oracle: &OracleSVI,
    key: MarketKey,
    quantity: u64,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    assert!(ctx.sender() == manager.owner(), ENotOwner);
    let payout_coin = redeem_internal<Quote>(predict, manager, oracle, key, quantity, clock, ctx);
    manager.deposit(payout_coin, ctx);
}

/// Sell a settled position permissionlessly into the PredictManager's balance.
public fun redeem_permissionless<Quote>(
    predict: &mut Predict,
    manager: &mut PredictManager,
    oracle: &OracleSVI,
    key: MarketKey,
    quantity: u64,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    assert!(oracle.is_settled(), EOracleNotSettled);
    let payout_coin = redeem_internal<Quote>(predict, manager, oracle, key, quantity, clock, ctx);
    manager.deposit_permissionless(payout_coin, ctx);
}

/// Get the amounts for range mint/redeem (for UI/preview).
/// Returns (mint_cost, redeem_payout). Bull-call and bear-put ranges with the
/// same strikes price identically — direction is not part of `RangeKey`.
public fun get_range_trade_amounts(
    predict: &Predict,
    oracle: &OracleSVI,
    key: RangeKey,
    quantity: u64,
    clock: &Clock,
): (u64, u64) {
    let (ask, bid) = predict.range_trade_prices(oracle, key, clock);
    (math::mul(ask, quantity), math::mul(bid, quantity))
}

/// Mint a vertical range `(lower, higher)` priced as a single instrument.
/// The user pays only the range premium up front; the vault tracks the bounded
/// liability natively via the strike-matrix range_qty offset.
public fun mint_range<Quote>(
    predict: &mut Predict,
    manager: &mut PredictManager,
    oracle: &OracleSVI,
    key: RangeKey,
    quantity: u64,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    assert!(ctx.sender() == manager.owner(), ENotOwner);
    assert!(!predict.trading_paused, ETradingPaused);
    assert!(quantity > 0, EZeroQuantity);
    predict.treasury_config.assert_quote_asset<Quote>();
    predict.oracle_config.assert_range_key_matches(oracle, &key);
    oracle_config::assert_live_oracle(oracle, clock);

    let lower = key.lower_strike();
    let higher = key.higher_strike();

    predict.vault.insert_range(oracle.id(), lower, higher, quantity);
    predict.refresh_oracle_risk(oracle);

    // Quote against the post-trade state so the trader pays for the liability
    // their own mint just added to the vault.
    let (ask, _) = predict.range_trade_prices(oracle, key, clock);
    predict.assert_mintable_ask(oracle.id(), ask);
    let cost = math::mul(ask, quantity);

    let payment = manager.withdraw<Quote>(cost, ctx).into_balance();
    predict.vault.accept_payment(payment);
    predict.vault.assert_total_exposure(predict.risk_config.max_total_exposure_pct());
    manager.increase_range(key, quantity);

    event::emit(RangeMinted {
        predict_id: object::id(predict),
        manager_id: object::id(manager),
        trader: manager.owner(),
        quote_asset: type_name::with_defining_ids<Quote>(),
        oracle_id: key.oracle_id(),
        expiry: key.expiry(),
        lower_strike: lower,
        higher_strike: higher,
        quantity,
        cost,
        ask_price: ask,
    });
}

/// Redeem a vertical range. Payout is the post-trade bid value pre-settlement,
/// or `$1·qty` if the settlement landed in the band (lower, higher].
public fun redeem_range<Quote>(
    predict: &mut Predict,
    manager: &mut PredictManager,
    oracle: &OracleSVI,
    key: RangeKey,
    quantity: u64,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    assert!(ctx.sender() == manager.owner(), ENotOwner);
    assert!(quantity > 0, EZeroQuantity);
    predict.oracle_config.assert_range_key_matches(oracle, &key);
    oracle_config::assert_quoteable_oracle(oracle, clock);

    manager.decrease_range(key, quantity);

    let lower = key.lower_strike();
    let higher = key.higher_strike();

    predict.vault.remove_range(oracle.id(), lower, higher, quantity);
    predict.refresh_oracle_risk(oracle);

    // Quote against the post-trade state so the seller is paid from the
    // liability after their range has been removed from the vault.
    let (_, payout) = predict.get_range_trade_amounts(oracle, key, quantity, clock);

    let payout_balance = predict.vault.dispense_payout<Quote>(payout);
    let payout_coin = payout_balance.into_coin(ctx);
    manager.deposit(payout_coin, ctx);

    event::emit(RangeRedeemed {
        predict_id: object::id(predict),
        manager_id: object::id(manager),
        trader: manager.owner(),
        quote_asset: type_name::with_defining_ids<Quote>(),
        oracle_id: key.oracle_id(),
        expiry: key.expiry(),
        lower_strike: lower,
        higher_strike: higher,
        quantity,
        payout,
        bid_price: math::div(payout, quantity),
        is_settled: oracle.is_settled(),
    });
}

/// Supply an accepted quote asset into the vault. Returns LP tokens representing shares.
/// First depositor gets shares 1:1. Subsequent depositors get shares
/// proportional to their deposit relative to current vault value.
/// Supply an enabled quote asset into the shared LP pool.
public fun supply<Quote>(predict: &mut Predict, coin: Coin<Quote>, ctx: &mut TxContext): Coin<PLP> {
    let amount = coin.value();
    assert!(amount > 0, EZeroAmount);
    predict.treasury_config.assert_quote_asset<Quote>();

    let vault_value = predict.vault.vault_value();
    predict.vault.accept_payment(coin.into_balance());

    let total = predict.treasury_cap.total_supply();
    let shares = if (total == 0) {
        amount
    } else {
        assert!(vault_value > 0, EZeroVaultValue);
        mul_div_round_down(amount, total, vault_value)
    };
    assert!(shares > 0, EZeroSharesMinted);

    event::emit(Supplied {
        predict_id: object::id(predict),
        supplier: ctx.sender(),
        quote_asset: type_name::with_defining_ids<Quote>(),
        amount,
        shares_minted: shares,
    });
    coin::mint(&mut predict.treasury_cap, shares, ctx)
}

/// Withdraw a selected quote asset from the vault by providing LP tokens.
/// Outflows can use any quote asset with concrete vault balance, even if it is
/// disabled for new inflows.
/// Burns the LP tokens and returns the corresponding quote asset.
public fun withdraw<Quote>(
    predict: &mut Predict,
    lp_coin: Coin<PLP>,
    ctx: &mut TxContext,
): Coin<Quote> {
    let vault_value = predict.vault.vault_value();
    let shares_burned = lp_coin.value();
    assert!(shares_burned > 0, EZeroAmount);
    let amount = predict.shares_to_amount(shares_burned, vault_value);
    let balance = predict.vault.balance();
    let max_payout = predict.vault.total_max_payout();
    let available = if (balance > max_payout) {
        balance - max_payout
    } else {
        0
    };
    assert!(amount <= available, EWithdrawExceedsAvailable);
    predict.treasury_cap.burn(lp_coin);
    event::emit(Withdrawn {
        predict_id: object::id(predict),
        withdrawer: ctx.sender(),
        quote_asset: type_name::with_defining_ids<Quote>(),
        amount,
        shares_burned,
    });
    predict.vault.dispense_payout<Quote>(amount).into_coin(ctx)
}

// === Public-Package Functions ===

/// Create and share the Predict object. Returns its ID.
public(package) fun create<Quote>(
    currency: &Currency<Quote>,
    treasury_cap: TreasuryCap<PLP>,
    ctx: &mut TxContext,
): ID {
    let mut predict = Predict {
        id: object::new(ctx),
        vault: vault::new(ctx),
        treasury_cap,
        pricing_config: pricing_config::new(),
        risk_config: risk_config::new(),
        treasury_config: treasury_config::new(),
        oracle_config: oracle_config::new(ctx),
        trading_paused: false,
    };
    predict.enable_quote_asset<Quote>(currency);
    let predict_id = object::id(&predict);
    transfer::share_object(predict);

    predict_id
}

public(package) fun enable_quote_asset<Quote>(predict: &mut Predict, currency: &Currency<Quote>) {
    predict.treasury_config.add_quote_asset<Quote>(currency);
    event::emit(QuoteAssetEnabled {
        predict_id: object::id(predict),
        quote_asset: type_name::with_defining_ids<Quote>(),
    });
}

public(package) fun disable_quote_asset<Quote>(predict: &mut Predict) {
    predict.treasury_config.remove_quote_asset<Quote>();
    event::emit(QuoteAssetDisabled {
        predict_id: object::id(predict),
        quote_asset: type_name::with_defining_ids<Quote>(),
    });
}

public(package) fun add_oracle_grid(
    predict: &mut Predict,
    oracle_id: ID,
    min_strike: u64,
    tick_size: u64,
    ctx: &mut TxContext,
) {
    predict.oracle_config.add_oracle_grid(oracle_id, min_strike, tick_size);
    let max_strike = min_strike + tick_size * constants::oracle_strike_grid_ticks!();
    predict.vault.init_oracle_matrix(oracle_id, min_strike, max_strike, tick_size, ctx);
}

/// Whether trading is currently paused.
public fun trading_paused(predict: &Predict): bool {
    predict.trading_paused
}

/// Get the base spread.
public fun base_spread(predict: &Predict): u64 {
    predict.pricing_config.base_spread()
}

/// Get the accepted quote asset whitelist.
public fun accepted_quotes(predict: &Predict): &VecSet<TypeName> {
    predict.treasury_config.accepted_quotes()
}

/// Get the min spread.
public fun min_spread(predict: &Predict): u64 {
    predict.pricing_config.min_spread()
}

/// Get the utilization multiplier.
public fun utilization_multiplier(predict: &Predict): u64 {
    predict.pricing_config.utilization_multiplier()
}

/// Get the max total exposure percentage.
public fun max_total_exposure_pct(predict: &Predict): u64 {
    predict.risk_config.max_total_exposure_pct()
}

/// Set trading pause state.
public(package) fun set_trading_paused(predict: &mut Predict, paused: bool) {
    predict.trading_paused = paused;
    event::emit(TradingPauseUpdated {
        predict_id: object::id(predict),
        paused,
    });
}

/// Set base spread.
public(package) fun set_base_spread(predict: &mut Predict, spread: u64) {
    predict.pricing_config.set_base_spread(spread);
    predict.emit_pricing_config_updated();
}

/// Set min spread.
public(package) fun set_min_spread(predict: &mut Predict, spread: u64) {
    predict.pricing_config.set_min_spread(spread);
    predict.emit_pricing_config_updated();
}

/// Set utilization multiplier.
public(package) fun set_utilization_multiplier(predict: &mut Predict, multiplier: u64) {
    predict.pricing_config.set_utilization_multiplier(multiplier);
    predict.emit_pricing_config_updated();
}

/// Set the global minimum allowed post-spread ask price at mint time.
public(package) fun set_min_ask_price(predict: &mut Predict, value: u64) {
    predict.pricing_config.set_min_ask_price(value);
    predict.emit_pricing_config_updated();
}

/// Set the global maximum allowed post-spread ask price at mint time.
public(package) fun set_max_ask_price(predict: &mut Predict, value: u64) {
    predict.pricing_config.set_max_ask_price(value);
    predict.emit_pricing_config_updated();
}

/// Set a per-oracle ask-bound override. Authorized by the oracle's own cap.
/// The override may only tighten the global bounds — never loosen them.
public(package) fun set_oracle_ask_bounds(
    predict: &mut Predict,
    oracle: &OracleSVI,
    cap: &OracleSVICap,
    min: u64,
    max: u64,
) {
    assert!(min >= predict.pricing_config.min_ask_price(), EAskBoundLooserThanGlobal);
    assert!(max <= predict.pricing_config.max_ask_price(), EAskBoundLooserThanGlobal);
    predict.oracle_config.set_oracle_ask_bounds(oracle, cap, min, max);
    event::emit(OracleAskBoundsSet {
        predict_id: object::id(predict),
        oracle_id: oracle.id(),
        min_ask_price: min,
        max_ask_price: max,
    });
}

/// Clear a per-oracle ask-bound override so the oracle inherits the global
/// default again. Authorized by the oracle's own cap.
public(package) fun clear_oracle_ask_bounds(
    predict: &mut Predict,
    oracle: &OracleSVI,
    cap: &OracleSVICap,
) {
    predict.oracle_config.clear_oracle_ask_bounds(oracle, cap);
    event::emit(OracleAskBoundsCleared {
        predict_id: object::id(predict),
        oracle_id: oracle.id(),
    });
}

/// Set max total exposure percentage.
public(package) fun set_max_total_exposure_pct(predict: &mut Predict, pct: u64) {
    predict.risk_config.set_max_total_exposure_pct(pct);
    event::emit(RiskConfigUpdated {
        predict_id: object::id(predict),
        max_total_exposure_pct: predict.risk_config.max_total_exposure_pct(),
    });
}

#[test_only]
/// Create a Predict object for testing without sharing it.
public(package) fun create_test_predict<Quote>(
    currency: &Currency<Quote>,
    ctx: &mut TxContext,
): Predict {
    let treasury_cap = coin::create_treasury_cap_for_testing<PLP>(ctx);
    let mut predict = Predict {
        id: object::new(ctx),
        vault: vault::new(ctx),
        treasury_cap,
        pricing_config: pricing_config::new(),
        risk_config: risk_config::new(),
        treasury_config: treasury_config::new(),
        oracle_config: oracle_config::new(ctx),
        trading_paused: false,
    };
    predict.enable_quote_asset<Quote>(currency);
    predict
}

#[test_only]
public(package) fun vault_mut(predict: &mut Predict): &mut Vault {
    &mut predict.vault
}

#[test_only]
public(package) fun oracle_config(predict: &Predict): &OracleConfig {
    &predict.oracle_config
}

#[test_only]
public(package) fun treasury_config(predict: &Predict): &TreasuryConfig {
    &predict.treasury_config
}

#[test_only]
public(package) fun vault_balance(predict: &Predict): u64 {
    predict.vault.balance()
}

// === Private Functions ===

fun redeem_internal<Quote>(
    predict: &mut Predict,
    manager: &mut PredictManager,
    oracle: &OracleSVI,
    key: MarketKey,
    quantity: u64,
    clock: &Clock,
    ctx: &mut TxContext,
): Coin<Quote> {
    assert!(quantity > 0, EZeroQuantity);
    predict.oracle_config.assert_key_matches(oracle, &key);
    oracle_config::assert_quoteable_oracle(oracle, clock);

    manager.decrease_position(key, quantity);

    predict.vault.remove_position(oracle.id(), key.is_up(), key.strike(), quantity);
    predict.refresh_oracle_risk(oracle);

    // Quote against the post-trade state so the seller is paid from the
    // liability after their position has been removed from the vault.
    let (_, payout) = predict.get_trade_amounts(oracle, key, quantity, clock);

    let payout_balance = predict.vault.dispense_payout<Quote>(payout);
    let payout_coin = payout_balance.into_coin(ctx);

    event::emit(PositionRedeemed {
        predict_id: object::id(predict),
        manager_id: object::id(manager),
        owner: manager.owner(),
        executor: ctx.sender(),
        quote_asset: type_name::with_defining_ids<Quote>(),
        oracle_id: key.oracle_id(),
        expiry: key.expiry(),
        strike: key.strike(),
        is_up: key.is_up(),
        quantity,
        payout,
        bid_price: math::div(payout, quantity),
        is_settled: oracle.is_settled(),
    });

    payout_coin
}

/// Returns the USDC value of `shares` at the given vault value.
fun shares_to_amount(predict: &Predict, shares: u64, vault_value: u64): u64 {
    let total = predict.treasury_cap.total_supply();
    if (shares == 0 || total == 0) return 0;
    if (total == shares) return vault_value;
    mul_div_round_down(shares, vault_value, total)
}

fun emit_pricing_config_updated(predict: &Predict) {
    event::emit(PricingConfigUpdated {
        predict_id: object::id(predict),
        base_spread: predict.pricing_config.base_spread(),
        min_spread: predict.pricing_config.min_spread(),
        utilization_multiplier: predict.pricing_config.utilization_multiplier(),
        min_ask_price: predict.pricing_config.min_ask_price(),
        max_ask_price: predict.pricing_config.max_ask_price(),
    });
}

/// Per-unit `(ask, bid)` for a single-strike position, post-spread (or settled
/// fair price when the oracle is settled).
fun trade_prices(predict: &Predict, oracle: &OracleSVI, key: MarketKey, clock: &Clock): (u64, u64) {
    predict.oracle_config.assert_key_matches(oracle, &key);
    oracle_config::assert_quoteable_oracle(oracle, clock);

    let up_price = oracle.compute_price(key.strike());
    if (oracle.is_settled()) {
        let fair_price = if (key.is_up()) {
            up_price
        } else {
            constants::float_scaling!() - up_price
        };
        return (fair_price, fair_price)
    };

    let spread = predict
        .pricing_config
        .quote_spread_from_fair_price(
            up_price,
            predict.vault.total_mtm(),
            predict.vault.balance(),
        );
    let up_bid = if (up_price > spread) {
        up_price - spread
    } else {
        0
    };
    let up_ask = (up_price + spread).min(constants::float_scaling!());
    let dn_bid = constants::float_scaling!() - up_ask;
    let dn_ask = constants::float_scaling!() - up_bid;

    if (key.is_up()) {
        (up_ask, up_bid)
    } else {
        (dn_ask, dn_bid)
    }
}

/// Per-unit `(ask, bid)` for a vertical range position, post-spread.
fun range_trade_prices(
    predict: &Predict,
    oracle: &OracleSVI,
    key: RangeKey,
    clock: &Clock,
): (u64, u64) {
    predict.oracle_config.assert_range_key_matches(oracle, &key);
    oracle_config::assert_quoteable_oracle(oracle, clock);

    // Fair range price = up(lower) − up(higher). UP price is monotone
    // non-increasing in strike, so this is always non-negative for a well-formed
    // key (`lower < higher`). Settled compute_price returns 1.0 if settlement >
    // strike, 0 otherwise, so the range evaluates to 1.0 iff settlement is in
    // the half-open band (lower, higher].
    let lower_up_price = oracle.compute_price(key.lower_strike());
    let higher_up_price = oracle.compute_price(key.higher_strike());
    let fair_price = lower_up_price - higher_up_price;

    if (oracle.is_settled()) {
        return (fair_price, fair_price)
    };

    let spread = predict
        .pricing_config
        .quote_spread_from_fair_price(
            fair_price,
            predict.vault.total_mtm(),
            predict.vault.balance(),
        );
    let ask = (fair_price + spread).min(constants::float_scaling!());
    let bid = if (fair_price > spread) {
        fair_price - spread
    } else {
        0
    };

    (ask, bid)
}

/// Resolve the effective ask-price bounds for an oracle: the per-oracle
/// override (if any) intersected with the global default. The intersection
/// guarantees the resolved bounds are never looser than the global, even if
/// admin tightens the global after a per-oracle override has been set.
fun resolve_ask_bounds(predict: &Predict, oracle_id: ID): (u64, u64) {
    let global_min = predict.pricing_config.min_ask_price();
    let global_max = predict.pricing_config.max_ask_price();
    let override = predict.oracle_config.ask_bounds_override(oracle_id);
    if (override.is_some()) {
        let bounds = override.destroy_some();
        (bounds.ask_bounds_min().max(global_min), bounds.ask_bounds_max().min(global_max))
    } else {
        (global_min, global_max)
    }
}

fun assert_mintable_ask(predict: &Predict, oracle_id: ID, ask_price: u64) {
    let (min_ask, max_ask) = predict.resolve_ask_bounds(oracle_id);
    assert!(ask_price >= min_ask && ask_price <= max_ask, EAskPriceOutOfBounds);
}

fun refresh_oracle_risk(predict: &mut Predict, oracle: &OracleSVI) {
    let oracle_id = oracle.id();
    let (min_strike, max_strike) = predict.vault.oracle_strike_range(oracle_id);
    if (min_strike == 0 && max_strike == 0) {
        // `(0, 0)` means this oracle has never had any minted exposure.
        predict.vault.set_mtm(oracle_id, 0);
        return
    };
    // Historical minted bounds do not shrink after a full unwind, so an empty
    // but previously touched book still rebuilds over the old range and
    // evaluates to 0 from zero `q_up` / `q_dn`.
    if (oracle.is_settled()) {
        predict.vault.set_mtm_with_settlement(oracle_id, oracle.settlement_price().destroy_some());
        return
    };
    let curve = predict.oracle_config.build_curve(oracle, min_strike, max_strike);
    predict.vault.set_mtm_with_curve(oracle_id, &curve);
}
