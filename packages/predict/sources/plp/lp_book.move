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
/// `min_output` is PLP shares for supply requests and DUSDC for withdrawals, and is
/// measured net of the supply/withdraw fee: it bounds what the requester actually
/// receives, not the pre-fee amount.
public struct RequestEntry has copy, drop, store {
    index: u64,
    /// Owning account, carried so a fill can attribute to the account directly
    /// rather than only the derived `recipient` address (address is not invertible).
    account_id: ID,
    recipient: address,
    amount: u64,
    min_output: u64,
    /// Frozen marks this request has already missed. Only ever non-zero when the
    /// protocol allows more than one attempt (`ProtocolConfig`), since at one
    /// attempt a miss refunds immediately.
    missed_flushes: u64,
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
    executable: bool,
    /// Supply-leg fee in FLOAT_SCALING, frozen with the mark so every request
    /// drained in this flush is charged the same rate. Already scaled by the
    /// utilization multiplier and clamped to `max_plp_fee_rate`.
    supply_fee_rate: u64,
    /// Withdraw-leg fee in FLOAT_SCALING, frozen with the mark alongside it.
    /// Already utilization-scaled and clamped, same as the supply leg.
    withdraw_fee_rate: u64,
    /// Utilization fee multiplier this flush froze, in FLOAT_SCALING. Carried so
    /// the flush event can report the multiplier the drain was handed, not a
    /// recomputed one.
    utilization_multiplier: u64,
}

/// Executable fill amounts for one queued request (or one partial slice of it) at
/// the frozen mark: `output` in the request's output asset — PLP shares for a
/// supply, DUSDC for a withdrawal — already net of `fee`, and the
/// DUSDC-denominated `fee` the pool retains. Both travel together because a fill
/// cannot be booked without charging its fee.
public struct FillQuote has copy, drop {
    output: u64,
    fee: u64,
}

/// Result of draining both LP queues at one frozen mark.
public struct DrainSummary has copy, drop {
    supplies_filled: u64,
    withdrawals_filled: u64,
    requests_processed: u64,
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
    min_plp_out: u64,
): u64 {
    assert!(payment.value() >= constants::min_supply_request!(), EBelowMinSupplyRequest);
    book.supply_queue.enqueue(account_id, recipient, payment.into_balance(), min_plp_out)
}

