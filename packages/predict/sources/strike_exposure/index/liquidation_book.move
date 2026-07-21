// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Priority-sorted liquidation index for active leveraged Predict orders.
///
/// Order IDs sort larger quantities and then larger static floors first because
/// those fields are inverse-encoded. Candidate selection repeatedly checks that
/// head while rotating a smaller scan across the remaining leveraged orders. The
/// same bounded active set supplies the floor-correction term for pool valuation.
module deepbook_predict::liquidation_book;

use deepbook_predict::{constants, order::{Self, Order}, pricing::{IntervalPriceMemo, PriceMemo}};
use fixed_math::{interval::{Self, Interval}, math};
use sui::table::{Self, Table};

const EActiveOrderAlreadyExists: u64 = 0;
const EActiveOrderNotFound: u64 = 1;
const EMaxActiveLeveragedOrders: u64 = 2;

const PAGE_CAPACITY: u64 = 64;

/// Active leveraged-order scan source.
public struct LiquidationBook has store {
    pages: Table<u64, OrderIdPage>,
    /// Page IDs in ascending order-ID order.
    page_ids: vector<u64>,
    /// Maximum order ID stored in each page, aligned with `page_ids`.
    max_order_ids: vector<u256>,
    next_page_id: u64,
    active_order_count: u64,
    /// Last order ID visited by the passive liquidation scan.
    passive_watermark: Option<u256>,
}

/// One bounded sorted page of active liquidation candidate order IDs.
public struct OrderIdPage has store {
    order_ids: vector<u256>,
}

/// Transient page position used while building one liquidation candidate batch.
public struct ScanCursor has copy, drop {
    page_ix: u64,
    offset: u64,
}

// === Public-Package Functions ===

/// The single definition of the liquidation knock-out test: live gross value at
/// or below the configured multiple of the static floor (`gross <= floor / ltv`).
/// The policy value (`liquidation_ltv`) is supplied from the caller's config
/// snapshot; this module holds no policy state. Leveraged-only is the caller's
/// duty — a 1x order's zero floor would spuriously pass this test.
public(package) fun is_under_liquidation_floor(
    gross_value: u64,
    floor_amount: u64,
    liquidation_ltv: u64,
): bool {
    gross_value <= math::div(floor_amount, liquidation_ltv)
}

public(package) fun contains_active_order(book: &LiquidationBook, order: &Order): bool {
    if (!order.is_leveraged() || book.active_order_count == 0) return false;

    let order_id = order.id();
    let page_ix = lower_bound(&book.max_order_ids, order_id);
    if (page_ix >= book.page_ids.length()) return false;

    let page = &book.pages[book.page_ids[page_ix]];
    let offset = lower_bound(&page.order_ids, order_id);
    offset < page.order_ids.length() && page.order_ids[offset] == order_id
}

/// Sum the NAV floor-correction term over the active leveraged book:
/// `Σ min(qty·range_price(lower, higher), floor_shares)`.
///
/// One-x orders are never inserted and liquidated orders are removed. Boundary
/// prices come from the payout walk's memo, and every finite leveraged boundary
/// must be present there. The correction is rounded and capped independently for
/// each still-active leveraged order; it does not apply the liquidation threshold.
public(package) fun correction_value(book: &LiquidationBook, memo: &PriceMemo): u64 {
    let mut correction = 0;
    let mut cursor = book.first_cursor();
    while (cursor.is_some()) {
        let scan = cursor.destroy_some();
        let order = order::from_order_id(book.order_id_at(scan));
        let range_value = math::mul(
            memo.cached_range_price(order.lower_tick(), order.higher_tick()),
            order.quantity(),
        );
        correction = correction + range_value.min(order.floor_shares());
        cursor = book.next_cursor(scan);
    };
    correction
}

/// Envelope twin of `correction_value` for the read-only interval lane:
/// `Σ min(gross envelope, floor_shares)` with pointwise interval min against
/// the exact static floor.
public(package) fun correction_value_interval(
    book: &LiquidationBook,
    memo: &IntervalPriceMemo,
): Interval {
    let mut correction = interval::exact(0);
    let mut cursor = book.first_cursor();
    while (cursor.is_some()) {
        let scan = cursor.destroy_some();
        let order = order::from_order_id(book.order_id_at(scan));
        let gross = memo
            .cached_range_price_interval(order.lower_tick(), order.higher_tick())
            .mul(&interval::exact(order.quantity()));
        correction = correction.add(&gross.min(&interval::exact(order.floor_shares())));
        cursor = book.next_cursor(scan);
    };
    correction
}

