// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Cover admin-gated setters on the modules that own the mutated state.
/// The tests verify each value reaches its destination and can be read back
/// through the owning object's getter.
#[test_only]
module deepbook_predict::admin_setters_tests;

use deepbook_predict::{
    admin,
    config_constants,
    constants::float_scaling as float,
    fee_config,
    leverage_config,
    market_oracle_config,
    pricing_config,
    protocol_config,
    registry,
    risk_config,
    stake_config
};
use std::unit_test::{assert_eq, destroy};

const PYTH_FEED_BTC: u32 = 100;
const BTC_TICK_SIZE: u64 = 1_000_000_000; // $1.00 in 1e9 price scaling

// === Pricing config setters ===

#[test]
fun set_base_fee_forwards_to_pricing_config() {
    let ctx = &mut tx_context::dummy();
    let admin_cap = admin::create_admin_cap_for_testing(ctx);
    let mut config = protocol_config::new_for_testing(ctx);

    protocol_config::set_base_fee(&mut config, &admin_cap, 30_000_000);
    assert_eq!(pricing_config::base_fee(config.pricing_config()), 30_000_000);

    destroy(config);
    destroy(admin_cap);
}

#[test]
fun set_min_fee_forwards_to_pricing_config() {
    let ctx = &mut tx_context::dummy();
    let admin_cap = admin::create_admin_cap_for_testing(ctx);
    let mut config = protocol_config::new_for_testing(ctx);

    protocol_config::set_min_fee(&mut config, &admin_cap, 4_000_000);
    assert_eq!(pricing_config::min_fee(config.pricing_config()), 4_000_000);

    destroy(config);
    destroy(admin_cap);
}

#[test]
fun set_min_and_max_ask_price_forward_to_pricing_config() {
    let ctx = &mut tx_context::dummy();
    let admin_cap = admin::create_admin_cap_for_testing(ctx);
    let mut config = protocol_config::new_for_testing(ctx);

    protocol_config::set_min_ask_price(&mut config, &admin_cap, 20_000_000);
    protocol_config::set_max_ask_price(&mut config, &admin_cap, 980_000_000);
    assert_eq!(pricing_config::min_ask_price(config.pricing_config()), 20_000_000);
    assert_eq!(pricing_config::max_ask_price(config.pricing_config()), 980_000_000);

    destroy(config);
    destroy(admin_cap);
}

#[test]
fun set_freshness_setters_forward_to_pricing_config() {
    let ctx = &mut tx_context::dummy();
    let admin_cap = admin::create_admin_cap_for_testing(ctx);
    let mut config = protocol_config::new_for_testing(ctx);

    protocol_config::set_pyth_spot_freshness_ms(&mut config, &admin_cap, 5_000);
    protocol_config::set_block_scholes_prices_freshness_ms(&mut config, &admin_cap, 4_000);
    protocol_config::set_block_scholes_svi_freshness_ms(&mut config, &admin_cap, 30_000);
    assert_eq!(pricing_config::pyth_spot_freshness_ms(config.pricing_config()), 5_000);
    assert_eq!(pricing_config::block_scholes_prices_freshness_ms(config.pricing_config()), 4_000);
    assert_eq!(pricing_config::block_scholes_svi_freshness_ms(config.pricing_config()), 30_000);

    destroy(config);
    destroy(admin_cap);
}

// === Fee config setters ===

#[test]
fun set_fee_shares_forwards_all_three_to_fee_config() {
    let ctx = &mut tx_context::dummy();
    let admin_cap = admin::create_admin_cap_for_testing(ctx);
    let mut config = protocol_config::new_for_testing(ctx);

    protocol_config::set_fee_shares(&mut config, &admin_cap, 700_000_000, 200_000_000, 100_000_000);
    assert_eq!(fee_config::lp_fee_share(config.fee_config()), 700_000_000);
    assert_eq!(fee_config::protocol_fee_share(config.fee_config()), 200_000_000);
    assert_eq!(fee_config::insurance_fee_share(config.fee_config()), 100_000_000);

    destroy(config);
    destroy(admin_cap);
}

