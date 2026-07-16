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
    constants::{
        lp_request_limit_flush_attempts as limit_attempts,
        max_executable_plp_price as max_plp_price,
        min_executable_plp_price as min_plp_price,
        min_supply_request as min_supply,
        min_withdraw_request as min_withdraw,
        plp_price_unit as plp_unit,
    },
    lp_book::{Self, DrainSummary, LpBook},
    pool_accounting::{Self, Ledger}
};
use dusdc::dusdc::DUSDC;
use std::unit_test::{assert_eq, destroy};
use sui::{balance, coin, coin_registry, test_scenario::{Self as test, Scenario}};

public struct LP_BOOK_TESTS has drop {}

const ALICE: address = @0xA;
const BOB: address = @0xB0B;
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
const LIMIT_PASS_SUPPLY_QUOTE: u64 = 20_000_000;
const LIMIT_MISS_WITHDRAW_AMOUNT: u64 = 10_000_000;
const LIMIT_MISS_WITHDRAW_QUOTE: u64 = 20_000_000;
const LIMIT_MISS_WITHDRAW_MIN_OUT: u64 = LIMIT_MISS_WITHDRAW_QUOTE + 1_000_000;

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
        scenario.ctx(),
    );

    assert_eq!(ledger.idle_balance(), 16_666_668); // 50e6 - 2 * 16_666_666 (frozen); repriced would leave 16_666_667
    assert_eq!(book.total_supply(), 10_000_000); // 30e6 - 2 * 10e6 burned
    assert_eq!(book.withdraw_requests_pending(), 0);

    finish(scenario, book, ledger);
}

// === FIFO-until-idle-dry ===

#[test]
fun withdrawals_stop_when_idle_is_dry_and_carry() {
    let (mut scenario, mut book, mut ledger) = setup();
    // total_supply 30e6, idle 30e6 -> mark 1.0.
    book.mint_locked_liquidity(30_000_000);
    seed_idle(&mut ledger, 30_000_000);
    // Two 20e6 withdrawals: first fills (idle 30e6 -> 10e6); second needs 20e6 but idle
    // is only 10e6, so the pass stops and carries it.
    enqueue_withdraw(&mut scenario, &mut book, 20_000_000);
    enqueue_withdraw(&mut scenario, &mut book, 20_000_000);

    let summary = book.drain(
        &mut ledger,
        lp_book::new_flush_mark(30_000_000, 30_000_000),
        vault_id(),
        option::none(),
        option::none(),
        scenario.ctx(),
    );

    assert_drain_summary(&summary, 0, 1, 1); // only the first; the dry head carries
    assert_eq!(book.total_supply(), 10_000_000); // only the first 20e6 burned
    assert_eq!(ledger.idle_balance(), 10_000_000); // only the first 20e6 paid
    assert_eq!(book.withdraw_requests_pending(), 1); // second carried

    finish(scenario, book, ledger);
}

// === Request limits and retry expiry ===

#[test]
fun supply_limit_miss_carries_then_fills_when_mark_improves() {
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
        scenario.ctx(),
    );

    assert_drain_summary(&summary, NO_SUPPLIES_FILLED, NO_WITHDRAWALS_FILLED, 1);
    assert_eq!(book.supply_requests_pending(), 1);
    assert_eq!(book.total_supply(), 30_000_000);
    assert_eq!(ledger.idle_balance(), 0);

    // Improved mark 1.0 -> supply quotes 20e6 shares, satisfying the same queued request.
    let summary = book.drain(
        &mut ledger,
        lp_book::new_flush_mark(30_000_000, 30_000_000),
        vault_id(),
        option::none(),
        option::none(),
        scenario.ctx(),
    );

    assert_drain_summary(&summary, 1, NO_WITHDRAWALS_FILLED, 1);
    assert_eq!(book.supply_requests_pending(), 0);
    assert_eq!(book.total_supply(), 30_000_000 + LIMIT_PASS_SUPPLY_QUOTE);
    assert_eq!(ledger.idle_balance(), LIMIT_MISS_SUPPLY_AMOUNT);

    finish(scenario, book, ledger);
}

#[test]
fun supply_limit_expires_after_three_misses() {
    let (mut scenario, mut book, mut ledger) = setup();
    // Each flush quotes 10e6 shares against an 11e6 minimum, so the third miss refunds.
    book.mint_locked_liquidity(30_000_000);
    let payment = coin::mint_for_testing<DUSDC>(LIMIT_MISS_SUPPLY_AMOUNT, scenario.ctx());
    book.request_supply(payment, alice_id(), ALICE, LIMIT_MISS_SUPPLY_MIN_OUT);

    let mut i = 0u64;
    while (i < limit_attempts!() - 1) {
        let summary = book.drain(
            &mut ledger,
            lp_book::new_flush_mark(60_000_000, 30_000_000),
            vault_id(),
            option::none(),
            option::none(),
            scenario.ctx(),
        );
        assert_drain_summary(&summary, NO_SUPPLIES_FILLED, NO_WITHDRAWALS_FILLED, 1);
        assert_eq!(book.supply_requests_pending(), 1);
        i = i + 1;
    };

    let summary = book.drain(
        &mut ledger,
        lp_book::new_flush_mark(60_000_000, 30_000_000),
        vault_id(),
        option::none(),
        option::none(),
        scenario.ctx(),
    );

    assert_drain_summary(&summary, NO_SUPPLIES_FILLED, NO_WITHDRAWALS_FILLED, 1);
    assert_eq!(book.supply_requests_pending(), 0);
    assert_eq!(book.total_supply(), 30_000_000);
    assert_eq!(ledger.idle_balance(), 0);

    finish(scenario, book, ledger);
}

