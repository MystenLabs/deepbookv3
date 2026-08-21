// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Economic and state-transition tests for frozen-grid inventory impact.
#[test_only]
module deepbook_predict::inventory_impact_tests;

use deepbook_predict::{
    constants,
    frozen_grid_fixture,
    inventory_grid::{Self, InventoryGrid},
    oracle_fixture::{Self, OracleBundle, OracleFixture},
    pricing::Pricer,
    strike_exposure::{Self, StrikeExposure},
    strike_exposure_config::{Self, StrikeExposureConfig},
    test_constants
};
use fixed_math::math;
use std::unit_test::{assert_eq, destroy};
use sui::{object::{Self, UID}, test_scenario::return_shared};

public struct ExposureHarness has key {
    id: UID,
    exposure: StrikeExposure,
}

const TEST_TICK_SIZE: u64 = 10_000;
const TEST_ADMISSION_TICK_SIZE: u64 = 10_000;
const IMPACT_SCALE: u64 = 1_000_000_000;
const IMPACT_MAX_RATE: u64 = 20_000_000; // 2%
const ONE_ORDER: u64 = 1_000_000_000;
const FIVE_BUCKET_CAPITAL: u64 = 950_000_000;
const MANY_ORDERS: u64 = 24;
const MANY_ORDER_QUANTITY: u64 = 1_000_000;
const MANY_ORDER_BASE_TICK: u64 = 9_999_400;
/// Ticks between adjacent order boundaries in the loaded-book test. One cell is
/// about forty ticks wide on this fixture, so a four-tick stride spreads these
/// orders across several distinct cells: enough that the centering walk crosses
/// many payout change points, while keeping every boundary below the tail buckets
/// so each of those still sees the whole book.
const MANY_ORDER_TICK_STRIDE: u64 = 4;

#[test]
fun default_zero_rate_is_a_kill_switch() {
    let (mut fx, oracle, mut harness) = new_harness(impact_config(0));
    let pricer = fx.load_pricer_bundle(&oracle);
    let terms = harness
        .exposure
        .quote_mint_terms(
            &pricer,
            test_constants::default_live_price() / TEST_TICK_SIZE,
            constants::pos_inf_tick!(),
            0,
            ONE_ORDER,
            true,
        );
    assert_eq!(terms.inventory_impact_charge(), 0);
    assert_eq!(terms.frozen_expected_payout(), 0);
    let order = harness.exposure.allocate_mint_order(terms);
    assert_eq!(harness.exposure.inventory_impact_potential(), 0);
    let close = harness.exposure.quote_live_close(&pricer, &order, order.quantity());
    assert_eq!(close.live_close_inventory_impact_charge(), 0);
    harness.exposure.process_live_close(close);
    assert_eq!(harness.exposure.inventory_impact_potential(), 0);
    cleanup(fx, oracle, harness);
}

#[test]
fun five_bucket_coordinate_matches_independent_reference() {
    let mut maxima = vector[];
    let mut index = 0u64;
    while (index < 100) {
        maxima.push_back(if (index < 5) ONE_ORDER else 0);
        index = index + 1;
    };
    assert_eq!(inventory_grid::capital_from_components(maxima, 50_000_000), FIVE_BUCKET_CAPITAL);
}

#[test]
fun quantile_grid_pile_on_round_trips_frozen_capital() {
    let (mut fx, oracle, mut harness) = new_harness(impact_config(IMPACT_MAX_RATE));
    let pricer = fx.load_pricer_bundle(&oracle);
    let ratios = frozen_grid_fixture::ratios();
    // Interior ratio 4 is the 5% quantile; the grid reads it against this pricer's
    // forward, so the absolute price it names is the same product.
    let five_percent_boundary = math::mul_down(ratios[4], pricer.forward());
    let five_percent_boundary_tick =
        five_percent_boundary / TEST_TICK_SIZE
            + if (five_percent_boundary % TEST_TICK_SIZE == 0) 0 else 1;
    harness.exposure.initialize_inventory_grid(&pricer, ratios);

    let terms = harness
        .exposure
        .quote_mint_terms(
            &pricer,
            0,
            five_percent_boundary_tick,
            0,
            ONE_ORDER,
            true,
        );
    let frozen_expected_payout = terms.frozen_expected_payout();
    let inventory_impact_charge = terms.inventory_impact_charge();
    // The range is the first five 1% buckets, so the centering term is the snapped
    // cell-span mass of that tail and is strictly inside `(0, quantity)`.
    assert!(frozen_expected_payout > 0);
    assert!(frozen_expected_payout < ONE_ORDER);
    assert!(inventory_impact_charge > 0);
    let order = harness.exposure.allocate_mint_order(terms);
    assert_eq!(harness.exposure.inventory_impact_potential(), inventory_impact_charge);
    let close = harness.exposure.quote_live_close(&pricer, &order, order.quantity());
    // Unwinding the pile-on is free and refunds nothing: the potential returns
    // to zero while the charge collected at mint stays with the pool.
    assert_eq!(close.live_close_inventory_impact_charge(), 0);
    harness.exposure.process_live_close(close);
    assert_eq!(harness.exposure.inventory_impact_potential(), 0);
    cleanup(fx, oracle, harness);
}

