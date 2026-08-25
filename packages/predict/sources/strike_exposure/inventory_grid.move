// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Ratio-axis 1%-probability inventory grid for one expiry exposure book.
///
/// The keeper inverts the live 1% CDF off-chain. Create mass-checks the 99
/// `strike / forward` rungs, stores them and their logs, and freezes the SVI
/// shape. Later quotes add each stored `ln(ratio)` to the live `ln(forward)`
/// and read the book through the inline cell mirror, so spot moving does not
/// require a keeper. The grid never touches the payout tree: the tree is the
/// source of truth for settlement backing and NAV.
module deepbook_predict::inventory_grid;

use deepbook_predict::{
    constants,
    inventory_cells::{Self, InventoryCells},
    pricing::{Self, FrozenPricer, Pricer},
    range_codec
};
use fixed_math::{i64::I64, math};

const EInvalidBoundaryCount: u64 = 0;
const EInvalidBoundary: u64 = 1;
const EInvalidBucketMass: u64 = 2;

/// 100 equal-probability settlement buckets. `K` averages the worst
/// `tail_bucket_count` and subtracts expected payout.
macro fun bucket_count(): u64 { 100 }

macro fun tail_bucket_count(): u64 { 5 }

/// Target bucket mass and invert check, FLOAT_SCALING: 1% ± 1 bp.
macro fun target_bucket_mass(): u64 { 10_000_000 }

macro fun bucket_mass_tolerance(): u64 { 100_000 }

#[test_only]
macro fun bisection_passes(): u64 { 40 }

/// Early-exit inside half the 1 bp mass check so two adjacent invert
/// residuals still pass `verified_snapshot`.
#[test_only]
macro fun invert_price_tolerance(): u64 { 50_000 }

/// Ratio search bracket: `1 / bracket_multiple` .. `bracket_multiple`.
#[test_only]
macro fun bracket_multiple(): u64 { 10_000 }

/// After the first rung, grow the high side by this many last-steps so a
/// widening tail still sits inside the bracket.
#[test_only]
macro fun search_high_step_multiple(): u64 { 4 }

/// Floor on that high-side room, FLOAT_SCALING: 10 bp of forward.
#[test_only]
macro fun search_high_min_room(): u64 { 1_000_000 }

/// One ratio ladder plus the payout mirror read under it.
///
/// `ratios` stay fixed after initialize. Quote cuts add each stored
/// `ln(ratio)` to the live `ln(forward)` rather than logging `ratio × F`
/// again: both logs already live in 1e9-scaled value space, so ATM is
/// `ln(forward)` exactly. The cell lattice is absolute log-price, fixed at
/// initialize, and carries the book.
///
/// `frozen_expected_payout` is the quote centering term: opens and closes move
/// it by the snapped cell-span mass under that quote's (frozen shape, live
/// forward) view. Quotes use this stored sum rather than re-integrating the
/// lattice, so a later mint does not price one digital per book edge. When
/// the forward moves, the term is the path of those increments, not the
/// current-view integral. A close that empties the mirror clears it.
public struct InventoryGrid has drop, store {
    /// Interior 1%..99% rungs as `strike / forward`, 1e9-scaled.
    ratios: vector<u64>,
    /// `ln(ratios[i])`, taken once at initialize so a later quote does not.
    ln_ratios: vector<I64>,
    frozen_pricer: FrozenPricer,
    frozen_expected_payout: u64,
    cells: InventoryCells,
}

/// Prospective capital facts for one range transition.
public struct InventoryChange has drop {
    before_k: u64,
    after_k: u64,
    frozen_expected_payout_delta: u64,
}

public(package) fun before_k(change: &InventoryChange): u64 {
    change.before_k
}

public(package) fun after_k(change: &InventoryChange): u64 {
    change.after_k
}

public(package) fun frozen_expected_payout_delta(change: &InventoryChange): u64 {
    change.frozen_expected_payout_delta
}

public(package) fun k95(grid: &InventoryGrid): u64 {
    grid.capital_from_starts(
        &grid.cut_bucket_cells(&grid.frozen_pricer.frozen_ln_forward()),
        0,
        0,
        0,
        true,
        grid.frozen_expected_payout,
    )
}

