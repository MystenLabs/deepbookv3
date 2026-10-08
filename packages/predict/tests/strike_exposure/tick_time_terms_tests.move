// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Exposure helpers a delayed-execution resolve uses: the non-aborting entry
/// band predicates, `try_terms` and its refund reasons, the post-trade
/// liability reads behind resolve's no-cash check, the fill-time allocation that
/// never creates a payout-tree node, and the non-aborting settled close.
///
/// The book scenario: A = (0, 100] and B = (100, +inf] are disjoint ranges on
/// either side of the ATM strike, with `lambda = 1/2`, so live liability is
/// `M + (T - M) / 2` for point max `M` and total payout `T`. Every expected
/// liability is worked by hand from that formula.
#[test_only]
module deepbook_predict::tick_time_terms_tests;

use deepbook_predict::{
    constants,
    order::{Self, Order},
    pricing::{Pricer, RangePrice},
    range_codec,
    strike_exposure::{Self, StrikeExposure},
    strike_exposure_config::{Self, StrikeExposureConfig},
    strike_payout_tree,
    test_constants,
    tick_time_exposure_fixture as fixture
};
use std::unit_test::{assert_eq, destroy};
use sui::vec_map;

const STRIKE: u64 = 100;
const LOWER_LEG_TICK: u64 = 90;
const HIGHER_LEG_TICK: u64 = 110;
const LAMBDA: u64 = 500_000_000; // 1/2
const IMPACT_RATE: u64 = 200_000_000; // 20%
const IMPACT_SCALE: u64 = 4_000_000_000;
const Q_A: u64 = 3_000_000_000;
const Q_B: u64 = 1_000_000_000;
const Q_C: u64 = 2_000_000_000;
/// Spec defaults for the entry band: 1% and 99%.
const MIN_ENTRY_PROBABILITY: u64 = 10_000_000;
const MAX_ENTRY_PROBABILITY: u64 = 990_000_000;
/// `phi(L) = r * L^2 / (2B)` at `L = 3e9`, `B = 4e9`, `r = 20%`: 15% * 3e9 / 2.
const IMPACT_AT_Q_A: u64 = 225_000_000;
/// Raw settlement inside A and below B: `ceil(95e9 / 1e9) = 95`, and `0 < 95 <= 100`.
const SETTLEMENT_IN_A: u64 = 95_000_000_000;
/// Hand-worked liabilities of the A/B book (see each test for the working).
const LIABILITY_A_ONLY: u64 = 3_000_000_000;
const LIABILITY_A_B: u64 = 3_500_000_000;
const LIABILITY_A_B_C: u64 = 5_500_000_000;
const LIABILITY_A_B_C_D: u64 = 6_000_000_000;
const LIABILITY_PARTIAL_A_B: u64 = 2_500_000_000;
const LIABILITY_PARTIAL_A: u64 = 2_000_000_000;
const REASON_FILL: u8 = 0;
const REASON_LIMITS: u8 = 1;
const REASON_ADMISSION: u8 = 2;

// === Entry band predicates ===

#[test]
fun mint_probability_band_is_inclusive_at_both_ends() {
    let config = strike_exposure_config::new();

    assert!(config.prob_ok(MIN_ENTRY_PROBABILITY));
    assert!(!config.prob_ok(MIN_ENTRY_PROBABILITY - 1));
    assert!(config.prob_ok(MAX_ENTRY_PROBABILITY));
    assert!(!config.prob_ok(MAX_ENTRY_PROBABILITY + 1));
    assert!(!config.prob_ok(0));
    destroy(config);
}

#[test]
fun range_band_checks_each_finite_leg_and_the_range() {
    // The default surface's variance is near zero, so a strike 10% from the
    // forward prices at a digital of essentially 0 or 1.
    let (mut fx, oracle, exposure) = fixture::setup(default_config(), IMPACT_SCALE);
    let pricer = fx.load_pricer_bundle(&oracle);
    let config = strike_exposure_config::new();

    // ATM to +inf: one finite leg near 1/2 and a range near 1/2.
    let atm_to_inf = range_price(&pricer, STRIKE, pos_inf());
    assert!(config.range_ok(&atm_to_inf));
    // (90, 100]: the range is near 1/2 but the lower leg is near 1.
    let lower_leg_too_high = range_price(&pricer, LOWER_LEG_TICK, STRIKE);
    assert!(!config.range_ok(&lower_leg_too_high));
    // (100, 110]: the range is near 1/2 but the upper leg's complement is near 1.
    let higher_leg_too_high = range_price(&pricer, STRIKE, HIGHER_LEG_TICK);
    assert!(!config.range_ok(&higher_leg_too_high));
    // (110, +inf]: the range itself is near 0.
    let range_too_low = range_price(&pricer, HIGHER_LEG_TICK, pos_inf());
    assert!(!config.range_ok(&range_too_low));

    destroy(config);
    fixture::finish(fx, oracle, exposure);
}

