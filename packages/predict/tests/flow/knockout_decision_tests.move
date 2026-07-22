// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// The knock-out decision is taken on a point estimate of the range price, so
/// pricing approximation error — not the position's value — can decide it.
///
/// `strike_exposure::under_liquidation_floor` compares the contract's computed
/// gross against `floor(floor_amount * 1e9 / liquidation_ltv)`, an integer.
/// The computed gross differs from the true gross by the pricing evaluation
/// error, which at production quantities is many integers wide, so a threshold
/// can lie strictly between them. When it does, the contract's answer and the
/// true answer disagree, and the disagreement is not dust: a knocked-out
/// holder forfeits their entire equity above the floor.
///
/// This module builds that disagreement from committed reference data at a
/// position size an ordinary trader can hold.
#[test_only]
module deepbook_predict::scope_flow__intent_rounding__knockout_decision_tests;

use account::account;
use deepbook_predict::{
    account_setup,
    market_setup,
    oracle_profile,
    oracle_setup,
    pool_setup,
    pricing_reference_data,
    test_values,
    test_world
};
use dusdc::dusdc::DUSDC;
use std::unit_test::assert_eq;
use sui::test_scenario::return_shared;

const TICK_LOW: u64 = 90;
const TICK_HIGH: u64 = 110;
const QUANTITY: u64 = 1_000_000_000;
const LEVERAGE_ONE_X: u64 = 1_000_000_000;
// Reference profile 0 (flat_medium_variance); its point index 6 is (90, 110].
const REPRICE_PROFILE: u64 = 0;
const RANGE_POINT_INDEX: u64 = 6;
// The mint surface: flat, low variance, source timestamp below profile 0's so
// the reprice row appends. It prices (90, 110] near 0.9745 — high enough to
// admit the order, low enough to stay under the entry-probability cap.
const MINT_SURFACE_VARIANCE: u64 = 2_000_000;
const MINT_SURFACE_SIGMA: u64 = 1_000_000;
const MINT_SURFACE_SPOT: u64 = 100_000_000_000;
const MINT_SURFACE_SOURCE_MS: u64 = 118_000;
// Default liquidation LTV, spelled locally; asserted against market state so a
// config change fails the test instead of silently moving the threshold.
const LIQUIDATION_LTV: u64 = 850_000_000;
// The committed floor that places the knock-out threshold inside the gap
// between the contract's gross and the true gross:
//   floor(581_663_191 * 1e9 / 0.85e9) = 684_309_636,
// while the contract's gross at profile 0 is 684_309_632 (at or below the
// threshold: knocked out) and the true gross is 684_309_642 (above it: solvent).
const TARGET_FLOOR_SHARES: u64 = 581_663_191;
// Min-fee floor 0.5% of a 1e9 position; the Bernoulli term floors to zero
// under the fixture's base fee of 1, so the close fee is price-independent.
const CLOSE_FEE: u64 = 5_000_000;
const FLOAT_SCALING: u128 = 1_000_000_000;

/// Independent spelling of the knock-out threshold: floor(F * 1e9 / ltv).
fun independent_threshold(floor_shares: u64): u64 {
    (((floor_shares as u128) * FLOAT_SCALING) / (LIQUIDATION_LTV as u128)) as u64
}

/// Independent spelling of a gross value: floor(price * quantity / 1e9).
fun independent_gross(price: u64, quantity: u64): u64 {
    (((price as u128) * (quantity as u128)) / FLOAT_SCALING) as u64
}