public(package) fun frozen_expected_payout(
    grid: &InventoryGrid,
    lower_tick: u64,
    higher_tick: u64,
    quantity: u64,
    tick_size: u64,
): u64 {
    let (start, stop) = grid.range_cells(lower_tick, higher_tick, tick_size);
    let probability = grid.cells.span_probability(&grid.frozen_pricer, start, stop);
    math::mul_down(probability, quantity)
}

/// Invert the live surface into the 99 interior 1% rungs and freeze them.
///
/// Production pushes an off-chain ladder into `initialize`. Tests use this
/// when they need a valid grid without carrying 99 ratios.
#[test_only]
public(package) fun from_pricer(pricer: &Pricer): InventoryGrid {
    initialize(pricer, invert_quantile_ratios(pricer))
}

/// Freeze a supplied ratio ladder after the 1% ± 1 bp mass check.
public(package) fun initialize(pricer: &Pricer, ratios: vector<u64>): InventoryGrid {
    let boundaries = materialized_ladder(pricer.forward(), &ratios);
    let frozen_pricer = verified_snapshot(pricer, &boundaries);
    // The lattice is spanned from the finite ends of the creation ladder and is
    // never re-cut: re-binning the book would be the tree read the cells avoid.
    let cells = inventory_cells::new(boundaries[1], boundaries[bucket_count!() - 1]);
    let ln_ratios = ln_ratio_ladder(&ratios);

    InventoryGrid {
        ratios,
        ln_ratios,
        frozen_pricer,
        frozen_expected_payout: 0,
        cells,
    }
}

public(package) fun quote_open(
    grid: &InventoryGrid,
    pricer: &Pricer,
    lower_tick: u64,
    higher_tick: u64,
    quantity: u64,
    tick_size: u64,
): InventoryChange {
    grid.quote_change(pricer, lower_tick, higher_tick, quantity, true, tick_size)
}

/// The removed expected payout is re-derived from the quote's live-forward view
/// rather than read from a value stored at open, so a close stays consistent
/// with the pointer the rest of the transition is priced under.
public(package) fun quote_close(
    grid: &InventoryGrid,
    pricer: &Pricer,
    lower_tick: u64,
    higher_tick: u64,
    quantity: u64,
    tick_size: u64,
): InventoryChange {
    grid.quote_change(pricer, lower_tick, higher_tick, quantity, false, tick_size)
}

/// Commit one already-quoted transition into the payout mirror.
public(package) fun apply_change(
    grid: &mut InventoryGrid,
    lower_tick: u64,
    higher_tick: u64,
    quantity: u64,
    frozen_expected_payout_delta: u64,
    adding: bool,
    tick_size: u64,
) {
    let (start, stop) = grid.range_cells(lower_tick, higher_tick, tick_size);
    grid.cells.apply_span(start, stop, quantity, adding);

    if (adding) {
        grid.frozen_expected_payout = grid.frozen_expected_payout + frozen_expected_payout_delta;
    } else if (grid.cells.is_empty()) {
        grid.frozen_expected_payout = 0;
    } else {
        grid.frozen_expected_payout =
            grid.frozen_expected_payout.saturating_sub(frozen_expected_payout_delta);
    };
}

fun quote_change(
    grid: &InventoryGrid,
    pricer: &Pricer,
    lower_tick: u64,
    higher_tick: u64,
    quantity: u64,
    adding: bool,
    tick_size: u64,
): InventoryChange {
    let view = pricing::inventory_view(&grid.frozen_pricer, pricer);
    let (start, stop) = grid.range_cells(lower_tick, higher_tick, tick_size);
    let frozen_expected_payout_delta = math::mul_down(
        grid.cells.span_probability(&view, start, stop),
        quantity,
    );
    // Stored increment, not a live lattice integral: re-pricing every distinct
    // cell edge was the later-mint slope. Same-forward slices still telescope;
    // a moved forward leaves E as the path of prior increments.
    let before_expected = grid.frozen_expected_payout;
    let after_expected = if (adding) {
        before_expected + frozen_expected_payout_delta
    } else {
        before_expected.saturating_sub(frozen_expected_payout_delta)
    };
    // One cut serves both coordinates: the live forward does not change between
    // them, and logging the ladder twice was the later-mint gas regression.
    let starts = grid.cut_bucket_cells(&pricer.ln_forward());

    InventoryChange {
        before_k: grid.capital_from_starts(&starts, 0, 0, 0, true, before_expected),
        after_k: grid.capital_from_starts(
            &starts,
            start,
            stop,
            quantity,
            adding,
            after_expected,
        ),
        frozen_expected_payout_delta,
    }
}

