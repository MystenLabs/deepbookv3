// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Protocol-wide configuration, templates, per-expiry rows, and flow gates for Predict.
///
/// This shared object owns the admin-tunable config structs, feed templates,
/// per-expiry config rows, trading pause, and full-pool valuation lock. Flow
/// modules decide which gates apply before they mutate expiry, oracle, pool, or
/// manager state.
module deepbook_predict::protocol_config;

use deepbook_predict::{
    admin::AdminCap,
    config_constants,
    config_events,
    constants,
    fee_config::{Self, FeeConfig},
    feed_template::FeedTemplate,
    leverage_config::{Self, LeverageConfig},
    market_oracle_config::{Self, MarketOracleConfig},
    pricing_config::{Self, PricingConfig},
    risk_config::{Self, RiskConfig},
    stake_config::{Self, StakeConfig}
};
use sui::table::{Self, Table};

const ETradingPaused: u64 = 0;
const EValuationInProgress: u64 = 1;
const EValuationNotInProgress: u64 = 2;
const EFeedTemplateAlreadyExists: u64 = 3;
const EFeedTemplateNotFound: u64 = 4;
const EExpiryEntryAlreadyExists: u64 = 5;
const EExpiryEntryNotFound: u64 = 6;
const EWrongMarketOracle: u64 = 7;
const EWrongExpiryMarket: u64 = 8;

/// Frozen contract terms stamped for one expiry.
public struct ExpiryConfigSnapshot has copy, drop {
    /// 1e9-scaled floor-to-live-value threshold for liquidation.
    liquidation_ltv: u64,
    /// Maximum terminal increase in the contract floor index over one expiry.
    max_expiry_floor_premium: u64,
    /// Fraction of aggregate expiry trading fees reserved for loss rebates.
    trading_loss_rebate_rate: u64,
    /// Minimum finite strike in this expiry's oracle grid.
    min_strike: u64,
    /// Strike tick size for this expiry's oracle grid.
    tick_size: u64,
    /// Window before expiry over which trade fees ramp up.
    expiry_fee_window_ms: u64,
    /// Fee multiplier reached at expiry, in FLOAT_SCALING; 1x disables.
    expiry_fee_max_multiplier: u64,
}

/// Central per-expiry config row.
public struct ExpiryEntry has copy, drop, store {
    /// Expiry market object bound to this expiry.
    expiry_market_id: ID,
    /// Market oracle object bound to this expiry.
    market_oracle_id: ID,
    /// Mutable oracle bounds/freshness policy for this expiry.
    oracle_policy: MarketOracleConfig,
    /// Blocks new mints for this expiry while true.
    mint_paused: bool,
}

/// Shared protocol policy and config state.
public struct ProtocolConfig has key {
    id: UID,
    pricing_config: PricingConfig,
    fee_config: FeeConfig,
    risk_config: RiskConfig,
    market_oracle_config: MarketOracleConfig,
    leverage_config: LeverageConfig,
    stake_config: StakeConfig,
    /// Blocks new risk creation while true.
    trading_paused: bool,
    /// Transaction-local lock held while a full-pool valuation is assembled.
    valuation_in_progress: bool,
    /// Pyth Lazer feed ID -> future-expiry template policy.
    per_feed: Table<u32, FeedTemplate>,
    /// Expiry timestamp -> object bindings and mutable per-expiry controls.
    per_expiry: Table<u64, ExpiryEntry>,
}

// === Public Functions ===

/// Return the protocol config object ID.
public fun id(config: &ProtocolConfig): ID {
    config.id.to_inner()
}

/// Return whether trading is currently paused.
public fun trading_paused(config: &ProtocolConfig): bool {
    config.trading_paused
}

/// Return whether new mints are paused for one expiry.
public fun expiry_mint_paused(config: &ProtocolConfig, expiry: u64): bool {
    config.expiry_entry(expiry).entry_mint_paused()
}

/// Return the configured strike tick size for a Pyth Lazer feed, if registered.
public fun pyth_feed_tick_size(config: &ProtocolConfig, pyth_lazer_feed_id: u32): Option<u64> {
    if (config.has_feed_template(pyth_lazer_feed_id)) {
        option::some(config.feed_template(pyth_lazer_feed_id).tick_size())
    } else {
        option::none()
    }
}