public(package) fun new(ctx: &mut TxContext): LiquidationBook {
    LiquidationBook {
        pages: table::new(ctx),
        page_ids: vector[],
        max_order_ids: vector[],
        next_page_id: 0,
        active_order_count: 0,
        passive_watermark: option::none(),
    }
}

/// Return at most `budget` candidates. Most come from the priority head; the
/// remainder advances a persistent cursor through the tail so lower-priority
/// active orders are eventually reconsidered.
public(package) fun select_liquidation_candidates(
    book: &mut LiquidationBook,
    budget: u64,
): vector<u256> {
    let mut candidates = vector[];
    if (book.active_order_count == 0 || budget == 0) {
        return candidates
    };

    let tail_budget = budget / constants::liquidation_tail_scan_divisor!();
    let head_budget = budget - tail_budget;
    let tail_start = book.collect_head_candidates(&mut candidates, head_budget);
    let scan_budget = budget - candidates.length();
    book.collect_passive_candidates(&mut candidates, scan_budget, tail_start);
    candidates
}

/// Fused valuation scan: visit every active leveraged order once, accumulate the
/// NAV floor-correction over survivors, and compact away every order at or below
/// the knock-out threshold at the memo's prices. Killed orders are returned for
/// the caller to settle against the payout tree and events — this module owns
/// only their index removal. Survivor correction is exactly `Σ floor_shares` —
/// bit-identical to `correction_value`'s min-cap for every survivor (surviving
/// means gross exceeds `floor / ltv >= floor` because a valid LTV is below 1.0,
/// so the min always picks the floor) — and compaction preserves each page's
/// sort order, so lookups stay valid. Page sizes are left as compacted (later
/// removals re-merge small pages); the passive scan watermark survives — it is
/// an order ID resolved against current geometry — and clears only when the
/// book empties, mirroring removal.
public(package) fun scan_compact(
    book: &mut LiquidationBook,
    memo: &PriceMemo,
    liquidation_ltv: u64,
): (u64, vector<Order>) {
    let mut correction = 0;
    let mut killed = vector[];
    if (book.active_order_count == 0) return (correction, killed);

    let mut page_ix = 0;
    while (page_ix < book.page_ids.length()) {
        let page_id = book.page_ids[page_ix];
        let new_max = {
            let page = book.pages.borrow_mut(page_id);
            let len = page.order_ids.length();
            let mut read = 0;
            let mut write = 0;
            while (read < len) {
                let order_id = page.order_ids[read];
                let order = order::from_order_id(order_id);
                let range_value = math::mul(
                    memo.cached_range_price(order.lower_tick(), order.higher_tick()),
                    order.quantity(),
                );
                if (
                    is_under_liquidation_floor(
                        range_value,
                        order.floor_shares(),
                        liquidation_ltv,
                    )
                ) {
                    killed.push_back(order);
                } else {
                    correction = correction + order.floor_shares();
                    *(&mut page.order_ids[write]) = order_id;
                    write = write + 1;
                };
                read = read + 1;
            };
            while (page.order_ids.length() > write) {
                page.order_ids.pop_back();
            };
            if (write > 0) option::some(page.order_ids[write - 1]) else option::none()
        };

        if (new_max.is_some()) {
            *(&mut book.max_order_ids[page_ix]) = new_max.destroy_some();
            page_ix = page_ix + 1;
        } else {
            // Removing the emptied page shifts its successor into `page_ix`;
            // do not advance.
            book.remove_page_at(page_ix);
        };
    };

    book.active_order_count = book.active_order_count - killed.length();
    if (book.active_order_count == 0) {
        book.passive_watermark = option::none();
    };
    (correction, killed)
}

