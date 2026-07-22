// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Round-trip conservation at fractional prices: the quoted mint tuple must
/// match an independent integer recomputation from the contract's own admitted
/// probability (downstream-exact-given-price), and an immediate full live close
/// at the same surface must refund exactly `net_premium - close_fee` — the
/// rounding-policy R1 same-expression construction means the close's gross
/// recomputation `mul(P, Q)` is bit-equal to the mint's, so the identity
/// `floor_shares = entry_value - net_premium` cancels exactly and the market
/// retains exactly the two fees. Any one-atom deviation on any profile is a
/// lane-disagreement or conservation finding, not tolerance.
#[test_only]
module deepbook_predict::scope_flow__intent_rounding__mint_close_tests;

use account::account;
use deepbook_predict::{
    account_setup,
    market_setup,
    oracle_setup,
    pool_setup,
    pricing_reference_data,
    test_values,
    test_world
};
use dusdc::dusdc::DUSDC;
use std::unit_test::assert_eq;
use sui::test_scenario::return_shared;

// Range (100, 110] prices mid-band on all three reference profiles, keeping
// admission inside the 1c-99c entry-probability bounds.
const RANGE_LOWER_TICK: u64 = 100;
const RANGE_HIGHER_TICK: u64 = 110;
const QUANTITY: u64 = 20_000_000;
const LEVERAGE_ONE_X: u64 = 1_000_000_000;
const LEVERAGE_TWO_X: u64 = 2_000_000_000;
// With template base fee 1 the Bernoulli fee term floors to zero at every
// probability, so mint and close fees sit exactly on the min-fee floor:
// 0.5% x 20e6 quantity = 100_000, independent of the profile's price.
const EXPECTED_FEE: u64 = 100_000;
// 1e9 fixed-point scale, spelled locally so the expected-value arithmetic
// shares no code with the contract's math helpers.
const FLOAT_SCALING: u128 = 1_000_000_000;

/// Independent spelling of the spec's scaled product: floor(a * b / 1e9).
fun independent_floor_mul(a: u64, b: u64): u64 {
    (((a as u128) * (b as u128)) / FLOAT_SCALING) as u64
}

/// Independent spelling of the spec's scaled quotient: floor(a * 1e9 / b).
fun independent_floor_div(a: u64, b: u64): u64 {
    (((a as u128) * FLOAT_SCALING) / (b as u128)) as u64
}

