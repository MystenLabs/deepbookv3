// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Root-free coverage for `lp_book`, the queue + drain primitive below the `plp`
/// wrapper. `lp_book` is account-agnostic: `request_supply`/`request_withdraw` take a
/// coin plus the owning `account_id` + `recipient` address, and cancel returns the
/// escrowed refund `Balance` straight back (the `plp` wrapper is what pulls from / pays
/// into account custody through the accumulator, in the untested outer layer). So the
/// flush DRAIN economics (proportional supply/withdraw at a frozen mark,
/// FIFO-until-idle-dry, independent per-queue budgets with carry-over, cancelled
/// requests not spending a budget) and the recipient-gated cancel refund are exercised
/// HERE against a standalone `LpBook` + `Ledger`. Every expected share/payout is
/// hand-computed independently of the contract.
#[test_only]
module deepbook_predict::lp_book_tests;

use deepbook_predict::{
    constants::{Self, min_supply_request as min_supply, min_withdraw_request as min_withdraw},
    lp_book::{Self, DrainSummary, LpBook},
    pool_accounting::{Self, Ledger},
    vault_events::{Self, RequestCancelled}
};
use dusdc::dusdc::DUSDC;
use std::unit_test::{assert_eq, destroy};
use sui::{balance, coin, coin_registry, event, test_scenario::{Self as test, Scenario}};

public struct LP_BOOK_TESTS has drop {}

const ALICE: address = @0xA;
const BOB: address = @0xB0B;
/// One whole PLP in raw units; dUSDC and PLP both use 6 decimals.
const ONE_PLP: u64 = 1_000_000;
/// Executable-band boundaries for a one-PLP supply, hand-derived from the
/// band factor 100 and 6-decimal parity: `ceil(supply/band) <= pool_value`
/// gives lowest executable pool value 1_000_000 / 100 = 10_000 (0.01 DUSDC
/// per PLP); `ceil(pool_value/band) <= supply` gives highest executable pool
/// value 100 * 1_000_000 = 100_000_000 (100 DUSDC per PLP).
const MIN_EXECUTABLE_PLP_PRICE: u64 = 10_000;
const MAX_EXECUTABLE_PLP_PRICE: u64 = 100_000_000;
/// `min_supply * min_supply + 1`: a min-sized supply against this mark mints 0 shares.
const ZERO_SHARE_SUPPLY_POOL_VALUE: u64 = 100_000_000_000_001;
/// `min_withdraw + 1`: a min-sized withdrawal against pool value 1 pays 0 DUSDC.
const ZERO_PAYOUT_WITHDRAW_TOTAL_SUPPLY: u64 = 1_000_001;
const NEAR_MAX_SUPPLY_HEADROOM: u64 = 5_000_000;
const NO_SUPPLIES_FILLED: u64 = 0;
const NO_WITHDRAWALS_FILLED: u64 = 0;
const NO_MIN_OUTPUT: u64 = 0;
const LIMIT_MISS_SUPPLY_AMOUNT: u64 = 20_000_000;
const LIMIT_MISS_SUPPLY_QUOTE: u64 = 10_000_000;
const LIMIT_MISS_SUPPLY_MIN_OUT: u64 = LIMIT_MISS_SUPPLY_QUOTE + 1_000_000;
const LIMIT_MISS_WITHDRAW_AMOUNT: u64 = 10_000_000;
const LIMIT_MISS_WITHDRAW_QUOTE: u64 = 20_000_000;
const LIMIT_MISS_WITHDRAW_MIN_OUT: u64 = LIMIT_MISS_WITHDRAW_QUOTE + 1_000_000;
/// The shipped `ProtocolConfig` default: one attempt, so a miss refunds at once.
const NO_RETRY: u64 = 1;
/// The configured maximum, used where a test covers the resting-limit path an admin
/// can turn on — and the queue blocking that comes back with it.
const THREE_ATTEMPTS: u64 = 3;
/// The shipped `ProtocolConfig` default: no ceiling on pool value.
const NO_CAP: u64 = 18_446_744_073_709_551_615;

// === Permanent minimum-liquidity mint ===

#[test]
fun mint_locked_liquidity_increments_total_supply() {
    let (scenario, mut book, ledger) = setup();
    book.mint_locked_liquidity(min_supply!());
    // The permanent minimum-liquidity mint raises treasury supply; it is held by the book
    // with no withdraw path, so total_supply stays >= this floor for the pool's life.
    assert_eq!(book.total_supply(), min_supply!());

    finish(scenario, book, ledger);
}

// === Priced supply / withdraw at a frozen mark ===

#[test]
fun supply_drain_mints_at_mark_and_joins_idle() {
    let (mut scenario, mut book, mut ledger) = setup();
    // Genesis lock seeds total_supply at a 1.0 mark (pool_value == total_supply).
    book.mint_locked_liquidity(min_supply!());
    let payment = coin::mint_for_testing<DUSDC>(min_supply!(), scenario.ctx());
    let index = book.request_supply(payment, alice_id(), ALICE, NO_MIN_OUTPUT);
    assert_eq!(index, 0);
    assert_eq!(book.supply_requests_pending(), 1);

    // Drain at pool_value == total_supply == L (mark 1.0): the supply mints 1:1.
    let summary = book.drain(
        &mut ledger,
        lp_book::new_flush_mark(min_supply!(), min_supply!()),
        vault_id(),
        option::none(),
        option::none(),
        NO_RETRY,
        NO_CAP,
        scenario.ctx(),
    );

    assert_drain_summary(&summary, 1, 0, 1);
    assert_eq!(book.supply_requests_pending(), 0);
    assert_eq!(book.total_supply(), 2 * min_supply!()); // locked L + minted L
    assert_eq!(ledger.idle_balance(), min_supply!()); // the supply escrow joined idle

    finish(scenario, book, ledger);
}

#[test]
fun priced_supply_mints_proportional_shares() {
    let (mut scenario, mut book, mut ledger) = setup();
    // total_supply 30e6, pool_value 60e6 -> mark 2.0.
    book.mint_locked_liquidity(30_000_000);
    let payment = coin::mint_for_testing<DUSDC>(20_000_000, scenario.ctx());
    book.request_supply(payment, alice_id(), ALICE, NO_MIN_OUTPUT);

    // shares = 20e6 * 30e6 / 60e6 = 10e6.
    book.drain(
        &mut ledger,
        lp_book::new_flush_mark(60_000_000, 30_000_000),
        vault_id(),
        option::none(),
        option::none(),
        NO_RETRY,
        NO_CAP,
        scenario.ctx(),
    );

    assert_eq!(book.total_supply(), 40_000_000); // 30e6 + 10e6 minted
    assert_eq!(ledger.idle_balance(), 20_000_000); // the 20e6 escrow joined idle
    assert_eq!(book.supply_requests_pending(), 0);

    finish(scenario, book, ledger);
}

#[test]
fun priced_withdraw_burns_and_pays_from_idle() {
    let (mut scenario, mut book, mut ledger) = setup();
    // total_supply 30e6, idle 60e6 -> mark 2.0.
    book.mint_locked_liquidity(30_000_000);
    seed_idle(&mut ledger, 60_000_000);
    enqueue_withdraw(&mut scenario, &mut book, 10_000_000);

    // dusdc = 10e6 * 60e6 / 30e6 = 20e6.
    book.drain(
        &mut ledger,
        lp_book::new_flush_mark(60_000_000, 30_000_000),
        vault_id(),
        option::none(),
        option::none(),
        NO_RETRY,
        NO_CAP,
        scenario.ctx(),
    );

    assert_eq!(book.total_supply(), 20_000_000); // 30e6 - 10e6 burned
    assert_eq!(ledger.idle_balance(), 40_000_000); // 60e6 - 20e6 paid out
    assert_eq!(book.withdraw_requests_pending(), 0);

    finish(scenario, book, ledger);
}

#[test]
fun two_withdrawals_share_one_frozen_mark() {
    let (mut scenario, mut book, mut ledger) = setup();
    // total_supply 30e6, idle 50e6 -> mark 5/3 (a fraction that rounds).
    book.mint_locked_liquidity(30_000_000);
    seed_idle(&mut ledger, 50_000_000);
    enqueue_withdraw(&mut scenario, &mut book, 10_000_000);
    enqueue_withdraw(&mut scenario, &mut book, 10_000_000);

    // Each prices at the FROZEN (50e6, 30e6) mark: floor(10e6 * 50e6 / 30e6) = 16_666_666.
    // If the second repriced post-first it would round to 16_666_667.
    book.drain(
        &mut ledger,
        lp_book::new_flush_mark(50_000_000, 30_000_000),
        vault_id(),
        option::none(),
        option::none(),
        NO_RETRY,
        NO_CAP,
        scenario.ctx(),
    );

    assert_eq!(ledger.idle_balance(), 16_666_668); // 50e6 - 2 * 16_666_666 (frozen); repriced would leave 16_666_667
    assert_eq!(book.total_supply(), 10_000_000); // 30e6 - 2 * 10e6 burned
    assert_eq!(book.withdraw_requests_pending(), 0);

    finish(scenario, book, ledger);
}

// === FIFO-until-idle-dry ===

#[test]
fun withdrawals_partially_fill_when_idle_runs_dry_and_carry_the_rest() {
    let (mut scenario, mut book, mut ledger) = setup();
    // total_supply 30e6, idle 30e6 -> mark 1.0.
    book.mint_locked_liquidity(30_000_000);
    seed_idle(&mut ledger, 30_000_000);
    // Two 20e6 withdrawals: the first fills (idle 30e6 -> 10e6); the second wants 20e6
    // but only 10e6 of idle is left, so it is paid 10e6 and keeps the other 10e6 queued.
    enqueue_withdraw(&mut scenario, &mut book, 20_000_000);
    enqueue_withdraw(&mut scenario, &mut book, 20_000_000);

    let summary = book.drain(
        &mut ledger,
        lp_book::new_flush_mark(30_000_000, 30_000_000),
        vault_id(),
        option::none(),
        option::none(),
        NO_RETRY,
        NO_CAP,
        scenario.ctx(),
    );

    // Both count as fills; idle is fully paid out and the second request stays queued
    // for its remaining half.
    assert_drain_summary(&summary, 0, 2, 2);
    assert_eq!(book.total_supply(), 0); // 20e6 + 10e6 burned against the 30e6 locked
    assert_eq!(ledger.idle_balance(), 0); // every DUSDC of idle reached an exiting LP
    assert_eq!(book.withdraw_requests_pending(), 1); // the second half is still first in line

    finish(scenario, book, ledger);
}