/// Return the configured expiry-fee ramp window for a Pyth Lazer feed, if registered.
public fun pyth_feed_expiry_fee_window_ms(
    config: &ProtocolConfig,
    pyth_lazer_feed_id: u32,
): Option<u64> {
    if (config.has_feed_template(pyth_lazer_feed_id)) {
        option::some(config.feed_template(pyth_lazer_feed_id).expiry_fee_window_ms())
    } else {
        option::none()
    }
}

/// Return the configured expiry-fee max multiplier for a Pyth Lazer feed, if registered.
public fun pyth_feed_expiry_fee_max_multiplier(
    config: &ProtocolConfig,
    pyth_lazer_feed_id: u32,
): Option<u64> {
    if (config.has_feed_template(pyth_lazer_feed_id)) {
        option::some(config.feed_template(pyth_lazer_feed_id).expiry_fee_max_multiplier())
    } else {
        option::none()
    }
}

/// Set the base fee multiplier.
public fun set_base_fee(config: &mut ProtocolConfig, _admin_cap: &AdminCap, fee: u64) {
    config.assert_not_valuation_in_progress();
    config.pricing_config.set_base_fee(fee);
    config_events::emit_pricing_config_updated(config.id(), &config.pricing_config);
}

/// Set the minimum fee floor.
public fun set_min_fee(config: &mut ProtocolConfig, _admin_cap: &AdminCap, fee: u64) {
    config.assert_not_valuation_in_progress();
    config.pricing_config.set_min_fee(fee);
    config_events::emit_pricing_config_updated(config.id(), &config.pricing_config);
}

/// Set the maximum floor-index increase snapshotted by future expiry markets.
public fun set_template_max_expiry_floor_premium(
    config: &mut ProtocolConfig,
    _admin_cap: &AdminCap,
    value: u64,
) {
    config.assert_not_valuation_in_progress();
    config.leverage_config.set_template_max_expiry_floor_premium(value);
    config_events::emit_leverage_config_updated(config.id(), &config.leverage_config);
}

/// Set the liquidation LTV snapshotted by future expiry markets.
public fun set_template_liquidation_ltv(
    config: &mut ProtocolConfig,
    _admin_cap: &AdminCap,
    value: u64,
) {
    config.assert_not_valuation_in_progress();
    config.leverage_config.set_template_liquidation_ltv(value);
    config_events::emit_leverage_config_updated(config.id(), &config.leverage_config);
}

/// Set the staking benefit thresholds: `lower` (half of max benefits) and
/// `upper` (full benefits). Validated as a pair (`upper > 2 * lower`).
public fun set_benefit_powers(
    config: &mut ProtocolConfig,
    _admin_cap: &AdminCap,
    lower: u64,
    upper: u64,
) {
    config.assert_not_valuation_in_progress();
    config.stake_config.set_benefit_powers(lower, upper);
}

/// Set the global minimum allowed mint price.
public fun set_min_ask_price(config: &mut ProtocolConfig, _admin_cap: &AdminCap, value: u64) {
    config.assert_not_valuation_in_progress();
    config.pricing_config.set_min_ask_price(value);
    config_events::emit_pricing_config_updated(config.id(), &config.pricing_config);
}

/// Set the global maximum allowed mint price.
public fun set_max_ask_price(config: &mut ProtocolConfig, _admin_cap: &AdminCap, value: u64) {
    config.assert_not_valuation_in_progress();
    config.pricing_config.set_max_ask_price(value);
    config_events::emit_pricing_config_updated(config.id(), &config.pricing_config);
}

/// Set the live Pyth spot freshness threshold.
public fun set_pyth_spot_freshness_ms(
    config: &mut ProtocolConfig,
    _admin_cap: &AdminCap,
    value: u64,
) {
    config.assert_not_valuation_in_progress();
    config.pricing_config.set_pyth_spot_freshness_ms(value);
    config_events::emit_pricing_config_updated(config.id(), &config.pricing_config);
}

/// Set the live Block Scholes spot/forward freshness threshold.
public fun set_block_scholes_prices_freshness_ms(
    config: &mut ProtocolConfig,
    _admin_cap: &AdminCap,
    value: u64,
) {
    config.assert_not_valuation_in_progress();
    config.pricing_config.set_block_scholes_prices_freshness_ms(value);
    config_events::emit_pricing_config_updated(config.id(), &config.pricing_config);
}

