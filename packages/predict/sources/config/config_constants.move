// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Constants and validation helpers for admin-tunable config.
///
/// Default values seed stored config objects at creation. Bounds define the hard
/// envelope admin setters can tune within. Changing a bound requires a package
/// upgrade.
module deepbook_predict::config_constants;

const EInvalidMaxTotalExposurePct: u64 = 0;
const EInvalidBaseFee: u64 = 1;
const EInvalidMinFee: u64 = 2;
const EInvalidMinAskPrice: u64 = 4;
const EInvalidMaxAskPrice: u64 = 5;
const EInvalidPythSpotFreshnessMs: u64 = 6;
const EInvalidBlockScholesPricesFreshnessMs: u64 = 7;
const EInvalidBlockScholesSVIFreshnessMs: u64 = 8;
const EInvalidLpFeeShare: u64 = 9;
const EInvalidProtocolFeeShare: u64 = 10;
const EInvalidInsuranceFeeShare: u64 = 11;
const EInvalidSettlementFreshnessMs: u64 = 12;
const EInvalidMaxSpotDeviation: u64 = 13;
const EInvalidMaxBasisDeviation: u64 = 14;
const EInvalidMinBasis: u64 = 15;
const EInvalidMaxBasis: u64 = 16;
const EInvalidExpiryAllocation: u64 = 17;
const EInvalidGrowUtilizationThreshold: u64 = 18;
const EInvalidShrinkUtilizationThreshold: u64 = 19;
const EInvalidGrowFactor: u64 = 20;
const EInvalidShrinkFactor: u64 = 21;
const EInvalidTradingLossRebateRate: u64 = 22;
const EInvalidMaxExpiryFloorPremium: u64 = 23;
const EInvalidExpiryFeeWindowMs: u64 = 24;
const EInvalidExpiryFeeMaxMultiplier: u64 = 25;
const EInvalidMaxBenefitPower: u64 = 26;
const EInvalidMaxFeeDiscount: u64 = 27;
const EInvalidMaxRebateFraction: u64 = 28;

// === Pool Risk ===

public(package) macro fun default_max_total_exposure_pct(): u64 { 800_000_000 }
public(package) macro fun min_max_total_exposure_pct(): u64 { 1 }
public(package) macro fun max_max_total_exposure_pct(): u64 {
    deepbook_predict::constants::float_scaling!()
}

public(package) fun assert_max_total_exposure_pct(value: u64) {
    assert!(
        value >= min_max_total_exposure_pct!() && value <= max_max_total_exposure_pct!(),
        EInvalidMaxTotalExposurePct,
    );
}

public(package) macro fun default_allocation(): u64 { 50_000_000_000 }
public(package) macro fun min_allocation(): u64 { 50_000_000_000 }
public(package) macro fun max_allocation(): u64 { 250_000_000_000 }

public(package) fun assert_expiry_allocation(value: u64) {
    assert!(value >= min_allocation!() && value <= max_allocation!(), EInvalidExpiryAllocation);
}

public(package) macro fun default_grow_utilization_threshold(): u64 { 800_000_000 }
public(package) macro fun min_grow_utilization_threshold(): u64 { 0 }
public(package) macro fun max_grow_utilization_threshold(): u64 {
    deepbook_predict::constants::float_scaling!()
}

public(package) fun assert_grow_utilization_threshold(value: u64) {
    assert!(
        value >= min_grow_utilization_threshold!() && value <= max_grow_utilization_threshold!(),
        EInvalidGrowUtilizationThreshold,
    );
}

public(package) macro fun default_shrink_utilization_threshold(): u64 { 300_000_000 }
public(package) macro fun min_shrink_utilization_threshold(): u64 { 0 }
public(package) macro fun max_shrink_utilization_threshold(): u64 {
    deepbook_predict::constants::float_scaling!()
}

public(package) fun assert_shrink_utilization_threshold(value: u64) {
    assert!(
        value >= min_shrink_utilization_threshold!()
            && value <= max_shrink_utilization_threshold!(),
        EInvalidShrinkUtilizationThreshold,
    );
}

public(package) macro fun default_grow_factor(): u64 { 2_000_000_000 }
public(package) macro fun min_grow_factor(): u64 {
    deepbook_predict::constants::float_scaling!() + 1
}
public(package) macro fun max_grow_factor(): u64 { 10_000_000_000 }

public(package) fun assert_grow_factor(value: u64) {
    assert!(value >= min_grow_factor!() && value <= max_grow_factor!(), EInvalidGrowFactor);
}

public(package) macro fun default_shrink_factor(): u64 { 500_000_000 }
public(package) macro fun min_shrink_factor(): u64 { 0 }
public(package) macro fun max_shrink_factor(): u64 {
    deepbook_predict::constants::float_scaling!() - 1
}