// === Pool-value cap on supplies ===
//
// The cap is checked against the frozen mark plus what this flush has already
// filled, so these run at a 1.0 mark with pool value 30e6 and read the headroom
// straight off the cap: a cap of 35e6 leaves exactly 5 DUSDC of room.

#[test]
fun supply_within_pool_cap_fills() {
    let (mut scenario, mut book, mut ledger) = setup();
    book.mint_locked_liquidity(30_000_000);
    let payment = coin::mint_for_testing<DUSDC>(min_supply!(), scenario.ctx());
    book.request_supply(payment, alice_id(), ALICE, NO_MIN_OUTPUT);

    // Cap 45e6 against pool value 30e6: 15 DUSDC of room for a 10 DUSDC deposit.
    let summary = drain_at_par_with_cap(&mut scenario, &mut book, &mut ledger, 45_000_000);

    assert_drain_summary(&summary, 1, NO_WITHDRAWALS_FILLED, 1);
    assert_eq!(book.total_supply(), 40_000_000); // 10 DUSDC minted 1:1 at the 1.0 mark
    assert_eq!(ledger.idle_balance(), min_supply!());

    finish(scenario, book, ledger);
}

/// A pool with no room left keeps its queue intact: the head carries with its escrow
/// untouched rather than being refunded, so the requester holds their place in line.
#[test]
fun supply_carries_when_the_pool_has_no_headroom() {
    let (mut scenario, mut book, mut ledger) = setup();
    book.mint_locked_liquidity(30_000_000);
    let payment = coin::mint_for_testing<DUSDC>(min_supply!(), scenario.ctx());
    book.request_supply(payment, alice_id(), ALICE, NO_MIN_OUTPUT);

    // Cap equal to pool value: zero headroom, so there is nothing to part-fill.
    let summary = drain_at_par_with_cap(&mut scenario, &mut book, &mut ledger, 30_000_000);

    // Nothing processed at all — the pass breaks before spending budget on a head it
    // cannot serve, and every request behind it is equally unservable.
    assert_drain_summary(&summary, NO_SUPPLIES_FILLED, NO_WITHDRAWALS_FILLED, 0);
    assert_eq!(book.supply_requests_pending(), 1); // still queued, still first in line
    assert_eq!(book.total_supply(), 30_000_000);
    assert_eq!(ledger.idle_balance(), 0);

    finish(scenario, book, ledger);
}

/// A request that both misses its limit and hits a full pool reports the *limit* —
/// the only test that distinguishes the two refund reasons, and so the only one that
/// pins the branch order the partial-fill rule depends on.
#[test]
fun over_cap_and_under_limit_reports_the_limit_miss() {
    let (mut scenario, mut book, mut ledger) = setup();
    book.mint_locked_liquidity(30_000_000);
    // At the 1.0 mark this quotes 10e6 PLP, short of the 11e6 minimum.
    let payment = coin::mint_for_testing<DUSDC>(min_supply!(), scenario.ctx());
    book.request_supply(payment, alice_id(), ALICE, 11_000_000);

    // Cap at the pool's own value: zero headroom as well as a missed limit.
    drain_at_par_with_cap(&mut scenario, &mut book, &mut ledger, 30_000_000);

    let cancels = event::events_by_type<RequestCancelled>();
    assert_eq!(cancels.length(), 1);
    assert_eq!(
        vault_events::request_cancelled_reason(&cancels[0]),
        constants::request_cancel_reason_limit_missed!(),
    );

    finish(scenario, book, ledger);
}

/// A deposit larger than the remaining headroom takes what fits and gets the rest
/// back, so the cap is filled exactly rather than left short.
#[test]
fun supply_larger_than_headroom_partially_fills_to_the_cap() {
    let (mut scenario, mut book, mut ledger) = setup();
    book.mint_locked_liquidity(30_000_000);
    let payment = coin::mint_for_testing<DUSDC>(30_000_000, scenario.ctx());
    book.request_supply(payment, alice_id(), ALICE, NO_MIN_OUTPUT);

    // Cap 55e6 against pool value 30e6: 25 DUSDC of room for a 30 DUSDC deposit.
    let summary = drain_at_par_with_cap(&mut scenario, &mut book, &mut ledger, 55_000_000);

    // Counts as a fill, and the unfilled 5 keeps its place at the head.
    assert_drain_summary(&summary, 1, NO_WITHDRAWALS_FILLED, 1);
    assert_eq!(book.supply_requests_pending(), 1);
    // 25 DUSDC minted 1:1 at the 1.0 mark; pool value lands exactly on the cap.
    assert_eq!(book.total_supply(), 55_000_000);
    assert_eq!(ledger.idle_balance(), 25_000_000);

    finish(scenario, book, ledger);
}

/// The limit is checked before the cap, so a deposit whose price is unacceptable is a
/// limit miss — never part-filled at that price for the portion that would have fit.
#[test]
fun limit_miss_is_not_partially_filled_into_available_headroom() {
    let (mut scenario, mut book, mut ledger) = setup();
    book.mint_locked_liquidity(30_000_000);
    // At the 1.0 mark a 30 DUSDC deposit quotes 30e6 PLP, short of this 31e6 minimum.
    let payment = coin::mint_for_testing<DUSDC>(30_000_000, scenario.ctx());
    book.request_supply(payment, alice_id(), ALICE, 31_000_000);

    // Headroom is ample; only the price is wrong.
    let summary = drain_at_par_with_cap(&mut scenario, &mut book, &mut ledger, 55_000_000);

    assert_drain_summary(&summary, NO_SUPPLIES_FILLED, NO_WITHDRAWALS_FILLED, 1);
    assert_eq!(book.supply_requests_pending(), 0);
    assert_eq!(book.total_supply(), 30_000_000); // nothing minted at a price it refused
    assert_eq!(ledger.idle_balance(), 0);

    finish(scenario, book, ledger);
}

/// The cap counts what this flush has already filled, not just the frozen mark —
/// otherwise several individually-fitting supplies would collectively overshoot it.
#[test]
fun supplies_cannot_collectively_exceed_the_pool_cap_in_one_flush() {
    let (mut scenario, mut book, mut ledger) = setup();
    book.mint_locked_liquidity(30_000_000);
    // Three 10 DUSDC requests against 25 DUSDC of room: two fit, the third does not.
    let mut i = 0u64;
    while (i < 3) {
        let payment = coin::mint_for_testing<DUSDC>(min_supply!(), scenario.ctx());
        book.request_supply(payment, alice_id(), ALICE, NO_MIN_OUTPUT);
        i = i + 1;
    };

    let summary = drain_at_par_with_cap(&mut scenario, &mut book, &mut ledger, 55_000_000);

    // Two fill whole; the third takes the last 5 of room and keeps its 5 remainder.
    assert_drain_summary(&summary, 3, NO_WITHDRAWALS_FILLED, 3);
    assert_eq!(book.supply_requests_pending(), 1);
    // Pool value lands exactly on the cap: 30e6 + 10e6 + 10e6 + 5e6.
    assert_eq!(book.total_supply(), 55_000_000);
    assert_eq!(ledger.idle_balance(), 25_000_000);

    finish(scenario, book, ledger);
}

/// A pool already above its cap — which trading profit alone can cause — accepts no
/// new supply, and the queue waits rather than being emptied.
#[test]
fun supply_carries_when_pool_is_already_over_cap() {
    let (mut scenario, mut book, mut ledger) = setup();
    book.mint_locked_liquidity(30_000_000);
    let payment = coin::mint_for_testing<DUSDC>(min_supply!(), scenario.ctx());
    book.request_supply(payment, alice_id(), ALICE, NO_MIN_OUTPUT);

    // Cap 20e6 below the pool's own 30e6 value: zero headroom, saturating to 0.
    let summary = drain_at_par_with_cap(&mut scenario, &mut book, &mut ledger, 20_000_000);

    assert_drain_summary(&summary, NO_SUPPLIES_FILLED, NO_WITHDRAWALS_FILLED, 0);
    assert_eq!(book.supply_requests_pending(), 1); // escrow stays with its queue place
    assert_eq!(book.total_supply(), 30_000_000);

    finish(scenario, book, ledger);
}

/// One flush end to end with a binding cap: supplies drain first against the frozen
/// mark until the cap is exhausted, then withdrawals pay out with no capacity check.
/// Every figure below is derived by hand from the 1.2 share price.
///
/// Also pins queue priority: S2 takes the remaining headroom as a partial fill and
/// keeps its unfilled balance at the head, so S3 is never reached this flush. Headroom
/// follows queue order, and nobody loses their place to a re-submission race.
#[test]
fun capped_flush_fills_withdraws_and_leaves_headroom_for_the_next_flush() {
    let (mut scenario, mut book, mut ledger) = setup();
    book.mint_locked_liquidity(1_000_000_000); // 1,000 PLP
    seed_idle(&mut ledger, 20_000_000); // 20 DUSDC idle; the rest of NAV sits in markets

    // Supplies, in queue order.
    let s1 = coin::mint_for_testing<DUSDC>(60_000_000, scenario.ctx());
    book.request_supply(s1, alice_id(), ALICE, NO_MIN_OUTPUT);
    let s2 = coin::mint_for_testing<DUSDC>(80_000_000, scenario.ctx());
    book.request_supply(s2, bob_id(), BOB, NO_MIN_OUTPUT);
    let s3 = coin::mint_for_testing<DUSDC>(20_000_000, scenario.ctx());
    book.request_supply(s3, alice_id(), ALICE, NO_MIN_OUTPUT);
    // Withdrawals, in queue order.
    enqueue_withdraw_for(&mut scenario, &mut book, ALICE, 50_000_000, NO_MIN_OUTPUT);
    enqueue_withdraw_for(&mut scenario, &mut book, BOB, 100_000_000, NO_MIN_OUTPUT);

    // Mark: pool 1,200 DUSDC over 1,000 PLP = 1.2 per share. Cap 1,300 leaves 100 of room.
    let summary = book.drain(
        &mut ledger,
        lp_book::new_flush_mark(1_200_000_000, 1_000_000_000),
        vault_id(),
        option::none(),
        option::none(),
        NO_RETRY,
        1_300_000_000,
        scenario.ctx(),
    );

    // S1 (60) fits in 100 and mints 60 / 1.2 = 50 PLP, leaving 40 of room.
    // S2 (80) exceeds the remaining 40, so 40 is taken at the same 1.2 — minting
    //   40 / 1.2 = 33.333333 PLP — and its other 40 stays queued at the head. The cap
    //   is now reached, so the supply pass stops and S3 is never reached.
    // Withdrawals then price at the same frozen 1.2, against 120 of idle (20 seeded
    //   plus the 100 the two supply fills brought in).
    // W1 (50 PLP) wants 60 and is paid in full, leaving 60 of idle.
    // W2 (100 PLP) wants 120 but only 60 of idle remains, so idle buys
    //   floor(60 / 1.2) = 50 PLP, pays exactly 60 for them, and the other 50 PLP stays
    //   queued at the head.
    assert_drain_summary(&summary, 2, 2, 4);
    // S2's remainder and the untouched S3 stay queued, in that order.
    assert_eq!(book.supply_requests_pending(), 2);
    // W2's unpaid half keeps its place at the front of the withdraw queue.
    assert_eq!(book.withdraw_requests_pending(), 1);
    // 1,000 + 50 + 33.333333 minted, then 50 and 50 burned by the two exits.
    assert_eq!(book.total_supply(), 983_333_333);
    // Every DUSDC of idle reached an exiting LP.
    assert_eq!(ledger.idle_balance(), 0);

    finish(scenario, book, ledger);
}

