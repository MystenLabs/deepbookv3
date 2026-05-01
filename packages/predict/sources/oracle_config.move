// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Predict-owned configuration layer on top of the core market_oracle.
///
/// This module stores the admin-tuned freshness thresholds, per-asset basis
/// circuit-breaker bounds, per-market_oracle strike grids, and per-market_oracle ask-bound
/// overrides. At market oracle creation the thresholds + per-asset bounds are
/// snapshotted into `MarketOracleBounds`, so source updates never need to read
/// from Predict.
module deepbook_predict::oracle_config;

use deepbook_predict::{
    constants,
    market_oracle::{Self, MarketOracleBounds, MarketOracle, MarketOracleCap},
    pricing::{Self, AskBounds},
    range_key::RangeKey,
    tuning_constants
};
use std::string::String;
use sui::table::{Self, Table};

const EInvalidStrike: u64 = 2;
const EOracleConfigNotFound: u64 = 3;
const ERangeKeyOracleMismatch: u64 = 5;
const ERangeKeyExpiryMismatch: u64 = 6;
const EInvalidAskBound: u64 = 7;
const EInvalidFreshnessThreshold: u64 = 8;
const EInvalidBasisBounds: u64 = 9;
const EFeedIdNotConfigured: u64 = 10;

/// Strike grid metadata attached to one market_oracle.
public struct OracleGrid has copy, drop, store {
    min_strike: u64,
    max_strike: u64,
    tick_size: u64,
}

/// Per-asset basis circuit-breaker bounds. Snapshotted onto each new market_oracle
/// (by underlying asset) at `create_market_oracle`. Updating an entry here does NOT
/// retroactively change existing oracles — operators tune their own market_oracle
/// via `market_oracle::set_basis_bounds` if they need to diverge from the default.
public struct BasisBounds has copy, drop, store {
    max_spot_deviation: u64,
    max_basis_deviation: u64,
    min_basis: u64,
    max_basis: u64,
}

/// Predict-owned market_oracle configuration and per-market_oracle metadata.
public struct OracleConfig has store {
    oracle_grids: Table<ID, OracleGrid>,
    /// Per-market_oracle ask-bound overrides; presence in this table means an override
    /// is active for that market_oracle id.
    oracle_ask_bounds: Table<ID, AskBounds>,
    /// Per-underlying-asset basis circuit-breaker bounds. Looked up by the
    /// market_oracle's `underlying_asset` at `create_market_oracle`; assets with no entry
    /// fall back to the `tuning_constants::default_*!()` basis-bound macros.
    asset_basis_bounds: Table<String, BasisBounds>,
    /// Per-underlying-asset Pyth Lazer feed ids. Admin must register an entry
    /// before `create_market_oracle` can be called for that asset. Stored as `u64` for type consistency
    /// with the other scalars on `OracleConfig`; narrowed to `u32` (Lazer's
    /// canonical feed-id width) at `registry::create_market_oracle`. Updating an
    /// entry here does NOT retroactively change existing oracles.
    asset_feed_ids: Table<String, u64>,
    /// Admin-tuned maximum age for Pyth spot to be considered canonical.
    pyth_spot_freshness_ms: u64,
    /// Admin-tuned maximum age of the Block Scholes price update used for basis
    /// and forward data in live snapshots.
    block_scholes_price_freshness_ms: u64,
    /// Admin-tuned maximum age of Block Scholes spot when Pyth is stale.
    block_scholes_fallback_freshness_ms: u64,
    /// Admin-tuned maximum age of the Block Scholes SVI update.
    block_scholes_svi_freshness_ms: u64,
}

// === Public-Package Functions ===

/// Admin-tuned Pyth spot freshness threshold (ms) used to seed new oracles.
public(package) fun pyth_spot_freshness_ms(oracle_config: &OracleConfig): u64 {
    oracle_config.pyth_spot_freshness_ms
}

/// Admin-tuned Block Scholes price freshness threshold (ms) used to seed new oracles.
public(package) fun block_scholes_price_freshness_ms(oracle_config: &OracleConfig): u64 {
    oracle_config.block_scholes_price_freshness_ms
}

/// Admin-tuned Block Scholes fallback freshness threshold (ms) used to seed new oracles.
public(package) fun block_scholes_fallback_freshness_ms(oracle_config: &OracleConfig): u64 {
    oracle_config.block_scholes_fallback_freshness_ms
}

/// Admin-tuned Block Scholes SVI freshness threshold (ms) used to seed new oracles.
public(package) fun block_scholes_svi_freshness_ms(oracle_config: &OracleConfig): u64 {
    oracle_config.block_scholes_svi_freshness_ms
}

