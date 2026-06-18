// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// P0-7 liquidation threshold boundary at the flow level, with a genuinely
/// non-flat floor schedule made bit-exact by construction: the expiry sits
/// exactly half the leverage floor window out (floor phase 0.5 at mint, 0.6 at
/// the check time), so every floor-index intermediate is exact under any
/// round-down composition. Pins both sides of the threshold (a clearly-solvent
/// order is left untouched and stays closable at its spec value; a worthless
/// order liquidates), that a failed attempt and a budget-0 budgeted pass are
/// pure no-ops, and the zero-pay tombstone cleanup. The exact boundary unit is
/// implementation-defined (the price→probability map is a step function under
/// the degenerate test SVI), so the two sides use a safe gap: p = 0.5 exactly
/// (gross 420e6 ≫ threshold 252_235_294) vs p = 0 (gross 0).
#[test_only]
module deepbook_predict::liquidation_boundary_tests;

use deepbook_predict::{constants, flow_test_helpers as helpers, test_constants};
use std::unit_test::assert_eq;

/// now (120_000) + leverage_floor_window_ms / 2: floor phase at mint is
/// exactly 0.5, so floor_index(open) = 1 + 0.2 * 0.5² = 1.05 exactly.
/// Grid-aligned (`now` + a multiple of the resolution period).
const EXPIRY_MS: u64 = 15_768_120_000;
/// Check time T1 = EXPIRY_MS − 0.4 * window: floor phase exactly 0.6, so
/// floor_index(T1) = 1 + 0.2 * 0.6² = 1.072 exactly — the schedule is
/// genuinely live between mint and check (1.05 → 1.072).
const T1_MS: u64 = 3_153_720_000;
/// Oracle re-seed source timestamps: strictly after the setup's 119_000 seed
/// and within every freshness window of the T1 clock.
const T1_ATM_SOURCE_TS: u64 = 3_153_719_500;
const T1_DROP_SOURCE_TS: u64 = 3_153_719_700;
const LEVERAGE_TWO_X: u64 = 2_000_000_000;
/// 84_000 lots, chosen so floor_shares = financed_amount / 1.05 = 200_000_000 is an
/// EXACT division (no dependence on the floor_shares rounding direction).
const QUANTITY: u64 = 840_000_000;
/// entry_value = floor(0.5 * 840e6) = 420_000_000 (ATM digital p = 0.5 exactly);
/// net_premium = floor(entry_value / 2x) = 210_000_000.
const CONTRIBUTION: u64 = 210_000_000;
/// Per-unit fee RATE floors at min_fee = 5e6 (fixture base_fee = 1):
/// trade fee = floor(5e6 * 840e6 / 1e9) per mint/redeem of this quantity.
const TRADE_FEE: u64 = 4_200_000;
/// mint_deposit − 2 * (net_premium + fee).
const POST_MINT_BALANCE: u64 = 571_600_000;
/// floor_at_open = floor(200_000_000 * 1.05e9 / 1e9) = 210_000_000 exact;
/// live backing per order = quantity − floor_at_open.
const LIVE_BACKING_PER_ORDER: u64 = 630_000_000;
/// floor(cumulative fees * 0.5 default rebate rate): 2 mints, then + redeem.
const REBATE_AFTER_MINTS: u64 = 4_200_000;
const REBATE_AFTER_REDEEM: u64 = 6_300_000;
/// Full live redeem of one order at T1: gross = floor(0.5 * 840e6)
/// = 420_000_000; removed floor = floor(200e6 * 1.072e9 / 1e9) = 214_400_000
/// exact (> the 210e6 seed — the ramp is live); redeem = 420e6 − 214.4e6
/// = 205_600_000; net of the withheld TRADE_FEE = 201_400_000.
const REDEEM_NET_PAYOUT: u64 = 201_400_000;
/// One grid tick below the orders' lower strike: the digital steps to p = 0,
/// gross = 0 <= threshold floor(214_400_000 * 1e9 / 0.85e9) = 252_235_294.
const DROPPED_SPOT: u64 = 99_000_000_000;

