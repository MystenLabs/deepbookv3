// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Constants and validation helpers for admin-tunable policy.
///
/// Default values seed stored policy state at creation. Bounds define the hard
/// envelope admin setters can tune within. Changing a bound requires a package upgrade.
module deepbook_predict::config_constants;

const EInvalidBaseFee: u64 = 0;
const EInvalidMinFee: u64 = 1;
const EInvalidMinEntryProbability: u64 = 2;
const EInvalidMaxEntryProbability: u64 = 3;
const EInvalidPythSpotFreshnessMs: u64 = 4;
const EInvalidBlockScholesPriceFreshnessMs: u64 = 5;
const EInvalidProtocolReserveProfitShare: u64 = 6;
const EInvalidTradingLossRebateRate: u64 = 7;
const EInvalidBlockScholesSVIFreshnessMs: u64 = 8;
const EInvalidExpiryFeeWindowMs: u64 = 9;
const EInvalidExpiryFeeMaxMultiplier: u64 = 10;
const EInvalidLowerBenefitPower: u64 = 11;
const EInvalidUpperBenefitPower: u64 = 12;
const EInvalidTradeLiquidationBudget: u64 = 13;
const EInvalidLiquidationLtv: u64 = 14;
const EInvalidMarketTickSize: u64 = 15;
const EInvalidEwmaAlpha: u64 = 16;
const EInvalidEwmaZScoreThreshold: u64 = 17;
const EInvalidEwmaPenaltyRate: u64 = 18;
const EInvalidBackingBufferLambda: u64 = 19;
const EInvalidMaxAdmissionLeverage: u64 = 20;
const EInvalidCadenceWindowSize: u64 = 21;
const EMarketTickSizeTooLarge: u64 = 22;
const EInvalidNoLeverageWindowMs: u64 = 23;
const EInvalidLpRequestLimitFlushAttempts: u64 = 24;
const EInvalidMaxLpPoolValue: u64 = 25;
const EInvalidPlpSupplyFeeRate: u64 = 26;
const EInvalidPlpWithdrawFeeRate: u64 = 27;
const EInvalidMaxBenefitRatio: u64 = 28;
const EInvalidInventorySkewGamma: u64 = 29;
const EInvalidInventorySkewCap: u64 = 30;

// === Fees ===

/// Merged protocol + insurance reserve share of materialized terminal profit, in
/// FLOAT_SCALING. The complement accrues to LPs.
public(package) macro fun default_protocol_reserve_profit_share(): u64 { 400_000_000 }

public(package) macro fun min_protocol_reserve_profit_share(): u64 { 0 }

public(package) macro fun max_protocol_reserve_profit_share(): u64 {
    fixed_math::math::float_scaling!()
}

public(package) fun assert_protocol_reserve_profit_share(value: u64) {
    assert!(
        value >= min_protocol_reserve_profit_share!()
            && value <= max_protocol_reserve_profit_share!(),
        EInvalidProtocolReserveProfitShare,
    );
}

/// Fee charged on an executed PLP *supply* fill, in FLOAT_SCALING. Ships at zero:
/// an exit concentrates the pool's outstanding risk on whoever stays, while a
/// deposit dilutes it, so the charge that prices that externality belongs on the
/// exit alone and adding equity is not taxed. The knob exists so the decision stays
/// reversible without a package upgrade, not because a supply charge is intended.
public(package) macro fun default_plp_supply_fee_rate(): u64 { 0 }

/// Fee charged on an executed PLP *withdraw* fill, in FLOAT_SCALING — 20 bps by
/// default. Retained by the pool, so it accrues to the holders who stay rather than
/// to the protocol reserve.
public(package) macro fun default_plp_withdraw_fee_rate(): u64 { 2_000_000 }

/// Shared envelope for both legs. The 5% ceiling bounds how punitive an `AdminCap`
/// alone can make LP entry or exit, and keeping it far below `float_scaling` is what
/// makes `amount - fee` structurally non-underflowing on the mandatory flush path
/// (pinned by `plp_supply_fee_rate_at_full_scale_is_rejected` and
/// `plp_withdraw_fee_rate_at_full_scale_is_rejected`).
public(package) macro fun min_plp_fee_rate(): u64 { 0 }