public(package) fun assert_shrink_factor(value: u64) {
    assert!(value >= min_shrink_factor!() && value <= max_shrink_factor!(), EInvalidShrinkFactor);
}

// === Leverage ===

public(package) macro fun default_max_expiry_floor_premium(): u64 { 200_000_000 }
public(package) macro fun min_max_expiry_floor_premium(): u64 { 0 }
public(package) macro fun max_max_expiry_floor_premium(): u64 {
    deepbook_predict::constants::float_scaling!()
}

public(package) fun assert_max_expiry_floor_premium(value: u64) {
    assert!(
        value >= min_max_expiry_floor_premium!() && value <= max_max_expiry_floor_premium!(),
        EInvalidMaxExpiryFloorPremium,
    );
}

// === Pricing ===

public(package) macro fun default_base_fee(): u64 { 20_000_000 }
public(package) macro fun min_base_fee(): u64 { 1 }
public(package) macro fun max_base_fee(): u64 { deepbook_predict::constants::float_scaling!() }

public(package) fun assert_base_fee(value: u64) {
    assert!(value >= min_base_fee!() && value <= max_base_fee!(), EInvalidBaseFee);
}

public(package) macro fun default_min_fee(): u64 { 5_000_000 }
public(package) macro fun min_min_fee(): u64 { 0 }
public(package) macro fun max_min_fee(): u64 { deepbook_predict::constants::float_scaling!() }

public(package) fun assert_min_fee(value: u64) {
    assert!(value >= min_min_fee!() && value <= max_min_fee!(), EInvalidMinFee);
}

/// Final window (ms before expiry) over which the fee ramps up. 0 disables it.
public(package) macro fun min_expiry_fee_window_ms(): u64 { 0 }
/// 30 days; predict markets are short-dated, so this is a generous envelope.
public(package) macro fun max_expiry_fee_window_ms(): u64 { 2_592_000_000 }

public(package) fun assert_expiry_fee_window_ms(value: u64) {
    assert!(
        value >= min_expiry_fee_window_ms!() && value <= max_expiry_fee_window_ms!(),
        EInvalidExpiryFeeWindowMs,
    );
}

/// Fee multiplier reached at expiry, in FLOAT_SCALING. 1x (float_scaling) disables
/// the ramp; min is 1x so the ramp can never reduce fees below the base rate.
public(package) macro fun min_expiry_fee_max_multiplier(): u64 {
    deepbook_predict::constants::float_scaling!()
}
public(package) macro fun max_expiry_fee_max_multiplier(): u64 {
    10 * deepbook_predict::constants::float_scaling!()
}

public(package) fun assert_expiry_fee_max_multiplier(value: u64) {
    assert!(
        value >= min_expiry_fee_max_multiplier!() && value <= max_expiry_fee_max_multiplier!(),
        EInvalidExpiryFeeMaxMultiplier,
    );
}

public(package) macro fun default_min_ask_price(): u64 { 10_000_000 }
public(package) macro fun min_min_ask_price(): u64 { 0 }
public(package) macro fun max_min_ask_price(): u64 {
    deepbook_predict::constants::float_scaling!() - 1
}

public(package) fun assert_min_ask_price(value: u64) {
    assert!(value >= min_min_ask_price!() && value <= max_min_ask_price!(), EInvalidMinAskPrice);
}

