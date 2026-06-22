// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Unit coverage for the pool accounting ledger: the profit basis (debits =
/// cash sent + materialized profit, credits = cash received), the terminal
/// loss-carryforward in `materialize_expiry_profit`, active-set deactivation, and
/// the terminal-accounting funding guard. Expected values are hand-derived from
/// the documented accounting, independent of the implementation (unit-tests rule
/// 1): each cash flow is tracked by hand and the materialized profit asserted
/// exactly.
#[test_only]
module deepbook_predict::pool_accounting_tests;

use deepbook_predict::pool_accounting;
use dusdc::dusdc::DUSDC;
use std::unit_test::{assert_eq, destroy};
use sui::balance;

const EXPIRY_A: address = @0xA;
const EXPIRY_B: address = @0xB;
const MAX_EXPIRY_ALLOCATION: u64 = 1000;
const POST_TERMINAL_FUNDING_AMOUNT: u64 = 100;
const FEE_INCENTIVE_CAP: u64 = 100;
const FIRST_FEE_INCENTIVE_ALLOCATION: u64 = 40;
const OVER_CAP_FEE_INCENTIVE_REQUEST: u64 = 80;

#[test]
fun send_and_receive_track_profit_basis() {
    let ctx = &mut tx_context::dummy();
    let mut ledger = pool_accounting::new(ctx);
    let id = object::id_from_address(EXPIRY_A);
    ledger.register_expiry(id, MAX_EXPIRY_ALLOCATION);

    // Fund 700 into the expiry: debits += 700, idle 1000 -> 300.
    ledger.receive_idle(balance::create_for_testing<DUSDC>(1000));
    destroy(ledger.send_expiry_cash(id, 700));
    assert_eq!(ledger.profit_basis_debits(), 700);
    assert_eq!(ledger.profit_basis_credits(), 0);
    assert_eq!(ledger.idle_balance(), 300);

    // Expiry returns 250: credits += 250, idle 300 -> 550.
    ledger.receive_expiry_cash(id, balance::create_for_testing<DUSDC>(250));
    assert_eq!(ledger.profit_basis_credits(), 250);
    assert_eq!(ledger.idle_balance(), 550);

    // Flow amounts mirror the two moves.
    let (sent, received) = ledger.expiry_flow_amounts(id);
    assert_eq!(sent, 700);
    assert_eq!(received, 250);

    destroy(ledger);
}

#[test]
fun fee_incentives_allocate_up_to_lifetime_cap() {
    let ctx = &mut tx_context::dummy();
    let mut ledger = pool_accounting::new(ctx);
    let id = object::id_from_address(EXPIRY_A);
    ledger.register_expiry(id, MAX_EXPIRY_ALLOCATION);

    let (allocated, allocated_after) = ledger.record_fee_incentives_allocated_up_to(
        id,
        FEE_INCENTIVE_CAP,
        FIRST_FEE_INCENTIVE_ALLOCATION,
    );
    assert_eq!(allocated, FIRST_FEE_INCENTIVE_ALLOCATION);
    assert_eq!(allocated_after, FIRST_FEE_INCENTIVE_ALLOCATION);

    let (allocated, allocated_after) = ledger.record_fee_incentives_allocated_up_to(
        id,
        FEE_INCENTIVE_CAP,
        OVER_CAP_FEE_INCENTIVE_REQUEST,
    );
    assert_eq!(allocated, FEE_INCENTIVE_CAP - FIRST_FEE_INCENTIVE_ALLOCATION);
    assert_eq!(allocated_after, FEE_INCENTIVE_CAP);

    let (allocated, allocated_after) = ledger.record_fee_incentives_allocated_up_to(
        id,
        FEE_INCENTIVE_CAP,
        FIRST_FEE_INCENTIVE_ALLOCATION,
    );
    assert_eq!(allocated, 0);
    assert_eq!(allocated_after, FEE_INCENTIVE_CAP);

    destroy(ledger);
}

