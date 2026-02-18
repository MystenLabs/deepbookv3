// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Constants module - all protocol constants.
///
/// Scaling conventions (aligned with DeepBook):
/// - Prices/percentages use FLOAT_SCALING (1e9): 500_000_000 = 50%
/// - Quantities are in Quote units (USDC with 6 decimals): 1_000_000 = 1 contract = $1
/// - At settlement, winners receive `quantity` directly (already in USDC units)
/// - Use deepbook::math for all mul/div operations
module deepbook_predict::constants;

// === Scaling ===

/// Fixed-point scaling factor (1e9) for math operations and prices.
/// 500_000_000 = 50%, 1_000_000_000 = 100%
public macro fun float_scaling(): u64 { 1_000_000_000 }

// === Default Config ===

/// Max total exposure as % of vault capital (80% in FLOAT_SCALING)
public macro fun default_max_total_exposure_pct(): u64 { 800_000_000 }

/// Base spread (1% in FLOAT_SCALING = 10_000_000)
public macro fun default_base_spread(): u64 { 10_000_000 }

/// Max skew multiplier applied to base spread (1x in FLOAT_SCALING)
/// At full imbalance, spread ranges from 0 to 2 * max_skew_multiplier * base_spread
public macro fun default_max_skew_multiplier(): u64 { 1_000_000_000 }

/// Utilization multiplier applied to base spread (2x in FLOAT_SCALING)
/// Controls how aggressively spread widens as vault approaches capacity
public macro fun default_utilization_multiplier(): u64 { 2_000_000_000 }

/// LP withdrawal lockup period (24 hours)
public macro fun default_min_lockup_ms(): u64 { 86_400_000 }

// === Time Constants ===

public macro fun ms_per_year(): u64 { 31_536_000_000 }

/// Oracle staleness threshold (30 seconds)
public macro fun staleness_threshold_ms(): u64 { 30_000 }
