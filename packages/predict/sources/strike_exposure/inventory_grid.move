// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Frozen 1%-probability inventory grid for one expiry exposure book.
///
/// The grid owns a probability partition of the settlement line and reads the book
/// through the inline cell mirror in `inventory_cells`. It never touches the payout
/// tree: the tree is the source of truth for settlement backing and NAV, and
/// reading it here would reintroduce the per-node object-cache ceiling that stops a
/// full book from being refreshed at all.
module deepbook_predict::inventory_grid;

use deepbook_predict::{
    constants,
    inventory_cells::{Self, InventoryCells},
    pricing::{Self, FrozenPricer, Pricer},
    range_codec
};
use fixed_math::math;

const EInvalidBoundaryCount: u64 = 0;
const EInvalidBoundary: u64 = 1;
const EInvalidBucketMass: u64 = 2;

macro fun bucket_count(): u64 { 100 }

macro fun tail_bucket_count(): u64 { 5 }

macro fun target_bucket_mass(): u64 { 10_000_000 }

macro fun bucket_mass_tolerance(): u64 { 100_000 }

/// One probability snapshot plus the payout mirror read under it.
///
/// The snapshot is fixed between refreshes so a transition's charge is a function
/// of the payout book rather than of which live tick it lands on. `refresh` re-cuts
/// the boundaries onto a later snapshot; the cell lattice underneath is fixed at
/// initialization and carries the book across every refresh.
///
/// Bucket maxima are derived from the cells on demand rather than stored, so no
/// rolling summary can survive a boundary re-cut and go stale. `frozen_expected_payout`
/// is the one carried value, and it is only ever a centering term for the tail
/// average: opens and closes move it by the snapped cell-span mass under the current
/// snapshot, and `refresh` replaces it with the mirror's own integral under the new
/// one. Those two groupings floor at different points, so closes subtract saturating,
/// and a close that empties the mirror clears the term outright.
public struct InventoryGrid has store {
    /// Raw settlement-price quantiles; bucket i is `(boundaries[i], boundaries[i + 1]]`.
    boundaries: vector<u64>,
    /// Cell index each boundary snaps to, re-cut whenever the boundaries are. Held
    /// so a quote reads a bucket's cells by index instead of taking a logarithm per
    /// bucket on the hot path.
    bucket_cell_starts: vector<u64>,
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
    grid.capital(0, 0, 0, true, grid.frozen_expected_payout)
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

public(package) fun initialize(pricer: &Pricer, ratios: vector<u64>): InventoryGrid {
    let boundaries = materialized_ladder(pricer, ratios);
    let frozen_pricer = verified_snapshot(pricer, &boundaries);
    // The lattice is spanned from the finite ends of the ladder this cut produced
    // and is never re-cut, so it is anchored to the market's creation surface.
    let cells = inventory_cells::new(boundaries[1], boundaries[bucket_count!() - 1]);
    let bucket_cell_starts = cut_bucket_cells(&cells, &boundaries);

    InventoryGrid {
        boundaries,
        bucket_cell_starts,
        frozen_pricer,
        frozen_expected_payout: 0,
        cells,
    }
}

/// Re-derive the probability partition onto a later snapshot.
///
/// A grid held from market creation forfeits compensation as the settlement
/// distribution narrows around it, so the boundaries are re-cut against the current
/// surface, their cell spans are re-taken, and the centering term is re-integrated
/// over the mirror under the new snapshot. The mirror itself is untouched: it holds
/// the book, not a summary of it, so nothing here can inherit stale rolling state.
///
/// This reads no dynamic-field children at all, which is the whole point. Rebuilding
/// from the payout tree cost one child per distinct strike against a ceiling equal to
/// the tree's own permitted node count, so a market at its maximum could not be
/// refreshed.
public(package) fun refresh(grid: &mut InventoryGrid, pricer: &Pricer, ratios: vector<u64>) {
    let boundaries = materialized_ladder(pricer, ratios);
    let frozen_pricer = verified_snapshot(pricer, &boundaries);

    grid.bucket_cell_starts = cut_bucket_cells(&grid.cells, &boundaries);
    grid.boundaries = boundaries;
    grid.frozen_expected_payout = grid.cells.expected_payout(&frozen_pricer);
    grid.frozen_pricer = frozen_pricer;
}

public(package) fun quote_open(
    grid: &InventoryGrid,
    lower_tick: u64,
    higher_tick: u64,
    quantity: u64,
    tick_size: u64,
): InventoryChange {
    let expected_delta = grid.frozen_expected_payout(lower_tick, higher_tick, quantity, tick_size);
    grid.quote_change(lower_tick, higher_tick, quantity, expected_delta, true, tick_size)
}

/// The removed expected payout is re-derived from the grid's current snapshot rather
/// than read from a value stored at open, so a close stays consistent with the
/// snapshot the rest of the transition is priced under.
public(package) fun quote_close(
    grid: &InventoryGrid,
    lower_tick: u64,
    higher_tick: u64,
    quantity: u64,
    tick_size: u64,
): InventoryChange {
    let expected_delta = grid.frozen_expected_payout(lower_tick, higher_tick, quantity, tick_size);
    grid.quote_change(lower_tick, higher_tick, quantity, expected_delta, false, tick_size)
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
    lower_tick: u64,
    higher_tick: u64,
    quantity: u64,
    frozen_expected_payout_delta: u64,
    adding: bool,
    tick_size: u64,
): InventoryChange {
    let (start, stop) = grid.range_cells(lower_tick, higher_tick, tick_size);
    let after_expected = if (adding) {
        grid.frozen_expected_payout + frozen_expected_payout_delta
    } else {
        grid.frozen_expected_payout.saturating_sub(frozen_expected_payout_delta)
    };

    InventoryChange {
        before_k: grid.k95(),
        after_k: grid.capital(start, stop, quantity, adding, after_expected),
        frozen_expected_payout_delta,
    }
}

/// Average of the five largest bucket maxima, less the centering term.
///
/// Every bucket carries 1% of the settlement distribution's probability mass by
/// construction, so the worst 5% of outcomes is the five largest buckets and the
/// tail is found by counting rather than by integrating a probability. Passing a
/// non-empty `[range_start, range_stop)` scores the book as if `quantity` were
/// added to or removed from those cells, which is how a quote obtains the
/// post-trade coordinate without mutating anything.
fun capital(
    grid: &InventoryGrid,
    range_start: u64,
    range_stop: u64,
    quantity: u64,
    adding: bool,
    expected_payout: u64,
): u64 {
    let mut maxima = vector[];
    let mut index = 0;
    while (index < bucket_count!()) {
        let start = grid.bucket_cell_starts[index].min(inventory_cells::cell_count!() - 1);
        // A bucket narrower than one cell still scores that cell: late in a market's
        // life the quantiles contract inside a lattice that cannot contract with them.
        let stop = grid.bucket_cell_starts[index + 1].max(start + 1);
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

/// Turn caller-supplied forward-relative quantiles into the absolute raw ladder the
/// grid stores.
///
/// Callers submit the 99 interior boundaries as `strike / forward`, 1e9-scaled, and
/// the open ends are supplied by the sentinels rather than by the caller. Pricing
/// reads a strike only as `ln(strike) - ln(forward)`, so a bucket's probability mass
/// is a function of these ratios alone: the same ladder verifies identically no
/// matter where the forward has moved between the caller pricing it and this
/// transaction executing. Absolute boundaries do not have that property, and the
/// equal-mass partition they have to satisfy is roughly two basis points of the
/// forward wide, so submitting absolute prices loses the race against spot.
///
/// The ladder is materialized against this pricer's own forward so everything
/// downstream — bucket cell spans, order bucketing — keeps working in absolute
/// strikes exactly as before.
fun materialized_ladder(pricer: &Pricer, ratios: vector<u64>): vector<u64> {
    assert!(ratios.length() == bucket_count!() - 1, EInvalidBoundaryCount);
    let forward = pricer.forward();
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
    // twice, and this runs on every refresh.
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

/// Cell index of every boundary in the ladder, taken once per cut.
fun cut_bucket_cells(cells: &InventoryCells, boundaries: &vector<u64>): vector<u64> {
    let mut starts = vector[];
    let mut index = 0;
    while (index < boundaries.length()) {
        starts.push_back(cells.boundary_index(boundaries[index]));
        index = index + 1;
    };
    starts
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
    let start = grid.bucket_cell_starts[index].min(inventory_cells::cell_count!() - 1);
    let stop = grid.bucket_cell_starts[index + 1].max(start + 1);
    grid.cells.span_max(start, stop, 0, 0, 0, true)
}

#[test_only]
public(package) fun boundary(grid: &InventoryGrid, index: u64): u64 {
    grid.boundaries[index]
}

#[test_only]
public(package) fun current_frozen_expected_payout(grid: &InventoryGrid): u64 {
    grid.frozen_expected_payout
}

#[test_only]
public(package) fun cells(grid: &InventoryGrid): &InventoryCells {
    &grid.cells
}
