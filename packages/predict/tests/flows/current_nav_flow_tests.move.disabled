// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Differential coverage for the exact single-expiry live NAV reader
/// (`expiry_market::current_nav`). Every test builds protocol state through the
/// production mint flow, then asserts `current_nav` exactly equals an INDEPENDENT
/// per-order reference (`reference_nav`): `free_cash - Σ max(0, qty·P - floor)`,
/// computed straight from each order's atoms and `pricing::range_price`. The
/// reference reuses NONE of `walk_linear` / `correction_value` /
/// `exact_live_liability` / `current_nav` / `expiry_cash::free_cash`, so it is a
/// genuine oracle (unit-tests rule 1): it sums per order, while the contract
/// decomposes into a boundary-aggregated linear walk minus a leveraged-book
/// correction walk.
///
/// All fixtures anchor every finite boundary at `strike_tick` (whose raw strike ==
/// the seeded forward, so `UP(strike) = Φ(0) = 0.5` exactly with the SVI wing
/// rounded to zero) and use even quantities, so the boundary-aggregated linear term
/// equals the per-order sum bit-for-bit and `assert_eq` holds with no rounding dust.
/// The far default expiry keeps the floor index flat at `1.0`, so `index_now = float!()`.
#[test_only]
module deepbook_predict::current_nav_flow_tests;

use deepbook_predict::{
    constants,
    expiry_market::ExpiryMarket,
    flow_test_helpers as helpers,
    order,
    pricing::Pricer,
    protocol_config::ProtocolConfig,
    range_codec,
    test_constants
};
use fixed_math::math::{Self, float_scaling as float};
use propbook::{
    block_scholes_feed::BlockScholesFeed,
    pyth_feed::PythFeed,
    registry::OracleRegistry
};
use std::unit_test::assert_eq;

/// 1x ATM up range, quantity 2e9: priced 0.5 -> 1e9 liability.
const ONE_X_QUANTITY: u64 = 2_000_000_000;
/// Leveraged up range, quantity 2e9, 2x: net_premium 5e8, floor_shares 5e8.
const LEVERAGED_QUANTITY: u64 = 2_000_000_000;
const LEVERAGE_TWO_X: u64 = 2_000_000_000;
/// Second same-strike up order, quantity 4e9.
const SECOND_SAME_STRIKE_QUANTITY: u64 = 4_000_000_000;
/// Deep-OTM forward (well below the 100e9 grid) so the minted up range prices to
/// ~0, driving the leveraged order underwater (value <= floor).
const UNDERWATER_FORWARD: u64 = 10_000_000_000;

#[test]
fun empty_live_market_values_at_free_cash() {
    let (mut fx, expiry_id, _trader) = helpers::setup_everything();
    fx.scenario_mut().next_tx(test_constants::alice());
    let (pyth, bs, oracle_registry, vault, market, config) = fx.take_market(expiry_id);

    // No orders: NAV is exactly the seeded free cash (no fees yet -> rebate 0).
    let nav = fx.current_nav(&market, &config, &oracle_registry, &pyth, &bs);
    assert_eq!(nav, test_constants::default_seeded_expiry_cash());
    check_nav(&fx, &market, &config, &oracle_registry, &pyth, &bs, vector[], float!());

    helpers::return_market(pyth, bs, oracle_registry, vault, market, config);
    fx.finish();
}

#[test]
fun single_one_x_up_order() {
    let (mut fx, expiry_id, trader) = helpers::setup_everything();
    fx.scenario_mut().next_tx(test_constants::alice());
    let (pyth, bs, oracle_registry, vault, mut market, config) = fx.take_market(expiry_id);
    let mut wrapper = fx.take_account(&trader);
    let root = fx.take_root();

    let id = fx.mint(
        &config,
        &oracle_registry,
        &mut wrapper,
        &root,
        &mut market,
        &pyth,
        &bs,
        helpers::strike_tick(),
        constants::pos_inf_tick!(),
        ONE_X_QUANTITY,
        test_constants::leverage_one_x(),
    );

    check_nav(&fx, &market, &config, &oracle_registry, &pyth, &bs, vector[id], float!());

    helpers::return_account(wrapper, root);

    helpers::return_market(pyth, bs, oracle_registry, vault, market, config);
    fx.finish();
}

