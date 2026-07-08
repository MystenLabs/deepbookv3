// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// LP request book and share issuance for the pool vault.
///
/// `LpBook` owns the PLP treasury cap plus the async supply/withdraw queues.
/// `plp` owns the shared `PoolVault`, valuation, and pool cash accounting; it
/// delegates request/cancel and frozen-mark queue drains here.
module deepbook_predict::lp_book;

use deepbook_predict::{constants, pool_accounting::Ledger, vault_events};
use dusdc::dusdc::DUSDC;
use fixed_math::math;
use sui::{balance::{Self, Balance}, coin::{Coin, TreasuryCap}, table::{Self, Table}};

const ERequestNotFound: u64 = 0;
const EBelowMinSupplyRequest: u64 = 1;
const EBelowMinWithdrawRequest: u64 = 2;
const ENotRequestOwner: u64 = 3;

const PAGE_CAPACITY: u64 = 64;

/// Pool LP state: share issuance plus queued supply/withdraw escrow.
public struct LpBook<phantom LP> has store {
    treasury_cap: TreasuryCap<LP>,
    supply_queue: RequestQueue<DUSDC>,
    withdraw_queue: RequestQueue<LP>,
    /// Permanent minimum-liquidity shares minted once at genesis
    /// (`plp::lock_capital`). Held here with no withdraw path, so `total_supply`
    /// stays > 0 for the life of the pool and the supply==0 bootstrap branch is
    /// unreachable. Withdrawal-rounding dust accrues to this position.
    locked_lp: Balance<LP>,
}

/// One queued supply/withdraw request. `amount` is the escrowed value in the
/// queue's asset — DUSDC for the supply queue, LP shares for the withdraw queue.
public struct RequestEntry has copy, drop, store {
    index: u64,
    /// Owning account, carried so a fill can attribute to the account directly
    /// rather than only the derived `recipient` address (address is not invertible).
    account_id: ID,
    recipient: address,
    amount: u64,
}

/// Non-empty request page. Page IDs are `index / PAGE_CAPACITY`; the linked list
/// skips pages that became empty after removals.
public struct RequestPage has store {
    prev: Option<u64>,
    next: Option<u64>,
    entries: vector<RequestEntry>,
}

/// FIFO queue keyed by monotonically increasing request indexes.
///
/// Cancelled requests are physically removed. `pending` is the live request count,
/// not the span between head and tail indexes; only non-empty pages stay linked.
public struct RequestQueue<phantom T> has store {
    pages: Table<u64, RequestPage>,
    head_page_id: Option<u64>,
    tail_page_id: Option<u64>,
    next_index: u64,
    pending: u64,
    escrow: Balance<T>,
}

/// Frozen flush share-price mark: `pool_value` over `total_supply`. Carried as one
/// value so the supply/withdraw pricing helpers read each term by name and cannot
/// transpose the numerator and denominator.
public struct FlushMark has drop {
    pool_value: u64,
    total_supply: u64,
}

/// Result of draining both LP queues at one frozen mark.
public struct DrainSummary has copy, drop {
    supplies_filled: u64,
    withdrawals_filled: u64,
    supplies_processed: u64,
    withdrawals_processed: u64,
}

// === Public-Package Functions ===

public(package) fun new<LP>(treasury_cap: TreasuryCap<LP>, ctx: &mut TxContext): LpBook<LP> {
    LpBook {
        treasury_cap,
        supply_queue: queue_new(ctx),
        withdraw_queue: queue_new(ctx),
        locked_lp: balance::zero(),
    }
}

public(package) fun total_supply<LP>(book: &LpBook<LP>): u64 {
    book.treasury_cap.total_supply()
}

/// Mint the permanent minimum-liquidity shares held by the book and never
/// withdrawable, keeping `total_supply > 0` after genesis so the supply==0
/// bootstrap branch is structurally unreachable. Called once by `plp::lock_capital`.
public(package) fun mint_locked_liquidity<LP>(book: &mut LpBook<LP>, amount: u64) {
    book.locked_lp.join(book.treasury_cap.mint_balance(amount));
}

public(package) fun supply_requests_pending<LP>(book: &LpBook<LP>): u64 {
    book.supply_queue.pending
}

