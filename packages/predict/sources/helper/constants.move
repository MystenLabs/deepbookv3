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

// === Leverage ===

/// Window before expiry over which the leverage floor index rises.
public macro fun leverage_floor_window_ms(): u64 { 31_536_000_000 }

// === Staking ===

/// Milliseconds in a day; DEEP stake lock periods are expressed in whole days.
public macro fun day_ms(): u64 { 86_400_000 }

/// Staking power per tier, in raw DEEP units (DEEP has 6 decimals), i.e. 10k DEEP.
/// Each whole tier of power grants one step of fee discount and loss rebate.
public macro fun stake_tier_step(): u64 { 10_000_000_000 }

/// Maximum number of staking tiers; caps the fee discount at 50% and the loss
/// rebate at 100%.
public macro fun max_stake_tiers(): u64 { 10 }

/// Trading-fee discount granted per staking tier, in FLOAT_SCALING (5%).
public macro fun fee_discount_per_tier(): u64 { 50_000_000 }

/// Trading-loss rebate fraction granted per staking tier, in FLOAT_SCALING (10%).
public macro fun rebate_per_tier(): u64 { 100_000_000 }

// === Builder Fees ===

/// Add-on builder fee as a fraction of the normal trade fee.
public macro fun builder_fee_multiplier(): u64 { 100_000_000 }

/// Maximum all-in builder fee rate per traded quantity.
public macro fun max_builder_fee_rate(): u64 { 5_000_000 }

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

/// Sentinel lower strike for ranges open to negative infinity.
public macro fun neg_inf(): u64 { 0 }

/// Sentinel upper strike for ranges open to positive infinity.
public macro fun pos_inf(): u64 { std::u64::max_value!() }
