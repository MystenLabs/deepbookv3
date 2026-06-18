// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// S1/L1 live-solvency boundary for a thin FINITE-range 1x order: minted on
/// `(min_strike, min_strike + tick]` exactly at the money, then partially closed
/// live. Pins that the close removes the order's entire live terms and reinserts
/// the exact residual (cancel-and-replace) so liability drops to the surviving
/// half, that the survivor carries zero floor (a 1x order), and that custody
/// conserves across the market-cash / account sheets with S1 backing intact.
///
/// The settled-redeem boundary legs are covered by the passive settlement flow
/// tests; this file keeps the live cancel-and-replace solvency boundary focused.
#[test_only]
module deepbook_predict::settled_solvency_boundary_tests;

use deepbook_predict::{flow_test_helpers as helpers, order, test_constants};
use std::unit_test::assert_eq;

/// Per-trade fee floors at `min_fee`: the fixture floors base_fee to 1, so the
/// raw Bernoulli fee mul(1, sqrt(0.5 * 0.5)) rounds to 0 and the floor binds.
/// The default expiry-fee ramp multiplier is exactly 1.0 (ramp disabled).
const MINT_MIN_FEE: u64 = 5_000_000;
/// The order is `(min_strike, min_strike + tick]` and the live forward ==
/// min_strike, so the entry probability is the at-the-money digital
/// Φ(0) = 0.5 exactly (the SVI wing rounds to zero), and up(min_strike + tick)
/// clamps to exactly 0 (|d2| ≈ 315σ, far past the Φ clamp at 8σ).
/// A 1x order fronts its full premium: floor(0.5 * 1e9) = 500_000_000.
const MINT_PRINCIPAL: u64 = 500_000_000;
/// mint_deposit - net_premium - fee = 1e9 - 5e8 - 5e6.
const POST_MINT_BALANCE: u64 = 495_000_000;
/// Half the minted quantity (a whole number of 10_000-unit lots).
const HALF_CLOSE: u64 = 500_000_000;
/// Live close fee on the closed slice: 5e6 * 5e8 / 1e9 (fee basis is the
/// closed quantity, not the original order quantity).
const CLOSE_FEE: u64 = 2_500_000;
/// Partial close at the unchanged ATM mark: gross = floor(0.5 * 5e8)
/// = 250_000_000 minus CLOSE_FEE withheld.
const CLOSE_NET_PAYOUT: u64 = 247_500_000;
/// POST_MINT_BALANCE + CLOSE_NET_PAYOUT.
const POST_CLOSE_BALANCE: u64 = 742_500_000;
/// Rebate reserve = floor(cumulative fees * 0.5 default rebate rate):
/// after the mint floor(5e6 * 0.5), after the close floor(7.5e6 * 0.5).
const REBATE_AFTER_MINT: u64 = 2_500_000;
const REBATE_AFTER_CLOSE: u64 = 3_750_000;

#[test]
fun finite_range_partial_close_preserves_live_solvency() {
    let (mut fx, expiry_id, trader) = helpers::setup_live_market(
        test_constants::short_expiry_ms(),
        test_constants::default_live_price(),
    );
    fx.scenario_mut().next_tx(test_constants::alice());
    let (pyth, bs, oracle_registry, vault, mut market, config) = fx.take_market(expiry_id);
    let mut wrapper = fx.take_account(&trader);
    let root = fx.take_root();

    // --- Baseline: the fixture seeded the fresh expiry with cash while pool
    // funding is absent; nothing owed, nothing spent.
    let seeded_cash = test_constants::default_seeded_expiry_cash();
    helpers::check_market_cash(&market, helpers::expected_market_cash(seeded_cash, 0, 0));
    fx.check_manager(
        &wrapper,
        &root,
        expiry_id,
        helpers::expected_manager_state(test_constants::mint_deposit(), 0, 0, 0, 0),
    );
    // --- Mint one 1x order on the finite range (min_strike, min_strike + tick],
    // exactly at the money. Principal + fee land in expiry cash; live backing
    // for a zero-floor 1x order is its full quantity.
    let order_id = fx.mint(
        &config,
        &oracle_registry,
        &mut wrapper,
        &root,
        &mut market,
        &pyth,
        &bs,
        helpers::strike_tick(),
        helpers::strike_tick() + 1,
        test_constants::mint_quantity(),
        test_constants::leverage_one_x(),
    );
    helpers::check_market_cash(
        &market,
        helpers::expected_market_cash(
            seeded_cash + MINT_PRINCIPAL + MINT_MIN_FEE,
            test_constants::mint_quantity(),
            REBATE_AFTER_MINT,
        ),
    );
    fx.check_manager(
        &wrapper,
        &root,
        expiry_id,
        helpers::expected_manager_state(POST_MINT_BALANCE, MINT_MIN_FEE, 1, 0, 0),
    );
    assert!(helpers::has_position(&wrapper, expiry_id, order_id));

    // --- Partial live close of exactly half at the unchanged ATM mark. The
    // close removes the order's entire live terms and reinserts the exact
    // residual (cancel-and-replace), so liability drops to the surviving half.
    let (_closed, replacement) = fx.redeem(
        &config,
        &oracle_registry,
        &mut wrapper,
        &root,
        &mut market,
        &pyth,
        &bs,
        order_id,
        HALF_CLOSE,
    );
    let survivor_id = replacement.destroy_some();
    let survivor = order::from_order_id(survivor_id);
    assert_eq!(survivor.quantity(), HALF_CLOSE);
    assert_eq!(survivor.floor_shares(), 0);
    let cash_after_close = seeded_cash + MINT_PRINCIPAL + MINT_MIN_FEE - CLOSE_NET_PAYOUT;
    helpers::check_market_cash(
        &market,
        helpers::expected_market_cash(cash_after_close, HALF_CLOSE, REBATE_AFTER_CLOSE),
    );
    fx.check_manager(
        &wrapper,
        &root,
        expiry_id,
        helpers::expected_manager_state(POST_CLOSE_BALANCE, MINT_MIN_FEE + CLOSE_FEE, 1, 0, 0),
    );
    assert!(!helpers::has_position(&wrapper, expiry_id, order_id));
    assert!(helpers::has_position(&wrapper, expiry_id, survivor_id));

    helpers::return_account(wrapper, root);

    helpers::return_market(pyth, bs, oracle_registry, vault, market, config);
    fx.finish();
}
