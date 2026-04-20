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

// === Staleness Thresholds ===

/// Default spot halt-gate threshold (3 seconds).
/// With the operator's 1s `update_prices` cadence, a 3s gate lets the fallback
/// path carry the oracle through arbitrary-length Lazer outages while still
/// halting within 3s when both feeds go silent.
public macro fun default_spot_staleness_threshold_ms(): u64 { 3_000 }

/// Default maximum age of the cached operator basis (60 seconds).
/// Consumed by `update_spot_from_lazer` (refuses to derive a forward against
/// a stale basis) and by `oracle_config::assert_live_oracle` /
/// `assert_quoteable_oracle` (refuses to quote against a stale basis).
/// Generous vs. the operator's 1s `update_prices` cadence.
public macro fun default_basis_staleness_threshold_ms(): u64 { 60_000 }

/// Hard upper bound (60s) for the oracle and basis staleness thresholds.
/// Admin setters reject anything larger — beyond this the liveness gate
/// stops meaningfully protecting quoting and settlement.
public macro fun max_staleness_threshold_ms(): u64 { 60_000 }

/// Default window within which the last Pyth Lazer spot push is treated as
/// the authoritative master spot (2 seconds). While Lazer is within this
/// window, `update_prices` refreshes basis/forward but does NOT overwrite
/// `oracle.prices.spot`. Beyond it, the operator's spot flows through as a
/// fallback. Independent of `default_spot_staleness_threshold_ms!()` (the hard
/// halt gate) which is always checked on top.
public macro fun default_lazer_authoritative_threshold_ms(): u64 { 2_000 }

/// Default window within which Lazer's last spot push is treated as the
/// authoritative settlement source (60 seconds). Longer than the live-update
/// window because settlement is irreversible — gate the terminal
/// `update_prices` settlement branch so the operator can't race-freeze while
/// Lazer is still credibly the settlement oracle. Matches
/// `max_staleness_threshold_ms!()` so settlement patience maxes at the same
/// ceiling admin can choose for other staleness windows.
public macro fun default_lazer_settlement_authoritative_threshold_ms(): u64 { 60_000 }

// === Basis Circuit Breaker ===

/// Default maximum per-push spot deviation accepted by `update_prices`
/// (2% in FLOAT_SCALING). Catches decimal errors, fat-finger pushes, and
/// BS outages that return garbage values. Admin can override per asset
/// via `registry::set_asset_basis_bounds` for assets with different
/// volatility profiles.
public macro fun default_max_spot_deviation(): u64 { 20_000_000 }

/// Default maximum per-push basis deviation accepted by `update_prices`
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
