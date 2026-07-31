// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Depth and shape regression for the payout tree.
///
/// Boundary ticks are chosen by whoever mints, so the balancing rule must not be
/// derivable from a tick. The previous treap keyed rotations on
/// `blake2b256(bcs(tick))`, which is exactly that: a caller could scan for ticks
/// whose priorities descend as the ticks ascend and force a right spine of depth
/// N, turning every `apply_at` and settlement prefix walk into an N-node
/// dynamic-field traversal. External audit issue #47.
///
/// Depth is enforced by code alone — a runtime balance check would cost a full
/// traversal, so nothing on chain notices a regression, and the only symptom is
/// the tree drifting back toward the spine this change exists to prevent. These
/// tests are therefore the whole guarantee, and they are written to kill specific
/// mutations rather than to exercise the happy path: insertion orders are chosen
/// to reach all four rotation cases, and `assert_tree_invariant_for_testing`
/// recomputes every stored height and summary rather than trusting them.
#[test_only]
module deepbook_predict::strike_payout_tree_balance_tests;

use deepbook_predict::{constants, strike_payout_tree::{Self, StrikePayoutTree}};
use std::unit_test::{assert_eq, destroy};

const QUANTITY: u64 = 1_000_000;
const FLOOR_SHARES: u64 = 250_000;
/// `QUANTITY - FLOOR_SHARES`, the net payout each boundary contributes.
const NET_PAYOUT: u64 = 750_000;
const NODES: u64 = 100;
const GC_STRIDE: u64 = 3;

/// On-grid ticks, strictly increasing, whose treap priorities strictly DECREASE —
/// the shape attack. Every tick is a multiple of 10, so the set clears
/// `strike_exposure::assert_admitted_mint_ticks`'s grid gate for a market whose
/// `admission_tick_size` is 10x its `tick_size`. Found with ~11k blake2b probes,
/// well under a second of laptop CPU.
const SKEWED_TICKS: vector<u64> = vector[
    1110, 10739550, 21475700, 32213220, 42949930, 53689330, 64425020, 75162460, 85899770, 96637210,
    107378160, 118115050, 128850590, 139586740, 150323920, 161062410, 171800450, 182536090,
    193275570, 204010890, 214749040, 225486020, 236225840, 246961910, 257699780, 268435820,
    279173140, 289910300, 300648660, 311386410, 322123090, 332860310, 343597990, 354334660,
    365073020, 375809770, 386546830, 397284580, 408022960, 418759500, 429496440, 440234300,
    450971660, 461710020, 472448500, 483183560, 493921100, 504658680, 515397310, 526134370,
    536871750, 547609110, 558345750, 569083960, 579820390, 590559250, 601295960, 612033610,
    622769840, 633507310, 644248430, 654982410, 665721080, 676456990, 687195190, 697932460,
    708669640, 719408270, 730144660, 740881720, 751620290, 762359490, 773094100, 783831640,
    794569200, 805306720, 816046910, 826782130, 837518440, 848255950, 858993980, 869731680,
    880469520, 891206290, 901942540, 912680120, 923418770, 934157040, 944894840, 955629720,
    966367390, 977104890, 987842000, 998580290, 1009316840, 1020055260, 1030794930, 1041532620,
    1052266700, 1063003910,
];

/// Minimum height for 100 nodes: `ceil(log2(101))`. Ascending insertion into a
/// height-balanced tree always achieves it.
const EXPECTED_HEIGHT: u64 = 7;
/// AVL's worst case at 100 nodes, from the minimum-nodes recurrence
/// `N(h) = N(h-1) + N(h-2) + 1`: `N(9) = 88 <= 100 < N(10) = 143`, so height <= 9.
/// At the production cap of `max_payout_tree_nodes!()` the same recurrence gives
/// `N(14) = 986 <= 1000 < N(15) = 1596` — height <= 14 for every admissible tick
/// set, against the treap's 1000-deep adversarial worst case.
const AVL_HEIGHT_BOUND: u64 = 9;

fun insert(tree: &mut StrikePayoutTree, tick: u64) {
    tree.insert_range(tick, constants::pos_inf_tick!(), QUANTITY, FLOOR_SHARES);
}

fun remove(tree: &mut StrikePayoutTree, tick: u64) {
    tree.remove_range(tick, constants::pos_inf_tick!(), QUANTITY, FLOOR_SHARES);
}

