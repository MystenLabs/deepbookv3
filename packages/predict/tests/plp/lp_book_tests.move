// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Root-free coverage for `lp_book`, the queue + drain primitive below the `plp`
/// wrapper. Because the vault-level `plp` request/cancel entrypoints auto-settle from
/// a `sui::accumulator::AccumulatorRoot` that a unit test cannot construct, the flush
/// DRAIN economics (proportional supply/withdraw at a frozen mark, FIFO-until-idle-dry,
/// independent per-queue budgets with carry-over, cancelled requests not spending a
/// budget) and the manager-routed cancel refund + recipient check are exercised HERE
/// against a standalone `LpBook` + `Ledger`, where `request_supply`/`request_withdraw`
/// take a coin directly and `drain` takes the frozen `(pool_value, total_supply)` mark
/// as parameters. Every expected share/payout is hand-computed independently of the
/// contract. The `PredictWithdrawCap` authorization that the `plp` wrapper adds on top
/// lives in the untested outer (root-taking) layer.
#[test_only]
module deepbook_predict::lp_book_tests;

use deepbook_predict::{
    constants::{min_supply_request as min_supply, min_withdraw_request as min_withdraw},
    flow_test_helpers as helpers,
    lp_book::{Self, LpBook},
    pool_accounting::{Self, Ledger},
    predict_manager::PredictManager
};
use dusdc::dusdc::DUSDC;
use std::unit_test::{assert_eq, destroy};
use sui::{balance, coin, coin_registry};

public struct LP_BOOK_TESTS has drop {}

const BOB: address = @0xB0B;

// === Permanent minimum-liquidity mint ===

#[test]
fun mint_locked_liquidity_increments_total_supply() {
    let (fx, manager, mut book, ledger) = setup();
    book.mint_locked_liquidity(min_supply!());
    // The permanent minimum-liquidity mint raises treasury supply; it is held by the book
    // with no withdraw path, so total_supply stays >= this floor for the pool's life.
    assert_eq!(book.total_supply(), min_supply!());

    destroy(ledger);
    destroy(book);
    destroy(manager);
    fx.finish();
}

// === Priced supply / withdraw at a frozen mark ===

#[test]
fun supply_drain_mints_at_mark_and_joins_idle() {
    let (mut fx, manager, mut book, mut ledger) = setup();
    let vault_id = fx.vault_id();
    // Genesis lock seeds total_supply at a 1.0 mark (pool_value == total_supply).
    book.mint_locked_liquidity(min_supply!());
    let payment = coin::mint_for_testing<DUSDC>(min_supply!(), fx.scenario_mut().ctx());
    let index = book.request_supply(vault_id, &manager, payment);
    assert_eq!(index, 0);
    assert_eq!(book.supply_requests_pending(), 1);

    // Drain at pool_value == total_supply == L (mark 1.0): the supply mints 1:1.
    let (supplies_filled, withdrawals_filled) = book.drain(
        vault_id,
        &mut ledger,
        min_supply!(),
        min_supply!(),
        option::none(),
        option::none(),
        fx.scenario_mut().ctx(),
    );

    assert_eq!(supplies_filled, 1);
    assert_eq!(withdrawals_filled, 0);
    assert_eq!(book.supply_requests_pending(), 0);
    assert_eq!(book.total_supply(), 2 * min_supply!()); // locked L + minted L
    assert_eq!(ledger.idle_balance(), min_supply!()); // the supply escrow joined idle

    destroy(ledger);
    destroy(book);
    destroy(manager);
    fx.finish();
}

