// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// The tick-time quote variants resolve prices with: `try_quote_mint_range`,
/// `try_quote_mint_terms` and `try_quote_live_close`. On valid inputs they must
/// return exactly what the aborting `quote_*` functions return; where those
/// abort on a tick-dependent input they return `none` (with refund reason 1 for
/// a size, 2 for anything about the range) instead.
///
/// They price through `pricing::try_range_price`, so they need slice B's
/// implementation to run.
#[test_only]
module deepbook_predict::try_quote_terms_tests;

use deepbook_predict::{
    constants,
    order::{Self, Order},
    pricing::{Self, Pricer},
    strike_exposure::StrikeExposure,
    strike_exposure_config::{Self, StrikeExposureConfig},
    test_constants,
    tick_time_exposure_fixture as fixture
};
use std::unit_test::assert_eq;
use sui::vec_map;

const STRIKE: u64 = 100;
const LOWER_LEG_TICK: u64 = 90;
const HIGHER_LEG_TICK: u64 = 110;
/// Not a multiple of the 10-tick admission grid.
const OFF_GRID_TICK: u64 = 105;
const LAMBDA: u64 = 500_000_000; // 1/2
const IMPACT_RATE: u64 = 200_000_000; // 20%
const IMPACT_SCALE: u64 = 4_000_000_000;
const Q_A: u64 = 3_000_000_000;
const Q_B: u64 = 1_000_000_000;
/// A 1,000 USDC premium budget, about 2e9 contracts at the ATM price.
const BUDGET: u64 = 1_000_000_000;
/// `phi(L) = r * L^2 / (2B)` at `L = 3e9`, `B = 4e9`, `r = 20%`: 15% * 3e9 / 2.
/// A lone order's full close rebates the same amount.
const IMPACT_AT_Q_A: u64 = 225_000_000;
/// A (0, 100] q=3e9 then B (100, +inf] q=1e9 with `lambda = 1/2`:
/// M = 3e9, T = 4e9, liability 3e9 + 1e9 / 2.
const LIABILITY_A_B: u64 = 3_500_000_000;
const REASON_FILL: u8 = 0;
const REASON_LIMITS: u8 = 1;
const REASON_ADMISSION: u8 = 2;

// === try_quote_mint_terms ===

#[test]
fun try_quote_mint_terms_matches_quote_mint_terms_for_an_exact_quantity() {
    let (mut fx, oracle, exposure) = fixture::setup(
        fixture::config(LAMBDA, IMPACT_RATE),
        IMPACT_SCALE,
    );
    let pricer = fx.load_pricer_bundle(&oracle);

    let expected = exposure.quote_mint_terms(&pricer, STRIKE, pos_inf(), 0, Q_A, true);
    let (terms, reason) = exposure.try_quote_mint_terms(&pricer, STRIKE, pos_inf(), 0, Q_A, true);

    assert_eq!(reason, REASON_FILL);
    let terms = terms.destroy_some();
    assert_eq!(terms.quantity(), Q_A);
    assert_eq!(terms.inventory_impact_charge(), IMPACT_AT_Q_A);
    assert_eq!(terms.premium(), expected.premium());
    assert_eq!(terms.entry_probability(), expected.entry_probability());
    assert_eq!(terms.inventory_impact_charge(), expected.inventory_impact_charge());
    fixture::finish(fx, oracle, exposure);
}

#[test]
fun try_quote_mint_terms_matches_quote_mint_terms_for_a_budget() {
    let (mut fx, oracle, exposure) = fixture::setup(
        fixture::config(LAMBDA, IMPACT_RATE),
        IMPACT_SCALE,
    );
    let pricer = fx.load_pricer_bundle(&oracle);

    let expected = exposure.quote_mint_terms(&pricer, STRIKE, pos_inf(), BUDGET, 0, false);
    let (terms, reason) = exposure.try_quote_mint_terms(
        &pricer,
        STRIKE,
        pos_inf(),
        BUDGET,
        0,
        false,
    );

    assert_eq!(reason, REASON_FILL);
    let terms = terms.destroy_some();
    assert_eq!(terms.quantity(), expected.quantity());
    assert_eq!(terms.premium(), expected.premium());
    assert_eq!(terms.inventory_impact_charge(), expected.inventory_impact_charge());
    // The budget binds: the fill spends at most it, and is a whole number of lots.
    assert!(terms.premium() <= BUDGET);
    assert_eq!(terms.quantity() % constants::position_lot_size!(), 0);
    fixture::finish(fx, oracle, exposure);
}

