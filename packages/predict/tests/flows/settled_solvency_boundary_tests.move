// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// S3/L1 settled-solvency flow: a finite-range 1x order is partially closed
/// live, then settled exactly AT each boundary of its half-open range
/// `(lower, higher]`. Pins that the settled payout reserve drains to exactly
/// zero (no residual, no underflow), that a worthless settled survivor is
/// still closable (a zero-payout permissionless close must not abort), and
/// that custody conserves across the full market-cash / pool / manager sheets
/// at every step. One parameterized runner, three boundary rows.
#[test_only]
module deepbook_predict::settled_solvency_boundary_tests;

use deepbook_predict::{constants, flow_test_helpers as helpers, order, test_constants};
use std::unit_test::{assert_eq, destroy};

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

/// `(lower, higher]` INCLUDES higher: settling exactly at `higher` pays the
/// surviving half its full notional, and the reserve drains to exactly zero.
#[test]
fun settlement_at_higher_boundary_pays_full() {
    run_boundary_settlement(
        helpers::min_strike() + test_constants::default_tick_size(),
        HALF_CLOSE,
    );
}

/// `(lower, higher]` EXCLUDES lower: settling exactly at `lower` pays zero,
/// and the worthless settled survivor still closes without aborting.
#[test]
fun settlement_at_lower_boundary_pays_zero() {
    run_boundary_settlement(helpers::min_strike(), 0);
}

/// Settlement strictly above `higher` pays zero (the strict > side of the
/// half-open interval).
#[test]
fun settlement_above_higher_pays_zero() {
    run_boundary_settlement(
        helpers::min_strike() + 2 * test_constants::default_tick_size(),
        0,
    );
}

fun run_boundary_settlement(settlement_price: u64, expected_settled_payout: u64) {
    let (mut fx, expiry_id, oracle_id, mut manager) = helpers::setup_live_market(
        test_constants::short_expiry_ms(),
        test_constants::default_live_price(),
    );
    fx.scenario_mut().next_tx(test_constants::alice());
    let (mut pyth, vault, mut market, mut oracle, config) = fx.take_market(expiry_id, oracle_id);

    // --- Post-funding-sync baseline: the pool topped the fresh expiry up to
    // the cash floor out of idle; nothing owed, nothing spent.
    let cash_floor = constants::expiry_cash_floor!();
    let idle = test_constants::default_initial_supply() - cash_floor;
    helpers::check_market_cash(&market, helpers::expected_market_cash(cash_floor, 0, 0));
    helpers::check_pool(
        &vault,
        helpers::expected_pool_state(idle, test_constants::default_initial_supply(), 0),
    );
    helpers::check_manager(
        &manager,
        expiry_id,
        helpers::expected_manager_state(test_constants::mint_deposit(), 0, 0, 0, 0),
    );
    assert!(!oracle.is_settled());

    // --- Mint one 1x order on the finite range (min_strike, min_strike + tick],
    // exactly at the money. Principal + fee land in expiry cash; live backing
    // for a zero-floor 1x order is its full quantity.
    let higher = helpers::min_strike() + test_constants::default_tick_size();
    let order_id = fx.mint(
        &config,
        &mut manager,
        &mut market,
        &oracle,
        &pyth,
        helpers::min_strike(),
        higher,
        test_constants::mint_quantity(),
        test_constants::leverage_one_x(),
    );
    helpers::check_market_cash(
        &market,
        helpers::expected_market_cash(
            cash_floor + MINT_PRINCIPAL + MINT_MIN_FEE,
            test_constants::mint_quantity(),
            REBATE_AFTER_MINT,
        ),
    );
    helpers::check_manager(
        &manager,
        expiry_id,
        helpers::expected_manager_state(POST_MINT_BALANCE, MINT_MIN_FEE, 1, 0, 0),
    );
    assert!(manager.has_position(expiry_id, order_id));

    // --- Partial live close of exactly half at the unchanged ATM mark. The
    // close removes the order's entire live terms and reinserts the exact
    // residual (cancel-and-replace), so liability drops to the surviving half.
    let (_closed, replacement) = fx.redeem(
        &config,
        &mut manager,
        &mut market,
        &oracle,
        &pyth,
        order_id,
        HALF_CLOSE,
    );
    let survivor_id = replacement.destroy_some();
    let survivor = order::from_order_id(survivor_id);
    assert_eq!(survivor.quantity(), HALF_CLOSE);
    assert_eq!(survivor.floor_shares(), 0);
    let cash_after_close = cash_floor + MINT_PRINCIPAL + MINT_MIN_FEE - CLOSE_NET_PAYOUT;
    helpers::check_market_cash(
        &market,
        helpers::expected_market_cash(cash_after_close, HALF_CLOSE, REBATE_AFTER_CLOSE),
    );
    helpers::check_manager(
        &manager,
        expiry_id,
        helpers::expected_manager_state(POST_CLOSE_BALANCE, MINT_MIN_FEE + CLOSE_FEE, 1, 0, 0),
    );
    assert!(!manager.has_position(expiry_id, order_id));
    assert!(manager.has_position(expiry_id, survivor_id));

    // --- Settle at the row's boundary price. Settlement is an oracle-domain
    // write: the market cash sheet must be bit-identical to the pre-settle
    // state, and the liability getter still reports the lazy (un-materialized)
    // live reserve until the first settled redeem.
    fx.settle_oracle(&config, &mut oracle, &mut pyth, settlement_price);
    assert!(oracle.is_settled());
    helpers::check_market_cash(
        &market,
        helpers::expected_market_cash(cash_after_close, HALF_CLOSE, REBATE_AFTER_CLOSE),
    );

    // --- Permissionless full close of the survivor. Settled redeem pays the
    // exact terminal payout with no per-trade fee, and the materialized
    // settled reserve drains to exactly zero — no residual, no underflow.
    let balance_before = manager.balance();
    fx.redeem_settled(
        &config,
        &mut manager,
        &mut market,
        &oracle,
        &pyth,
        survivor_id,
        HALF_CLOSE,
    );
    assert_eq!(manager.balance() - balance_before, expected_settled_payout);
    assert_eq!(market.payout_liability(), 0);
    helpers::check_market_cash(
        &market,
        helpers::expected_market_cash(
            cash_after_close - expected_settled_payout,
            0,
            REBATE_AFTER_CLOSE,
        ),
    );
    helpers::check_manager(
        &manager,
        expiry_id,
        helpers::expected_manager_state(
            POST_CLOSE_BALANCE + expected_settled_payout,
            MINT_MIN_FEE + CLOSE_FEE,
            0,
            0,
            0,
        ),
    );
    assert!(!manager.has_position(expiry_id, survivor_id));
    // The pool sheet is untouched by the whole trade lifecycle.
    helpers::check_pool(
        &vault,
        helpers::expected_pool_state(idle, test_constants::default_initial_supply(), 0),
    );

    helpers::return_market(pyth, vault, market, oracle, config);
    destroy(manager);
    fx.finish();
}
