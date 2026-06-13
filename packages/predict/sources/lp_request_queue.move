// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// FIFO request queue with pooled escrow for the async LP layer.
///
/// One queue holds same-typed LP requests (DUSDC for supply, PLP for withdraw):
/// `enqueue` escrows the caller's `Balance<T>` and records a `Request` at the tail;
/// the daily flush drains from the head, and `remove` splits one entry's escrow
/// back out — used alike by a flush fill, a flush refund, and an owner cancel.
/// `head`/`tail` are a monotonic cursor: `remove` may punch a hole at any index,
/// which the drain skips via `contains`. This is storage only — it owns no
/// PoolVault, pricing, or authorization knowledge; those live in `plp`.
module deepbook_predict::lp_request_queue;

use sui::{balance::{Self, Balance}, table::{Self, Table}};

const ERequestNotFound: u64 = 0;

/// One queued LP request. `amount` is the escrowed input value: DUSDC supplied for
/// a supply request, or PLP shares to redeem for a withdraw request. `recipient` is
/// the address the fill is delivered to (a PredictManager's id-as-address).
public struct Request has copy, drop, store {
    recipient: address,
    amount: u64,
}

/// FIFO queue of `Request`s plus the pooled escrow backing every live entry.
/// `entries` is keyed by a monotonically increasing index in `[head, tail)`; a
/// removed index leaves a hole the drain cursor steps past.
public struct RequestQueue<phantom T> has store {
    entries: Table<u64, Request>,
    head: u64,
    tail: u64,
    escrow: Balance<T>,
}

// === Public-Package Functions ===

/// Create an empty queue.
public(package) fun new<T>(ctx: &mut TxContext): RequestQueue<T> {
    RequestQueue { entries: table::new(ctx), head: 0, tail: 0, escrow: balance::zero() }
}

/// The head cursor: the next index the drain inspects.
public(package) fun head<T>(queue: &RequestQueue<T>): u64 {
    queue.head
}

/// The tail: one past the last enqueued index. Untouched by the drain.
public(package) fun tail<T>(queue: &RequestQueue<T>): u64 {
    queue.tail
}

/// True once the head cursor has reached the tail — nothing left to drain.
public(package) fun is_empty<T>(queue: &RequestQueue<T>): bool {
    queue.head >= queue.tail
}

/// Count of live (un-removed) entries, i.e. enqueued minus removed, excluding holes.
public(package) fun pending<T>(queue: &RequestQueue<T>): u64 {
    queue.entries.length()
}

/// Total escrowed balance still held for live entries.
public(package) fun escrow_value<T>(queue: &RequestQueue<T>): u64 {
    queue.escrow.value()
}

/// True if a live entry exists at `index` (false for a hole or an out-of-range index).
public(package) fun contains<T>(queue: &RequestQueue<T>, index: u64): bool {
    queue.entries.contains(index)
}

/// Borrow the entry at `index`. Aborts `ERequestNotFound` for a hole or unknown index.
public(package) fun borrow<T>(queue: &RequestQueue<T>, index: u64): &Request {
    assert!(queue.entries.contains(index), ERequestNotFound);
    queue.entries.borrow(index)
}

public(package) fun recipient(request: &Request): address {
    request.recipient
}

public(package) fun amount(request: &Request): u64 {
    request.amount
}

/// Escrow `escrow` and record a `Request` for `recipient` at the tail. Returns the
/// new entry's index.
public(package) fun enqueue<T>(
    queue: &mut RequestQueue<T>,
    recipient: address,
    escrow: Balance<T>,
): u64 {
    let index = queue.tail;
    queue.entries.add(index, Request { recipient, amount: escrow.value() });
    queue.tail = index + 1;
    queue.escrow.join(escrow);
    index
}

/// Remove the entry at `index` and split its escrowed amount back out of the pool.
/// The drain consumes a fill with this; `plp` cancel/refund returns escrow with it.
/// The head cursor is not advanced — removing a non-head index leaves a hole.
public(package) fun remove<T>(queue: &mut RequestQueue<T>, index: u64): Balance<T> {
    assert!(queue.entries.contains(index), ERequestNotFound);
    let Request { recipient: _, amount } = queue.entries.remove(index);
    queue.escrow.split(amount)
}

/// Advance the head cursor past one processed (filled, refunded, or skipped-hole) index.
public(package) fun advance_head<T>(queue: &mut RequestQueue<T>) {
    queue.head = queue.head + 1;
}
