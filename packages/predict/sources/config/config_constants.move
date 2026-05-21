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
const EInvalidUtilizationMultiplier: u64 = 3;
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
const EInvalidSettlementLossRebateRate: u64 = 22;
const EInvalidMintCutoffMs: u64 = 23;
const EInvalidRedeemCutoffMs: u64 = 24;

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

public(package) macro fun default_utilization_multiplier(): u64 { 2_000_000_000 }
public(package) macro fun min_utilization_multiplier(): u64 { 0 }
public(package) macro fun max_utilization_multiplier(): u64 { 10_000_000_000 }

public(package) fun assert_utilization_multiplier(value: u64) {
    assert!(
        value >= min_utilization_multiplier!() && value <= max_utilization_multiplier!(),
        EInvalidUtilizationMultiplier,
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

public(package) macro fun default_settlement_loss_rebate_rate(): u64 {
    500_000_000
}
public(package) macro fun min_settlement_loss_rebate_rate(): u64 { 0 }
public(package) macro fun max_settlement_loss_rebate_rate(): u64 {
    deepbook_predict::constants::float_scaling!()
}

public(package) fun assert_settlement_loss_rebate_rate(value: u64) {
    assert!(
        value >= min_settlement_loss_rebate_rate!()
            && value <= max_settlement_loss_rebate_rate!(),
        EInvalidSettlementLossRebateRate,
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

/// Per-oracle mint cutoff window before expiry. Zero disables; one-day cap
/// keeps mint choke-off from being permanent.
public(package) macro fun min_mint_cutoff_ms(): u64 { 0 }
public(package) macro fun max_mint_cutoff_ms(): u64 { 86_400_000 }

public(package) fun assert_mint_cutoff_ms(value: u64) {
    assert!(value >= min_mint_cutoff_ms!() && value <= max_mint_cutoff_ms!(), EInvalidMintCutoffMs);
}

/// Per-oracle live-redeem cutoff window before expiry. Zero disables;
/// positions inside the window must wait for terminal settlement.
public(package) macro fun min_redeem_cutoff_ms(): u64 { 0 }
public(package) macro fun max_redeem_cutoff_ms(): u64 { 86_400_000 }

public(package) fun assert_redeem_cutoff_ms(value: u64) {
    assert!(
        value >= min_redeem_cutoff_ms!() && value <= max_redeem_cutoff_ms!(),
        EInvalidRedeemCutoffMs,
    );
}
