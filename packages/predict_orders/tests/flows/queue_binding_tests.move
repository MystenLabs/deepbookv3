// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Queue creation and binding: each market's queue sits at the ID derived from
/// the desk's queue registry and the market, a second queue for one market
/// aborts, creation refuses another desk's registry, and every queue entry
/// point refuses another desk or another market's objects before it reaches
/// Predict.
#[test_only]
module deepbook_predict_orders::queue_binding_tests;

use deepbook_predict::test_constants;
use deepbook_predict_orders::{queue, queue_fixture::{Self as fixture, QueueTest}};
use std::unit_test::assert_eq;

const QUANTITY: u64 = 4_000_000;
const MAX_COST: u64 = 3_000_000;
const TAU: u64 = 121_000;
const MAX_ORDERS: u64 = 10;

// === Creation ===

#[test]
fun the_queue_sits_at_the_id_derived_from_the_registry_and_the_market() {
    let q = fixture::new();
    let desk_id = q.desk_id();
    let expiry_id = q.expiry_id();

    assert_eq!(q.queue().id(), q.queue_id());
    assert_eq!(q.queue().desk_id(), desk_id);
    assert_eq!(q.queue().expiry_market_id(), expiry_id);
    assert_eq!(queue::queue_id(q.registry_id(), expiry_id), q.queue_id());
    // The registry is its own object, apart from the desk.
    assert!(q.registry_id() != desk_id);
    // An empty queue: nothing waiting and nothing to pay.
    let (payout_cursor, next_id, payouts_completed) = q.queue().payout_progress();
    assert_eq!(payout_cursor, 0);
    assert_eq!(next_id, 0);
    assert!(!payouts_completed);
    q.finish();
}

/// Aborts in `derived_object::claim` with its `EObjectAlreadyExists`, so neither
/// the trailing sentinel nor any other abort satisfies the test.
#[
    test,
    expected_failure(
        abort_code = sui::derived_object::EObjectAlreadyExists,
        location = sui::derived_object,
    ),
]
fun a_second_queue_for_the_same_market_aborts() {
    let mut q = fixture::new();
    q.create_queue();
    abort 999
}

/// Queue creation is permissionless: any sender creates another market's queue,
/// at its own derived ID.
#[test]
fun anyone_creates_another_markets_queue_at_its_derived_id() {
    let (q, other) = fixture::new_with_other_market();
    let mut q = q.with_market(other).next_tx(test_constants::bob());
    let registry_id = q.registry_id();

    let created = q.create_queue();

    assert_eq!(created, queue::queue_id(registry_id, other));
    assert!(created != q.queue_id());
    q.finish();
}

/// The registry belongs to one desk: creating a queue through it with another
/// desk aborts before claiming an ID.
#[test, expected_failure(abort_code = queue::EWrongDesk)]
fun creating_a_queue_with_another_desks_registry_aborts() {
    let (q, other) = fixture::new_with_other_market();
    let mut q = q.with_market(other).with_new_desk();
    q.create_queue();
    abort 999
}

// === Binding ===

#[test, expected_failure(abort_code = queue::EWrongMarket)]
fun enqueue_with_another_markets_objects_aborts() {
    let (q, other) = fixture::new_with_other_market();
    let mut q = q.with_market(other);
    place_mint(&mut q);
    abort 999
}

#[test, expected_failure(abort_code = queue::EWrongMarket)]
fun commit_with_another_markets_objects_aborts() {
    let (q, other) = fixture::new_with_other_market();
    let mut q = q.with_market(other);
    q.commit_at(TAU, fixture::live_price());
    abort 999
}

#[test, expected_failure(abort_code = queue::EWrongMarket)]
fun resolve_with_another_markets_objects_aborts() {
    let (q, other) = fixture::new_with_other_market();
    let mut q = q.with_market(other);
    q.resolve(MAX_ORDERS);
    abort 999
}

#[test, expected_failure(abort_code = queue::EWrongDesk)]
fun enqueue_under_another_desk_aborts() {
    let mut q = fixture::new().with_new_desk();
    place_mint(&mut q);
    abort 999
}

#[test, expected_failure(abort_code = queue::EWrongDesk)]
fun refund_under_another_desk_aborts() {
    let mut q = fixture::new().with_new_desk();
    q.refund(MAX_ORDERS);
    abort 999
}

#[test, expected_failure(abort_code = queue::EWrongDesk)]
fun settle_step_under_another_desk_aborts() {
    let mut q = fixture::new().with_new_desk();
    q.settle_step();
    abort 999
}

// === Helpers ===

fun place_mint(q: &mut QueueTest): u64 {
    q.enqueue_atm(QUANTITY, MAX_COST)
}
