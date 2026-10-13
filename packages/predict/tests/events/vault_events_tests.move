// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Wire layout of the sum-safe expiry PnL event. The emitter is called with a
/// distinct value per field, and the event's BCS bytes are compared with a local
/// struct that spells out the published field order, so a reordered, retyped, or
/// dropped field fails here before it freezes at publish.
#[test_only]
module deepbook_predict::vault_events_tests;

use deepbook_predict::vault_events;
use std::{bcs, unit_test::assert_eq};
use sui::event;

const ONE_EVENT: u64 = 1;
const FIRST: u64 = 0;

public struct ExpectedExpiryPnlRealized has copy, drop {
    pool_vault_id: ID,
    expiry_market_id: ID,
    propbook_underlying_id: u32,
    expiry: u64,
    settlement_price: u64,
    in_profit: bool,
    amount: u64,
}

#[test]
fun expiry_pnl_realized_layout() {
    let expected = ExpectedExpiryPnlRealized {
        pool_vault_id: object::id_from_address(@0xB1),
        expiry_market_id: object::id_from_address(@0xE1),
        propbook_underlying_id: 1,
        expiry: 2,
        settlement_price: 3,
        in_profit: true,
        amount: 4,
    };

    vault_events::pnl_realized(
        expected.pool_vault_id,
        expected.expiry_market_id,
        expected.propbook_underlying_id,
        expected.expiry,
        expected.settlement_price,
        expected.in_profit,
        expected.amount,
    );

    let events = event::events_by_type<vault_events::ExpiryPnlRealized>();
    assert_eq!(events.length(), ONE_EVENT);
    assert_eq!(bcs::to_bytes(&events[FIRST]), bcs::to_bytes(&expected));
}