/// Insert one finite boundary per tick, checking the whole invariant after each —
/// a mid-sequence corruption that a later rotation happens to repair still fails.
fun build_checked(ticks: vector<u64>, ctx: &mut TxContext): StrikePayoutTree {
    let mut tree = strike_payout_tree::new(ctx);
    ticks.do!(|tick| {
        insert(&mut tree, tick);
        tree.assert_tree_invariant_for_testing();
    });
    tree
}

/// Settlement above every boundary: every `(tick, +inf]` range is in the money, so
/// the liability is one `NET_PAYOUT` per surviving boundary.
fun settled_above_all(tree: &StrikePayoutTree): u64 {
    tree.settled_payout_liability(constants::pos_inf_tick!() - 1, 1)
}

#[test]
/// The attack fixture, in the order it was generated.
fun chosen_ticks_cannot_force_a_deep_tree() {
    let mut ctx = tx_context::dummy();
    let tree = build_checked(SKEWED_TICKS, &mut ctx);

    assert_eq!(tree.assert_tree_invariant_for_testing(), EXPECTED_HEIGHT);
    assert!(EXPECTED_HEIGHT <= AVL_HEIGHT_BOUND);
    assert_eq!(settled_above_all(&tree), NODES * NET_PAYOUT);

    destroy(tree);
}

#[test]
/// Descending arrival drives the left-heavy single rotation, which ascending
/// fixtures never reach.
fun descending_inserts_stay_balanced() {
    let mut ctx = tx_context::dummy();
    let mut ticks = SKEWED_TICKS;
    ticks.reverse();
    let tree = build_checked(ticks, &mut ctx);

    assert_eq!(tree.assert_tree_invariant_for_testing(), EXPECTED_HEIGHT);
    assert_eq!(settled_above_all(&tree), NODES * NET_PAYOUT);

    destroy(tree);
}

#[test]
/// Outside-in arrival alternates the two heavy sides, reaching both double
/// rotations as well as both singles.
fun outside_in_inserts_stay_balanced() {
    let mut ctx = tx_context::dummy();
    let sorted = SKEWED_TICKS;
    let mut zigzag = vector[];
    let mut lo = 0;
    let mut hi = sorted.length() - 1;
    while (lo <= hi) {
        zigzag.push_back(sorted[lo]);
        if (lo < hi) zigzag.push_back(sorted[hi]);
        lo = lo + 1;
        if (hi == 0) break;
        hi = hi - 1;
    };

    let tree = build_checked(zigzag, &mut ctx);
    assert!(tree.assert_tree_invariant_for_testing() <= AVL_HEIGHT_BOUND);
    assert_eq!(settled_above_all(&tree), NODES * NET_PAYOUT);

    destroy(tree);
}

#[test]
/// A delete can leave a node two levels heavy with its taller child's subtrees
/// EQUAL in height. That tie must take the single rotation: the double leaves the
/// demoted child holding a two-level gap that nothing goes back to fix. Only a
/// removal produces the tie, so no insert-only fixture distinguishes `>` from
/// `>=` in `rebalance`'s inner-rotation condition.
fun delete_induced_height_tie_takes_the_single_rotation() {
    let mut ctx = tx_context::dummy();
    let mut tree = strike_payout_tree::new(&mut ctx);

    vector[1, 2, 3, 6, 7, 5, 4, 8].do!(|tick| insert(&mut tree, tick));
    tree.assert_tree_invariant_for_testing();

    remove(&mut tree, 1);

    // Under `>=` this leaves a node with subtree heights 0 and 2.
    assert_eq!(tree.assert_tree_invariant_for_testing(), 4);
    assert_eq!(settled_above_all(&tree), 7 * NET_PAYOUT);

    // The mirror image, so both the left-heavy and right-heavy inner conditions
    // are pinned. Removing the largest tick leans the tree the other way.
    let mut mirrored = strike_payout_tree::new(&mut ctx);
    vector[8, 7, 6, 3, 2, 4, 5, 1].do!(|tick| insert(&mut mirrored, tick));
    mirrored.assert_tree_invariant_for_testing();

    remove(&mut mirrored, 8);

    assert_eq!(mirrored.assert_tree_invariant_for_testing(), 4);
    assert_eq!(settled_above_all(&mirrored), 7 * NET_PAYOUT);

    destroy(tree);
    destroy(mirrored);
}

