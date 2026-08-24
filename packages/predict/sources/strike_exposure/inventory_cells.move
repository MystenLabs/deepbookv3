// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Inline fixed-cell mirror of one expiry book's payout profile.
///
/// The inventory coordinate needs the whole payout curve at once: a refresh
/// rebuilds every bucket maximum and the centering expectation. Reading that from
/// `StrikePayoutTree` costs one dynamic-field child per distinct strike, against a
/// per-transaction object-cache ceiling that coincides with
/// `constants::max_payout_tree_nodes`, so a market at its permitted maximum cannot
/// be refreshed at all. A `vector` held inline in the market object costs no
/// children, which removes that ceiling by construction rather than by tuning.
///
/// The price is resolution. The lattice is fixed at initialization while the
/// settlement distribution narrows toward expiry, so an order boundary is rounded
/// to the nearest cell edge and two boundaries inside one cell collapse into one.
/// `predeploy/evidence/p32-cell-array-sizing-2026-08-20.md` sizes that error
/// against reading the tree.
///
/// The payout tree remains the source of truth for settlement backing and NAV.
/// Nothing here is read for solvency; it exists only to carry the inventory
/// coordinate, which is already an average of five range maxima over
/// 1%-probability buckets and so tolerates a coarse substitute that the flush
/// cannot.
module deepbook_predict::inventory_cells;

use deepbook_predict::{constants, pricing::FrozenPricer, range_codec};
use fixed_math::{i64::{Self, I64}, math};

const EInvalidCellSpan: u64 = 0;

/// Cells per market. At the three-hour horizon the grid lane operates on, 2,048
/// geometric cells over the span below are ~0.4 basis points each, which held
/// median per-trade charge error against a tree read to 1.6% or better through 90%
/// of market life. 512 and 1,024 were measured too and are worse at every horizon;
/// this is one `u64` each, so the whole mirror is 16 KB inline.
public(package) macro fun cell_count(): u64 { 2048 }

/// Half-span of the lattice as a multiple of the submitted quantile ladder's own
/// half-width. The ladder spans the 1st to 99th percentile, which is ±2.326
/// standard deviations, and the sizing run used ±4, so the lattice is stretched by
/// 4 / 2.326. Spot leaving the span is not a correctness problem — the two end
/// cells absorb everything outside it — but resolution there collapses to one
/// cell, so the span buys drift headroom at the cost of cell width.
macro fun span_numerator(): u64 { 172 }

macro fun span_denominator(): u64 { 100 }

/// Floor on cell width in log space, 1e9-scaled, so the lattice is never finer than
/// the logarithm that indexes it can resolve. `math::ln` targets 1e-7 relative error
/// on its result, and a result of magnitude ~25 is the worst case across the
/// representable price domain, which leaves ~2.5e-6 of absolute log error; cells
/// below that would be indexed arbitrarily. 4e-6 keeps margin. At the horizons the
/// grid lane operates on the span-derived width is an order of magnitude above this,
/// so the floor binds only on a distribution too narrow to partition usefully at
/// all, where it degrades resolution instead of destroying ordering.
macro fun min_step_ln(): u64 { 4_000 }

/// A fixed geometric lattice plus the payout owed in each of its cells.
///
/// Boundary `j` for `1 <= j <= cell_count - 1` sits at
/// `exp(anchor_ln + (j - 1) * step_ln)`; boundary `0` is the open bottom and
/// boundary `cell_count` the open top. Cell `i` is `(boundary_i, boundary_{i+1}]`,
/// matching the payout tree's half-open convention, and holds an absolute
/// non-negative payout rather than a signed delta, so no intermediate can
/// underflow.
///
/// Uniform spacing in the log of price, rather than in price, is what makes every
/// cell the same width in relative terms. A bucket therefore sees the same cell
/// resolution wherever the forward has moved to, so fidelity is invariant to spot
/// inside the span. This is the same property that makes the boundary ratios work,
/// arriving for the same reason.
public struct InventoryCells has drop, store {
    anchor_ln: I64,
    step_ln: u64,
    values: vector<u64>,
    /// Count of cells with a nonzero payout. A close that returns this to zero
    /// has emptied the mirror, so the centering term can be cleared rather than
    /// left holding walk-versus-incremental dust.
    occupied: u64,
}

