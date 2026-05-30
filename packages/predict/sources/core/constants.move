// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Upgrade-required protocol constants for Predict.
///
/// Scaling conventions (aligned with DeepBook):
/// - Prices/percentages use FLOAT_SCALING (1e9): 500_000_000 = 50%
/// - Quantities are in 6-decimal quote units: 1_000_000 = 1 contract = one quote unit
/// - At settlement, winners receive `quantity` directly
/// - Use deepbook::math for all mul/div operations
module deepbook_predict::constants;

// === Package Versioning ===

/// Current package version. Bumped on each upgrade and added to the protocol
/// `allowed_versions` set by admin so version-gated entry points keep working.
public macro fun current_version(): u64 { 1 }

// === Scaling ===

/// Fixed-point scaling factor (1e9) for math operations and prices.
/// 500_000_000 = 50%, 1_000_000_000 = 100%
public macro fun float_scaling(): u64 { 1_000_000_000 }

/// Decimal exponent of `float_scaling!()` (i.e. `float_scaling!() == 10^9`).
/// Used when normalizing oracle prices from their native `(magnitude, exponent)`
/// form into the package's 1e9-scaled `u64`.
public macro fun float_scaling_decimals(): u64 { 9 }

// === Position Sizing ===

/// Minimum position quantity increment.
public macro fun position_lot_size(): u64 { 10_000 }

/// Minimum mint-time user principal, excluding trading and builder fees.
public macro fun min_order_principal(): u64 { 1_000_000 }

// === Leverage ===

/// Window before expiry over which the leverage floor index rises.
public macro fun leverage_floor_window_ms(): u64 { 31_536_000_000 }

/// Entry probability below which only 1x mints are allowed.
public(package) macro fun leverage_one_x_only_price_threshold(): u64 { 100_000_000 }

/// Entry probability below which leverage is capped at 2x.
public(package) macro fun leverage_two_x_max_price_threshold(): u64 { 200_000_000 }

// === Staking ===

/// Raw units in one whole DEEP (DEEP uses 6 decimals).
public macro fun deep_decimals(): u64 { 1_000_000 }

/// Trading-fee discount at full active stake, in FLOAT_SCALING (fixed 50% cap).
/// The loss rebate has no staking-side cap — its size is governed by the
/// per-expiry `trading_loss_rebate_rate` in `fee_config`.
public macro fun max_fee_discount(): u64 { 500_000_000 }

// === Liquidation ===

/// Divisor used to reserve a head-priority slice of each liquidation candidate budget.
public macro fun liquidation_head_scan_divisor(): u64 { 3 }

// === Builder Fees ===

/// Add-on builder fee as a fraction of the normal trade fee.
public macro fun builder_fee_multiplier(): u64 { 100_000_000 }

/// Maximum all-in builder fee rate per traded quantity.
public macro fun max_builder_fee_rate(): u64 { 5_000_000 }

// === Trade Fee Ramp ===

/// Window before expiry over which the trade fee ramps up to a market's
/// per-feed max multiplier; the ramp is inactive earlier. Read live by
/// `pricing::fee_rate` (the per-feed max multiplier stays snapshotted per market).
public macro fun expiry_fee_window_ms(): u64 { 60 * 60 * 24 * 1000 }

// === Time Constants ===

/// Milliseconds in a 365-day year.
public macro fun ms_per_year(): u64 { 31_536_000_000 }

// === Curve Builder ===

/// Number of sample points for adaptive curve building.
public macro fun curve_samples(): u64 { 50 }

/// Minimum interval between curve sample points ($0.001 in FLOAT_SCALING)
public macro fun min_curve_interval(): u64 { 1_000_000 }

// === Oracle Strike Grid ===

/// Fixed number of strike ticks each oracle must cover.
public macro fun oracle_strike_grid_ticks(): u64 { 100_000 }

/// Granularity unit for oracle tick sizes; every tick_size must be a multiple of this value.
public macro fun oracle_tick_size_unit(): u64 { 10_000 }

/// Expiries within this window preallocate the smallest centered NAV matrix span.
public macro fun short_expiry_preallocation_window_ms(): u64 { 60 * 60 * 1000 }

/// Expiries within this window preallocate the medium centered NAV matrix span.
public macro fun medium_expiry_preallocation_window_ms(): u64 { 60 * 60 * 24 * 1000 }

/// Centered strike ticks preallocated for expiries within one hour.
public macro fun short_expiry_preallocated_ticks(): u64 { 10_000 }

/// Centered strike ticks preallocated for expiries within one day.
public macro fun medium_expiry_preallocated_ticks(): u64 { 25_000 }

/// Centered strike ticks preallocated for later expiries.
public macro fun default_expiry_preallocated_ticks(): u64 { 50_000 }

/// Sentinel lower strike for ranges open to negative infinity.
public macro fun neg_inf(): u64 { 0 }

/// Sentinel upper strike for ranges open to positive infinity.
public macro fun pos_inf(): u64 { std::u64::max_value!() }