#[test]
fun full_live_close_refunds_premium_minus_fee_across_fractional_profiles() {
    let (mut world, mut resources) = test_world::new(
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
    pool_setup::fund_market(
        &mut world,
        &resources,
        &market_handle,
        test_values::pool_capital(),
    );
    test_world::next_tx(&mut world, test_values::alice());
    let account_handle = account_setup::create_funded_account(
        &mut world,
        &resources,
        test_values::trader_deposit(),
    );

    let mut profile_index = 0;
    while (profile_index < pricing_reference_data::profile_count()) {
        // Each reference profile carries a strictly increasing source
        // timestamp, so successive seeds append fresh feed rows.
        test_world::next_tx(&mut world, test_values::admin());
        let profile = pricing_reference_data::profile(profile_index);
        oracle_setup::seed_market_surface(
            &mut world,
            &resources,
            &oracles,
            &market_handle,
            &profile,
            test_values::now_ms(),
        );

        test_world::next_tx(&mut world, test_values::alice());
        let mut wrapper = account_setup::take_account(&world, &account_handle);
        let root = test_world::take_accumulator_root(&world);
        let mut market = market_setup::take_market(&world, &market_handle);
        let config = test_world::take_config(&world);
        let (pricer, feeds) = oracle_setup::load_pricer(
            &world,
            &resources,
            &oracles,
            &market,
            &config,
        );

        // The committed tuple, recomputed independently from the contract's
        // own admitted probability: E = floor(P*Q/1e9), prem = floor(E*1e9/L),
        // and the fee sits on the price-independent min-fee floor.
        let quote = market.quote_mint(
            &config,
            &pricer,
            RANGE_LOWER_TICK,
            RANGE_HIGHER_TICK,
            std::u64::max_value!(),
            QUANTITY,
            true,
            LEVERAGE_TWO_X,
            test_world::clock(&resources),
            test_world::ctx(&mut world),
        );
        let probability = quote.entry_probability();
        let entry_value = independent_floor_mul(probability, QUANTITY);
        let premium = independent_floor_div(entry_value, LEVERAGE_TWO_X);
        assert_eq!(quote.net_premium(), premium);
        assert_eq!(quote.trading_fee(), EXPECTED_FEE);
        assert_eq!(quote.penalty_fee(), 0);
        assert_eq!(quote.builder_fee(), 0);
        assert_eq!(quote.fee_incentive_subsidy(), 0);
        assert_eq!(quote.all_in_cost(), premium + EXPECTED_FEE);

        let balance_before = wrapper
            .load_account()
            .balance<DUSDC>(&root, test_world::clock(&resources));
        let cash_before = market.cash_balance();
        let auth = account::generate_auth(test_world::ctx(&mut world));
        let order_id = market.mint_exact_quantity(
            &mut wrapper,
            auth,
            &config,
            &pricer,
            RANGE_LOWER_TICK,
            RANGE_HIGHER_TICK,
            QUANTITY,
            LEVERAGE_TWO_X,
            std::u64::max_value!(),
            std::u64::max_value!(),
            &root,
            test_world::clock(&resources),
            test_world::ctx(&mut world),
        );
        let balance_after_mint = wrapper
            .load_account()
            .balance<DUSDC>(&root, test_world::clock(&resources));
        assert_eq!(balance_before - balance_after_mint, premium + EXPECTED_FEE);
        assert_eq!(market.cash_balance() - cash_before, premium + EXPECTED_FEE);

        // Immediate full close at the same surface: gross recomputes to the
        // same E, the floor cancels by identity, and the trader receives
        // exactly the premium back minus the close fee. The clock advances one
        // millisecond past the mint to clear the same-timestamp redeem guard.
        test_world::clock_mut(&mut resources).set_for_testing(
            test_values::now_ms() + profile_index + 1,
        );
        let auth = account::generate_auth(test_world::ctx(&mut world));
        let (_closed_id, replacement) = market.redeem_live(
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
        assert!(replacement.is_none());
        let balance_after_close = wrapper
            .load_account()
            .balance<DUSDC>(&root, test_world::clock(&resources));
        assert_eq!(balance_after_close - balance_after_mint, premium - EXPECTED_FEE);
        assert_eq!(balance_before - balance_after_close, 2 * EXPECTED_FEE);
        assert_eq!(market.cash_balance() - cash_before, 2 * EXPECTED_FEE);

        oracle_setup::return_feeds(feeds);
        return_shared(config);
        return_shared(market);
        return_shared(root);
        return_shared(wrapper);
        profile_index = profile_index + 1;
    };
    assert_eq!(profile_index, pricing_reference_data::profile_count());
    test_world::finish(world, resources);
}

#[test]
fun one_x_close_refunds_entry_value_minus_fee_across_fractional_profiles() {
    let (mut world, mut resources) = test_world::new(
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
    pool_setup::fund_market(
        &mut world,
        &resources,
        &market_handle,
        test_values::pool_capital(),
    );
    test_world::next_tx(&mut world, test_values::alice());
    let account_handle = account_setup::create_funded_account(
        &mut world,
        &resources,
        test_values::trader_deposit(),
    );

    let mut profile_index = 0;
    while (profile_index < pricing_reference_data::profile_count()) {
        test_world::next_tx(&mut world, test_values::admin());
        let profile = pricing_reference_data::profile(profile_index);
        oracle_setup::seed_market_surface(
            &mut world,
            &resources,
            &oracles,
            &market_handle,
            &profile,
            test_values::now_ms(),
        );

        test_world::next_tx(&mut world, test_values::alice());
        let mut wrapper = account_setup::take_account(&world, &account_handle);
        let root = test_world::take_accumulator_root(&world);
        let mut market = market_setup::take_market(&world, &market_handle);
        let config = test_world::take_config(&world);
        let (pricer, feeds) = oracle_setup::load_pricer(
            &world,
            &resources,
            &oracles,
            &market,
            &config,
        );

        // At 1x the premium is the whole entry value (floor 0), so the quote,
        // debit, and refund all pin the same single flooring of P*Q.
        let quote = market.quote_mint(
            &config,
            &pricer,
            RANGE_LOWER_TICK,
            RANGE_HIGHER_TICK,
            std::u64::max_value!(),
            QUANTITY,
            true,
            LEVERAGE_ONE_X,
            test_world::clock(&resources),
            test_world::ctx(&mut world),
        );
        let entry_value = independent_floor_mul(quote.entry_probability(), QUANTITY);
        assert_eq!(quote.net_premium(), entry_value);
        assert_eq!(quote.trading_fee(), EXPECTED_FEE);
        assert_eq!(quote.all_in_cost(), entry_value + EXPECTED_FEE);

        let balance_before = wrapper
            .load_account()
            .balance<DUSDC>(&root, test_world::clock(&resources));
        let cash_before = market.cash_balance();
        let auth = account::generate_auth(test_world::ctx(&mut world));
        let order_id = market.mint_exact_quantity(
            &mut wrapper,
            auth,
            &config,
            &pricer,
            RANGE_LOWER_TICK,
            RANGE_HIGHER_TICK,
            QUANTITY,
            LEVERAGE_ONE_X,
            std::u64::max_value!(),
            std::u64::max_value!(),
            &root,
            test_world::clock(&resources),
            test_world::ctx(&mut world),
        );
        let balance_after_mint = wrapper
            .load_account()
            .balance<DUSDC>(&root, test_world::clock(&resources));
        assert_eq!(balance_before - balance_after_mint, entry_value + EXPECTED_FEE);

        // Clear the same-timestamp redeem guard before the close.
        test_world::clock_mut(&mut resources).set_for_testing(
            test_values::now_ms() + profile_index + 1,
        );
        let auth = account::generate_auth(test_world::ctx(&mut world));
        let (_closed_id, replacement) = market.redeem_live(
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
        assert!(replacement.is_none());
        let balance_after_close = wrapper
            .load_account()
            .balance<DUSDC>(&root, test_world::clock(&resources));
        assert_eq!(balance_after_close - balance_after_mint, entry_value - EXPECTED_FEE);
        assert_eq!(market.cash_balance() - cash_before, 2 * EXPECTED_FEE);

        oracle_setup::return_feeds(feeds);
        return_shared(config);
        return_shared(market);
        return_shared(root);
        return_shared(wrapper);
        profile_index = profile_index + 1;
    };
    assert_eq!(profile_index, pricing_reference_data::profile_count());
    test_world::finish(world, resources);
}