/// A full pool now holds the line instead of emptying it: the head keeps its escrow
/// and its position, and the pass stops without touching anything behind it. This is
/// the deliberate inverse of the earlier refund-everything behaviour — with no
/// headroom, nothing behind the head could fill either, so walking the rest of the
/// queue would only spend budget and events to refuse each one in turn.
#[test]
fun full_pool_holds_the_supply_queue_instead_of_clearing_it() {
    let (mut scenario, mut book, mut ledger) = setup();
    book.mint_locked_liquidity(30_000_000);
    let mut i = 0u64;
    while (i < 4) {
        let payment = coin::mint_for_testing<DUSDC>(min_supply!(), scenario.ctx());
        book.request_supply(payment, alice_id(), ALICE, NO_MIN_OUTPUT);
        i = i + 1;
    };

    // Cap at the pool's own value: zero headroom for any of them.
    let summary = drain_at_par_with_cap(&mut scenario, &mut book, &mut ledger, 30_000_000);

    // Nothing processed, nothing minted, all four still queued in their original order.
    assert_drain_summary(&summary, NO_SUPPLIES_FILLED, NO_WITHDRAWALS_FILLED, 0);
    assert_eq!(book.supply_requests_pending(), 4);
    assert_eq!(book.total_supply(), 30_000_000);
    assert_eq!(ledger.idle_balance(), 0);

    finish(scenario, book, ledger);
}

/// Headroom that opens later is served in queue order, so a partially filled head
/// keeps its seniority across flushes rather than racing re-submitted requests.
#[test]
fun partially_filled_head_keeps_its_place_across_flushes() {
    let (mut scenario, mut book, mut ledger) = setup();
    book.mint_locked_liquidity(30_000_000);
    let first = coin::mint_for_testing<DUSDC>(30_000_000, scenario.ctx());
    book.request_supply(first, alice_id(), ALICE, NO_MIN_OUTPUT);
    let second = coin::mint_for_testing<DUSDC>(min_supply!(), scenario.ctx());
    book.request_supply(second, bob_id(), BOB, NO_MIN_OUTPUT);

    // 10 of room: the 30 head takes it all and carries 20, the 10 behind it is untouched.
    let summary = drain_at_par_with_cap(&mut scenario, &mut book, &mut ledger, 40_000_000);
    assert_drain_summary(&summary, 1, NO_WITHDRAWALS_FILLED, 1);
    assert_eq!(book.supply_requests_pending(), 2);
    assert_eq!(book.total_supply(), 40_000_000);

    // Raising the cap by 20 lets the same head finish before the request behind it.
    let summary = drain_at_par_with_cap(&mut scenario, &mut book, &mut ledger, 60_000_000);
    // The head's remaining 20 fills, then the 10 behind it takes the last 10 of room.
    assert_drain_summary(&summary, 2, NO_WITHDRAWALS_FILLED, 2);
    assert_eq!(book.supply_requests_pending(), 0);
    assert_eq!(book.total_supply(), 70_000_000);
    assert_eq!(ledger.idle_balance(), 40_000_000);

    finish(scenario, book, ledger);
}

/// Withdrawals are not capacity-checked: the cap closes the pool to new capital and
/// must never trap capital already in it.
#[test]
fun pool_cap_does_not_gate_withdrawals() {
    let (mut scenario, mut book, mut ledger) = setup();
    book.mint_locked_liquidity(30_000_000);
    seed_idle(&mut ledger, 30_000_000);
    enqueue_withdraw(&mut scenario, &mut book, 10_000_000);

    // Cap far below pool value: the exit still pays out in full.
    let summary = drain_at_par_with_cap(&mut scenario, &mut book, &mut ledger, 20_000_000);

    assert_drain_summary(&summary, NO_SUPPLIES_FILLED, 1, 1);
    assert_eq!(book.total_supply(), 20_000_000); // 10e6 PLP burned
    assert_eq!(ledger.idle_balance(), 20_000_000); // 10 DUSDC paid out at the 1.0 mark

    finish(scenario, book, ledger);
}

// === Request limits and retry expiry ===
//
// The attempt count is admin-tunable (`ProtocolConfig`), so both settings are
// covered: `NO_RETRY` is what ships and must leave no head unresolved, while
// `THREE_ATTEMPTS` is the resting-limit path an operator can turn on — including
// the queue blocking it reintroduces, which is pinned here on purpose so the cost
// of raising the knob is visible in the suite rather than only in RP-12.

#[test]
fun supply_limit_miss_refunds_at_the_flush_that_reaches_it() {
    let (mut scenario, mut book, mut ledger) = setup();
    // total_supply 30e6, mark 2.0 -> supply quotes 10e6 shares, below the 11e6 limit.
    book.mint_locked_liquidity(30_000_000);
    let payment = coin::mint_for_testing<DUSDC>(LIMIT_MISS_SUPPLY_AMOUNT, scenario.ctx());
    book.request_supply(payment, alice_id(), ALICE, LIMIT_MISS_SUPPLY_MIN_OUT);

    let summary = book.drain(
        &mut ledger,
        lp_book::new_flush_mark(60_000_000, 30_000_000),
        vault_id(),
        option::none(),
        option::none(),
        NO_RETRY,
        NO_CAP,
        scenario.ctx(),
    );

    // Processed as a refund, not a fill: the head is resolved on its first miss.
    assert_drain_summary(&summary, NO_SUPPLIES_FILLED, NO_WITHDRAWALS_FILLED, 1);
    assert_eq!(book.supply_requests_pending(), 0);
    // Nothing minted and the escrow went back to the requester, not into idle.
    assert_eq!(book.total_supply(), 30_000_000);
    assert_eq!(ledger.idle_balance(), 0);

    finish(scenario, book, ledger);
}

/// A supply request whose limit no mark can satisfy is refunded on the flush that
/// reaches it, so the request behind it fills in that same flush. Pins the queue
/// against a head that stalls the drain (external audit finding, issue #42).
#[test]
fun supply_limit_miss_does_not_block_later_requests() {
    let (mut scenario, mut book, mut ledger) = setup();
    book.mint_locked_liquidity(30_000_000);
    let unfillable = coin::mint_for_testing<DUSDC>(LIMIT_MISS_SUPPLY_AMOUNT, scenario.ctx());
    book.request_supply(unfillable, bob_id(), BOB, unattainable_min_out());
    let honest = coin::mint_for_testing<DUSDC>(min_supply!(), scenario.ctx());
    book.request_supply(honest, alice_id(), ALICE, NO_MIN_OUTPUT);

    let summary = book.drain(
        &mut ledger,
        lp_book::new_flush_mark(60_000_000, 30_000_000),
        vault_id(),
        option::none(),
        option::none(),
        NO_RETRY,
        NO_CAP,
        scenario.ctx(),
    );

    // Both heads resolved in one flush: the unfillable one refunded, the honest one filled.
    assert_drain_summary(&summary, 1, NO_WITHDRAWALS_FILLED, 2);
    assert_eq!(book.supply_requests_pending(), 0);
    // 10e6 DUSDC at the 2.0 mark mints 5e6 PLP on top of the 30e6 genesis lock.
    assert_eq!(book.total_supply(), 35_000_000);
    // Only the honest escrow joined idle; the refunded 20e6 did not.
    assert_eq!(ledger.idle_balance(), 10_000_000);

    finish(scenario, book, ledger);
}

/// With the attempt count raised, a missing head rests instead of refunding and is
/// filled by a later flush whose mark improves — the affordance the knob buys.
#[test]
fun supply_limit_miss_carries_then_fills_when_mark_improves_at_three_attempts() {
    let (mut scenario, mut book, mut ledger) = setup();
    // total_supply 30e6, first mark 2.0 -> supply quotes 10e6 shares, below the 11e6 limit.
    book.mint_locked_liquidity(30_000_000);
    let payment = coin::mint_for_testing<DUSDC>(LIMIT_MISS_SUPPLY_AMOUNT, scenario.ctx());
    book.request_supply(payment, alice_id(), ALICE, LIMIT_MISS_SUPPLY_MIN_OUT);

    let summary = book.drain(
        &mut ledger,
        lp_book::new_flush_mark(60_000_000, 30_000_000),
        vault_id(),
        option::none(),
        option::none(),
        THREE_ATTEMPTS,
        NO_CAP,
        scenario.ctx(),
    );

    assert_drain_summary(&summary, NO_SUPPLIES_FILLED, NO_WITHDRAWALS_FILLED, 1);
    assert_eq!(book.supply_requests_pending(), 1);
    assert_eq!(book.total_supply(), 30_000_000);

    // Improved mark 1.0 -> the same queued request now quotes 20e6 shares and fills.
    let summary = book.drain(
        &mut ledger,
        lp_book::new_flush_mark(30_000_000, 30_000_000),
        vault_id(),
        option::none(),
        option::none(),
        THREE_ATTEMPTS,
        NO_CAP,
        scenario.ctx(),
    );

    assert_drain_summary(&summary, 1, NO_WITHDRAWALS_FILLED, 1);
    assert_eq!(book.supply_requests_pending(), 0);
    assert_eq!(book.total_supply(), 50_000_000); // 30e6 + 20e6 minted at the 1.0 mark
    assert_eq!(ledger.idle_balance(), LIMIT_MISS_SUPPLY_AMOUNT);

    finish(scenario, book, ledger);
}