#[test]
fun materialize_carries_loss_forward_before_recognizing_profit() {
    let ctx = &mut tx_context::dummy();
    let mut ledger = pool_accounting::new(ctx);
    let id = object::id_from_address(EXPIRY_A);
    ledger.register_expiry(id, MAX_EXPIRY_ALLOCATION);

    // Sent 1000, then the expiry returns only 600 (a 400 terminal loss).
    ledger.receive_idle(balance::create_for_testing<DUSDC>(1000));
    destroy(ledger.send_expiry_cash(id, MAX_EXPIRY_ALLOCATION));
    ledger.receive_expiry_cash(id, balance::create_for_testing<DUSDC>(600));

    // First materialize latches the 400 loss; recognizes 0 profit, debits unchanged.
    assert_eq!(ledger.materialize_expiry_profit(id), 0);
    assert_eq!(ledger.profit_basis_debits(), 1000);

    // A later 300 gain (received 900) only refills the loss carry 400 -> 100.
    ledger.receive_expiry_cash(id, balance::create_for_testing<DUSDC>(300));
    assert_eq!(ledger.materialize_expiry_profit(id), 0);
    assert_eq!(ledger.profit_basis_debits(), 1000);

    // A further 200 gain (received 1100) clears the last 100 loss and recognizes
    // 100 profit, which lands in the debit basis.
    ledger.receive_expiry_cash(id, balance::create_for_testing<DUSDC>(200));
    assert_eq!(ledger.materialize_expiry_profit(id), 100);
    assert_eq!(ledger.profit_basis_debits(), 1100);

    destroy(ledger);
}

#[test]
fun materialize_recognizes_immediate_profit_with_no_funding() {
    let ctx = &mut tx_context::dummy();
    let mut ledger = pool_accounting::new(ctx);
    let id = object::id_from_address(EXPIRY_A);
    ledger.register_expiry(id, MAX_EXPIRY_ALLOCATION);

    // No cash sent (sent 0); the expiry returns 500 of pure profit.
    ledger.receive_expiry_cash(id, balance::create_for_testing<DUSDC>(500));
    assert_eq!(ledger.materialize_expiry_profit(id), 500);
    assert_eq!(ledger.profit_basis_debits(), 500);

    // A second materialize with no new cash is a no-op.
    assert_eq!(ledger.materialize_expiry_profit(id), 0);
    assert_eq!(ledger.profit_basis_debits(), 500);

    destroy(ledger);
}

#[test]
fun deactivate_removes_from_active_set_and_reports_presence() {
    let ctx = &mut tx_context::dummy();
    let mut ledger = pool_accounting::new(ctx);
    let id_a = object::id_from_address(EXPIRY_A);
    let id_b = object::id_from_address(EXPIRY_B);
    ledger.register_expiry(id_a, MAX_EXPIRY_ALLOCATION);
    ledger.register_expiry(id_b, MAX_EXPIRY_ALLOCATION);
    assert_eq!(ledger.active_expiry_markets().length(), 2);

    assert!(ledger.deactivate_expiry_if_present(id_a));
    assert_eq!(ledger.active_expiry_markets().length(), 1);
    assert!(ledger.active_expiry_markets().contains(&id_b));

    // Second deactivation of the same expiry is a reported no-op.
    assert!(!ledger.deactivate_expiry_if_present(id_a));
    assert_eq!(ledger.active_expiry_markets().length(), 1);

    destroy(ledger);
}

#[test, expected_failure(abort_code = pool_accounting::ETerminalAccountingStarted)]
fun funding_after_terminal_accounting_started_aborts() {
    let ctx = &mut tx_context::dummy();
    let mut ledger = pool_accounting::new(ctx);
    let id = object::id_from_address(EXPIRY_A);
    ledger.register_expiry(id, MAX_EXPIRY_ALLOCATION);
    ledger.receive_idle(balance::create_for_testing<DUSDC>(1000));

    // Latch terminal accounting, then attempt to fund the expiry again.
    ledger.materialize_expiry_profit(id);
    destroy(ledger.send_expiry_cash(id, POST_TERMINAL_FUNDING_AMOUNT));

    abort 999
}

#[test, expected_failure(abort_code = pool_accounting::ETerminalAccountingStarted)]
fun fee_incentive_allocation_after_terminal_accounting_started_aborts() {
    let ctx = &mut tx_context::dummy();
    let mut ledger = pool_accounting::new(ctx);
    let id = object::id_from_address(EXPIRY_A);
    ledger.register_expiry(id, MAX_EXPIRY_ALLOCATION);

    ledger.materialize_expiry_profit(id);
    ledger.record_fee_incentives_allocated_up_to(
        id,
        FEE_INCENTIVE_CAP,
        FIRST_FEE_INCENTIVE_ALLOCATION,
    );

    abort 999
}
