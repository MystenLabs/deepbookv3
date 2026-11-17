// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// The payout tree's liability at a `Pricer`, read through the production walk.
/// Predict values a tree only through `walk_frozen`, the flush's walk, so a test
/// that needs the tree's current liability opens the next snapshot generation over
/// it, walks that generation before any mutation (every node at its current
/// terms), and closes it again.
#[test_only]
module deepbook_predict::tree_walk;

use deepbook_predict::{pricing::Pricer, strike_payout_tree::StrikePayoutTree};

/// The tree's liability at its current terms. Supersedes any generation the tree
/// holds, so call it only once the test no longer walks that generation.
public fun liability(tree: &mut StrikePayoutTree, pricer: &Pricer, tick_size: u64): u64 {
    let generation = tree.snapshot_seq_for_testing() + 1;
    tree.snap_on(generation);
    let value = tree.walk_frozen(pricer, tick_size, generation);
    tree.snap_off();
    value
}
