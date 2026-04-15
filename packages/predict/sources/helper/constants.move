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

/// Base spread multiplier for Bernoulli scaling (2% in FLOAT_SCALING).
/// Effective spread at 50c = base_spread * √(0.5 * 0.5) = base_spread * 0.5 = 1%
public macro fun default_base_spread(): u64 { 20_000_000 }

/// Minimum spread floor (0.5% in FLOAT_SCALING)
public macro fun default_min_spread(): u64 { 5_000_000 }

/// Utilization multiplier applied to base spread (2x in FLOAT_SCALING)
/// Controls how aggressively spread widens as vault approaches capacity
public macro fun default_utilization_multiplier(): u64 { 2_000_000_000 }

/// Minimum ask price the protocol will allow at mint (1% in FLOAT_SCALING)
public macro fun default_min_ask_price(): u64 { 10_000_000 }

/// Maximum ask price the protocol will allow at mint (99% in FLOAT_SCALING)
public macro fun default_max_ask_price(): u64 { 990_000_000 }

// === Time Constants ===

public macro fun ms_per_year(): u64 { 31_536_000_000 }

/// Default spot halt-gate threshold (3 seconds).
/// With the operator's 1s `update_basis` cadence, a 3s gate lets the fallback
/// path carry the oracle through arbitrary-length Lazer outages while still
/// halting within 3s when both feeds go silent.
public macro fun default_staleness_threshold_ms(): u64 { 3_000 }

/// Default maximum age of the cached operator basis (60 seconds).
/// Consumed by `update_spot_from_lazer` (refuses to derive a forward against
/// a stale basis) and by `oracle_config::assert_live_oracle` /
/// `assert_quoteable_oracle` (refuses to quote against a stale basis).
/// Generous vs. the operator's 1s `update_basis` cadence.
public macro fun default_basis_staleness_threshold_ms(): u64 { 60_000 }

/// Hard upper bound (60s) for the oracle and basis staleness thresholds.
/// Admin setters reject anything larger — beyond this the liveness gate
/// stops meaningfully protecting quoting and settlement.
public macro fun max_staleness_threshold_ms(): u64 { 60_000 }

/// Default window within which the last Pyth Lazer spot push is treated as
/// the authoritative master spot (2 seconds). While Lazer is within this
/// window, `update_basis` refreshes basis/forward but does NOT overwrite
/// `oracle.prices.spot`. Beyond it, the operator's spot flows through as a
/// fallback. Independent of `default_staleness_threshold_ms!()` (the hard
/// halt gate) which is always checked on top.
public macro fun default_lazer_authoritative_threshold_ms(): u64 { 2_000 }

// === Basis Circuit Breaker ===

/// Default maximum per-push spot deviation accepted by `update_basis`
/// (10% in FLOAT_SCALING). Catches decimal errors, fat-finger pushes, and
/// BS outages that return garbage values.
public macro fun default_max_basis_spot_deviation(): u64 { 100_000_000 }

/// Default maximum per-push basis deviation accepted by `update_basis`
/// (5% in FLOAT_SCALING). Basis moves slowly; a large per-push move is
/// always suspicious.
public macro fun default_max_basis_deviation(): u64 { 50_000_000 }

/// Default minimum allowed absolute basis value (0.9 in FLOAT_SCALING).
/// Basis = forward / spot; short-dated expiries should stay near 1.0.
public macro fun default_min_basis(): u64 { 900_000_000 }

/// Default maximum allowed absolute basis value (1.1 in FLOAT_SCALING).
public macro fun default_max_basis(): u64 { 1_100_000_000 }

// === Curve Builder ===

/// Default number of sample points for adaptive curve building
public macro fun default_curve_samples(): u64 { 50 }

/// Minimum interval between curve sample points ($0.001 in FLOAT_SCALING)
public macro fun min_curve_interval(): u64 { 1_000_000 }

// === Oracle Strike Grid ===

/// Fixed number of strike ticks each oracle must cover.
public macro fun oracle_strike_grid_ticks(): u64 { 100_000 }

/// Granularity unit for oracle tick sizes; every tick_size must be a multiple of this value.
public macro fun oracle_tick_size_unit(): u64 { 10_000 }

/// Required decimals for all accepted quote assets in phase 1.
public macro fun required_quote_decimals(): u8 { 6 }
