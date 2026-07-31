// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Pins the arithmetic that keeps one `plp::value_expiry` inside a single
/// transaction's dynamic-field-children budget. These are compile-time constants, so
/// the assertions are cheap — the point is that a future edit to any of the caps
/// cannot silently push the flush over Sui's ceiling, which does not fail as a
/// degraded fill but as a pool-wide LP freeze (`finish_flush` requires every
/// snapshotted market valued). See RP-26.
///
/// `sui move test` does NOT enforce the object-runtime limit — a unit test can load
/// 1,100 children without aborting — so the real ceiling is only reachable on
/// localnet. That is exactly why the budget is asserted here as arithmetic instead of
/// being left to a run nobody re-runs.
#[test_only]
module deepbook_predict::valuation_capacity_tests;

use deepbook_predict::constants;
use std::unit_test::assert_eq;

#[test]
fun one_market_valuation_fits_the_object_budget() {
    let worst_case =
        constants::max_payout_tree_nodes!() + constants::max_liquidation_pages!() + constants::valuation_base_children_reserve!();
    assert!(worst_case <= constants::object_cache_budget!());
}

/// The cap is derived, not chosen: it is exactly the budget less everything else the
/// valuation transaction carries. Asserting equality rather than an inequality is
/// deliberate — a cap set below the derivation would waste strike capacity silently,
/// and one set above it is the freeze this whole entry exists to prevent.
#[test]
fun the_node_cap_is_exactly_the_remaining_budget() {
    assert_eq!(
        constants::max_payout_tree_nodes!(),
        constants::object_cache_budget!() - constants::max_liquidation_pages!() - constants::valuation_base_children_reserve!(),
    );
}

/// The liquidation book competes for the same budget, so its page count must track
/// the leveraged-order cap. If that cap is raised, the node cap shrinks by itself —
/// this pins the coupling rather than the current numbers.
#[test]
fun liquidation_pages_track_the_leveraged_order_cap() {
    assert_eq!(
        constants::max_liquidation_pages!(),
        constants::max_active_leveraged_orders!().div_ceil(64),
    );
    // Raising the leveraged cap must cost node capacity, never come for free.
    assert!(
        constants::max_payout_tree_nodes!() + constants::max_active_leveraged_orders!().div_ceil(64) < constants::object_cache_budget!(),
    );
}