#[test]
fun set_template_trading_loss_rebate_rate_forwards_to_fee_config() {
    let ctx = &mut tx_context::dummy();
    let admin_cap = admin::create_admin_cap_for_testing(ctx);
    let mut config = protocol_config::new_for_testing(ctx);

    protocol_config::set_template_trading_loss_rebate_rate(&mut config, &admin_cap, 250_000_000);
    assert_eq!(fee_config::trading_loss_rebate_rate(config.fee_config()), 250_000_000);

    destroy(config);
    destroy(admin_cap);
}

// === Risk config setters ===

#[test]
fun set_max_total_exposure_pct_forwards_to_risk_config() {
    let ctx = &mut tx_context::dummy();
    let admin_cap = admin::create_admin_cap_for_testing(ctx);
    let mut config = protocol_config::new_for_testing(ctx);

    protocol_config::set_max_total_exposure_pct(&mut config, &admin_cap, 500_000_000);
    assert_eq!(risk_config::max_total_exposure_pct(config.risk_config()), 500_000_000);

    destroy(config);
    destroy(admin_cap);
}

#[test]
fun set_expiry_allocation_forwards_to_risk_config() {
    let ctx = &mut tx_context::dummy();
    let admin_cap = admin::create_admin_cap_for_testing(ctx);
    let mut config = protocol_config::new_for_testing(ctx);

    protocol_config::set_expiry_allocation(&mut config, &admin_cap, 100_000_000_000);
    assert_eq!(risk_config::expiry_allocation(config.risk_config()), 100_000_000_000);

    destroy(config);
    destroy(admin_cap);
}

#[test]
fun set_resize_setters_forward_to_risk_config() {
    let ctx = &mut tx_context::dummy();
    let admin_cap = admin::create_admin_cap_for_testing(ctx);
    let mut config = protocol_config::new_for_testing(ctx);

    protocol_config::set_grow_utilization_threshold(&mut config, &admin_cap, 900_000_000);
    protocol_config::set_shrink_utilization_threshold(&mut config, &admin_cap, 200_000_000);
    protocol_config::set_grow_factor(&mut config, &admin_cap, 3 * float!());
    protocol_config::set_shrink_factor(&mut config, &admin_cap, 400_000_000);

    assert_eq!(risk_config::grow_utilization_threshold(config.risk_config()), 900_000_000);
    assert_eq!(risk_config::shrink_utilization_threshold(config.risk_config()), 200_000_000);
    assert_eq!(risk_config::grow_factor(config.risk_config()), 3 * float!());
    assert_eq!(risk_config::shrink_factor(config.risk_config()), 400_000_000);

    destroy(config);
    destroy(admin_cap);
}

// === Leverage config setter ===

#[test]
fun set_template_max_expiry_floor_premium_forwards_to_leverage_config() {
    let ctx = &mut tx_context::dummy();
    let admin_cap = admin::create_admin_cap_for_testing(ctx);
    let mut config = protocol_config::new_for_testing(ctx);

    protocol_config::set_template_max_expiry_floor_premium(&mut config, &admin_cap, 300_000_000);
    assert_eq!(leverage_config::max_expiry_floor_premium(config.leverage_config()), 300_000_000);

    destroy(config);
    destroy(admin_cap);
}

// === Stake config setter ===

#[test]
fun set_benefit_powers_forwards_to_stake_config() {
    let ctx = &mut tx_context::dummy();
    let admin_cap = admin::create_admin_cap_for_testing(ctx);
    let mut config = protocol_config::new_for_testing(ctx);

    protocol_config::set_benefit_powers(
        &mut config,
        &admin_cap,
        200_000_000_000,
        1_000_000_000_000,
    );
    assert_eq!(stake_config::lower_benefit_power(config.stake_config()), 200_000_000_000);
    assert_eq!(stake_config::upper_benefit_power(config.stake_config()), 1_000_000_000_000);

    destroy(config);
    destroy(admin_cap);
}