#[test]
fun a_partial_close_leaves_a_disjoint_peak_standing() {
    let (mut fx, oracle, harness) = new_harness(impact_config(IMPACT_MAX_RATE));
    let pricer = fx.load_pricer_bundle(&oracle);
    let mut grid = inventory_grid::initialize(&pricer, frozen_grid_fixture::ratios());

    // Two disjoint ranges, each a few cells wide and a few cells apart, so the
    // mirror records them separately. A is initially taller; after half of A closes,
    // B must stand as the book's peak rather than A's reduced height.
    let (a_lower, a_higher, a_quantity) = (10_000_000, 10_000_080, ONE_ORDER);
    let (b_lower, b_higher, b_quantity) = (10_000_160, 10_000_240, 900_000_000);

    open_range(&mut grid, a_lower, a_higher, a_quantity);
    open_range(&mut grid, b_lower, b_higher, b_quantity);
    assert_eq!(book_peak(&grid), ONE_ORDER);

    let a_close_quantity = a_quantity / 2;
    let a_close_expected = close_range(&mut grid, a_lower, a_higher, a_close_quantity);

    // Naively subtracting A's close from a book-level maximum would report 500m.
    // Because payout is held per region, B's independent 900m peak is what remains.
    assert_eq!(book_peak(&grid), b_quantity);
    assert!(book_peak(&grid) != ONE_ORDER - a_close_quantity);

    let a_open_expected = grid.frozen_expected_payout(
        a_lower,
        a_higher,
        a_quantity,
        TEST_TICK_SIZE,
    );
    grid.apply_change(
        a_lower,
        a_higher,
        a_quantity - a_close_quantity,
        a_open_expected - a_close_expected,
        false,
        TEST_TICK_SIZE,
    );
    close_range(&mut grid, b_lower, b_higher, b_quantity);
    assert_eq!(book_peak(&grid), 0);
    assert_eq!(grid.current_frozen_expected_payout(), 0);
    assert_eq!(grid.k95(), 0);

    destroy(grid);
    cleanup(fx, oracle, harness);
}

#[test]
fun closing_a_hedge_pays_the_same_potential_increase_as_opening_risk() {
    let (mut fx, oracle, mut harness) = new_harness(impact_config(IMPACT_MAX_RATE));
    let pricer = fx.load_pricer_bundle(&oracle);
    harness.exposure.initialize_inventory_grid(&pricer, frozen_grid_fixture::ratios());

    let median_tick = test_constants::default_live_price() / TEST_TICK_SIZE;
    let risky_terms = harness
        .exposure
        .quote_mint_terms(&pricer, 0, median_tick, 0, ONE_ORDER, true);
    let open_charge = risky_terms.inventory_impact_charge();
    assert!(open_charge > 0);
    let risky_order = harness.exposure.allocate_mint_order(risky_terms);

    // The complementary range makes payout constant across settlement states.
    // A risk-reducing mint is free but does not draw an inventory refund.
    let hedge_terms = harness
        .exposure
        .quote_mint_terms(
            &pricer,
            median_tick,
            constants::pos_inf_tick!(),
            0,
            ONE_ORDER,
            true,
        );
    assert_eq!(hedge_terms.inventory_impact_charge(), 0);
    let hedge_order = harness.exposure.allocate_mint_order(hedge_terms);
    assert_eq!(harness.exposure.inventory_impact_potential(), 0);

    let hedge_close = harness.exposure.quote_live_close(&pricer, &hedge_order, ONE_ORDER);
    assert_eq!(hedge_close.live_close_inventory_impact_charge(), open_charge);
    harness.exposure.process_live_close(hedge_close).destroy_none();

    let risky_close = harness.exposure.quote_live_close(&pricer, &risky_order, ONE_ORDER);
    assert_eq!(risky_close.live_close_inventory_impact_charge(), 0);
    harness.exposure.process_live_close(risky_close).destroy_none();
    assert_eq!(harness.exposure.inventory_impact_potential(), 0);

    cleanup(fx, oracle, harness);
}

