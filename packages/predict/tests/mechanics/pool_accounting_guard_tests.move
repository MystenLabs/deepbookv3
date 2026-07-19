// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Registration, funding-cap, and terminal-state ledger guards.
#[test_only]
module deepbook_predict::scope_mechanics__intent_guard__pool_accounting_tests;

use deepbook_predict::pool_accounting;
use dusdc::dusdc::DUSDC;
use std::unit_test::destroy;
use sui::balance;

const EXPIRY: address = @0xA;
const EXPIRY_MS: u64 = 1_000;
const MAX_EXPIRY_ALLOCATION: u64 = 1_000;
const INITIAL_EXPIRY_CASH: u64 = 100;
const FIRST_FUNDING: u64 = 700;
const OVER_CAP_FUNDING: u64 = 301;
const POST_TERMINAL_AMOUNT: u64 = 100;
const FEE_INCENTIVE_CAP: u64 = 100;
const FEE_INCENTIVE_REQUEST: u64 = 40;

#[test, expected_failure(abort_code = pool_accounting::ERegisteredExpiryAlreadyExists)]
fun duplicate_registration_aborts() {
    let ctx = &mut tx_context::dummy();
    let mut ledger = pool_accounting::new(ctx);
    let expiry_id = object::id_from_address(EXPIRY);
    ledger.register_expiry(
        expiry_id,
        EXPIRY_MS,
        MAX_EXPIRY_ALLOCATION,
        INITIAL_EXPIRY_CASH,
    );
    ledger.register_expiry(
        expiry_id,
        EXPIRY_MS,
        MAX_EXPIRY_ALLOCATION,
        INITIAL_EXPIRY_CASH,
    );
    abort 999
}

#[test, expected_failure(abort_code = pool_accounting::EUnknownRegisteredExpiry)]
fun unregistered_expiry_read_aborts() {
    let ctx = &mut tx_context::dummy();
    let ledger = pool_accounting::new(ctx);
    ledger.available_expiry_funding(object::id_from_address(EXPIRY));
    abort 999
}

#[test, expected_failure(abort_code = pool_accounting::EMaxExpiryFundingExceeded)]
fun funding_one_above_allocation_cap_aborts() {
    let ctx = &mut tx_context::dummy();
    let mut ledger = pool_accounting::new(ctx);
    let expiry_id = object::id_from_address(EXPIRY);
    ledger.register_expiry(
        expiry_id,
        EXPIRY_MS,
        MAX_EXPIRY_ALLOCATION,
        INITIAL_EXPIRY_CASH,
    );
    ledger.receive_idle(
        balance::create_for_testing<DUSDC>(FIRST_FUNDING + OVER_CAP_FUNDING),
    );
    destroy(ledger.send_expiry_cash(expiry_id, FIRST_FUNDING));
    destroy(ledger.send_expiry_cash(expiry_id, OVER_CAP_FUNDING));
    abort 999
}

#[test, expected_failure(abort_code = pool_accounting::ETerminalAccountingStarted)]
fun funding_after_terminal_accounting_aborts() {
    let ctx = &mut tx_context::dummy();
    let mut ledger = pool_accounting::new(ctx);
    let expiry_id = object::id_from_address(EXPIRY);
    ledger.register_expiry(
        expiry_id,
        EXPIRY_MS,
        MAX_EXPIRY_ALLOCATION,
        INITIAL_EXPIRY_CASH,
    );
    ledger.receive_idle(balance::create_for_testing<DUSDC>(POST_TERMINAL_AMOUNT));
    ledger.materialize_expiry_profit(expiry_id);
    destroy(ledger.send_expiry_cash(expiry_id, POST_TERMINAL_AMOUNT));
    abort 999
}

#[test, expected_failure(abort_code = pool_accounting::ETerminalAccountingStarted)]
fun fee_incentives_after_terminal_accounting_abort() {
    let ctx = &mut tx_context::dummy();
    let mut ledger = pool_accounting::new(ctx);
    let expiry_id = object::id_from_address(EXPIRY);
    ledger.register_expiry(
        expiry_id,
        EXPIRY_MS,
        MAX_EXPIRY_ALLOCATION,
        INITIAL_EXPIRY_CASH,
    );
    ledger.materialize_expiry_profit(expiry_id);
    ledger.record_fee_incentives_allocated_up_to(
        expiry_id,
        FEE_INCENTIVE_CAP,
        FEE_INCENTIVE_REQUEST,
    );
    abort 999
}
