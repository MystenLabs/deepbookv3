// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Defines Predict's upgrade-required scales, hard limits, time units, and event discriminators.
/// Prices, probabilities, and rates use 1e9 fixed point; DUSDC, PLP, DEEP, and contract quantities use six decimal base units unless stated otherwise.
module deepbook_predict::constants;

// === Package Versioning ===

/// Returns the package version compared against `ProtocolConfig.version_watermark` by version-gated entrypoints.
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

// === Pool Funding ===

/// DUSDC cash floor targeted by pool rebalancing, in 6-decimal quote units.
public(package) macro fun expiry_cash_floor(): u64 { 10_000_000_000 }

/// Rebalancing band and target buffer fraction, in FLOAT_SCALING.
public(package) macro fun expiry_rebalance_pct(): u64 { 100_000_000 }

// === Async LP Requests ===
// Request admission thresholds and cancellation reasons are upgrade-required protocol values.

/// Minimum DUSDC a single supply request must escrow: 10 DUSDC (6-decimal units).
public(package) macro fun min_supply_request(): u64 { 10_000_000 }

/// Minimum PLP a single withdraw request must escrow: 1 PLP (6-decimal units).
public(package) macro fun min_withdraw_request(): u64 { 1_000_000 }

/// Number of frozen-mark limit misses a queued LP request can survive before the
/// protocol cancels and refunds it.
public(package) macro fun lp_request_limit_flush_attempts(): u64 { 3 }

public(package) macro fun request_cancel_reason_user(): u8 { 0 }

public(package) macro fun request_cancel_reason_non_executable(): u8 { 1 }

public(package) macro fun request_cancel_reason_limit_expired(): u8 { 2 }

/// Permanent genesis liquidity locked at the one-time `plp::lock_capital` bootstrap:
/// 10 DUSDC (6-decimal units). The locked PLP keeps `total_supply > 0` for the
/// life of the pool, so async LP pricing never needs a supply==0 bootstrap branch.
public(package) macro fun min_bootstrap_liquidity(): u64 { 10_000_000 }

/// Executable frozen-mark band: the PLP price must be within this factor of unit
/// parity (1 DUSDC per whole PLP) in both directions — [0.01, 100] DUSDC. dUSDC
/// and PLP both use 6 decimals, so unit parity is raw-unit parity and the band
/// test needs no price unit.
public(package) macro fun executable_price_band_factor(): u64 { 100 }

/// Maximum active pre-expiry markets that can require live NAV valuation in one
/// full-pool flush.
public(package) macro fun max_live_expiry_markets(): u64 { 24 }

/// Maximum finite payout-tree boundary nodes one expiry market may carry into NAV.
public(package) macro fun max_payout_tree_nodes(): u64 { 1_000 }

/// Maximum active leveraged orders one expiry market may carry into NAV.
public(package) macro fun max_active_leveraged_orders(): u64 { 5_000 }

// === Time Constants ===

public(package) macro fun one_minute_ms(): u64 { 60_000 }

public(package) macro fun five_minutes_ms(): u64 { 5 * one_minute_ms!() }

public(package) macro fun one_hour_ms(): u64 { 60 * one_minute_ms!() }

public(package) macro fun one_day_ms(): u64 { 24 * one_hour_ms!() }

public(package) macro fun one_week_ms(): u64 { 7 * one_day_ms!() }

/// Milliseconds in one fixed 30-day month; this is not a calendar month.
public(package) macro fun one_month_ms(): u64 { 30 * one_day_ms!() }

/// Milliseconds in a fixed 365-day year.
public(package) macro fun one_year_ms(): u64 { 365 * one_day_ms!() }

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

// === Fee Incentives ===

/// Fraction of the post-staking trading fee paid by sponsor-funded incentives.
public(package) macro fun fee_incentive_subsidy_rate(): u64 { 200_000_000 }

/// Fraction of the expiry allocation cap an expiry can hold in live fee incentives.
public(package) macro fun fee_incentive_live_target_rate(): u64 { 20_000_000 }

/// Fraction of the expiry allocation cap an expiry can receive over its lifetime.
public(package) macro fun fee_incentive_lifetime_cap_rate(): u64 { 100_000_000 }

/// Minimum DUSDC a single fee-incentive sponsorship may contribute.
public(package) macro fun min_fee_incentive_sponsorship(): u64 { 10_000_000 }

// === Settlement ===

/// Exact settlement timestamp grid.
/// Cadence periods are multiples of this value so created expiries align with whole-millisecond Pyth history keys; a missing exact expiry observation prevents settlement and therefore pool valuation.
public(package) macro fun resolution_period_ms(): u64 { one_minute_ms!() }

// === Strike Tick Domain ===

/// Bit width of each strike tick field packed into an order ID.
public(package) macro fun tick_bits(): u8 { 30 }

/// Positive-infinity tick sentinel and exclusive upper bound of the finite tick domain.
/// Finite ticks occupy `1..pos_inf_tick - 1`; tick zero is the negative-infinity sentinel.
public(package) macro fun pos_inf_tick(): u64 { (1u64 << tick_bits!()) - 1 }

/// Granularity unit for market tick sizes; every tick_size must be a multiple of this value.
public macro fun market_tick_size_unit(): u64 { 10_000 }

/// Sentinel lower strike for ranges open to negative infinity.
public macro fun neg_inf(): u64 { 0 }

/// Sentinel upper strike for ranges open to positive infinity.
public macro fun pos_inf(): u64 { std::u64::max_value!() }