#[test, expected_failure(abort_code = strike_exposure::EInventoryGridNotInitialized)]
fun nonzero_rate_requires_initialized_grid() {
    let (mut fx, oracle, harness) = new_harness(impact_config(IMPACT_MAX_RATE));
    let pricer = fx.load_pricer_bundle(&oracle);
    harness
        .exposure
        .quote_mint_terms(
            &pricer,
            test_constants::default_live_price() / TEST_TICK_SIZE,
            constants::pos_inf_tick!(),
            0,
            ONE_ORDER,
            true,
        );
    abort 999
}

#[test, expected_failure(abort_code = inventory_grid::EInvalidBoundaryCount)]
fun grid_boundary_count_is_exact() {
    let (mut fx, oracle, mut harness) = new_harness(impact_config(IMPACT_MAX_RATE));
    let pricer = fx.load_pricer_bundle(&oracle);
    let mut boundaries = frozen_grid_fixture::ratios();
    boundaries.pop_back();
    harness.exposure.initialize_inventory_grid(&pricer, boundaries);
    abort 999
}

#[test, expected_failure(abort_code = inventory_grid::EInvalidBoundary)]
fun grid_ratios_must_strictly_increase() {
    let (mut fx, oracle, mut harness) = new_harness(impact_config(IMPACT_MAX_RATE));
    let pricer = fx.load_pricer_bundle(&oracle);
    let mut ratios = frozen_grid_fixture::ratios();
    // Two adjacent quantiles collapsed onto one value, which is how a real ladder
    // fails: near expiry the distribution narrows until neighbours round together.
    // Every earlier bucket still carries its 1%, so the ordering rule is what fires.
    *ratios.borrow_mut(11) = ratios[10];
    harness.exposure.initialize_inventory_grid(&pricer, ratios);
    abort 999
}

#[test]
fun the_grid_ladder_closes_both_ends_and_is_read_against_the_forward() {
    let (mut fx, oracle, harness) = new_harness(impact_config(IMPACT_MAX_RATE));
    let pricer = fx.load_pricer_bundle(&oracle);
    let grid = inventory_grid::initialize(&pricer, frozen_grid_fixture::ratios());

    // Callers supply interior ratios only, so no input can leave a settlement price
    // outside every bucket: the open ends are the grid's own sentinels.
    assert_eq!(grid.boundary(0), constants::neg_inf!());
    assert_eq!(grid.boundary(100), constants::pos_inf!());
    // The fixture's median ratio is exactly 1.0, so the bucket boundary it lands on
    // is the forward itself — the ladder is relative to the forward, not absolute.
    assert_eq!(grid.boundary(50), pricer.forward());

    destroy(grid);
    cleanup(fx, oracle, harness);
}

#[test, expected_failure(abort_code = inventory_grid::EInvalidBucketMass)]
fun grid_rejects_a_bucket_outside_mass_tolerance() {
    let (mut fx, oracle, mut harness) = new_harness(impact_config(IMPACT_MAX_RATE));
    let pricer = fx.load_pricer_bundle(&oracle);
    let mut boundaries = frozen_grid_fixture::ratios();
    *boundaries.borrow_mut(1) = (boundaries[1] + boundaries[2]) / 2;
    harness.exposure.initialize_inventory_grid(&pricer, boundaries);
    abort 999
}

#[test, expected_failure(abort_code = strike_exposure::EInventoryGridAlreadyInitialized)]
fun grid_can_only_be_initialized_once() {
    let (mut fx, oracle, mut harness) = new_harness(impact_config(IMPACT_MAX_RATE));
    let pricer = fx.load_pricer_bundle(&oracle);
    harness.exposure.initialize_inventory_grid(&pricer, frozen_grid_fixture::ratios());
    harness.exposure.initialize_inventory_grid(&pricer, frozen_grid_fixture::ratios());
    abort 999
}

