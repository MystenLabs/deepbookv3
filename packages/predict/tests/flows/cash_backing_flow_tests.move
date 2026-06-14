// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// S1/S2 expiry-cash sheet: asserts the exact (cash_balance, payout_liability,
/// rebate_reserve) triple after EVERY cash-mutating operation of a two-sided
/// 1x book on the far expiry — mint, mint, partial live redeem, settlement,
/// winner settled redeem, loser settled redeem. Pins that mint net_premium AND
/// fee land in expiry cash, that disjoint live liability is the max settlement
/// floor plus the default gap buffer, that settlement itself is an oracle-only
/// transition (cash sheet bit-identical, liability getter still reports the
/// lazy un-materialized live reserve), and that the materialized terminal
/// reserve drains to exactly zero with the loser paying nothing.
#[test_only]
module deepbook_predict::cash_backing_flow_tests;

use deepbook_predict::{config_constants, constants, flow_test_helpers as helpers, test_constants};
use fixed_math::math;
use std::unit_test::destroy;

/// Both mints quote the exact ATM digital: forward == min_strike, so
/// UP(min_strike) = Φ(0) = 0.5 exactly (the SVI wing rounds to zero), and the
/// complement range prices via the UP(neg_inf) = 1.0 sentinel: 1.0 - 0.5 = 0.5.
/// 1x premium = floor(0.5 * quantity).
const MINT1_PRINCIPAL: u64 = 500_000_000;
/// Second order: 1x DOWN complement (-inf, min_strike], quantity 2e9.
const DOWN_QUANTITY: u64 = 2_000_000_000;
const MINT2_PRINCIPAL: u64 = 1_000_000_000;
/// Fees floor at min_fee = 5e6 per 1e9 of quantity (fixture base_fee = 1 makes
/// the raw Bernoulli fee round to 0; the default ramp multiplier is exactly 1.0).
const MINT1_FEE: u64 = 5_000_000;
const MINT2_FEE: u64 = 10_000_000;
/// Partial live close of half of order 1 at the unchanged ATM mark:
/// gross = floor(0.5 * 5e8) = 250_000_000; fee on the closed quantity = 2_500_000.
const HALF_CLOSE: u64 = 500_000_000;
const CLOSE_FEE: u64 = 2_500_000;
const CLOSE_NET_PAYOUT: u64 = 247_500_000;
/// Rebate reserve = floor(cumulative fee basis * 0.5 default rebate rate).
const REBATE_AFTER_MINT1: u64 = 2_500_000;
const REBATE_AFTER_MINT2: u64 = 7_500_000;
const REBATE_AFTER_CLOSE: u64 = 8_750_000;
/// ITM for order 1's range (110e9 > lower 100e9), OTM for order 2
/// (110e9 > higher 100e9 pays zero).
const SETTLEMENT_ITM: u64 = 110_000_000_000;