#[test]
fun priced_supply_mints_proportional_shares() {
    let (mut fx, manager, mut book, mut ledger) = setup();
    let vault_id = fx.vault_id();
    // total_supply 30e6, pool_value 60e6 -> mark 2.0.
    book.mint_locked_liquidity(30_000_000);
    let supply = 20_000_000;
    let payment = coin::mint_for_testing<DUSDC>(supply, fx.scenario_mut().ctx());
    book.request_supply(vault_id, &manager, payment);

    // shares = 20e6 * 30e6 / 60e6 = 10e6.
    book.drain(
        vault_id,
        &mut ledger,
        60_000_000,
        30_000_000,
        option::none(),
        option::none(),
        fx.scenario_mut().ctx(),
    );

    assert_eq!(book.total_supply(), 40_000_000); // 30e6 + 10e6 minted
    assert_eq!(ledger.idle_balance(), 20_000_000); // the 20e6 escrow joined idle
    assert_eq!(book.supply_requests_pending(), 0);

    destroy(ledger);
    destroy(book);
    destroy(manager);
    fx.finish();
}

#[test]
fun priced_withdraw_burns_and_pays_from_idle() {
    let (mut fx, manager, mut book, mut ledger) = setup();
    let vault_id = fx.vault_id();
    // total_supply 30e6, idle 60e6 -> mark 2.0.
    book.mint_locked_liquidity(30_000_000);
    seed_idle(&mut ledger, 60_000_000);
    let withdraw = 10_000_000;
    enqueue_withdraw(&mut fx, &mut book, vault_id, &manager, withdraw);

    // dusdc = 10e6 * 60e6 / 30e6 = 20e6.
    book.drain(
        vault_id,
        &mut ledger,
        60_000_000,
        30_000_000,
        option::none(),
        option::none(),
        fx.scenario_mut().ctx(),
    );

    assert_eq!(book.total_supply(), 20_000_000); // 30e6 - 10e6 burned
    assert_eq!(ledger.idle_balance(), 40_000_000); // 60e6 - 20e6 paid out
    assert_eq!(book.withdraw_requests_pending(), 0);

    destroy(ledger);
    destroy(book);
    destroy(manager);
    fx.finish();
}

#[test]
fun two_withdrawals_share_one_frozen_mark() {
    let (mut fx, manager, mut book, mut ledger) = setup();
    let vault_id = fx.vault_id();
    // total_supply 30e6, idle 50e6 -> mark 5/3 (a fraction that rounds).
    book.mint_locked_liquidity(30_000_000);
    seed_idle(&mut ledger, 50_000_000);
    enqueue_withdraw(&mut fx, &mut book, vault_id, &manager, 10_000_000);
    enqueue_withdraw(&mut fx, &mut book, vault_id, &manager, 10_000_000);

    // Each prices at the FROZEN (50e6, 30e6) mark: floor(10e6 * 50e6 / 30e6) = 16_666_666.
    // If the second repriced post-first it would round to 16_666_667.
    book.drain(
        vault_id,
        &mut ledger,
        50_000_000,
        30_000_000,
        option::none(),
        option::none(),
        fx.scenario_mut().ctx(),
    );

    assert_eq!(ledger.idle_balance(), 16_666_668); // 50e6 - 2 * 16_666_666 (frozen); repriced would leave 16_666_667
    assert_eq!(book.total_supply(), 10_000_000); // 30e6 - 2 * 10e6 burned
    assert_eq!(book.withdraw_requests_pending(), 0);

    destroy(ledger);
    destroy(book);
    destroy(manager);
    fx.finish();
}

// === FIFO-until-idle-dry ===

#[test]
fun withdrawals_stop_when_idle_is_dry_and_carry() {
    let (mut fx, manager, mut book, mut ledger) = setup();
    let vault_id = fx.vault_id();
    // total_supply 30e6, idle 30e6 -> mark 1.0.
    book.mint_locked_liquidity(30_000_000);
    seed_idle(&mut ledger, 30_000_000);
    // Two 20e6 withdrawals: first fills (idle 30e6 -> 10e6); second needs 20e6 but idle
    // is only 10e6, so the pass stops and carries it.
    enqueue_withdraw(&mut fx, &mut book, vault_id, &manager, 20_000_000);
    enqueue_withdraw(&mut fx, &mut book, vault_id, &manager, 20_000_000);

    let (_s, withdrawals_filled) = book.drain(
        vault_id,
        &mut ledger,
        30_000_000,
        30_000_000,
        option::none(),
        option::none(),
        fx.scenario_mut().ctx(),
    );

    assert_eq!(withdrawals_filled, 1); // only the first
    assert_eq!(book.total_supply(), 10_000_000); // only the first 20e6 burned
    assert_eq!(ledger.idle_balance(), 10_000_000); // only the first 20e6 paid
    assert_eq!(book.withdraw_requests_pending(), 1); // second carried

    destroy(ledger);
    destroy(book);
    destroy(manager);
    fx.finish();
}

