// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Abort-path coverage for every `strike_exposure_config` error code.
///
/// Setter-side: `EInvalidEntryProbabilityBound` (the relational min < max entry
/// probability guard on the template setters). Leaf math guard:
/// `EInvalidFeeProbability` — unreachable
/// from the public mint surface because `pricing` quotes come from
/// `compute_nd2`'s explicitly clamped digital, so it is exercised by a direct
/// package-internal `trading_fee` call (rule 4). Mint-admission policy is
/// exercised through `assert_mint_admission`, which is the package boundary the
/// real trade flow calls after it has loaded the live price.
#[test_only]
module deepbook_predict::strike_exposure_config_tests;

use deepbook_predict::{
    admin::{Self, AdminCap},
    config_constants,
    constants,
    protocol_config::{Self, ProtocolConfig},
    strike_exposure_config,
    test_constants
};
use fixed_math::math::float_scaling as float;
use std::unit_test::{assert_eq, destroy};
use sui::test_scenario::{Self as test, Scenario, return_shared};

const ENTRY_PROBABILITY_BELOW_MIN: u64 = 5_860_417;
const ENTRY_PROBABILITY_HALF: u64 = 500_000_000;
const DEFAULT_BACKING_BUFFER_LAMBDA: u64 = 310_000_000;
const DEFAULT_BASE_FEE: u64 = 100_000_000;
const DEFAULT_MIN_FEE: u64 = 22_000_000;
const DEFAULT_ATM_FEE_DUSDC_RAW: u64 = 50_000;
const DEFAULT_MIN_FEE_DUSDC_RAW: u64 = 22_000;

/// Create a real shared `ProtocolConfig` (template values at defaults) and an
/// `AdminCap`, ready for admin setter calls in the next transaction.
fun new_shared_config(): (Scenario, AdminCap, ID) {
    let mut scenario = test::begin(test_constants::admin());
    let config_id = protocol_config::create_and_share(scenario.ctx());
    let admin_cap = admin::new(scenario.ctx());
    scenario.next_tx(test_constants::admin());
    (scenario, admin_cap, config_id)
}

#[test]
fun new_config_seeds_default_market_economics() {
    let config = strike_exposure_config::new();

    assert_eq!(config.backing_buffer_lambda(), DEFAULT_BACKING_BUFFER_LAMBDA);
    assert_eq!(config.base_fee(), DEFAULT_BASE_FEE);
    assert_eq!(config.min_fee(), DEFAULT_MIN_FEE);
    // At p = 0.5, sqrt(p * (1 - p)) = 0.5, so the default base fee
    // charges 0.05 DUSDC on one 1-DUSDC-payout contract.
    assert_eq!(
        config.trading_fee(
            test_constants::default_expiry_ms(),
            ENTRY_PROBABILITY_HALF,
            test_constants::dusdc_unit(),
            test_constants::now_ms(),
        ),
        DEFAULT_ATM_FEE_DUSDC_RAW,
    );
    destroy(config);
}

// === EInvalidEntryProbabilityBound (template setter relational guard) ===

// A min entry probability equal to the current max entry probability is the
// tightest just-outside value
// (the setter requires min < max strictly); it is inside the
// `config_constants` envelope, so the relational guard is what fires.
#[test, expected_failure(abort_code = strike_exposure_config::EInvalidEntryProbabilityBound)]
fun template_min_entry_probability_at_max_entry_probability_aborts() {
    let (scenario, admin_cap, config_id) = new_shared_config();
    let mut config = scenario.take_shared_by_id<ProtocolConfig>(config_id);
    config.set_template_min_entry_probability(
        &admin_cap,
        config_constants::default_max_entry_probability!(),
    );
    abort 999
}

#[test, expected_failure(abort_code = strike_exposure_config::EInvalidEntryProbabilityBound)]
fun template_max_entry_probability_at_min_entry_probability_aborts() {
    let (scenario, admin_cap, config_id) = new_shared_config();
    let mut config = scenario.take_shared_by_id<ProtocolConfig>(config_id);
    config.set_template_max_entry_probability(
        &admin_cap,
        config_constants::default_min_entry_probability!(),
    );
    abort 999
}