/// Set the live Block Scholes SVI freshness threshold.
public fun set_block_scholes_svi_freshness_ms(
    config: &mut ProtocolConfig,
    _admin_cap: &AdminCap,
    value: u64,
) {
    config.assert_not_valuation_in_progress();
    config.pricing_config.set_block_scholes_svi_freshness_ms(value);
    config_events::emit_pricing_config_updated(config.id(), &config.pricing_config);
}

/// Set the current protocol reserve profit share used when materializing aggregate expiry profit.
public fun set_protocol_reserve_profit_share(
    config: &mut ProtocolConfig,
    _admin_cap: &AdminCap,
    protocol_reserve_profit_share: u64,
) {
    config.assert_not_valuation_in_progress();
    config.fee_config.set_protocol_reserve_profit_share(protocol_reserve_profit_share);
    config_events::emit_fee_config_updated(config.id(), &config.fee_config);
}

/// Set the trading loss rebate rate template used by future expiry markets.
public fun set_template_trading_loss_rebate_rate(
    config: &mut ProtocolConfig,
    _admin_cap: &AdminCap,
    value: u64,
) {
    config.assert_not_valuation_in_progress();
    config.fee_config.set_trading_loss_rebate_rate(value);
    config_events::emit_fee_config_updated(config.id(), &config.fee_config);
}

/// Set the total liquidation candidate budget used before live valuations.
public fun set_valuation_liquidation_budget(
    config: &mut ProtocolConfig,
    _admin_cap: &AdminCap,
    budget: u64,
) {
    config.assert_not_valuation_in_progress();
    config.risk_config.set_valuation_liquidation_budget(budget);
    config_events::emit_risk_config_updated(config.id(), &config.risk_config);
}

/// Set the total liquidation candidate budget used before mint and redeem flows.
public fun set_trade_liquidation_budget(
    config: &mut ProtocolConfig,
    _admin_cap: &AdminCap,
    budget: u64,
) {
    config.assert_not_valuation_in_progress();
    config.risk_config.set_trade_liquidation_budget(budget);
    config_events::emit_risk_config_updated(config.id(), &config.risk_config);
}

/// Set the settlement freshness threshold template for future market oracles.
public fun set_market_oracle_template_settlement_freshness_ms(
    config: &mut ProtocolConfig,
    _admin_cap: &AdminCap,
    value: u64,
) {
    config.assert_not_valuation_in_progress();
    config.market_oracle_config.set_settlement_freshness_ms(value);
    config_events::emit_market_oracle_template_config_updated(
        config.id(),
        &config.market_oracle_config,
    );
}

/// Set basis guard bounds template for future market oracles.
public fun set_market_oracle_template_basis_bounds(
    config: &mut ProtocolConfig,
    _admin_cap: &AdminCap,
    max_spot_deviation: u64,
    max_basis_deviation: u64,
    min_basis: u64,
    max_basis: u64,
) {
    config.assert_not_valuation_in_progress();
    config
        .market_oracle_config
        .set_basis_bounds(
            max_spot_deviation,
            max_basis_deviation,
            min_basis,
            max_basis,
        );
    config_events::emit_market_oracle_template_config_updated(
        config.id(),
        &config.market_oracle_config,
    );
}

/// Set the strike tick size used by future expiry markets for one Pyth feed.
public fun set_pyth_feed_tick_size(
    config: &mut ProtocolConfig,
    _admin_cap: &AdminCap,
    pyth_lazer_feed_id: u32,
    tick_size: u64,
) {
    config.assert_not_valuation_in_progress();
    config.assert_feed_template_exists(pyth_lazer_feed_id);
    config.per_feed.borrow_mut(pyth_lazer_feed_id).set_tick_size(tick_size);
    config.emit_feed_template_updated(pyth_lazer_feed_id);
}

/// Set the per-asset expiry-fee ramp window snapshotted by future expiry markets
/// for one Pyth feed.
public fun set_pyth_feed_expiry_fee_window_ms(
    config: &mut ProtocolConfig,
    _admin_cap: &AdminCap,
    pyth_lazer_feed_id: u32,
    window_ms: u64,
) {
    config.assert_not_valuation_in_progress();
    config.assert_feed_template_exists(pyth_lazer_feed_id);
    config.per_feed.borrow_mut(pyth_lazer_feed_id).set_expiry_fee_window_ms(window_ms);
    config.emit_feed_template_updated(pyth_lazer_feed_id);
}