// === Per-queue budgets and carry-over ===

#[test]
fun unbounded_flush_drains_every_queued_supply() {
    let (mut fx, manager, mut book, mut ledger) = setup();
    let vault_id = fx.vault_id();
    book.mint_locked_liquidity(min_supply!());
    // 101 supplies at the 1.0 mark -> all mint 1:1, past the old shared 100-request cap.
    let total = 101u64;
    let mut i = 0;
    while (i < total) {
        let coin = coin::mint_for_testing<DUSDC>(min_supply!(), fx.scenario_mut().ctx());
        book.request_supply(vault_id, &manager, coin);
        i = i + 1;
    };

    let (supplies_filled, _w) = book.drain(
        vault_id,
        &mut ledger,
        min_supply!(),
        min_supply!(),
        option::none(),
        option::none(),
        fx.scenario_mut().ctx(),
    );

    assert_eq!(supplies_filled, total);
    assert_eq!(book.total_supply(), (total + 1) * min_supply!()); // locked + 101 minted
    assert_eq!(ledger.idle_balance(), total * min_supply!());
    assert_eq!(book.supply_requests_pending(), 0);

    destroy(ledger);
    destroy(book);
    destroy(manager);
    fx.finish();
}

#[test]
fun bounded_supply_budget_fills_up_to_budget_and_carries() {
    let (mut fx, manager, mut book, mut ledger) = setup();
    let vault_id = fx.vault_id();
    book.mint_locked_liquidity(min_supply!());
    // Three supplies at the 1.0 mark; a supply_budget of 2 fills two and carries the third.
    let mut i = 0u64;
    while (i < 3) {
        let coin = coin::mint_for_testing<DUSDC>(min_supply!(), fx.scenario_mut().ctx());
        book.request_supply(vault_id, &manager, coin);
        i = i + 1;
    };

    let (filled, _w) = book.drain(
        vault_id,
        &mut ledger,
        min_supply!(),
        min_supply!(),
        option::some(2),
        option::none(),
        fx.scenario_mut().ctx(),
    );

    assert_eq!(filled, 2);
    assert_eq!(book.total_supply(), 3 * min_supply!()); // locked + 2 filled
    assert_eq!(book.supply_requests_pending(), 1); // third carried

    // The carried supply fills on the next unbounded drain.
    book.drain(
        vault_id,
        &mut ledger,
        2 * min_supply!(),
        3 * min_supply!(),
        option::none(),
        option::none(),
        fx.scenario_mut().ctx(),
    );
    assert_eq!(book.supply_requests_pending(), 0);

    destroy(ledger);
    destroy(book);
    destroy(manager);
    fx.finish();
}

