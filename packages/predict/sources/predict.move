// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Main entry point for the DeepBook Predict protocol.
///
/// This module orchestrates user actions across the vault, market config,
/// manager, and pricing layers. It owns public trading and LP flows, while the
/// lower modules provide isolated state machines and pricing primitives.
///
/// Trading uses one fair market_oracle price plus an explicit fee. The fee is charged
/// on mint and pre-settlement redeem, routed through `FeeReserve`, and reported
/// as `fee_amount` in trade events. Settlement redemption is zero-fee.
module deepbook_predict::predict;

use deepbook::math;
use deepbook_predict::{
    constants,
    fee_reserve::{Self, FeeReserve},
    market_config::{Self, MarketConfig},
    market_oracle::{Self, MarketOracle, MarketOracleCap},
    math::mul_div_round_down,
    plp::PLP,
    predict_manager::PredictManager,
    pricing::{Self, CurvePoint, PricingConfig, UnitQuote},
    pyth_source::PythSource,
    range_key::RangeKey,
    rate_limiter::{Self, RateLimiter},
    risk_config::{Self, RiskConfig},
    treasury_config::{Self, TreasuryConfig},
    vault::{Self, Vault}
};
use std::{string::String, type_name::{Self, TypeName}};
use sui::{
    balance::Balance,
    clock::Clock,
    coin::{Self, Coin, TreasuryCap},
    coin_registry::Currency,
    derived_object,
    event,
    vec_set::VecSet
};

const ETradingPaused: u64 = 0;
const ENotOwner: u64 = 1;
const EWithdrawExceedsAvailable: u64 = 2;
const EZeroQuantity: u64 = 3;
const EZeroAmount: u64 = 4;
const EZeroVaultValue: u64 = 5;
const EZeroSharesMinted: u64 = 6;
const ERangeKeyOracleMismatch: u64 = 8;
const EOracleNotSettled: u64 = 9;
const ERangeKeyExpiryMismatch: u64 = 10;
const EPredictAlreadyCreated: u64 = 11;

/// Emitted when a position interval is minted.
/// `cost` is fair value plus `fee_amount`; `fee_rate` is per-unit.
public struct PositionMinted has copy, drop, store {
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
    fee_amount: u64,
}

/// Emitted when a position interval is redeemed.
/// `payout` is net of fee for live redemptions and settlement value when settled.
public struct PositionRedeemed has copy, drop, store {
    predict_id: ID,
    manager_id: ID,
    owner: address,
    executor: address,
    quote_asset: TypeName,
    oracle_id: ID,
    expiry: u64,
    lower_strike: u64,
    higher_strike: u64,
    quantity: u64,
    payout: u64,
    fee_amount: u64,
    is_settled: bool,
}

/// Emitted when global trading pause state changes.
public struct TradingPauseUpdated has copy, drop, store {
    predict_id: ID,
    paused: bool,
}

/// Emitted when pricing configuration changes.
public struct PricingConfigUpdated has copy, drop, store {
    predict_id: ID,
    base_fee: u64,
    min_fee: u64,
    utilization_multiplier: u64,
    min_ask_price: u64,
    max_ask_price: u64,
}

/// Emitted when fee reserve distribution shares change.
public struct FeeReserveConfigUpdated has copy, drop, store {
    predict_id: ID,
    lp_fee_share: u64,
    protocol_fee_share: u64,
    insurance_fee_share: u64,
}

/// Emitted when risk configuration changes.
public struct RiskConfigUpdated has copy, drop, store {
    predict_id: ID,
    max_total_exposure_pct: u64,
    mtm_freshness_ms: u64,
}

/// Emitted when a quote asset is enabled for new inflows.
public struct QuoteAssetEnabled has copy, drop, store {
    predict_id: ID,
    quote_asset: TypeName,
}

/// Emitted when a quote asset is disabled for new inflows.
public struct QuoteAssetDisabled has copy, drop, store {
    predict_id: ID,
    quote_asset: TypeName,
}

/// Emitted when LP capital is supplied to the vault.
public struct Supplied has copy, drop, store {
    predict_id: ID,
    supplier: address,
    quote_asset: TypeName,
    amount: u64,
    shares_minted: u64,
}

/// Emitted when LP capital is withdrawn from the vault.
public struct Withdrawn has copy, drop, store {
    predict_id: ID,
    withdrawer: address,
    quote_asset: TypeName,
    amount: u64,
    shares_burned: u64,
}