/// Envelope twin of `scan_compact` for the interval valuation lane. The
/// knock-out test reads the LOW side of each order's gross envelope: an order
/// that might be at or below its threshold is killed, so the mark never counts
/// a claim the protocol might not honor (kill-on-possible, protocol-favored).
/// Survivor correction stays the exact integer `Σ floor_shares`; compaction and
/// bookkeeping are identical to `scan_compact`.
public(package) fun scan_compact_interval(
    book: &mut LiquidationBook,
    memo: &IntervalPriceMemo,
    liquidation_ltv: u64,
): (u64, vector<Order>) {
    let mut correction = 0;
    let mut killed = vector[];
    if (book.active_order_count == 0) return (correction, killed);

    let mut page_ix = 0;
    while (page_ix < book.page_ids.length()) {
        let page_id = book.page_ids[page_ix];
        let new_max = {
            let page = book.pages.borrow_mut(page_id);
            let len = page.order_ids.length();
            let mut read = 0;
            let mut write = 0;
            while (read < len) {
                let order_id = page.order_ids[read];
                let order = order::from_order_id(order_id);
                let gross = memo
                    .cached_range_price_interval(order.lower_tick(), order.higher_tick())
                    .mul(&interval::exact(order.quantity()));
                if (
                    is_under_liquidation_floor(
                        gross.lo(),
                        order.floor_shares(),
                        liquidation_ltv,
                    )
                ) {
                    killed.push_back(order);
                } else {
                    correction = correction + order.floor_shares();
                    *(&mut page.order_ids[write]) = order_id;
                    write = write + 1;
                };
                read = read + 1;
            };
            while (page.order_ids.length() > write) {
                page.order_ids.pop_back();
            };
            if (write > 0) option::some(page.order_ids[write - 1]) else option::none()
        };

        if (new_max.is_some()) {
            *(&mut book.max_order_ids[page_ix]) = new_max.destroy_some();
            page_ix = page_ix + 1;
        } else {
            // Removing the emptied page shifts its successor into `page_ix`;
            // do not advance.
            book.remove_page_at(page_ix);
        };
    };

    book.active_order_count = book.active_order_count - killed.length();
    if (book.active_order_count == 0) {
        book.passive_watermark = option::none();
    };
    (correction, killed)
}

/// Index a leveraged order for liquidation scanning; no-op for 1x orders.
public(package) fun insert_order(book: &mut LiquidationBook, order: &Order) {
    if (!order.is_leveraged()) return;

    assert!(
        book.active_order_count < constants::max_active_leveraged_orders!(),
        EMaxActiveLeveragedOrders,
    );
    book.insert_active_order_id(order.id());
}

/// Remove a leveraged order from the active scan index; no-op for 1x orders.
public(package) fun remove_order(book: &mut LiquidationBook, order: &Order) {
    if (!order.is_leveraged()) return;

    book.remove_active_order_id(order.id());
}

// === Private Functions ===

fun insert_active_order_id(book: &mut LiquidationBook, order_id: u256) {
    if (book.active_order_count == 0) {
        let page_id = book.new_page_id();
        book.pages.add(page_id, OrderIdPage { order_ids: vector[order_id] });
        book.page_ids.push_back(page_id);
        book.max_order_ids.push_back(order_id);
        book.active_order_count = 1;
        return
    };

    let page_ix = book.page_index_for_insert(order_id);
    let page_id = book.page_ids[page_ix];
    let (left_max, should_split, right_order_ids) = {
        let mut should_split = false;
        let mut right_order_ids: vector<u256> = vector[];
        let page = book.pages.borrow_mut(page_id);
        let offset = lower_bound(&page.order_ids, order_id);
        assert!(
            offset == page.order_ids.length() || page.order_ids[offset] != order_id,
            EActiveOrderAlreadyExists,
        );
        page.order_ids.insert(order_id, offset);

        if (page.order_ids.length() > PAGE_CAPACITY) {
            should_split = true;
            let split_at = page.order_ids.length() / 2;
            while (page.order_ids.length() > split_at) {
                right_order_ids.push_back(page.order_ids.remove(split_at));
            };
        };
        (page.order_ids[page.order_ids.length() - 1], should_split, right_order_ids)
    };

    *(&mut book.max_order_ids[page_ix]) = left_max;
    if (should_split) {
        let right_max = right_order_ids[right_order_ids.length() - 1];
        let right_page_id = book.new_page_id();
        book.pages.add(right_page_id, OrderIdPage { order_ids: right_order_ids });
        book.page_ids.insert(right_page_id, page_ix + 1);
        book.max_order_ids.insert(right_max, page_ix + 1);
    };
    book.active_order_count = book.active_order_count + 1;
}