#[test]
fun independent_budgets_let_withdrawals_drain_under_supply_pressure() {
    let (mut fx, manager, mut book, mut ledger) = setup();
    let vault_id = fx.vault_id();
    // total_supply 30e6, idle 30e6 -> mark 1.0.
    book.mint_locked_liquidity(30_000_000);
    seed_idle(&mut ledger, 30_000_000);
    // Three supplies queued ahead of one withdrawal. Independent budgets of 1 each fill
    // exactly one of each, so the withdrawal drains despite the supply backlog.
    let mut i = 0;
    while (i < 3) {
        let coin = coin::mint_for_testing<DUSDC>(min_supply!(), fx.scenario_mut().ctx());
        book.request_supply(vault_id, &manager, coin);
        i = i + 1;
    };
    enqueue_withdraw(&mut fx, &mut book, vault_id, &manager, 10_000_000);

    let (supplies_filled, withdrawals_filled) = book.drain(
        vault_id,
        &mut ledger,
        30_000_000,
        30_000_000,
        option::some(1),
        option::some(1),
        fx.scenario_mut().ctx(),
    );

    assert_eq!(supplies_filled, 1);
    assert_eq!(withdrawals_filled, 1); // withdrawal NOT starved
    assert_eq!(book.supply_requests_pending(), 2); // supply budget bounded to 1
    assert_eq!(book.withdraw_requests_pending(), 0);
    // +10e6 supplied (min_supply), +min_supply minted; -10e6 burned, -10e6 paid.
    assert_eq!(book.total_supply(), 30_000_000 + min_supply!() - 10_000_000);
    assert_eq!(ledger.idle_balance(), 30_000_000 + min_supply!() - 10_000_000);

    destroy(ledger);
    destroy(book);
    destroy(manager);
    fx.finish();
}

// === Cancellation refunds into the requesting manager ===

#[test]
fun cancel_supply_refunds_dusdc_into_manager() {
    let (mut fx, mut manager, mut book, ledger) = setup();
    let vault_id = fx.vault_id();
    let coin = coin::mint_for_testing<DUSDC>(min_supply!(), fx.scenario_mut().ctx());
    let index = book.request_supply(vault_id, &manager, coin);

    book.cancel_supply_request(vault_id, &mut manager, index, fx.scenario_mut().ctx());

    // Escrow returned straight to the manager's internal DUSDC custody.
    assert_eq!(manager.internal_balance<DUSDC>(), min_supply!());
    assert_eq!(book.supply_requests_pending(), 0);

    destroy(ledger);
    destroy(book);
    destroy(manager);
    fx.finish();
}

#[test]
fun cancel_withdraw_refunds_plp_into_manager() {
    let (mut fx, mut manager, mut book, ledger) = setup();
    let vault_id = fx.vault_id();
    let index = enqueue_withdraw(&mut fx, &mut book, vault_id, &manager, min_withdraw!());

    book.cancel_withdraw_request(vault_id, &mut manager, index, fx.scenario_mut().ctx());

    assert_eq!(manager.internal_balance<LP_BOOK_TESTS>(), min_withdraw!());
    assert_eq!(book.withdraw_requests_pending(), 0);

    destroy(ledger);
    destroy(book);
    destroy(manager);
    fx.finish();
}

#[test]
fun cancelled_supply_requests_do_not_spend_drain_budget() {
    let (mut fx, mut manager, mut book, mut ledger) = setup();
    let vault_id = fx.vault_id();
    book.mint_locked_liquidity(min_supply!());

    let cancelled = 5;
    let mut i = 0;
    while (i < cancelled) {
        let coin = coin::mint_for_testing<DUSDC>(min_supply!(), fx.scenario_mut().ctx());
        let index = book.request_supply(vault_id, &manager, coin);
        book.cancel_supply_request(vault_id, &mut manager, index, fx.scenario_mut().ctx());
        i = i + 1;
    };
    let coin = coin::mint_for_testing<DUSDC>(min_supply!(), fx.scenario_mut().ctx());
    let live_index = book.request_supply(vault_id, &manager, coin);
    assert_eq!(live_index, cancelled); // monotonic index, past the cancelled ones
    assert_eq!(book.supply_requests_pending(), 1);
    assert_eq!(manager.internal_balance<DUSDC>(), cancelled * min_supply!());

    // A supply_budget of 1 fills the single live request: the cancelled ones were
    // physically removed and never counted against the budget.
    let (filled, _w) = book.drain(
        vault_id,
        &mut ledger,
        min_supply!(),
        min_supply!(),
        option::some(1),
        option::none(),
        fx.scenario_mut().ctx(),
    );
    assert_eq!(filled, 1);
    assert_eq!(book.total_supply(), 2 * min_supply!()); // locked + 1 live filled
    assert_eq!(book.supply_requests_pending(), 0);

    destroy(ledger);
    destroy(book);
    destroy(manager);
    fx.finish();
}

