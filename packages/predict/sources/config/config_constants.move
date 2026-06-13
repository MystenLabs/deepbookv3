// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Constants and validation helpers for admin-tunable policy.
///
/// Default values seed stored policy state at creation. Bounds define the hard
/// envelope admin setters can tune within. Changing a bound requires a package upgrade.
module deepbook_predict::config_constants;

const EInvalidBaseFee: u64 = 0;
const EInvalidMinFee: u64 = 1;
const EInvalidMinAskPrice: u64 = 2;
const EInvalidMaxAskPrice: u64 = 3;
const EInvalidPythSpotFreshnessMs: u64 = 4;
const EInvalidBlockScholesPricesFreshnessMs: u64 = 5;
const EInvalidBlockScholesSVIFreshnessMs: u64 = 6;
const EInvalidSettlementFreshnessMs: u64 = 8;
const EInvalidTradingLossRebateRate: u64 = 14;
const EInvalidTerminalFloorIndex: u64 = 15;
const EInvalidExpiryFeeWindowMs: u64 = 16;
const EInvalidExpiryFeeMaxMultiplier: u64 = 17;
const EInvalidLowerBenefitPower: u64 = 18;
const EInvalidUpperBenefitPower: u64 = 19;
const EInvalidBenefitPowers: u64 = 20;
const EInvalidTradeLiquidationBudget: u64 = 22;
const EInvalidLiquidationLtv: u64 = 23;
const EInvalidOracleTickSize: u64 = 24;
const EInvalidEwmaAlpha: u64 = 26;
const EInvalidEwmaZScoreThreshold: u64 = 27;
const EInvalidEwmaPenaltyRate: u64 = 28;
const EInvalidBackingBufferLambda: u64 = 29;

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

// === Floor Index, Backing, and Liquidation ===

public(package) macro fun default_terminal_floor_index(): u64 { 1_200_000_000 }
public(package) macro fun min_terminal_floor_index(): u64 {
    predict_math::math::float_scaling!()
}
public(package) macro fun max_terminal_floor_index(): u64 {
    2 * predict_math::math::float_scaling!()
}

public(package) fun assert_terminal_floor_index(value: u64) {
    assert!(
        value >= min_terminal_floor_index!() && value <= max_terminal_floor_index!(),
        EInvalidTerminalFloorIndex,
    );
}

public(package) macro fun default_liquidation_ltv(): u64 { 850_000_000 }
public(package) macro fun min_liquidation_ltv(): u64 { 500_000_000 }
public(package) macro fun max_liquidation_ltv(): u64 { 950_000_000 }

public(package) fun assert_liquidation_ltv(value: u64) {
    assert!(
        value >= min_liquidation_ltv!() && value <= max_liquidation_ltv!(),
        EInvalidLiquidationLtv,
    );
}

public(package) macro fun default_backing_buffer_lambda(): u64 { 250_000_000 }
public(package) macro fun min_backing_buffer_lambda(): u64 { 50_000_000 }
public(package) macro fun max_backing_buffer_lambda(): u64 {
    predict_math::math::float_scaling!()
}

public(package) fun assert_backing_buffer_lambda(value: u64) {
    assert!(
        value >= min_backing_buffer_lambda!() && value <= max_backing_buffer_lambda!(),
        EInvalidBackingBufferLambda,
    );
}

// === Pricing ===

public(package) macro fun default_base_fee(): u64 { 20_000_000 }
public(package) macro fun min_base_fee(): u64 { 1 }
public(package) macro fun max_base_fee(): u64 { predict_math::math::float_scaling!() }

public(package) fun assert_base_fee(value: u64) {
    assert!(value >= min_base_fee!() && value <= max_base_fee!(), EInvalidBaseFee);
}

public(package) macro fun default_min_fee(): u64 { 5_000_000 }
public(package) macro fun min_min_fee(): u64 { 0 }
public(package) macro fun max_min_fee(): u64 { predict_math::math::float_scaling!() }

public(package) fun assert_min_fee(value: u64) {
    assert!(value >= min_min_fee!() && value <= max_min_fee!(), EInvalidMinFee);
}

/// Window before expiry over which trade fees ramp up to the per-feed max
/// multiplier. Five minutes is the shortest admin-tunable window.
public(package) macro fun default_expiry_fee_window_ms(): u64 { 60 * 60 * 24 * 1000 }
public(package) macro fun min_expiry_fee_window_ms(): u64 { 5 * 60 * 1000 }
public(package) macro fun max_expiry_fee_window_ms(): u64 {
    deepbook_predict::constants::ms_per_year!()
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
    predict_math::math::float_scaling!()
}
public(package) macro fun min_expiry_fee_max_multiplier(): u64 {
    predict_math::math::float_scaling!()
}
public(package) macro fun max_expiry_fee_max_multiplier(): u64 {
    10 * predict_math::math::float_scaling!()
}

