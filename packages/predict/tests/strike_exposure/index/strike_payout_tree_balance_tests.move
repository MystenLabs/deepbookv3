// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Order-independence and garbage-collection regressions for the payout index.
///
/// Insertion order and mid-sequence removes must leave the same sorted records
/// and the same reserve and settlement terms. `assert_tree_invariant_for_testing`
/// recomputes sort order and emptiness rather than trusting `node_count`.
#[test_only]
module deepbook_predict::strike_payout_tree_balance_tests;

use deepbook_predict::{constants, strike_payout_tree::{Self, StrikePayoutTree}};
use std::unit_test::{assert_eq, destroy};

const QUANTITY: u64 = 1_000_000;
const NODES: u64 = 100;
const GC_STRIDE: u64 = 3;
const GC_SURVIVORS: u64 = 66;

/// On-grid ticks, strictly increasing. Every tick is a multiple of 10, so the
/// set clears `strike_exposure::assert_admitted_mint_ticks`'s grid gate for a
/// market whose `admission_tick_size` is 10x its `tick_size`.
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

fun insert(tree: &mut StrikePayoutTree, tick: u64) {
    tree.insert_range(tick, constants::pos_inf_tick!(), QUANTITY);
}

fun remove(tree: &mut StrikePayoutTree, tick: u64) {
    tree.remove_range(tick, constants::pos_inf_tick!(), QUANTITY);
}

/// Insert one finite boundary per tick, checking the whole invariant after each.
fun build_checked(ticks: vector<u64>, ctx: &mut TxContext): StrikePayoutTree {
    let mut tree = strike_payout_tree::new(ctx);
    ticks.do!(|tick| {
        insert(&mut tree, tick);
        tree.assert_tree_invariant_for_testing();
    });
    tree
}

/// Settlement above every boundary: every `(tick, +inf]` range is in the money, so
/// the liability is one `QUANTITY` per surviving boundary.
fun settled_above_all(tree: &StrikePayoutTree): u64 {
    tree.settled_payout_liability(constants::pos_inf_tick!() - 1, 1)
}

#[test]
fun chosen_ticks_stay_sorted_and_keep_terms() {
    let mut ctx = tx_context::dummy();
    let tree = build_checked(SKEWED_TICKS, &mut ctx);

    assert_eq!(tree.assert_tree_invariant_for_testing(), NODES);
    assert_eq!(settled_above_all(&tree), NODES * QUANTITY);

    destroy(tree);
}

#[test]
fun descending_inserts_match_ascending_terms() {
    let mut ctx = tx_context::dummy();
    let mut ticks = SKEWED_TICKS;
    ticks.reverse();
    let tree = build_checked(ticks, &mut ctx);

    assert_eq!(tree.assert_tree_invariant_for_testing(), NODES);
    assert_eq!(settled_above_all(&tree), NODES * QUANTITY);

    destroy(tree);
}

#[test]
fun outside_in_inserts_match_ascending_terms() {
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
    assert_eq!(tree.assert_tree_invariant_for_testing(), NODES);
    assert_eq!(settled_above_all(&tree), NODES * QUANTITY);

    destroy(tree);
}

#[test]
fun removing_an_end_tick_keeps_the_remaining_terms() {
    let mut ctx = tx_context::dummy();
    let mut tree = strike_payout_tree::new(&mut ctx);

    vector[1, 2, 3, 6, 7, 5, 4, 8].do!(|tick| insert(&mut tree, tick));
    tree.assert_tree_invariant_for_testing();

    remove(&mut tree, 1);

    assert_eq!(tree.assert_tree_invariant_for_testing(), 7);
    assert_eq!(settled_above_all(&tree), 7 * QUANTITY);

    let mut mirrored = strike_payout_tree::new(&mut ctx);
    vector[8, 7, 6, 3, 2, 4, 5, 1].do!(|tick| insert(&mut mirrored, tick));
    mirrored.assert_tree_invariant_for_testing();

    remove(&mut mirrored, 8);

    assert_eq!(mirrored.assert_tree_invariant_for_testing(), 7);
    assert_eq!(settled_above_all(&mirrored), 7 * QUANTITY);

    destroy(tree);
    destroy(mirrored);
}

#[test]
fun removing_an_interior_tick_keeps_neighbor_terms() {
    let mut ctx = tx_context::dummy();
    let mut tree = strike_payout_tree::new(&mut ctx);

    vector[1, 2, 3, 4].do!(|tick| insert(&mut tree, tick));
    remove(&mut tree, 2);

    tree.assert_tree_invariant_for_testing();
    // Survivors are ticks 1, 3 and 4. Losing tick 4 would report 2 * QUANTITY.
    assert_eq!(settled_above_all(&tree), 3 * QUANTITY);
    let (max_net_payout, total_net_payout) = tree.payout_reserve_terms();
    assert_eq!(max_net_payout, 3 * QUANTITY);
    assert_eq!(total_net_payout, 3 * QUANTITY);

    destroy(tree);
}

#[test]
fun boundary_gc_preserves_terms_against_a_rebuild() {
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
    assert_eq!(survivors.length(), GC_SURVIVORS);
    assert_eq!(settled_above_all(&tree), GC_SURVIVORS * QUANTITY);

    let rebuilt = build_checked(survivors, &mut ctx);
    assert_eq!(settled_above_all(&tree), settled_above_all(&rebuilt));
    let (gc_max, gc_total) = tree.payout_reserve_terms();
    let (rebuilt_max, rebuilt_total) = rebuilt.payout_reserve_terms();
    assert_eq!(gc_max, rebuilt_max);
    assert_eq!(gc_total, rebuilt_total);

    destroy(tree);
    destroy(rebuilt);
}

#[test]
fun interleaved_churn_preserves_the_invariant() {
    let mut ctx = tx_context::dummy();
    let mut tree = strike_payout_tree::new(&mut ctx);
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

    assert_eq!(settled_above_all(&tree), live.length() * QUANTITY);
    assert_eq!(tree.assert_tree_invariant_for_testing(), live.length());

    destroy(tree);
}

#[test]
fun draining_every_boundary_empties_the_index() {
    let mut ctx = tx_context::dummy();
    let ticks = SKEWED_TICKS;
    let mut tree = build_checked(ticks, &mut ctx);

    ticks.do!(|tick| {
        remove(&mut tree, tick);
        tree.assert_tree_invariant_for_testing();
    });

    assert_eq!(tree.assert_tree_invariant_for_testing(), 0);
    assert_eq!(settled_above_all(&tree), 0);
    let (max_net_payout, total_net_payout) = tree.payout_reserve_terms();
    assert_eq!(max_net_payout, 0);
    assert_eq!(total_net_payout, 0);

    destroy(tree);
}