#[test]
fun cash_sheet_exact_after_every_flow() {
    let (mut fx, expiry_id, oracle_id, mut manager) = helpers::setup_everything();
    fx.scenario_mut().next_tx(test_constants::alice());
    let (mut pyth, vault, mut market, mut oracle, config) = fx.take_market(expiry_id, oracle_id);

    // --- Baseline: the fixture seeded the fresh expiry with cash while pool
    // funding is absent.
    let seeded_cash = test_constants::default_seeded_expiry_cash();
    let deposit = test_constants::default_manager_deposit();
    helpers::check_market_cash(&market, helpers::expected_market_cash(seeded_cash, 0, 0));
    helpers::check_manager(
        &manager,
        expiry_id,
        helpers::expected_manager_state(deposit, 0, 0, 0, 0),
    );

    // --- Mint 1: 1x ATM UP range (min_strike, +inf], quantity 1e9. Principal
    // and fee both land in expiry cash; backing for a zero-floor 1x order is
    // its full quantity.
    let order1 = fx.mint(
        &config,
        &mut manager,
        &mut market,
        &oracle,
        &pyth,
        helpers::min_strike(),
        constants::pos_inf!(),
        test_constants::mint_quantity(),
        test_constants::leverage_one_x(),
    );
    helpers::check_market_cash(
        &market,
        helpers::expected_market_cash(
            seeded_cash + MINT1_PRINCIPAL + MINT1_FEE,
            test_constants::mint_quantity(),
            REBATE_AFTER_MINT1,
        ),
    );
    helpers::check_manager(
        &manager,
        expiry_id,
        helpers::expected_manager_state(
            deposit - MINT1_PRINCIPAL - MINT1_FEE,
            MINT1_FEE,
            1,
            0,
            0,
        ),
    );

    // --- Mint 2: 1x DOWN complement (-inf, min_strike], quantity 2e9.
    // The two ranges are disjoint: M = max(1e9, 2e9) = 2e9, Σ = 3e9,
    // gap = 1e9, default buffer = 250e6, reserve = 2.25e9.
    let order2 = fx.mint(
        &config,
        &mut manager,
        &mut market,
        &oracle,
        &pyth,
        constants::neg_inf!(),
        helpers::min_strike(),
        DOWN_QUANTITY,
        test_constants::leverage_one_x(),
    );
    let cash_after_mints =
        seeded_cash
        + MINT1_PRINCIPAL
        + MINT1_FEE
        + MINT2_PRINCIPAL
        + MINT2_FEE;
    helpers::check_market_cash(
        &market,
        helpers::expected_market_cash(
            cash_after_mints,
            DOWN_QUANTITY + default_gap_buffer(test_constants::mint_quantity()),
            REBATE_AFTER_MINT2,
        ),
    );
    let balance_after_mints = deposit - MINT1_PRINCIPAL - MINT1_FEE - MINT2_PRINCIPAL - MINT2_FEE;
    helpers::check_manager(
        &manager,
        expiry_id,
        helpers::expected_manager_state(
            balance_after_mints,
            MINT1_FEE + MINT2_FEE,
            2,
            0,
            0,
        ),
    );

    // --- Partial live close of half of order 1 at the unchanged ATM quote.
    // Cash pays only the net redeem (the fee is withheld in expiry cash and
    // grows the rebate basis); cancel-and-replace leaves M = 2e9 and gap =
    // surviving UP backing 0.5e9, so default reserve = 2.125e9. The
    // replacement keeps the position count at 2.
    let (_closed_id, replacement) = fx.redeem(
        &config,
        &mut manager,
        &mut market,
        &oracle,
        &pyth,
        order1,
        HALF_CLOSE,
    );
    let order1b = replacement.destroy_some();
    let cash_after_close = cash_after_mints - CLOSE_NET_PAYOUT;
    let liability_after_close = DOWN_QUANTITY + default_gap_buffer(HALF_CLOSE);
    helpers::check_market_cash(
        &market,
        helpers::expected_market_cash(
            cash_after_close,
            liability_after_close,
            REBATE_AFTER_CLOSE,
        ),
    );
    let balance_after_close = balance_after_mints + CLOSE_NET_PAYOUT;
    helpers::check_manager(
        &manager,
        expiry_id,
        helpers::expected_manager_state(
            balance_after_close,
            MINT1_FEE + MINT2_FEE + CLOSE_FEE,
            2,
            0,
            0,
        ),
    );
    assert!(manager.has_position(expiry_id, order1b));

    // --- Settle ITM for order 1, OTM for order 2. Settlement is an
    // oracle-domain write (settle_oracle takes no market argument): the expiry
    // cash sheet must be bit-identical, and the liability getter still reports
    // the lazy un-materialized live reserve.
    fx.settle_oracle(&config, &mut oracle, &mut pyth, SETTLEMENT_ITM);
    helpers::check_market_cash(
        &market,
        helpers::expected_market_cash(
            cash_after_close,
            liability_after_close,
            REBATE_AFTER_CLOSE,
        ),
    );

    // --- Winner settled redeem: the first settled redeem materializes the
    // exact terminal liability for the whole book (only the surviving half of
    // order 1 wins), then pays the survivor its full notional with no fee —
    // the reserve drains to exactly zero.
    fx.redeem_settled(&config, &mut manager, &mut market, &oracle, &pyth, order1b, HALF_CLOSE);
    helpers::check_market_cash(
        &market,
        helpers::expected_market_cash(
            cash_after_close - HALF_CLOSE,
            0,
            REBATE_AFTER_CLOSE,
        ),
    );
    helpers::check_manager(
        &manager,
        expiry_id,
        helpers::expected_manager_state(
            balance_after_close + HALF_CLOSE,
            MINT1_FEE + MINT2_FEE + CLOSE_FEE,
            1,
            0,
            0,
        ),
    );
    assert!(!manager.has_position(expiry_id, order1b));

    // --- Loser settled redeem: pays zero, cash sheet bit-identical, position
    // cleared (a permissionless zero-payout close must not abort). The
    // trader's lost premium stays in expiry cash as LP-side surplus.
    fx.redeem_settled(&config, &mut manager, &mut market, &oracle, &pyth, order2, DOWN_QUANTITY);
    helpers::check_market_cash(
        &market,
        helpers::expected_market_cash(
            cash_after_close - HALF_CLOSE,
            0,
            REBATE_AFTER_CLOSE,
        ),
    );
    helpers::check_manager(
        &manager,
        expiry_id,
        helpers::expected_manager_state(
            balance_after_close + HALF_CLOSE,
            MINT1_FEE + MINT2_FEE + CLOSE_FEE,
            0,
            0,
            0,
        ),
    );

    helpers::return_market(pyth, vault, market, oracle, config);
    destroy(manager);
    fx.finish();
}

fun default_gap_buffer(gap: u64): u64 {
    math::mul(config_constants::default_backing_buffer_lambda!(), gap)
}