public(package) macro fun max_plp_fee_rate(): u64 { 50_000_000 }

public(package) fun assert_plp_supply_fee_rate(value: u64) {
    assert!(value >= min_plp_fee_rate!() && value <= max_plp_fee_rate!(), EInvalidPlpSupplyFeeRate);
}

public(package) fun assert_plp_withdraw_fee_rate(value: u64) {
    assert!(
        value >= min_plp_fee_rate!() && value <= max_plp_fee_rate!(),
        EInvalidPlpWithdrawFeeRate,
    );
}

// === Trade Liquidation ===

public(package) macro fun default_trade_liquidation_budget(): u64 { 24 }

public(package) macro fun min_trade_liquidation_budget(): u64 { 24 }

public(package) macro fun max_trade_liquidation_budget(): u64 {
    3_000
}

public(package) fun assert_trade_liquidation_budget(value: u64) {
    assert!(
        value >= min_trade_liquidation_budget!() && value <= max_trade_liquidation_budget!(),
        EInvalidTradeLiquidationBudget,
    );
}

// === LP Request Queue ===

/// Frozen-mark attempts a queued LP request gets before the protocol cancels and
/// refunds it. The default of 1 is fill-or-kill: the flush that reaches a request
/// either fills it or refunds it, so no request can hold the queue head.
///
/// Every attempt beyond the first leaves a request queued at the head and stops
/// that queue for the flush, which is a shared-liveness cost, not a per-user one:
/// N requests carrying a limit no mark can satisfy block every later LP for
/// `2N+1` flushes (`predeploy/evidence/rp12-lp-queue-head-of-line-2026-07-29.md`).
/// The maximum is therefore deliberately tight — raising it trades LP-queue
/// liveness for a resting-limit affordance, and is an operator decision that
/// should follow measured miss rates. See RP-12.
public(package) macro fun default_lp_request_limit_flush_attempts(): u64 { 1 }

public(package) macro fun min_lp_request_limit_flush_attempts(): u64 { 1 }

public(package) macro fun max_lp_request_limit_flush_attempts(): u64 { 3 }

public(package) fun assert_lp_request_limit_flush_attempts(value: u64) {
    assert!(
        value >= min_lp_request_limit_flush_attempts!()
            && value <= max_lp_request_limit_flush_attempts!(),
        EInvalidLpRequestLimitFlushAttempts,
    );
}

/// Ceiling on LP-attributable pool value (`idle + Σ active NAV`, net of the
/// protocol-profit exclusion) that queued supplies may raise the pool to. Checked at
/// the flush against the frozen mark, because that is the only point where pool value
/// is exact; a supply that would carry the pool past it is filled up to the cap and
/// its remainder held at the queue head rather than refunded. The default admits everything, so the cap binds only once an operator sets
/// a real figure.
///
/// This caps pool *value*, not cumulative deposits — trading profit raises NAV, so a
/// pool can sit above a set cap with no new deposits, in which case supplies wait
/// until NAV falls back. See RP-23.
///
/// The floor is the genesis lock plus one minimum supply, which is the smallest cap
/// under which a minimally-bootstrapped pool can still admit a deposit. It is a
/// sanity bound, not a liveness guarantee: a pool bootstrapped above the minimum, or
/// one whose NAV has since grown, can be closed to new capital by any cap at or below
/// its current value — which is a legitimate operator action, not a misconfiguration.
public(package) macro fun default_max_lp_pool_value(): u64 { std::u64::max_value!() }

public(package) macro fun min_max_lp_pool_value(): u64 {
    deepbook_predict::constants::min_bootstrap_liquidity!() +
    deepbook_predict::constants::min_supply_request!()
}

public(package) macro fun max_max_lp_pool_value(): u64 { std::u64::max_value!() }

public(package) fun assert_max_lp_pool_value(value: u64) {
    assert!(
        value >= min_max_lp_pool_value!() && value <= max_max_lp_pool_value!(),
        EInvalidMaxLpPoolValue,
    );
}

// === Backing and Liquidation ===

public(package) macro fun default_liquidation_ltv(): u64 { 850_000_000 }