#[test, expected_failure(abort_code = strike_exposure::EInventoryGridBookNotEmpty)]
fun grid_initialization_rejects_a_nonempty_book() {
    let (mut fx, oracle, mut harness) = new_harness(impact_config(0));
    let pricer = fx.load_pricer_bundle(&oracle);
    let terms = harness
        .exposure
        .quote_mint_terms(
            &pricer,
            test_constants::default_live_price() / TEST_TICK_SIZE,
            constants::pos_inf_tick!(),
            0,
            ONE_ORDER,
            true,
        );
    harness.exposure.allocate_mint_order(terms);
    harness.exposure.initialize_inventory_grid(&pricer, frozen_grid_fixture::ratios());
    abort 999
}

#[test, expected_failure(abort_code = strike_exposure::EInventoryGridMarketSettled)]
fun grid_initialization_rejects_a_settled_market() {
    let (mut fx, oracle, mut harness) = new_harness(impact_config(IMPACT_MAX_RATE));
    let pricer = fx.load_pricer_bundle(&oracle);
    harness.exposure.record_settlement(test_constants::default_live_price());
    harness.exposure.initialize_inventory_grid(&pricer, frozen_grid_fixture::ratios());
    abort 999
}

#[test]
fun re_cutting_onto_the_same_snapshot_reproduces_the_grid() {
    let (mut fx, oracle, harness) = new_harness(impact_config(IMPACT_MAX_RATE));
    let pricer = fx.load_pricer_bundle(&oracle);
    let mut grid = seeded_grid(&pricer);

    // A refresh re-cuts the boundaries and re-integrates the centering term over the
    // mirror. Re-cutting onto the snapshot already in force must therefore be
    // indistinguishable, bucket for bucket.
    let before_maxima = every_bucket_maximum(&grid);
    let before_k = grid.k95();
    grid.refresh(&pricer, frozen_grid_fixture::ratios());
    assert_eq!(every_bucket_maximum(&grid), before_maxima);
    assert_eq!(grid.k95(), before_k);

    close_seeded_orders(&mut grid);
    assert_eq!(grid.current_frozen_expected_payout(), 0);
    assert_eq!(grid.k95(), 0);

    destroy(grid);
    cleanup(fx, oracle, harness);
}

#[test]
fun a_close_after_a_refresh_cannot_underflow_expected_payout() {
    let (mut fx, oracle, harness) = new_harness(impact_config(IMPACT_MAX_RATE));
    let pricer = fx.load_pricer_bundle(&oracle);
    let mut grid = seeded_grid(&pricer);

    // A refresh installs the mirror's own netted integral, while closes subtract
    // per-order floors computed from exact range probabilities. The two groupings
    // round differently, so draining the book must floor the centering term rather
    // than abort a close.
    grid.refresh(&pricer, frozen_grid_fixture::ratios());
    close_seeded_orders(&mut grid);
    assert_eq!(grid.current_frozen_expected_payout(), 0);

    destroy(grid);
    cleanup(fx, oracle, harness);
}

#[test]
fun refresh_rebuilds_a_loaded_book_without_reading_the_payout_tree() {
    let (mut fx, oracle, harness) = new_harness(impact_config(IMPACT_MAX_RATE));
    let pricer = fx.load_pricer_bundle(&oracle);
    let mut grid = inventory_grid::initialize(&pricer, frozen_grid_fixture::ratios());

    // Many `(lower, +inf]` orders on distinct boundaries. Against the payout tree
    // each is a stored child; here they are payout change points in one inline
    // vector and no children at all. Every lower tick sits below the fifth-highest
    // grid boundary, so all five tail buckets settle above the whole book.
    let mut index = 0;
    while (index < MANY_ORDERS) {
        open_range(
            &mut grid,
            MANY_ORDER_BASE_TICK + index * MANY_ORDER_TICK_STRIDE,
            constants::pos_inf_tick!(),
            MANY_ORDER_QUANTITY,
        );
        index = index + 1;
    };

    grid.refresh(&pricer, frozen_grid_fixture::ratios());

    let whole_book = MANY_ORDERS * MANY_ORDER_QUANTITY;
    let mut bucket = 100 - 5;
    while (bucket < 100) {
        assert_eq!(grid.bucket_maximum(bucket), whole_book);
        bucket = bucket + 1;
    };
    // Every tail bucket carries the same peak, so the tail average is that peak.
    assert_eq!(grid.k95(), whole_book - grid.current_frozen_expected_payout());

    destroy(grid);
    cleanup(fx, oracle, harness);
}