#[test]
fun withdraw_limit_miss_carries_then_fills_when_mark_improves() {
    let (mut scenario, mut book, mut ledger) = setup();
    // total_supply 30e6, first mark 2.0 -> withdraw quotes 20e6 DUSDC, below the 21e6 limit.
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
        scenario.ctx(),
    );

    assert_drain_summary(&summary, NO_SUPPLIES_FILLED, NO_WITHDRAWALS_FILLED, 1);
    assert_eq!(book.withdraw_requests_pending(), 1);
    assert_eq!(book.total_supply(), 30_000_000);
    assert_eq!(ledger.idle_balance(), 60_000_000);

    // Improved mark 2.1 -> withdraw quotes exactly 21e6 DUSDC, satisfying the request.
    let summary = book.drain(
        &mut ledger,
        lp_book::new_flush_mark(63_000_000, 30_000_000),
        vault_id(),
        option::none(),
        option::none(),
        scenario.ctx(),
    );

    assert_drain_summary(&summary, NO_SUPPLIES_FILLED, 1, 1);
    assert_eq!(book.withdraw_requests_pending(), 0);
    assert_eq!(book.total_supply(), 30_000_000 - LIMIT_MISS_WITHDRAW_AMOUNT);
    assert_eq!(ledger.idle_balance(), 60_000_000 - LIMIT_MISS_WITHDRAW_MIN_OUT);

    finish(scenario, book, ledger);
}

#[test]
fun withdraw_limit_expires_after_three_misses() {
    let (mut scenario, mut book, mut ledger) = setup();
    // Each flush quotes 20e6 DUSDC against a 21e6 minimum, so the third miss refunds.
    book.mint_locked_liquidity(30_000_000);
    seed_idle(&mut ledger, 60_000_000);
    enqueue_withdraw_with_limit(
        &mut scenario,
        &mut book,
        LIMIT_MISS_WITHDRAW_AMOUNT,
        LIMIT_MISS_WITHDRAW_MIN_OUT,
    );

    let mut i = 0u64;
    while (i < limit_attempts!() - 1) {
        let summary = book.drain(
            &mut ledger,
            lp_book::new_flush_mark(60_000_000, 30_000_000),
            vault_id(),
            option::none(),
            option::none(),
            scenario.ctx(),
        );
        assert_drain_summary(&summary, NO_SUPPLIES_FILLED, NO_WITHDRAWALS_FILLED, 1);
        assert_eq!(book.withdraw_requests_pending(), 1);
        i = i + 1;
    };

    let summary = book.drain(
        &mut ledger,
        lp_book::new_flush_mark(60_000_000, 30_000_000),
        vault_id(),
        option::none(),
        option::none(),
        scenario.ctx(),
    );

    assert_drain_summary(&summary, NO_SUPPLIES_FILLED, NO_WITHDRAWALS_FILLED, 1);
    assert_eq!(book.withdraw_requests_pending(), 0);
    assert_eq!(book.total_supply(), 30_000_000);
    assert_eq!(ledger.idle_balance(), 60_000_000);

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
        scenario.ctx(),
    );

    assert_drain_summary(&summary, total, 0, total);
    assert_eq!(book.total_supply(), (total + 1) * min_supply!()); // locked + 101 minted
    assert_eq!(ledger.idle_balance(), total * min_supply!());
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
    book.mint_locked_liquidity(plp_unit!());
    let payment = coin::mint_for_testing<DUSDC>(min_supply!(), scenario.ctx());
    book.request_supply(payment, alice_id(), ALICE, NO_MIN_OUTPUT);

    // At 0.01 DUSDC/PLP, 10 DUSDC mints 1,000 PLP = 1_000_000_000 raw shares.
    let summary = book.drain(
        &mut ledger,
        lp_book::new_flush_mark(min_plp_price!(), plp_unit!()),
        vault_id(),
        option::none(),
        option::none(),
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
    book.mint_locked_liquidity(plp_unit!());
    let payment = coin::mint_for_testing<DUSDC>(min_supply!(), scenario.ctx());
    book.request_supply(payment, alice_id(), ALICE, NO_MIN_OUTPUT);

    let summary = book.drain(
        &mut ledger,
        lp_book::new_flush_mark(min_plp_price!() - 1, plp_unit!()),
        vault_id(),
        option::none(),
        option::none(),
        scenario.ctx(),
    );

    assert_drain_summary(&summary, NO_SUPPLIES_FILLED, NO_WITHDRAWALS_FILLED, 1);
    assert_eq!(book.supply_requests_pending(), 0);
    assert_eq!(book.total_supply(), plp_unit!());
    assert_eq!(ledger.idle_balance(), 0);

    finish(scenario, book, ledger);
}