#[test]
fun a_zero_size_reports_limits() {
    let (mut fx, oracle, exposure) = fixture::setup(default_config(), IMPACT_SCALE);
    let pricer = fx.load_pricer_bundle(&oracle);

    // A zero budget sizes to zero lots; an exact quantity of zero is zero.
    let (budget_terms, budget_reason) = exposure.try_quote_mint_terms(
        &pricer,
        STRIKE,
        pos_inf(),
        0,
        0,
        false,
    );
    let (exact_terms, exact_reason) = exposure.try_quote_mint_terms(
        &pricer,
        STRIKE,
        pos_inf(),
        0,
        0,
        true,
    );

    assert!(budget_terms.is_none());
    assert!(exact_terms.is_none());
    assert_eq!(budget_reason, REASON_LIMITS);
    assert_eq!(exact_reason, REASON_LIMITS);
    assert_eq!(budget_reason, constants::fill_reason_limits!());
    fixture::finish(fx, oracle, exposure);
}

#[test]
fun an_out_of_band_range_reports_admission() {
    // Near-zero variance prices a strike 10% from the forward at a digital of
    // essentially 0 or 1.
    let (mut fx, oracle, exposure) = fixture::setup(default_config(), IMPACT_SCALE);
    let pricer = fx.load_pricer_bundle(&oracle);

    // (110, +inf]: the range itself is near 0.
    assert_admission_refund(&exposure, &pricer, HIGHER_LEG_TICK, pos_inf());
    // (90, 100]: the range is near 1/2, but its lower leg is near 1.
    assert_admission_refund(&exposure, &pricer, LOWER_LEG_TICK, STRIKE);
    // (100, 110]: the range is near 1/2, but its upper leg's complement is near 1.
    assert_admission_refund(&exposure, &pricer, STRIKE, HIGHER_LEG_TICK);
    fixture::finish(fx, oracle, exposure);
}

#[test]
fun an_off_grid_tick_reports_admission() {
    let (mut fx, oracle, exposure) = fixture::setup(default_config(), IMPACT_SCALE);
    let pricer = fx.load_pricer_bundle(&oracle);

    assert_admission_refund(&exposure, &pricer, OFF_GRID_TICK, pos_inf());
    assert_admission_refund(&exposure, &pricer, 0, OFF_GRID_TICK);
    fixture::finish(fx, oracle, exposure);
}

#[test]
fun a_tick_pair_no_order_can_encode_reports_admission() {
    let (mut fx, oracle, exposure) = fixture::setup(default_config(), IMPACT_SCALE);
    let pricer = fx.load_pricer_bundle(&oracle);

    // Empty, reversed, the whole line, and past the positive-infinity sentinel
    // (the first admission-grid tick above it: 2^30 - 1 + 7 = 1_073_741_830).
    let admission_multiple =
        test_constants::default_admission_tick_size() / test_constants::default_tick_size();
    let past_pos_inf = pos_inf() + 7;
    assert_eq!(past_pos_inf % admission_multiple, 0);
    assert_admission_refund(&exposure, &pricer, STRIKE, STRIKE);
    assert_admission_refund(&exposure, &pricer, STRIKE, LOWER_LEG_TICK);
    assert_admission_refund(&exposure, &pricer, 0, pos_inf());
    assert_admission_refund(&exposure, &pricer, STRIKE, past_pos_inf);
    fixture::finish(fx, oracle, exposure);
}

#[test]
fun an_unpriceable_surface_returns_none_instead_of_aborting() {
    // Every finite digital on this surface aborts `EZeroForward` (paired test below).
    let (mut fx, oracle, exposure) = fixture::setup_zero_forward(default_config(), IMPACT_SCALE);
    let pricer = fx.load_pricer_bundle(&oracle);

    assert!(exposure.try_quote_mint_range(&pricer, STRIKE, pos_inf()).is_none());
    assert_admission_refund(&exposure, &pricer, STRIKE, pos_inf());
    let order = order::new_from_ticks(STRIKE, pos_inf(), Q_A, 0);
    assert!(exposure.try_quote_live_close(&pricer, &order, Q_A).is_none());
    fixture::finish(fx, oracle, exposure);
}

#[test, expected_failure(abort_code = pricing::EZeroForward)]
fun the_aborting_quote_aborts_on_the_unpriceable_surface() {
    let (mut fx, oracle, exposure) = fixture::setup_zero_forward(default_config(), IMPACT_SCALE);
    let pricer = fx.load_pricer_bundle(&oracle);

    exposure.quote_mint_terms(&pricer, STRIKE, pos_inf(), 0, Q_A, true);
    fixture::finish(fx, oracle, exposure);
    abort 999
}

// === try_quote_mint_range ===

