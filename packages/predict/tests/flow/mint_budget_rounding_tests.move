// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Budget-bias sizing at rounding-lossy fractional probabilities (RP-13).
/// The search probes `floor(P*q/L)` (one flooring) while the committed premium
/// is `floor(floor(P*q/1e9)*1e9/L)` (two floorings), so the probe can only
/// overstate: fills never exceed the budget, and when the double flooring
/// loses an atom the search undershoots the largest affordable order by
/// exactly one lot — RP-13's registered one-lot-conservative edge, pinned here
/// with budgets derived independently from the contract's admitted
/// probability. The edge needs a NON-INTEGER leverage multiple: at integer
/// multiples the nested-floor identity floor(floor(X/1e9)/n) == floor(X/n·1e9)
/// makes probe and committed premium bit-identical, so no atom is ever lost.
#[test_only]
module deepbook_predict::scope_flow__intent_rounding__mint_budget_tests;

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

// Range (100, 110] prices mid-band on all three reference profiles.
const RANGE_LOWER_TICK: u64 = 100;
const RANGE_HIGHER_TICK: u64 = 110;
// Quantity used only to read the admitted probability from an exact quote.
const PROBE_QUANTITY: u64 = 20_000_000;
// 1.5x: a fractional leverage multiple, so the committed premium's second
// flooring can drop below the probe (impossible at 2x by the nested-floor
// identity).
const LEVERAGE_ONE_POINT_FIVE_X: u64 = 1_500_000_000;
const LOT: u64 = 10_000; // constants::position_lot_size
// The edge scan starts at k = 1_000 lots (well above the min-premium floor)
// and must find a lossy lot count within the span; the profile data is fixed,
// so the hit is deterministic.
const SCAN_START_LOTS: u64 = 1_000;
const SCAN_SPAN_LOTS: u64 = 200;
// Min-fee rate 0.5% at 1e9 scale, spelled locally for the independent fee.
const MIN_FEE_RATE: u64 = 5_000_000;
// 1e9 fixed-point scale, spelled locally so the expected-value arithmetic
// shares no code with the contract's math helpers.
const FLOAT_SCALING: u128 = 1_000_000_000;

/// Independent spelling of the search probe: floor(p * q / leverage).
fun independent_probe(p: u64, q: u64, leverage: u64): u64 {
    (((p as u128) * (q as u128)) / (leverage as u128)) as u64
}

/// Independent spelling of the committed premium: the mint tuple's two
/// floorings, floor(floor(p * q / 1e9) * 1e9 / leverage).
fun independent_committed_premium(p: u64, q: u64, leverage: u64): u64 {
    let entry_value = ((p as u128) * (q as u128)) / FLOAT_SCALING;
    ((entry_value * FLOAT_SCALING) / (leverage as u128)) as u64
}

/// Independent spelling of the min-fee floor: floor(rate * q / 1e9).
fun independent_min_fee(q: u64): u64 {
    (((MIN_FEE_RATE as u128) * (q as u128)) / FLOAT_SCALING) as u64
}

/// Find the first lot count at or above the scan start whose committed premium
/// loses an atom to the probe — the deterministic edge target for this
/// profile's admitted probability.
fun find_edge_lots(p: u64, leverage: u64): u64 {
    let mut lots = SCAN_START_LOTS;
    while (lots < SCAN_START_LOTS + SCAN_SPAN_LOTS) {
        let q = lots * LOT;
        if (independent_committed_premium(p, q, leverage) < independent_probe(p, q, leverage)) {
            return lots
        };
        lots = lots + 1;
    };
    abort 999
}

#[test]
fun budget_probe_never_overfills_and_undershoots_at_most_one_lot() {
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

        // Read the admitted probability from an exact-quantity quote; the
        // probability does not depend on quantity.
        let probe_quote = market.quote_mint(
            &config,
            &pricer,
            RANGE_LOWER_TICK,
            RANGE_HIGHER_TICK,
            std::u64::max_value!(),
            PROBE_QUANTITY,
            true,
            LEVERAGE_ONE_POINT_FIVE_X,
            test_world::clock(&resources),
            test_world::ctx(&mut world),
        );
        let probability = probe_quote.entry_probability();

        // The scanned edge target: its committed premium is strictly below
        // its probe. One atom under the probe both rejects the target lot in
        // the search AND still affords it at commitment — the registered
        // one-lot-conservative undershoot, deterministic on every profile.
        let target_lots = find_edge_lots(probability, LEVERAGE_ONE_POINT_FIVE_X);
        let target_quantity = target_lots * LOT;
        let budget = independent_probe(probability, target_quantity, LEVERAGE_ONE_POINT_FIVE_X) - 1;
        assert!(
            independent_committed_premium(
                probability,
                target_quantity,
                LEVERAGE_ONE_POINT_FIVE_X,
            ) <= budget,
        );
        let expected_quantity = (target_lots - 1) * LOT;
        let expected_premium = independent_committed_premium(
            probability,
            expected_quantity,
            LEVERAGE_ONE_POINT_FIVE_X,
        );
        let expected_fee = independent_min_fee(expected_quantity);

        let quote = market.quote_mint(
            &config,
            &pricer,
            RANGE_LOWER_TICK,
            RANGE_HIGHER_TICK,
            budget,
            LOT,
            false,
            LEVERAGE_ONE_POINT_FIVE_X,
            test_world::clock(&resources),
            test_world::ctx(&mut world),
        );
        assert_eq!(quote.quantity(), expected_quantity);
        assert_eq!(quote.net_premium(), expected_premium);
        assert!(quote.net_premium() <= budget);
        assert_eq!(quote.trading_fee(), expected_fee);
        assert_eq!(quote.penalty_fee(), 0);
        assert_eq!(quote.all_in_cost(), expected_premium + expected_fee);

        // Execute the same budget and pin quote-execution agreement through
        // the account debit.
        let balance_before = wrapper
            .load_account()
            .balance<DUSDC>(&root, test_world::clock(&resources));
        let auth = account::generate_auth(test_world::ctx(&mut world));
        let _order_id = market.mint_exact_amount(
            &mut wrapper,
            auth,
            &config,
            &pricer,
            RANGE_LOWER_TICK,
            RANGE_HIGHER_TICK,
            budget,
            LOT,
            LEVERAGE_ONE_POINT_FIVE_X,
            &root,
            test_world::clock(&resources),
            test_world::ctx(&mut world),
        );
        let balance_after = wrapper
            .load_account()
            .balance<DUSDC>(&root, test_world::clock(&resources));
        assert_eq!(balance_before - balance_after, expected_premium + expected_fee);

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