/// The same request expires and refunds on its third miss rather than resting forever.
#[test]
fun supply_limit_expires_after_three_misses_at_three_attempts() {
    let (mut scenario, mut book, mut ledger) = setup();
    book.mint_locked_liquidity(30_000_000);
    let payment = coin::mint_for_testing<DUSDC>(LIMIT_MISS_SUPPLY_AMOUNT, scenario.ctx());
    book.request_supply(payment, alice_id(), ALICE, LIMIT_MISS_SUPPLY_MIN_OUT);

    // Misses 1 and 2 leave it queued.
    let mut i = 0u64;
    while (i < 2) {
        let summary = drain_at_two_x(&mut scenario, &mut book, &mut ledger, THREE_ATTEMPTS);
        assert_drain_summary(&summary, NO_SUPPLIES_FILLED, NO_WITHDRAWALS_FILLED, 1);
        assert_eq!(book.supply_requests_pending(), 1);
        i = i + 1;
    };

    // Miss 3 refunds it.
    let summary = drain_at_two_x(&mut scenario, &mut book, &mut ledger, THREE_ATTEMPTS);
    assert_drain_summary(&summary, NO_SUPPLIES_FILLED, NO_WITHDRAWALS_FILLED, 1);
    assert_eq!(book.supply_requests_pending(), 0);
    assert_eq!(book.total_supply(), 30_000_000);
    assert_eq!(ledger.idle_balance(), 0);

    finish(scenario, book, ledger);
}

/// The cost of raising the knob, pinned: at three attempts an unfillable head holds
/// the queue, and the honest request behind it is not reached for two more flushes.
/// This is the behaviour issue #42 reported; it is reachable only by admin choice.
#[test]
fun raising_attempts_reintroduces_head_of_line_blocking() {
    let (mut scenario, mut book, mut ledger) = setup();
    book.mint_locked_liquidity(30_000_000);
    let unfillable = coin::mint_for_testing<DUSDC>(LIMIT_MISS_SUPPLY_AMOUNT, scenario.ctx());
    book.request_supply(unfillable, bob_id(), BOB, unattainable_min_out());
    let honest = coin::mint_for_testing<DUSDC>(min_supply!(), scenario.ctx());
    book.request_supply(honest, alice_id(), ALICE, NO_MIN_OUTPUT);

    // Flushes 1 and 2: the head misses, stops the queue, and the honest request waits.
    let mut i = 0u64;
    while (i < 2) {
        let summary = drain_at_two_x(&mut scenario, &mut book, &mut ledger, THREE_ATTEMPTS);
        assert_drain_summary(&summary, NO_SUPPLIES_FILLED, NO_WITHDRAWALS_FILLED, 1);
        assert_eq!(book.supply_requests_pending(), 2);
        assert_eq!(book.total_supply(), 30_000_000);
        i = i + 1;
    };

    // Flush 3: the head expires and only then is the honest request reached.
    let summary = drain_at_two_x(&mut scenario, &mut book, &mut ledger, THREE_ATTEMPTS);
    assert_drain_summary(&summary, 1, NO_WITHDRAWALS_FILLED, 2);
    assert_eq!(book.supply_requests_pending(), 0);
    assert_eq!(book.total_supply(), 35_000_000);

    finish(scenario, book, ledger);
}

/// The withdraw drain has its own shape — `processed` is counted inside the branch
/// and the idle check sits after the limit check — so the tunable path is covered on
/// both queues rather than assumed symmetric with supply.
#[test]
fun withdraw_limit_miss_carries_then_expires_at_three_attempts() {
    let (mut scenario, mut book, mut ledger) = setup();
    book.mint_locked_liquidity(30_000_000);
    seed_idle(&mut ledger, 60_000_000);
    enqueue_withdraw_with_limit(
        &mut scenario,
        &mut book,
        LIMIT_MISS_WITHDRAW_AMOUNT,
        LIMIT_MISS_WITHDRAW_MIN_OUT,
    );
    // A second withdrawal behind it, to show the head holds the queue while it rests.
    enqueue_withdraw_for(&mut scenario, &mut book, BOB, min_withdraw!(), NO_MIN_OUTPUT);

    // Misses 1 and 2: the head rests and the request behind it is never reached.
    let mut i = 0u64;
    while (i < 2) {
        let summary = drain_at_two_x(&mut scenario, &mut book, &mut ledger, THREE_ATTEMPTS);
        assert_drain_summary(&summary, NO_SUPPLIES_FILLED, NO_WITHDRAWALS_FILLED, 1);
        assert_eq!(book.withdraw_requests_pending(), 2);
        assert_eq!(ledger.idle_balance(), 60_000_000);
        i = i + 1;
    };

    // Miss 3 refunds the head, and only then is the second withdrawal paid.
    let summary = drain_at_two_x(&mut scenario, &mut book, &mut ledger, THREE_ATTEMPTS);
    assert_drain_summary(&summary, NO_SUPPLIES_FILLED, 1, 2);
    assert_eq!(book.withdraw_requests_pending(), 0);
    // 1 PLP burned at the 2.0 mark pays 2 DUSDC; the rested head's escrow was refunded.
    assert_eq!(book.total_supply(), 29_000_000);
    assert_eq!(ledger.idle_balance(), 58_000_000);

    finish(scenario, book, ledger);
}

/// A refunded miss spends one budget unit, exactly like a fill — so a bounded budget
/// stops the pass after it and the next request waits for the following flush.
#[test]
fun limit_miss_spends_one_budget_unit() {
    let (mut scenario, mut book, mut ledger) = setup();
    book.mint_locked_liquidity(30_000_000);
    let unfillable = coin::mint_for_testing<DUSDC>(min_supply!(), scenario.ctx());
    book.request_supply(unfillable, bob_id(), BOB, unattainable_min_out());
    let honest = coin::mint_for_testing<DUSDC>(min_supply!(), scenario.ctx());
    book.request_supply(honest, alice_id(), ALICE, NO_MIN_OUTPUT);

    // Budget of 1: the refund consumes it, so the honest request is not reached.
    let summary = drain_at_par_with_budgets(
        &mut scenario,
        &mut book,
        &mut ledger,
        option::some(1),
        option::none(),
    );
    assert_drain_summary(&summary, NO_SUPPLIES_FILLED, NO_WITHDRAWALS_FILLED, 1);
    assert_eq!(book.supply_requests_pending(), 1);
    assert_eq!(book.total_supply(), 30_000_000);

    // Next flush reaches it and mints 10e6 PLP at the 1.0 mark.
    let summary = drain_at_par_with_budgets(
        &mut scenario,
        &mut book,
        &mut ledger,
        option::some(1),
        option::none(),
    );
    assert_drain_summary(&summary, 1, NO_WITHDRAWALS_FILLED, 1);
    assert_eq!(book.supply_requests_pending(), 0);
    assert_eq!(book.total_supply(), 40_000_000);

    finish(scenario, book, ledger);
}

#[test]
fun withdraw_limit_miss_refunds_at_the_flush_that_reaches_it() {
    let (mut scenario, mut book, mut ledger) = setup();
    // total_supply 30e6, mark 2.0 -> withdraw quotes 20e6 DUSDC, below the 21e6 limit.
    book.mint_locked_liquidity(30_000_000);
    seed_idle(&mut ledger, 60_000_000);
    enqueue_withdraw_with_limit(
        &mut scenario,
        &mut book,
        LIMIT_MISS_WITHDRAW_AMOUNT,
        LIMIT_MISS_WITHDRAW_MIN_OUT,
    );

    let summary = book.drain(
        &mut ledger,
        lp_book::new_flush_mark(60_000_000, 30_000_000),
        vault_id(),
        option::none(),
        option::none(),
        NO_RETRY,
        NO_CAP,
        scenario.ctx(),
    );

    assert_drain_summary(&summary, NO_SUPPLIES_FILLED, NO_WITHDRAWALS_FILLED, 1);
    assert_eq!(book.withdraw_requests_pending(), 0);
    // Escrowed PLP went back to the requester: nothing burned, no idle paid out.
    assert_eq!(book.total_supply(), 30_000_000);
    assert_eq!(ledger.idle_balance(), 60_000_000);

    finish(scenario, book, ledger);
}

/// The withdraw-side twin of `supply_limit_miss_does_not_block_later_requests`:
/// an exit request behind an unfillable limit is paid in the same flush, so the
/// queue cannot be held closed by a request no mark can satisfy (issue #42).
#[test]
fun withdraw_limit_miss_does_not_block_later_requests() {
    let (mut scenario, mut book, mut ledger) = setup();
    book.mint_locked_liquidity(30_000_000);
    seed_idle(&mut ledger, 60_000_000);
    enqueue_withdraw_for(
        &mut scenario,
        &mut book,
        BOB,
        LIMIT_MISS_WITHDRAW_AMOUNT,
        unattainable_min_out(),
    );
    enqueue_withdraw_for(&mut scenario, &mut book, ALICE, min_withdraw!(), NO_MIN_OUTPUT);

    let summary = book.drain(
        &mut ledger,
        lp_book::new_flush_mark(60_000_000, 30_000_000),
        vault_id(),
        option::none(),
        option::none(),
        NO_RETRY,
        NO_CAP,
        scenario.ctx(),
    );

    assert_drain_summary(&summary, NO_SUPPLIES_FILLED, 1, 2);
    assert_eq!(book.withdraw_requests_pending(), 0);
    // 1e6 PLP burned at the 2.0 mark pays 2e6 DUSDC out of the 60e6 idle.
    assert_eq!(book.total_supply(), 29_000_000);
    assert_eq!(ledger.idle_balance(), 58_000_000);

    finish(scenario, book, ledger);
}

