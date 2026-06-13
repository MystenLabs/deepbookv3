// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Upgrade-required protocol constants for Predict.
///
/// Scaling conventions (aligned with DeepBook):
/// - Prices/percentages use FLOAT_SCALING (1e9): 500_000_000 = 50%
/// - Quantities are in 6-decimal quote units: 1_000_000 = 1 contract = one quote unit
/// - At settlement, winners receive `quantity` directly
/// - Use `math` for all fixed-point scaling and mul/div operations
module deepbook_predict::constants;

// === Package Versioning ===

/// Current package version. Bumped on each upgrade and added to the protocol
/// `allowed_versions` set by admin so version-gated entry points keep working.
public macro fun current_version(): u64 { 1 }

// === Scaling ===

/// Decimal exponent of `math::float_scaling!()` (i.e. `math::float_scaling!() == 10^9`).
/// Used when normalizing oracle prices from their native `(magnitude, exponent)`
/// form into the package's 1e9-scaled `u64`.
public(package) macro fun float_scaling_decimals(): u64 { 9 }

/// Decimals of the DUSDC settlement asset (the pool's denomination).
public macro fun dusdc_decimals(): u8 { 6 }

// === Position Sizing ===

/// Minimum position quantity increment.
public macro fun position_lot_size(): u64 { 10_000 }

/// Minimum mint-time net premium, excluding trading and builder fees.
public macro fun min_net_premium(): u64 { 1_000_000 }

// === Leverage ===

/// Window before expiry over which the leverage floor index rises.
public(package) macro fun leverage_floor_window_ms(): u64 { 31_536_000_000 }

/// Entry probability below which only 1x mints are allowed.
public(package) macro fun leverage_one_x_only_price_threshold(): u64 { 100_000_000 }

/// Entry probability below which leverage is capped at 2x.
public(package) macro fun leverage_two_x_max_price_threshold(): u64 { 200_000_000 }

// === Staking ===

/// Raw units in one whole DEEP (DEEP uses 6 decimals).
public macro fun deep_decimals(): u64 { 1_000_000 }

/// Trading-fee discount at full active stake, in FLOAT_SCALING (fixed 50% cap).
/// The loss rebate has no staking-side cap — its size is governed by the
/// per-expiry `trading_loss_rebate_rate` in `expiry_cash_config`.
public(package) macro fun max_fee_discount(): u64 { 500_000_000 }

// === Liquidation ===

/// Divisor for the passive tail slice of each liquidation candidate budget; the
/// head-priority slice takes the remainder. Divisor 3 => 1/3 tail, 2/3 head.
public(package) macro fun liquidation_tail_scan_divisor(): u64 { 3 }

// === Builder Fees ===

/// Add-on builder fee as a fraction of the normal trade fee.
public macro fun builder_fee_multiplier(): u64 { 100_000_000 }

/// Maximum all-in builder fee rate per traded quantity.
public macro fun max_builder_fee_rate(): u64 { 5_000_000 }

// === Time Constants ===

/// Milliseconds in a 365-day year.
public(package) macro fun ms_per_year(): u64 { 31_536_000_000 }

// === SVI Oracle Bounds ===

/// SVI `sigma` lower bound: 1e-3 in 1e9 fixed-point.
public(package) macro fun svi_sigma_min(): u64 { 1_000_000 }

/// SVI `sigma` upper bound: 100.0 in 1e9 fixed-point.
public(package) macro fun svi_sigma_max(): u64 { 100_000_000_000 }

// === Oracle Strike Grid ===

/// Fixed number of strike ticks each oracle must cover.
public macro fun oracle_strike_grid_ticks(): u64 { 100_000 }

/// Highest boundary index in the shared order-ID / strike-grid boundary domain.
/// Index 0 is the −inf sentinel, 1..=ticks+1 are the finite strikes, and ticks+2
/// is the +inf sentinel. Read by both `order` (packed-ID encoding bound) and
/// `strike_grid` (the +inf boundary index).
public(package) macro fun max_boundary_index(): u64 { oracle_strike_grid_ticks!() + 2 }

/// Granularity unit for oracle tick sizes; every tick_size must be a multiple of this value.
public macro fun oracle_tick_size_unit(): u64 { 10_000 }

/// Sentinel lower strike for ranges open to negative infinity.
public macro fun neg_inf(): u64 { 0 }

/// Sentinel upper strike for ranges open to positive infinity.
public macro fun pos_inf(): u64 { std::u64::max_value!() }

// === Settlement Sampling ===

/// Window before expiry over which fresh spot samples are collected for the
/// random-average settlement price.
public(package) macro fun settlement_sample_window_ms(): u64 { 60_000 }

/// Minimum pre-expiry samples required before settlement uses the sampled-average
/// path. With fewer samples, settlement falls through to the next latched source
/// in priority order.
public(package) macro fun min_settlement_samples(): u64 { 30 }

/// Maximum pre-expiry spot samples retained per market (most recent kept). Bounds
/// storage/gas; with the half-subset mean, the averaged subset is <= this / 2.
public(package) macro fun max_settlement_samples(): u64 { 200 }

// === NAV Valuation ===

/// Max up-price spread (1e9-scaled probability) permitted to collapse a payout
/// subtree to one interpolated price in the exact-NAV linear walk. The per-subtree
/// error introduced is bounded by `tolerance * subtree_quantity`; the correction
/// (floor) term is always priced exactly regardless. `0` disables interpolation,
/// so the walk is fully exact.
///
/// PLACEHOLDER = 0 (exact, interpolation off): the exact walk is the default and
/// interpolation is a benchmark-gated fallback (see ASYNC_NAV_REDESIGN §2.3.2). A
/// nonzero tolerance must be sized by the §7 gas/accuracy benchmark before it is
/// enabled — it is upgrade-required, not admin-tunable.
public(package) macro fun nav_interpolation_price_tolerance(): u64 { 0 }

// === PredictManager Derivation ===

/// `PredictManagerKey` u64 slot for sender-owned managers created via
/// `predict_manager::new`.
public macro fun sender_owned_manager_slot(): u64 { 0 }

/// `PredictManagerKey` u64 slot for self-owned managers created via
/// `predict_manager::new_self_owned`.
public macro fun self_owned_manager_slot(): u64 { 1 }
