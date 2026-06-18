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
    constants::{min_supply_request as min_supply, min_withdraw_request as min_withdraw},
    lp_book::{Self, LpBook},
    pool_accounting::{Self, Ledger}
};
use dusdc::dusdc::DUSDC;
use std::unit_test::{assert_eq, destroy};
use sui::{balance, coin, coin_registry, test_scenario::{Self as test, Scenario}};

public struct LP_BOOK_TESTS has drop {}

const ALICE: address = @0xA;
const BOB: address = @0xB0B;

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
    let index = book.request_supply(alice_id(), ALICE, payment);
    assert_eq!(index, 0);
    assert_eq!(book.supply_requests_pending(), 1);

    // Drain at pool_value == total_supply == L (mark 1.0): the supply mints 1:1.
    let (supplies_filled, withdrawals_filled) = book.drain(
        vault_id(),
        &mut ledger,
        min_supply!(),
        min_supply!(),
        option::none(),
        option::none(),
        scenario.ctx(),
    );

    assert_eq!(supplies_filled, 1);
    assert_eq!(withdrawals_filled, 0);
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
    book.request_supply(alice_id(), ALICE, payment);

    // shares = 20e6 * 30e6 / 60e6 = 10e6.
    book.drain(
        vault_id(),
        &mut ledger,
        60_000_000,
        30_000_000,
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
        vault_id(),
        &mut ledger,
        60_000_000,
        30_000_000,
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
        vault_id(),
        &mut ledger,
        50_000_000,
        30_000_000,
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

    let (_s, withdrawals_filled) = book.drain(
        vault_id(),
        &mut ledger,
        30_000_000,
        30_000_000,
        option::none(),
        option::none(),
        scenario.ctx(),
    );

    assert_eq!(withdrawals_filled, 1); // only the first
    assert_eq!(book.total_supply(), 10_000_000); // only the first 20e6 burned
    assert_eq!(ledger.idle_balance(), 10_000_000); // only the first 20e6 paid
    assert_eq!(book.withdraw_requests_pending(), 1); // second carried

    finish(scenario, book, ledger);
}

// === Per-queue budgets and carry-over ===

#[test]
fun unbounded_flush_drains_every_queued_supply() {
    let (mut scenario, mut book, mut ledger) = setup();
    book.mint_locked_liquidity(min_supply!());
    // 101 supplies at the 1.0 mark -> all mint 1:1, past the old shared 100-request cap.
    let total = 101u64;
    let mut i = 0;
    while (i < total) {
        let coin = coin::mint_for_testing<DUSDC>(min_supply!(), scenario.ctx());
        book.request_supply(alice_id(), ALICE, coin);
        i = i + 1;
    };

    let (supplies_filled, _w) = book.drain(
        vault_id(),
        &mut ledger,
        min_supply!(),
        min_supply!(),
        option::none(),
        option::none(),
        scenario.ctx(),
    );

    assert_eq!(supplies_filled, total);
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
        book.request_supply(alice_id(), ALICE, coin);
        i = i + 1;
    };

    let (filled, _w) = book.drain(
        vault_id(),
        &mut ledger,
        min_supply!(),
        min_supply!(),
        option::some(2),
        option::none(),
        scenario.ctx(),
    );

    assert_eq!(filled, 2);
    assert_eq!(book.total_supply(), 3 * min_supply!()); // locked + 2 filled
    assert_eq!(book.supply_requests_pending(), 1); // third carried

    // The carried supply fills on the next unbounded drain.
    book.drain(
        vault_id(),
        &mut ledger,
        2 * min_supply!(),
        3 * min_supply!(),
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
        book.request_supply(alice_id(), ALICE, coin);
        i = i + 1;
    };
    enqueue_withdraw(&mut scenario, &mut book, 10_000_000);

    let (supplies_filled, withdrawals_filled) = book.drain(
        vault_id(),
        &mut ledger,
        30_000_000,
        30_000_000,
        option::some(1),
        option::some(1),
        scenario.ctx(),
    );

    assert_eq!(supplies_filled, 1);
    assert_eq!(withdrawals_filled, 1); // withdrawal NOT starved
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
    let index = book.request_supply(alice_id(), ALICE, coin);

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
    let mut i = 0;
    while (i < cancelled) {
        let coin = coin::mint_for_testing<DUSDC>(min_supply!(), scenario.ctx());
        let index = book.request_supply(alice_id(), ALICE, coin);
        let (_id, _amount, refund) = book.cancel_supply_request(ALICE, index);
        refunds.join(refund);
        i = i + 1;
    };
    let coin = coin::mint_for_testing<DUSDC>(min_supply!(), scenario.ctx());
    let live_index = book.request_supply(alice_id(), ALICE, coin);
    assert_eq!(live_index, cancelled); // monotonic index, past the cancelled ones
    assert_eq!(book.supply_requests_pending(), 1);
    assert_eq!(refunds.value(), cancelled * min_supply!());

    // A supply_budget of 1 fills the single live request: the cancelled ones were
    // physically removed and never counted against the budget.
    let (filled, _w) = book.drain(
        vault_id(),
        &mut ledger,
        min_supply!(),
        min_supply!(),
        option::some(1),
        option::none(),
        scenario.ctx(),
    );
    assert_eq!(filled, 1);
    assert_eq!(book.total_supply(), 2 * min_supply!()); // locked + 1 live filled
    assert_eq!(book.supply_requests_pending(), 0);

    destroy(refunds);
    finish(scenario, book, ledger);
}

// === Request lookup / recipient / mark / minimum aborts ===

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
    let index = book.request_supply(alice_id(), ALICE, coin);

    // ...so Bob (a different recipient) cannot cancel it.
    let (_id, _amount, refund) = book.cancel_supply_request(BOB, index);
    destroy(refund);
    finish(scenario, book, ledger);
    abort 999
}

#[test, expected_failure(abort_code = lp_book::EInvalidDrainMark)]
fun priced_supply_with_zero_pool_value_aborts() {
    let (mut scenario, mut book, mut ledger) = setup();
    let payment = coin::mint_for_testing<DUSDC>(min_supply!(), scenario.ctx());
    book.request_supply(alice_id(), ALICE, payment);

    book.drain(
        vault_id(),
        &mut ledger,
        0,
        min_supply!(),
        option::none(),
        option::none(),
        scenario.ctx(),
    );

    abort 999
}

#[test, expected_failure(abort_code = lp_book::EBelowMinSupplyRequest)]
fun request_supply_below_min_aborts() {
    let (mut scenario, mut book, _ledger) = setup();
    let coin = coin::mint_for_testing<DUSDC>(min_supply!() - 1, scenario.ctx());
    book.request_supply(alice_id(), ALICE, coin);

    abort 999
}

#[test, expected_failure(abort_code = lp_book::EBelowMinWithdrawRequest)]
fun request_withdraw_below_min_aborts() {
    let (mut scenario, mut book, _ledger) = setup();
    let lp = coin::mint_for_testing<LP_BOOK_TESTS>(min_withdraw!() - 1, scenario.ctx());
    book.request_withdraw(alice_id(), ALICE, lp);

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
fun enqueue_withdraw(
    scenario: &mut Scenario,
    book: &mut LpBook<LP_BOOK_TESTS>,
    amount: u64,
): u64 {
    let lp = coin::mint_for_testing<LP_BOOK_TESTS>(amount, scenario.ctx());
    book.request_withdraw(alice_id(), ALICE, lp)
}

fun finish(scenario: Scenario, book: LpBook<LP_BOOK_TESTS>, ledger: Ledger) {
    destroy(book);
    destroy(ledger);
    scenario.end();
}