/// Emitted when admin-tuned market_oracle freshness thresholds change.
public struct MarketFreshnessConfigUpdated has copy, drop, store {
    predict_id: ID,
    pyth_spot_freshness_ms: u64,
    block_scholes_prices_freshness_ms: u64,
    block_scholes_svi_freshness_ms: u64,
}

/// Emitted when an asset is bound to a Pyth Lazer feed id.
public struct OracleFeedIdSet has copy, drop, store {
    predict_id: ID,
    asset: String,
    pyth_lazer_feed_id: u64,
}

/// Main shared object for the DeepBook Predict protocol.
public struct Predict has key {
    id: UID,
    /// Vault holding treasury balances and tracking exposure
    vault: Vault,
    /// Protocol and insurance fee reserves excluded from LP vault value.
    fee_reserve: FeeReserve,
    /// Treasury cap for minting/burning PLP tokens
    treasury_cap: TreasuryCap<PLP>,
    /// Pricing configuration (admin-controlled)
    pricing_config: PricingConfig,
    /// Risk limits (admin-controlled)
    risk_config: RiskConfig,
    /// Treasury asset whitelist and related treasury policy state
    treasury_config: TreasuryConfig,
    /// Market source bindings and oracle freshness policy.
    market_config: MarketConfig,
    /// Rate limiter for LP withdrawals
    withdrawal_limiter: RateLimiter,
    /// Whether trading (mint) is globally paused
    trading_paused: bool,
}

/// Derived-object key for the singleton Predict shared object per quote type.
public struct PredictKey<phantom T>() has copy, drop, store;

// === Public Functions ===

/// Mint a position interval `(lower, higher]` using an enabled quote asset.
/// The user pays the fair price plus per-unit fee up front; the vault tracks
/// bounded liability natively via strike-matrix interval accounting.
public fun mint<Quote>(
    predict: &mut Predict,
    manager: &mut PredictManager,
    market_oracle: &MarketOracle,
    pyth: &PythSource,
    key: RangeKey,
    quantity: u64,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    assert!(ctx.sender() == manager.owner(), ENotOwner);
    mint_internal<Quote>(predict, manager, market_oracle, pyth, key, quantity, clock, ctx);
}

/// Redeem a position interval.
/// Live payout is post-trade fair value less fee. Settlement redemption is
/// zero-fee and pays `quantity` if settlement landed in `(lower, higher]`.
public fun redeem<Quote>(
    predict: &mut Predict,
    manager: &mut PredictManager,
    market_oracle: &MarketOracle,
    pyth: &PythSource,
    key: RangeKey,
    quantity: u64,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    assert!(ctx.sender() == manager.owner(), ENotOwner);
    let payout_coin = if (market_oracle.is_settled()) {
        redeem_settled_internal<Quote>(predict, manager, market_oracle, key, quantity, clock, ctx)
    } else {
        redeem_live_internal<Quote>(
            predict,
            manager,
            market_oracle,
            pyth,
            key,
            quantity,
            clock,
            ctx,
        )
    };
    manager.deposit(payout_coin, ctx);
}

/// Sell a settled position interval permissionlessly into the PredictManager's balance.
public fun redeem_permissionless<Quote>(
    predict: &mut Predict,
    manager: &mut PredictManager,
    market_oracle: &MarketOracle,
    key: RangeKey,
    quantity: u64,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    assert!(market_oracle.is_settled(), EOracleNotSettled);
    let payout_coin = redeem_settled_internal<Quote>(
        predict,
        manager,
        market_oracle,
        key,
        quantity,
        clock,
        ctx,
    );
    manager.deposit_permissionless(payout_coin, ctx);
}

