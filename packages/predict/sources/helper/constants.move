// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Constants module - all protocol constants.
///
/// Scaling conventions (aligned with DeepBook):
/// - Prices/percentages use FLOAT_SCALING (1e9): 500_000_000 = 50%
/// - Quantities are in 6-decimal quote units: 1_000_000 = 1 contract = one quote unit
/// - At settlement, winners receive `quantity` directly
/// - Use deepbook::math for all mul/div operations
module deepbook_predict::constants;

// === Scaling ===

/// Fixed-point scaling factor (1e9) for math operations and prices.
/// 500_000_000 = 50%, 1_000_000_000 = 100%
public macro fun float_scaling(): u64 { 1_000_000_000 }

/// Decimal exponent of `float_scaling!()` (i.e. `float_scaling!() == 10^9`).
/// Used when normalizing oracle prices from their native `(magnitude, exponent)`
/// form into the package's 1e9-scaled `u64`.
public macro fun float_scaling_decimals(): u64 { 9 }

// === Time Constants ===

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

public macro fun neg_inf(): u64 { 0 }
public macro fun pos_inf(): u64 { std::u64::max_value!() }