// === Request lookup / recipient / mark / minimum aborts ===

#[test, expected_failure(abort_code = lp_book::ERequestNotFound)]
fun cancel_unknown_supply_request_aborts() {
    let (mut fx, mut manager, mut book, _ledger) = setup();
    let vault_id = fx.vault_id();
    book.cancel_supply_request(vault_id, &mut manager, 0, fx.scenario_mut().ctx());

    abort 999
}

#[test, expected_failure(abort_code = lp_book::ENotRequestOwner)]
fun cancel_with_non_recipient_manager_aborts() {
    let (mut fx, manager_a, mut book, _ledger) = setup();
    let vault_id = fx.vault_id();
    let mut manager_b = fx.create_funded_manager_as(BOB, 0);
    // Alice's manager owns the request...
    let coin = coin::mint_for_testing<DUSDC>(min_supply!(), fx.scenario_mut().ctx());
    let index = book.request_supply(vault_id, &manager_a, coin);

    // ...so Bob's manager (a different recipient) cannot cancel it.
    book.cancel_supply_request(vault_id, &mut manager_b, index, fx.scenario_mut().ctx());
    abort 999
}

#[test, expected_failure(abort_code = lp_book::EInvalidDrainMark)]
fun priced_supply_with_zero_pool_value_aborts() {
    let (mut fx, manager, mut book, mut ledger) = setup();
    let vault_id = fx.vault_id();
    let payment = coin::mint_for_testing<DUSDC>(min_supply!(), fx.scenario_mut().ctx());
    book.request_supply(vault_id, &manager, payment);

    let (_supplies, _withdrawals) = book.drain(
        vault_id,
        &mut ledger,
        0,
        min_supply!(),
        option::none(),
        option::none(),
        fx.scenario_mut().ctx(),
    );

    abort 999
}

#[test, expected_failure(abort_code = lp_book::EBelowMinSupplyRequest)]
fun request_supply_below_min_aborts() {
    let (mut fx, manager, mut book, _ledger) = setup();
    let vault_id = fx.vault_id();
    let coin = coin::mint_for_testing<DUSDC>(min_supply!() - 1, fx.scenario_mut().ctx());
    book.request_supply(vault_id, &manager, coin);

    abort 999
}

#[test, expected_failure(abort_code = lp_book::EBelowMinWithdrawRequest)]
fun request_withdraw_below_min_aborts() {
    let (mut fx, manager, mut book, _ledger) = setup();
    let vault_id = fx.vault_id();
    let lp = coin::mint_for_testing<LP_BOOK_TESTS>(min_withdraw!() - 1, fx.scenario_mut().ctx());
    book.request_withdraw(vault_id, &manager, lp);

    abort 999
}

// === Helpers ===

fun setup(): (helpers::Fixture, PredictManager, LpBook<LP_BOOK_TESTS>, Ledger) {
    let mut fx = helpers::setup_market_default();
    let manager = fx.create_funded_manager(0);
    let (book, ledger) = new_book(fx.scenario_mut().ctx());
    (fx, manager, book, ledger)
}

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
/// accumulator-delivered shares. `mint_locked_liquidity` must have set `total_supply`
/// high enough that the drain burn never underflows.
fun enqueue_withdraw(
    fx: &mut helpers::Fixture,
    book: &mut LpBook<LP_BOOK_TESTS>,
    vault_id: ID,
    manager: &PredictManager,
    amount: u64,
): u64 {
    let lp = coin::mint_for_testing<LP_BOOK_TESTS>(amount, fx.scenario_mut().ctx());
    book.request_withdraw(vault_id, manager, lp)
}