#[test, expected_failure(abort_code = strike_exposure_config::EEntryProbabilityOutOfBounds)]
fun range_band_assert_rejects_a_leg_only_failure() {
    let (mut fx, oracle, _exposure) = fixture::setup(default_config(), IMPACT_SCALE);
    let pricer = fx.load_pricer_bundle(&oracle);
    let config = strike_exposure_config::new();

    config.assert_range_mint_probability_policy(&range_price(&pricer, LOWER_LEG_TICK, STRIKE));
    abort 999
}

// === try_mint_terms ===

#[test]
fun try_mint_terms_matches_mint_terms_on_valid_inputs() {
    let (mut fx, oracle, exposure) = fixture::setup(
        fixture::config(LAMBDA, IMPACT_RATE),
        IMPACT_SCALE,
    );
    let pricer = fx.load_pricer_bundle(&oracle);

    let expected_range = exposure.quote_mint_range(&pricer, STRIKE, pos_inf());
    let expected = exposure.mint_terms(expected_range, Q_A, Q_A);
    let (terms, reason) = exposure.try_terms(
        exposure.quote_mint_range(&pricer, STRIKE, pos_inf()),
        Q_A,
        Q_A,
    );

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
fun try_mint_terms_reports_limits_for_unusable_sizes() {
    let (mut fx, oracle, exposure) = fixture::setup(default_config(), IMPACT_SCALE);
    let pricer = fx.load_pricer_bundle(&oracle);
    let lot = constants::position_lot_size!();
    let one_lot_past_the_id_field = (order::max_quantity_lots!() + 1) * lot;

    // Zero size, below the minimum, not a whole lot, and too many lots to encode.
    let cases = vector[
        vector[0, 0],
        vector[Q_A, Q_A + lot],
        vector[Q_A + 1, 0],
        vector[one_lot_past_the_id_field, 0],
    ];
    cases.do!(|sizes| {
        let range = exposure.quote_mint_range(&pricer, STRIKE, pos_inf());
        let (terms, reason) = exposure.try_terms(range, sizes[0], sizes[1]);
        assert!(terms.is_none());
        assert_eq!(reason, REASON_LIMITS);
        assert_eq!(reason, constants::fill_reason_limits!());
    });

    fixture::finish(fx, oracle, exposure);
}

#[test]
fun try_mint_terms_reports_admission_below_the_minimum_premium() {
    // One lot pays at most `1.0 * 10_000 = 10_000`, below the 1 USDC (1_000_000)
    // minimum premium at any probability.
    let (mut fx, oracle, exposure) = fixture::setup(default_config(), IMPACT_SCALE);
    let pricer = fx.load_pricer_bundle(&oracle);
    let lot = constants::position_lot_size!();

    let range = exposure.quote_mint_range(&pricer, STRIKE, pos_inf());
    let (terms, reason) = exposure.try_terms(range, lot, lot);

    assert!(terms.is_none());
    assert_eq!(reason, REASON_ADMISSION);
    assert_eq!(reason, constants::fill_reason_admission!());
    fixture::finish(fx, oracle, exposure);
}

/// The aborting path checks the premium floor before the size, so a zero size
/// aborts on the premium there, while `try_terms` reports it as a size
/// (reason 1). Both reject the same input.
#[test, expected_failure(abort_code = strike_exposure_config::EPremiumBelowMinimum)]
fun mint_terms_aborts_on_a_zero_size() {
    let (mut fx, oracle, exposure) = fixture::setup(default_config(), IMPACT_SCALE);
    let pricer = fx.load_pricer_bundle(&oracle);

    exposure.mint_terms(exposure.quote_mint_range(&pricer, STRIKE, pos_inf()), 0, 0);
    abort 999
}

// === Liability after a prospective trade ===

#[test]
fun mint_liability_after_matches_the_post_mint_payout_liability() {
    // Inventory impact on, so `quote_mint_range` samples the book reads.
    let (mut fx, oracle, mut exposure) = fixture::setup(
        fixture::config(LAMBDA, IMPACT_RATE),
        IMPACT_SCALE,
    );
    let pricer = fx.load_pricer_bundle(&oracle);

    // Empty book, A (0, 100] q=3e9: M = 3e9, T = 3e9, liability 3e9.
    mint_and_check(&mut exposure, &pricer, 0, STRIKE, Q_A, LIABILITY_A_ONLY);
    // B (100, +inf] q=1e9 has no peak yet: M = max(3e9, 0 + 1e9) = 3e9,
    // T = 4e9, liability 3e9 + 1e9 / 2 = 3.5e9.
    mint_and_check(&mut exposure, &pricer, STRIKE, pos_inf(), Q_B, LIABILITY_A_B);
    // C (0, 100] q=2e9 stacks on A's 3e9 peak: M = 5e9, T = 6e9,
    // liability 5e9 + 1e9 / 2 = 5.5e9.
    mint_and_check(&mut exposure, &pricer, 0, STRIKE, Q_C, LIABILITY_A_B_C);
    // D (100, +inf] q=1e9 lifts B's side to 2e9 only: M = 5e9, T = 7e9,
    // liability 5e9 + 2e9 / 2 = 6e9.
    mint_and_check(&mut exposure, &pricer, STRIKE, pos_inf(), Q_B, LIABILITY_A_B_C_D);

    fixture::finish(fx, oracle, exposure);
}

#[test]
fun close_liability_after_matches_the_post_close_payout_liability() {
    let (mut fx, oracle, mut exposure) = fixture::setup(
        fixture::config(LAMBDA, IMPACT_RATE),
        IMPACT_SCALE,
    );
    let pricer = fx.load_pricer_bundle(&oracle);
    let order_a = mint(&mut exposure, &pricer, 0, STRIKE, Q_A);
    let order_b = mint(&mut exposure, &pricer, STRIKE, pos_inf(), Q_B);
    // M = 3e9, T = 4e9: 3e9 + 1e9 / 2.
    assert_eq!(exposure.payout_liability(), LIABILITY_A_B);

    // Close 1e9 of A: A's side drops to 2e9, B's stays 1e9. M = 2e9, T = 3e9,
    // liability 2e9 + 1e9 / 2 = 2.5e9.
    let survivor_a = close_and_check(&mut exposure, &pricer, &order_a, Q_B, LIABILITY_PARTIAL_A_B);
    // Close all of B: M = 2e9 from A's side, T = 2e9, liability 2e9.
    close_and_check(&mut exposure, &pricer, &order_b, Q_B, LIABILITY_PARTIAL_A);
    // Close the rest of A: an empty book.
    close_and_check(&mut exposure, &pricer, &survivor_a.destroy_some(), Q_C, 0);

    fixture::finish(fx, oracle, exposure);
}

// === allocate_mint_order_existing ===

#[test]
fun allocate_mint_order_existing_fills_over_ensured_nodes() {
    let (mut fx, oracle, mut exposure) = fixture::setup(fixture::config(LAMBDA, 0), IMPACT_SCALE);
    let pricer = fx.load_pricer_bundle(&oracle);

    // Placement creates the one finite boundary both ranges share.
    exposure.ensure_nodes(STRIKE, pos_inf());
    assert_eq!(exposure.tree_nodes(), 1);
    assert!(exposure.nodes_exist(STRIKE, pos_inf()));
    assert!(exposure.nodes_exist(0, STRIKE));

    let terms_b = exposure.quote_mint_terms(&pricer, STRIKE, pos_inf(), 0, Q_B, true);
    let order_b = exposure.allocate(terms_b);
    assert_eq!(order_b.id(), order::from_ticks(STRIKE, pos_inf(), Q_B, 0).id());
    assert_eq!(exposure.tree_nodes(), 1);
    assert_eq!(exposure.payout_liability(), Q_B);

    let terms_a = exposure.quote_mint_terms(&pricer, 0, STRIKE, 0, Q_A, true);
    let order_a = exposure.allocate(terms_a);
    assert_eq!(order_a.id(), order::from_ticks(0, STRIKE, Q_A, 1).id());
    assert_eq!(exposure.tree_nodes(), 1);
    // M = 3e9, T = 4e9: 3e9 + 1e9 / 2.
    assert_eq!(exposure.payout_liability(), LIABILITY_A_B);

    fixture::finish(fx, oracle, exposure);
}

#[test, expected_failure(abort_code = strike_payout_tree::ENodeMissing)]
fun allocate_mint_order_existing_without_its_node_aborts() {
    let (mut fx, oracle, mut exposure) = fixture::setup(default_config(), IMPACT_SCALE);
    let pricer = fx.load_pricer_bundle(&oracle);

    let terms = exposure.quote_mint_terms(&pricer, STRIKE, pos_inf(), 0, Q_B, true);
    exposure.allocate(terms);
    abort 999
}

#[test, expected_failure(abort_code = strike_exposure::ETermsExposureMismatch)]
fun allocate_mint_order_existing_with_terms_from_another_exposure_aborts() {
    let (mut fx, oracle, exposure) = fixture::setup(default_config(), IMPACT_SCALE);
    let mut other = fixture::other_exposure(&mut fx, default_config(), IMPACT_SCALE);
    let pricer = fx.load_pricer_bundle(&oracle);
    other.ensure_nodes(STRIKE, pos_inf());

    let terms = exposure.quote_mint_terms(&pricer, STRIKE, pos_inf(), 0, Q_B, true);
    other.allocate(terms);
    abort 999
}

// === try_process_settled_close ===

#[test]
fun try_process_settled_close_pays_each_winner_once() {
    let (mut fx, oracle, mut exposure) = fixture::setup(default_config(), IMPACT_SCALE);
    let pricer = fx.load_pricer_bundle(&oracle);
    let order_a = mint(&mut exposure, &pricer, 0, STRIKE, Q_A);
    let order_b = mint(&mut exposure, &pricer, STRIKE, pos_inf(), Q_B);

    // Nothing to pay while the book is live.
    assert!(exposure.try_settled(&order_a).is_none());

    exposure.set_settled(SETTLEMENT_IN_A);
    assert_eq!(exposure.payout_liability(), Q_A);

    // B lost: it pays zero and leaves the liability alone.
    assert_eq!(exposure.try_settled(&order_b), option::some(0));
    assert_eq!(exposure.payout_liability(), Q_A);
    // A won its full quantity.
    assert_eq!(exposure.try_settled(&order_a), option::some(Q_A));
    assert_eq!(exposure.payout_liability(), 0);
    // Paying A again would underflow the settled liability: skipped, unchanged.
    assert!(exposure.try_settled(&order_a).is_none());
    assert_eq!(exposure.payout_liability(), 0);

    fixture::finish(fx, oracle, exposure);
}

// === Helpers ===

/// Quote, check the predicted liability, mint, and check the backing reads it.
fun mint_and_check(
    exposure: &mut StrikeExposure,
    pricer: &Pricer,
    lower_tick: u64,
    higher_tick: u64,
    quantity: u64,
    expected_liability: u64,
) {
    let range = exposure.quote_mint_range(pricer, lower_tick, higher_tick);
    assert_eq!(exposure.liab_minted(&range, quantity), expected_liability);
    let terms = exposure.mint_terms(range, quantity, quantity);
    exposure.allocate_mint_order(terms);
    assert_eq!(exposure.payout_liability(), expected_liability);
}

/// Check the predicted liability of a close, apply it, and check the backing
/// reads it. Returns the partial close's survivor.
fun close_and_check(
    exposure: &mut StrikeExposure,
    pricer: &Pricer,
    order: &Order,
    close_quantity: u64,
    expected_liability: u64,
): Option<Order> {
    assert_eq!(
        exposure.liab_closed(order.lower_tick(), order.higher_tick(), close_quantity),
        expected_liability,
    );
    let terms = exposure.quote_live_close(pricer, order, close_quantity);
    let survivor = exposure.apply_close(terms, &vec_map::empty());
    assert_eq!(exposure.payout_liability(), expected_liability);
    survivor
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

fun range_price(pricer: &Pricer, lower_tick: u64, higher_tick: u64): RangePrice {
    let tick_size = test_constants::default_tick_size();
    pricer.range_price(
        range_codec::strike_from_tick(lower_tick, tick_size),
        range_codec::strike_from_tick(higher_tick, tick_size),
    )
}

fun pos_inf(): u64 { constants::pos_inf_tick!() }

/// Spec defaults: lambda 31%, inventory impact off.
fun default_config(): StrikeExposureConfig {
    strike_exposure_config::new()
}