// KNOWN-FAILING: P-15
#[test]
fun knockout_threshold_inside_the_pricing_error_band_forfeits_real_equity() {
    let (mut world, resources) = test_world::new(
        test_values::system(),
        test_values::admin(),
        test_values::now_ms(),
    );
    test_world::next_tx(&mut world, test_values::admin());
    let admin_cap = test_world::take_predict_admin_cap(&world);
    market_setup::configure_low_fee_unrestricted_leverage_market(&world, &admin_cap);
    test_world::return_predict_admin_cap(&world, admin_cap);
    let oracles = oracle_setup::create_default_oracles(&mut world);
    test_world::next_tx(&mut world, test_values::admin());
    let oracle_admin_cap = test_world::take_propbook_admin_cap(&world);
    oracle_setup::bind_default_oracles(&world, &oracle_admin_cap, &oracles);
    test_world::return_propbook_admin_cap(&world, oracle_admin_cap);
    test_world::next_tx(&mut world, test_values::admin());
    let admin_cap = test_world::take_predict_admin_cap(&world);
    let market_handle = market_setup::create_default_market(&mut world, &resources, &admin_cap);
    test_world::return_predict_admin_cap(&world, admin_cap);
    test_world::next_tx(&mut world, test_values::admin());
    pool_setup::fund_market(&mut world, &resources, &market_handle, test_values::pool_capital());

    test_world::next_tx(&mut world, test_values::admin());
    let mint_surface = oracle_profile::new(
        oracle_profile::spot_prices(MINT_SURFACE_SPOT, MINT_SURFACE_SPOT, MINT_SURFACE_SPOT),
        oracle_profile::svi_params(
            MINT_SURFACE_VARIANCE,
            false,
            0,
            MINT_SURFACE_SIGMA,
            0,
            false,
            0,
            false,
        ),
        MINT_SURFACE_SOURCE_MS,
    );
    oracle_setup::seed_market_surface(
        &mut world,
        &resources,
        &oracles,
        &market_handle,
        &mint_surface,
        test_values::now_ms(),
    );
    test_world::next_tx(&mut world, test_values::alice());
    let account_handle = account_setup::create_funded_account(
        &mut world,
        &resources,
        test_values::trader_deposit(),
    );

    test_world::next_tx(&mut world, test_values::alice());
    let mut wrapper = account_setup::take_account(&world, &account_handle);
    let root = test_world::take_accumulator_root(&world);
    let mut market = market_setup::take_market(&world, &market_handle);
    let config = test_world::take_config(&world);
    let (pricer, feeds) = oracle_setup::load_pricer(&world, &resources, &oracles, &market, &config);
    assert_eq!(market.liquidation_ltv(), LIQUIDATION_LTV);

    // The committed floor is `entry_value - net_premium`, so the leverage that
    // commits TARGET_FLOOR_SHARES follows from the mint surface's own entry
    // value: net_premium must land on `entry_value - TARGET_FLOOR_SHARES`.
    let probe = market.quote_mint(
        &config,
        &pricer,
        TICK_LOW,
        TICK_HIGH,
        std::u64::max_value!(),
        QUANTITY,
        true,
        LEVERAGE_ONE_X,
        test_world::clock(&resources),
        test_world::ctx(&mut world),
    );
    let entry_value = independent_gross(probe.entry_probability(), QUANTITY);
    let target_premium = entry_value - TARGET_FLOOR_SHARES;
    let leverage = (((entry_value as u128) * FLOAT_SCALING) / (target_premium as u128)) as u64;

    let auth = account::generate_auth(test_world::ctx(&mut world));
    let order_id = market.mint_exact_quantity(
        &mut wrapper,
        auth,
        &config,
        &pricer,
        TICK_LOW,
        TICK_HIGH,
        QUANTITY,
        leverage,
        std::u64::max_value!(),
        std::u64::max_value!(),
        &root,
        test_world::clock(&resources),
        test_world::ctx(&mut world),
    );
    // The order carries exactly the floor the construction targets: its live
    // value is the gross above that floor.
    assert_eq!(
        market.order_value(option::some(pricer), order_id),
        entry_value - TARGET_FLOOR_SHARES,
    );

    oracle_setup::return_feeds(feeds);
    return_shared(config);
    return_shared(market);
    return_shared(root);
    return_shared(wrapper);

    // Reprice onto reference profile 0, where the independent true value of
    // (90, 110] is committed generated data.
    test_world::next_tx(&mut world, test_values::admin());
    let reprice_surface = pricing_reference_data::profile(REPRICE_PROFILE);
    oracle_setup::seed_market_surface(
        &mut world,
        &resources,
        &oracles,
        &market_handle,
        &reprice_surface,
        test_values::now_ms(),
    );

    test_world::next_tx(&mut world, test_values::alice());
    let mut wrapper = account_setup::take_account(&world, &account_handle);
    let root = test_world::take_accumulator_root(&world);
    let mut market = market_setup::take_market(&world, &market_handle);
    let config = test_world::take_config(&world);
    let (pricer, feeds) = oracle_setup::load_pricer(&world, &resources, &oracles, &market, &config);

    // Independent truth: the true range price puts this order's gross strictly
    // ABOVE its knock-out threshold, so the position is solvent and its holder
    // is owed the difference.
    let point = pricing_reference_data::points(REPRICE_PROFILE)[RANGE_POINT_INDEX];
    assert_eq!(pricing_reference_data::lower_tick(&point), TICK_LOW);
    assert_eq!(pricing_reference_data::higher_tick(&point), TICK_HIGH);
    let true_gross = independent_gross(pricing_reference_data::reference(&point), QUANTITY);
    let threshold = independent_threshold(TARGET_FLOOR_SHARES);
    assert!(true_gross > threshold);
    let true_equity = true_gross - TARGET_FLOOR_SHARES;

    // What the holder actually receives on a full close.
    let balance_before = wrapper
        .load_account()
        .balance<DUSDC>(&root, test_world::clock(&resources));
    let auth = account::generate_auth(test_world::ctx(&mut world));
    market.redeem_live(
        &mut wrapper,
        auth,
        &config,
        &pricer,
        order_id,
        QUANTITY,
        0,
        0,
        &root,
        test_world::clock(&resources),
        test_world::ctx(&mut world),
    );
    let proceeds =
        wrapper
            .load_account()
            .balance<DUSDC>(&root, test_world::clock(&resources)) - balance_before;
    // Grant the payout its full certified pricing error and the close fee: a
    // solvent position must still pay its holder essentially all of the equity
    // above the floor. It pays nothing, because the knock-out predicate read
    // the approximation instead of the value.
    let payout_error_allowance =
        independent_gross(pricing_reference_data::tolerance(&point), QUANTITY) + 1;
    let minimum_solvent_proceeds = true_equity - payout_error_allowance - CLOSE_FEE;
    assert!(proceeds >= minimum_solvent_proceeds);

    oracle_setup::return_feeds(feeds);
    return_shared(config);
    return_shared(market);
    return_shared(root);
    return_shared(wrapper);
    test_world::finish(world, resources);
}