/// Set the per-asset expiry-fee max multiplier snapshotted by future expiry markets
/// for one Pyth feed. `max_multiplier` (FLOAT_SCALING, 1x disables) is the multiplier
/// reached at expiry over the configured ramp window. Larger values suit more volatile assets.
public fun set_pyth_feed_expiry_fee_max_multiplier(
    config: &mut ProtocolConfig,
    _admin_cap: &AdminCap,
    pyth_lazer_feed_id: u32,
    max_multiplier: u64,
) {
    config.assert_not_valuation_in_progress();
    config.assert_feed_template_exists(pyth_lazer_feed_id);
    config.per_feed.borrow_mut(pyth_lazer_feed_id).set_expiry_fee_max_multiplier(max_multiplier);
    config.emit_feed_template_updated(pyth_lazer_feed_id);
}

/// Set whether trading is paused.
public fun set_trading_paused(config: &mut ProtocolConfig, _admin_cap: &AdminCap, paused: bool) {
    config.set_trading_paused_internal(paused);
}

/// Set whether new mints are paused for one expiry.
public fun set_expiry_mint_paused(
    config: &mut ProtocolConfig,
    _admin_cap: &AdminCap,
    expiry: u64,
    paused: bool,
) {
    config.set_expiry_mint_paused_internal(expiry, paused);
}

// === Public-Package Functions ===

public(package) fun pricing_config(config: &ProtocolConfig): &PricingConfig {
    &config.pricing_config
}

public(package) fun fee_config(config: &ProtocolConfig): &FeeConfig {
    &config.fee_config
}

public(package) fun risk_config(config: &ProtocolConfig): &RiskConfig {
    &config.risk_config
}

public(package) fun leverage_config(config: &ProtocolConfig): &LeverageConfig {
    &config.leverage_config
}

public(package) fun stake_config(config: &ProtocolConfig): &StakeConfig {
    &config.stake_config
}

public(package) fun liquidation_ltv(snapshot: &ExpiryConfigSnapshot): u64 {
    snapshot.liquidation_ltv
}

public(package) fun max_expiry_floor_premium(snapshot: &ExpiryConfigSnapshot): u64 {
    snapshot.max_expiry_floor_premium
}

public(package) fun trading_loss_rebate_rate(snapshot: &ExpiryConfigSnapshot): u64 {
    snapshot.trading_loss_rebate_rate
}

public(package) fun min_strike(snapshot: &ExpiryConfigSnapshot): u64 {
    snapshot.min_strike
}

public(package) fun tick_size(snapshot: &ExpiryConfigSnapshot): u64 {
    snapshot.tick_size
}

public(package) fun expiry_fee_window_ms(snapshot: &ExpiryConfigSnapshot): u64 {
    snapshot.expiry_fee_window_ms
}

public(package) fun expiry_fee_max_multiplier(snapshot: &ExpiryConfigSnapshot): u64 {
    snapshot.expiry_fee_max_multiplier
}

public(package) fun expiry_oracle_policy(
    config: &ProtocolConfig,
    expiry: u64,
): &MarketOracleConfig {
    config.expiry_entry(expiry).entry_oracle_policy()
}

public(package) fun assert_expiry_market_binding(
    config: &ProtocolConfig,
    expiry: u64,
    expiry_market_id: ID,
) {
    assert!(
        config.expiry_entry(expiry).entry_expiry_market_id() == expiry_market_id,
        EWrongExpiryMarket,
    );
}

public(package) fun assert_expiry_oracle_binding(
    config: &ProtocolConfig,
    expiry: u64,
    market_oracle_id: ID,
) {
    assert!(
        config.expiry_entry(expiry).entry_market_oracle_id() == market_oracle_id,
        EWrongMarketOracle,
    );
}

public(package) fun set_expiry_oracle_settlement_freshness_ms(
    config: &mut ProtocolConfig,
    expiry: u64,
    market_oracle_id: ID,
    value: u64,
) {
    config.assert_not_valuation_in_progress();
    let policy = {
        let entry = config.expiry_entry_mut(expiry);
        assert!(entry.market_oracle_id == market_oracle_id, EWrongMarketOracle);
        entry.oracle_policy.set_settlement_freshness_ms(value);
        entry.oracle_policy
    };
    emit_expiry_oracle_policy_updated(market_oracle_id, &policy);
}

