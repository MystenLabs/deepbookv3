// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Pins the capacity terms that keep one `plp::value_expiry` inside a single
/// transaction's dynamic-field-children budget. See RP-28.
///
/// The load-bearing test is `worst_case_page_occupancy_stays_within_the_bound`: it
/// builds a real liquidation book and counts real pages, because the derivation's weak
/// term is a claim about the book's *structure*, not about arithmetic. An earlier
/// version of this file asserted only relations between the constants — each of which
/// reduced to `budget <= budget` once the macro was substituted — and it stayed green
/// through a factor-of-two error in exactly that term.
///
/// `sui move test` does NOT enforce the object-runtime limit; a unit test loads 1,100
/// children without aborting. So the ceiling itself is reachable only on localnet, and
/// what these tests can honestly cover is the *inputs* to the derivation.
#[test_only]
module deepbook_predict::valuation_capacity_tests;

use deepbook_predict::{constants, liquidation_book, order::{Self, Order}};
use std::unit_test::destroy;

const LOWER_TICK: u64 = 1;
const HIGHER_TICK: u64 = 3;
/// Enough inserts to cross several page splits without approaching the test VM's budget.
const ORDERS: u64 = 600;

/// The bound must hold for the worst insertion order, not the average one. Ascending
/// order ids are the realistic worst case — a bot minting a monotone strike ladder at
/// constant size and floor produces them — because every insert lands in the last page,
/// so each page splits once at its midpoint and is never revisited, leaving occupancy at
/// the split floor rather than at capacity.
///
/// This is the test that fails if `max_liquidation_pages` is ever divided by the page
/// capacity instead of half of it.
#[test]
fun worst_case_page_occupancy_stays_within_the_bound() {
    let ctx = &mut tx_context::dummy();
    let mut book = liquidation_book::new(ctx);
    let mut i = 0;
    while (i < ORDERS) {
        let order = ascending_leveraged_order(i);
        book.insert_order(&order);
        i = i + 1;
    };

    // Assert against the SAME occupancy assumption `max_liquidation_pages` divides by,
    // not against the page capacity — otherwise changing the derivation's divisor leaves
    // this green, which is exactly how the factor-of-two error survived its first test.
    // Asserting the ratio rather than a page count keeps it independent of
    // `max_active_leveraged_orders`.
    let pages = book.page_count();
    assert!(pages <= ORDERS.div_ceil(constants::liquidation_orders_per_page_worst_case!()));

    // And prove the assumption is tight rather than vacuously loose: a perfectly packed
    // book would need only half as many pages, and this one exceeds that. Together the
    // two bounds fix the divisor at the split floor.
    assert!(pages > ORDERS.div_ceil(constants::liquidation_page_capacity!()));

    destroy(book);
}

/// The point of deriving the cap: one market's worst-case valuation fits.
#[test]
fun one_market_valuation_fits_the_object_budget() {
    let worst_case =
        constants::max_payout_tree_nodes!() + constants::max_liquidation_pages!() + constants::valuation_base_children_reserve!();
    assert!(worst_case <= constants::object_cache_budget!());
}

/// A derived cap can be driven to an unusable value without ever underflowing: raising
/// `max_active_leveraged_orders` far enough leaves a positive but economically dead node
/// budget, and no relation between the constants would catch it. This floor is the one
/// arithmetic assertion here a future edit can actually violate.
#[test]
fun the_node_cap_stays_usable() {
    assert!(constants::max_payout_tree_nodes!() >= 500);
}

/// Ascending in the book's key order, with constant quantity and floor so only the
/// sequence varies — the shape a monotone minting bot produces.
fun ascending_leveraged_order(sequence: u64): Order {
    let quantity = constants::position_lot_size!();
    order::new_from_ticks(LOWER_TICK, HIGHER_TICK, quantity / 2, quantity, sequence)
}
