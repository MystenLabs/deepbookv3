// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// The pool's payout profile mirrored on a fixed log-price lattice, priced under
/// a frozen distribution *shape* that re-anchors to the live forward on every
/// read.
///
/// The inventory charge scores how unevenly the pool owes across the settlement
/// prices that carry probability. That needs a probability measure, and the
/// measure has two separable parts: the **shape** of the distribution, and the
/// **price it is centred on**. Only the shape is genuinely expensive to obtain —
/// it comes from the volatility surface — while the centre is the forward, which
/// every trade already carries in its own validated pricer. Freezing both goes
/// stale the moment spot moves; freezing neither needs a keeper. This module
/// freezes the shape and re-anchors the centre, which needs no keeper and stays
/// accurate through large moves.
///
/// The lattice is uniform in log price, and that is what makes re-anchoring
/// free. Under a fixed shape, moving the centre from `F_0` to `F_t` translates
/// the whole mass profile along the log axis by `ln(F_t / F_0)`, so on a uniform
/// log lattice it is an integer **cell shift**. The stored cumulative masses are
/// therefore read at a shifted index rather than recomputed, and no surface
/// evaluation happens after the lattice is built.
///
/// The book itself is stored as two difference arrays. An order over
/// `(lower, higher]` raises the profile at one cell and drops it at another, so
/// a trade touches exactly two entries regardless of how many cells it spans;
/// the profile `W` is their running difference, recovered during the same scan
/// that computes the statistic. `rise` and `fall` accumulate separately because
/// a single cell's net change is signed even though `W` never is.
///
/// The span is measured in the market's own at-the-money volatility, so one
/// constant serves every cadence and price level, and the two end cells are
/// open-ended sentinels: mass beyond the span folds into them, which keeps the
/// measure summing to one under any shift.
module deepbook_predict::inventory_lattice;

use deepbook_predict::{constants, pricing::{Self, Pricer}, range_codec};
use fixed_math::{i64::{Self, I64}, math};

/// Unreachable in production: `pricing` already refuses a non-positive forward
/// before a `Pricer` exists, so this is a leaf-level tripwire on the one input
/// the lattice cannot lay out around. No `expected_failure` test per
/// unit-tests rule 4.
const EInvalidLatticeSpan: u64 = 0;

/// Cells in the lattice, including the two open-ended sentinels. Sized from the
/// measured discretisation error of the statistic against its exact continuous
/// value: at this count the median error is about 1% of the charge and the 99th
/// percentile about 6%, against a charge that is itself a low single-digit
/// percentage of the ordinary trading fee. Doubling it halves the error and
/// doubles the per-trade byte cost.
public(package) macro fun cell_count(): u64 { 256 }

/// Half-span of the lattice in at-the-money total volatilities. The frozen shape
/// keeps almost no mass beyond this, so the sentinels stay nearly empty until
/// the forward itself travels — which is exactly the regime this design exists
/// to survive.
macro fun span_volatilities(): u64 { 10 }

/// Smallest admissible log step, guarding a degenerate zero-volatility surface
/// from collapsing every boundary onto one price.
macro fun min_step_ln(): u64 { 1_000 }

/// The payout profile mirrored on a log-price lattice, with the frozen shape's
/// cumulative mass at each interior boundary.
public struct InventoryLattice has drop, store {
    /// Log price of the lowest interior boundary.
    anchor_ln: I64,
    /// Uniform log-price distance between interior boundaries.
    step_ln: u64,
    /// Log of the forward the shape was frozen against. Re-anchoring measures
    /// every later forward from here.
    frozen_ln_forward: I64,
    /// Frozen cumulative mass at each interior boundary, 1e9-scaled and
    /// non-decreasing: entry `i` is the probability that settlement lands at or
    /// below boundary `i`. Length is `cell_count - 1`.
    boundary_mass: vector<u64>,
    /// Difference arrays for the payout profile: an order raises `rise` at the
    /// cell it starts in and `fall` at the cell it ends in.
    rise: vector<u64>,
    fall: vector<u64>,
}