#[test, expected_failure(abort_code = inventory_grid::EInvalidBucketMass)]
fun refresh_verifies_bucket_mass_against_the_supplied_snapshot() {
    let (mut fx, oracle, mut harness) = new_harness(impact_config(IMPACT_MAX_RATE));
    let pricer = fx.load_pricer_bundle(&oracle);
    harness.exposure.initialize_inventory_grid(&pricer, frozen_grid_fixture::ratios());
    let mut boundaries = frozen_grid_fixture::ratios();
    *boundaries.borrow_mut(1) = (boundaries[1] + boundaries[2]) / 2;
    harness.exposure.refresh_inventory_grid(&pricer, boundaries);
    abort 999
}

#[test]
fun one_ratio_ladder_stays_valid_after_the_forward_moves() {
    let (mut fx, mut oracle, mut harness) = new_harness(impact_config(IMPACT_MAX_RATE));
    let ratios = frozen_grid_fixture::ratios();
    let opening = fx.load_pricer_bundle(&oracle);
    harness.exposure.initialize_inventory_grid(&opening, ratios);

    // Move the forward 1%: four hundred times the drift an absolute-price ladder
    // survives, because a bucket of equal probability mass is only basis points of
    // the forward wide. Ratios are read against whatever forward the transaction
    // resolves, so the same ladder must still verify.
    let moved_forward = test_constants::default_live_price() * 101 / 100;
    // Republished under the unchanged clock, so the SVI anchor and remaining time are
    // untouched and the forward is the only thing that moves.
    let moved_at = fx.clock().timestamp_ms();
    fx.set_bs_forward_for_testing_bundle(&mut oracle, moved_at, moved_forward);
    let moved = fx.load_pricer_bundle(&oracle);
    assert_eq!(moved.forward(), moved_forward);

    harness.exposure.refresh_inventory_grid(&moved, ratios);
    cleanup(fx, oracle, harness);
}

/// The companion to the test above: the same forward move applied to a ladder that
/// names absolute prices does abort, which is what made off-chain boundary
/// generation inoperable against a live pricer.
#[test, expected_failure(abort_code = inventory_grid::EInvalidBucketMass)]
fun the_same_move_invalidates_a_ladder_of_absolute_prices() {
    let (mut fx, mut oracle, mut harness) = new_harness(impact_config(IMPACT_MAX_RATE));
    let ratios = frozen_grid_fixture::ratios();
    let opening = fx.load_pricer_bundle(&oracle);
    harness.exposure.initialize_inventory_grid(&opening, ratios);

    let moved_at = fx.clock().timestamp_ms();
    fx.set_bs_forward_for_testing_bundle(
        &mut oracle,
        moved_at,
        test_constants::default_live_price() * 101 / 100,
    );
    let moved = fx.load_pricer_bundle(&oracle);

    // Rescale so the ladder materializes back to the pre-move absolute prices: the
    // grid an absolute interface would have received after the forward moved 1%.
    let mut stale = vector[];
    let mut index = 0;
    while (index < ratios.length()) {
        stale.push_back(math::mul_div_down(ratios[index], opening.forward(), moved.forward()));
        index = index + 1;
    };
    harness.exposure.refresh_inventory_grid(&moved, stale);
    abort 999
}

#[test, expected_failure(abort_code = strike_exposure::EInventoryGridNotInitialized)]
fun refresh_requires_an_initialized_grid() {
    let (mut fx, oracle, mut harness) = new_harness(impact_config(IMPACT_MAX_RATE));
    let pricer = fx.load_pricer_bundle(&oracle);
    harness.exposure.refresh_inventory_grid(&pricer, frozen_grid_fixture::ratios());
    abort 999
}

#[test, expected_failure(abort_code = strike_exposure::EInventoryGridMarketSettled)]
fun refresh_rejects_a_settled_market() {
    let (mut fx, oracle, mut harness) = new_harness(impact_config(IMPACT_MAX_RATE));
    let pricer = fx.load_pricer_bundle(&oracle);
    harness.exposure.initialize_inventory_grid(&pricer, frozen_grid_fixture::ratios());
    harness.exposure.record_settlement(test_constants::default_live_price());
    harness.exposure.refresh_inventory_grid(&pricer, frozen_grid_fixture::ratios());
    abort 999
}

