// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Main entry point for the DeepBook Predict protocol.
///
/// This module orchestrates user actions across the vault, oracle config,
/// manager, and pricing layers. It owns public trading and LP flows, while the
/// lower modules provide isolated state machines and pricing primitives.
///
/// Trading uses one fair oracle price plus an explicit fee. The fee is charged
/// on mint and pre-settlement redeem, routed through `FeeReserve`, and reported
/// as `fee_amount` in trade events. Settlement redemption is zero-fee.
module deepbook_predict::predict;

use deepbook::math;
use deepbook_predict::{
    constants,
    fee_reserve::{Self, FeeReserve},
    math::mul_div_round_down,
    oracle::{Self, OracleSVI, OracleSVICap},
    oracle_config::{Self, OracleConfig},
    plp::PLP,
    predict_manager::PredictManager,
    pricing_config::{Self, PricingConfig},
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
const EAskPriceOutOfBounds: u64 = 7;
const EAskBoundLooserThanGlobal: u64 = 8;
const EOracleNotSettled: u64 = 9;
const EStaleOracleMtm: u64 = 10;
const EPredictAlreadyCreated: u64 = 11;
const EFeeExceedsRedeemValue: u64 = 12;

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

/// Emitted when a per-oracle ask-bound override is set.
public struct OracleAskBoundsSet has copy, drop, store {
    predict_id: ID,
    oracle_id: ID,
    min_ask_price: u64,
    max_ask_price: u64,
}

/// Emitted when a per-oracle ask-bound override is cleared.
public struct OracleAskBoundsCleared has copy, drop, store {
    predict_id: ID,
    oracle_id: ID,
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

/// Emitted when admin-tuned oracle staleness thresholds change.
public struct OracleStalenessConfigUpdated has copy, drop, store {
    predict_id: ID,
    spot_staleness_threshold_ms: u64,
    basis_staleness_threshold_ms: u64,
    lazer_authoritative_threshold_ms: u64,
    lazer_settlement_authoritative_threshold_ms: u64,
}

/// Emitted when per-asset oracle basis bounds change.
public struct OracleBasisBoundsUpdated has copy, drop, store {
    predict_id: ID,
    asset: String,
    max_spot_deviation: u64,
    max_basis_deviation: u64,
    min_basis: u64,
    max_basis: u64,
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
    /// Oracle strike grid registry, operational checks, and curve builder
    oracle_config: OracleConfig,
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
    oracle: &OracleSVI,
    key: RangeKey,
    quantity: u64,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    assert!(ctx.sender() == manager.owner(), ENotOwner);
    mint_internal<Quote>(predict, manager, oracle, key, quantity, clock, ctx);
}

/// Compact a settled oracle's dense strike matrix into constant-size state.
/// Only an authorized oracle operator can trigger compaction.
public fun compact_settled_oracle(
    predict: &mut Predict,
    oracle: &OracleSVI,
    oracle_cap: &OracleSVICap,
) {
    oracle::assert_authorized_cap(oracle, oracle_cap);
    assert!(oracle.is_settled(), EOracleNotSettled);
    let settlement = oracle.settlement_price().destroy_some();
    predict.vault.compact_settled_oracle_if_needed(oracle.id(), settlement);
}

/// Redeem a position interval.
/// Live payout is post-trade fair value less fee. Settlement redemption is
/// zero-fee and pays `quantity` if settlement landed in `(lower, higher]`.
public fun redeem<Quote>(
    predict: &mut Predict,
    manager: &mut PredictManager,
    oracle: &OracleSVI,
    key: RangeKey,
    quantity: u64,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    assert!(ctx.sender() == manager.owner(), ENotOwner);
    let payout_coin = redeem_internal<Quote>(predict, manager, oracle, key, quantity, clock, ctx);
    manager.deposit(payout_coin, ctx);
}

/// Sell a settled position interval permissionlessly into the PredictManager's balance.
public fun redeem_permissionless<Quote>(
    predict: &mut Predict,
    manager: &mut PredictManager,
    oracle: &OracleSVI,
    key: RangeKey,
    quantity: u64,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    assert!(oracle.is_settled(), EOracleNotSettled);
    let payout_coin = redeem_internal<Quote>(predict, manager, oracle, key, quantity, clock, ctx);
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
    predict.assert_total_mtm_fresh(clock);
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
    predict.assert_total_mtm_fresh(clock);
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

/// Keeper/ops hook for syncing one oracle's cached MTM into the vault. This is
/// used to keep LP supply/withdraw accounting fresh across unsettled exposed
/// oracles; trade paths still refresh only the touched oracle inline.
public fun refresh_oracle_mtm(predict: &mut Predict, oracle: &OracleSVI, clock: &Clock) {
    if (oracle.is_settled() && predict.vault.has_settled_oracle(oracle.id())) return;
    if (!oracle.is_settled()) {
        oracle.assert_live_oracle(clock);
    };
    predict.refresh_oracle_risk(oracle, clock);
    if (oracle.is_settled()) {
        predict.vault.remove_unsettled_exposed_oracle(oracle.id(), true);
    };
}

/// Per-unit `(fair_price, fee_rate)` for a position interval.
/// `fee_rate` is an absolute price increment in FLOAT_SCALING, not bps.
public fun trade_quote(
    predict: &Predict,
    oracle: &OracleSVI,
    key: RangeKey,
    clock: &Clock,
): (u64, u64) {
    predict.oracle_config.assert_range_key_matches(oracle, &key);
    oracle.assert_quoteable_oracle(clock);

    let fair_price = range_fair_price(oracle, key);

    if (oracle.is_settled()) return (fair_price, 0);

    // Fee uses the cached aggregate MTM. This path does not require every
    // exposed oracle to be freshly synced; only the traded oracle is refreshed
    // inline before calling into pricing.
    let fee_rate = predict
        .pricing_config
        .quote_fee_rate_from_fair_price(
            fair_price,
            predict.vault.total_mtm(),
            predict.vault.balance(),
        );
    (fair_price, fee_rate)
}

/// Return oracle IDs whose unsettled exposure must be refreshed before LP flows.
public fun unsettled_exposed_oracles(predict: &Predict): &vector<ID> {
    predict.vault.unsettled_exposed_oracles()
}

/// Resolved ask-price bounds for an oracle, after intersecting any per-oracle
/// override with the global default. Exposed for UI/preview.
public fun ask_bounds(predict: &Predict, oracle_id: ID): (u64, u64) {
    predict.resolve_ask_bounds(oracle_id)
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
        pricing_config: pricing_config::new(),
        risk_config: risk_config::new(),
        treasury_config: treasury_config::new(),
        oracle_config: oracle_config::new(ctx),
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

/// Register an oracle strike grid and initialize its vault matrix.
public(package) fun add_oracle_grid(
    predict: &mut Predict,
    oracle_id: ID,
    min_strike: u64,
    tick_size: u64,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    predict.oracle_config.add_oracle_grid(oracle_id, min_strike, tick_size);
    let max_strike = min_strike + tick_size * constants::oracle_strike_grid_ticks!();
    predict.vault.init_oracle_matrix(oracle_id, min_strike, max_strike, tick_size, clock, ctx);
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
    predict.emit_risk_config_updated();
}

/// Update the MTM freshness threshold used for LP supply/withdraw gating.
public(package) fun set_mtm_freshness_ms(predict: &mut Predict, value: u64) {
    predict.risk_config.set_mtm_freshness_ms(value);
    predict.emit_risk_config_updated();
}

/// Update the admin-tuned spot staleness threshold used to seed new oracles
/// at `create_oracle`. Does NOT retroactively update existing oracles — the
/// operator retunes per-oracle via `oracle::set_spot_staleness_threshold_ms`.
public(package) fun set_staleness_threshold_ms(predict: &mut Predict, value: u64) {
    predict.oracle_config.set_spot_staleness_threshold_ms(value);
    predict.emit_oracle_staleness_config_updated();
}

/// Update the admin-tuned basis staleness threshold used to seed new oracles.
public(package) fun set_basis_staleness_threshold_ms(predict: &mut Predict, value: u64) {
    predict.oracle_config.set_basis_staleness_threshold_ms(value);
    predict.emit_oracle_staleness_config_updated();
}

/// Update the admin-tuned Lazer-authoritative window used to seed new oracles.
public(package) fun set_lazer_authoritative_threshold_ms(predict: &mut Predict, value: u64) {
    predict.oracle_config.set_lazer_authoritative_threshold_ms(value);
    predict.emit_oracle_staleness_config_updated();
}

/// Update the admin-tuned Lazer-settlement-authoritative window used to seed
/// new oracles. Does NOT retroactively update existing oracles — the operator
/// retunes per-oracle via
/// `oracle::set_lazer_settlement_authoritative_threshold_ms`.
public(package) fun set_lazer_settlement_authoritative_threshold_ms(
    predict: &mut Predict,
    value: u64,
) {
    predict.oracle_config.set_lazer_settlement_authoritative_threshold_ms(value);
    predict.emit_oracle_staleness_config_updated();
}

/// Update the per-asset basis circuit-breaker bounds seed used by
/// `oracle_config::build_oracle_bounds` at `create_oracle`. Does NOT
/// retroactively update existing oracles.
public(package) fun set_asset_basis_bounds(
    predict: &mut Predict,
    asset: String,
    max_spot_deviation: u64,
    max_basis_deviation: u64,
    min_basis: u64,
    max_basis: u64,
) {
    predict
        .oracle_config
        .set_asset_basis_bounds(
            asset,
            max_spot_deviation,
            max_basis_deviation,
            min_basis,
            max_basis,
        );
    event::emit(OracleBasisBoundsUpdated {
        predict_id: object::id(predict),
        asset,
        max_spot_deviation,
        max_basis_deviation,
        min_basis,
        max_basis,
    });
}

/// Bind `asset → pyth_lazer_feed_id` so `create_oracle` can infer the feed
/// id from the underlying asset instead of taking it as a PTB arg. Does NOT
/// retroactively update existing oracles — they keep the feed id snapshotted
/// at their own creation time.
public(package) fun set_asset_feed_id(
    predict: &mut Predict,
    asset: String,
    pyth_lazer_feed_id: u64,
) {
    predict.oracle_config.set_asset_feed_id(asset, pyth_lazer_feed_id);
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

/// Snapshot the admin-tuned oracle bounds (staleness thresholds + per-asset
/// basis bounds) for `asset` at `create_oracle` time.
public(package) fun build_oracle_bounds(predict: &Predict, asset: String): oracle::OracleBounds {
    predict.oracle_config.build_oracle_bounds(asset)
}

/// Resolve the admin-registered Pyth Lazer feed id for `asset`. Aborts with
/// `oracle_config::EFeedIdNotConfigured` if no entry exists — admin must call
/// `set_asset_feed_id` at least once per underlying before its first oracle
/// can be created. Returned as `u64` for type consistency with the rest of
/// the admin-config surface; narrowed to `u32` at `registry::create_oracle`.
public(package) fun resolve_feed_id(predict: &Predict, asset: String): u64 {
    predict.oracle_config.resolve_feed_id(asset)
}

// === Private Functions ===

/// Assert every unsettled exposed oracle has a fresh cached MTM for LP flows.
fun assert_total_mtm_fresh(predict: &Predict, clock: &Clock) {
    // MTM freshness is enforced only for LP supply/withdraw. Trade quoting
    // still relies on cached aggregate `vault.total_mtm()` and refreshes the
    // touched oracle inline.
    let unsettled_exposed_oracles = predict.vault.unsettled_exposed_oracles();
    let mut i = 0;
    let len = unsettled_exposed_oracles.length();
    let now = clock.timestamp_ms();
    while (i < len) {
        let oracle_id = unsettled_exposed_oracles[i];
        let last_update = predict.vault.get_last_mtm_update(oracle_id);
        if (now > last_update) {
            assert!(now - last_update <= predict.risk_config.mtm_freshness_ms(), EStaleOracleMtm);
        };
        i = i + 1;
    }
}

/// Shared mint path after caller authorization.
fun mint_internal<Quote>(
    predict: &mut Predict,
    manager: &mut PredictManager,
    oracle: &OracleSVI,
    key: RangeKey,
    quantity: u64,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    predict.apply_trade_delta<Quote>(manager, oracle, key, quantity, true, clock);

    let (principal_amount, fee_amount) = predict.get_principal_and_fee_amount(
        oracle,
        key,
        quantity,
        true,
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

/// Shared redemption path.
fun redeem_internal<Quote>(
    predict: &mut Predict,
    manager: &mut PredictManager,
    oracle: &OracleSVI,
    key: RangeKey,
    quantity: u64,
    clock: &Clock,
    ctx: &mut TxContext,
): Coin<Quote> {
    predict.apply_trade_delta<Quote>(manager, oracle, key, quantity, false, clock);

    let (principal_amount, fee_amount) = predict.get_principal_and_fee_amount(
        oracle,
        key,
        quantity,
        false,
        clock,
    );
    let mut payout_balance = predict.vault.dispense_payout<Quote>(principal_amount);
    let fee_balance = payout_balance.split(fee_amount);
    predict.apply_fee(fee_balance);

    let payout_coin = payout_balance.into_coin(ctx);

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
        payout: payout_coin.value(),
        fee_amount,
        is_settled: oracle.is_settled(),
    });

    payout_coin
}

/// Apply the position, vault, and risk-state delta for a buy or sell before
/// pricing the trade against the post-trade vault state.
fun apply_trade_delta<Quote>(
    predict: &mut Predict,
    manager: &mut PredictManager,
    oracle: &OracleSVI,
    key: RangeKey,
    quantity: u64,
    is_buy: bool,
    clock: &Clock,
) {
    assert!(quantity > 0, EZeroQuantity);
    predict.oracle_config.assert_range_key_matches(oracle, &key);
    if (is_buy) {
        assert!(!predict.trading_paused, ETradingPaused);
        predict.treasury_config.assert_quote_asset<Quote>();
        oracle.assert_live_oracle(clock);

        manager.increase_range(key, quantity);
        predict
            .vault
            .insert_range(
                oracle.id(),
                key.lower_strike(),
                key.higher_strike(),
                quantity,
            );
        predict.refresh_oracle_risk(oracle, clock);
        predict.vault.add_unsettled_exposed_oracle(oracle.id());
    } else {
        oracle.assert_quoteable_oracle(clock);

        manager.decrease_range(key, quantity);
        predict
            .vault
            .remove_range(
                oracle.id(),
                key.lower_strike(),
                key.higher_strike(),
                quantity,
            );
        predict.refresh_oracle_risk(oracle, clock);
        predict.vault.remove_unsettled_exposed_oracle(oracle.id(), oracle.is_settled());
    }
}

fun get_principal_and_fee_amount(
    predict: &Predict,
    oracle: &OracleSVI,
    key: RangeKey,
    quantity: u64,
    is_mint: bool,
    clock: &Clock,
): (u64, u64) {
    let (fair_price, quoted_fee_rate) = predict.trade_quote(oracle, key, clock);
    predict.assert_tradeable_price(oracle.id(), fair_price, quoted_fee_rate, is_mint);

    let principal_amount = math::mul(fair_price, quantity);
    let fee_amount = math::mul(quoted_fee_rate, quantity);

    (principal_amount, fee_amount)
}

/// Fair range price = up(lower) - up(higher). UP price is monotone
/// non-increasing in strike, so this is non-negative for a well-formed key.
/// Settled compute_price makes this 1.0 iff settlement is in `(lower, higher]`.
fun range_fair_price(oracle: &OracleSVI, key: RangeKey): u64 {
    let lower_up_price = oracle.compute_price(key.lower_strike());
    let higher_up_price = oracle.compute_price(key.higher_strike());
    lower_up_price - higher_up_price
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

/// Emit the full current oracle-staleness config snapshot.
fun emit_oracle_staleness_config_updated(predict: &Predict) {
    event::emit(OracleStalenessConfigUpdated {
        predict_id: object::id(predict),
        spot_staleness_threshold_ms: predict.oracle_config.spot_staleness_threshold_ms(),
        basis_staleness_threshold_ms: predict.oracle_config.basis_staleness_threshold_ms(),
        lazer_authoritative_threshold_ms: predict.oracle_config.lazer_authoritative_threshold_ms(),
        lazer_settlement_authoritative_threshold_ms: predict
            .oracle_config
            .lazer_settlement_authoritative_threshold_ms(),
    });
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

/// Assert a mint price fits the resolved global/per-oracle bounds.
fun assert_tradeable_price(
    predict: &Predict,
    oracle_id: ID,
    fair_price: u64,
    quoted_fee_rate: u64,
    is_mint: bool,
) {
    if (is_mint) {
        let mint_price = fair_price + quoted_fee_rate;
        let (min_ask, max_ask) = predict.resolve_ask_bounds(oracle_id);
        assert!(mint_price >= min_ask && mint_price <= max_ask, EAskPriceOutOfBounds);
    } else {
        assert!(fair_price >= quoted_fee_rate, EFeeExceedsRedeemValue);
    }
}

/// Refresh one oracle's cached risk metrics in the vault.
fun refresh_oracle_risk(predict: &mut Predict, oracle: &OracleSVI, clock: &Clock) {
    let oracle_id = oracle.id();
    if (oracle.is_settled() && predict.vault.has_settled_oracle(oracle_id)) {
        // Compacted settled liability is already updated by vault mutations.
        return
    };
    let (min_strike, max_strike) = predict.vault.oracle_strike_range(oracle_id);
    if (min_strike == 0 && max_strike == 0) {
        // `(0, 0)` means this oracle has never had any minted exposure.
        predict.vault.set_mtm(oracle_id, 0, clock);
        return
    };
    // Historical minted bounds do not shrink after a full unwind, so an empty
    // but previously touched book still rebuilds over the old range and
    // evaluates to 0 from zero start/end boundary quantity.
    if (oracle.is_settled()) {
        predict
            .vault
            .set_mtm_with_settlement(oracle_id, oracle.settlement_price().destroy_some(), clock);
        return
    };
    let curve = predict.oracle_config.build_curve(oracle, min_strike, max_strike);
    predict.vault.set_mtm_with_curve(oracle_id, &curve, clock);
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
        pricing_config: pricing_config::new(),
        risk_config: risk_config::new(),
        treasury_config: treasury_config::new(),
        oracle_config: oracle_config::new(ctx),
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
/// Return oracle config access for tests.
public(package) fun oracle_config(predict: &Predict): &OracleConfig {
    &predict.oracle_config
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