/// Build the lattice from the first priced trade's own surface.
///
/// The book is empty at this point by construction — this is that market's first
/// mint — so the profile starts at zero and no boundary needs re-binning. The
/// interior boundaries are laid out uniformly in log price across
/// `+/- span_volatilities` of the pricer's at-the-money volatility, and each one
/// records the frozen shape's cumulative mass there. Nothing reads the surface
/// again for the market's life.
public(package) fun initialize(pricer: &Pricer): InventoryLattice {
    let forward = pricer.forward();
    assert!(forward > 0, EInvalidLatticeSpan);
    let volatility = pricer.atm_total_volatility();
    let half_span = math::mul_down(volatility, span_volatilities!() * math::float_scaling!());
    let interior = cell_count!() - 1;
    let step_ln = (2 * half_span / (interior - 1)).max(min_step_ln!());

    let ln_forward = math::ln(forward);
    let anchor_ln = ln_forward.sub(&i64::from_u64(step_ln * ((interior - 1) / 2)));

    let mut boundary_mass = vector[];
    let mut index = 0;
    while (index < interior) {
        let boundary_ln = anchor_ln.add(&i64::from_u64(step_ln * index));
        let price = math::exp(&boundary_ln);
        // The shape is stored as cumulative mass at or below the boundary, the
        // complement of the pricer's own up-digital, so a later read subtracts
        // neighbours instead of re-pricing them.
        let up = pricer.up_price(range_codec::strike_from_raw(price));
        boundary_mass.push_back(math::float_scaling!() - up);
        index = index + 1;
    };

    InventoryLattice {
        anchor_ln,
        step_ln,
        frozen_ln_forward: ln_forward,
        boundary_mass,
        rise: zeroed_cells(),
        fall: zeroed_cells(),
    }
}

fun zeroed_cells(): vector<u64> {
    let mut cells = vector[];
    let mut index = 0;
    while (index < cell_count!()) {
        cells.push_back(0);
        index = index + 1;
    };
    cells
}

/// Fold one range change into the mirrored profile. Two entries move regardless
/// of how many cells the order spans, because the profile is stored as a
/// difference.
public(package) fun apply_range(
    lattice: &mut InventoryLattice,
    lower_tick: u64,
    higher_tick: u64,
    quantity: u64,
    tick_size: u64,
    adding: bool,
) {
    if (quantity == 0) return;
    let start = lattice.cell_of_tick(lower_tick, tick_size);
    let stop = lattice.cell_of_tick(higher_tick, tick_size);
    if (stop <= start) return;

    apply_delta(&mut lattice.rise, start, quantity, adding);
    if (stop < cell_count!()) {
        apply_delta(&mut lattice.fall, stop, quantity, adding);
    };
}

/// The probability-weighted standard deviation of the payout profile, re-anchored
/// to `pricer`'s forward.
public(package) fun deviation(lattice: &InventoryLattice, pricer: &Pricer): u64 {
    let (current, _) = lattice.scan(pricer, 0, 0, 0, true);
    current
}

/// The measure before and after one hypothetical range change, in a single scan.
///
/// Pricing a trade needs both sides under the *same* anchor, and the change is a
/// difference: one entry rises and another falls. Carrying both running profiles
/// through one pass is what lets a quote price a change without copying the
/// mirror or mutating it speculatively.
public(package) fun deviation_pair(
    lattice: &InventoryLattice,
    pricer: &Pricer,
    lower_tick: u64,
    higher_tick: u64,
    quantity: u64,
    tick_size: u64,
    adding: bool,
): (u64, u64) {
    let start = lattice.cell_of_tick(lower_tick, tick_size);
    let stop = lattice.cell_of_tick(higher_tick, tick_size);
    if (stop <= start) {
        let current = lattice.deviation(pricer);
        return (current, current)
    };
    lattice.scan(pricer, start, stop, quantity, adding)
}

/// One pass over the lattice, carrying the profile as it is and as the
/// hypothetical change would leave it, and accumulating both moment pairs
/// against the re-anchored mass.
fun scan(
    lattice: &InventoryLattice,
    pricer: &Pricer,
    start: u64,
    stop: u64,
    quantity: u64,
    adding: bool,
): (u64, u64) {
    lattice.scan_at(lattice.anchor_shift(pricer), start, stop, quantity, adding)
}

fun scan_at(
    lattice: &InventoryLattice,
    shift: I64,
    start: u64,
    stop: u64,
    quantity: u64,
    adding: bool,
): (u64, u64) {
    let mut carried = 0u64;
    let mut changed = 0u64;
    let mut previous_mass = 0u64;
    let mut first = 0u256;
    let mut second = 0u256;
    let mut changed_first = 0u256;
    let mut changed_second = 0u256;
    let mut cell = 0;
    while (cell < cell_count!()) {
        carried = carried + lattice.rise[cell] - lattice.fall[cell];
        changed = changed + lattice.rise[cell] - lattice.fall[cell];
        if (quantity > 0) {
            if (cell == start) {
                changed = if (adding) changed + quantity else changed - quantity;
            };
            if (cell == stop) {
                changed = if (adding) changed - quantity else changed + quantity;
            };
        };

        // Cumulative mass at this cell's upper boundary under the re-anchored
        // measure; the last cell is the open-ended sentinel and closes at one.
        let cumulative = if (cell + 1 == cell_count!()) {
            math::float_scaling!()
        } else {
            lattice.shifted_boundary_mass(cell, shift)
        };
        let mass = cumulative - previous_mass;
        previous_mass = cumulative;
        if (mass > 0) {
            let weight = mass as u256;
            if (carried > 0) {
                let payout = carried as u256;
                first = first + weight * payout;
                second = second + weight * payout * payout;
            };
            if (changed > 0) {
                let payout = changed as u256;
                changed_first = changed_first + weight * payout;
                changed_second = changed_second + weight * payout * payout;
            };
        };
        cell = cell + 1;
    };

    (deviation_from_moments(first, second), deviation_from_moments(changed_first, changed_second))
}