// === Market oracle template setters ===

#[test]
fun set_market_oracle_template_settlement_freshness_forwards() {
    let ctx = &mut tx_context::dummy();
    let admin_cap = admin::create_admin_cap_for_testing(ctx);
    let mut config = protocol_config::new_for_testing(ctx);

    protocol_config::set_market_oracle_template_settlement_freshness_ms(
        &mut config,
        &admin_cap,
        5_000,
    );
    assert_eq!(market_oracle_config::settlement_freshness_ms(config.market_oracle_config()), 5_000);

    destroy(config);
    destroy(admin_cap);
}

#[test]
fun set_market_oracle_template_basis_bounds_forwards_all_four() {
    let ctx = &mut tx_context::dummy();
    let admin_cap = admin::create_admin_cap_for_testing(ctx);
    let mut config = protocol_config::new_for_testing(ctx);

    protocol_config::set_market_oracle_template_basis_bounds(
        &mut config,
        &admin_cap,
        50_000_000,
        60_000_000,
        950_000_000,
        1_050_000_000,
    );
    assert_eq!(market_oracle_config::max_spot_deviation(config.market_oracle_config()), 50_000_000);
    assert_eq!(
        market_oracle_config::max_basis_deviation(config.market_oracle_config()),
        60_000_000,
    );
    assert_eq!(market_oracle_config::min_basis(config.market_oracle_config()), 950_000_000);
    assert_eq!(market_oracle_config::max_basis(config.market_oracle_config()), 1_050_000_000);

    destroy(config);
    destroy(admin_cap);
}

// === trading_paused round-trip ===

#[test]
fun set_trading_paused_round_trips_through_config_getter() {
    let ctx = &mut tx_context::dummy();
    let admin_cap = admin::create_admin_cap_for_testing(ctx);
    let mut config = protocol_config::new_for_testing(ctx);

    assert!(!config.trading_paused());
    protocol_config::set_trading_paused(&mut config, &admin_cap, true);
    assert!(config.trading_paused());
    // Admin can also unpause (unlike PauseCap which is one-way).
    protocol_config::set_trading_paused(&mut config, &admin_cap, false);
    assert!(!config.trading_paused());

    destroy(config);
    destroy(admin_cap);
}

// === Pyth feed expiry-fee setter ===

#[test]
fun set_pyth_feed_expiry_fee_max_multiplier_updates_config() {
    let ctx = &mut tx_context::dummy();
    let (mut reg, admin_cap) = registry::new_for_testing(ctx);
    registry::create_pyth_source(
        &mut reg,
        &admin_cap,
        PYTH_FEED_BTC,
        BTC_TICK_SIZE,
        float!(),
        ctx,
    );

    registry::set_pyth_feed_expiry_fee_max_multiplier(
        &mut reg,
        &admin_cap,
        PYTH_FEED_BTC,
        2 * float!(),
    );
    assert_eq!(
        *registry::pyth_feed_expiry_fee_max_multiplier(&reg, PYTH_FEED_BTC).borrow(),
        2 * float!(),
    );

    registry::destroy_registry_drop_for_testing(reg);
    destroy(admin_cap);
}

#[test, expected_failure(abort_code = config_constants::EInvalidExpiryFeeMaxMultiplier)]
fun set_pyth_feed_expiry_fee_multiplier_below_min_aborts() {
    let ctx = &mut tx_context::dummy();
    let (mut reg, admin_cap) = registry::new_for_testing(ctx);
    registry::create_pyth_source(
        &mut reg,
        &admin_cap,
        PYTH_FEED_BTC,
        BTC_TICK_SIZE,
        float!(),
        ctx,
    );

    registry::set_pyth_feed_expiry_fee_max_multiplier(
        &mut reg,
        &admin_cap,
        PYTH_FEED_BTC,
        config_constants::min_expiry_fee_max_multiplier!() - 1,
    );
    abort 999
}
