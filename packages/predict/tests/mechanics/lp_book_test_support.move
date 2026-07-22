// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Subject-local construction for standalone LP-book and ledger mechanics.
#[test_only]
module deepbook_predict::lp_book_test_support;

use deepbook_predict::{
    lp_book::{Self, DrainSummary, LpBook},
    pool_accounting::{Self, Ledger},
    vault_events::{RequestCancelled, RequestLimitMissed}
};
use std::{bcs, unit_test::{assert_eq, destroy}};
use sui::{coin_registry, event};

public struct LP_BOOK_TEST_SUPPORT has drop {}

public struct ExpectedRequestCancelled has copy, drop, store {
    pool_vault_id: ID,
    account_id: ID,
    recipient: address,
    index: u64,
    amount: u64,
    is_supply: bool,
    reason: u8,
    requests_pending_after: u64,
}

public struct ExpectedRequestLimitMissed has copy, drop, store {
    pool_vault_id: ID,
    account_id: ID,
    recipient: address,
    index: u64,
    amount: u64,
    is_supply: bool,
    quoted_output: u64,
    min_output: u64,
    missed_flushes: u64,
    max_misses: u64,
}

public(package) fun new_book_and_ledger(
    ctx: &mut TxContext,
): (LpBook<LP_BOOK_TEST_SUPPORT>, Ledger) {
    let (initializer, treasury_cap) = coin_registry::new_currency_with_otw(
        LP_BOOK_TEST_SUPPORT {},
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

public(package) fun account_id(): ID {
    @0xA.to_id()
}

public(package) fun vault_id(): ID {
    @0xFEED.to_id()
}

public(package) fun assert_summary(
    summary: &DrainSummary,
    supplies_filled: u64,
    withdrawals_filled: u64,
    requests_processed: u64,
) {
    assert_eq!(summary.supplies_filled(), supplies_filled);
    assert_eq!(summary.withdrawals_filled(), withdrawals_filled);
    assert_eq!(summary.requests_processed(), requests_processed);
}

public(package) fun assert_cancelled_event(
    expected_event_count: u64,
    event_offset: u64,
    recipient: address,
    index: u64,
    amount: u64,
    is_supply: bool,
    reason: u8,
    requests_pending_after: u64,
) {
    let events = event::events_by_type<RequestCancelled>();
    assert_eq!(events.length(), expected_event_count);
    let expected = ExpectedRequestCancelled {
        pool_vault_id: vault_id(),
        account_id: account_id(),
        recipient,
        index,
        amount,
        is_supply,
        reason,
        requests_pending_after,
    };
    assert_eq!(bcs::to_bytes(events.borrow(event_offset)), bcs::to_bytes(&expected));
}

public(package) fun assert_limit_missed_event(
    expected_event_count: u64,
    event_offset: u64,
    recipient: address,
    index: u64,
    amount: u64,
    is_supply: bool,
    quoted_output: u64,
    min_output: u64,
    missed_flushes: u64,
    max_misses: u64,
) {
    let events = event::events_by_type<RequestLimitMissed>();
    assert_eq!(events.length(), expected_event_count);
    let expected = ExpectedRequestLimitMissed {
        pool_vault_id: vault_id(),
        account_id: account_id(),
        recipient,
        index,
        amount,
        is_supply,
        quoted_output,
        min_output,
        missed_flushes,
        max_misses,
    };
    assert_eq!(bcs::to_bytes(events.borrow(event_offset)), bcs::to_bytes(&expected));
}
