// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Upgrade-required protocol constants for Predict.
///
/// Scaling conventions (aligned with DeepBook):
/// - Prices/percentages use FLOAT_SCALING (1e9): 500_000_000 = 50%
/// - Quantities are in 6-decimal quote units: 1_000_000 = 1 contract = one quote unit
/// - At settlement, a winning order redeems `quantity - floor_shares` (the full
///   `quantity` only when unleveraged, i.e. `floor_shares == 0`)
/// - Use `math` for all fixed-point scaling and mul/div operations
module deepbook_predict::constants;

// === Package Versioning ===

/// Current package version, bumped on each upgrade. Version-gated entry points run
/// only while `current_version!() >= ProtocolConfig.version_watermark`; admin raises
/// the watermark (`protocol_config::bump_version_watermark`) to retire older versions.
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
// Minimums and the per-flush cap are upgrade-required for now. A per-vault
// admin-tunable minimum is a deferred follow-up (see config rules in move.md).

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

/// Raw PLP units in one whole PLP.
public(package) macro fun plp_price_unit(): u64 { 1_000_000 }

/// Minimum executable frozen PLP mark: 0.01 DUSDC per whole PLP, in DUSDC raw units.
public(package) macro fun min_executable_plp_price(): u64 { 10_000 }

/// Maximum executable frozen PLP mark: 100 DUSDC per whole PLP, in DUSDC raw units.
public(package) macro fun max_executable_plp_price(): u64 { 100_000_000 }

/// Maximum active pre-expiry markets that can require live NAV valuation in one
/// full-pool flush.
public(package) macro fun max_live_expiry_markets(): u64 { 24 }

/// Maximum finite payout-tree boundary nodes one expiry market may carry into NAV.
/// Held below Sui's ~1,000 cached-object per-transaction wall (measured single-market
/// crossing ~982 nodes, `predeploy/evidence/c1-object-cache-flush-2026-07-07.md`) so
/// one market's refresh walk always fits its own transaction.
public(package) macro fun max_payout_tree_nodes(): u64 { 950 }

/// Maximum active leveraged orders one expiry market may carry into NAV.
public(package) macro fun max_active_leveraged_orders(): u64 { 5_000 }

// === Time Constants ===

/// Milliseconds in one minute.
public(package) macro fun one_minute_ms(): u64 { 60_000 }

/// Milliseconds in five minutes.
public(package) macro fun five_minutes_ms(): u64 { 5 * one_minute_ms!() }

/// Milliseconds in one hour.
public(package) macro fun one_hour_ms(): u64 { 60 * one_minute_ms!() }

/// Milliseconds in one day.
public(package) macro fun one_day_ms(): u64 { 24 * one_hour_ms!() }

/// Milliseconds in one week.
public(package) macro fun one_week_ms(): u64 { 7 * one_day_ms!() }

/// Milliseconds in one fixed 30-day month; this is not a calendar month.
public(package) macro fun one_month_ms(): u64 { 30 * one_day_ms!() }

/// Milliseconds in a 365-day year.
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

/// Resolution-feed grid period. Terminal settlement is an exact whole-millisecond
/// lookup keyed at `market.expiry`; `pyth_feed::insert_at` accepts only a print
/// whose signed publisher timestamp is exactly that millisecond. The off-chain
/// resolution relayer sources that key from Pyth Lazer's exact-timestamp
/// resolution endpoints and inserts it on this millisecond grid.
/// Cadence periods are multiples of this value, so cadence-created expiries stay
/// on a settling key the relayer can produce. An off-grid expiry could never settle
/// and would block the pool flush indefinitely
/// (`plp::value_expiry` aborts on a past-expiry market that has no settling
/// observation yet).
public(package) macro fun resolution_period_ms(): u64 { one_minute_ms!() }

// === Strike Tick Domain ===

/// Bit width of each strike tick field packed into an order ID.
public(package) macro fun tick_bits(): u8 { 30 }

/// Positive-infinity sentinel tick and maximum finite-tick bound. As the higher
/// tick it is the open upper bound; finite ticks
/// occupy `1..pos_inf_tick - 1`, and tick `0` is the negative-infinity sentinel
/// as the lower tick. Read by `order` (shape validation) and the range/tick codec.
public(package) macro fun pos_inf_tick(): u64 { (1u64 << tick_bits!()) - 1 }

/// Granularity unit for market tick sizes; every tick_size must be a multiple of this value.
public macro fun market_tick_size_unit(): u64 { 10_000 }

/// Sentinel lower strike for ranges open to negative infinity.
public macro fun neg_inf(): u64 { 0 }

/// Sentinel upper strike for ranges open to positive infinity.
public macro fun pos_inf(): u64 { std::u64::max_value!() }