#[test]
fun slicing_one_order_collects_the_same_charge_as_minting_it_whole() {
    let (mut fx, oracle, harness) = new_harness(impact_config(IMPACT_MAX_RATE));
    let pricer = fx.load_pricer_bundle(&oracle);
    let whole = mint_and_total_charge(&mut fx, &pricer, vector[ONE_ORDER]);
    let sliced = mint_and_total_charge(
        &mut fx,
        &pricer,
        vector[ONE_ORDER / 4, ONE_ORDER / 4, ONE_ORDER / 4, ONE_ORDER / 4],
    );
    // The charge is a difference of one book-level potential, so the intermediate
    // potentials telescope and the split collects exactly the direct transition.
    assert_eq!(sliced, whole);
    cleanup(fx, oracle, harness);
}

#[test]
fun a_book_that_pays_the_same_everywhere_carries_almost_no_capital() {
    let (mut fx, oracle, mut harness) = new_harness(impact_config(IMPACT_MAX_RATE));
    let pricer = fx.load_pricer_bundle(&oracle);
    harness.exposure.initialize_inventory_grid(&pricer, frozen_grid_fixture::ratios());
    let median_tick = test_constants::default_live_price() / TEST_TICK_SIZE;

    let below = harness.exposure.quote_mint_terms(&pricer, 0, median_tick, 0, ONE_ORDER, true);
    harness.exposure.allocate_mint_order(below);
    let one_sided_potential = harness.exposure.inventory_impact_potential();
    assert!(one_sided_potential > 0);

    // The complementary leg pays the same amount at every settlement price, so
    // the worst outcome stops exceeding the ordinary one and the capital the
    // book consumes collapses even though its gross payout has doubled.
    let above = harness
        .exposure
        .quote_mint_terms(&pricer, median_tick, constants::pos_inf_tick!(), 0, ONE_ORDER, true);
    harness.exposure.allocate_mint_order(above);
    assert_eq!(harness.exposure.inventory_impact_potential(), 0);

    cleanup(fx, oracle, harness);
}

#[test]
fun placing_away_from_the_peak_costs_less_than_piling_onto_it() {
    let (mut fx, oracle, mut harness) = new_harness(impact_config(IMPACT_MAX_RATE));
    let pricer = fx.load_pricer_bundle(&oracle);
    harness.exposure.initialize_inventory_grid(&pricer, frozen_grid_fixture::ratios());
    let (peak_lower, peak_higher) = seeded_order_range();
    let peak = harness
        .exposure
        .quote_mint_terms(&pricer, peak_lower, peak_higher, 0, ONE_ORDER, true);
    harness.exposure.allocate_mint_order(peak);

    // Same size, same instant, same book: only the placement differs. Adding to
    // the existing peak raises the worst outcomes directly, while the disjoint
    // range only lifts buckets the tail was not already resting on.
    let pile_on = harness
        .exposure
        .quote_mint_terms(&pricer, peak_lower, peak_higher, 0, ONE_ORDER, true);
    let elsewhere = harness.exposure.quote_mint_terms(&pricer, 1, peak_lower, 0, ONE_ORDER, true);
    assert!(elsewhere.inventory_impact_charge() < pile_on.inventory_impact_charge());

    destroy(pile_on);
    destroy(elsewhere);
    cleanup(fx, oracle, harness);
}

/// Mint `slices` sequentially over one range into a book of their own, and
/// return the inventory impact the whole sequence collected.
fun mint_and_total_charge(fx: &mut OracleFixture, pricer: &Pricer, slices: vector<u64>): u64 {
    let expiry_id = fx.expiry_id();
    let expiry_ms = fx.expiry();
    let mut exposure = strike_exposure::new(
        expiry_id,
        impact_config(IMPACT_MAX_RATE),
        TEST_TICK_SIZE,
        TEST_ADMISSION_TICK_SIZE,
        expiry_ms - test_constants::default_cadence_period_ms(),
        fx.scenario_mut().ctx(),
    );
    exposure.initialize_inventory_grid(pricer, frozen_grid_fixture::ratios());
    let (lower, higher) = seeded_order_range();

    let mut total = 0;
    slices.do!(|quantity| {
        let terms = exposure.quote_mint_terms(pricer, lower, higher, 0, quantity, true);
        total = total + terms.inventory_impact_charge();
        exposure.allocate_mint_order(terms);
    });

    destroy(exposure);
    total
}