#[test]
fun liquidation_fires_only_below_threshold_and_is_otherwise_a_noop() {
    let (mut fx, expiry_id, trader) = helpers::setup_live_market(
        EXPIRY_MS,
        test_constants::default_live_price(),
    );
    fx.scenario_mut().next_tx(test_constants::alice());
    let (mut pyth, mut bs, oracle_registry, vault, mut market, config) = fx.take_market(expiry_id);
    let mut wrapper = fx.take_account(&trader);
    let root = fx.take_root();

    // --- Baseline.
    let seeded_cash = test_constants::default_seeded_expiry_cash();
    helpers::check_market_cash(&market, helpers::expected_market_cash(seeded_cash, 0, 0));
    fx.check_manager(
        &wrapper,
        &root,
        expiry_id,
        helpers::expected_manager_state(test_constants::mint_deposit(), 0, 0, 0, 0),
    );

    // --- Two identical 2x semi-infinite orders.
    let order_a = fx.mint(
        &config,
        &oracle_registry,
        &mut wrapper,
        &root,
        &mut market,
        &pyth,
        &bs,
        helpers::strike_tick(),
        constants::pos_inf_tick!(),
        QUANTITY,
        LEVERAGE_TWO_X,
    );
    let order_b = fx.mint(
        &config,
        &oracle_registry,
        &mut wrapper,
        &root,
        &mut market,
        &pyth,
        &bs,
        helpers::strike_tick(),
        constants::pos_inf_tick!(),
        QUANTITY,
        LEVERAGE_TWO_X,
    );
    let cash_after_mints = seeded_cash + 2 * (CONTRIBUTION + TRADE_FEE);
    helpers::check_market_cash(
        &market,
        helpers::expected_market_cash(
            cash_after_mints,
            2 * LIVE_BACKING_PER_ORDER,
            REBATE_AFTER_MINTS,
        ),
    );
    fx.check_manager(
        &wrapper,
        &root,
        expiry_id,
        helpers::expected_manager_state(POST_MINT_BALANCE, 2 * TRADE_FEE, 2, 0, 0),
    );

    // --- Advance to T1 and re-seed the oracle at the same ATM price. Both
    // orders are clearly solvent (gross 420e6 > threshold 252_235_294): a
    // failed liquidation attempt must be a pure no-op.
    fx.set_clock_for_testing(T1_MS);
    fx.prepare_live_oracle_at(
        &market,
        &mut pyth,
        &mut bs,
        test_constants::default_live_price(),
        T1_ATM_SOURCE_TS,
    );
    assert!(!fx.liquidate_order(&config, &oracle_registry, &mut market, &pyth, &bs, order_a));
    assert!(!fx.liquidate_order(&config, &oracle_registry, &mut market, &pyth, &bs, order_b));
    helpers::check_market_cash(
        &market,
        helpers::expected_market_cash(
            cash_after_mints,
            2 * LIVE_BACKING_PER_ORDER,
            REBATE_AFTER_MINTS,
        ),
    );
    fx.check_manager(
        &wrapper,
        &root,
        expiry_id,
        helpers::expected_manager_state(POST_MINT_BALANCE, 2 * TRADE_FEE, 2, 0, 0),
    );
    assert!(helpers::has_position(&wrapper, expiry_id, order_a));

    // --- L1 liveness: the not-liquidatable order closes at its spec value
    // (gross minus the LIVE floor at T1, minus the withheld fee).
    let (_closed, replacement) = fx.redeem(
        &config,
        &oracle_registry,
        &mut wrapper,
        &root,
        &mut market,
        &pyth,
        &bs,
        order_a,
        QUANTITY,
    );
    assert!(replacement.is_none());
    let cash_after_redeem = cash_after_mints - REDEEM_NET_PAYOUT;
    helpers::check_market_cash(
        &market,
        helpers::expected_market_cash(
            cash_after_redeem,
            LIVE_BACKING_PER_ORDER,
            REBATE_AFTER_REDEEM,
        ),
    );
    fx.check_manager(
        &wrapper,
        &root,
        expiry_id,
        helpers::expected_manager_state(
            POST_MINT_BALANCE + REDEEM_NET_PAYOUT,
            3 * TRADE_FEE,
            1,
            0,
            0,
        ),
    );
    assert!(!helpers::has_position(&wrapper, expiry_id, order_a));

    // --- Drop the forward one tick below the lower strike (pyth-only update;
    // basis stays 1.0). order_b is now liquidatable, but a budget-0 budgeted
    // pass selects zero candidates and must change nothing.
    fx.set_pyth_price_for_testing(&mut pyth, DROPPED_SPOT, T1_DROP_SOURCE_TS);
    assert_eq!(fx.liquidate(&config, &oracle_registry, &mut market, &pyth, &bs, 0), 0);
    helpers::check_market_cash(
        &market,
        helpers::expected_market_cash(
            cash_after_redeem,
            LIVE_BACKING_PER_ORDER,
            REBATE_AFTER_REDEEM,
        ),
    );
    fx.check_manager(
        &wrapper,
        &root,
        expiry_id,
        helpers::expected_manager_state(
            POST_MINT_BALANCE + REDEEM_NET_PAYOUT,
            3 * TRADE_FEE,
            1,
            0,
            0,
        ),
    );

    // --- Targeted liquidation below the threshold: the knockout removes the
    // order's full backing, moves no cash, and never touches the manager.
    assert!(fx.liquidate_order(&config, &oracle_registry, &mut market, &pyth, &bs, order_b));
    helpers::check_market_cash(
        &market,
        helpers::expected_market_cash(cash_after_redeem, 0, REBATE_AFTER_REDEEM),
    );
    fx.check_manager(
        &wrapper,
        &root,
        expiry_id,
        helpers::expected_manager_state(
            POST_MINT_BALANCE + REDEEM_NET_PAYOUT,
            3 * TRADE_FEE,
            1,
            0,
            0,
        ),
    );
    assert!(helpers::has_position(&wrapper, expiry_id, order_b));

    // --- Tombstone cleanup: zero payout, zero fee, position cleared.
    let (_closed_b, repl_b) = fx.redeem(
        &config,
        &oracle_registry,
        &mut wrapper,
        &root,
        &mut market,
        &pyth,
        &bs,
        order_b,
        QUANTITY,
    );
    assert!(repl_b.is_none());
    fx.check_manager(
        &wrapper,
        &root,
        expiry_id,
        helpers::expected_manager_state(
            POST_MINT_BALANCE + REDEEM_NET_PAYOUT,
            3 * TRADE_FEE,
            0,
            0,
            0,
        ),
    );
    helpers::check_market_cash(
        &market,
        helpers::expected_market_cash(cash_after_redeem, 0, REBATE_AFTER_REDEEM),
    );
    assert!(!helpers::has_position(&wrapper, expiry_id, order_b));

    helpers::return_account(wrapper, root);

    helpers::return_market(pyth, bs, oracle_registry, vault, market, config);
    fx.finish();
}