public(package) macro fun min_liquidation_ltv(): u64 { 500_000_000 }

public(package) macro fun max_liquidation_ltv(): u64 { 950_000_000 }

public(package) fun assert_liquidation_ltv(value: u64) {
    assert!(
        value >= min_liquidation_ltv!() && value <= max_liquidation_ltv!(),
        EInvalidLiquidationLtv,
    );
}

/// Global admission-leverage cap snapshotted by newly created expiry markets. Mint
/// admission scales this cap down for low-probability contracts.
public(package) macro fun default_max_admission_leverage(): u64 {
    3 * fixed_math::math::float_scaling!()
}

public(package) macro fun min_max_admission_leverage(): u64 {
    fixed_math::math::float_scaling!()
}

public(package) macro fun max_max_admission_leverage(): u64 {
    10 * fixed_math::math::float_scaling!()
}

public(package) fun assert_max_admission_leverage(value: u64) {
    assert!(
        value >= min_max_admission_leverage!()
            && value <= max_max_admission_leverage!(),
        EInvalidMaxAdmissionLeverage,
    );
}

/// Shape parameter for the admission curve:
/// `p * (1 + k) / (p + k)`. `0.2` makes low probabilities meaningfully stricter
/// while still approaching the configured cap smoothly as probability rises.
public(package) macro fun admission_leverage_curve_k(): u64 { 200_000_000 }

/// Window before expiry within which mint admission originates no leverage at all:
/// the cap is exactly 1x. Near expiry a contract's probability can move far in a
/// single tick, leaping a leveraged order past its knockout before liquidation can
/// fire and leaving the gap with the LP. `0` disables the block; one hour by default.
public(package) macro fun default_no_leverage_window_ms(): u64 {
    deepbook_predict::constants::one_hour_ms!()
}

public(package) macro fun min_no_leverage_window_ms(): u64 { 0 }

public(package) macro fun max_no_leverage_window_ms(): u64 {
    deepbook_predict::constants::one_year_ms!()
}

public(package) fun assert_no_leverage_window_ms(value: u64) {
    assert!(
        value >= min_no_leverage_window_ms!() && value <= max_no_leverage_window_ms!(),
        EInvalidNoLeverageWindowMs,
    );
}

public(package) macro fun default_backing_buffer_lambda(): u64 { 250_000_000 }

public(package) macro fun min_backing_buffer_lambda(): u64 { 50_000_000 }

public(package) macro fun max_backing_buffer_lambda(): u64 {
    fixed_math::math::float_scaling!()
}

public(package) fun assert_backing_buffer_lambda(value: u64) {
    assert!(
        value >= min_backing_buffer_lambda!() && value <= max_backing_buffer_lambda!(),
        EInvalidBackingBufferLambda,
    );
}

// === Inventory Skew ===

/// Intensity of the inventory-skew charge, in FLOAT_SCALING. The per-unit rate is
/// `gamma * (delta / net_payout) * p * (1 - p)`, so `gamma` is the per-unit rate at
/// maximum crowding and maximum uncertainty (`p = 1/2`), times four — the formula
/// peaks at `gamma / 4`. Pool-wide load is not in this product (priced by the
/// utilization fee multiplier instead). Ships at `0`: the sole kill switch, and
/// the rate short-circuits before any tree read when disarmed.
public(package) macro fun default_inventory_skew_gamma(): u64 { 0 }

public(package) macro fun min_inventory_skew_gamma(): u64 { 0 }

/// Admin ceiling on gamma. Peaks the uncapped rate at 25% of notional
/// (`gamma/4` at coin-flip + full crowding); tighter per-market bounds use
/// `inventory_skew_cap`.
public(package) macro fun max_inventory_skew_gamma(): u64 {
    fixed_math::math::float_scaling!()
}

public(package) fun assert_inventory_skew_gamma(value: u64) {
    assert!(
        value >= min_inventory_skew_gamma!() && value <= max_inventory_skew_gamma!(),
        EInvalidInventorySkewGamma,
    );
}

