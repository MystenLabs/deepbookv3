// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// The refund routine's prune flag. Placement creates each mint's boundary
/// nodes (`ensure_mint_nodes`, zero leaves) and pins them; a refund unpins them
/// and, only with `prune = true`, detaches the ones no other waiting order pins.
/// `try_settle` passes `false`, so its refunds leave the nodes.
#[test_only]
module deepbook_predict::refund_prune_tests;

use deepbook_predict::{
    expiry_cash,
    order_queue::{Self, OrderBook},
    order_queue_test_helpers as h,
    strike_exposure::StrikeExposure
};
use std::unit_test::{assert_eq, destroy};
use sui::balance;
use usdc::usdc::USDC;

const BASE: u64 = 1_000_000_000;
const REFUND_MS: u64 = 1_000_006_000;
const BUDGET: u64 = 1_000_000;
const ORDER_FEE: u64 = 20_000;
const MINT_CASH_NEED: u64 = 990_001;
const OTHER_TICK: u64 = 300;

#[test]
fun a_refund_without_prune_leaves_the_unpinned_zero_nodes() {
    let ctx = &mut tx_context::dummy();
    let mut book = order_queue::new_book(ctx);
    let mut exposure = h::new_exposure(ctx);
    let id = place_with_nodes(&mut book, &mut exposure, h::lower_tick(), h::higher_tick());
    assert_eq!(exposure.payout_node_count(), 2);

    refund(&mut book, &mut exposure, id, false);

    assert_eq!(book.pins().length(), 0);
    assert_eq!(exposure.payout_node_count(), 2);
    destroy(book);
    destroy(exposure);
}

#[test]
fun a_refund_with_prune_detaches_only_nodes_no_waiting_order_pins() {
    let ctx = &mut tx_context::dummy();
    let mut book = order_queue::new_book(ctx);
    let mut exposure = h::new_exposure(ctx);
    // Two waiting mints share tick 100: nodes 100, 200, 300.
    let first = place_with_nodes(&mut book, &mut exposure, h::lower_tick(), h::higher_tick());
    let second = place_with_nodes(&mut book, &mut exposure, h::lower_tick(), OTHER_TICK);
    assert_eq!(exposure.payout_node_count(), 3);

    // Node 200 goes; node 100 stays pinned by the second mint.
    refund(&mut book, &mut exposure, first, true);
    assert_eq!(exposure.payout_node_count(), 2);
    assert_eq!(*book.pins().get(&h::lower_tick()), 1);

    refund(&mut book, &mut exposure, second, true);
    assert_eq!(exposure.payout_node_count(), 0);
    assert_eq!(book.pins().length(), 0);
    destroy(book);
    destroy(exposure);
}

/// Place a mint the way enqueue does: create its boundary nodes, then append.
fun place_with_nodes(
    book: &mut OrderBook,
    exposure: &mut StrikeExposure,
    lower_tick: u64,
    higher_tick: u64,
): u64 {
    exposure.ensure_mint_nodes(lower_tick, higher_tick);
    h::place_mint(
        book,
        &h::default_policy(),
        BASE,
        h::account(0),
        lower_tick,
        higher_tick,
        BUDGET,
        ORDER_FEE,
        MINT_CASH_NEED,
    )
}

fun refund(book: &mut OrderBook, exposure: &mut StrikeExposure, record_id: u64, prune: bool) {
    let mut cash = expiry_cash::new();
    let mut incentives = balance::zero<USDC>();
    let outcome = book.refund_order(
        exposure,
        &mut cash,
        &mut incentives,
        record_id,
        order_queue::reason_deadline(),
        prune,
        REFUND_MS,
    );
    assert!(outcome.is_some());
    destroy(cash);
    destroy(incentives);
}