public(package) fun withdraw_requests_pending<LP>(book: &LpBook<LP>): u64 {
    book.withdraw_queue.pending
}

public(package) fun request_supply<LP>(
    book: &mut LpBook<LP>,
    payment: Coin<DUSDC>,
    account_id: ID,
    recipient: address,
): u64 {
    assert!(payment.value() >= constants::min_supply_request!(), EBelowMinSupplyRequest);
    book.supply_queue.enqueue(account_id, recipient, payment.into_balance())
}

public(package) fun request_withdraw<LP>(
    book: &mut LpBook<LP>,
    lp: Coin<LP>,
    account_id: ID,
    recipient: address,
): u64 {
    assert!(lp.value() >= constants::min_withdraw_request!(), EBelowMinWithdrawRequest);
    book.withdraw_queue.enqueue(account_id, recipient, lp.into_balance())
}

public(package) fun cancel_supply_request<LP>(
    book: &mut LpBook<LP>,
    recipient: address,
    index: u64,
): (ID, u64, Balance<DUSDC>) {
    let (request, refund) = book.supply_queue.remove_for_recipient(index, recipient);
    (request.account_id, request.amount, refund)
}

public(package) fun cancel_withdraw_request<LP>(
    book: &mut LpBook<LP>,
    recipient: address,
    index: u64,
): (ID, u64, Balance<LP>) {
    let (request, refund) = book.withdraw_queue.remove_for_recipient(index, recipient);
    (request.account_id, request.amount, refund)
}

public(package) fun new_flush_mark(pool_value: u64, total_supply: u64): FlushMark {
    FlushMark { pool_value, total_supply }
}

public(package) fun supplies_filled(summary: &DrainSummary): u64 {
    summary.supplies_filled
}

public(package) fun withdrawals_filled(summary: &DrainSummary): u64 {
    summary.withdrawals_filled
}

public(package) fun supplies_processed(summary: &DrainSummary): u64 {
    summary.supplies_processed
}

public(package) fun withdrawals_processed(summary: &DrainSummary): u64 {
    summary.withdrawals_processed
}

public(package) fun requests_processed(summary: &DrainSummary): u64 {
    summary.supplies_processed + summary.withdrawals_processed
}

/// Drain both LP queues at the frozen flush mark (`pool_value` over `total_supply`),
/// supplies first then withdrawals. `supply_budget` / `withdraw_budget` bound how many
/// live requests each queue may process this flush; processed means filled or
/// protocol-refunded as non-executable at the mark. `None` drains that queue fully.
/// The two budgets are independent, so supply pressure can never starve withdrawals.
/// Supplies run first on purpose: their fresh idle cash funds same-flush withdrawals.
/// User-cancelled requests are removed at cancel time and never spend flush capacity.
public(package) fun drain<LP>(
    book: &mut LpBook<LP>,
    ledger: &mut Ledger,
    mark: FlushMark,
    pool_vault_id: ID,
    supply_budget: Option<u64>,
    withdraw_budget: Option<u64>,
    ctx: &mut TxContext,
): DrainSummary {
    let mut supplies_filled = 0;
    let mut supplies_processed = 0;
    let mut withdrawals_filled = 0;
    let mut withdrawals_processed = 0;

    while (under_budget(&supply_budget, supplies_processed) && !book.supply_queue.is_empty()) {
        let (request, escrowed) = book.supply_queue.pop_front();
        let shares = quote_supply_shares(request.amount, &mark);
        supplies_processed = supplies_processed + 1;
        if (shares.is_none()) {
            shares.destroy_none();
            refund_supply_request(pool_vault_id, request, escrowed);
        } else {
            let shares = shares.destroy_some();
            ledger.receive_idle(escrowed);
            let shares_minted = book.treasury_cap.mint_balance(shares);
            balance::send_funds(shares_minted, request.recipient);
            vault_events::emit_supply_filled(
                pool_vault_id,
                request.account_id,
                request.recipient,
                request.index,
                request.amount,
                shares,
            );
            supplies_filled = supplies_filled + 1;
        };
    };

    while (under_budget(&withdraw_budget, withdrawals_processed) && !book.withdraw_queue.is_empty()) {
        let request = book.withdraw_queue.front_request();
        let payout = quote_withdraw_dusdc(request.amount, &mark);
        if (payout.is_none()) {
            payout.destroy_none();
            let (request, escrowed_lp) = book.withdraw_queue.pop_front();
            withdrawals_processed = withdrawals_processed + 1;
            refund_withdraw_request(pool_vault_id, request, escrowed_lp);
        } else {
            let payout = payout.destroy_some();
            if (ledger.idle_balance() < payout) {
                // FIFO-until-dry: idle can't cover the head request, so stop and carry
                // this and every later withdrawal to reprice next flush.
                break
            };
            let (_, escrowed_lp) = book.withdraw_queue.pop_front();
            let payout_cash = ledger.withdraw_idle(payout);
            book.treasury_cap.burn(escrowed_lp.into_coin(ctx));
            balance::send_funds(payout_cash, request.recipient);
            vault_events::emit_withdraw_filled(
                pool_vault_id,
                request.account_id,
                request.recipient,
                request.index,
                request.amount,
                payout,
            );
            withdrawals_processed = withdrawals_processed + 1;
            withdrawals_filled = withdrawals_filled + 1;
        };
    };

    DrainSummary {
        supplies_filled,
        withdrawals_filled,
        supplies_processed,
        withdrawals_processed,
    }
}