#[test]
fun supply_at_max_executable_plp_price_fills() {
    let (mut scenario, mut book, mut ledger) = setup();
    book.mint_locked_liquidity(plp_unit!());
    let payment = coin::mint_for_testing<DUSDC>(min_supply!(), scenario.ctx());
    book.request_supply(payment, alice_id(), ALICE, NO_MIN_OUTPUT);

    // At 100 DUSDC/PLP, 10 DUSDC mints 0.1 PLP = 100_000 raw shares.
    let summary = book.drain(
        &mut ledger,
        lp_book::new_flush_mark(max_plp_price!(), plp_unit!()),
        vault_id(),
        option::none(),
        option::none(),
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
    book.mint_locked_liquidity(plp_unit!());
    let payment = coin::mint_for_testing<DUSDC>(min_supply!(), scenario.ctx());
    book.request_supply(payment, alice_id(), ALICE, NO_MIN_OUTPUT);

    let summary = book.drain(
        &mut ledger,
        lp_book::new_flush_mark(max_plp_price!() + 1, plp_unit!()),
        vault_id(),
        option::none(),
        option::none(),
        scenario.ctx(),
    );

    assert_drain_summary(&summary, NO_SUPPLIES_FILLED, NO_WITHDRAWALS_FILLED, 1);
    assert_eq!(book.supply_requests_pending(), 0);
    assert_eq!(book.total_supply(), plp_unit!());
    assert_eq!(ledger.idle_balance(), 0);

    finish(scenario, book, ledger);
}

#[test]
fun oversized_supply_that_exceeds_u64_shares_refunds() {
    let (mut scenario, mut book, mut ledger) = setup();
    book.mint_locked_liquidity(plp_unit!());
    let payment = coin::mint_for_testing<DUSDC>(std::u64::max_value!(), scenario.ctx());
    book.request_supply(payment, alice_id(), ALICE, NO_MIN_OUTPUT);

    // At the executable floor price, max-u64 DUSDC would mint max_u64 * 100
    // raw PLP shares, which does not fit in u64 and is therefore non-executable.
    let summary = book.drain(
        &mut ledger,
        lp_book::new_flush_mark(min_plp_price!(), plp_unit!()),
        vault_id(),
        option::none(),
        option::none(),
        scenario.ctx(),
    );

    assert_drain_summary(&summary, NO_SUPPLIES_FILLED, NO_WITHDRAWALS_FILLED, 1);
    assert_eq!(book.supply_requests_pending(), 0);
    assert_eq!(book.total_supply(), plp_unit!());
    assert_eq!(ledger.idle_balance(), 0);

    finish(scenario, book, ledger);
}

#[test]
fun supply_that_exceeds_remaining_plp_headroom_refunds() {
    let (mut scenario, mut book, mut ledger) = setup();
    let near_max_total_supply = std::u64::max_value!() - NEAR_MAX_SUPPLY_HEADROOM;
    book.mint_locked_liquidity(near_max_total_supply);
    let payment = coin::mint_for_testing<DUSDC>(min_supply!(), scenario.ctx());
    book.request_supply(payment, alice_id(), ALICE, NO_MIN_OUTPUT);

    // At a 1.0 executable mark, the min supply request quotes to min_supply shares,
    // but only 5_000_000 PLP raw units remain before the treasury supply cap.
    let summary = book.drain(
        &mut ledger,
        lp_book::new_flush_mark(near_max_total_supply, near_max_total_supply),
        vault_id(),
        option::none(),
        option::none(),
        scenario.ctx(),
    );

    assert_drain_summary(&summary, NO_SUPPLIES_FILLED, NO_WITHDRAWALS_FILLED, 1);
    assert_eq!(book.supply_requests_pending(), 0);
    assert_eq!(book.total_supply(), near_max_total_supply);
    assert_eq!(ledger.idle_balance(), 0);

    finish(scenario, book, ledger);
}

#[test]
fun non_executable_supply_refunds_spend_supply_budget() {
    let (mut scenario, mut book, mut ledger) = setup();
    book.mint_locked_liquidity(plp_unit!());
    let mut i = 0u64;
    while (i < 3) {
        let payment = coin::mint_for_testing<DUSDC>(min_supply!(), scenario.ctx());
        book.request_supply(payment, alice_id(), ALICE, NO_MIN_OUTPUT);
        i = i + 1;
    };

    let summary = book.drain(
        &mut ledger,
        lp_book::new_flush_mark(min_plp_price!() - 1, plp_unit!()),
        vault_id(),
        option::some(2),
        option::none(),
        scenario.ctx(),
    );

    assert_drain_summary(&summary, NO_SUPPLIES_FILLED, NO_WITHDRAWALS_FILLED, 2);
    assert_eq!(book.supply_requests_pending(), 1);
    assert_eq!(book.total_supply(), plp_unit!());
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
    let lp = coin::mint_for_testing<LP_BOOK_TESTS>(amount, scenario.ctx());
    book.request_withdraw(lp, alice_id(), ALICE, min_output)
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