fun remove_active_order_id(book: &mut LiquidationBook, order_id: u256) {
    assert!(book.active_order_count > 0, EActiveOrderNotFound);
    let page_ix = lower_bound(&book.max_order_ids, order_id);
    assert!(page_ix < book.page_ids.length(), EActiveOrderNotFound);
    let page_id = book.page_ids[page_ix];
    let (remaining, new_max) = {
        let page = book.pages.borrow_mut(page_id);
        let offset = lower_bound(&page.order_ids, order_id);
        assert!(
            offset < page.order_ids.length() && page.order_ids[offset] == order_id,
            EActiveOrderNotFound,
        );
        page.order_ids.remove(offset);
        let remaining = page.order_ids.length();
        let new_max = if (remaining > 0) page.order_ids[remaining - 1] else 0;
        (remaining, new_max)
    };

    book.active_order_count = book.active_order_count - 1;
    if (remaining == 0) {
        book.remove_page_at(page_ix);
    } else {
        *(&mut book.max_order_ids[page_ix]) = new_max;
        book.merge_page_if_small(page_ix);
    };

    if (book.active_order_count == 0) {
        book.passive_watermark = option::none();
    };
}

fun collect_head_candidates(
    book: &LiquidationBook,
    candidates: &mut vector<u256>,
    budget: u64,
): Option<ScanCursor> {
    let mut count = 0;
    let mut candidate = book.first_cursor();
    while (count < budget && candidate.is_some()) {
        let cursor = candidate.destroy_some();
        candidates.push_back(book.order_id_at(cursor));
        count = count + 1;
        candidate = book.next_cursor(cursor);
    };
    candidate
}

fun collect_passive_candidates(
    book: &mut LiquidationBook,
    candidates: &mut vector<u256>,
    scan_budget: u64,
    tail_start: Option<ScanCursor>,
) {
    if (scan_budget == 0 || tail_start.is_none()) return;

    let tail_start_cursor = tail_start.destroy_some();
    let passive_domain_count = book.active_order_count - candidates.length();
    if (passive_domain_count == 0) return;

    let mut candidate = book.first_passive_cursor(tail_start_cursor);
    let mut added = 0;
    let mut visited = 0;
    let mut last_order_id = option::none();
    while (added < scan_budget && visited < passive_domain_count) {
        let order_id = book.order_id_at(candidate);
        candidates.push_back(order_id);
        added = added + 1;
        last_order_id = option::some(order_id);
        visited = visited + 1;
        candidate = book.next_cursor(candidate).destroy_or!(tail_start_cursor);
    };

    if (last_order_id.is_some()) {
        book.passive_watermark = last_order_id;
    };
}

fun first_passive_cursor(book: &LiquidationBook, tail_start: ScanCursor): ScanCursor {
    if (book.passive_watermark.is_some()) {
        let candidate = book.cursor_after_order_id(*book.passive_watermark.borrow());
        if (candidate.is_some()) {
            let cursor = candidate.destroy_some();
            if (!cursor.is_before(tail_start)) return cursor
        };
    };

    tail_start
}

fun first_cursor(book: &LiquidationBook): Option<ScanCursor> {
    if (book.active_order_count == 0) return option::none();

    option::some(ScanCursor { page_ix: 0, offset: 0 })
}

fun next_cursor(book: &LiquidationBook, cursor: ScanCursor): Option<ScanCursor> {
    let page = &book.pages[book.page_ids[cursor.page_ix]];
    let next_offset = cursor.offset + 1;
    if (next_offset < page.order_ids.length()) {
        option::some(ScanCursor { page_ix: cursor.page_ix, offset: next_offset })
    } else {
        let next_page_ix = cursor.page_ix + 1;
        if (next_page_ix < book.page_ids.length()) {
            option::some(ScanCursor { page_ix: next_page_ix, offset: 0 })
        } else {
            option::none()
        }
    }
}

