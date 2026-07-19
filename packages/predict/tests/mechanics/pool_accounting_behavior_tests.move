// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Local registration, active-set, and zero-flow ledger behavior.
#[test_only]
module deepbook_predict::scope_mechanics__intent_behavior__pool_accounting_tests;

use deepbook_predict::pool_accounting;
use dusdc::dusdc::DUSDC;
use std::unit_test::{assert_eq, destroy};
use sui::balance;

const EXPIRY_A: address = @0xA;
const EXPIRY_B: address = @0xB;
const EXPIRY_A_MS: u64 = 1_000;
const EXPIRY_B_MS: u64 = 2_000;
const BEFORE_ALL_EXPIRIES_MS: u64 = 999;
const AT_EXPIRY_A_MS: u64 = 1_000;
const BETWEEN_EXPIRIES_MS: u64 = 1_500;
const AT_EXPIRY_B_MS: u64 = 2_000;
const MAX_EXPIRY_ALLOCATION: u64 = 1_000;
const INITIAL_EXPIRY_CASH: u64 = 100;
const ZERO_AMOUNT: u64 = 0;
const ONE_ACTIVE: u64 = 1;
const TWO_ACTIVE: u64 = 2;

#[test]
fun registration_projects_supplied_terms_and_active_identity() {
    let ctx = &mut tx_context::dummy();
    let mut ledger = pool_accounting::new(ctx);
    let expiry_id = object::id_from_address(EXPIRY_A);

    ledger.register_expiry(
        expiry_id,
        EXPIRY_A_MS,
        MAX_EXPIRY_ALLOCATION,
        INITIAL_EXPIRY_CASH,
    );

    let active = ledger.active_expiry_markets();
    assert_eq!(active.length(), ONE_ACTIVE);
    assert_eq!(active[ZERO_AMOUNT], expiry_id);
    assert_eq!(ledger.max_expiry_allocation(expiry_id), MAX_EXPIRY_ALLOCATION);
    assert_eq!(ledger.initial_expiry_cash(expiry_id), INITIAL_EXPIRY_CASH);
    assert_eq!(ledger.available_expiry_funding(expiry_id), MAX_EXPIRY_ALLOCATION);
    assert_eq!(ledger.idle_balance(), ZERO_AMOUNT);
    assert_eq!(ledger.profit_basis_debits(), ZERO_AMOUNT);
    assert_eq!(ledger.profit_basis_credits(), ZERO_AMOUNT);
    assert_eq!(ledger.pending_protocol_profit(), ZERO_AMOUNT);
    destroy(ledger);
}

#[test]
fun live_count_uses_strict_future_and_deactivation_is_idempotent() {
    let ctx = &mut tx_context::dummy();
    let mut ledger = pool_accounting::new(ctx);
    let expiry_a = object::id_from_address(EXPIRY_A);
    let expiry_b = object::id_from_address(EXPIRY_B);
    ledger.register_expiry(
        expiry_a,
        EXPIRY_A_MS,
        MAX_EXPIRY_ALLOCATION,
        INITIAL_EXPIRY_CASH,
    );
    ledger.register_expiry(
        expiry_b,
        EXPIRY_B_MS,
        MAX_EXPIRY_ALLOCATION,
        INITIAL_EXPIRY_CASH,
    );

    assert_eq!(ledger.active_live_expiry_count(BEFORE_ALL_EXPIRIES_MS), TWO_ACTIVE);
    assert_eq!(ledger.active_live_expiry_count(AT_EXPIRY_A_MS), ONE_ACTIVE);
    assert_eq!(ledger.active_live_expiry_count(BETWEEN_EXPIRIES_MS), ONE_ACTIVE);
    assert_eq!(ledger.active_live_expiry_count(AT_EXPIRY_B_MS), ZERO_AMOUNT);
    assert!(ledger.deactivate_expiry_if_present(expiry_a));
    assert!(!ledger.deactivate_expiry_if_present(expiry_a));
    let active = ledger.active_expiry_markets();
    assert_eq!(active.length(), ONE_ACTIVE);
    assert_eq!(active[ZERO_AMOUNT], expiry_b);
    destroy(ledger);
}

#[test]
fun zero_cash_moves_are_identity_operations() {
    let ctx = &mut tx_context::dummy();
    let mut ledger = pool_accounting::new(ctx);
    let unknown_id = object::id_from_address(EXPIRY_A);

    let sent = ledger.send_expiry_cash(unknown_id, ZERO_AMOUNT);
    assert_eq!(sent.value(), ZERO_AMOUNT);
    assert_eq!(ledger.receive_expiry_cash(balance::zero<DUSDC>(), unknown_id), ZERO_AMOUNT);
    assert_eq!(ledger.idle_balance(), ZERO_AMOUNT);
    assert_eq!(ledger.profit_basis_debits(), ZERO_AMOUNT);
    assert_eq!(ledger.profit_basis_credits(), ZERO_AMOUNT);
    destroy(sent);
    destroy(ledger);
}