/// Per-asset basis bounds currently registered for `asset`, or `None` if the
/// asset would fall back to the `tuning_constants::default_*!()` basis-bound macros
/// at `create_market_oracle`.
public(package) fun asset_basis_bounds(
    oracle_config: &OracleConfig,
    asset: String,
): Option<BasisBounds> {
    if (oracle_config.asset_basis_bounds.contains(asset)) {
        option::some(oracle_config.asset_basis_bounds[asset])
    } else {
        option::none()
    }
}

/// Per-asset Pyth Lazer feed id currently registered for `asset`, or `None`
/// if no entry exists. `create_market_oracle` requires a registered entry and aborts
/// with `EFeedIdNotConfigured` otherwise; this getter is for introspection.
public(package) fun asset_feed_id(oracle_config: &OracleConfig, asset: String): Option<u64> {
    if (oracle_config.asset_feed_ids.contains(asset)) {
        option::some(oracle_config.asset_feed_ids[asset])
    } else {
        option::none()
    }
}

/// Resolve the Pyth Lazer feed id registered for `asset`, or abort if none
/// has been set. Called by `registry::create_market_oracle` so operators can't pass
/// an arbitrary feed id — admin must bind `asset → feed_id` once per
/// underlying before the first market_oracle of that asset can be created.
public(package) fun resolve_feed_id(oracle_config: &OracleConfig, asset: String): u64 {
    assert!(oracle_config.asset_feed_ids.contains(asset), EFeedIdNotConfigured);
    oracle_config.asset_feed_ids[asset]
}

/// Return the maximum allowed operator spot deviation.
public(package) fun basis_bounds_max_spot_deviation(bounds: &BasisBounds): u64 {
    bounds.max_spot_deviation
}

/// Return the maximum allowed basis deviation.
public(package) fun basis_bounds_max_basis_deviation(bounds: &BasisBounds): u64 {
    bounds.max_basis_deviation
}

/// Return the minimum allowed basis ratio.
public(package) fun basis_bounds_min_basis(bounds: &BasisBounds): u64 {
    bounds.min_basis
}

/// Return the maximum allowed basis ratio.
public(package) fun basis_bounds_max_basis(bounds: &BasisBounds): u64 {
    bounds.max_basis
}

/// Create a new market_oracle-config registry seeded with the `tuning_constants::default_*!()`
/// freshness thresholds. `asset_basis_bounds` starts empty; any asset without
/// an explicit entry falls back to `default_basis_bounds()` at creation.
public(package) fun new(ctx: &mut TxContext): OracleConfig {
    OracleConfig {
        oracle_grids: table::new(ctx),
        oracle_ask_bounds: table::new(ctx),
        asset_basis_bounds: table::new(ctx),
        asset_feed_ids: table::new(ctx),
        pyth_spot_freshness_ms: tuning_constants::default_pyth_spot_freshness_ms!(),
        block_scholes_price_freshness_ms: tuning_constants::default_block_scholes_price_freshness_ms!(),
        block_scholes_fallback_freshness_ms: tuning_constants::default_block_scholes_fallback_freshness_ms!(),
        block_scholes_svi_freshness_ms: tuning_constants::default_block_scholes_svi_freshness_ms!(),
    }
}

/// Build an `MarketOracleBounds` snapshot for a new market_oracle with `underlying_asset`.
/// Freshness fields come from the admin-tuned global config; basis bounds
/// come from the per-asset entry if present, else the `tuning_constants::default_*!()`
/// basis-bound macros.
public(package) fun build_market_oracle_bounds(
    oracle_config: &OracleConfig,
    underlying_asset: String,
): MarketOracleBounds {
    let (
        max_spot_deviation,
        max_basis_deviation,
        min_basis,
        max_basis,
    ) = oracle_config.resolve_basis_bounds(underlying_asset);
    market_oracle::new_bounds(
        oracle_config.pyth_spot_freshness_ms,
        oracle_config.block_scholes_price_freshness_ms,
        oracle_config.block_scholes_fallback_freshness_ms,
        oracle_config.block_scholes_svi_freshness_ms,
        max_spot_deviation,
        max_basis_deviation,
        min_basis,
        max_basis,
    )
}

/// Admin setter: update the global Pyth spot freshness seed used by
/// subsequent `create_market_oracle` calls. Does NOT retroactively update existing
/// oracles — operators retune their own market_oracle fallback freshness if needed.
public(package) fun set_pyth_spot_freshness_ms(oracle_config: &mut OracleConfig, value: u64) {
    validate_freshness_ms(value);
    oracle_config.pyth_spot_freshness_ms = value;
}