#[test]
fun try_quote_mint_range_samples_the_book_with_inventory_impact_off() {
    // With impact off, `quote_mint_range` skips the book reads; the try variant
    // must still take them, or the post-mint liability below would read 1e9.
    let (mut fx, oracle, mut exposure) = fixture::setup(fixture::config(LAMBDA, 0), IMPACT_SCALE);
    let pricer = fx.load_pricer_bundle(&oracle);
    let terms_a = exposure.quote_mint_terms(&pricer, 0, STRIKE, 0, Q_A, true);
    exposure.allocate_mint_order(terms_a);

    let range = exposure.try_quote_mint_range(&pricer, STRIKE, pos_inf()).destroy_some();
    assert_eq!(exposure.mint_liability_after(&range, Q_B), LIABILITY_A_B);
    let (terms_b, reason) = exposure.try_mint_terms(range, Q_B, Q_B);
    assert_eq!(reason, REASON_FILL);
    let terms_b = terms_b.destroy_some();
    assert_eq!(terms_b.inventory_impact_charge(), 0);
    exposure.allocate_mint_order(terms_b);
    assert_eq!(exposure.payout_liability(), LIABILITY_A_B);
    fixture::finish(fx, oracle, exposure);
}

// === try_quote_live_close ===

#[test]
fun try_quote_live_close_matches_quote_live_close() {
    let (mut fx, oracle, mut exposure) = fixture::setup(
        fixture::config(LAMBDA, IMPACT_RATE),
        IMPACT_SCALE,
    );
    let pricer = fx.load_pricer_bundle(&oracle);
    let order = mint(&mut exposure, &pricer, STRIKE, pos_inf(), Q_A);

    // Full close of the only order rebates its whole charge.
    let expected_full = exposure.quote_live_close(&pricer, &order, Q_A);
    let full = exposure.try_quote_live_close(&pricer, &order, Q_A).destroy_some();
    assert_eq!(full.inventory_impact_rebate(), IMPACT_AT_Q_A);
    assert_eq!(full.inventory_impact_rebate(), expected_full.inventory_impact_rebate());
    assert_eq!(full.redeem_amount(), expected_full.redeem_amount());
    assert_eq!(full.range_probability(), expected_full.range_probability());

    let expected_partial = exposure.quote_live_close(&pricer, &order, Q_B);
    let partial = exposure.try_quote_live_close(&pricer, &order, Q_B).destroy_some();
    assert_eq!(partial.inventory_impact_rebate(), expected_partial.inventory_impact_rebate());
    assert_eq!(partial.redeem_amount(), expected_partial.redeem_amount());

    // The try terms drive the same mutation as the aborting ones.
    let survivor = exposure.process_live_close(partial, &vec_map::empty()).destroy_some();
    assert_eq!(survivor.quantity(), Q_A - Q_B);
    fixture::finish(fx, oracle, exposure);
}

#[test]
fun try_quote_live_close_rejects_unusable_close_sizes() {
    let (mut fx, oracle, mut exposure) = fixture::setup(default_config(), IMPACT_SCALE);
    let pricer = fx.load_pricer_bundle(&oracle);
    let order = mint(&mut exposure, &pricer, STRIKE, pos_inf(), Q_A);
    let lot = constants::position_lot_size!();

    // Zero, one lot more than the order holds, and not a whole lot.
    assert!(exposure.try_quote_live_close(&pricer, &order, 0).is_none());
    assert!(exposure.try_quote_live_close(&pricer, &order, Q_A + lot).is_none());
    assert!(exposure.try_quote_live_close(&pricer, &order, Q_B + 1).is_none());
    // The whole order is still closable.
    assert!(exposure.try_quote_live_close(&pricer, &order, Q_A).is_some());
    fixture::finish(fx, oracle, exposure);
}

// === Helpers ===

fun assert_admission_refund(
    exposure: &StrikeExposure,
    pricer: &Pricer,
    lower_tick: u64,
    higher_tick: u64,
) {
    assert!(exposure.try_quote_mint_range(pricer, lower_tick, higher_tick).is_none());
    let (terms, reason) = exposure.try_quote_mint_terms(
        pricer,
        lower_tick,
        higher_tick,
        0,
        Q_A,
        true,
    );
    assert!(terms.is_none());
    assert_eq!(reason, REASON_ADMISSION);
    assert_eq!(reason, constants::fill_reason_admission!());
}

fun mint(
    exposure: &mut StrikeExposure,
    pricer: &Pricer,
    lower_tick: u64,
    higher_tick: u64,
    quantity: u64,
): Order {
    let terms = exposure.quote_mint_terms(pricer, lower_tick, higher_tick, 0, quantity, true);
    exposure.allocate_mint_order(terms)
}

fun pos_inf(): u64 { constants::pos_inf_tick!() }

fun default_config(): StrikeExposureConfig {
    strike_exposure_config::new()
}