public(package) macro fun default_max_ask_price(): u64 { 990_000_000 }
public(package) macro fun min_max_ask_price(): u64 { 0 }
public(package) macro fun max_max_ask_price(): u64 {
    deepbook_predict::constants::float_scaling!() - 1
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

// === Fees ===

public(package) macro fun default_lp_fee_share(): u64 { 600_000_000 }
public(package) macro fun min_lp_fee_share(): u64 { 0 }
public(package) macro fun max_lp_fee_share(): u64 { deepbook_predict::constants::float_scaling!() }

public(package) fun assert_lp_fee_share(value: u64) {
    assert!(value >= min_lp_fee_share!() && value <= max_lp_fee_share!(), EInvalidLpFeeShare);
}

public(package) macro fun default_protocol_fee_share(): u64 { 200_000_000 }
public(package) macro fun min_protocol_fee_share(): u64 { 0 }
public(package) macro fun max_protocol_fee_share(): u64 {
    deepbook_predict::constants::float_scaling!()
}

public(package) fun assert_protocol_fee_share(value: u64) {
    assert!(
        value >= min_protocol_fee_share!() && value <= max_protocol_fee_share!(),
        EInvalidProtocolFeeShare,
    );
}

public(package) macro fun default_insurance_fee_share(): u64 { 200_000_000 }
public(package) macro fun min_insurance_fee_share(): u64 { 0 }
public(package) macro fun max_insurance_fee_share(): u64 {
    deepbook_predict::constants::float_scaling!()
}

public(package) fun assert_insurance_fee_share(value: u64) {
    assert!(
        value >= min_insurance_fee_share!() && value <= max_insurance_fee_share!(),
        EInvalidInsuranceFeeShare,
    );
}

public(package) macro fun default_trading_loss_rebate_rate(): u64 {
    500_000_000
}
public(package) macro fun min_trading_loss_rebate_rate(): u64 { 0 }
public(package) macro fun max_trading_loss_rebate_rate(): u64 {
    deepbook_predict::constants::float_scaling!()
}

public(package) fun assert_trading_loss_rebate_rate(value: u64) {
    assert!(
        value >= min_trading_loss_rebate_rate!()
            && value <= max_trading_loss_rebate_rate!(),
        EInvalidTradingLossRebateRate,
    );
}

// === Staking ===

/// Staking power at which trading benefits reach their maximum (50% fee
/// discount, 100% loss rebate): 100k DEEP, in raw units.
public(package) macro fun default_max_benefit_power(): u64 {
    100_000 * deepbook_predict::constants::deep_decimals!()
}
/// Floor of 1k DEEP and ceiling of 10M DEEP keep the benefit threshold from
/// being set to a trivially-disabling value in either direction.
public(package) macro fun min_max_benefit_power(): u64 {
    1_000 * deepbook_predict::constants::deep_decimals!()
}
public(package) macro fun max_max_benefit_power(): u64 {
    10_000_000 * deepbook_predict::constants::deep_decimals!()
}

public(package) fun assert_max_benefit_power(value: u64) {
    assert!(
        value >= min_max_benefit_power!() && value <= max_max_benefit_power!(),
        EInvalidMaxBenefitPower,
    );
}

/// Fee discount at full active stake, in FLOAT_SCALING. Admin-tunable 0..50%.
public(package) macro fun default_max_fee_discount(): u64 { 500_000_000 }
public(package) macro fun min_max_fee_discount(): u64 { 0 }
public(package) macro fun max_max_fee_discount(): u64 { 500_000_000 }

public(package) fun assert_max_fee_discount(value: u64) {
    assert!(
        value >= min_max_fee_discount!() && value <= max_max_fee_discount!(),
        EInvalidMaxFeeDiscount,
    );
}

/// Loss-rebate share at full active stake, in FLOAT_SCALING. Admin-tunable 0..100%.
public(package) macro fun default_max_rebate_fraction(): u64 {
    deepbook_predict::constants::float_scaling!()
}
public(package) macro fun min_max_rebate_fraction(): u64 { 0 }
public(package) macro fun max_max_rebate_fraction(): u64 {
    deepbook_predict::constants::float_scaling!()
}

public(package) fun assert_max_rebate_fraction(value: u64) {
    assert!(
        value >= min_max_rebate_fraction!() && value <= max_max_rebate_fraction!(),
        EInvalidMaxRebateFraction,
    );
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

public(package) macro fun default_max_spot_deviation(): u64 { 20_000_000 }
public(package) macro fun min_max_spot_deviation(): u64 { 1 }
public(package) macro fun max_max_spot_deviation(): u64 { 100_000_000 }

public(package) fun assert_max_spot_deviation(value: u64) {
    assert!(
        value >= min_max_spot_deviation!() && value <= max_max_spot_deviation!(),
        EInvalidMaxSpotDeviation,
    );
}

public(package) macro fun default_max_basis_deviation(): u64 { 20_000_000 }
public(package) macro fun min_max_basis_deviation(): u64 { 1 }
public(package) macro fun max_max_basis_deviation(): u64 { 100_000_000 }

public(package) fun assert_max_basis_deviation(value: u64) {
    assert!(
        value >= min_max_basis_deviation!() && value <= max_max_basis_deviation!(),
        EInvalidMaxBasisDeviation,
    );
}

public(package) macro fun default_min_basis(): u64 { 900_000_000 }
public(package) macro fun min_min_basis(): u64 { 500_000_000 }
public(package) macro fun max_min_basis(): u64 { 2_000_000_000 }

public(package) fun assert_min_basis(value: u64) {
    assert!(value >= min_min_basis!() && value <= max_min_basis!(), EInvalidMinBasis);
}

public(package) macro fun default_max_basis(): u64 { 1_100_000_000 }
public(package) macro fun min_max_basis(): u64 { 500_000_000 }
public(package) macro fun max_max_basis(): u64 { 2_000_000_000 }

public(package) fun assert_max_basis(value: u64) {
    assert!(value >= min_max_basis!() && value <= max_max_basis!(), EInvalidMaxBasis);
}