/// Admin setter: update the global Block Scholes price freshness seed.
public(package) fun set_block_scholes_price_freshness_ms(oracle_config: &mut OracleConfig, value: u64) {
    validate_freshness_ms(value);
    oracle_config.block_scholes_price_freshness_ms = value;
}

/// Admin setter: update the global Block Scholes fallback freshness seed.
public(package) fun set_block_scholes_fallback_freshness_ms(
    oracle_config: &mut OracleConfig,
    value: u64,
) {
    validate_freshness_ms(value);
    oracle_config.block_scholes_fallback_freshness_ms = value;
}

/// Admin setter: update the global Block Scholes SVI freshness seed.
public(package) fun set_block_scholes_svi_freshness_ms(
    oracle_config: &mut OracleConfig,
    value: u64,
) {
    validate_freshness_ms(value);
    oracle_config.block_scholes_svi_freshness_ms = value;
}

/// Admin setter: set or update the per-asset basis bounds seed for `asset`.
/// Consumed by `build_market_oracle_bounds` at the next matching `create_market_oracle`.
/// Validates `min_basis < max_basis` and that both deviation fractions fit
/// within 1.0 (1e9 scale).
public(package) fun set_asset_basis_bounds(
    oracle_config: &mut OracleConfig,
    asset: String,
    max_spot_deviation: u64,
    max_basis_deviation: u64,
    min_basis: u64,
    max_basis: u64,
) {
    validate_basis_bounds_inputs(max_spot_deviation, max_basis_deviation, min_basis, max_basis);
    let bounds = BasisBounds { max_spot_deviation, max_basis_deviation, min_basis, max_basis };
    if (oracle_config.asset_basis_bounds.contains(asset)) {
        let row = &mut oracle_config.asset_basis_bounds[asset];
        *row = bounds;
    } else {
        oracle_config.asset_basis_bounds.add(asset, bounds);
    }
}

/// Admin setter: bind `asset → feed_id` so subsequent `create_market_oracle` calls
/// for that underlying resolve the Pyth Lazer feed id from config instead of
/// taking it as a PTB arg. Does NOT retroactively update existing oracles —
/// they keep the feed id snapshotted at their own creation time.
public(package) fun set_asset_feed_id(
    oracle_config: &mut OracleConfig,
    asset: String,
    feed_id: u64,
) {
    if (oracle_config.asset_feed_ids.contains(asset)) {
        let row = &mut oracle_config.asset_feed_ids[asset];
        *row = feed_id;
    } else {
        oracle_config.asset_feed_ids.add(asset, feed_id);
    }
}

/// Register the configured strike grid for a newly created market_oracle.
public(package) fun add_oracle_grid(
    oracle_config: &mut OracleConfig,
    oracle_id: ID,
    min_strike: u64,
    tick_size: u64,
) {
    let max_strike = min_strike + tick_size * constants::oracle_strike_grid_ticks!();
    let grid = OracleGrid {
        min_strike,
        max_strike,
        tick_size,
    };
    oracle_config.oracle_grids.add(oracle_id, grid);
}

/// Set or update a per-market_oracle ask-bound override. The caller must hold an
/// `MarketOracleCap` authorized for `market_oracle`. Validates the math invariant
/// `min < max < float_scaling`; the "no looser than the global default"
/// constraint is enforced by the caller (see `predict::set_oracle_ask_bounds`).
public(package) fun set_oracle_ask_bounds(
    oracle_config: &mut OracleConfig,
    market_oracle: &MarketOracle,
    cap: &MarketOracleCap,
    min: u64,
    max: u64,
) {
    market_oracle.assert_authorized_cap(cap);
    assert!(min < max, EInvalidAskBound);

    let oracle_id = market_oracle.id();
    let bounds = pricing::new_ask_bounds(min, max);
    if (oracle_config.oracle_ask_bounds.contains(oracle_id)) {
        let row = &mut oracle_config.oracle_ask_bounds[oracle_id];
        *row = bounds;
    } else {
        oracle_config.oracle_ask_bounds.add(oracle_id, bounds);
    }
}

/// Remove the per-market_oracle ask-bound override so the market_oracle inherits the global
/// default again. No-op if no override is currently set.
public(package) fun clear_oracle_ask_bounds(
    oracle_config: &mut OracleConfig,
    market_oracle: &MarketOracle,
    cap: &MarketOracleCap,
) {
    market_oracle.assert_authorized_cap(cap);
    let oracle_id = market_oracle.id();
    if (oracle_config.oracle_ask_bounds.contains(oracle_id)) {
        oracle_config.oracle_ask_bounds.remove(oracle_id);
    };
}

