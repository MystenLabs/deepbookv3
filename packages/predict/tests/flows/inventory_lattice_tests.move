// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Coverage for the inventory lattice: the measure it carries, and what
/// re-anchoring does to it.
///
/// These live with the flow tests because building a lattice needs a validated
/// `Pricer`, which only the market fixture can produce. Expected values are
/// derived from the definition of the statistic, never from the lattice's own
/// arithmetic.
#[test_only]
module deepbook_predict::inventory_lattice_tests;

use deepbook_predict::{constants, flow_test_helpers as helpers, inventory_lattice, test_constants};
use fixed_math::i64;
use std::unit_test::assert_eq;

/// One whole contract, which is also the fixed-point scale.
const ONE: u64 = 1_000_000_000;

/// A flat book owes the same at every settlement price, so the measure is zero
/// under any anchor — this is what makes a complete set free, and it must stay
/// true after the anchor moves.
#[test]
fun a_flat_book_scores_zero_under_every_anchor() {
    let (mut fx, market) = fixture();
    let pricer = helpers::load_pricer_bundle(&mut fx, &market);
    let mut lattice = inventory_lattice::initialize(&pricer);
    assert_eq!(lattice.deviation(&pricer), 0);

    // The whole ladder at one payout: flat by construction.
    lattice.apply_range_for_testing(
        0,
        constants::pos_inf_tick!(),
        ONE,
        test_constants::default_tick_size(),
    );
    let mut step = 0;
    while (step <= 40) {
        assert_eq!(lattice.deviation_at_shift(i64::from_u64(step)), 0);
        assert_eq!(lattice.deviation_at_shift(i64::from_parts(step, true)), 0);
        step = step + 8;
    };

    helpers::return_market_bundle(market);
    fx.finish();
}

/// The at-the-money one-sided book: half the measure's mass pays and half does
/// not, so the deviation is half the payout. Derived from the definition —
/// `sqrt(m(1-m))` at `m = 1/2` is `1/2` — and the lattice reproduces it to
/// within its own cell resolution.
#[test]
fun a_one_sided_book_at_the_money_scores_half_its_payout() {
    let (mut fx, market) = fixture();
    let pricer = helpers::load_pricer_bundle(&mut fx, &market);
    let mut lattice = inventory_lattice::initialize(&pricer);
    lattice.apply_range_for_testing(
        helpers::strike_tick(),
        constants::pos_inf_tick!(),
        ONE,
        test_constants::default_tick_size(),
    );

    let measured = lattice.deviation(&pricer);
    // Within a cell's worth of the exact half; the lattice's own resolution is
    // the only source of the gap.
    assert!(measured > ONE / 2 - ONE / 100);
    assert!(measured <= ONE / 2);

    helpers::return_market_bundle(market);
    fx.finish();
}

/// Re-anchoring is the whole point: the same book scores differently as the
/// centre of the measure moves, because what the pool owes stops being a
/// coin flip and starts being nearly certain.
///
/// For a one-sided book the measure is `q * sqrt(m(1-m))` where `m` is the mass
/// above the strike. Shifting the anchor up drives `m` toward one and the
/// measure toward zero; shifting it down drives `m` toward zero and does the
/// same. A measure frozen at both shape and centre would return the identical
/// number at every shift, which is exactly the failure this design removes.
#[test]
fun the_measure_re_anchors_and_peaks_where_the_book_is_a_coin_flip() {
    let (mut fx, market) = fixture();
    let pricer = helpers::load_pricer_bundle(&mut fx, &market);
    let mut lattice = inventory_lattice::initialize(&pricer);
    lattice.apply_range_for_testing(
        helpers::strike_tick(),
        constants::pos_inf_tick!(),
        ONE,
        test_constants::default_tick_size(),
    );

    let at_the_money = lattice.deviation_at_shift(i64::from_u64(0));
    let moved_up = lattice.deviation_at_shift(i64::from_u64(60));
    let moved_far_up = lattice.deviation_at_shift(i64::from_u64(110));
    let moved_down = lattice.deviation_at_shift(i64::from_parts(60, true));

    // The anchor genuinely moves the measure.
    assert!(moved_up < at_the_money);
    assert!(moved_down < at_the_money);
    // And further is smaller still: the book becomes a near-certainty either way.
    assert!(moved_far_up < moved_up);
    // A frozen-centre measure would have returned `at_the_money` for all of them.
    assert!(moved_far_up * 2 < at_the_money);

    helpers::return_market_bundle(market);
    fx.finish();
}

/// Re-anchoring may never create or destroy probability: mass that shifts past
/// an end folds into that end's sentinel, so the measure is still a measure at
/// every anchor.
#[test]
fun every_anchor_still_sums_to_certainty() {
    let (mut fx, market) = fixture();
    let pricer = helpers::load_pricer_bundle(&mut fx, &market);
    let lattice = inventory_lattice::initialize(&pricer);

    let mut step = 0;
    while (step <= 400) {
        assert_eq!(lattice.total_mass_at_shift(i64::from_u64(step)), ONE);
        assert_eq!(lattice.total_mass_at_shift(i64::from_parts(step, true)), ONE);
        step = step + 40;
    };

    helpers::return_market_bundle(market);
    fx.finish();
}

fun fixture(): (helpers::Fixture, helpers::MarketBundle) {
    let mut fx = helpers::setup_market_default();
    let expiry_id = fx.create_expiry(test_constants::default_expiry_ms());
    let mut market = fx.take_market_bundle(expiry_id);
    fx.prepare_live_oracle_bundle(&mut market, test_constants::default_live_price());
    (fx, market)
}
