// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Pins the one capacity term a future edit can still get wrong: the usable floor of the node cap. See RP-30.
///
/// With boundaries stored inline the cap is a compute-headroom literal, not a derivation — there are no child-count inputs left to relate. The compute ceiling itself is reachable only on localnet (P-30's remeasure), so this file pins only the floor a careless edit could cross.
#[test_only]
module deepbook_predict::valuation_capacity_tests;

use deepbook_predict::constants;

/// Independently chosen usable floor for the node cap: a cap under this makes
/// the strike grid impractically coarse.
const USABLE_NODE_FLOOR: u64 = 500;

/// A literal cap can be lowered past usefulness without any arithmetic failing; this floor is the assertion a careless edit would actually violate.
#[test]
fun the_node_cap_stays_usable() {
    assert!(constants::max_payout_tree_nodes!() >= USABLE_NODE_FLOOR);
}