// === Per-queue budgets and carry-over ===

#[test]
fun unbounded_flush_drains_every_queued_supply() {
    let (mut scenario, mut book, mut ledger) = setup();
    book.mint_locked_liquidity(min_supply!());
    // 101 supplies at the 1.0 mark -> all mint 1:1, past the old shared 100-request cap.
    let total = 101u64;
    let mut i = 0u64;
    while (i < total) {
        let coin = coin::mint_for_testing<DUSDC>(min_supply!(), scenario.ctx());
        book.request_supply(coin, alice_id(), ALICE, NO_MIN_OUTPUT);
        i = i + 1;
    };

    let summary = book.drain(
        &mut ledger,
        lp_book::new_flush_mark(min_supply!(), min_supply!()),
        vault_id(),
        option::none(),
        option::none(),
        NO_RETRY,
        NO_CAP,
        scenario.ctx(),
    );

    assert_drain_summary(&summary, total, 0, total);
    assert_eq!(book.total_supply(), (total + 1) * min_supply!()); // locked + 101 minted
    assert_eq!(ledger.idle_balance(), total * min_supply!());
    assert_eq!(book.supply_requests_pending(), 0);

    finish(scenario, book, ledger);
}

#[test]
fun cancel_tail_page_request_unlinks_page_and_keeps_queue_drainable() {
    let (mut scenario, mut book, mut ledger) = setup();
    book.mint_locked_liquidity(min_supply!());

    // Fill exactly two pages (PAGE_CAPACITY = 64): page 0 holds 0..63, page 1
    // holds the single index 64. A FIFO drain only ever empties the head page,
    // so the tail-page unlink (`prev = some`, `next = none`) is reached only by
    // cancelling that lone tail entry.
    let page_capacity = 64u64;
    let total = page_capacity + 1;
    let mut tail_index = 0u64;
    let mut i = 0u64;
    while (i < total) {
        let coin = coin::mint_for_testing<DUSDC>(min_supply!(), scenario.ctx());
        tail_index = book.request_supply(coin, alice_id(), ALICE, NO_MIN_OUTPUT);
        i = i + 1;
    };
    assert_eq!(book.supply_requests_pending(), total);

    let (_id, _amount, refund) = book.cancel_supply_request(ALICE, tail_index);
    destroy(refund);
    assert_eq!(book.supply_requests_pending(), page_capacity);

    // The list survived the unlink: draining fills all 64 page-0 requests, so
    // head_page_id and tail_page_id still point at a coherent single page.
    let summary = book.drain(
        &mut ledger,
        lp_book::new_flush_mark(min_supply!(), min_supply!()),
        vault_id(),
        option::none(),
        option::none(),
        NO_RETRY,
        NO_CAP,
        scenario.ctx(),
    );
    assert_drain_summary(&summary, page_capacity, 0, page_capacity);
    assert_eq!(book.supply_requests_pending(), 0);

    finish(scenario, book, ledger);
}

// The middle-page unlink relinks BOTH neighbors — `page 0.next -> page 2` and
// `page 2.prev -> page 0`. The two directions need separate tests: a forward
// drain can only observe `.next` (it never reads `.prev`), and page 0's own later
// unlink overwrites `page 2.prev` before a forward drain would reach it, masking a
// wrong backward relink. So one test drives each direction to its own observation.

#[test]
fun cancel_middle_page_forward_relinks_predecessor_to_successor() {
    let (mut scenario, mut book, mut ledger) = setup();
    book.mint_locked_liquidity(min_supply!());

    // Three pages: page 0 (0..63), page 1 (64..127), page 2 (128).
    let page_capacity = 64u64;
    let total = 2 * page_capacity + 1;
    let mut i = 0u64;
    while (i < total) {
        let coin = coin::mint_for_testing<DUSDC>(min_supply!(), scenario.ctx());
        book.request_supply(coin, alice_id(), ALICE, NO_MIN_OUTPUT);
        i = i + 1;
    };

    // Empty the middle page (last cancel at index 127 triggers the unlink).
    let mut j = page_capacity;
    while (j < 2 * page_capacity) {
        let (_id, _amount, refund) = book.cancel_supply_request(ALICE, j);
        destroy(refund);
        j = j + 1;
    };
    assert_eq!(book.supply_requests_pending(), page_capacity + 1);

    // Forward relink: a FIFO drain reaches page 2 only through page 0's rewired
    // `next`, so all 65 survivors (page 0's 64 + page 2's 1) fill.
    let summary = book.drain(
        &mut ledger,
        lp_book::new_flush_mark(min_supply!(), min_supply!()),
        vault_id(),
        option::none(),
        option::none(),
        NO_RETRY,
        NO_CAP,
        scenario.ctx(),
    );
    assert_drain_summary(&summary, page_capacity + 1, 0, page_capacity + 1);
    assert_eq!(book.supply_requests_pending(), 0);

    finish(scenario, book, ledger);
}

#[test]
fun cancel_middle_page_backward_relinks_successor_to_predecessor() {
    let (mut scenario, mut book, mut ledger) = setup();
    book.mint_locked_liquidity(min_supply!());

    // Same three pages: page 0 (0..63), page 1 (64..127), page 2 (128).
    let page_capacity = 64u64;
    let total = 2 * page_capacity + 1;
    let mut i = 0u64;
    while (i < total) {
        let coin = coin::mint_for_testing<DUSDC>(min_supply!(), scenario.ctx());
        book.request_supply(coin, alice_id(), ALICE, NO_MIN_OUTPUT);
        i = i + 1;
    };

    // Empty the middle page: sets `page 2.prev -> page 0`.
    let mut j = page_capacity;
    while (j < 2 * page_capacity) {
        let (_id, _amount, refund) = book.cancel_supply_request(ALICE, j);
        destroy(refund);
        j = j + 1;
    };
    assert_eq!(book.supply_requests_pending(), page_capacity + 1);

    // Backward relink: now empty page 2 (its lone index 128). Its unlink reads
    // `page 2.prev` and relinks it — if the middle unlink left it pointing at the
    // removed page 1, this `borrow_mut` hits a missing page and aborts. Page 0 is
    // still full, so it is untouched here and cannot mask the check.
    let (_id, _amount, refund) = book.cancel_supply_request(ALICE, 2 * page_capacity);
    destroy(refund);
    assert_eq!(book.supply_requests_pending(), page_capacity);

    // Page 0 survived intact: draining fills all 64.
    let summary = book.drain(
        &mut ledger,
        lp_book::new_flush_mark(min_supply!(), min_supply!()),
        vault_id(),
        option::none(),
        option::none(),
        NO_RETRY,
        NO_CAP,
        scenario.ctx(),
    );
    assert_drain_summary(&summary, page_capacity, 0, page_capacity);
    assert_eq!(book.supply_requests_pending(), 0);

    finish(scenario, book, ledger);
}

#[test]
fun bounded_supply_budget_fills_up_to_budget_and_carries() {
    let (mut scenario, mut book, mut ledger) = setup();
    book.mint_locked_liquidity(min_supply!());
    // Three supplies at the 1.0 mark; a supply_budget of 2 fills two and carries the third.
    let mut i = 0u64;
    while (i < 3) {
        let coin = coin::mint_for_testing<DUSDC>(min_supply!(), scenario.ctx());
        book.request_supply(coin, alice_id(), ALICE, NO_MIN_OUTPUT);
        i = i + 1;
    };

    let summary = book.drain(
        &mut ledger,
        lp_book::new_flush_mark(min_supply!(), min_supply!()),
        vault_id(),
        option::some(2),
        option::none(),
        NO_RETRY,
        NO_CAP,
        scenario.ctx(),
    );

    assert_drain_summary(&summary, 2, 0, 2);
    assert_eq!(book.total_supply(), 3 * min_supply!()); // locked + 2 filled
    assert_eq!(book.supply_requests_pending(), 1); // third carried

    // The carried supply fills on the next unbounded drain.
    book.drain(
        &mut ledger,
        lp_book::new_flush_mark(2 * min_supply!(), 3 * min_supply!()),
        vault_id(),
        option::none(),
        option::none(),
        NO_RETRY,
        NO_CAP,
        scenario.ctx(),
    );
    assert_eq!(book.supply_requests_pending(), 0);

    finish(scenario, book, ledger);
}

#[test]
fun independent_budgets_let_withdrawals_drain_under_supply_pressure() {
    let (mut scenario, mut book, mut ledger) = setup();
    // total_supply 30e6, idle 30e6 -> mark 1.0.
    book.mint_locked_liquidity(30_000_000);
    seed_idle(&mut ledger, 30_000_000);
    // Three supplies queued ahead of one withdrawal. Independent budgets of 1 each fill
    // exactly one of each, so the withdrawal drains despite the supply backlog.
    let mut i = 0u64;
    while (i < 3) {
        let coin = coin::mint_for_testing<DUSDC>(min_supply!(), scenario.ctx());
        book.request_supply(coin, alice_id(), ALICE, NO_MIN_OUTPUT);
        i = i + 1;
    };
    enqueue_withdraw(&mut scenario, &mut book, 10_000_000);

    let summary = book.drain(
        &mut ledger,
        lp_book::new_flush_mark(30_000_000, 30_000_000),
        vault_id(),
        option::some(1),
        option::some(1),
        NO_RETRY,
        NO_CAP,
        scenario.ctx(),
    );

    assert_drain_summary(&summary, 1, 1, 2); // withdrawal NOT starved
    assert_eq!(book.supply_requests_pending(), 2); // supply budget bounded to 1
    assert_eq!(book.withdraw_requests_pending(), 0);
    // +10e6 supplied (min_supply), +min_supply minted; -10e6 burned, -10e6 paid.
    assert_eq!(book.total_supply(), 30_000_000 + min_supply!() - 10_000_000);
    assert_eq!(ledger.idle_balance(), 30_000_000 + min_supply!() - 10_000_000);

    finish(scenario, book, ledger);
}

// === Cancellation returns the escrowed refund to the recipient ===