/// Quote and commit one open, returning the centering delta it moved.
fun open_range(grid: &mut InventoryGrid, lower: u64, higher: u64, quantity: u64): u64 {
    let expected = grid
        .quote_open(lower, higher, quantity, TEST_TICK_SIZE)
        .frozen_expected_payout_delta();
    grid.apply_change(lower, higher, quantity, expected, true, TEST_TICK_SIZE);
    expected
}

/// Quote and commit one close, returning the centering delta it moved.
fun close_range(grid: &mut InventoryGrid, lower: u64, higher: u64, quantity: u64): u64 {
    let expected = grid
        .quote_close(lower, higher, quantity, TEST_TICK_SIZE)
        .frozen_expected_payout_delta();
    grid.apply_change(lower, higher, quantity, expected, false, TEST_TICK_SIZE);
    expected
}

/// Largest payout any bucket carries, which is the book's peak as the grid sees it.
fun book_peak(grid: &InventoryGrid): u64 {
    let mut peak = 0;
    let mut index = 0;
    while (index < 100) {
        let maximum = grid.bucket_maximum(index);
        if (maximum > peak) peak = maximum;
        index = index + 1;
    };
    peak
}

/// Two overlapping ranges opened through the ordinary incremental path, so a
/// refresh has a real book to re-integrate.
fun seeded_grid(pricer: &Pricer): InventoryGrid {
    let mut grid = inventory_grid::initialize(pricer, frozen_grid_fixture::ratios());
    let (lower, higher) = seeded_order_range();
    let mut index = 0;
    while (index < 2) {
        open_range(&mut grid, lower + index, higher, ONE_ORDER);
        index = index + 1;
    };
    grid
}

fun close_seeded_orders(grid: &mut InventoryGrid) {
    let (lower, higher) = seeded_order_range();
    let mut index = 0;
    while (index < 2) {
        close_range(grid, lower + index, higher, ONE_ORDER);
        index = index + 1;
    };
}

fun seeded_order_range(): (u64, u64) {
    (test_constants::default_live_price() / TEST_TICK_SIZE, constants::pos_inf_tick!() - 1)
}

fun every_bucket_maximum(grid: &InventoryGrid): vector<u64> {
    let mut maxima = vector[];
    let mut index = 0;
    while (index < 100) {
        maxima.push_back(grid.bucket_maximum(index));
        index = index + 1;
    };
    maxima
}

fun new_harness(config: StrikeExposureConfig): (OracleFixture, OracleBundle, ExposureHarness) {
    let mut fx = oracle_fixture::setup_oracle(
        test_constants::default_live_price(),
        TEST_TICK_SIZE,
        test_constants::short_expiry_ms(),
    );
    let expiry_id = fx.expiry_id();
    let expiry_ms = fx.expiry();
    fx.scenario_mut().next_tx(test_constants::admin());
    let id = object::new(fx.scenario_mut().ctx());
    let harness_id = id.to_inner();
    let exposure = strike_exposure::new(
        expiry_id,
        config,
        TEST_TICK_SIZE,
        TEST_ADMISSION_TICK_SIZE,
        expiry_ms - test_constants::default_cadence_period_ms(),
        fx.scenario_mut().ctx(),
    );
    transfer::share_object(ExposureHarness { id, exposure });
    fx.scenario_mut().next_tx(test_constants::admin());
    let harness = fx.scenario_mut().take_shared_by_id<ExposureHarness>(harness_id);
    let mut oracle = fx.take_oracle_bundle();
    fx.prepare_live_oracle_bundle(&mut oracle, test_constants::default_live_price());
    (fx, oracle, harness)
}

fun cleanup(fx: OracleFixture, oracle: OracleBundle, harness: ExposureHarness) {
    return_shared(harness);
    oracle_fixture::return_oracle_bundle(oracle);
    fx.finish();
}

fun impact_config(max_rate: u64): StrikeExposureConfig {
    let mut config = strike_exposure_config::new();
    config.set_inventory_impact_max_rate(max_rate);
    config.set_inventory_impact_scale(IMPACT_SCALE);
    config
}