/// Hard ceiling on the per-unit inventory-skew rate, in FLOAT_SCALING. A rate of
/// `float_scaling` would charge the order's whole max payout, so the default is
/// non-binding: the formula itself peaks at `gamma / 4`. Lower it to bound how
/// punitive the charge can get on the most crowded ranges.
public(package) macro fun default_inventory_skew_cap(): u64 {
    fixed_math::math::float_scaling!()
}

public(package) macro fun min_inventory_skew_cap(): u64 { 0 }

public(package) macro fun max_inventory_skew_cap(): u64 {
    fixed_math::math::float_scaling!()
}

public(package) fun assert_inventory_skew_cap(value: u64) {
    assert!(
        value >= min_inventory_skew_cap!() && value <= max_inventory_skew_cap!(),
        EInvalidInventorySkewCap,
    );
}

/// Whether a live close pays the inventory-skew rebate back out of the escrowed
/// reserve. Ships off, so the charge is one-way until an operator turns the
/// give-back on. No bounds helper: a bool has no invalid value.
public(package) macro fun default_inventory_skew_rebate_enabled(): bool { false }

// === Pricing ===

public(package) macro fun default_base_fee(): u64 { 20_000_000 }

public(package) macro fun min_base_fee(): u64 { 1 }

public(package) macro fun max_base_fee(): u64 { fixed_math::math::float_scaling!() }

public(package) fun assert_base_fee(value: u64) {
    assert!(value >= min_base_fee!() && value <= max_base_fee!(), EInvalidBaseFee);
}

public(package) macro fun default_min_fee(): u64 { 5_000_000 }

public(package) macro fun min_min_fee(): u64 { 0 }

public(package) macro fun max_min_fee(): u64 { fixed_math::math::float_scaling!() }

public(package) fun assert_min_fee(value: u64) {
    assert!(value >= min_min_fee!() && value <= max_min_fee!(), EInvalidMinFee);
}

/// Window before expiry over which trade fees ramp up to the per-expiry max
/// multiplier. Five minutes is the shortest admin-tunable window.
public(package) macro fun default_expiry_fee_window_ms(): u64 {
    deepbook_predict::constants::one_day_ms!()
}

public(package) macro fun min_expiry_fee_window_ms(): u64 {
    deepbook_predict::constants::five_minutes_ms!()
}

public(package) macro fun max_expiry_fee_window_ms(): u64 {
    deepbook_predict::constants::one_year_ms!()
}

public(package) fun assert_expiry_fee_window_ms(value: u64) {
    assert!(
        value >= min_expiry_fee_window_ms!() && value <= max_expiry_fee_window_ms!(),
        EInvalidExpiryFeeWindowMs,
    );
}

/// Fee multiplier reached at expiry, in FLOAT_SCALING. 1x (float_scaling) disables
/// the ramp; min is 1x so the ramp can never reduce fees below the base rate.
public(package) macro fun default_expiry_fee_max_multiplier(): u64 {
    fixed_math::math::float_scaling!()
}

public(package) macro fun min_expiry_fee_max_multiplier(): u64 {
    fixed_math::math::float_scaling!()
}

public(package) macro fun max_expiry_fee_max_multiplier(): u64 {
    10 * fixed_math::math::float_scaling!()
}

public(package) fun assert_expiry_fee_max_multiplier(value: u64) {
    assert!(
        value >= min_expiry_fee_max_multiplier!() && value <= max_expiry_fee_max_multiplier!(),
        EInvalidExpiryFeeMaxMultiplier,
    );
}

public(package) fun assert_market_tick_size_bounds(value: u64) {
    assert!(
        value > 0 && value % deepbook_predict::constants::market_tick_size_unit!() == 0,
        EInvalidMarketTickSize,
    );
    // Prevent raw-strike multiplication overflow: the maximum finite strike is
    // `pos_inf_tick * tick_size`, which must fit in `u64`. Pure market bound;
    // normal market tick sizes are far below it.
    assert!(
        value <= std::u64::max_value!() / deepbook_predict::constants::pos_inf_tick!(),
        EMarketTickSizeTooLarge,
    );
}

public(package) macro fun max_cadence_window_size(): u64 { 10 }

public(package) fun assert_cadence_window_size(value: u64) {
    assert!(value <= max_cadence_window_size!(), EInvalidCadenceWindowSize);
}

