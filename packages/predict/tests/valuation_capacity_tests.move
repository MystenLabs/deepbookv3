// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Pins the one capacity term a future edit can still get wrong: the usable floor of the derived node cap. See RP-30.
///
/// This file used to carry two more tests, and both lost their subject when leverage was removed. `worst_case_page_occupancy_stays_within_the_bound` built a real liquidation book and counted real pages, because the derivation's weak term was a claim about that book's *structure*; the book is deleted and the term with it. `one_market_valuation_fits_the_object_budget` asserted `nodes + pages + reserve <= budget`, which with the page term gone reduces to `budget <= budget` — a tautology, and precisely the anti-pattern this module's history warns about (an earlier version asserted only such relations and stayed green through a factor-of-two error). It is deleted rather than kept green.
///
/// `sui move test` does NOT enforce the object-runtime limit; a unit test loads 1,100 children without aborting. The ceiling itself is reachable only on localnet, so the derivation's remaining input — `valuation_base_children_reserve`, still UNMEASURED — is confirmed by the capacity campaign C-1 calls for, not here.
#[test_only]
module deepbook_predict::valuation_capacity_tests;

use deepbook_predict::constants;

/// A derived cap can be driven to an unusable value without ever underflowing: inflating `valuation_base_children_reserve` far enough leaves a positive but economically dead node budget, and no relation between the constants would catch it. This floor is the one arithmetic assertion here a future edit can actually violate.
#[test]
fun the_node_cap_stays_usable() {
    assert!(constants::max_payout_tree_nodes!() >= 500);
}
