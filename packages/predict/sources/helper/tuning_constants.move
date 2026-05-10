// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Admin-tunable defaults paired with hard floor/ceiling bounds.
///
/// Every macro in this module falls into one of two roles:
/// - `default_*` — the value an oracle or config is seeded with at creation.
/// - `*_floor` / `*_ceiling` / `max_*` — hard admin-safety envelope enforced
///   by setter validation; admin can retune within it, but not past it.
///
/// Split out of `constants.move` so the admin-safety envelope is visible at
/// the module-structure level rather than buried alongside fixed protocol
/// constants.
module deepbook_predict::tuning_constants;

// === Freshness Thresholds ===

/// Default maximum age of the Block Scholes spot/forward update (3 seconds).
/// This single gate covers both live basis reads and Block Scholes fallback settlement.
public macro fun default_block_scholes_prices_freshness_ms(): u64 { 3_000 }

/// Default maximum age of the Block Scholes SVI update (60 seconds).
public macro fun default_block_scholes_svi_freshness_ms(): u64 { 60_000 }

/// Hard upper bound (60s) for oracle freshness thresholds.
/// Admin setters reject anything larger — beyond this the liveness gate
/// stops meaningfully protecting quoting.
public macro fun max_freshness_threshold_ms(): u64 { 60_000 }

/// Default window within which the latest Pyth spot update is treated as
/// canonical (2 seconds). While Pyth is fresh, live reads use Pyth spot and
/// derive forward from the latest Block Scholes basis. Beyond it, Block
/// Scholes spot/forward can be used as the fallback if fresh.
public macro fun default_pyth_spot_freshness_ms(): u64 { 2_000 }

// === Basis Circuit Breaker ===

/// Default maximum per-push spot deviation accepted by Block Scholes price updates
/// (2% in FLOAT_SCALING). Catches decimal errors, fat-finger pushes, and
/// BS outages that return garbage values. Operators can retune per market
/// via `market_oracle::set_basis_bounds` when needed.
public macro fun default_max_spot_deviation(): u64 { 20_000_000 }

/// Default maximum per-push basis deviation accepted by Block Scholes price updates
/// (2% in FLOAT_SCALING). Basis = forward / spot moves slowly relative
/// to spot; a large per-push move is always suspicious. Tighter than
/// the absolute `[min_basis, max_basis]` bounds so a single push can't
/// sweep the entire allowed range.
public macro fun default_max_basis_deviation(): u64 { 20_000_000 }

/// Default minimum allowed absolute basis value (0.9 in FLOAT_SCALING).
/// Basis = forward / spot; short-dated expiries should stay near 1.0.
public macro fun default_min_basis(): u64 { 900_000_000 }

/// Default maximum allowed absolute basis value (1.1 in FLOAT_SCALING).
public macro fun default_max_basis(): u64 { 1_100_000_000 }

/// Hard ceiling (10%) on per-push deviation caps admitted by the admin
/// basis-bound setters. 5× the 2% default — loose enough for market stress,
/// tight enough that no single admin call can push the guard toward the
/// 100% no-op.
public macro fun max_basis_deviation_ceiling(): u64 { 100_000_000 }

/// Hard floor (0.5) on `min_basis` admitted by the admin basis-bound setters.
/// Basis = forward / spot sits near 1.0 for short-dated expiries; even deep
/// backwardation rarely dips below 0.5.
public macro fun min_basis_floor(): u64 { 500_000_000 }

/// Hard ceiling (2.0) on `max_basis` admitted by the admin basis-bound
/// setters. Symmetric with `min_basis_floor`: wide enough for contango
/// spikes, tight enough that `max_basis = u64::MAX` is rejected.
public macro fun max_basis_ceiling(): u64 { 2_000_000_000 }