#[test]
fun single_one_x_down_order_anchored_at_neg_inf() {
    let (mut fx, expiry_id, trader) = helpers::setup_everything();
    fx.scenario_mut().next_tx(test_constants::alice());
    let (pyth, bs, oracle_registry, vault, mut market, config) = fx.take_market(expiry_id);
    let mut wrapper = fx.take_account(&trader);
    let root = fx.take_root();

    let id = fx.mint(
        &config,
        &oracle_registry,
        &mut wrapper,
        &root,
        &mut market,
        &pyth,
        &bs,
        constants::neg_inf!(),
        helpers::strike_tick(),
        ONE_X_QUANTITY,
        test_constants::leverage_one_x(),
    );

    // The (-inf, strike] range exercises the `tree.base` (P(-inf) = 1) anchor.
    check_nav(&fx, &market, &config, &oracle_registry, &pyth, &bs, vector[id], float!());

    helpers::return_account(wrapper, root);

    helpers::return_market(pyth, bs, oracle_registry, vault, market, config);
    fx.finish();
}

#[test]
fun two_one_x_orders_same_strike_collapse_to_one_node() {
    let (mut fx, expiry_id, trader) = helpers::setup_everything();
    fx.scenario_mut().next_tx(test_constants::alice());
    let (pyth, bs, oracle_registry, vault, mut market, config) = fx.take_market(expiry_id);
    let mut wrapper = fx.take_account(&trader);
    let root = fx.take_root();

    let id1 = fx.mint(
        &config,
        &oracle_registry,
        &mut wrapper,
        &root,
        &mut market,
        &pyth,
        &bs,
        helpers::strike_tick(),
        constants::pos_inf_tick!(),
        ONE_X_QUANTITY,
        test_constants::leverage_one_x(),
    );
    let id2 = fx.mint(
        &config,
        &oracle_registry,
        &mut wrapper,
        &root,
        &mut market,
        &pyth,
        &bs,
        helpers::strike_tick(),
        constants::pos_inf_tick!(),
        SECOND_SAME_STRIKE_QUANTITY,
        test_constants::leverage_one_x(),
    );

    // Both up orders share the strike start boundary -> one tree node priced
    // once at P(strike); the aggregate quantity equals the per-order sum.
    check_nav(&fx, &market, &config, &oracle_registry, &pyth, &bs, vector[id1, id2], float!());

    helpers::return_account(wrapper, root);

    helpers::return_market(pyth, bs, oracle_registry, vault, market, config);
    fx.finish();
}

#[test]
fun single_leveraged_order_above_floor() {
    let (mut fx, expiry_id, trader) = helpers::setup_everything();
    fx.scenario_mut().next_tx(test_constants::alice());
    let (pyth, bs, oracle_registry, vault, mut market, config) = fx.take_market(expiry_id);
    let mut wrapper = fx.take_account(&trader);
    let root = fx.take_root();

    let id = fx.mint(
        &config,
        &oracle_registry,
        &mut wrapper,
        &root,
        &mut market,
        &pyth,
        &bs,
        helpers::strike_tick(),
        constants::pos_inf_tick!(),
        LEVERAGED_QUANTITY,
        LEVERAGE_TWO_X,
    );

    // value = mul(0.5, 2e9) = 1e9 > floor = mul(floor_shares 5e8, 1.0) = 5e8, so the
    // correction min() picks the floor and the order's net liability is 5e8.
    check_nav(&fx, &market, &config, &oracle_registry, &pyth, &bs, vector[id], float!());

    helpers::return_account(wrapper, root);

    helpers::return_market(pyth, bs, oracle_registry, vault, market, config);
    fx.finish();
}

#[test]
fun single_leveraged_order_underwater_nets_to_zero() {
    let (mut fx, expiry_id, trader) = helpers::setup_everything();
    fx.scenario_mut().next_tx(test_constants::alice());
    let (mut pyth, mut bs, oracle_registry, vault, mut market, config) = fx.take_market(expiry_id);
    let mut wrapper = fx.take_account(&trader);
    let root = fx.take_root();

    let id = fx.mint(
        &config,
        &oracle_registry,
        &mut wrapper,
        &root,
        &mut market,
        &pyth,
        &bs,
        helpers::strike_tick(),
        constants::pos_inf_tick!(),
        LEVERAGED_QUANTITY,
        LEVERAGE_TWO_X,
    );

    // Drop the forward far below the grid so the up range prices to ~0: value <=
    // floor, the order's limited-recourse floor zeroes its net liability with NO
    // liquidation pass, and NAV returns to free cash.
    fx.prepare_live_oracle(&market, &mut pyth, &mut bs, UNDERWATER_FORWARD);

    let nav = fx.current_nav(&market, &config, &oracle_registry, &pyth, &bs);
    assert_eq!(nav, market.cash_balance().saturating_sub(market.rebate_reserve()));
    check_nav(&fx, &market, &config, &oracle_registry, &pyth, &bs, vector[id], float!());

    helpers::return_account(wrapper, root);

    helpers::return_market(pyth, bs, oracle_registry, vault, market, config);
    fx.finish();
}