/// Variance in the single-division form the raw scale carries: both moments are
/// 1e9-scaled masses times payouts, so the mean squares to the same scale as
/// `scale * second`. Non-negative by Cauchy-Schwarz for a non-negative measure;
/// the floor absorbs the surface's own rounding dust rather than aborting a quote.
fun deviation_from_moments(first: u256, second: u256): u64 {
    let scale = math::float_scaling!() as u256;
    let numerator = (scale * second).saturating_sub(first * first);
    (math::sqrt_u128_down((numerator / (scale * scale)) as u128) as u64)
}

/// The lattice's own span, for tests and for the creation event.
public(package) fun span_bounds(lattice: &InventoryLattice): (u64, u64) {
    let interior = cell_count!() - 1;
    let top = lattice.anchor_ln.add(&i64::from_u64(lattice.step_ln * (interior - 1)));
    (math::exp(&lattice.anchor_ln), math::exp(&top))
}

/// Cell whose interior boundary first reaches `tick`. Tick zero is the open-lower
/// sentinel and the positive-infinity tick is the open-upper one, so both land on
/// the lattice ends without consulting a boundary.
fun cell_of_tick(lattice: &InventoryLattice, tick: u64, tick_size: u64): u64 {
    if (tick == 0) return 0;
    if (tick >= constants::pos_inf_tick!()) return cell_count!();
    lattice.cell_of_price(tick * tick_size)
}

fun cell_of_price(lattice: &InventoryLattice, price: u64): u64 {
    if (price == 0) return 0;
    let price_ln = math::ln(price);
    let offset = price_ln.sub(&lattice.anchor_ln);
    if (offset.is_negative()) return 0;
    let cells = offset.magnitude() / lattice.step_ln;
    let interior = cell_count!() - 1;
    // A price at or above the top interior boundary belongs to the upper
    // sentinel, whose index is the last cell.
    if (cells >= interior) cell_count!() - 1 else cells + 1
}

/// Frozen cumulative mass read at the re-anchored index. Indices below the
/// lattice read as no mass and indices above it as certainty, which is what
/// folds the shape's tails into the sentinels under any shift.
fun shifted_boundary_mass(lattice: &InventoryLattice, cell: u64, shift: I64): u64 {
    let interior = cell_count!() - 1;
    let index = i64::from_u64(cell).sub(&shift);
    if (index.is_negative()) return 0;
    let index = index.magnitude();
    if (index >= interior) return math::float_scaling!();
    lattice.boundary_mass[index]
}

/// Whole-cell distance from the frozen forward to `pricer`'s own, which is the
/// translation the fixed shape undergoes when it re-anchors.
fun anchor_shift(lattice: &InventoryLattice, pricer: &Pricer): I64 {
    let live_ln = math::ln(pricer.forward());
    let travelled = live_ln.sub(&lattice.frozen_ln_forward);
    let cells = travelled.magnitude() / lattice.step_ln;
    i64::from_parts(cells, travelled.is_negative())
}

fun apply_delta(entries: &mut vector<u64>, index: u64, quantity: u64, adding: bool) {
    let entry = &mut entries[index];
    if (adding) {
        *entry = *entry + quantity;
    } else {
        *entry = *entry - quantity;
    };
}

#[test_only]
/// Total mass under a given re-anchoring, which every shift must leave at
/// certainty: what falls off one end folds into that end's sentinel.
public(package) fun total_mass_at_shift(lattice: &InventoryLattice, shift: I64): u64 {
    let mut previous = 0u64;
    let mut total = 0u64;
    let mut cell = 0;
    while (cell < cell_count!()) {
        let cumulative = if (cell + 1 == cell_count!()) {
            math::float_scaling!()
        } else {
            lattice.shifted_boundary_mass(cell, shift)
        };
        total = total + (cumulative - previous);
        previous = cumulative;
        cell = cell + 1;
    };
    total
}

/// Read the measure at an explicit re-anchoring shift, so a test can sweep the
/// anchor without standing up a second oracle state.
#[test_only]
public(package) fun deviation_at_shift(lattice: &InventoryLattice, shift: I64): u64 {
    let (current, _) = lattice.scan_at(shift, 0, 0, 0, true);
    current
}

#[test_only]
public(package) fun apply_range_for_testing(
    lattice: &mut InventoryLattice,
    lower_tick: u64,
    higher_tick: u64,
    quantity: u64,
    tick_size: u64,
) {
    lattice.apply_range(lower_tick, higher_tick, quantity, tick_size, true);
}