#[test]
fun cancel_supply_returns_escrowed_dusdc() {
    let (mut scenario, mut book, ledger) = setup();
    let coin = coin::mint_for_testing<DUSDC>(min_supply!(), scenario.ctx());
    let index = book.request_supply(coin, alice_id(), ALICE, NO_MIN_OUTPUT);

    let (account_id, amount, refund) = book.cancel_supply_request(ALICE, index);

    // The full escrow is returned, attributed to the cancelling account.
    assert_eq!(account_id, alice_id());
    assert_eq!(amount, min_supply!());
    assert_eq!(refund.value(), min_supply!());
    assert_eq!(book.supply_requests_pending(), 0);

    destroy(refund);
    finish(scenario, book, ledger);
}

#[test]
fun cancel_withdraw_returns_escrowed_plp() {
    let (mut scenario, mut book, ledger) = setup();
    let index = enqueue_withdraw(&mut scenario, &mut book, min_withdraw!());

    let (account_id, amount, refund) = book.cancel_withdraw_request(ALICE, index);

    assert_eq!(account_id, alice_id());
    assert_eq!(amount, min_withdraw!());
    assert_eq!(refund.value(), min_withdraw!());
    assert_eq!(book.withdraw_requests_pending(), 0);

    destroy(refund);
    finish(scenario, book, ledger);
}

#[test]
fun cancelled_supply_requests_do_not_spend_drain_budget() {
    let (mut scenario, mut book, mut ledger) = setup();
    book.mint_locked_liquidity(min_supply!());

    let cancelled = 5;
    let mut refunds = balance::zero<DUSDC>();
    let mut i = 0u64;
    while (i < cancelled) {
        let coin = coin::mint_for_testing<DUSDC>(min_supply!(), scenario.ctx());
        let index = book.request_supply(coin, alice_id(), ALICE, NO_MIN_OUTPUT);
        let (_id, _amount, refund) = book.cancel_supply_request(ALICE, index);
        refunds.join(refund);
        i = i + 1;
    };
    let coin = coin::mint_for_testing<DUSDC>(min_supply!(), scenario.ctx());
    let live_index = book.request_supply(coin, alice_id(), ALICE, NO_MIN_OUTPUT);
    assert_eq!(live_index, cancelled); // monotonic index, past the cancelled ones
    assert_eq!(book.supply_requests_pending(), 1);
    assert_eq!(refunds.value(), cancelled * min_supply!());

    // A supply_budget of 1 fills the single live request: the cancelled ones were
    // physically removed and never counted against the budget.
    let summary = book.drain(
        &mut ledger,
        lp_book::new_flush_mark(min_supply!(), min_supply!()),
        vault_id(),
        option::some(1),
        option::none(),
        NO_RETRY,
        NO_CAP,
        scenario.ctx(),
    );
    assert_drain_summary(&summary, 1, 0, 1);
    assert_eq!(book.total_supply(), 2 * min_supply!()); // locked + 1 live filled
    assert_eq!(book.supply_requests_pending(), 0);

    destroy(refunds);
    finish(scenario, book, ledger);
}

// === Request lookup / recipient / non-executable marks / minimum aborts ===

#[test, expected_failure(abort_code = lp_book::ERequestNotFound)]
fun cancel_unknown_supply_request_aborts() {
    let (scenario, mut book, ledger) = setup();
    let (_id, _amount, refund) = book.cancel_supply_request(ALICE, 0);

    destroy(refund);
    finish(scenario, book, ledger);
    abort 999
}

#[test, expected_failure(abort_code = lp_book::ENotRequestOwner)]
fun cancel_with_non_recipient_aborts() {
    let (mut scenario, mut book, ledger) = setup();
    // Alice's account owns the request...
    let coin = coin::mint_for_testing<DUSDC>(min_supply!(), scenario.ctx());
    let index = book.request_supply(coin, alice_id(), ALICE, NO_MIN_OUTPUT);

    // ...so Bob (a different recipient) cannot cancel it.
    let (_id, _amount, refund) = book.cancel_supply_request(BOB, index);
    destroy(refund);
    finish(scenario, book, ledger);
    abort 999
}

#[test]
fun priced_supply_with_zero_pool_value_refunds() {
    let (mut scenario, mut book, mut ledger) = setup();
    book.mint_locked_liquidity(min_supply!());
    let payment = coin::mint_for_testing<DUSDC>(min_supply!(), scenario.ctx());
    book.request_supply(payment, alice_id(), ALICE, NO_MIN_OUTPUT);

    let summary = book.drain(
        &mut ledger,
        lp_book::new_flush_mark(0, min_supply!()),
        vault_id(),
        option::none(),
        option::none(),
        NO_RETRY,
        NO_CAP,
        scenario.ctx(),
    );

    assert_drain_summary(&summary, NO_SUPPLIES_FILLED, NO_WITHDRAWALS_FILLED, 1);
    assert_eq!(book.supply_requests_pending(), 0);
    assert_eq!(book.total_supply(), min_supply!());
    assert_eq!(ledger.idle_balance(), 0);

    finish(scenario, book, ledger);
}

#[test]
fun priced_supply_that_rounds_to_zero_shares_refunds() {
    let (mut scenario, mut book, mut ledger) = setup();
    book.mint_locked_liquidity(min_supply!());
    let payment = coin::mint_for_testing<DUSDC>(min_supply!(), scenario.ctx());
    book.request_supply(payment, alice_id(), ALICE, NO_MIN_OUTPUT);

    // shares = floor(min_supply * min_supply / (min_supply^2 + 1)) = 0.
    let summary = book.drain(
        &mut ledger,
        lp_book::new_flush_mark(ZERO_SHARE_SUPPLY_POOL_VALUE, min_supply!()),
        vault_id(),
        option::none(),
        option::none(),
        NO_RETRY,
        NO_CAP,
        scenario.ctx(),
    );

    assert_drain_summary(&summary, NO_SUPPLIES_FILLED, NO_WITHDRAWALS_FILLED, 1);
    assert_eq!(book.supply_requests_pending(), 0);
    assert_eq!(book.total_supply(), min_supply!());
    assert_eq!(ledger.idle_balance(), 0);

    finish(scenario, book, ledger);
}

#[test]
fun priced_withdraw_that_rounds_to_zero_payout_refunds() {
    let (mut scenario, mut book, mut ledger) = setup();
    book.mint_locked_liquidity(ZERO_PAYOUT_WITHDRAW_TOTAL_SUPPLY);
    enqueue_withdraw(&mut scenario, &mut book, min_withdraw!());

    // payout = floor(min_withdraw * 1 / (min_withdraw + 1)) = 0.
    let summary = book.drain(
        &mut ledger,
        lp_book::new_flush_mark(1, ZERO_PAYOUT_WITHDRAW_TOTAL_SUPPLY),
        vault_id(),
        option::none(),
        option::none(),
        NO_RETRY,
        NO_CAP,
        scenario.ctx(),
    );

    assert_drain_summary(&summary, NO_SUPPLIES_FILLED, NO_WITHDRAWALS_FILLED, 1);
    assert_eq!(book.withdraw_requests_pending(), 0);
    assert_eq!(book.total_supply(), ZERO_PAYOUT_WITHDRAW_TOTAL_SUPPLY);
    assert_eq!(ledger.idle_balance(), 0);

    finish(scenario, book, ledger);
}

#[test]
fun supply_at_min_executable_plp_price_fills() {
    let (mut scenario, mut book, mut ledger) = setup();
    book.mint_locked_liquidity(ONE_PLP);
    let payment = coin::mint_for_testing<DUSDC>(min_supply!(), scenario.ctx());
    book.request_supply(payment, alice_id(), ALICE, NO_MIN_OUTPUT);

    // At 0.01 DUSDC/PLP, 10 DUSDC mints 1,000 PLP = 1_000_000_000 raw shares.
    let summary = book.drain(
        &mut ledger,
        lp_book::new_flush_mark(MIN_EXECUTABLE_PLP_PRICE, ONE_PLP),
        vault_id(),
        option::none(),
        option::none(),
        NO_RETRY,
        NO_CAP,
        scenario.ctx(),
    );

    assert_drain_summary(&summary, 1, 0, 1);
    assert_eq!(book.total_supply(), 1_001_000_000);
    assert_eq!(ledger.idle_balance(), min_supply!());

    finish(scenario, book, ledger);
}

#[test]
fun supply_below_min_executable_plp_price_refunds() {
    let (mut scenario, mut book, mut ledger) = setup();
    book.mint_locked_liquidity(ONE_PLP);
    let payment = coin::mint_for_testing<DUSDC>(min_supply!(), scenario.ctx());
    book.request_supply(payment, alice_id(), ALICE, NO_MIN_OUTPUT);

    let summary = book.drain(
        &mut ledger,
        lp_book::new_flush_mark(MIN_EXECUTABLE_PLP_PRICE - 1, ONE_PLP),
        vault_id(),
        option::none(),
        option::none(),
        NO_RETRY,
        NO_CAP,
        scenario.ctx(),
    );

    assert_drain_summary(&summary, NO_SUPPLIES_FILLED, NO_WITHDRAWALS_FILLED, 1);
    assert_eq!(book.supply_requests_pending(), 0);
    assert_eq!(book.total_supply(), ONE_PLP);
    assert_eq!(ledger.idle_balance(), 0);

    finish(scenario, book, ledger);
}

#[test]
fun supply_at_max_executable_plp_price_fills() {
    let (mut scenario, mut book, mut ledger) = setup();
    book.mint_locked_liquidity(ONE_PLP);
    let payment = coin::mint_for_testing<DUSDC>(min_supply!(), scenario.ctx());
    book.request_supply(payment, alice_id(), ALICE, NO_MIN_OUTPUT);

    // At 100 DUSDC/PLP, 10 DUSDC mints 0.1 PLP = 100_000 raw shares.
    let summary = book.drain(
        &mut ledger,
        lp_book::new_flush_mark(MAX_EXECUTABLE_PLP_PRICE, ONE_PLP),
        vault_id(),
        option::none(),
        option::none(),
        NO_RETRY,
        NO_CAP,
        scenario.ctx(),
    );

    assert_drain_summary(&summary, 1, 0, 1);
    assert_eq!(book.total_supply(), 1_100_000);
    assert_eq!(ledger.idle_balance(), min_supply!());

    finish(scenario, book, ledger);
}

