// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Depth regression for the payout tree.
///
/// Boundary ticks are chosen by whoever mints, so the balancing rule must not be
/// derivable from a tick. The previous treap keyed rotations on
/// `blake2b256(bcs(tick))`, which is exactly that: a caller could scan for ticks
/// whose priorities descend as the ticks ascend and force a right spine of depth
/// N, turning every `apply_at` and settlement prefix walk into an N-node
/// dynamic-field traversal. External audit issue #47.
///
/// The fixtures below are the adversarial tick set from that report. Under the
/// treap it built a 100-node linked list; the assertions here pin that the same
/// ticks now build the same height as an honest book. Expected heights are
/// independently derived from a Python model of the rotation logic
/// (`scratch/audit47/`), not from this contract.
#[test_only]
module deepbook_predict::strike_payout_tree_balance_tests;

use deepbook_predict::{constants, strike_payout_tree::{Self, StrikePayoutTree}};
use std::unit_test::{assert_eq, destroy};

const QUANTITY: u64 = 1_000_000;
const FLOOR_SHARES: u64 = 250_000;
const NODES: u64 = 100;

/// Strictly increasing ticks whose treap priorities strictly DECREASE — the shape
/// attack. Every tick is a multiple of 10, so the set clears
/// `strike_exposure::assert_admitted_mint_ticks` for a market whose
/// `admission_tick_size` is 10x its `tick_size`: these are boundaries real mints
/// could place. Found with ~11k blake2b probes, well under a second of laptop CPU.
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

/// The same count of on-grid ticks drawn uniformly from a band around tick
/// 500_000: an honest book, no priority search.
const HONEST_TICKS: vector<u64> = vector[
    495380, 495470, 495490, 495500, 495590, 495600, 495610, 495630, 495640, 495710, 495740, 495830,
    495880, 495920, 495960, 495990, 496050, 496200, 496260, 496360, 496470, 496540, 496840, 496850,
    496920, 497100, 497190, 497260, 497280, 497460, 497490, 497540, 497940, 497960, 498060, 498070,
    498150, 498210, 498310, 498510, 498700, 498740, 498810, 499040, 499060, 499280, 499290, 499340,
    499370, 499440, 499590, 499640, 499760, 500060, 500080, 500190, 500240, 500370, 500440, 500480,
    500530, 500600, 500640, 500700, 500730, 500770, 500790, 500840, 500880, 500900, 500950, 500960,
    500990, 501230, 501330, 501420, 501450, 501540, 501660, 501960, 501980, 502150, 502290, 502460,
    502950, 502980, 503130, 503350, 503400, 503460, 503790, 503960, 504310, 504500, 504510, 504630,
    504700, 504880, 504930, 504980,
];

/// Height both books reach under height-balanced rotations (Python model).
const EXPECTED_HEIGHT: u64 = 7;
/// AVL's worst case for 100 nodes: floor(1.44 * log2(102)) = 9. The assertions
/// above are exact; this pins the bound the structure guarantees.
const AVL_HEIGHT_BOUND: u64 = 9;

/// One finite boundary per tick: `(tick, +inf]` never stores the upper end, so
/// each call adds exactly one node through the same path a mint takes.
fun build(ticks: vector<u64>, ctx: &mut TxContext): StrikePayoutTree {
    let mut tree = strike_payout_tree::new(ctx);
    ticks.do!(
        |tick| tree.insert_range(
            tick,
            constants::pos_inf_tick!(),
            QUANTITY,
            FLOOR_SHARES,
        ),
    );
    tree
}

#[test]
fun chosen_ticks_cannot_force_a_deep_tree() {
    let mut ctx = tx_context::dummy();
    let skewed_ticks = SKEWED_TICKS;
    let skewed = build(skewed_ticks, &mut ctx);

    assert_eq!(skewed_ticks.length(), NODES);
    assert_eq!(skewed.root_height_for_testing(), EXPECTED_HEIGHT);
    assert!(skewed.root_height_for_testing() <= AVL_HEIGHT_BOUND);
    skewed.assert_balanced_for_testing();

    destroy(skewed);
}

#[test]
/// The adversarial book is worth no more depth than an honest one.
fun adversarial_and_honest_books_reach_the_same_height() {
    let mut ctx = tx_context::dummy();
    let skewed = build(SKEWED_TICKS, &mut ctx);
    let honest = build(HONEST_TICKS, &mut ctx);

    assert_eq!(honest.root_height_for_testing(), EXPECTED_HEIGHT);
    assert_eq!(skewed.root_height_for_testing(), honest.root_height_for_testing());
    honest.assert_balanced_for_testing();

    destroy(skewed);
    destroy(honest);
}

#[test]
/// Boundary GC goes through `join_subtrees`, which relinks the in-order successor
/// and rebalances back up — the path insertion never exercises.
fun boundary_gc_preserves_the_height_invariant() {
    let mut ctx = tx_context::dummy();
    let skewed_ticks = SKEWED_TICKS;
    let mut tree = build(skewed_ticks, &mut ctx);

    // Drop every third boundary to zero so its node is collected mid-tree.
    let mut i = 0;
    while (i < skewed_ticks.length()) {
        tree.remove_range(
            skewed_ticks[i],
            constants::pos_inf_tick!(),
            QUANTITY,
            FLOOR_SHARES,
        );
        tree.assert_balanced_for_testing();
        i = i + 3;
    };

    assert!(tree.root_height_for_testing() <= AVL_HEIGHT_BOUND);
    destroy(tree);
}
