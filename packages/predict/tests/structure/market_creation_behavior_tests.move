// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Structural coverage for market identity, pool registration, and snapshotted policy.
#[test_only]
module deepbook_predict::scope_structure__intent_behavior__market_creation_tests;

use deepbook_predict::{oracle_setup, test_values, test_world};
use std::unit_test::assert_eq;
use sui::test_scenario::return_shared;

const SNAPSHOT_REBATE_RATE: u64 = 250_000_000;
const SNAPSHOT_LIQUIDATION_LTV: u64 = 800_000_000;
const SNAPSHOT_MAX_LEVERAGE: u64 = 2_000_000_000;
const SNAPSHOT_BACKING_LAMBDA: u64 = 300_000_000;
const SNAPSHOT_EXPIRY_FEE_WINDOW_MS: u64 = 300_000;
const SNAPSHOT_EXPIRY_FEE_MULTIPLIER: u64 = 2_000_000_000;
const SNAPSHOT_NO_LEVERAGE_WINDOW_MS: u64 = 60_000;

#[test]
fun creation_records_identity_pool_membership_and_immutable_market_policy() {
    let (mut world, resources) = test_world::new(
        test_values::system(),
        test_values::admin(),
        test_values::now_ms(),
    );

    let admin_cap = test_world::take_predict_admin_cap(&world);
    let mut registry = test_world::take_registry(&world);
    let mut config = test_world::take_config(&world);
    registry.register_underlying(&config, &admin_cap, test_values::propbook_underlying_id());
    registry.set_template_cadence_config(
        &config,
        &admin_cap,
        test_values::propbook_underlying_id(),
        test_values::cadence_id(),
        test_values::tick_size(),
        test_values::admission_tick_size(),
        test_values::max_expiry_allocation(),
        test_values::initial_expiry_cash(),
        test_values::cadence_window_size(),
    );
    config.set_template_trading_loss_rebate_rate(&admin_cap, SNAPSHOT_REBATE_RATE);
    config.set_template_liquidation_ltv(&admin_cap, SNAPSHOT_LIQUIDATION_LTV);
    config.set_template_max_admission_leverage(&admin_cap, SNAPSHOT_MAX_LEVERAGE);
    config.set_template_backing_buffer_lambda(&admin_cap, SNAPSHOT_BACKING_LAMBDA);
    config.set_template_expiry_fee_window_ms(&admin_cap, SNAPSHOT_EXPIRY_FEE_WINDOW_MS);
    config.set_template_expiry_fee_max_multiplier(
        &admin_cap,
        SNAPSHOT_EXPIRY_FEE_MULTIPLIER,
    );
    config.set_template_no_leverage_window_ms(&admin_cap, SNAPSHOT_NO_LEVERAGE_WINDOW_MS);
    return_shared(config);
    return_shared(registry);
    test_world::return_predict_admin_cap(&world, admin_cap);
    let oracles = oracle_setup::create_default_oracles(&mut world);

    test_world::next_tx(&mut world, test_values::admin());
    let propbook_admin_cap = test_world::take_propbook_admin_cap(&world);
    oracle_setup::bind_default_oracles(&world, &propbook_admin_cap, &oracles);
    test_world::return_propbook_admin_cap(&world, propbook_admin_cap);

    test_world::next_tx(&mut world, test_values::admin());
    let admin_cap = test_world::take_predict_admin_cap(&world);
    let mut registry = test_world::take_registry(&world);
    let mut vault = test_world::take_vault(&world);
    let mut config = test_world::take_config(&world);
    let oracle_registry = test_world::take_oracle_registry(&world);
    let lifecycle_cap = registry.mint_lifecycle_cap(
        &config,
        &admin_cap,
        test_world::ctx(&mut world),
    );
    let market_id = registry.create_and_share_expiry_market(
        &mut vault,
        &config,
        &oracle_registry,
        &lifecycle_cap,
        test_values::propbook_underlying_id(),
        test_values::cadence_id(),
        test_world::clock(&resources),
        test_world::ctx(&mut world),
    );
    assert_eq!(
        registry
            .expiry_market_id(test_values::propbook_underlying_id(), test_values::expiry_ms())
            .destroy_some(),
        market_id,
    );
    assert_eq!(vault.active_expiry_markets(), vector[market_id]);
    assert_eq!(vault.active_live_expiry_count(test_world::clock(&resources)), 1);

    config.set_template_trading_loss_rebate_rate(&admin_cap, 500_000_000);
    config.set_template_liquidation_ltv(&admin_cap, 900_000_000);
    config.set_template_max_admission_leverage(&admin_cap, 3_000_000_000);
    config.set_template_backing_buffer_lambda(&admin_cap, 400_000_000);
    config.set_template_expiry_fee_window_ms(&admin_cap, 600_000);
    config.set_template_expiry_fee_max_multiplier(&admin_cap, 3_000_000_000);
    config.set_template_no_leverage_window_ms(&admin_cap, 120_000);

    return_shared(oracle_registry);
    return_shared(config);
    return_shared(vault);
    return_shared(registry);
    lifecycle_cap.destroy();
    test_world::return_predict_admin_cap(&world, admin_cap);

    test_world::next_tx(&mut world, test_values::admin());
    let market = test_world::take_shared_by_id<deepbook_predict::expiry_market::ExpiryMarket>(
        &world,
        market_id,
    );
    assert_eq!(market.id(), market_id);
    assert_eq!(market.propbook_underlying_id(), test_values::propbook_underlying_id());
    assert_eq!(market.expiry(), test_values::expiry_ms());
    assert_eq!(market.reference_tick_source_timestamp_ms(), test_values::now_ms());
    assert_eq!(market.cash_balance(), 0);
    assert_eq!(market.payout_liability(), 0);
    assert_eq!(market.required_cash(), 0);
    assert!(!market.is_settled());
    assert!(market.try_settlement_price().is_none());
    assert!(!market.mint_paused());
    assert_eq!(market.tick_size(), test_values::tick_size());
    assert_eq!(market.admission_tick_size(), test_values::admission_tick_size());
    assert_eq!(market.trading_loss_rebate_rate(), SNAPSHOT_REBATE_RATE);
    assert_eq!(market.liquidation_ltv(), SNAPSHOT_LIQUIDATION_LTV);
    assert_eq!(market.max_admission_leverage(), SNAPSHOT_MAX_LEVERAGE);
    assert_eq!(market.backing_buffer_lambda(), SNAPSHOT_BACKING_LAMBDA);
    assert_eq!(market.expiry_fee_window_ms(), SNAPSHOT_EXPIRY_FEE_WINDOW_MS);
    assert_eq!(market.expiry_fee_max_multiplier(), SNAPSHOT_EXPIRY_FEE_MULTIPLIER);
    assert_eq!(market.no_leverage_window_ms(), SNAPSHOT_NO_LEVERAGE_WINDOW_MS);
    return_shared(market);
    test_world::finish(world, resources);
}