/// Build an empty lattice around the quantile ladder the caller submitted.
///
/// Only ever called with an empty book, because grid initialization requires one,
/// so the cells start at zero and no bulk import from the tree is needed. The
/// lattice is never re-cut afterwards: re-cutting would mean re-binning the book,
/// which is the tree read this exists to avoid.
public(package) fun new(lowest_boundary: u64, highest_boundary: u64): InventoryCells {
    assert!(constants::neg_inf!() < lowest_boundary, EInvalidCellSpan);
    assert!(lowest_boundary < highest_boundary, EInvalidCellSpan);
    assert!(highest_boundary < constants::pos_inf!(), EInvalidCellSpan);

    let lowest_ln = math::ln(lowest_boundary);
    let ladder_width = math::ln(highest_boundary).sub(&lowest_ln);
    assert!(!ladder_width.is_negative() && ladder_width.magnitude() > 0, EInvalidCellSpan);

    // `cell_count - 1` finite boundaries leave `cell_count - 2` gaps across the span,
    // and the floor widens the whole lattice rather than truncating it, so the ladder
    // always sits inside the span with the surplus split evenly either side.
    let target_span = math::mul_div_down(
        ladder_width.magnitude(),
        span_numerator!(),
        span_denominator!(),
    );
    let step_ln = (target_span / (cell_count!() - 2)).max(min_step_ln!());
    let span = step_ln * (cell_count!() - 2);
    let margin = i64::from_u64((span - ladder_width.magnitude()) / 2);
    let anchor_ln = lowest_ln.sub(&margin);

    let mut values = vector[];
    let mut index = 0;
    while (index < cell_count!()) {
        values.push_back(0);
        index = index + 1;
    };

    InventoryCells { anchor_ln, step_ln, values, occupied: 0 }
}

/// The half-open cell span `[start, stop)` a raw interval `(lower, higher]` maps to.
///
/// Both ends snap to the nearest cell boundary. Widening to every touched cell was
/// measured too and is worse on every statistic, not merely more expensive: it
/// inflates the tail and the centering term together and the errors do not cancel.
/// An interval that snaps to nothing still takes one cell, so no order can be
/// recorded as owing nothing anywhere and no bucket can be scored over no cells.
public(package) fun cell_span(cells: &InventoryCells, lower_raw: u64, higher_raw: u64): (u64, u64) {
    let start = cells.boundary_index(lower_raw).min(cell_count!() - 1);
    let stop = cells.boundary_index(higher_raw).max(start + 1).min(cell_count!());
    (start, stop)
}

public(package) fun is_empty(cells: &InventoryCells): bool {
    cells.occupied == 0
}

/// Add or remove one range order's payout across the cells it covers.
public(package) fun apply_span(
    cells: &mut InventoryCells,
    start: u64,
    stop: u64,
    quantity: u64,
    adding: bool,
) {
    let mut index = start;
    while (index < stop) {
        let current = cells.values[index];
        let next = if (adding) current + quantity else current - quantity;
        if (current == 0 && next > 0) {
            cells.occupied = cells.occupied + 1;
        } else if (current > 0 && next == 0) {
            cells.occupied = cells.occupied - 1;
        };
        *cells.values.borrow_mut(index) = next;
        index = index + 1;
    };
}

/// Largest payout reachable in `[start, stop)`, optionally with `quantity` added to
/// or removed from the cells in `[range_start, range_stop)`.
///
/// Quoting needs a bucket's maximum both before and after a candidate transition
/// without mutating anything, and the adjustment applied here is the same one
/// `apply_span` commits, so a quote and its commit cannot disagree about which
/// cells an order covers. Pass a zero-width range to read the current maximum.
public(package) fun span_max(
    cells: &InventoryCells,
    start: u64,
    stop: u64,
    range_start: u64,
    range_stop: u64,
    quantity: u64,
    adding: bool,
): u64 {
    let mut maximum = 0;
    let mut index = start;
    while (index < stop) {
        let mut value = cells.values[index];
        if (index >= range_start && index < range_stop) {
            value = if (adding) value + quantity else value - quantity;
        };
        if (value > maximum) maximum = value;
        index = index + 1;
    };
    maximum
}