#[test]
fun mixed_one_x_and_leveraged_book() {
    let (mut fx, expiry_id, trader) = helpers::setup_everything();
    fx.scenario_mut().next_tx(test_constants::alice());
    let (pyth, bs, oracle_registry, vault, mut market, config) = fx.take_market(expiry_id);
    let mut wrapper = fx.take_account(&trader);
    let root = fx.take_root();

    let up = fx.mint(
        &config,
        &oracle_registry,
        &mut wrapper,
        &root,
        &mut market,
        &pyth,
        &bs,
        helpers::strike_tick(),
        constants::pos_inf_tick!(),
        ONE_X_QUANTITY,
        test_constants::leverage_one_x(),
    );
    let down = fx.mint(
        &config,
        &oracle_registry,
        &mut wrapper,
        &root,
        &mut market,
        &pyth,
        &bs,
        constants::neg_inf!(),
        helpers::strike_tick(),
        ONE_X_QUANTITY,
        test_constants::leverage_one_x(),
    );
    let leveraged = fx.mint(
        &config,
        &oracle_registry,
        &mut wrapper,
        &root,
        &mut market,
        &pyth,
        &bs,
        helpers::strike_tick(),
        constants::pos_inf_tick!(),
        LEVERAGED_QUANTITY,
        LEVERAGE_TWO_X,
    );

    // strike now carries start quantity (1x up + leveraged up) and end quantity
    // (1x down); only the leveraged order is in the correction book.
    check_nav(
        &fx,
        &market,
        &config,
        &oracle_registry,
        &pyth,
        &bs,
        vector[up, down, leveraged],
        float!(),
    );

    helpers::return_account(wrapper, root);

    helpers::return_market(pyth, bs, oracle_registry, vault, market, config);
    fx.finish();
}

// === Helpers ===

/// Assert `current_nav` equals the independent per-order reference and the market
/// stays solvent (S1 backing). The contract builds its own pricer internally; we
/// build an identical one (the oracle is frozen within the tx) for the reference.
fun check_nav(
    fx: &helpers::Fixture,
    market: &ExpiryMarket,
    config: &ProtocolConfig,
    oracle_registry: &OracleRegistry,
    pyth: &PythFeed,
    bs: &BlockScholesFeed,
    order_ids: vector<u256>,
    index_now: u64,
) {
    let pricer = fx.load_pricer(market, config, oracle_registry, pyth, bs);
    let nav = fx.current_nav(market, config, oracle_registry, pyth, bs);
    assert_eq!(nav, reference_nav(market, &pricer, &order_ids, index_now));
    helpers::assert_market_backed(market);
}

/// Independent NAV oracle (unit-tests rule 1): `free_cash - Σ max(0, qty·P - floor)`
/// per open order, using only order atoms and `pricing::range_price`. The order's
/// ticks are converted to raw strikes through the same `range_codec` boundary the
/// contract uses (the codec is the pricing boundary, not the NAV math under test).
fun reference_nav(
    market: &ExpiryMarket,
    pricer: &Pricer,
    order_ids: &vector<u256>,
    index_now: u64,
): u64 {
    let mut liability = 0;
    order_ids.do_ref!(|id| {
        let decoded = order::from_order_id(*id);
        let (lower, higher) = range_codec::strikes_from_ticks(
            decoded.lower_tick(),
            decoded.higher_tick(),
            market.tick_size(),
        );
        let range_value = math::mul(pricer.range_price(lower, higher), decoded.quantity());
        let floor_value = math::mul(decoded.floor_shares(), index_now);
        liability = liability + range_value.saturating_sub(floor_value);
    });
    let free_cash = market.cash_balance().saturating_sub(market.rebate_reserve());
    free_cash.saturating_sub(liability)
}
