// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Exact funding-cap boundary and returned-cash capacity reopening.
#[test_only]
module deepbook_predict::scope_mechanics__intent_boundary__pool_accounting_tests;

use deepbook_predict::pool_accounting;
use dusdc::dusdc::DUSDC;
use std::unit_test::{assert_eq, destroy};
use sui::balance;

const EXPIRY: address = @0xA;
const EXPIRY_MS: u64 = 1_000;
const MAX_EXPIRY_ALLOCATION: u64 = 1_000;
const INITIAL_EXPIRY_CASH: u64 = 100;
const RETURNED_UNIT: u64 = 1;
const ZERO_AVAILABLE: u64 = 0;

#[test]
fun exact_allocation_cap_fits_and_one_return_reopens_one_unit() {
    let ctx = &mut tx_context::dummy();
    let mut ledger = pool_accounting::new(ctx);
    let expiry_id = object::id_from_address(EXPIRY);
    ledger.register_expiry(
        expiry_id,
        EXPIRY_MS,
        MAX_EXPIRY_ALLOCATION,
        INITIAL_EXPIRY_CASH,
    );
    ledger.receive_idle(balance::create_for_testing<DUSDC>(MAX_EXPIRY_ALLOCATION));

    let funded = ledger.send_expiry_cash(expiry_id, MAX_EXPIRY_ALLOCATION);
    assert_eq!(funded.value(), MAX_EXPIRY_ALLOCATION);
    assert_eq!(ledger.available_expiry_funding(expiry_id), ZERO_AVAILABLE);
    ledger.receive_expiry_cash(balance::create_for_testing<DUSDC>(RETURNED_UNIT), expiry_id);
    let reopened = ledger.send_expiry_cash(expiry_id, RETURNED_UNIT);
    assert_eq!(reopened.value(), RETURNED_UNIT);
    assert_eq!(ledger.available_expiry_funding(expiry_id), ZERO_AVAILABLE);
    destroy(funded);
    destroy(reopened);
    destroy(ledger);
}