public(package) macro fun default_min_entry_probability(): u64 { 10_000_000 }

// The 1% hard floor keeps the budget-to-quantity inverse's rounding undershoot below one position lot throughout the supported leverage envelope.
public(package) macro fun min_min_entry_probability(): u64 { 10_000_000 }

public(package) macro fun max_min_entry_probability(): u64 {
    fixed_math::math::float_scaling!() - 1
}

public(package) fun assert_min_entry_probability(value: u64) {
    assert!(
        value >= min_min_entry_probability!()
            && value <= max_min_entry_probability!(),
        EInvalidMinEntryProbability,
    );
}

public(package) macro fun default_max_entry_probability(): u64 { 990_000_000 }

public(package) macro fun min_max_entry_probability(): u64 { 0 }

public(package) macro fun max_max_entry_probability(): u64 {
    fixed_math::math::float_scaling!() - 1
}

public(package) fun assert_max_entry_probability(value: u64) {
    assert!(
        value >= min_max_entry_probability!()
            && value <= max_max_entry_probability!(),
        EInvalidMaxEntryProbability,
    );
}

/// Live pricing anchors the Block Scholes forward on the Pyth spot by default;
/// `false` prices off the Block Scholes forward directly. No bounds helper: a
/// bool has no invalid value.
public(package) macro fun default_use_pyth_spot_for_forward(): bool { true }

public(package) macro fun default_pyth_spot_freshness_ms(): u64 { 10_000 }

public(package) macro fun min_pyth_spot_freshness_ms(): u64 { 1 }

public(package) macro fun max_pyth_spot_freshness_ms(): u64 {
    deepbook_predict::constants::one_minute_ms!()
}

public(package) fun assert_pyth_spot_freshness_ms(value: u64) {
    assert!(
        value >= min_pyth_spot_freshness_ms!() && value <= max_pyth_spot_freshness_ms!(),
        EInvalidPythSpotFreshnessMs,
    );
}

public(package) macro fun default_block_scholes_price_freshness_ms(): u64 { 10_000 }

public(package) macro fun min_block_scholes_price_freshness_ms(): u64 { 1 }

public(package) macro fun max_block_scholes_price_freshness_ms(): u64 {
    deepbook_predict::constants::one_minute_ms!()
}

public(package) fun assert_block_scholes_price_freshness_ms(value: u64) {
    assert!(
        value >= min_block_scholes_price_freshness_ms!()
            && value <= max_block_scholes_price_freshness_ms!(),
        EInvalidBlockScholesPriceFreshnessMs,
    );
}

public(package) macro fun default_block_scholes_svi_freshness_ms(): u64 { 60_000 }

public(package) macro fun min_block_scholes_svi_freshness_ms(): u64 { 1 }

public(package) macro fun max_block_scholes_svi_freshness_ms(): u64 {
    2 * deepbook_predict::constants::one_minute_ms!()
}

public(package) fun assert_block_scholes_svi_freshness_ms(value: u64) {
    assert!(
        value >= min_block_scholes_svi_freshness_ms!()
            && value <= max_block_scholes_svi_freshness_ms!(),
        EInvalidBlockScholesSVIFreshnessMs,
    );
}

// === EWMA Penalty ===

/// Smoothing factor for the gas-price EWMA in FLOAT_SCALING. The default 1% reacts slowly; the upper bound keeps `1 - alpha` positive.
public(package) macro fun default_ewma_alpha(): u64 { 10_000_000 }

public(package) macro fun min_ewma_alpha(): u64 { 1 }

public(package) macro fun max_ewma_alpha(): u64 { 100_000_000 }

public(package) fun assert_ewma_alpha(value: u64) {
    assert!(value >= min_ewma_alpha!() && value <= max_ewma_alpha!(), EInvalidEwmaAlpha);
}

/// Standard deviations above the smoothed mean required before the penalty fires,
/// in FLOAT_SCALING (3 sigma by default). The min is one sigma so the penalty
/// cannot be tuned to surcharge near-average gas; the max keeps a single admin
/// call from raising the bar so high the penalty can never trigger.
public(package) macro fun default_ewma_z_score_threshold(): u64 { 3_000_000_000 }

