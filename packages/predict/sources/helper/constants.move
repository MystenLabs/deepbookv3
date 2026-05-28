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

/// Raw units in one whole DEEP (DEEP uses 6 decimals).
public macro fun deep_decimals(): u64 { 1_000_000 }

/// Lock horizon for full staking-power weight: 2 years. Shorter remaining locks
/// earn proportionally less power.
public macro fun max_stake_period_ms(): u64 { 2 * ms_per_year!() }

/// Maximum stake lock in whole days (the 2-year horizon). Locks beyond this are
/// rejected at the staking entry point.
public macro fun max_lock_days(): u64 { max_stake_period_ms!() / day_ms!() }

/// Staking power at which trading benefits reach their maximum: 100k DEEP.
/// Below this, benefits scale linearly with power; above it they stay capped.
public macro fun max_benefit_power(): u64 { 100_000 * deep_decimals!() }

/// Trading-fee discount at full benefit power, in FLOAT_SCALING (50%).
public macro fun max_fee_discount(): u64 { 500_000_000 }

/// Loss-rebate share at full benefit power, in FLOAT_SCALING (100%).
public macro fun max_rebate_fraction(): u64 { 1_000_000_000 }

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