/// Frozen probability mass of the half-open cell span `[start, stop)`.
///
/// This is the same mass `expected_payout` attributes to those cells: survival at
/// the start edge minus survival at the stop edge. Opens and closes accumulate
/// `quantity` times this mass so the incremental centering term and a same-snapshot
/// refresh stay in the same units. Open ends are exact: cell zero begins at
/// probability one and the last cell ends at probability zero.
public(package) fun span_probability(
    cells: &InventoryCells,
    pricer: &FrozenPricer,
    start: u64,
    stop: u64,
): u64 {
    let lower_up = if (start == 0) {
        math::float_scaling!()
    } else {
        pricer.frozen_up_price(
            range_codec::strike_from_raw_boundary(cells.boundary_price(start)),
        )
    };
    let higher_up = if (stop >= cell_count!()) {
        0
    } else {
        pricer.frozen_up_price(
            range_codec::strike_from_raw_boundary(cells.boundary_price(stop)),
        )
    };
    lower_up.saturating_sub(higher_up)
}

/// Probability-weighted payout across the whole lattice under `pricer`.
///
/// A piecewise-constant profile integrates as its own boundary deltas against the
/// survival function: `E = v_0 + sum_j (v_j - v_{j-1}) * P(settlement > edge_j)`,
/// with the bottom cell carrying probability one. Only a cell whose payout differs
/// from its neighbour contributes, so this costs one digital price per distinct
/// snapped order boundary rather than one per cell — the same count the payout
/// tree's own walk pays, with no children loaded.
public(package) fun expected_payout(cells: &InventoryCells, pricer: &FrozenPricer): u64 {
    let mut credit = cells.values[0] as u128;
    let mut debit = 0u128;
    let mut index = 1;
    while (index < cell_count!()) {
        let previous = cells.values[index - 1];
        let current = cells.values[index];
        if (current != previous) {
            let up_price = pricer.frozen_up_price(
                range_codec::strike_from_raw_boundary(cells.boundary_price(index)),
            );
            if (current > previous) {
                credit = credit + (math::mul_down(current - previous, up_price) as u128);
            } else {
                debit = debit + (math::mul_down(previous - current, up_price) as u128);
            };
        };
        index = index + 1;
    };
    // Expected payout is non-negative in exact arithmetic. Flooring absorbs
    // rounding across the ladder, and it errs the safe way: understating the
    // centering term can only raise the capital coordinate.
    if (credit > debit) ((credit - debit) as u64) else 0
}

/// Nearest lattice boundary index to a raw price, in `0..cell_count`.
///
/// Constant log spacing is what keeps this arithmetic rather than a search: the
/// index is one logarithm, one subtraction and one division, where the payout tree
/// needs a traversal and a stored child per node.
public(package) fun boundary_index(cells: &InventoryCells, raw: u64): u64 {
    if (raw == constants::neg_inf!()) return 0;
    if (raw == constants::pos_inf!()) return cell_count!();

    let offset = math::ln(raw).sub(&cells.anchor_ln);
    // Below the anchor the nearest boundary is the open bottom: cell zero absorbs
    // the whole region under the span, so a lower edge there extends to it and an
    // upper edge there leaves the interval in that one cell.
    if (offset.is_negative()) return 0;
    let steps = (offset.magnitude() + cells.step_ln / 2) / cells.step_ln;
    (steps + 1).min(cell_count!())
}

/// Raw price of lattice boundary `index`, for `1 <= index <= cell_count - 1`.
fun boundary_price(cells: &InventoryCells, index: u64): u64 {
    let offset = i64::from_u64((index - 1) * cells.step_ln);
    math::exp(&cells.anchor_ln.add(&offset))
}

#[test_only]
public(package) fun cell_value(cells: &InventoryCells, index: u64): u64 {
    cells.values[index]
}

#[test_only]
public(package) fun boundary_price_for_testing(cells: &InventoryCells, index: u64): u64 {
    cells.boundary_price(index)
}