#[test]
fun supply_above_max_executable_plp_price_refunds() {
    let (mut scenario, mut book, mut ledger) = setup();
    book.mint_locked_liquidity(ONE_PLP);
    let payment = coin::mint_for_testing<DUSDC>(min_supply!(), scenario.ctx());
    book.request_supply(payment, alice_id(), ALICE, NO_MIN_OUTPUT);

    let summary = book.drain(
        &mut ledger,
        lp_book::new_flush_mark(MAX_EXECUTABLE_PLP_PRICE + 1, ONE_PLP),
        vault_id(),
        option::none(),
        option::none(),
        NO_RETRY,
        NO_CAP,
        scenario.ctx(),
    );

    assert_drain_summary(&summary, NO_SUPPLIES_FILLED, NO_WITHDRAWALS_FILLED, 1);
    assert_eq!(book.supply_requests_pending(), 0);
    assert_eq!(book.total_supply(), ONE_PLP);
    assert_eq!(ledger.idle_balance(), 0);

    finish(scenario, book, ledger);
}

#[test]
fun oversized_supply_that_exceeds_u64_shares_refunds() {
    let (mut scenario, mut book, mut ledger) = setup();
    book.mint_locked_liquidity(ONE_PLP);
    let payment = coin::mint_for_testing<DUSDC>(std::u64::max_value!(), scenario.ctx());
    book.request_supply(payment, alice_id(), ALICE, NO_MIN_OUTPUT);

    // At the executable floor price, max-u64 DUSDC would mint max_u64 * 100
    // raw PLP shares, which does not fit in u64 and is therefore non-executable.
    let summary = book.drain(
        &mut ledger,
        lp_book::new_flush_mark(MIN_EXECUTABLE_PLP_PRICE, ONE_PLP),
        vault_id(),
        option::none(),
        option::none(),
        NO_RETRY,
        NO_CAP,
        scenario.ctx(),
    );

    assert_drain_summary(&summary, NO_SUPPLIES_FILLED, NO_WITHDRAWALS_FILLED, 1);
    assert_eq!(book.supply_requests_pending(), 0);
    assert_eq!(book.total_supply(), ONE_PLP);
    assert_eq!(ledger.idle_balance(), 0);

    finish(scenario, book, ledger);
}

#[test]
fun supply_that_exceeds_remaining_plp_headroom_fills_the_representable_prefix() {
    let (mut scenario, mut book, mut ledger) = setup();
    let near_max_total_supply = std::u64::max_value!() - NEAR_MAX_SUPPLY_HEADROOM;
    book.mint_locked_liquidity(near_max_total_supply);
    let payment = coin::mint_for_testing<DUSDC>(min_supply!(), scenario.ctx());
    book.request_supply(payment, alice_id(), ALICE, NO_MIN_OUTPUT);

    // At a 1.0 executable mark the 10 DUSDC request quotes 10e6 shares, but only
    // 5_000_000 raw units remain before the treasury supply cap. The drain mints the
    // 5e6 that fit and leaves the rest queued rather than refusing the whole request.
    let summary = book.drain(
        &mut ledger,
        lp_book::new_flush_mark(near_max_total_supply, near_max_total_supply),
        vault_id(),
        option::none(),
        option::none(),
        NO_RETRY,
        NO_CAP,
        scenario.ctx(),
    );

    assert_drain_summary(&summary, 1, NO_WITHDRAWALS_FILLED, 1);
    assert_eq!(book.supply_requests_pending(), 1); // the unmintable half waits
    assert_eq!(book.total_supply(), std::u64::max_value!()); // exactly full
    assert_eq!(ledger.idle_balance(), NEAR_MAX_SUPPLY_HEADROOM);

    finish(scenario, book, ledger);
}

#[test]
fun non_executable_supply_refunds_spend_supply_budget() {
    let (mut scenario, mut book, mut ledger) = setup();
    book.mint_locked_liquidity(ONE_PLP);
    let mut i = 0u64;
    while (i < 3) {
        let payment = coin::mint_for_testing<DUSDC>(min_supply!(), scenario.ctx());
        book.request_supply(payment, alice_id(), ALICE, NO_MIN_OUTPUT);
        i = i + 1;
    };

    let summary = book.drain(
        &mut ledger,
        lp_book::new_flush_mark(MIN_EXECUTABLE_PLP_PRICE - 1, ONE_PLP),
        vault_id(),
        option::some(2),
        option::none(),
        NO_RETRY,
        NO_CAP,
        scenario.ctx(),
    );

    assert_drain_summary(&summary, NO_SUPPLIES_FILLED, NO_WITHDRAWALS_FILLED, 2);
    assert_eq!(book.supply_requests_pending(), 1);
    assert_eq!(book.total_supply(), ONE_PLP);
    assert_eq!(ledger.idle_balance(), 0);

    finish(scenario, book, ledger);
}

#[test]
fun non_executable_withdraw_refunds_spend_withdraw_budget() {
    let (mut scenario, mut book, mut ledger) = setup();
    book.mint_locked_liquidity(ZERO_PAYOUT_WITHDRAW_TOTAL_SUPPLY);
    enqueue_withdraw(&mut scenario, &mut book, min_withdraw!());
    enqueue_withdraw(&mut scenario, &mut book, min_withdraw!());

    let summary = book.drain(
        &mut ledger,
        lp_book::new_flush_mark(1, ZERO_PAYOUT_WITHDRAW_TOTAL_SUPPLY),
        vault_id(),
        option::none(),
        option::some(1),
        NO_RETRY,
        NO_CAP,
        scenario.ctx(),
    );

    assert_drain_summary(&summary, NO_SUPPLIES_FILLED, NO_WITHDRAWALS_FILLED, 1);
    assert_eq!(book.withdraw_requests_pending(), 1);
    assert_eq!(book.total_supply(), ZERO_PAYOUT_WITHDRAW_TOTAL_SUPPLY);
    assert_eq!(ledger.idle_balance(), 0);

    finish(scenario, book, ledger);
}

#[test, expected_failure(abort_code = lp_book::EBelowMinSupplyRequest)]
fun request_supply_below_min_aborts() {
    let (mut scenario, mut book, _ledger) = setup();
    let coin = coin::mint_for_testing<DUSDC>(min_supply!() - 1, scenario.ctx());
    book.request_supply(coin, alice_id(), ALICE, NO_MIN_OUTPUT);

    abort 999
}

#[test, expected_failure(abort_code = lp_book::EBelowMinWithdrawRequest)]
fun request_withdraw_below_min_aborts() {
    let (mut scenario, mut book, _ledger) = setup();
    let lp = coin::mint_for_testing<LP_BOOK_TESTS>(min_withdraw!() - 1, scenario.ctx());
    book.request_withdraw(lp, alice_id(), ALICE, NO_MIN_OUTPUT);

    abort 999
}

// === Helpers ===

fun setup(): (Scenario, LpBook<LP_BOOK_TESTS>, Ledger) {
    let mut scenario = test::begin(ALICE);
    let (book, ledger) = new_book(scenario.ctx());
    (scenario, book, ledger)
}

/// A stable dummy account id for the requesting account (event/attribution only).
fun alice_id(): ID { ALICE.to_id() }

/// A second requesting account, so queue-ordering tests can tell two owners apart.
fun bob_id(): ID { BOB.to_id() }

/// No executable mark can ever quote this, so a request carrying it always misses.
fun unattainable_min_out(): u64 { std::u64::max_value!() }

/// Drain at a 1.0 mark with pool value 30e6, under an explicit pool-value ceiling.
fun drain_at_par_with_cap(
    scenario: &mut Scenario,
    book: &mut LpBook<LP_BOOK_TESTS>,
    ledger: &mut Ledger,
    max_pool_value: u64,
): DrainSummary {
    book.drain(
        ledger,
        lp_book::new_flush_mark(30_000_000, 30_000_000),
        vault_id(),
        option::none(),
        option::none(),
        NO_RETRY,
        max_pool_value,
        scenario.ctx(),
    )
}

/// Drain both queues at a 1.0 share price, so a budget test varies only the budget.
fun drain_at_par_with_budgets(
    scenario: &mut Scenario,
    book: &mut LpBook<LP_BOOK_TESTS>,
    ledger: &mut Ledger,
    supply_budget: Option<u64>,
    withdraw_budget: Option<u64>,
): DrainSummary {
    book.drain(
        ledger,
        lp_book::new_flush_mark(30_000_000, 30_000_000),
        vault_id(),
        supply_budget,
        withdraw_budget,
        NO_RETRY,
        NO_CAP,
        scenario.ctx(),
    )
}

/// Drain at the 2.0 mark (pool 60e6 over supply 30e6) with unbounded budgets, so a
/// repeated-flush test varies only the attempt count.
fun drain_at_two_x(
    scenario: &mut Scenario,
    book: &mut LpBook<LP_BOOK_TESTS>,
    ledger: &mut Ledger,
    max_limit_misses: u64,
): DrainSummary {
    book.drain(
        ledger,
        lp_book::new_flush_mark(60_000_000, 30_000_000),
        vault_id(),
        option::none(),
        option::none(),
        max_limit_misses,
        NO_CAP,
        scenario.ctx(),
    )
}

/// A stable dummy pool-vault id for drain-event attribution.
fun vault_id(): ID { @0xFEED.to_id() }

fun new_book(ctx: &mut TxContext): (LpBook<LP_BOOK_TESTS>, Ledger) {
    let (initializer, treasury_cap) = coin_registry::new_currency_with_otw(
        LP_BOOK_TESTS {},
        6,
        b"TLP".to_string(),
        b"Test LP".to_string(),
        b"Test LP token".to_string(),
        b"".to_string(),
        ctx,
    );
    destroy(initializer.finalize(ctx));
    (lp_book::new(treasury_cap, ctx), pool_accounting::new(ctx))
}

/// Seed pool idle DUSDC directly so withdraw drains have liquidity to pay from.
fun seed_idle(ledger: &mut Ledger, amount: u64) {
    ledger.receive_idle(balance::create_for_testing<DUSDC>(amount));
}

/// Queue one withdraw request escrowing a `mint_for_testing` LP stand-in for
/// accumulator-delivered shares.
fun enqueue_withdraw(scenario: &mut Scenario, book: &mut LpBook<LP_BOOK_TESTS>, amount: u64): u64 {
    enqueue_withdraw_with_limit(scenario, book, amount, NO_MIN_OUTPUT)
}