/// Average of the five largest bucket maxima, less the centering term.
///
/// Every bucket carries 1% of the settlement distribution's probability mass
/// along the ratio axis, so the worst 5% of outcomes is the five largest
/// buckets. `starts` is the live-forward cut, taken once per quote. Passing a
/// non-empty `[range_start, range_stop)` scores the book as if `quantity` were
/// added to or removed from those cells.
fun capital_from_starts(
    grid: &InventoryGrid,
    starts: &vector<u64>,
    range_start: u64,
    range_stop: u64,
    quantity: u64,
    adding: bool,
    expected_payout: u64,
): u64 {
    let mut maxima = vector[];
    let mut index = 0;
    while (index < bucket_count!()) {
        let start = starts[index].min(inventory_cells::cell_count!() - 1);
        // A bucket narrower than one cell still scores that cell: late in a market's
        // life the quantiles contract inside a lattice that cannot contract with them.
        let stop = starts[index + 1].max(start + 1);
        maxima.push_back(grid
            .cells
            .span_max(start, stop, range_start, range_stop, quantity, adding));
        index = index + 1;
    };
    capital_from_components(maxima, expected_payout)
}

/// The tail average less the centering term, over already-collected bucket maxima.
public(package) fun capital_from_components(
    bucket_maxima: vector<u64>,
    frozen_expected_payout: u64,
): u64 {
    let mut top = vector[0, 0, 0, 0, 0];
    let mut index = 0;
    while (index < bucket_maxima.length()) {
        let value = bucket_maxima[index];
        let mut minimum_index = 0;
        let mut tail_index = 1;
        while (tail_index < tail_bucket_count!()) {
            if (top[tail_index] < top[minimum_index]) {
                minimum_index = tail_index;
            };
            tail_index = tail_index + 1;
        };
        if (value > top[minimum_index]) {
            *top.borrow_mut(minimum_index) = value;
        };
        index = index + 1;
    };

    let mut sum = 0u128;
    index = 0;
    while (index < tail_bucket_count!()) {
        sum = sum + (top[index] as u128);
        index = index + 1;
    };
    let tail_average = (sum / (tail_bucket_count!() as u128)) as u64;
    tail_average.saturating_sub(frozen_expected_payout)
}

/// Invert the 1%..99% survival targets as `strike / forward`, 1e9-scaled.
///
/// Production does not run this. Tests and the off-chain float twin produce
/// the ladder; on-chain work is the mass check in `initialize`.
#[test_only]
fun invert_quantile_ratios(pricer: &Pricer): vector<u64> {
    let forward = pricer.forward();
    let scale = math::float_scaling!();
    let high_cap = high_bracket(scale);
    let mut search_low = (scale / bracket_multiple!()).max(1);
    let mut ratios = vector[];
    let mut index = 1;
    while (index < bucket_count!()) {
        let target = scale - index * target_bucket_mass!();
        // Bisect the stored ratio, and price the rematerialized strike
        // `mul_down(ratio, forward)` so the mass check sees the same rung.
        // The high side tracks the last step: a fixed `10_000×` cap puts
        // every geometric mid near `100×` forward and wastes most digitals
        // walking back.
        let search_high = next_search_high(&ratios, high_cap);
        let ratio = ratio_at_up_price(
            pricer,
            forward,
            target,
            search_low,
            search_high,
            high_cap,
        );
        assert!(ratio > 0, EInvalidBoundary);
        if (ratios.length() > 0) {
            assert!(ratio > ratios[ratios.length() - 1], EInvalidBoundary);
        };
        ratios.push_back(ratio);
        search_low = ratio;
        index = index + 1;
    };
    ratios
}