public(package) fun assert_expiry_fee_max_multiplier(value: u64) {
    assert!(
        value >= min_expiry_fee_max_multiplier!() && value <= max_expiry_fee_max_multiplier!(),
        EInvalidExpiryFeeMaxMultiplier,
    );
}

public(package) fun assert_oracle_tick_size(value: u64) {
    assert!(
        value > 0 && value % deepbook_predict::constants::oracle_tick_size_unit!() == 0,
        EInvalidOracleTickSize,
    );
}

public(package) macro fun default_min_ask_price(): u64 { 10_000_000 }
public(package) macro fun min_min_ask_price(): u64 { 0 }
public(package) macro fun max_min_ask_price(): u64 {
    predict_math::math::float_scaling!() - 1
}

public(package) fun assert_min_ask_price(value: u64) {
    assert!(value >= min_min_ask_price!() && value <= max_min_ask_price!(), EInvalidMinAskPrice);
}

public(package) macro fun default_max_ask_price(): u64 { 990_000_000 }
public(package) macro fun min_max_ask_price(): u64 { 0 }
public(package) macro fun max_max_ask_price(): u64 {
    predict_math::math::float_scaling!() - 1
}

public(package) fun assert_max_ask_price(value: u64) {
    assert!(value >= min_max_ask_price!() && value <= max_max_ask_price!(), EInvalidMaxAskPrice);
}

public(package) macro fun default_pyth_spot_freshness_ms(): u64 { 2_000 }
public(package) macro fun min_pyth_spot_freshness_ms(): u64 { 1 }
public(package) macro fun max_pyth_spot_freshness_ms(): u64 { 60_000 }

public(package) fun assert_pyth_spot_freshness_ms(value: u64) {
    assert!(
        value >= min_pyth_spot_freshness_ms!() && value <= max_pyth_spot_freshness_ms!(),
        EInvalidPythSpotFreshnessMs,
    );
}

public(package) macro fun default_block_scholes_prices_freshness_ms(): u64 { 3_000 }
public(package) macro fun min_block_scholes_prices_freshness_ms(): u64 { 1 }
public(package) macro fun max_block_scholes_prices_freshness_ms(): u64 { 60_000 }

public(package) fun assert_block_scholes_prices_freshness_ms(value: u64) {
    assert!(
        value >= min_block_scholes_prices_freshness_ms!()
            && value <= max_block_scholes_prices_freshness_ms!(),
        EInvalidBlockScholesPricesFreshnessMs,
    );
}

public(package) macro fun default_block_scholes_svi_freshness_ms(): u64 { 60_000 }
public(package) macro fun min_block_scholes_svi_freshness_ms(): u64 { 1 }
public(package) macro fun max_block_scholes_svi_freshness_ms(): u64 { 60_000 }

public(package) fun assert_block_scholes_svi_freshness_ms(value: u64) {
    assert!(
        value >= min_block_scholes_svi_freshness_ms!()
            && value <= max_block_scholes_svi_freshness_ms!(),
        EInvalidBlockScholesSVIFreshnessMs,
    );
}

// === EWMA Penalty ===

/// Smoothing factor for the gas-price EWMA in FLOAT_SCALING. ~1% reacts slowly,
/// mirroring DeepBook core. Bounded below float_scaling so `1 - alpha` stays positive.
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
    predict_math::math::float_scaling!()
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
    predict_math::math::float_scaling!()
}

public(package) fun assert_trading_loss_rebate_rate(value: u64) {
    assert!(
        value >= min_trading_loss_rebate_rate!()
            && value <= max_trading_loss_rebate_rate!(),
        EInvalidTradingLossRebateRate,
    );
}

// === Staking ===

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

/// Validate both benefit thresholds together. The upper segment must require
/// strictly more stake than the lower one: `upper - lower > lower`, i.e.
/// `upper > 2 * lower` (which also guarantees `upper > lower`, so the curve's
/// `upper - lower` denominator is positive).
public(package) fun assert_benefit_powers(lower: u64, upper: u64) {
    assert_lower_benefit_power(lower);
    assert_upper_benefit_power(upper);
    assert!(upper > 2 * lower, EInvalidBenefitPowers);
}

// === Market Oracle ===

public(package) macro fun default_settlement_freshness_ms(): u64 { 3_000 }
public(package) macro fun min_settlement_freshness_ms(): u64 { 1 }
public(package) macro fun max_settlement_freshness_ms(): u64 { 60_000 }

public(package) fun assert_settlement_freshness_ms(value: u64) {
    assert!(
        value >= min_settlement_freshness_ms!() && value <= max_settlement_freshness_ms!(),
        EInvalidSettlementFreshnessMs,
    );
}