/// Supply an accepted quote asset into the vault. Returns LP tokens representing shares.
/// First depositor gets shares 1:1. Subsequent depositors get shares
/// proportional to their deposit relative to current vault value.
/// Supply an enabled quote asset into the shared LP pool.
public fun supply<Quote>(
    predict: &mut Predict,
    coin: Coin<Quote>,
    clock: &Clock,
    ctx: &mut TxContext,
): Coin<PLP> {
    predict.vault.assert_unsettled_mtm_fresh(predict.risk_config.mtm_freshness_ms(), clock);
    let amount = coin.value();
    assert!(amount > 0, EZeroAmount);
    predict.treasury_config.assert_quote_asset<Quote>();

    let vault_value = predict.vault.vault_value();
    predict.vault.accept_payment(coin.into_balance());
    predict.withdrawal_limiter.record_deposit(amount, clock);

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
    clock: &Clock,
    ctx: &mut TxContext,
): Coin<Quote> {
    predict.vault.assert_unsettled_mtm_fresh(predict.risk_config.mtm_freshness_ms(), clock);
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
    predict.withdrawal_limiter.consume(amount, clock);
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

/// Keeper/ops hook for syncing one market_oracle's cached MTM into the vault. This is
/// used to keep LP supply/withdraw accounting fresh across unsettled exposed
/// oracles; trade mutations refresh the touched market_oracle inline.
public fun refresh_oracle_mtm(
    predict: &mut Predict,
    market_oracle: &MarketOracle,
    pyth: &PythSource,
    clock: &Clock,
) {
    let oracle_id = market_oracle.id();
    if (market_oracle.is_settled()) {
        let settlement = market_oracle.settlement_price().destroy_some();
        predict.vault.apply_settled_oracle_valuation(oracle_id, settlement, clock);
    } else {
        let (min_strike, max_strike) = predict.vault.valuation_strike_range(oracle_id);
        if (min_strike == 0 && max_strike == 0) {
            return
        } else {
            let curve = predict.build_live_curve(
                market_oracle,
                pyth,
                clock,
                min_strike,
                max_strike,
            );
            predict.vault.apply_live_valuation(oracle_id, curve, clock);
        };
    };
}

/// Compact a settled market_oracle's dense strike matrix into constant-size state.
/// Only an authorized market_oracle operator can trigger compaction.
public fun compact_settled_oracle(
    predict: &mut Predict,
    market_oracle: &MarketOracle,
    oracle_cap: &MarketOracleCap,
) {
    market_oracle::assert_authorized_cap(market_oracle, oracle_cap);
    assert!(market_oracle.is_settled(), EOracleNotSettled);
    let settlement = market_oracle.settlement_price().destroy_some();
    predict.vault.compact_settled_oracle_if_needed(market_oracle.id(), settlement);
}

/// Per-unit `(fair_price, fee_rate)` quote for a position interval.
/// `fee_rate` is an absolute price increment in FLOAT_SCALING, not bps.
public fun quote_unit_price(
    predict: &Predict,
    market_oracle: &MarketOracle,
    pyth: &PythSource,
    key: RangeKey,
    clock: &Clock,
): (u64, u64) {
    predict.assert_range_key_matches(market_oracle, &key);
    let quote = predict.quote_unit(market_oracle, pyth, &key, clock);
    (quote.fair_price(), quote.fee_rate())
}

/// Return market_oracle IDs whose unsettled exposure must be refreshed before LP flows.
public fun unsettled_exposed_oracles(predict: &Predict): &vector<ID> {
    predict.vault.unsettled_exposed_oracles()
}

/// Global all-in mint price bounds.
public fun ask_bounds(predict: &Predict): (u64, u64) {
    (predict.pricing_config.min_ask_price(), predict.pricing_config.max_ask_price())
}

/// Whether trading is currently paused.
public fun trading_paused(predict: &Predict): bool {
    predict.trading_paused
}

/// Get the base fee.
public fun base_fee(predict: &Predict): u64 {
    predict.pricing_config.base_fee()
}

/// Get the accepted quote asset whitelist.
public fun accepted_quotes(predict: &Predict): &VecSet<TypeName> {
    predict.treasury_config.accepted_quotes()
}

/// Get the min fee.
public fun min_fee(predict: &Predict): u64 {
    predict.pricing_config.min_fee()
}

/// Get the utilization multiplier.
public fun utilization_multiplier(predict: &Predict): u64 {
    predict.pricing_config.utilization_multiplier()
}

/// Get the max total exposure percentage.
public fun max_total_exposure_pct(predict: &Predict): u64 {
    predict.risk_config.max_total_exposure_pct()
}

/// Get the MTM freshness threshold used for LP supply/withdraw gating.
public fun mtm_freshness_ms(predict: &Predict): u64 {
    predict.risk_config.mtm_freshness_ms()
}

/// Returns the currently available withdrawal amount.
public fun available_withdrawal(predict: &Predict, clock: &Clock): u64 {
    predict.withdrawal_limiter.available_withdrawal(clock)
}

/// Return the official total fee amount accrued across all charged Predict trades.
public fun total_fees_accrued(predict: &Predict): u64 {
    predict.fee_reserve.total_fees_accrued()
}

/// Return total LP fee share accrued across all charged Predict trades.
public fun lp_fees_accrued(predict: &Predict): u64 {
    predict.fee_reserve.lp_fees_accrued()
}

/// Return total protocol fee share accrued across all charged Predict trades.
public fun protocol_fees_accrued(predict: &Predict): u64 {
    predict.fee_reserve.protocol_fees_accrued()
}

/// Return total insurance fee share accrued across all charged Predict trades.
public fun insurance_fees_accrued(predict: &Predict): u64 {
    predict.fee_reserve.insurance_fees_accrued()
}

/// Return concrete protocol fee reserve balance for asset type `Quote`.
public fun protocol_fee_asset_balance<Quote>(predict: &Predict): u64 {
    predict.fee_reserve.protocol_asset_balance<Quote>()
}

/// Return concrete insurance fee reserve balance for asset type `Quote`.
public fun insurance_fee_asset_balance<Quote>(predict: &Predict): u64 {
    predict.fee_reserve.insurance_asset_balance<Quote>()
}

/// Return the current LP fee share.
public fun lp_fee_share(predict: &Predict): u64 {
    predict.fee_reserve.lp_fee_share()
}

/// Return the current protocol fee share.
public fun protocol_fee_share(predict: &Predict): u64 {
    predict.fee_reserve.protocol_fee_share()
}

/// Return the current insurance fee share.
public fun insurance_fee_share(predict: &Predict): u64 {
    predict.fee_reserve.insurance_fee_share()
}

// === Public-Package Functions ===

/// Create and share the Predict object. Returns its ID.
public(package) fun create<Quote>(
    registry_uid: &mut UID,
    currency: &Currency<Quote>,
    treasury_cap: TreasuryCap<PLP>,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    assert!(!derived_object::exists(registry_uid, PredictKey<Quote>()), EPredictAlreadyCreated);
    let mut predict = Predict {
        id: derived_object::claim(registry_uid, PredictKey<Quote>()),
        vault: vault::new(ctx),
        fee_reserve: fee_reserve::new(ctx),
        treasury_cap,
        pricing_config: pricing::new(),
        risk_config: risk_config::new(),
        treasury_config: treasury_config::new(),
        market_config: market_config::new(ctx),
        // Withdrawal rate limiter starts disabled. Admin must call
        // update_withdrawal_limiter() then enable_withdrawal_limiter()
        // to activate, configuring capacity and rate for the quote asset.
        withdrawal_limiter: rate_limiter::new(clock),
        trading_paused: false,
    };
    predict.enable_quote_asset<Quote>(currency);
    transfer::share_object(predict);
}

/// Enable a quote asset for new Predict inflows.
public(package) fun enable_quote_asset<Quote>(predict: &mut Predict, currency: &Currency<Quote>) {
    predict.treasury_config.add_quote_asset<Quote>(currency);
    event::emit(QuoteAssetEnabled {
        predict_id: object::id(predict),
        quote_asset: type_name::with_defining_ids<Quote>(),
    });
}

/// Disable a quote asset for new Predict inflows.
public(package) fun disable_quote_asset<Quote>(predict: &mut Predict) {
    predict.treasury_config.remove_quote_asset<Quote>();
    event::emit(QuoteAssetDisabled {
        predict_id: object::id(predict),
        quote_asset: type_name::with_defining_ids<Quote>(),
    });
}

/// Initialize vault exposure state for a newly created market oracle.
public(package) fun init_market_oracle_exposure(
    predict: &mut Predict,
    oracle_id: ID,
    expiry: u64,
    min_strike: u64,
    tick_size: u64,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    let max_strike = min_strike + tick_size * constants::oracle_strike_grid_ticks!();
    predict
        .vault
        .init_oracle_matrix(oracle_id, expiry, min_strike, max_strike, tick_size, clock, ctx);
}

/// Set trading pause state.
public(package) fun set_trading_paused(predict: &mut Predict, paused: bool) {
    predict.trading_paused = paused;
    event::emit(TradingPauseUpdated {
        predict_id: object::id(predict),
        paused,
    });
}

/// Set base fee.
public(package) fun set_base_fee(predict: &mut Predict, fee: u64) {
    predict.pricing_config.set_base_fee(fee);
    predict.emit_pricing_config_updated();
}

/// Set min fee.
public(package) fun set_min_fee(predict: &mut Predict, fee: u64) {
    predict.pricing_config.set_min_fee(fee);
    predict.emit_pricing_config_updated();
}

/// Set utilization multiplier.
public(package) fun set_utilization_multiplier(predict: &mut Predict, multiplier: u64) {
    predict.pricing_config.set_utilization_multiplier(multiplier);
    predict.emit_pricing_config_updated();
}

/// Set fee distribution shares.
public(package) fun set_fee_shares(
    predict: &mut Predict,
    lp_fee_share: u64,
    protocol_fee_share: u64,
    insurance_fee_share: u64,
) {
    predict.fee_reserve.set_fee_shares(lp_fee_share, protocol_fee_share, insurance_fee_share);
    event::emit(FeeReserveConfigUpdated {
        predict_id: object::id(predict),
        lp_fee_share,
        protocol_fee_share,
        insurance_fee_share,
    });
}

/// Set the global minimum allowed all-in mint price.
public(package) fun set_min_ask_price(predict: &mut Predict, value: u64) {
    predict.pricing_config.set_min_ask_price(value);
    predict.emit_pricing_config_updated();
}

/// Set the global maximum allowed all-in mint price.
public(package) fun set_max_ask_price(predict: &mut Predict, value: u64) {
    predict.pricing_config.set_max_ask_price(value);
    predict.emit_pricing_config_updated();
}

/// Set max total exposure percentage.
public(package) fun set_max_total_exposure_pct(predict: &mut Predict, pct: u64) {
    predict.risk_config.set_max_total_exposure_pct(pct);
    predict.emit_risk_config_updated();
}

/// Update the MTM freshness threshold used for LP supply/withdraw gating.
public(package) fun set_mtm_freshness_ms(predict: &mut Predict, value: u64) {
    predict.risk_config.set_mtm_freshness_ms(value);
    predict.emit_risk_config_updated();
}

/// Update the admin-tuned Pyth spot freshness threshold used to seed new
/// market oracles. Does NOT retroactively update existing oracles.
public(package) fun set_pyth_spot_freshness_ms(predict: &mut Predict, value: u64) {
    predict.market_config.set_pyth_spot_freshness_ms(value);
    predict.emit_market_freshness_config_updated();
}

/// Update the admin-tuned Block Scholes spot/forward freshness threshold used to seed new oracles.
public(package) fun set_block_scholes_prices_freshness_ms(predict: &mut Predict, value: u64) {
    predict.market_config.set_block_scholes_prices_freshness_ms(value);
    predict.emit_market_freshness_config_updated();
}

/// Update the admin-tuned Block Scholes SVI freshness threshold used to seed new oracles.
public(package) fun set_block_scholes_svi_freshness_ms(predict: &mut Predict, value: u64) {
    predict.market_config.set_block_scholes_svi_freshness_ms(value);
    predict.emit_market_freshness_config_updated();
}

/// Bind `asset → pyth_lazer_feed_id` so `create_market_oracle` can infer the feed
/// id from the underlying asset instead of taking it as a PTB arg. Does NOT
/// retroactively update existing oracles — they keep the feed id snapshotted
/// at their own creation time.
public(package) fun set_asset_feed_id(
    predict: &mut Predict,
    asset: String,
    pyth_lazer_feed_id: u64,
) {
    predict.market_config.set_asset_feed_id(asset, pyth_lazer_feed_id);
    event::emit(OracleFeedIdSet {
        predict_id: object::id(predict),
        asset,
        pyth_lazer_feed_id,
    });
}

/// Update withdrawal rate limiter capacity and refill rate.
public(package) fun update_withdrawal_limiter(
    predict: &mut Predict,
    capacity: u64,
    refill_rate_per_ms: u64,
    clock: &Clock,
) {
    predict.withdrawal_limiter.update_config(capacity, refill_rate_per_ms, clock);
}

/// Enable the withdrawal rate limiter.
public(package) fun enable_withdrawal_limiter(predict: &mut Predict, clock: &Clock) {
    predict.withdrawal_limiter.enable(clock);
}

/// Disable the withdrawal rate limiter.
public(package) fun disable_withdrawal_limiter(predict: &mut Predict) {
    predict.withdrawal_limiter.disable();
}

/// Snapshot the admin-tuned market_oracle bounds at `create_market_oracle` time.
public(package) fun build_market_oracle_bounds(
    predict: &Predict,
): market_oracle::MarketOracleBounds {
    predict.market_config.build_market_oracle_bounds()
}

/// Resolve the admin-registered Pyth Lazer feed id for `asset`. Aborts with
/// `market_config::EFeedIdNotConfigured` if no entry exists — admin must call
/// `set_asset_feed_id` at least once per underlying before its first market_oracle
/// can be created. Returned as `u64` for type consistency with the rest of
/// the admin-config surface; narrowed to `u32` at `registry::create_market_oracle`.
public(package) fun resolve_feed_id(predict: &Predict, asset: String): u64 {
    predict.market_config.resolve_feed_id(asset)
}

// === Private Functions ===

/// Assert a range key matches the market oracle identity, expiry, and configured grid.
fun assert_range_key_matches(predict: &Predict, market_oracle: &MarketOracle, key: &RangeKey) {
    assert!(key.oracle_id() == market_oracle.id(), ERangeKeyOracleMismatch);
    assert!(key.expiry() == market_oracle.expiry(), ERangeKeyExpiryMismatch);
    predict.vault.assert_range_key_matches(key);
}

/// Shared mint path after caller authorization.
fun mint_internal<Quote>(
    predict: &mut Predict,
    manager: &mut PredictManager,
    market_oracle: &MarketOracle,
    pyth: &PythSource,
    key: RangeKey,
    quantity: u64,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    predict.apply_mint_delta<Quote>(
        manager,
        market_oracle,
        pyth,
        key,
        quantity,
        clock,
    );

    let (principal_amount, fee_amount) = predict.quote_mint_amounts(
        market_oracle,
        pyth,
        key,
        quantity,
        clock,
    );
    let cost = principal_amount + fee_amount;

    let mut payment = manager.withdraw<Quote>(cost, ctx).into_balance();
    let fee_payment = payment.split(fee_amount);
    predict.apply_fee(fee_payment);
    predict.vault.accept_payment(payment);
    predict.vault.assert_total_exposure(predict.risk_config.max_total_exposure_pct());

    event::emit(PositionMinted {
        predict_id: object::id(predict),
        manager_id: object::id(manager),
        trader: manager.owner(),
        quote_asset: type_name::with_defining_ids<Quote>(),
        oracle_id: key.oracle_id(),
        expiry: key.expiry(),
        lower_strike: key.lower_strike(),
        higher_strike: key.higher_strike(),
        quantity,
        cost,
        fee_amount,
    });
}

/// Shared live redemption path.
fun redeem_live_internal<Quote>(
    predict: &mut Predict,
    manager: &mut PredictManager,
    market_oracle: &MarketOracle,
    pyth: &PythSource,
    key: RangeKey,
    quantity: u64,
    clock: &Clock,
    ctx: &mut TxContext,
): Coin<Quote> {
    predict.apply_live_redeem_delta(manager, market_oracle, pyth, key, quantity, clock);

    let (principal_amount, fee_amount) = predict.quote_live_redeem_amounts(
        market_oracle,
        pyth,
        key,
        quantity,
        clock,
    );
    let mut payout_balance = predict.vault.dispense_payout<Quote>(principal_amount);
    let fee_balance = payout_balance.split(fee_amount);
    predict.apply_fee(fee_balance);

    let payout_coin = payout_balance.into_coin(ctx);

    predict.emit_position_redeemed<Quote>(
        manager,
        key,
        quantity,
        payout_coin.value(),
        fee_amount,
        false,
        ctx,
    );

    payout_coin
}

/// Shared settled redemption path.
fun redeem_settled_internal<Quote>(
    predict: &mut Predict,
    manager: &mut PredictManager,
    market_oracle: &MarketOracle,
    key: RangeKey,
    quantity: u64,
    clock: &Clock,
    ctx: &mut TxContext,
): Coin<Quote> {
    let settlement = market_oracle.settlement_price().destroy_some();
    predict.apply_settled_redeem_delta(manager, market_oracle, key, quantity, settlement, clock);

    let payout_amount = key.settled_payout(settlement, quantity);
    let payout_coin = predict.vault.dispense_payout<Quote>(payout_amount).into_coin(ctx);
    predict.emit_position_redeemed<Quote>(
        manager,
        key,
        quantity,
        payout_coin.value(),
        0,
        true,
        ctx,
    );

    payout_coin
}

/// Apply the position, vault, and risk-state delta for a mint before pricing
/// against the post-trade vault state.
fun apply_mint_delta<Quote>(
    predict: &mut Predict,
    manager: &mut PredictManager,
    market_oracle: &MarketOracle,
    pyth: &PythSource,
    key: RangeKey,
    quantity: u64,
    clock: &Clock,
) {
    assert!(quantity > 0, EZeroQuantity);
    predict.assert_range_key_matches(market_oracle, &key);
    assert!(!predict.trading_paused, ETradingPaused);
    predict.treasury_config.assert_quote_asset<Quote>();

    let (min_strike, max_strike) = predict.vault.valuation_strike_range(market_oracle.id());
    let (min_strike, max_strike) = key.extend_strike_range(min_strike, max_strike);
    let curve = predict.build_live_curve(market_oracle, pyth, clock, min_strike, max_strike);
    manager.increase_position(key, quantity);
    predict.vault.insert_live_range(key, quantity, curve, clock);
}

/// Apply the position, vault, and risk-state delta for a live redeem before
/// pricing against the post-trade vault state.
fun apply_live_redeem_delta(
    predict: &mut Predict,
    manager: &mut PredictManager,
    market_oracle: &MarketOracle,
    pyth: &PythSource,
    key: RangeKey,
    quantity: u64,
    clock: &Clock,
) {
    assert!(quantity > 0, EZeroQuantity);
    predict.assert_range_key_matches(market_oracle, &key);

    let (min_strike, max_strike) = predict.vault.valuation_strike_range(market_oracle.id());
    let (min_strike, max_strike) = key.extend_strike_range(min_strike, max_strike);
    let curve = predict.build_live_curve(market_oracle, pyth, clock, min_strike, max_strike);
    manager.decrease_position(key, quantity);
    predict.vault.remove_live_range(key, quantity, curve, clock);
}

/// Apply the position, vault, and risk-state delta for a settled redeem before
/// pricing against the post-trade vault state.
fun apply_settled_redeem_delta(
    predict: &mut Predict,
    manager: &mut PredictManager,
    market_oracle: &MarketOracle,
    key: RangeKey,
    quantity: u64,
    settlement: u64,
    clock: &Clock,
) {
    assert!(quantity > 0, EZeroQuantity);
    predict.assert_range_key_matches(market_oracle, &key);
    assert!(market_oracle.is_settled(), EOracleNotSettled);

    manager.decrease_position(key, quantity);
    predict.vault.remove_settled_range(key, quantity, settlement, clock);
}

fun quote_mint_amounts(
    predict: &Predict,
    market_oracle: &MarketOracle,
    pyth: &PythSource,
    key: RangeKey,
    quantity: u64,
    clock: &Clock,
): (u64, u64) {
    let quote = predict.quote_live_unit(market_oracle, pyth, &key, clock);
    predict.assert_mint_quote_allowed(&quote);

    let principal_amount = math::mul(quote.fair_price(), quantity);
    let fee_amount = math::mul(quote.fee_rate(), quantity);

    (principal_amount, fee_amount)
}

fun quote_live_redeem_amounts(
    predict: &Predict,
    market_oracle: &MarketOracle,
    pyth: &PythSource,
    key: RangeKey,
    quantity: u64,
    clock: &Clock,
): (u64, u64) {
    let quote = predict.quote_live_unit(market_oracle, pyth, &key, clock);

    let principal_amount = math::mul(quote.fair_price(), quantity);
    let fee_amount = math::mul(quote.fee_rate(), quantity);
    let fee_amount = fee_amount.min(principal_amount);

    (principal_amount, fee_amount)
}

fun quote_unit(
    predict: &Predict,
    market_oracle: &MarketOracle,
    pyth: &PythSource,
    key: &RangeKey,
    clock: &Clock,
): UnitQuote {
    if (market_oracle.is_settled()) {
        let settlement = market_oracle.settlement_price().destroy_some();
        let fair_price = pricing::compute_settled_range_price(
            settlement,
            key.lower_strike(),
            key.higher_strike(),
        );
        pricing::quote_zero_fee(fair_price)
    } else {
        predict.quote_live_unit(market_oracle, pyth, key, clock)
    }
}

fun quote_live_unit(
    predict: &Predict,
    market_oracle: &MarketOracle,
    pyth: &PythSource,
    key: &RangeKey,
    clock: &Clock,
): UnitQuote {
    pricing::quote_live_range(
        &predict.pricing_config,
        market_oracle,
        pyth,
        clock,
        key,
        predict.vault.total_mtm(),
        predict.vault.balance(),
    )
}

fun build_live_curve(
    predict: &Predict,
    market_oracle: &MarketOracle,
    pyth: &PythSource,
    clock: &Clock,
    min_strike: u64,
    max_strike: u64,
): vector<CurvePoint> {
    let oracle_id = market_oracle.id();
    let (grid_min, grid_tick, grid_max) = predict.vault.grid_params(oracle_id);
    pricing::build_live_curve(
        market_oracle,
        pyth,
        clock,
        grid_min,
        grid_tick,
        grid_max,
        min_strike,
        max_strike,
    )
}

/// Returns the USDC value of `shares` at the given vault value.
fun shares_to_amount(predict: &Predict, shares: u64, vault_value: u64): u64 {
    let total = predict.treasury_cap.total_supply();
    if (shares == 0 || total == 0) return 0;
    if (total == shares) return vault_value;
    mul_div_round_down(shares, vault_value, total)
}

/// Route a full fee balance through the fee reserve and deposit the LP share into the vault.
/// Zero fees are ignored so settlement redemption does not emit fee accruals.
fun apply_fee<Quote>(predict: &mut Predict, fee_balance: Balance<Quote>) {
    if (fee_balance.value() == 0) {
        fee_balance.destroy_zero();
        return
    };
    let predict_id = object::id(predict);
    let lp_fee = predict.fee_reserve.accrue_fee(fee_balance, predict_id);
    predict.vault.accept_payment(lp_fee);
}

fun emit_position_redeemed<Quote>(
    predict: &Predict,
    manager: &PredictManager,
    key: RangeKey,
    quantity: u64,
    payout: u64,
    fee_amount: u64,
    is_settled: bool,
    ctx: &TxContext,
) {
    event::emit(PositionRedeemed {
        predict_id: object::id(predict),
        manager_id: object::id(manager),
        owner: manager.owner(),
        executor: ctx.sender(),
        quote_asset: type_name::with_defining_ids<Quote>(),
        oracle_id: key.oracle_id(),
        expiry: key.expiry(),
        lower_strike: key.lower_strike(),
        higher_strike: key.higher_strike(),
        quantity,
        payout,
        fee_amount,
        is_settled,
    });
}

/// Emit the full current pricing-config snapshot.
fun emit_pricing_config_updated(predict: &Predict) {
    event::emit(PricingConfigUpdated {
        predict_id: object::id(predict),
        base_fee: predict.pricing_config.base_fee(),
        min_fee: predict.pricing_config.min_fee(),
        utilization_multiplier: predict.pricing_config.utilization_multiplier(),
        min_ask_price: predict.pricing_config.min_ask_price(),
        max_ask_price: predict.pricing_config.max_ask_price(),
    });
}

/// Emit the full current risk-config snapshot.
fun emit_risk_config_updated(predict: &Predict) {
    event::emit(RiskConfigUpdated {
        predict_id: object::id(predict),
        max_total_exposure_pct: predict.risk_config.max_total_exposure_pct(),
        mtm_freshness_ms: predict.risk_config.mtm_freshness_ms(),
    });
}

/// Emit the full current market_oracle freshness config snapshot.
fun emit_market_freshness_config_updated(predict: &Predict) {
    event::emit(MarketFreshnessConfigUpdated {
        predict_id: object::id(predict),
        pyth_spot_freshness_ms: predict.market_config.pyth_spot_freshness_ms(),
        block_scholes_prices_freshness_ms: predict
            .market_config
            .block_scholes_prices_freshness_ms(),
        block_scholes_svi_freshness_ms: predict.market_config.block_scholes_svi_freshness_ms(),
    });
}

/// Assert a mint quote can be traded under global ask bounds.
fun assert_mint_quote_allowed(predict: &Predict, quote: &UnitQuote) {
    pricing::assert_mint_quote_allowed(&predict.pricing_config, quote);
}

// === Test-Only Functions ===

#[test_only]
/// Create a Predict object for testing without sharing it.
public(package) fun create_test_predict<Quote>(
    currency: &Currency<Quote>,
    ctx: &mut TxContext,
): Predict {
    let treasury_cap = coin::create_treasury_cap_for_testing<PLP>(ctx);
    let clock = sui::clock::create_for_testing(ctx);
    let mut predict = Predict {
        id: object::new(ctx),
        vault: vault::new(ctx),
        fee_reserve: fee_reserve::new(ctx),
        treasury_cap,
        pricing_config: pricing::new(),
        risk_config: risk_config::new(),
        treasury_config: treasury_config::new(),
        market_config: market_config::new(ctx),
        withdrawal_limiter: rate_limiter::new(&clock),
        trading_paused: false,
    };
    predict.enable_quote_asset<Quote>(currency);
    clock.destroy_for_testing();
    predict
}

#[test_only]
/// Return mutable vault access for tests.
public(package) fun vault_mut(predict: &mut Predict): &mut Vault {
    &mut predict.vault
}

#[test_only]
/// Return market_oracle config access for tests.
public(package) fun market_config(predict: &Predict): &MarketConfig {
    &predict.market_config
}

#[test_only]
/// Return treasury config access for tests.
public(package) fun treasury_config(predict: &Predict): &TreasuryConfig {
    &predict.treasury_config
}

#[test_only]
/// Return aggregate vault balance for tests.
public(package) fun vault_balance(predict: &Predict): u64 {
    predict.vault.balance()
}