/// Local high for the next 1% quantile. The first rung still uses the
/// full cap; later rungs sit just above the last ratio.
#[test_only]
fun next_search_high(ratios: &vector<u64>, high_cap: u64): u64 {
    let n = ratios.length();
    if (n == 0) return high_cap;
    let last = ratios[n - 1];
    if (last >= high_cap) return high_cap;
    let room = if (n == 1) {
        (last / 4).max(1)
    } else {
        let step = last - ratios[n - 2];
        (step * search_high_step_multiple!()).max(search_high_min_room!()).max(1)
    };
    let max_room = high_cap - last;
    if (room >= max_room) high_cap else last + room
}

#[test_only]
fun ratio_at_up_price(
    pricer: &Pricer,
    forward: u64,
    target: u64,
    mut low: u64,
    mut high: u64,
    high_cap: u64,
): u64 {
    // A short high that is still too cheap (UP above the target) means
    // the quantile is above it. Fall back to the full cap rather than
    // returning a low rung that fails the mass check.
    if (high < high_cap && high > low) {
        let up_high = pricer.up_price(
            range_codec::strike_from_raw_boundary(math::mul_down(high, forward)),
        );
        if (up_high.diff(target) <= invert_price_tolerance!()) return high;
        if (up_high > target) {
            high = high_cap;
        };
    };
    let mut pass = 0;
    while (pass < bisection_passes!()) {
        if (high - low <= 1) return geometric_mid(low, high);
        let mid = geometric_mid(low, high);
        if (mid == low || mid == high) return mid;
        let up = pricer.up_price(
            range_codec::strike_from_raw_boundary(math::mul_down(mid, forward)),
        );
        if (up.diff(target) <= invert_price_tolerance!()) return mid;
        if (up > target) {
            low = mid;
        } else {
            high = mid;
        };
        pass = pass + 1;
    };
    geometric_mid(low, high)
}

#[test_only]
fun high_bracket(scale: u64): u64 {
    let max = std::u64::max_value!();
    if (scale > max / bracket_multiple!()) max else scale * bracket_multiple!()
}

#[test_only]
fun geometric_mid(low: u64, high: u64): u64 {
    (math::sqrt_u128_down((low as u128) * (high as u128)) as u64)
}

/// Turn stored forward-relative quantiles into dollar rungs at `forward`.
///
/// The 99 interior boundaries are `strike / forward`, 1e9-scaled, and the open
/// ends are the sentinels. Pricing reads a strike only as `ln(strike) - ln(forward)`,
/// so a bucket's mass is a function of these ratios alone. Initialize verifies
/// that once; every later quote rematerializes the same ratios against the live
/// forward.
fun materialized_ladder(forward: u64, ratios: &vector<u64>): vector<u64> {
    assert!(ratios.length() == bucket_count!() - 1, EInvalidBoundaryCount);
    let mut boundaries = vector[constants::neg_inf!()];
    let mut index = 0;
    while (index < ratios.length()) {
        // Flooring is deliberate and shared with pricing's own scaling: the residual
        // is a billionth of the forward, four orders of magnitude inside the mass
        // tolerance, and `verified_snapshot` re-prices whatever this produces.
        boundaries.push_back(math::mul_down(ratios[index], forward));
        index = index + 1;
    };
    boundaries.push_back(constants::pos_inf!());
    boundaries
}

/// Freeze `pricer` and verify every bucket the boundaries cut carries the 1%
/// probability mass the tail average assumes.
///
/// Length and complete coverage of the settlement line are not re-checked here:
/// `materialized_ladder` is the only producer, it owns the count, and it supplies
/// the open ends itself. Strict monotonicity is checked, because a caller's ratios
/// can still arrive out of order or collide when scaled.
fun verified_snapshot(pricer: &Pricer, boundaries: &vector<u64>): FrozenPricer {
    let frozen_pricer = pricing::snapshot_for_inventory(pricer);
    // The buckets partition the line, so each interior boundary is one bucket's top
    // and the next one's bottom. Carrying its UP price down the ladder prices every
    // boundary once; a `frozen_range_price` per bucket prices all 99 finite ones
    // twice.
    let mut lower_up_price = frozen_pricer.frozen_up_price(
        range_codec::strike_from_raw_boundary(boundaries[0]),
    );
    let mut index = 0;
    while (index < bucket_count!()) {
        assert!(boundaries[index] < boundaries[index + 1], EInvalidBoundary);
        let higher_up_price = frozen_pricer.frozen_up_price(
            range_codec::strike_from_raw_boundary(boundaries[index + 1]),
        );
        // Floored for the reason `compute_range_price` floors: fixed-point error or a
        // non-monotone surface can invert two adjacent boundary probabilities, and an
        // inverted pair is a mass far outside tolerance either way.
        let mass = lower_up_price.saturating_sub(higher_up_price);
        assert!(mass.diff(target_bucket_mass!()) <= bucket_mass_tolerance!(), EInvalidBucketMass);
        lower_up_price = higher_up_price;
        index = index + 1;
    };
    frozen_pricer
}