public(package) macro fun min_ewma_z_score_threshold(): u64 {
    fixed_math::math::float_scaling!()
}

public(package) macro fun max_ewma_z_score_threshold(): u64 { 10_000_000_000 }

public(package) fun assert_ewma_z_score_threshold(value: u64) {
    assert!(
        value >= min_ewma_z_score_threshold!() && value <= max_ewma_z_score_threshold!(),
        EInvalidEwmaZScoreThreshold,
    );
}

/// Per-unit fee added to a penalized trade, in FLOAT_SCALING (10 bps by default,
/// capped at 20 bps to bound how punitive the surcharge can be made).
public(package) macro fun default_ewma_penalty_rate(): u64 { 1_000_000 }

public(package) macro fun min_ewma_penalty_rate(): u64 { 0 }

public(package) macro fun max_ewma_penalty_rate(): u64 { 2_000_000 }

public(package) fun assert_ewma_penalty_rate(value: u64) {
    assert!(
        value >= min_ewma_penalty_rate!() && value <= max_ewma_penalty_rate!(),
        EInvalidEwmaPenaltyRate,
    );
}

// === Fees ===

public(package) macro fun default_trading_loss_rebate_rate(): u64 {
    500_000_000
}

public(package) macro fun min_trading_loss_rebate_rate(): u64 { 0 }

public(package) macro fun max_trading_loss_rebate_rate(): u64 {
    fixed_math::math::float_scaling!()
}

public(package) fun assert_trading_loss_rebate_rate(value: u64) {
    assert!(
        value >= min_trading_loss_rebate_rate!()
            && value <= max_trading_loss_rebate_rate!(),
        EInvalidTradingLossRebateRate,
    );
}

// === Staking ===

/// Ceiling on the DEEP-stake benefit ratio, in FLOAT_SCALING. The stake curve is
/// scaled by this, so it sets how much of the programme runs: `0` pays nothing at
/// any stake, `float_scaling` runs it at full strength, and values between phase
/// it in. Ships at **0**, so a market created from the shipped template charges
/// every trader the undiscounted fee and pays no stake-scaled loss rebate.
public(package) macro fun default_max_benefit_ratio(): u64 { 0 }

public(package) macro fun min_max_benefit_ratio(): u64 { 0 }

public(package) macro fun max_max_benefit_ratio(): u64 {
    fixed_math::math::float_scaling!()
}

public(package) fun assert_max_benefit_ratio(value: u64) {
    assert!(
        value >= min_max_benefit_ratio!() && value <= max_max_benefit_ratio!(),
        EInvalidMaxBenefitRatio,
    );
}

/// Active stake at the benefit-curve kink: half of max benefits. Default 100k
/// DEEP, admin-tunable 10k..1M.
public(package) macro fun default_lower_benefit_power(): u64 {
    100_000 * deepbook_predict::constants::deep_decimals!()
}

public(package) macro fun min_lower_benefit_power(): u64 {
    10_000 * deepbook_predict::constants::deep_decimals!()
}

public(package) macro fun max_lower_benefit_power(): u64 {
    1_000_000 * deepbook_predict::constants::deep_decimals!()
}

/// Active stake for full (max) benefits. Default 1.1M DEEP, admin-tunable
/// 100k..50M.
public(package) macro fun default_upper_benefit_power(): u64 {
    1_100_000 * deepbook_predict::constants::deep_decimals!()
}

public(package) macro fun min_upper_benefit_power(): u64 {
    100_000 * deepbook_predict::constants::deep_decimals!()
}

public(package) macro fun max_upper_benefit_power(): u64 {
    50_000_000 * deepbook_predict::constants::deep_decimals!()
}

public(package) fun assert_lower_benefit_power(value: u64) {
    assert!(
        value >= min_lower_benefit_power!() && value <= max_lower_benefit_power!(),
        EInvalidLowerBenefitPower,
    );
}

public(package) fun assert_upper_benefit_power(value: u64) {
    assert!(
        value >= min_upper_benefit_power!() && value <= max_upper_benefit_power!(),
        EInvalidUpperBenefitPower,
    );
}
