// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Constants module - all protocol constants.
module deepbook_predict::constants;

// === Scaling ===
/// Fixed-point scaling factor (1e9) for math operations
const FLOAT_SCALING: u64 = 1_000_000_000;
/// Price scaling factor (1e6) - USDC has 6 decimals
const PRICE_SCALING: u64 = 1_000_000;
/// Basis points scaling (10_000 = 100%)
const BPS_SCALING: u64 = 10_000;

// === Default Config ===
/// Max single trade as % of available capital (5%)
const DEFAULT_MAX_SINGLE_TRADE_PCT: u64 = 500_000_000; // 5% in FLOAT_SCALING
/// Max exposure per market as % of vault capital (20%)
const DEFAULT_MAX_EXPOSURE_PER_MARKET_PCT: u64 = 200_000_000; // 20%
/// Max total exposure as % of vault capital (80%)
const DEFAULT_MAX_TOTAL_EXPOSURE_PCT: u64 = 800_000_000; // 80%
/// Base spread in basis points (1%)
const DEFAULT_BASE_SPREAD_BPS: u64 = 100;
/// Max spread adjustment in basis points (2%)
const DEFAULT_MAX_SPREAD_ADJUSTMENT_BPS: u64 = 200;
/// Oracle staleness threshold (30 seconds)
const DEFAULT_ORACLE_STALENESS_MS: u64 = 30_000;
/// LP withdrawal lockup period (24 hours)
const DEFAULT_MIN_LOCKUP_MS: u64 = 86_400_000;
/// Grace period for claiming positions after expiry (7 days)
const GRACE_PERIOD_MS: u64 = 604_800_000;
/// Maximum number of strikes per oracle
const MAX_STRIKES_QUANTITY: u64 = 20;

// === Market Constants ===
/// Direction: price above strike at expiry
const DIRECTION_UP: u8 = 0;
/// Direction: price below strike at expiry
const DIRECTION_DOWN: u8 = 1;

// === Time Constants ===
const MS_PER_SECOND: u64 = 1_000;
const MS_PER_MINUTE: u64 = 60_000;
const MS_PER_HOUR: u64 = 3_600_000;
const MS_PER_DAY: u64 = 86_400_000;
const MS_PER_YEAR: u64 = 31_536_000_000;

// === Public Functions ===

public fun float_scaling(): u64 { FLOAT_SCALING }

public fun price_scaling(): u64 { PRICE_SCALING }

public fun bps_scaling(): u64 { BPS_SCALING }

public fun default_max_single_trade_pct(): u64 { DEFAULT_MAX_SINGLE_TRADE_PCT }

public fun default_max_exposure_per_market_pct(): u64 { DEFAULT_MAX_EXPOSURE_PER_MARKET_PCT }

public fun default_max_total_exposure_pct(): u64 { DEFAULT_MAX_TOTAL_EXPOSURE_PCT }

public fun default_base_spread_bps(): u64 { DEFAULT_BASE_SPREAD_BPS }

public fun default_max_spread_adjustment_bps(): u64 { DEFAULT_MAX_SPREAD_ADJUSTMENT_BPS }

public fun default_oracle_staleness_ms(): u64 { DEFAULT_ORACLE_STALENESS_MS }

public fun default_min_lockup_ms(): u64 { DEFAULT_MIN_LOCKUP_MS }

public fun grace_period_ms(): u64 { GRACE_PERIOD_MS }

public fun max_strikes_quantity(): u64 { MAX_STRIKES_QUANTITY }

public fun direction_up(): u8 { DIRECTION_UP }

public fun direction_down(): u8 { DIRECTION_DOWN }

public fun ms_per_second(): u64 { MS_PER_SECOND }

public fun ms_per_minute(): u64 { MS_PER_MINUTE }

public fun ms_per_hour(): u64 { MS_PER_HOUR }

public fun ms_per_day(): u64 { MS_PER_DAY }

public fun ms_per_year(): u64 { MS_PER_YEAR }