fun enqueue_withdraw_with_limit(
    scenario: &mut Scenario,
    book: &mut LpBook<LP_BOOK_TESTS>,
    amount: u64,
    min_output: u64,
): u64 {
    enqueue_withdraw_for(scenario, book, ALICE, amount, min_output)
}

/// Queue a withdraw request owned by `recipient`, so one test can stage requests
/// from two different LPs in a known order.
fun enqueue_withdraw_for(
    scenario: &mut Scenario,
    book: &mut LpBook<LP_BOOK_TESTS>,
    recipient: address,
    amount: u64,
    min_output: u64,
): u64 {
    let lp = coin::mint_for_testing<LP_BOOK_TESTS>(amount, scenario.ctx());
    book.request_withdraw(lp, recipient.to_id(), recipient, min_output)
}

fun assert_drain_summary(
    summary: &DrainSummary,
    supplies_filled: u64,
    withdrawals_filled: u64,
    requests_processed: u64,
) {
    assert_eq!(summary.supplies_filled(), supplies_filled);
    assert_eq!(summary.withdrawals_filled(), withdrawals_filled);
    assert_eq!(summary.requests_processed(), requests_processed);
}

fun finish(scenario: Scenario, book: LpBook<LP_BOOK_TESTS>, ledger: Ledger) {
    destroy(book);
    destroy(ledger);
    scenario.end();
}

// === Partial-fill follow-ups: cancel, and repeated partials ===

/// Cancelling after a partial fill must return only what is still escrowed — the
/// filled part already became PLP. Pins that `remove_for_recipient` reads the entry's
/// reduced amount rather than the amount originally requested.
#[test]
fun cancel_after_a_partial_fill_refunds_only_the_remainder() {
    let (mut scenario, mut book, mut ledger) = setup();
    book.mint_locked_liquidity(30_000_000);
    let payment = coin::mint_for_testing<DUSDC>(30_000_000, scenario.ctx());
    let index = book.request_supply(payment, alice_id(), ALICE, NO_MIN_OUTPUT);

    // 10 of room against a 30 deposit: 10 fills, 20 stays queued.
    drain_at_par_with_cap(&mut scenario, &mut book, &mut ledger, 40_000_000);
    assert_eq!(book.supply_requests_pending(), 1);

    let (_id, amount, refund) = book.cancel_supply_request(ALICE, index);
    // The cancel reports and returns the unfilled 20, not the original 30.
    assert_eq!(amount, 20_000_000);
    assert_eq!(refund.value(), 20_000_000);
    assert_eq!(book.supply_requests_pending(), 0);

    refund.destroy_for_testing();
    finish(scenario, book, ledger);
}

/// A request filled a slice at a time across several flushes still completes, and the
/// limit it carries stays satisfiable. The rescale rounds up, so the effective rate can
/// only tighten; this pins that the tightening does not strand the request. The 2/3
/// limit below divides unevenly on purpose, so the rescale actually rounds.
#[test]
fun repeated_partial_fills_complete_the_request() {
    let (mut scenario, mut book, mut ledger) = setup();
    book.mint_locked_liquidity(30_000_000);
    // 30 DUSDC asking 20 PLP: a 2/3 rate, comfortably under the 1.0 mark.
    let payment = coin::mint_for_testing<DUSDC>(30_000_000, scenario.ctx());
    book.request_supply(payment, alice_id(), ALICE, 20_000_000);

    // Room opens 10, then 15, then enough for the rest. The carried limit is rescaled
    // and rounded up at each step: 20 -> 13.333334 -> 3.333334, each still clearing.
    let summary = drain_at_par_with_cap(&mut scenario, &mut book, &mut ledger, 40_000_000);
    assert_drain_summary(&summary, 1, NO_WITHDRAWALS_FILLED, 1);
    assert_eq!(book.supply_requests_pending(), 1);
    assert_eq!(book.total_supply(), 40_000_000);

    let summary = drain_at_par_with_cap(&mut scenario, &mut book, &mut ledger, 45_000_000);
    assert_drain_summary(&summary, 1, NO_WITHDRAWALS_FILLED, 1);
    assert_eq!(book.supply_requests_pending(), 1);
    assert_eq!(book.total_supply(), 55_000_000);

    let summary = drain_at_par_with_cap(&mut scenario, &mut book, &mut ledger, 60_000_000);
    assert_drain_summary(&summary, 1, NO_WITHDRAWALS_FILLED, 1);

    // Fully served across three flushes: all 30 DUSDC in, 30 PLP minted on top of the
    // 30 locked, and nothing stranded by the tightening limit.
    assert_eq!(book.supply_requests_pending(), 0);
    assert_eq!(book.total_supply(), 60_000_000);
    assert_eq!(ledger.idle_balance(), 30_000_000);

    finish(scenario, book, ledger);
}

/// The carried limit must round **up**, and this is the only test that can tell the
/// difference. At the 2/3 mark a 40.000001 DUSDC request asking 26.666667 PLP sits just
/// under the mark's rate, so the 30 prefix clears its own proportional minimum and
/// fills. What is left, 10.000001, then quotes 6.666667 against a carried limit of
/// ceil = 6.666668 — one unit short, so it is refused. Rounding down would carry
/// 6.666667 instead and fill it, minting 6.666667 more PLP. Every other assertion in
/// the suite is identical under both directions.
#[test]
fun carried_limit_rounds_up_and_refuses_a_fill_below_the_requested_price() {
    let (mut scenario, mut book, mut ledger) = setup();
    book.mint_locked_liquidity(20_000_000);
    let payment = coin::mint_for_testing<DUSDC>(40_000_001, scenario.ctx());
    book.request_supply(payment, alice_id(), ALICE, 26_666_667);

    // 30 of room: the prefix quotes 20e6 against a proportional minimum of 20e6, so it
    // fills exactly at price and carries 10.000001.
    let summary = drain_at_two_thirds(&mut scenario, &mut book, &mut ledger, 60_000_000);
    assert_drain_summary(&summary, 1, NO_WITHDRAWALS_FILLED, 1);
    assert_eq!(book.supply_requests_pending(), 1);
    assert_eq!(book.total_supply(), 40_000_000);

    // Ample room now, but the remainder is a unit short of its carried limit.
    let summary = drain_at_two_thirds(&mut scenario, &mut book, &mut ledger, 90_000_000);
    assert_drain_summary(&summary, NO_SUPPLIES_FILLED, NO_WITHDRAWALS_FILLED, 1);
    assert_eq!(book.supply_requests_pending(), 0);
    // Nothing further minted. Rounding down would have minted 6.666667 more here.
    assert_eq!(book.total_supply(), 40_000_000);

    finish(scenario, book, ledger);
}

/// Drain at a 2/3 share price (pool 30e6 over supply 20e6) under an explicit cap.
fun drain_at_two_thirds(
    scenario: &mut Scenario,
    book: &mut LpBook<LP_BOOK_TESTS>,
    ledger: &mut Ledger,
    max_pool_value: u64,
): DrainSummary {
    book.drain(
        ledger,
        lp_book::new_flush_mark(30_000_000, 20_000_000),
        vault_id(),
        option::none(),
        option::none(),
        NO_RETRY,
        max_pool_value,
        scenario.ctx(),
    )
}

// === Prefix pricing: a slice must clear the request's own price ===

/// The prefix is quoted on its own and rounds down, so clearing the limit on the whole
/// request does not imply clearing it on a slice. Aslan's case: 30 DUSDC asking 20 PLP
/// at the 2/3 mark, with room for exactly 20 — the slice quotes floor(20 x 2/3) =
/// 13.333333 while the request's own price needs ceil(20 x 20/30) = 13.333334. The
/// slice is carried, not filled a hair under price; rounding the pool's quote up to
/// close the gap instead would pay the difference out of the LPs who stay.
#[test]
fun supply_prefix_below_the_requests_price_is_carried_not_filled() {
    let (mut scenario, mut book, mut ledger) = setup();
    book.mint_locked_liquidity(20_000_000);
    let payment = coin::mint_for_testing<DUSDC>(30_000_000, scenario.ctx());
    book.request_supply(payment, alice_id(), ALICE, 20_000_000);

    // Cap 50e6 over pool value 30e6 leaves exactly the 20 of room from the example.
    let summary = drain_at_two_thirds(&mut scenario, &mut book, &mut ledger, 50_000_000);

    // Nothing filled, nothing minted, no budget spent — the head simply waits.
    assert_drain_summary(&summary, NO_SUPPLIES_FILLED, NO_WITHDRAWALS_FILLED, 0);
    assert_eq!(book.supply_requests_pending(), 1);
    assert_eq!(book.total_supply(), 20_000_000);
    assert_eq!(ledger.idle_balance(), 0);

    finish(scenario, book, ledger);
}

/// The withdraw prefix carries the same hazard, so it gets the same guard. At the 2/3
/// mark a 30 PLP exit asking 45 DUSDC is exactly at price; 10.000001 of idle affords
/// floor(10.000001 x 2/3) = 6.666667 shares, which quote floor(6.666667 x 1.5) =
/// 10.000000 against a proportional minimum of ceil(45 x 6.666667/30) = 10.000001.
/// One unit short, so it carries rather than paying the exiting LP under their price.
#[test]
fun withdraw_prefix_below_the_requests_price_is_carried_not_paid() {
    let (mut scenario, mut book, mut ledger) = setup();
    book.mint_locked_liquidity(50_000_000);
    seed_idle(&mut ledger, 10_000_001);
    enqueue_withdraw_with_limit(&mut scenario, &mut book, 30_000_000, 45_000_000);

    let summary = drain_at_two_thirds(&mut scenario, &mut book, &mut ledger, NO_CAP);

    // Carried whole: no payout, no burn, no budget spent, escrow still queued.
    assert_drain_summary(&summary, NO_SUPPLIES_FILLED, NO_WITHDRAWALS_FILLED, 0);
    assert_eq!(book.withdraw_requests_pending(), 1);
    assert_eq!(book.total_supply(), 50_000_000);
    assert_eq!(ledger.idle_balance(), 10_000_001);

    finish(scenario, book, ledger);
}