public(package) fun set_expiry_oracle_basis_bounds(
    config: &mut ProtocolConfig,
    expiry: u64,
    market_oracle_id: ID,
    max_spot_deviation: u64,
    max_basis_deviation: u64,
    min_basis: u64,
    max_basis: u64,
) {
    config.assert_not_valuation_in_progress();
    let policy = {
        let entry = config.expiry_entry_mut(expiry);
        assert!(entry.market_oracle_id == market_oracle_id, EWrongMarketOracle);
        entry
            .oracle_policy
            .set_basis_bounds(
                max_spot_deviation,
                max_basis_deviation,
                min_basis,
                max_basis,
            );
        entry.oracle_policy
    };
    emit_expiry_oracle_policy_updated(market_oracle_id, &policy);
}

public(package) fun add_feed_template(
    config: &mut ProtocolConfig,
    pyth_lazer_feed_id: u32,
    template: FeedTemplate,
) {
    config.assert_not_valuation_in_progress();
    assert!(!config.has_feed_template(pyth_lazer_feed_id), EFeedTemplateAlreadyExists);
    config.per_feed.add(pyth_lazer_feed_id, template);
    config.emit_feed_template_updated(pyth_lazer_feed_id);
}

public(package) fun stamp_expiry_entry(
    config: &mut ProtocolConfig,
    expiry: u64,
    expiry_market_id: ID,
    market_oracle_id: ID,
    pyth_lazer_feed_id: u32,
    spot: u64,
): ExpiryConfigSnapshot {
    assert!(!config.has_expiry_entry(expiry), EExpiryEntryAlreadyExists);
    let feed_template = *config.feed_template(pyth_lazer_feed_id);
    let tick_size = feed_template.tick_size();
    let min_strike = centered_min_strike(spot, tick_size);
    let snapshot = ExpiryConfigSnapshot {
        liquidation_ltv: config.leverage_config.liquidation_ltv(),
        max_expiry_floor_premium: config.leverage_config.max_expiry_floor_premium(),
        trading_loss_rebate_rate: config.fee_config.trading_loss_rebate_rate(),
        min_strike,
        tick_size,
        expiry_fee_window_ms: feed_template.expiry_fee_window_ms(),
        expiry_fee_max_multiplier: feed_template.expiry_fee_max_multiplier(),
    };
    let oracle_policy = config.market_oracle_config;
    config
        .per_expiry
        .add(
            expiry,
            ExpiryEntry {
                expiry_market_id,
                market_oracle_id,
                oracle_policy,
                mint_paused: false,
            },
        );
    snapshot
}

/// Abort unless trading mutations are currently allowed.
///
/// Intentionally omits the package-version gate: per-pool mutating flows that
/// call this assert their own mirrored `allowed_versions`, sourced from the
/// registry.
public(package) fun assert_trading_allowed(config: &ProtocolConfig) {
    config.assert_not_trading_paused();
    config.assert_not_valuation_in_progress();
}

/// Abort unless a valuation lock is currently active.
public(package) fun assert_valuation_in_progress(config: &ProtocolConfig) {
    assert!(config.valuation_in_progress, EValuationNotInProgress);
}

/// Abort unless no valuation lock is currently active.
public(package) fun assert_not_valuation_in_progress(config: &ProtocolConfig) {
    assert!(!config.valuation_in_progress, EValuationInProgress);
}

/// Create and share the protocol-wide configuration object.
public(package) fun create_and_share(ctx: &mut TxContext): ID {
    let config = new(ctx);
    let id = config.id();
    transfer::share_object(config);
    id
}

/// Force `trading_paused = true` without admin authority. Reserved for
/// `PauseCap` holders going through the registry; cannot be used to unpause.
public(package) fun pause_trading(config: &mut ProtocolConfig) {
    config.set_trading_paused_internal(true);
}

/// Force `mint_paused = true` for one expiry. Reserved for `PauseCap` holders
/// going through the registry; cannot be used to unpause.
public(package) fun pause_expiry_mint(config: &mut ProtocolConfig, expiry: u64) {
    config.set_expiry_mint_paused_internal(expiry, true);
}

/// Begin a transaction-local full-pool valuation lock.
public(package) fun begin_valuation(config: &mut ProtocolConfig) {
    config.assert_not_valuation_in_progress();
    config.valuation_in_progress = true;
}