public(package) fun request_withdraw<LP>(
    book: &mut LpBook<LP>,
    lp: Coin<LP>,
    account_id: ID,
    recipient: address,
    min_dusdc_out: u64,
): u64 {
    assert!(lp.value() >= constants::min_withdraw_request!(), EBelowMinWithdrawRequest);
    book.withdraw_queue.enqueue(account_id, recipient, lp.into_balance(), min_dusdc_out)
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

/// Freeze one flush's pricing inputs: the `pool_value / total_supply` mark, the
/// per-leg (already utilization-scaled) fee rates, and the utilization multiplier,
/// in that order — supply before withdraw, matching every other signature in this
/// flow. Five same-typed arguments, so the order is stated here rather than left
/// to the call site; a transposition of the two rates is caught by
/// `flush_freezes_both_configured_fee_rates`.
public(package) fun new_flush_mark(
    pool_value: u64,
    total_supply: u64,
    supply_fee_rate: u64,
    withdraw_fee_rate: u64,
    utilization_multiplier: u64,
): FlushMark {
    FlushMark {
        pool_value,
        total_supply,
        executable: is_executable_mark(pool_value, total_supply),
        supply_fee_rate,
        withdraw_fee_rate,
        utilization_multiplier,
    }
}

/// The supply-leg rate this mark froze. Read off the mark rather than re-read from
/// config so the flush event reports what the drain was actually handed: a mark
/// built with the wrong rate is otherwise invisible to every observer, since the
/// withdraw leg cannot be driven behaviourally from a Move test.
public(package) fun supply_fee_rate(mark: &FlushMark): u64 {
    mark.supply_fee_rate
}

/// The withdraw-leg rate this mark froze; same reasoning as `supply_fee_rate`.
public(package) fun withdraw_fee_rate(mark: &FlushMark): u64 {
    mark.withdraw_fee_rate
}

/// The utilization multiplier this mark froze; same reasoning as the fee-rate
/// accessors — the event reports what the drain was handed.
public(package) fun utilization_multiplier(mark: &FlushMark): u64 {
    mark.utilization_multiplier
}

public(package) fun supplies_filled(summary: &DrainSummary): u64 {
    summary.supplies_filled
}

public(package) fun withdrawals_filled(summary: &DrainSummary): u64 {
    summary.withdrawals_filled
}

public(package) fun requests_processed(summary: &DrainSummary): u64 {
    summary.requests_processed
}

/// Drain both LP queues at the frozen flush mark (`pool_value` over `total_supply`),
/// supplies first then withdrawals. `supply_budget` / `withdraw_budget` bound how many
/// head requests each queue may process this flush; processed means filled,
/// protocol-refunded as non-executable at the mark, or a live limit miss. `None` makes
/// that queue unbounded. The two budgets are independent, so supply pressure can never
/// starve withdrawals.
///
/// `max_limit_misses` is the admin-tunable attempt count from `ProtocolConfig`. At `1`
/// every head is resolved by the flush that reaches it — filled or refunded — so no
/// request a mark cannot fill can hold up the requests behind it. Above `1` a missing
/// head stays queued and stops that queue for the flush, which is what RP-12 trades
/// away for a resting limit.
///
/// `max_pool_value` caps the LP-attributable pool value supplies may raise the pool
/// to. It is applied only to the supply pass, against the frozen mark plus the
/// supplies filled so far this flush, so a run of individually-fitting requests cannot
/// collectively overshoot. Withdrawals drain afterwards and do not give back headroom
/// within the same flush — the mark is frozen, so the room they free is priced at the
/// next one (RP-23).
///
/// Supplies run first on purpose: their fresh idle cash funds same-flush withdrawals.
/// User-cancelled requests are removed at cancel time and never spend flush capacity.
/// Every fill is charged its leg's frozen fee rate on the DUSDC it actually fills —
/// the slice, not the whole request, when the fill is partial. The two legs carry
/// independent rates and the supply leg ships at zero. Refunded and still-queued
/// requests are never charged.
public(package) fun drain<LP>(
    book: &mut LpBook<LP>,
    ledger: &mut Ledger,
    mark: FlushMark,
    pool_vault_id: ID,
    supply_budget: Option<u64>,
    withdraw_budget: Option<u64>,
    max_limit_misses: u64,
    max_pool_value: u64,
    ctx: &mut TxContext,
): DrainSummary {
    let (supplies_filled, supplies_processed) = drain_supply_queue(
        book,
        ledger,
        &mark,
        pool_vault_id,
        &supply_budget,
        max_limit_misses,
        max_pool_value,
    );
    let (withdrawals_filled, withdrawals_processed) = drain_withdraw_queue(
        book,
        ledger,
        &mark,
        pool_vault_id,
        &withdraw_budget,
        max_limit_misses,
        ctx,
    );

    DrainSummary {
        supplies_filled,
        withdrawals_filled,
        requests_processed: supplies_processed + withdrawals_processed,
    }
}

fun drain_supply_queue<LP>(
    book: &mut LpBook<LP>,
    ledger: &mut Ledger,
    mark: &FlushMark,
    pool_vault_id: ID,
    budget: &Option<u64>,
    max_limit_misses: u64,
    max_pool_value: u64,
): (u64, u64) {
    let mut filled = 0;
    let mut processed = 0;
    // Runs forward from the frozen mark as supplies fill, so a flush cannot admit
    // several individually-fitting requests that collectively exceed the cap. The
    // frozen mark is the pool value BEFORE this drain; each fill joins its escrow to
    // idle, raising pool value by exactly `amount`.
    let mut pool_value = mark.pool_value;

    while (under_budget(budget, processed) && !book.supply_queue.is_empty()) {
        let request = book.supply_queue.front_request();
        let quote = mark.quote_supply_shares(request.amount);
        if (quote.is_none()) {
            processed = processed + 1;
            quote.destroy_none();
            let (request, escrowed) = book.supply_queue.pop_front();
            refund_supply_request(
                pool_vault_id,
                request,
                escrowed,
                constants::request_cancel_reason_non_executable!(),
                book.supply_queue.pending,
            );
        } else {
            // The whole-request quote gates the limit; the fee actually charged is the
            // prefix's, quoted below on the slice this drain fills.
            let FillQuote { output: shares, fee: _ } = quote.destroy_some();
            if (shares < request.min_output) {
                processed = processed + 1;
                // Counted off the copied entry so the refund path does no page write:
                // at one attempt the entry is popped on this very miss.
                let missed_flushes = request.missed_flushes + 1;
                if (missed_flushes >= max_limit_misses) {
                    let (request, escrowed) = book.supply_queue.pop_front();
                    refund_supply_request(
                        pool_vault_id,
                        request,
                        escrowed,
                        constants::request_cancel_reason_limit_missed!(),
                        book.supply_queue.pending,
                    );
                } else {
                    book.supply_queue.record_front_limit_miss();
                    emit_request_limit_missed(
                        pool_vault_id,
                        &request,
                        true,
                        shares,
                        missed_flushes,
                        max_limit_misses,
                    );
                    break
                };
            } else {
                // Take whatever the cap leaves room for; a request too big for the room
                // left keeps its place at the head with the unfilled balance escrowed.
                let headroom = max_pool_value.saturating_sub(pool_value);
                let fill_amount = request.amount.min(headroom);
                let partial = fill_amount < request.amount;
                let fill_quote = mark.quote_supply_shares(fill_amount);
                if (fill_quote.is_none()) {
                    // No room, or a prefix so small it prices to zero shares. Stop the
                    // pass: with the cap reached, nothing behind this head could fill
                    // either, so walking the rest of the queue only spends flush budget
                    // and events to refuse each one.
                    break
                };
                let FillQuote { output: fill_shares, fee } = fill_quote.destroy_some();
                // Capacity is judged on the prefix this drain would actually mint, not
                // on the whole request: a request whose full quote would overflow the
                // treasury can still have an executable slice while the rest waits.
                if (fill_shares > std::u64::max_value!() - book.treasury_cap.total_supply()) {
                    if (!partial) {
                        processed = processed + 1;
                        let (request, escrowed) = book.supply_queue.pop_front();
                        refund_supply_request(
                            pool_vault_id,
                            request,
                            escrowed,
                            constants::request_cancel_reason_non_executable!(),
                            book.supply_queue.pending,
                        );
                    };
                    break
                };
                // The prefix is quoted on its own and rounds down, so clearing the limit
                // on the whole request does not imply clearing it on a slice. Hold the
                // slice to the request's own price — `ceil` of the proportional share —
                // and carry rather than fill below it. Rounding the pool's quote up
                // instead would pay the difference out of the LPs who stay.
                let min_for_prefix = math::mul_div_up(
                    request.min_output,
                    fill_amount,
                    request.amount,
                );
                if (fill_shares < min_for_prefix) break;
                processed = processed + 1;
                let escrowed = if (partial) {
                    book.supply_queue.fill_front_partially(fill_amount)
                } else {
                    let (_, escrowed) = book.supply_queue.pop_front();
                    escrowed
                };
                ledger.receive_idle(escrowed);
                pool_value = pool_value + fill_amount;
                let shares_minted = book.treasury_cap.mint_balance(fill_shares);
                balance::send_funds(shares_minted, request.recipient);
                vault_events::emit_supply_filled(
                    pool_vault_id,
                    request.account_id,
                    request.recipient,
                    request.index,
                    fill_amount,
                    fill_shares,
                    fee,
                    request.amount - fill_amount,
                    book.supply_queue.pending,
                );
                filled = filled + 1;
                if (partial) break
            };
        };
    };

    (filled, processed)
}

fun drain_withdraw_queue<LP>(
    book: &mut LpBook<LP>,
    ledger: &mut Ledger,
    mark: &FlushMark,
    pool_vault_id: ID,
    budget: &Option<u64>,
    max_limit_misses: u64,
    ctx: &mut TxContext,
): (u64, u64) {
    let mut filled = 0;
    let mut processed = 0;

    while (under_budget(budget, processed) && !book.withdraw_queue.is_empty()) {
        let request = book.withdraw_queue.front_request();
        let quote = mark.quote_withdraw_dusdc(request.amount);
        if (quote.is_none()) {
            quote.destroy_none();
            let (request, escrowed_lp) = book.withdraw_queue.pop_front();
            processed = processed + 1;
            refund_withdraw_request(
                pool_vault_id,
                request,
                escrowed_lp,
                constants::request_cancel_reason_non_executable!(),
                book.withdraw_queue.pending,
            );
        } else {
            let FillQuote { output: payout, fee } = quote.destroy_some();
            if (payout < request.min_output) {
                processed = processed + 1;
                let missed_flushes = request.missed_flushes + 1;
                if (missed_flushes >= max_limit_misses) {
                    let (request, escrowed_lp) = book.withdraw_queue.pop_front();
                    refund_withdraw_request(
                        pool_vault_id,
                        request,
                        escrowed_lp,
                        constants::request_cancel_reason_limit_missed!(),
                        book.withdraw_queue.pending,
                    );
                } else {
                    book.withdraw_queue.record_front_limit_miss();
                    emit_request_limit_missed(
                        pool_vault_id,
                        &request,
                        false,
                        payout,
                        missed_flushes,
                        max_limit_misses,
                    );
                    break
                };
            } else {
                // Pay as much of the head as idle covers. Shares to burn are floored, so
                // the pool never hands out cash it has not destroyed shares for, and the
                // payout is then quoted from those shares by the same helper a full fill
                // uses — a partial exit prices identically to a whole one, and at most a
                // ulp of idle is left behind rather than the requester being shorted.
                // Only the net leaves the pool, so idle is measured against the net and
                // the retained fee never has to be funded.
                let idle = ledger.idle_balance();
                let (burn_shares, payout, fee) = if (idle >= payout) {
                    (request.amount, payout, fee)
                } else {
                    // Checked, not the aborting form: this runs inside the mandatory
                    // flush, so an unrepresentable quote must carry like any other
                    // rather than abort the pool-wide drain (RP-2).
                    //
                    // Deliberately conservative with a fee set: this inverts idle at the
                    // GROSS price, so the slice's net payout undershoots idle by about
                    // the fee. Grossing idle up by `1/(1 - rate)` would fill marginally
                    // more but needs a second inversion rounded the pool's way at both
                    // steps; the unspent remainder is bounded by the fee and the next
                    // flush picks it up.
                    let affordable = math::try_mul_div_down(
                        idle,
                        mark.total_supply,
                        mark.pool_value,
                    );
                    if (affordable.is_none()) break;
                    let affordable = affordable.destroy_some();
                    // Same rounding hazard as the supply prefix: the affordable slice
                    // is quoted on its own and rounds down, so hold it to the request's
                    // own price rather than paying a hair under it.
                    let min_for_prefix = math::mul_div_up(
                        request.min_output,
                        affordable,
                        request.amount,
                    );
                    let partial_quote = mark.quote_withdraw_dusdc(affordable);
                    if (partial_quote.is_none() || partial_quote.borrow().output < min_for_prefix) {
                        // Idle buys no whole share, or those shares price to nothing.
                        // Carry the head and stop, as the dry queue always has.
                        break
                    };
                    let FillQuote {
                        output: partial_payout,
                        fee: partial_fee,
                    } = partial_quote.destroy_some();
                    (affordable, partial_payout, partial_fee)
                };
                let partial = burn_shares < request.amount;
                let escrowed_lp = if (partial) {
                    book.withdraw_queue.fill_front_partially(burn_shares)
                } else {
                    let (_, escrowed_lp) = book.withdraw_queue.pop_front();
                    escrowed_lp
                };
                let payout_cash = ledger.withdraw_idle(payout);
                book.treasury_cap.burn(escrowed_lp.into_coin(ctx));
                balance::send_funds(payout_cash, request.recipient);
                vault_events::emit_withdraw_filled(
                    pool_vault_id,
                    request.account_id,
                    request.recipient,
                    request.index,
                    burn_shares,
                    payout,
                    fee,
                    request.amount - burn_shares,
                    book.withdraw_queue.pending,
                );
                processed = processed + 1;
                filled = filled + 1;
                // Idle is spent to within a ulp, or to within the slice's fee when one
                // is set; everything behind carries either way, as FIFO requires.
                if (partial) break
            };
        };
    };

    (filled, processed)
}

/// Whether another request fits the budget: an unbounded (`None`) budget never
/// blocks; a bounded budget allows fills/refunds until `processed` reaches it.
fun under_budget(budget: &Option<u64>, processed: u64): bool {
    budget.is_none() || processed < *budget.borrow()
}

fun refund_supply_request(
    pool_vault_id: ID,
    request: RequestEntry,
    escrowed: Balance<DUSDC>,
    reason: u8,
    requests_pending_after: u64,
) {
    balance::send_funds(escrowed, request.recipient);
    vault_events::emit_request_cancelled(
        pool_vault_id,
        request.account_id,
        request.recipient,
        request.index,
        request.amount,
        true,
        reason,
        requests_pending_after,
    );
}

fun refund_withdraw_request<LP>(
    pool_vault_id: ID,
    request: RequestEntry,
    escrowed_lp: Balance<LP>,
    reason: u8,
    requests_pending_after: u64,
) {
    balance::send_funds(escrowed_lp, request.recipient);
    vault_events::emit_request_cancelled(
        pool_vault_id,
        request.account_id,
        request.recipient,
        request.index,
        request.amount,
        false,
        reason,
        requests_pending_after,
    );
}

fun emit_request_limit_missed(
    pool_vault_id: ID,
    request: &RequestEntry,
    is_supply: bool,
    quoted_output: u64,
    missed_flushes: u64,
    max_limit_misses: u64,
) {
    vault_events::emit_request_limit_missed(
        pool_vault_id,
        request.account_id,
        request.recipient,
        request.index,
        request.amount,
        is_supply,
        quoted_output,
        request.min_output,
        missed_flushes,
        max_limit_misses,
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
    min_output: u64,
): u64 {
    let index = queue.next_index;
    queue.next_index = index + 1;
    let page_id = queue.ensure_tail_page_for_index(index);
    let amount = escrow.value();
    queue
        .pages
        .borrow_mut(page_id)
        .entries
        .push_back(RequestEntry {
            index,
            account_id,
            recipient,
            amount,
            min_output,
            missed_flushes: 0,
        });
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

/// Fill `filled` of the head request and leave the rest queued in place, keeping the
/// request's queue position, index, and owner. Returns the escrow for the filled part,
/// so the queue's pooled escrow and the entry's `amount` shrink together.
///
/// The remaining `min_output` is scaled to the remaining amount so the request keeps
/// asking for the same *price* it originally did, and it is rounded **up** so the
/// carried limit is never laxer than what the requester signed up for: at worst they
/// are held to a fractionally stricter price, never a worse one.
fun fill_front_partially<T>(queue: &mut RequestQueue<T>, filled: u64): Balance<T> {
    assert!(queue.pending > 0, ERequestNotFound);
    let page_id = *queue.head_page_id.borrow();
    let entry = &mut queue.pages.borrow_mut(page_id).entries[0];
    // A caller that filled the whole request must pop it instead; leaving a zero-amount
    // entry queued would keep a live request nothing can ever serve.
    assert!(filled < entry.amount, ERequestNotFound);
    let remaining = entry.amount - filled;
    entry.min_output = math::mul_div_up(entry.min_output, remaining, entry.amount);
    entry.amount = remaining;
    queue.escrow.split(filled)
}

/// Persist a miss on the head so it survives to the next flush. Only called when the
/// request keeps an attempt; a miss that refunds counts off the caller's copy instead,
/// so the refund path writes no page.
fun record_front_limit_miss<T>(queue: &mut RequestQueue<T>) {
    assert!(queue.pending > 0, ERequestNotFound);
    let page_id = *queue.head_page_id.borrow();
    let entry = &mut queue.pages.borrow_mut(page_id).entries[0];
    entry.missed_flushes = entry.missed_flushes + 1;
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

/// LP shares minted for `amount` DUSDC at the frozen flush mark, and the fee
/// withheld from that DUSDC. The fee is charged on the input before conversion, so
/// only the net buys shares; the fee itself joins idle with the rest of the escrow
/// as DUSDC no shares were issued against, which is how it accrues to existing
/// holders. `None` means the mark/request pair is not executable and the queued
/// request must be refunded.
fun quote_supply_shares(mark: &FlushMark, amount: u64): Option<FillQuote> {
    if (!mark.executable) return option::none();
    let fee = fee_on(amount, mark.supply_fee_rate);
    // = net * total_supply / pool_value, round down (supplier mints ≤1 ulp
    // fewer shares; the pool keeps the dust).
    math::try_mul_div_down(amount - fee, mark.total_supply, mark.pool_value).and!(|shares| {
        if (shares == 0) option::none() else option::some(FillQuote { output: shares, fee })
    })
}

/// DUSDC owed for `shares` LP at the frozen flush mark, and the fee withheld from
/// that payout. The requester receives the net; the fee stays in idle while the
/// full `shares` are burned, which is how it accrues to remaining holders. `None`
/// means the mark/request pair is not executable and the queued request must be
/// refunded.
fun quote_withdraw_dusdc(mark: &FlushMark, shares: u64): Option<FillQuote> {
    if (!mark.executable) return option::none();
    // = shares * pool_value / total_supply, round down (withdrawer is paid ≤1 ulp
    // less; the pool keeps the dust).
    math::try_mul_div_down(shares, mark.pool_value, mark.total_supply).and!(|gross| {
        let fee = fee_on(gross, mark.withdraw_fee_rate);
        let payout = gross - fee;
        if (payout == 0) option::none() else option::some(FillQuote { output: payout, fee })
    })
}

/// Fee withheld from a DUSDC amount at one of the mark's frozen rates, rounded up
/// so the dust biases to the pool (rounding policy R2). The result never exceeds
/// `amount`: `max_plp_fee_rate` is well below `float_scaling`, so `amount - fee`
/// cannot underflow at either call site.
fun fee_on(amount: u64, rate: u64): u64 {
    if (rate == 0) return 0;
    math::mul_div_up(amount, rate, math::float_scaling!())
}

fun is_executable_mark(pool_value: u64, total_supply: u64): bool {
    if (total_supply == 0) return false;
    // Executable iff the mark price is within band× of unit parity in both
    // directions (dUSDC and PLP share 6 decimals, so unit price is raw-unit
    // parity and no price unit enters the test):
    //   price <= band    <=>  pool_value <= band·supply  <=>  ceil(pv/band) <= supply
    //   price >= 1/band  <=>  supply <= band·pool_value  <=>  ceil(supply/band) <= pv
    let band = constants::executable_price_band_factor!();
    pool_value.div_ceil(band) <= total_supply && total_supply.div_ceil(band) <= pool_value
}