/// Cell index of every boundary in the ladder, taken once per quote.
///
/// Interior rungs are `ln(ratio_i) + ln(F)`. Both logs are already 1e9-scaled
/// values, so a unit ratio is `ln(F)` and no extra `ln(1e9)` subtract appears.
/// Sentinels are the open lattice ends and do not go through the logarithm.
fun cut_bucket_cells(grid: &InventoryGrid, ln_forward: &I64): vector<u64> {
    assert!(grid.ln_ratios.length() == bucket_count!() - 1, EInvalidBoundaryCount);
    let mut starts = vector[0];
    let mut index = 0;
    while (index < grid.ln_ratios.length()) {
        let price_ln = grid.ln_ratios[index].add(ln_forward);
        starts.push_back(grid.cells.boundary_index_from_ln(&price_ln));
        index = index + 1;
    };
    starts.push_back(inventory_cells::cell_count!());
    starts
}

fun ln_ratio_ladder(ratios: &vector<u64>): vector<I64> {
    let mut ln_ratios = vector[];
    let mut index = 0;
    while (index < ratios.length()) {
        ln_ratios.push_back(math::ln(ratios[index]));
        index = index + 1;
    };
    ln_ratios
}

fun range_cells(
    grid: &InventoryGrid,
    lower_tick: u64,
    higher_tick: u64,
    tick_size: u64,
): (u64, u64) {
    let lower = raw_boundary_from_tick(lower_tick, tick_size);
    let higher = raw_boundary_from_tick(higher_tick, tick_size);
    grid.cells.cell_span(lower, higher)
}

fun raw_boundary_from_tick(tick: u64, tick_size: u64): u64 {
    if (tick == 0) return constants::neg_inf!();
    if (tick == constants::pos_inf_tick!()) return constants::pos_inf!();
    tick * tick_size
}

#[test_only]
public(package) fun bucket_maximum(grid: &InventoryGrid, index: u64): u64 {
    let starts = grid.cut_bucket_cells(&grid.frozen_pricer.frozen_ln_forward());
    bucket_maximum_at(grid, &starts, index)
}

#[test_only]
public(package) fun book_peak(grid: &InventoryGrid): u64 {
    let starts = grid.cut_bucket_cells(&grid.frozen_pricer.frozen_ln_forward());
    let mut peak = 0;
    let mut index = 0;
    while (index < bucket_count!()) {
        let maximum = bucket_maximum_at(grid, &starts, index);
        if (maximum > peak) peak = maximum;
        index = index + 1;
    };
    peak
}

#[test_only]
fun bucket_maximum_at(grid: &InventoryGrid, starts: &vector<u64>, index: u64): u64 {
    let start = starts[index].min(inventory_cells::cell_count!() - 1);
    let stop = starts[index + 1].max(start + 1);
    grid.cells.span_max(start, stop, 0, 0, 0, true)
}

#[test_only]
public(package) fun boundary(grid: &InventoryGrid, index: u64): u64 {
    materialized_ladder(grid.frozen_pricer.frozen_forward(), &grid.ratios)[index]
}

#[test_only]
public(package) fun current_frozen_expected_payout(grid: &InventoryGrid): u64 {
    grid.frozen_expected_payout
}

#[test_only]
public(package) fun cells(grid: &InventoryGrid): &InventoryCells {
    &grid.cells
}

#[test_only]
public(package) fun ratios(grid: &InventoryGrid): vector<u64> {
    grid.ratios
}
