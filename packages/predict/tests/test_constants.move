// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Shared constants for Predict test code — the single source of truth for the
/// market/price/strike/supply values the fixtures bring up. Values that exist in
/// the production `constants` or `math` modules are aliased from them, never
/// duplicated; the rest are deliberate test-fixture choices documented inline.
#[test_only]
module deepbook_predict::test_constants;

use deepbook_predict::constants;
use fixed_math::math;

// === Test Addresses ===
const ADMIN: address = @0x0;
const ALICE: address = @0xA;
const BOB: address = @0xB;
const CAROL: address = @0xC;

public fun admin(): address { ADMIN }

public fun alice(): address { ALICE }

public fun bob(): address { BOB }

public fun carol(): address { CAROL }

// === Unit accessors (aliased from production modules) ===

/// FLOAT_SCALING (1e9): `500_000_000` = 50%, `1_000_000_000` = 100%.
public fun float(): u64 { math::float_scaling!() }

/// One whole DUSDC quote unit = `10^dusdc_decimals!()` = `1_000_000` raw units.
public fun dusdc_unit(): u64 { 10u64.pow(constants::dusdc_decimals!()) }

// === Default market bring-up (test-fixture choices) ===

/// Pyth feed id the default fixture registers.
public fun pyth_feed_id(): u32 { 1 }

/// Wall-clock the fixture's `Clock` starts at.
public fun now_ms(): u64 { 100_000 }

/// Source timestamp for the bootstrap/live oracle seed (< `now_ms`, within
/// staleness so updates are accepted).
public fun live_source_timestamp_ms(): u64 { 99_000 }

/// Default oracle tick size. Must be a multiple of `oracle_tick_size_unit`
/// (10_000) and small enough that `pos_inf_tick * tick_size` fits in u64; 1e9 is.
/// Strikes are absolute ticks: `raw_strike = tick * tick_size`.
public fun default_tick_size(): u64 { 1_000_000_000 }

/// The canonical finite strike tick the flow tests mint against. With the default
/// 1e9 tick size it maps to the raw strike `100e9` (`default_strike_tick *
/// default_tick_size`), the strike of `default_live_price` (≈50% for a
/// `(strike_tick, +inf)` UP range).
public fun default_strike_tick(): u64 { 100 }

/// A representative finite raw strike (`default_strike_tick * default_tick_size =
/// 100e9`), used by the direct-pricing tests that take raw strikes.
public fun min_finite_strike(): u64 { 100_000_000_000 }

/// Default DUSDC cash seeded into expiry markets while pool funding is absent.
public fun default_seeded_expiry_cash(): u64 { 300_000_000_000 }

/// Back-compat alias for older fixture call sites.
public fun default_initial_supply(): u64 { default_seeded_expiry_cash() }

/// Protocol-reserve profit share the default fixture sets (40% in FLOAT_SCALING).
public fun protocol_reserve_share(): u64 { 400_000_000 }

// === Default expiry / trade flow (for `setup_everything`) ===

/// Default expiry for the composite bring-up: ~1 year out (`now + ~365d`), past
/// the leverage-floor window so the floor schedule is flat and >1x mints are
/// admissible — the broadly-useful default for flow tests.
public fun default_expiry_ms(): u64 { 31_536_100_000 }

/// Default live price seeded by `prepare_live_oracle` in the composite bring-up;
/// sits at `min_finite_strike` (≈50% for a `[min_strike, +inf)` range).
public fun default_live_price(): u64 { 100_000_000_000 }

/// Default SVI `a` for live oracle test fixtures.
public fun default_svi_a(): u64 { 1 }

/// Default SVI `b` for live oracle test fixtures.
public fun default_svi_b(): u64 { 10_000 }

/// Default SVI `rho` magnitude for live oracle test fixtures: +1.0.
public fun default_svi_rho_magnitude(): u64 { math::float_scaling!() }

/// Default SVI `m` for live oracle test fixtures: far enough right to keep the
/// wing contribution rounded to zero for default-grid strikes.
public fun default_svi_m(): u64 { 10 * math::float_scaling!() }

/// Default SVI `sigma` for live oracle test fixtures: 1e-3 in 1e9 fixed point, the
/// lower edge of propbook's accepted vol-of-vol band.
public fun default_svi_sigma(): u64 { 1_000_000 }

/// Default trader-manager deposit in the composite bring-up; large enough to fund
/// several leveraged mints plus fees.
public fun default_manager_deposit(): u64 { 30_000_000_000 }

// === Shared happy-path flow values (the short-expiry lifecycle tests) ===

/// 1x leverage in FLOAT_SCALING (a flat floor schedule => zero floor shares).
public fun leverage_one_x(): u64 { math::float_scaling!() }

/// Short expiry (`now + 100s`) used by the lifecycle/payout flow tests: near
/// enough that the leverage floor schedule is non-flat (a 2x order carries a real
/// floor), unlike the far `default_expiry_ms`.
public fun short_expiry_ms(): u64 { 200_000 }

/// Standard single-order mint quantity for the flow tests (1e9 = 1_000 contracts).
public fun mint_quantity(): u64 { 1_000_000_000 }

/// Standard trader deposit for the short-expiry flow tests (covers one mint's
/// net_premium + fee, with room for the winning payout).
public fun mint_deposit(): u64 { 1_000_000_000 }
