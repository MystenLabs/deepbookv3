// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Focused coverage for `lp_book` behavior below the `plp` wrapper: request lookup
/// aborts, invalid frozen marks, the permanent minimum-liquidity mint, and a
/// successful priced drain. Queue storage internals stay private; end-to-end
/// cancellation/cap behavior lives in `lp_flow_tests`.
#[test_only]
module deepbook_predict::lp_book_tests;

use deepbook_predict::{
    constants::min_supply_request as min_supply,
    flow_test_helpers as helpers,
    lp_book::{Self, LpBook},
    pool_accounting::{Self, Ledger},
    predict_manager::PredictManager
};
use dusdc::dusdc::DUSDC;
use std::unit_test::{assert_eq, destroy};
use sui::{coin, coin_registry};

public struct LP_BOOK_TESTS has drop {}

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

#[test, expected_failure(abort_code = lp_book::ERequestNotFound)]
fun cancel_unknown_supply_request_aborts() {
    let (mut fx, mut manager, mut book, _ledger) = setup();
    let vault_id = fx.vault_id();
    book.cancel_supply_request(vault_id, &mut manager, 0, fx.scenario_mut().ctx());

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