#[test]
fun template_entry_probability_bounds_accept_adjacent_values() {
    let (scenario, admin_cap, config_id) = new_shared_config();
    let mut config = scenario.take_shared_by_id<ProtocolConfig>(config_id);

    // min one unit below the default max, then max one unit above that min:
    // the tightest just-inside pair for the relational guard.
    config.set_template_min_entry_probability(
        &admin_cap,
        config_constants::default_max_entry_probability!() - 1,
    );
    config.set_template_max_entry_probability(
        &admin_cap,
        config_constants::default_max_entry_probability!(),
    );

    let snapshot = config.strike_exposure_config_snapshot();
    assert_eq!(
        snapshot.min_entry_probability(),
        config_constants::default_max_entry_probability!() - 1,
    );
    assert_eq!(
        snapshot.max_entry_probability(),
        config_constants::default_max_entry_probability!(),
    );
    destroy(snapshot);

    return_shared(config);
    destroy(admin_cap);
    scenario.end();
}

// The default seeds a 1h block, and the template setter reaches the snapshot that
// future expiry markets take.

// === EInvalidFeeProbability (leaf math guard, direct call) ===

#[test, expected_failure(abort_code = strike_exposure_config::EInvalidFeeProbability)]
fun trading_fee_probability_above_one_aborts() {
    let config = strike_exposure_config::new();
    config.trading_fee(
        test_constants::default_expiry_ms(),
        float!() + 1,
        test_constants::mint_quantity(),
        test_constants::now_ms(),
    );
    abort 999
}

#[test]
fun trading_fee_at_probability_one_floors_at_min_fee() {
    let config = strike_exposure_config::new();
    // Just-inside boundary: p = 1.0 is accepted. Bernoulli variance at p = 1
    // is 0, so the raw fee is 0 and the per-unit rate floors at the default
    // min fee; far from expiry the ramp multiplier is 1x, so one contract pays
    // the 0.022 DUSDC floor.
    assert_eq!(
        config.trading_fee(
            test_constants::default_expiry_ms(),
            float!(),
            test_constants::dusdc_unit(),
            test_constants::now_ms(),
        ),
        DEFAULT_MIN_FEE_DUSDC_RAW,
    );
    destroy(config);
}

// === EEntryProbabilityOutOfBounds (mint admission) ===

#[test, expected_failure(abort_code = strike_exposure_config::EEntryProbabilityOutOfBounds)]
fun mint_admission_probability_one_above_max_entry_probability_aborts() {
    let config = strike_exposure_config::new();
    // p = 1.0 is above the default max entry probability 0.99.
    config.assert_mint_admission(
        float!(),
        test_constants::mint_quantity(),
    );
    abort 999
}

#[test, expected_failure(abort_code = strike_exposure_config::EEntryProbabilityOutOfBounds)]
fun mint_admission_probability_below_min_entry_probability_aborts() {
    let config = strike_exposure_config::new();
    // This probability is below 1%, but its old all-in ask price would have
    // cleared 1% after the min fee was added. Admission now gates raw
    // probability directly.
    config.assert_mint_admission(
        ENTRY_PROBABILITY_BELOW_MIN,
        test_constants::mint_quantity(),
    );
    abort 999
}

// === EPremiumBelowMinimum (mint admission) ===

#[test, expected_failure(abort_code = strike_exposure_config::EPremiumBelowMinimum)]
fun mint_admission_premium_one_lot_below_minimum_aborts() {
    let config = strike_exposure_config::new();
    // At p = 0.5, quantity 1_990_000 gives premium
    // 995_000, one position lot below the 1_000_000 minimum.
    config.assert_mint_admission(
        ENTRY_PROBABILITY_HALF,
        2 * constants::min_premium!() - constants::position_lot_size!(),
    );
    abort 999
}

#[test]
fun mint_admission_premium_at_minimum_succeeds() {
    let config = strike_exposure_config::new();

    let premium = config.assert_mint_admission(
        ENTRY_PROBABILITY_HALF,
        2 * constants::min_premium!(),
    );
    assert_eq!(premium, constants::min_premium!());
    destroy(config);
}
