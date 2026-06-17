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
public(package) macro fun expiry_cash_floor(): u64 { 50_000_000_000 }

/// Maximum active expiries that can be registered to the pool at once.
public(package) macro fun max_active_expiry_markets(): u64 { 10 }

/// Rebalancing band and target buffer fraction, in FLOAT_SCALING.
public(package) macro fun expiry_rebalance_pct(): u64 { 100_000_000 }

/// Global cap on net DUSDC the pool may have funded into any one expiry.
/// Per-expiry tuning is deferred to B-rest; main carried this as a per-expiry
/// admin config, dissolved here into a single upgrade-required risk cap.
public(package) macro fun expiry_max_funding(): u64 { 250_000_000_000 }

// === Async LP Requests ===
// Minimums and the per-flush cap are upgrade-required for now. A per-vault
// admin-tunable minimum is a deferred follow-up (see config rules in move.md).

/// Minimum DUSDC a single supply request must escrow: 10 DUSDC (6-decimal units).
public(package) macro fun min_supply_request(): u64 { 10_000_000 }

/// Minimum PLP a single withdraw request must escrow: 1 PLP (6-decimal units).
public(package) macro fun min_withdraw_request(): u64 { 1_000_000 }

/// Permanent genesis liquidity locked at the one-time `plp::lock_capital` bootstrap:
/// 10 DUSDC (6-decimal units). MUST be >= `min_withdraw_request` so `total_supply`
/// can never re-enter the dust band post-genesis (pinned by a constant-relationship
/// test); the locked PLP keeps `total_supply > 0` for the life of the pool.
public(package) macro fun min_bootstrap_liquidity(): u64 { 10_000_000 }

/// Minimum executable PLP price: 0.01 DUSDC per PLP, in FLOAT_SCALING.
public(package) macro fun min_plp_price(): u64 { 10_000_000 }

/// Maximum executable PLP price: 100 DUSDC per PLP, in FLOAT_SCALING.
public(package) macro fun max_plp_price(): u64 { 100_000_000_000 }

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

// === Settlement ===

/// Resolution-feed grid period. Terminal settlement is an exact whole-millisecond
/// lookup keyed at `market.expiry`; `pyth_feed::insert_at` accepts only a print
/// whose signed publisher timestamp is exactly that millisecond. The off-chain
/// resolution relayer sources that key from Pyth Lazer's exact-timestamp
/// resolution endpoints and inserts it on this millisecond grid.
/// `registry::create_expiry_market` requires `expiry % resolution_period_ms!() == 0`
/// so the settling key is always producible; an off-grid expiry could never settle
/// and would block the pool flush indefinitely (`plp::value_expiry` aborts on a
/// past-expiry market that has no settling observation yet).
public(package) macro fun resolution_period_ms(): u64 { 60_000 }

// === Strike Tick Domain ===

/// Bit width of each strike tick field in the packed range key and order ID.
public(package) macro fun tick_bits(): u8 { 24 }

/// Positive-infinity sentinel tick, maximum finite-tick bound, and u24 mask for
/// unpacking a tick. As the higher tick it is the open upper bound; finite ticks
/// occupy `1..pos_inf_tick - 1`, and tick `0` is the negative-infinity sentinel
/// as the lower tick. Read by `order` (shape validation) and the range/tick codec.
public(package) macro fun pos_inf_tick(): u64 { (1u64 << tick_bits!()) - 1 }

/// Granularity unit for market tick sizes; every tick_size must be a multiple of this value.
public macro fun market_tick_size_unit(): u64 { 10_000 }

/// Sentinel lower strike for ranges open to negative infinity.
public macro fun neg_inf(): u64 { 0 }

/// Sentinel upper strike for ranges open to positive infinity.
public macro fun pos_inf(): u64 { std::u64::max_value!() }

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