fun cursor_after_order_id(book: &LiquidationBook, order_id: u256): Option<ScanCursor> {
    let page_ix = upper_bound(&book.max_order_ids, order_id);
    if (page_ix >= book.page_ids.length()) return option::none();

    let page = &book.pages[book.page_ids[page_ix]];
    let offset = upper_bound(&page.order_ids, order_id);
    if (offset < page.order_ids.length()) {
        option::some(ScanCursor { page_ix, offset })
    } else if (page_ix + 1 < book.page_ids.length()) {
        option::some(ScanCursor { page_ix: page_ix + 1, offset: 0 })
    } else {
        option::none()
    }
}

fun order_id_at(book: &LiquidationBook, cursor: ScanCursor): u256 {
    book.pages[book.page_ids[cursor.page_ix]].order_ids[cursor.offset]
}

fun is_before(cursor: ScanCursor, other: ScanCursor): bool {
    cursor.page_ix < other.page_ix || (cursor.page_ix == other.page_ix && cursor.offset < other.offset)
}

fun new_page_id(book: &mut LiquidationBook): u64 {
    let page_id = book.next_page_id;
    book.next_page_id = page_id + 1;
    page_id
}

fun page_index_for_insert(book: &LiquidationBook, order_id: u256): u64 {
    let page_ix = lower_bound(&book.max_order_ids, order_id);
    if (page_ix < book.page_ids.length()) {
        page_ix
    } else {
        book.page_ids.length() - 1
    }
}

fun page_length(book: &LiquidationBook, page_ix: u64): u64 {
    book.pages[book.page_ids[page_ix]].order_ids.length()
}

fun remove_page_at(book: &mut LiquidationBook, page_ix: u64) {
    let page_id = book.page_ids.remove(page_ix);
    book.max_order_ids.remove(page_ix);
    let OrderIdPage { order_ids } = book.pages.remove(page_id);
    order_ids.destroy_empty();
}

fun merge_page_if_small(book: &mut LiquidationBook, page_ix: u64) {
    let page_count = book.page_ids.length();
    if (page_count <= 1) return;

    let page_len = book.page_length(page_ix);
    if (page_len >= PAGE_CAPACITY / 2) return;

    if (page_ix > 0) {
        let left_ix = page_ix - 1;
        if (book.page_length(left_ix) + page_len <= PAGE_CAPACITY) {
            book.merge_adjacent_pages(left_ix, page_ix);
            return
        };
    };

    if (page_ix + 1 < page_count) {
        let right_ix = page_ix + 1;
        if (page_len + book.page_length(right_ix) <= PAGE_CAPACITY) {
            book.merge_adjacent_pages(page_ix, right_ix);
        };
    };
}

fun merge_adjacent_pages(book: &mut LiquidationBook, left_ix: u64, right_ix: u64) {
    let left_page_id = book.page_ids[left_ix];
    let right_page_id = book.page_ids[right_ix];
    let OrderIdPage { order_ids: right_order_ids } = book.pages.remove(right_page_id);
    let new_max = {
        let left_page = book.pages.borrow_mut(left_page_id);
        left_page.order_ids.append(right_order_ids);
        left_page.order_ids[left_page.order_ids.length() - 1]
    };
    *(&mut book.max_order_ids[left_ix]) = new_max;
    book.page_ids.remove(right_ix);
    book.max_order_ids.remove(right_ix);
}

fun lower_bound(order_ids: &vector<u256>, order_id: u256): u64 {
    let mut lo = 0;
    let mut hi = order_ids.length();
    while (lo < hi) {
        let mid = (lo + hi) / 2;
        if (order_ids[mid] < order_id) {
            lo = mid + 1;
        } else {
            hi = mid;
        };
    };
    lo
}

fun upper_bound(order_ids: &vector<u256>, order_id: u256): u64 {
    let mut lo = 0;
    let mut hi = order_ids.length();
    while (lo < hi) {
        let mid = (lo + hi) / 2;
        if (order_ids[mid] <= order_id) {
            lo = mid + 1;
        } else {
            hi = mid;
        };
    };
    lo
}