/// Whether another request fits the budget: an unbounded (`None`) budget never
/// blocks; a bounded budget allows fills/refunds until `processed` reaches it.
fun under_budget(budget: &Option<u64>, processed: u64): bool {
    budget.is_none() || processed < *budget.borrow()
}

fun refund_supply_request(pool_vault_id: ID, request: RequestEntry, escrowed: Balance<DUSDC>) {
    balance::send_funds(escrowed, request.recipient);
    vault_events::emit_request_cancelled(
        pool_vault_id,
        request.account_id,
        request.recipient,
        request.index,
        request.amount,
        true,
    );
}

fun refund_withdraw_request<LP>(pool_vault_id: ID, request: RequestEntry, escrowed_lp: Balance<LP>) {
    balance::send_funds(escrowed_lp, request.recipient);
    vault_events::emit_request_cancelled(
        pool_vault_id,
        request.account_id,
        request.recipient,
        request.index,
        request.amount,
        false,
    );
}

// === Queue Helpers ===

fun queue_new<T>(ctx: &mut TxContext): RequestQueue<T> {
    RequestQueue {
        pages: table::new(ctx),
        head_page_id: option::none(),
        tail_page_id: option::none(),
        next_index: 0,
        pending: 0,
        escrow: balance::zero(),
    }
}

fun is_empty<T>(queue: &RequestQueue<T>): bool {
    queue.pending == 0
}

fun enqueue<T>(
    queue: &mut RequestQueue<T>,
    account_id: ID,
    recipient: address,
    escrow: Balance<T>,
): u64 {
    let index = queue.next_index;
    queue.next_index = index + 1;
    let page_id = queue.ensure_tail_page_for_index(index);
    let amount = escrow.value();
    queue
        .pages
        .borrow_mut(page_id)
        .entries
        .push_back(RequestEntry { index, account_id, recipient, amount });
    queue.escrow.join(escrow);
    queue.pending = queue.pending + 1;
    index
}

fun front_request<T>(queue: &RequestQueue<T>): RequestEntry {
    assert!(queue.pending > 0, ERequestNotFound);
    let page_id = *queue.head_page_id.borrow();
    queue.pages[page_id].entries[0]
}

fun pop_front<T>(queue: &mut RequestQueue<T>): (RequestEntry, Balance<T>) {
    let request = queue.front_request();
    queue.remove(request.index)
}

fun remove<T>(queue: &mut RequestQueue<T>, index: u64): (RequestEntry, Balance<T>) {
    let page_id = page_id_for_index(index);
    assert!(queue.pages.contains(page_id), ERequestNotFound);
    let (request, page_empty) = {
        let page = queue.pages.borrow_mut(page_id);
        let offset = entry_offset(&page.entries, index);
        let request = page.entries.remove(offset);
        (request, page.entries.length() == 0)
    };
    if (page_empty) {
        queue.unlink_empty_page(page_id);
    };
    queue.pending = queue.pending - 1;
    let escrow = queue.escrow.split(request.amount);
    (request, escrow)
}

