// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Wire-contract coverage for the canonical ProtocolConfig history events.
#[test_only]
module deepbook_predict::config_events_tests;

use deepbook_predict::{config_events, test_helpers};
use std::{bcs, unit_test::{assert_eq, destroy}};
use sui::{clock, event, test_scenario::return_shared};

const EVENT_TIMESTAMP_MS: u64 = 1_750_000_000_000;
const FIRST_EVENT_INDEX: u64 = 0;
const ONE_EVENT: u64 = 1;
const TWO_EVENTS: u64 = 2;
const FOUR_EVENTS: u64 = 4;
const EIGHT_EVENTS: u64 = 8;

const BACKING_BUFFER_LAMBDA: u64 = 300_000_000;
const BASE_FEE: u64 = 30_000_000;
const MIN_FEE: u64 = 6_000_000;
const MIN_ENTRY_PROBABILITY: u64 = 20_000_000;
const MAX_ENTRY_PROBABILITY: u64 = 980_000_000;
const EXPIRY_FEE_WINDOW_MS: u64 = 120_000;
const EXPIRY_FEE_MAX_MULTIPLIER: u64 = 2_000_000_000;
const INVENTORY_IMPACT_MAX_RATE: u64 = 100_000_000;

const PYTH_SPOT_FRESHNESS_MS: u64 = 20_000;
const BLOCK_SCHOLES_PRICE_FRESHNESS_MS: u64 = 30_000;
const BLOCK_SCHOLES_SVI_FRESHNESS_MS: u64 = 90_000;

const EWMA_ALPHA: u64 = 20_000_000;
const EWMA_Z_SCORE_THRESHOLD: u64 = 4_000_000_000;
const EWMA_PENALTY_RATE: u64 = 1_500_000;

const DEFAULT_PLP_WITHDRAW_FEE_RATE: u64 = 2_000_000;
const PLP_SUPPLY_FEE_RATE: u64 = 1_000_000;
const PLP_WITHDRAW_FEE_RATE: u64 = 3_000_000;

public struct ExpectedStrikeExposureTemplateConfigUpdated has copy, drop {
    backing_buffer_lambda: u64,
    base_fee: u64,
    min_fee: u64,
    min_entry_probability: u64,
    max_entry_probability: u64,
    expiry_fee_window_ms: u64,
    expiry_fee_max_multiplier: u64,
    inventory_impact_max_rate: u64,
    onchain_timestamp_ms: u64,
}

public struct ExpectedPricingConfigUpdated has copy, drop {
    use_pyth_spot_for_forward: bool,
    pyth_spot_freshness_ms: u64,
    block_scholes_price_freshness_ms: u64,
    block_scholes_svi_freshness_ms: u64,
    onchain_timestamp_ms: u64,
}

public struct ExpectedEwmaConfigUpdated has copy, drop {
    alpha: u64,
    z_score_threshold: u64,
    penalty_rate: u64,
    enabled: bool,
    onchain_timestamp_ms: u64,
}

public struct ExpectedPlpFeeRatesUpdated has copy, drop {
    plp_supply_fee_rate: u64,
    plp_withdraw_fee_rate: u64,
    onchain_timestamp_ms: u64,
}

#[test]
fun strike_exposure_template_setters_emit_complete_post_state() {
    let (mut scenario, registry, mut config, admin_cap) = test_helpers::begin_registry_test();
    let mut clock = clock::create_for_testing(scenario.ctx());
    clock.set_for_testing(EVENT_TIMESTAMP_MS);

    config.set_template_backing_buffer_lambda(&admin_cap, BACKING_BUFFER_LAMBDA, &clock);
    config.set_template_base_fee(&admin_cap, BASE_FEE, &clock);
    config.set_template_min_fee(&admin_cap, MIN_FEE, &clock);
    config.set_template_min_entry_probability(&admin_cap, MIN_ENTRY_PROBABILITY, &clock);
    config.set_template_max_entry_probability(&admin_cap, MAX_ENTRY_PROBABILITY, &clock);
    config.set_template_expiry_fee_window_ms(&admin_cap, EXPIRY_FEE_WINDOW_MS, &clock);
    config.set_template_expiry_fee_max_multiplier(
        &admin_cap,
        EXPIRY_FEE_MAX_MULTIPLIER,
        &clock,
    );
    config.set_template_inventory_impact_max_rate(
        &admin_cap,
        INVENTORY_IMPACT_MAX_RATE,
        &clock,
    );

    let events = event::events_by_type<config_events::StrikeExposureTemplateConfigUpdated>();
    assert_eq!(events.length(), EIGHT_EVENTS);
    let expected = ExpectedStrikeExposureTemplateConfigUpdated {
        backing_buffer_lambda: BACKING_BUFFER_LAMBDA,
        base_fee: BASE_FEE,
        min_fee: MIN_FEE,
        min_entry_probability: MIN_ENTRY_PROBABILITY,
        max_entry_probability: MAX_ENTRY_PROBABILITY,
        expiry_fee_window_ms: EXPIRY_FEE_WINDOW_MS,
        expiry_fee_max_multiplier: EXPIRY_FEE_MAX_MULTIPLIER,
        inventory_impact_max_rate: INVENTORY_IMPACT_MAX_RATE,
        onchain_timestamp_ms: EVENT_TIMESTAMP_MS,
    };
    assert_eq!(bcs::to_bytes(&events[EIGHT_EVENTS - ONE_EVENT]), bcs::to_bytes(&expected));

    clock.destroy_for_testing();
    destroy(admin_cap);
    return_shared(registry);
    return_shared(config);
    scenario.end();
}