#[test]
/// When the in-order successor carries a right subtree of its own, that subtree
/// must be re-parented onto the successor's old parent. Dropping it keeps the tree
/// balanced, keeps `node_count` consistent, and silently loses a boundary's payout
/// — so this asserts terms, not shape.
fun successor_keeps_its_own_right_subtree() {
    let mut ctx = tx_context::dummy();
    let mut tree = strike_payout_tree::new(&mut ctx);

    vector[1, 2, 3, 4].do!(|tick| insert(&mut tree, tick));
    remove(&mut tree, 2);

    tree.assert_tree_invariant_for_testing();
    // Survivors are ticks 1, 3 and 4. Losing tick 4 would report 2 * NET_PAYOUT.
    assert_eq!(settled_above_all(&tree), 3 * NET_PAYOUT);
    let (max_net_payout, total_net_payout) = tree.net_payout_reserve_terms();
    assert_eq!(max_net_payout, 3 * NET_PAYOUT);
    assert_eq!(total_net_payout, 3 * NET_PAYOUT);

    destroy(tree);
}

#[test]
/// The rewritten GC path, asserted on terms rather than height. A splice that
/// leaves a stale summary keeps every height correct while reporting a reserve
/// floor that is wrong by a factor of two.
fun boundary_gc_preserves_terms_and_balance() {
    let mut ctx = tx_context::dummy();
    let ticks = SKEWED_TICKS;
    let mut tree = build_checked(ticks, &mut ctx);

    let mut survivors = vector[];
    let mut i = 0;
    while (i < ticks.length()) {
        if (i % GC_STRIDE == 0) {
            remove(&mut tree, ticks[i]);
            tree.assert_tree_invariant_for_testing();
        } else {
            survivors.push_back(ticks[i]);
        };
        i = i + 1;
    };

    // 100 ticks, every third removed -> 34 removed, 66 survive.
    assert_eq!(survivors.length(), 66);
    assert_eq!(settled_above_all(&tree), 66 * NET_PAYOUT);

    // Metamorphic: a tree built from the survivors alone has a DIFFERENT shape
    // (the GC'd tree carries rotation history the rebuilt one never saw), so
    // agreement on every evaluator is a real check, not a tautology.
    let rebuilt = build_checked(survivors, &mut ctx);
    assert_eq!(settled_above_all(&tree), settled_above_all(&rebuilt));
    let (gc_max, gc_total) = tree.net_payout_reserve_terms();
    let (rebuilt_max, rebuilt_total) = rebuilt.net_payout_reserve_terms();
    assert_eq!(gc_max, rebuilt_max);
    assert_eq!(gc_total, rebuilt_total);

    destroy(tree);
    destroy(rebuilt);
}

#[test]
/// Mixed insert/remove churn. A deterministic LCG picks the tick so the sequence
/// is reproducible; the invariant is recomputed after every single operation,
/// which is what kills the ordering and double-rotation mutations that fixed
/// fixtures miss.
fun interleaved_churn_preserves_the_invariant() {
    let mut ctx = tx_context::dummy();
    let mut tree = strike_payout_tree::new(&mut ctx);
    // Sized so the per-operation invariant recomputation (which walks the whole
    // tree) fits the unit-test gas budget; the mutation-killing property is the
    // mixed insert/remove order plus checking after EVERY op, not the op count.
    let span = 60;
    let mut live = vector[];
    let mut seed = 12345;

    120u64.do!(|_| {
        seed = (seed * 1103515245 + 12345) % 2147483648;
        let tick = 1 + seed % span;
        let (found, index) = live.index_of(&tick);
        if (found) {
            remove(&mut tree, tick);
            live.remove(index);
        } else {
            insert(&mut tree, tick);
            live.push_back(tick);
        };
        tree.assert_tree_invariant_for_testing();
    });

    assert_eq!(settled_above_all(&tree), live.length() * NET_PAYOUT);
    assert!(tree.assert_tree_invariant_for_testing() <= AVL_HEIGHT_BOUND);

    destroy(tree);
}

#[test]
/// Draining every boundary must leave the tree genuinely empty, including the
/// root-removal case where `join_subtrees` has to produce a new root.
fun draining_every_boundary_empties_the_tree() {
    let mut ctx = tx_context::dummy();
    let ticks = SKEWED_TICKS;
    let mut tree = build_checked(ticks, &mut ctx);

    ticks.do!(|tick| {
        remove(&mut tree, tick);
        tree.assert_tree_invariant_for_testing();
    });

    assert_eq!(tree.assert_tree_invariant_for_testing(), 0);
    assert_eq!(settled_above_all(&tree), 0);
    let (max_net_payout, total_net_payout) = tree.net_payout_reserve_terms();
    assert_eq!(max_net_payout, 0);
    assert_eq!(total_net_payout, 0);

    destroy(tree);
}