fun remove_for_recipient<T>(
    queue: &mut RequestQueue<T>,
    index: u64,
    recipient: address,
): (RequestEntry, Balance<T>) {
    let page_id = page_id_for_index(index);
    assert!(queue.pages.contains(page_id), ERequestNotFound);
    let page = &queue.pages[page_id];
    let offset = entry_offset(&page.entries, index);
    assert!(page.entries[offset].recipient == recipient, ENotRequestOwner);
    queue.remove(index)
}

fun ensure_tail_page_for_index<T>(queue: &mut RequestQueue<T>, index: u64): u64 {
    let next_page_id = page_id_for_index(index);
    if (queue.tail_page_id.is_none()) {
        queue.pages.add(next_page_id, new_page(option::none(), option::none()));
        queue.head_page_id = option::some(next_page_id);
        queue.tail_page_id = option::some(next_page_id);
        return next_page_id
    };

    let tail_page_id = *queue.tail_page_id.borrow();
    if (tail_page_id == next_page_id) {
        return tail_page_id
    };

    queue.pages.borrow_mut(tail_page_id).next = option::some(next_page_id);
    queue.pages.add(next_page_id, new_page(option::some(tail_page_id), option::none()));
    queue.tail_page_id = option::some(next_page_id);
    next_page_id
}

fun new_page(prev: Option<u64>, next: Option<u64>): RequestPage {
    RequestPage { prev, next, entries: vector[] }
}

fun unlink_empty_page<T>(queue: &mut RequestQueue<T>, page_id: u64) {
    let RequestPage { prev, next, entries } = queue.pages.remove(page_id);
    entries.destroy_empty();

    if (prev.is_some()) {
        let prev_id = *prev.borrow();
        queue.pages.borrow_mut(prev_id).next = next;
    } else {
        queue.head_page_id = next;
    };

    if (next.is_some()) {
        let next_id = *next.borrow();
        queue.pages.borrow_mut(next_id).prev = prev;
    } else {
        queue.tail_page_id = prev;
    };
}

fun page_id_for_index(index: u64): u64 {
    index / PAGE_CAPACITY
}

fun entry_offset(entries: &vector<RequestEntry>, index: u64): u64 {
    let offset = entries.find_index!(|e| e.index == index);
    assert!(offset.is_some(), ERequestNotFound);
    offset.destroy_some()
}

// === Pricing Helpers ===

/// LP shares minted for `amount` DUSDC at the frozen flush mark. `None` means the
/// mark/request pair is not executable and the queued request must be refunded.
fun quote_supply_shares(amount: u64, mark: &FlushMark): Option<u64> {
    if (!mark.is_executable()) return option::none();
    // = amount * total_supply / pool_value, round down (supplier mints ≤1 ulp
    // fewer shares; the pool keeps the dust).
    nonzero_quote(math::try_mul_div_down(amount, mark.total_supply, mark.pool_value))
}

/// DUSDC owed for `shares` LP at the frozen flush mark. `None` means the
/// mark/request pair is not executable and the queued request must be refunded.
fun quote_withdraw_dusdc(shares: u64, mark: &FlushMark): Option<u64> {
    if (!mark.is_executable()) return option::none();
    // = shares * pool_value / total_supply, round down (withdrawer is paid ≤1 ulp
    // less; the pool keeps the dust).
    nonzero_quote(math::try_mul_div_down(shares, mark.pool_value, mark.total_supply))
}

fun is_executable(mark: &FlushMark): bool {
    if (mark.pool_value == 0 || mark.total_supply == 0) return false;
    let scaled_pool_value = (mark.pool_value as u128) * (constants::plp_price_unit!() as u128);
    let total_supply = mark.total_supply as u128;
    let min_value = total_supply * (constants::min_executable_plp_price!() as u128);
    let max_value = total_supply * (constants::max_executable_plp_price!() as u128);
    scaled_pool_value >= min_value && scaled_pool_value <= max_value
}

fun nonzero_quote(quote: Option<u64>): Option<u64> {
    if (quote.is_none()) {
        quote.destroy_none();
        option::none()
    } else {
        let quote = quote.destroy_some();
        if (quote == 0) option::none() else option::some(quote)
    }
}