#[test]
fun pricing_setters_emit_complete_post_state() {
    let (mut scenario, registry, mut config, admin_cap) = test_helpers::begin_registry_test();
    let mut clock = clock::create_for_testing(scenario.ctx());
    clock.set_for_testing(EVENT_TIMESTAMP_MS);

    config.set_use_pyth_spot_for_forward(&admin_cap, false, &clock);
    config.set_pyth_spot_freshness_ms(&admin_cap, PYTH_SPOT_FRESHNESS_MS, &clock);
    config.set_block_scholes_price_freshness_ms(
        &admin_cap,
        BLOCK_SCHOLES_PRICE_FRESHNESS_MS,
        &clock,
    );
    config.set_block_scholes_svi_freshness_ms(
        &admin_cap,
        BLOCK_SCHOLES_SVI_FRESHNESS_MS,
        &clock,
    );

    let events = event::events_by_type<config_events::PricingConfigUpdated>();
    assert_eq!(events.length(), FOUR_EVENTS);
    let expected = ExpectedPricingConfigUpdated {
        use_pyth_spot_for_forward: false,
        pyth_spot_freshness_ms: PYTH_SPOT_FRESHNESS_MS,
        block_scholes_price_freshness_ms: BLOCK_SCHOLES_PRICE_FRESHNESS_MS,
        block_scholes_svi_freshness_ms: BLOCK_SCHOLES_SVI_FRESHNESS_MS,
        onchain_timestamp_ms: EVENT_TIMESTAMP_MS,
    };
    assert_eq!(bcs::to_bytes(&events[FOUR_EVENTS - ONE_EVENT]), bcs::to_bytes(&expected));

    clock.destroy_for_testing();
    destroy(admin_cap);
    return_shared(registry);
    return_shared(config);
    scenario.end();
}

#[test]
fun ewma_setters_emit_complete_post_state() {
    let (mut scenario, registry, mut config, admin_cap) = test_helpers::begin_registry_test();
    let mut clock = clock::create_for_testing(scenario.ctx());
    clock.set_for_testing(EVENT_TIMESTAMP_MS);

    config.set_ewma_params(
        &admin_cap,
        EWMA_ALPHA,
        EWMA_Z_SCORE_THRESHOLD,
        EWMA_PENALTY_RATE,
        &clock,
    );
    config.set_ewma_enabled(&admin_cap, true, &clock);

    let events = event::events_by_type<config_events::EwmaConfigUpdated>();
    assert_eq!(events.length(), TWO_EVENTS);
    let expected = ExpectedEwmaConfigUpdated {
        alpha: EWMA_ALPHA,
        z_score_threshold: EWMA_Z_SCORE_THRESHOLD,
        penalty_rate: EWMA_PENALTY_RATE,
        enabled: true,
        onchain_timestamp_ms: EVENT_TIMESTAMP_MS,
    };
    assert_eq!(bcs::to_bytes(&events[TWO_EVENTS - ONE_EVENT]), bcs::to_bytes(&expected));

    clock.destroy_for_testing();
    destroy(admin_cap);
    return_shared(registry);
    return_shared(config);
    scenario.end();
}

#[test]
fun either_plp_fee_setter_emits_both_rates() {
    let (mut scenario, registry, mut config, admin_cap) = test_helpers::begin_registry_test();
    let mut clock = clock::create_for_testing(scenario.ctx());
    clock.set_for_testing(EVENT_TIMESTAMP_MS);

    config.set_plp_supply_fee_rate(&admin_cap, PLP_SUPPLY_FEE_RATE, &clock);
    config.set_plp_withdraw_fee_rate(&admin_cap, PLP_WITHDRAW_FEE_RATE, &clock);

    let events = event::events_by_type<config_events::PlpFeeRatesUpdated>();
    assert_eq!(events.length(), TWO_EVENTS);
    let supply_expected = ExpectedPlpFeeRatesUpdated {
        plp_supply_fee_rate: PLP_SUPPLY_FEE_RATE,
        plp_withdraw_fee_rate: DEFAULT_PLP_WITHDRAW_FEE_RATE,
        onchain_timestamp_ms: EVENT_TIMESTAMP_MS,
    };
    assert_eq!(bcs::to_bytes(&events[FIRST_EVENT_INDEX]), bcs::to_bytes(&supply_expected));
    let withdraw_expected = ExpectedPlpFeeRatesUpdated {
        plp_supply_fee_rate: PLP_SUPPLY_FEE_RATE,
        plp_withdraw_fee_rate: PLP_WITHDRAW_FEE_RATE,
        onchain_timestamp_ms: EVENT_TIMESTAMP_MS,
    };
    assert_eq!(bcs::to_bytes(&events[TWO_EVENTS - ONE_EVENT]), bcs::to_bytes(&withdraw_expected));

    clock.destroy_for_testing();
    destroy(admin_cap);
    return_shared(registry);
    return_shared(config);
    scenario.end();
}
