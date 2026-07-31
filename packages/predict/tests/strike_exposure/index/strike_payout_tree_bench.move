// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Gas benchmark: identical workloads on the treap and the height-balanced tree.
///
/// Uses ONLY `strike_payout_tree`'s package API, which is unchanged across the
/// two implementations, so this file compiles byte-identically on both branches.
/// Read gas with `sui move test -s`; note the column headed "Gas Used" reports
/// gas REMAINING, so consumption is `limit - reported`.
#[test_only]
module deepbook_predict::strike_payout_tree_bench;

use deepbook_predict::{constants, strike_payout_tree::{Self, StrikePayoutTree}};
use std::unit_test::destroy;

const QUANTITY: u64 = 1_000_000;
const FLOOR_SHARES: u64 = 250_000;
const TICK_SIZE: u64 = 10_000;

/// On-grid ticks whose treap priorities descend as the ticks ascend, fed in
/// outside-in (zig-zag) order — the arrival order that maximises AVL height.
const SKEWED_TICKS: vector<u64> = vector[
    1110, 1063003910, 10739550, 1052266700, 21475700, 1041532620, 32213220, 1030794930,
    42949930, 1020055260, 53689330, 1009316840, 64425020, 998580290, 75162460, 987842000,
    85899770, 977104890, 96637210, 966367390, 107378160, 955629720, 118115050, 944894840,
    128850590, 934157040, 139586740, 923418770, 150323920, 912680120, 161062410, 901942540,
    171800450, 891206290, 182536090, 880469520, 193275570, 869731680, 204010890, 858993980,
    214749040, 848255950, 225486020, 837518440, 236225840, 826782130, 246961910, 816046910,
    257699780, 805306720, 268435820, 794569200, 279173140, 783831640, 289910300, 773094100,
    300648660, 762359490, 311386410, 751620290, 322123090, 740881720, 332860310, 730144660,
    343597990, 719408270, 354334660, 708669640, 365073020, 697932460, 375809770, 687195190,
    386546830, 676456990, 397284580, 665721080, 408022960, 654982410, 418759500, 644248430,
    429496440, 633507310, 440234300, 622769840, 450971660, 612033610, 461710020, 601295960,
    472448500, 590559250, 483183560, 579820390, 493921100, 569083960, 504658680, 558345750,
    515397310, 547609110, 526134370, 536871750
];

/// On-grid ticks from an honest band around tick 500_000, in shuffled arrival
/// order — real books do not arrive sorted.
const HONEST_TICKS: vector<u64> = vector[
    500240, 500600, 502980, 504930, 500190, 500950, 498060, 503130, 499440, 499370, 499280,
    498150, 502290, 495380, 500080, 500640, 500480, 500770, 496360, 502460, 499340, 500990,
    501980, 498700, 495610, 495740, 499060, 496470, 501330, 498510, 497940, 500790, 504510,
    498310, 496050, 501230, 497490, 503960, 496540, 495880, 496850, 500700, 500960, 501660,
    498740, 497280, 497960, 504500, 504980, 496920, 501960, 495710, 495920, 495640, 496840,
    501450, 500060, 500440, 495500, 498070, 502150, 498210, 500730, 497260, 500900, 497540,
    499290, 504700, 498810, 501540, 497100, 499040, 499640, 495490, 495990, 495830, 501420,
    497190, 499760, 500840, 500370, 503790, 503460, 503400, 495630, 502950, 495590, 504630,
    504310, 497460, 500880, 504880, 496200, 495600, 503350, 496260, 499590, 495960, 500530,
    495470
];

fun build(ticks: vector<u64>, ctx: &mut TxContext): StrikePayoutTree {
    let mut tree = strike_payout_tree::new(ctx);
    ticks.do!(
        |tick| tree.insert_range(tick, constants::pos_inf_tick!(), QUANTITY, FLOOR_SHARES),
    );
    tree
}

// === Build cost ===

#[test]
fun bench_a_build_honest() {
    let mut ctx = tx_context::dummy();
    destroy(build(HONEST_TICKS, &mut ctx));
}

#[test]
fun bench_b_build_skewed() {
    let mut ctx = tx_context::dummy();
    destroy(build(SKEWED_TICKS, &mut ctx));
}

// === Marginal mint on top of each book (subtract the build above) ===

#[test]
fun bench_c_honest_plus_10_mints() {
    let mut ctx = tx_context::dummy();
    let ticks = HONEST_TICKS;
    let mut tree = build(ticks, &mut ctx);
    let top = ticks[ticks.length() - 1];
    10u64.do!(
        |i| tree.insert_range(top + 10 * (i + 1), constants::pos_inf_tick!(), QUANTITY, FLOOR_SHARES),
    );
    destroy(tree);
}

#[test]
fun bench_d_skewed_plus_10_mints() {
    let mut ctx = tx_context::dummy();
    let ticks = SKEWED_TICKS;
    let mut tree = build(ticks, &mut ctx);
    let top = ticks[ticks.length() - 1];
    10u64.do!(
        |i| tree.insert_range(top + 10 * (i + 1), constants::pos_inf_tick!(), QUANTITY, FLOOR_SHARES),
    );
    destroy(tree);
}

// === Settlement prefix descent (root-to-leaf; cost is depth) ===

#[test]
fun bench_e_honest_plus_20_settles() {
    let mut ctx = tx_context::dummy();
    let ticks = HONEST_TICKS;
    let tree = build(ticks, &mut ctx);
    let top = ticks[ticks.length() - 1];
    20u64.do!(|i| {
        let _ = tree.settled_payout_liability((top + i) * TICK_SIZE, TICK_SIZE);
    });
    destroy(tree);
}

#[test]
fun bench_f_skewed_plus_20_settles() {
    let mut ctx = tx_context::dummy();
    let ticks = SKEWED_TICKS;
    let tree = build(ticks, &mut ctx);
    let top = ticks[ticks.length() - 1];
    20u64.do!(|i| {
        let _ = tree.settled_payout_liability((top + i) * TICK_SIZE, TICK_SIZE);
    });
    destroy(tree);
}

// === Boundary GC / close path (every third boundary removed) ===

#[test]
fun bench_g_honest_plus_gc() {
    let mut ctx = tx_context::dummy();
    let ticks = HONEST_TICKS;
    let mut tree = build(ticks, &mut ctx);
    let mut i = 0;
    while (i < ticks.length()) {
        tree.remove_range(ticks[i], constants::pos_inf_tick!(), QUANTITY, FLOOR_SHARES);
        i = i + 3;
    };
    destroy(tree);
}

#[test]
fun bench_h_skewed_plus_gc() {
    let mut ctx = tx_context::dummy();
    let ticks = SKEWED_TICKS;
    let mut tree = build(ticks, &mut ctx);
    let mut i = 0;
    while (i < ticks.length()) {
        tree.remove_range(ticks[i], constants::pos_inf_tick!(), QUANTITY, FLOOR_SHARES);
        i = i + 3;
    };
    destroy(tree);
}
