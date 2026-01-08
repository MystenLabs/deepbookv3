// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Constants module - all protocol constants.
///
/// Scaling factors:
/// - FLOAT_SCALING: 1_000_000_000 (1e9) for fixed-point math
/// - PRICE_SCALING: 1_000_000 (1e6) for prices (USDC has 6 decimals)
/// - BPS_SCALING: 10_000 for basis points
///
/// Default config values:
/// - DEFAULT_MAX_SINGLE_TRADE_PCT: 5% of available capital
/// - DEFAULT_MAX_EXPOSURE_PER_MARKET_PCT: 20% of vault capital
/// - DEFAULT_MAX_TOTAL_EXPOSURE_PCT: 80% of vault capital
/// - DEFAULT_BASE_SPREAD_BPS: 100 (1%)
/// - DEFAULT_MAX_SPREAD_ADJUSTMENT_BPS: 200 (2%)
/// - DEFAULT_ORACLE_STALENESS_MS: 30_000 (30 seconds)
/// - DEFAULT_MIN_LOCKUP_MS: 86_400_000 (24 hours)
/// - GRACE_PERIOD_MS: 604_800_000 (7 days)
///
/// Market constants:
/// - DIRECTION_UP: 0
/// - DIRECTION_DOWN: 1
///
/// Time constants:
/// - MS_PER_SECOND: 1_000
/// - MS_PER_HOUR: 3_600_000
/// - MS_PER_DAY: 86_400_000
/// - MS_PER_YEAR: 31_536_000_000
module deepbook_predict::constants;



// === Scaling ===

// === Default Config ===

// === Market Constants ===

// === Time Constants ===

// === Public Functions ===