/// End a transaction-local full-pool valuation lock.
public(package) fun end_valuation(config: &mut ProtocolConfig) {
    config.assert_valuation_in_progress();
    config.valuation_in_progress = false;
}

fun set_trading_paused_internal(config: &mut ProtocolConfig, paused: bool) {
    config.assert_not_valuation_in_progress();
    config.trading_paused = paused;
    config_events::emit_trading_paused_updated(config.id(), paused);
}

fun set_expiry_mint_paused_internal(config: &mut ProtocolConfig, expiry: u64, paused: bool) {
    config.assert_not_valuation_in_progress();
    let expiry_market_id = {
        let entry = config.expiry_entry_mut(expiry);
        entry.mint_paused = paused;
        entry.entry_expiry_market_id()
    };
    config_events::emit_expiry_market_mint_paused_updated(expiry_market_id, paused);
}

/// Abort unless trading is not paused.
fun assert_not_trading_paused(config: &ProtocolConfig) {
    assert!(!config.trading_paused, ETradingPaused);
}

fun has_feed_template(config: &ProtocolConfig, pyth_lazer_feed_id: u32): bool {
    config.per_feed.contains(pyth_lazer_feed_id)
}

fun has_expiry_entry(config: &ProtocolConfig, expiry: u64): bool {
    config.per_expiry.contains(expiry)
}

fun assert_feed_template_exists(config: &ProtocolConfig, pyth_lazer_feed_id: u32) {
    assert!(config.has_feed_template(pyth_lazer_feed_id), EFeedTemplateNotFound);
}

fun expiry_entry_mut(config: &mut ProtocolConfig, expiry: u64): &mut ExpiryEntry {
    assert!(config.has_expiry_entry(expiry), EExpiryEntryNotFound);
    config.per_expiry.borrow_mut(expiry)
}

fun entry_expiry_market_id(entry: &ExpiryEntry): ID {
    entry.expiry_market_id
}

fun entry_market_oracle_id(entry: &ExpiryEntry): ID {
    entry.market_oracle_id
}

fun entry_oracle_policy(entry: &ExpiryEntry): &MarketOracleConfig {
    &entry.oracle_policy
}

fun entry_mint_paused(entry: &ExpiryEntry): bool {
    entry.mint_paused
}

fun feed_template(config: &ProtocolConfig, pyth_lazer_feed_id: u32): &FeedTemplate {
    config.assert_feed_template_exists(pyth_lazer_feed_id);
    config.per_feed.borrow(pyth_lazer_feed_id)
}

fun expiry_entry(config: &ProtocolConfig, expiry: u64): &ExpiryEntry {
    assert!(config.has_expiry_entry(expiry), EExpiryEntryNotFound);
    config.per_expiry.borrow(expiry)
}

fun centered_min_strike(spot: u64, tick_size: u64): u64 {
    config_constants::assert_oracle_tick_size_covers_spot(tick_size, spot);
    let center_ticks = constants::oracle_strike_grid_ticks!() / 2;

    (spot / tick_size - center_ticks) * tick_size
}

fun emit_feed_template_updated(config: &ProtocolConfig, pyth_lazer_feed_id: u32) {
    config_events::emit_feed_template_updated(
        config.id(),
        pyth_lazer_feed_id,
        config.feed_template(pyth_lazer_feed_id),
    );
}

fun emit_expiry_oracle_policy_updated(market_oracle_id: ID, policy: &MarketOracleConfig) {
    config_events::emit_market_oracle_bounds_updated(
        market_oracle_id,
        policy.settlement_freshness_ms(),
        policy.max_spot_deviation(),
        policy.max_basis_deviation(),
        policy.min_basis(),
        policy.max_basis(),
    );
}

fun new(ctx: &mut TxContext): ProtocolConfig {
    ProtocolConfig {
        id: object::new(ctx),
        pricing_config: pricing_config::new(),
        fee_config: fee_config::new(),
        risk_config: risk_config::new(),
        market_oracle_config: market_oracle_config::new(),
        leverage_config: leverage_config::new(),
        stake_config: stake_config::new(),
        trading_paused: false,
        valuation_in_progress: false,
        per_feed: table::new(ctx),
        per_expiry: table::new(ctx),
    }
}

// === Test-Only Functions ===

#[test_only]
public fun new_for_testing(ctx: &mut TxContext): ProtocolConfig {
    new(ctx)
}