/// Return the per-market_oracle ask-bound override, or `None` if the market_oracle inherits
/// the global default.
public(package) fun ask_bounds_override(
    oracle_config: &OracleConfig,
    oracle_id: ID,
): Option<AskBounds> {
    if (oracle_config.oracle_ask_bounds.contains(oracle_id)) {
        option::some(oracle_config.oracle_ask_bounds[oracle_id])
    } else {
        option::none()
    }
}

/// Assert that a strike lies on the configured grid for this market_oracle.
public(package) fun assert_valid_strike(
    oracle_config: &OracleConfig,
    market_oracle: &MarketOracle,
    strike: u64,
) {
    let oracle_id = market_oracle.id();
    let (min_strike, tick_size, max_strike) = oracle_config.grid_params(oracle_id);

    assert!(strike >= min_strike && strike <= max_strike, EInvalidStrike);
    assert!((strike - min_strike) % tick_size == 0, EInvalidStrike);
}

/// Assert that a range key matches the market_oracle identity, expiry, and that both
/// strikes lie on the configured grid.
public(package) fun assert_range_key_matches(
    oracle_config: &OracleConfig,
    market_oracle: &MarketOracle,
    range_key: &RangeKey,
) {
    let oracle_id = market_oracle.id();

    assert!(range_key.oracle_id() == oracle_id, ERangeKeyOracleMismatch);
    assert!(range_key.expiry() == market_oracle.expiry(), ERangeKeyExpiryMismatch);
    if (range_key.lower_strike() != constants::neg_inf!()) {
        oracle_config.assert_valid_strike(market_oracle, range_key.lower_strike());
    };
    if (range_key.higher_strike() != constants::pos_inf!()) {
        oracle_config.assert_valid_strike(market_oracle, range_key.higher_strike());
    };
}

/// Load the configured strike-grid parameters for an market_oracle.
public(package) fun grid_params(oracle_config: &OracleConfig, oracle_id: ID): (u64, u64, u64) {
    assert!(oracle_config.oracle_grids.contains(oracle_id), EOracleConfigNotFound);
    let grid = oracle_config.oracle_grids.borrow(oracle_id);
    let grid_min = grid.min_strike;
    let grid_max = grid.max_strike;
    let tick_size = grid.tick_size;
    (grid_min, tick_size, grid_max)
}

// === Private Functions ===

/// Resolve `(max_spot_deviation, max_basis_deviation, min_basis, max_basis)`
/// for a given underlying asset, falling back to the constants defaults when
/// no per-asset entry is registered.
fun resolve_basis_bounds(
    oracle_config: &OracleConfig,
    underlying_asset: String,
): (u64, u64, u64, u64) {
    if (oracle_config.asset_basis_bounds.contains(underlying_asset)) {
        let b = oracle_config.asset_basis_bounds[underlying_asset];
        (b.max_spot_deviation, b.max_basis_deviation, b.min_basis, b.max_basis)
    } else {
        (
            tuning_constants::default_max_spot_deviation!(),
            tuning_constants::default_max_basis_deviation!(),
            tuning_constants::default_min_basis!(),
            tuning_constants::default_max_basis!(),
        )
    }
}

/// Validate an admin-tuned freshness threshold.
fun validate_freshness_ms(value: u64) {
    assert!(
        value > 0 && value <= tuning_constants::max_freshness_threshold_ms!(),
        EInvalidFreshnessThreshold,
    );
}

/// Validate per-asset basis circuit-breaker inputs before storing them.
fun validate_basis_bounds_inputs(
    max_spot_deviation: u64,
    max_basis_deviation: u64,
    min_basis: u64,
    max_basis: u64,
) {
    assert!(min_basis < max_basis, EInvalidBasisBounds);
    assert!(min_basis >= tuning_constants::min_basis_floor!(), EInvalidBasisBounds);
    assert!(max_basis <= tuning_constants::max_basis_ceiling!(), EInvalidBasisBounds);
    assert!(
        max_spot_deviation > 0 && max_spot_deviation <= tuning_constants::max_basis_deviation_ceiling!(),
        EInvalidBasisBounds,
    );
    assert!(
        max_basis_deviation > 0 && max_basis_deviation <= tuning_constants::max_basis_deviation_ceiling!(),
        EInvalidBasisBounds,
    );
}
