// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Regression coverage for the exposure invariant behind post-settlement
/// liquidated-order redemption: a liquidated leveraged order has already been
/// removed from active exposure, so settled-market cleanup must clear its tombstone
/// instead of trying to close it as a settled active order.
#[test_only]
module deepbook_predict::liquidated_settled_redeem_tests;

use deepbook_predict::{
    constants,
    liquidation_book,
    oracle_fixture::{Self, OracleFixture},
    order::Order,
    protocol_config::ProtocolConfig,
    strike_exposure::{Self, StrikeExposure},
    strike_exposure_config,
    test_constants
};
use propbook::{block_scholes_feed::BlockScholesFeed, pyth_feed::PythFeed, registry::OracleRegistry};
use std::unit_test::assert_eq;
use sui::{object::{Self, UID}, test_scenario::return_shared};

public struct ExposureHarness has key {
    id: UID,
    exposure: StrikeExposure,
}

const LEVERAGE_TWO_X: u64 = 2_000_000_000;
/// 1% spot drop from the default 100e9 live spot knocks the 2x ATM UP range below
/// its liquidation threshold with the default near-zero SVI surface.
const DROPPED_SPOT: u64 = 99_000_000_000;
const DROPPED_SOURCE_TIMESTAMP_MS: u64 = 119_500;
/// Inside `(default_strike_tick, +inf]`, proving a liquidated order would have
/// been a settled winner if it were incorrectly treated as active.
const SETTLED_WINNING_SPOT: u64 = 101_000_000_000;

#[test]
fun liquidated_order_uses_tombstone_cleanup_not_settled_close() {
    let (fx, pyth, bs, oracle_registry, config, mut harness, order) = liquidated_order_fixture();

    assert!(harness.exposure.is_liquidated_order(&order));
    assert_eq!(harness.exposure.payout_liability(), 0);
    assert_eq!(harness.exposure.materialize_settled_liability(SETTLED_WINNING_SPOT), 0);

    harness.exposure.clear_liquidated_order(&order);

    assert!(!harness.exposure.is_liquidated_order(&order));
    assert_eq!(harness.exposure.payout_liability(), 0);

    cleanup(fx, pyth, bs, oracle_registry, config, harness);
}

#[test, expected_failure(abort_code = liquidation_book::EActiveOrderNotFound)]
fun settled_close_of_liquidated_order_aborts_because_order_is_not_active() {
    let (
        _fx,
        _pyth,
        _bs,
        _oracle_registry,
        _config,
        mut harness,
        order,
    ) = liquidated_order_fixture();

    harness.exposure.materialize_settled_liability(SETTLED_WINNING_SPOT);
    harness.exposure.close_settled_order(&order, SETTLED_WINNING_SPOT);

    abort 999
}

fun liquidated_order_fixture(): (
    OracleFixture,
    PythFeed,
    BlockScholesFeed,
    OracleRegistry,
    ProtocolConfig,
    ExposureHarness,
    Order,
) {
    let mut fx = oracle_fixture::setup_oracle(
        test_constants::default_live_price(),
        test_constants::default_tick_size(),
        test_constants::short_expiry_ms(),
    );
    fx.scenario_mut().next_tx(test_constants::admin());
    let harness_id = share_exposure_harness(&mut fx);
    fx.scenario_mut().next_tx(test_constants::admin());
    let mut harness = fx.scenario_mut().take_shared_by_id<ExposureHarness>(harness_id);
    let (mut pyth, mut bs, oracle_registry, config) = fx.take_oracle();
    fx.prepare_live_oracle(&mut bs, &mut pyth, test_constants::default_live_price());

    let pricer = fx.load_pricer(&config, &oracle_registry, &pyth, &bs);
    let (order, _, _) = harness
        .exposure
        .allocate_mint_order(
            &pricer,
            test_constants::default_strike_tick(),
            constants::pos_inf_tick!(),
            test_constants::mint_quantity(),
            LEVERAGE_TWO_X,
            fx.clock(),
        );

    fx.set_pyth(&mut pyth, DROPPED_SPOT, DROPPED_SOURCE_TIMESTAMP_MS);
    let liquidation_pricer = fx.load_pricer(&config, &oracle_registry, &pyth, &bs);
    assert!(harness.exposure.liquidate_live_order(&liquidation_pricer, &order, fx.clock()));

    (fx, pyth, bs, oracle_registry, config, harness, order)
}

fun share_exposure_harness(fx: &mut OracleFixture): ID {
    let expiry_market_id = fx.expiry_id();
    let expiry_ms = fx.expiry();
    let id = object::new(fx.scenario_mut().ctx());
    let harness_id = id.to_inner();
    let exposure = strike_exposure::new(
        expiry_market_id,
        expiry_ms,
        test_constants::default_tick_size(),
        strike_exposure_config::new(),
        fx.scenario_mut().ctx(),
    );
    transfer::share_object(ExposureHarness { id, exposure });
    harness_id
}

fun cleanup(
    fx: OracleFixture,
    pyth: PythFeed,
    bs: BlockScholesFeed,
    oracle_registry: OracleRegistry,
    config: ProtocolConfig,
    harness: ExposureHarness,
) {
    return_shared(harness);
    oracle_fixture::return_oracle(pyth, bs, oracle_registry, config);
    fx.finish();
}
