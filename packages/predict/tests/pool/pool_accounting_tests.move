// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module deepbook_predict::pool_accounting_tests;

use deepbook_predict::{config_constants, pool_accounting};
use dusdc::dusdc::DUSDC;
use std::unit_test::assert_eq;
use sui::{coin, test_utils::destroy};

const EXPIRY_ID: address = @0xACCC;
const UNKNOWN_EXPIRY_ID: address = @0xBEEF;
const EXPIRY_ID_0: address = @0xA000;
const EXPIRY_ID_1: address = @0xA001;
const EXPIRY_ID_2: address = @0xA002;
const EXPIRY_ID_3: address = @0xA003;
const EXPIRY_ID_4: address = @0xA004;
const EXPIRY_ID_5: address = @0xA005;
const EXPIRY_ID_6: address = @0xA006;
const EXPIRY_ID_7: address = @0xA007;
const EXPIRY_ID_8: address = @0xA008;
const EXPIRY_ID_9: address = @0xA009;
const EXPIRY_ID_10: address = @0xA010;

#[test, expected_failure(abort_code = pool_accounting::ERegisteredExpiryAlreadyExists)]
fun register_expiry_twice_aborts() {
    let ctx = &mut tx_context::dummy();
    let expiry_id = EXPIRY_ID.to_id();
    let mut ledger = pool_accounting::new(ctx);
    fund_expiry_capacity(&mut ledger, 1, ctx);
    ledger.register_expiry(expiry_id, default_max_funding());
    assert_eq!(ledger.active_expiry_markets().length(), 1);

    ledger.register_expiry(expiry_id, default_max_funding());
    abort 999
}

#[test, expected_failure(abort_code = pool_accounting::EInsufficientActiveAllocationBacking)]
fun register_expiry_without_idle_backing_aborts() {
    let ctx = &mut tx_context::dummy();
    let mut ledger = pool_accounting::new(ctx);

    ledger.register_expiry(EXPIRY_ID.to_id(), default_max_funding());
    abort 999
}

#[test, expected_failure(abort_code = pool_accounting::EMaxActiveExpiryMarkets)]
fun register_expiry_above_active_limit_aborts() {
    let ctx = &mut tx_context::dummy();
    let mut ledger = pool_accounting::new(ctx);
    fund_expiry_capacity(&mut ledger, 10, ctx);
    register_ten_active_expiries(&mut ledger);
    assert_eq!(ledger.active_expiry_markets().length(), 10);

    ledger.register_expiry(EXPIRY_ID_10.to_id(), default_max_funding());
    abort 999
}

#[test, expected_failure(abort_code = pool_accounting::EUnknownRegisteredExpiry)]
fun unknown_expiry_flow_read_aborts() {
    let ctx = &mut tx_context::dummy();
    let ledger = pool_accounting::new(ctx);
    assert_eq!(ledger.active_expiry_markets().length(), 0);

    let (_, _) = ledger.expiry_flow_amounts(UNKNOWN_EXPIRY_ID.to_id());
    abort 999
}

#[test, expected_failure(abort_code = pool_accounting::EMaxExpiryFundingExceeded)]
fun send_expiry_cash_above_funding_cap_aborts() {
    let ctx = &mut tx_context::dummy();
    let expiry_id = EXPIRY_ID.to_id();
    let mut ledger = pool_accounting::new(ctx);
    fund_expiry_capacity(&mut ledger, 2, ctx);
    ledger.register_expiry(expiry_id, default_max_funding());

    let cash = ledger.send_expiry_cash(expiry_id, default_max_funding(), default_max_funding() + 1);
    destroy(cash);
    abort 999
}

#[test, expected_failure(abort_code = pool_accounting::EMaxExpiryFundingExceeded)]
fun lowering_funding_cap_below_net_funding_aborts() {
    let ctx = &mut tx_context::dummy();
    let expiry_id = EXPIRY_ID.to_id();
    let mut ledger = pool_accounting::new(ctx);
    fund_expiry_capacity(&mut ledger, 1, ctx);
    ledger.register_expiry(expiry_id, default_max_funding());
    let sent = default_max_funding() / 2;
    let cash = ledger.send_expiry_cash(expiry_id, default_max_funding(), sent);
    destroy(cash);

    // New cap below the expiry's current net funding is rejected.
    let _ = ledger.update_max_expiry_funding(expiry_id, default_max_funding(), sent - 1);
    abort 999
}

#[test, expected_failure(abort_code = pool_accounting::ETerminalAccountingStarted)]
fun send_expiry_cash_after_terminal_accounting_aborts() {
    let ctx = &mut tx_context::dummy();
    let expiry_id = EXPIRY_ID.to_id();
    let mut ledger = pool_accounting::new(ctx);
    fund_expiry_capacity(&mut ledger, 1, ctx);
    ledger.register_expiry(expiry_id, default_max_funding());
    // Materializing terminal profit latches terminal accounting for the expiry.
    let _ = ledger.materialize_expiry_profit(expiry_id);

    let cash = ledger.send_expiry_cash(expiry_id, default_max_funding(), 1);
    destroy(cash);
    abort 999
}

#[test, expected_failure(abort_code = pool_accounting::EInvalidActiveFundingAggregate)]
fun cap_update_with_inconsistent_old_cap_aborts() {
    let ctx = &mut tx_context::dummy();
    let expiry_id = EXPIRY_ID.to_id();
    let mut ledger = pool_accounting::new(ctx);
    fund_expiry_capacity(&mut ledger, 1, ctx);
    ledger.register_expiry(expiry_id, default_max_funding());

    // `old_max_expiry_funding` is caller-supplied (the ledger does not store
    // per-expiry caps); an old value above the tracked active aggregate would
    // underflow the sum and is rejected as an aggregate-consistency violation.
    let _ = ledger.update_max_expiry_funding(expiry_id, 2 * default_max_funding(), 0);
    abort 999
}

fun register_ten_active_expiries(ledger: &mut pool_accounting::Ledger) {
    ledger.register_expiry(EXPIRY_ID_0.to_id(), default_max_funding());
    ledger.register_expiry(EXPIRY_ID_1.to_id(), default_max_funding());
    ledger.register_expiry(EXPIRY_ID_2.to_id(), default_max_funding());
    ledger.register_expiry(EXPIRY_ID_3.to_id(), default_max_funding());
    ledger.register_expiry(EXPIRY_ID_4.to_id(), default_max_funding());
    ledger.register_expiry(EXPIRY_ID_5.to_id(), default_max_funding());
    ledger.register_expiry(EXPIRY_ID_6.to_id(), default_max_funding());
    ledger.register_expiry(EXPIRY_ID_7.to_id(), default_max_funding());
    ledger.register_expiry(EXPIRY_ID_8.to_id(), default_max_funding());
    ledger.register_expiry(EXPIRY_ID_9.to_id(), default_max_funding());
}

fun default_max_funding(): u64 {
    config_constants::default_max_expiry_funding!()
}

fun fund_expiry_capacity(ledger: &mut pool_accounting::Ledger, count: u64, ctx: &mut TxContext) {
    let funding = default_max_funding() * count;
    ledger.receive_idle(coin::mint_for_testing<DUSDC>(funding, ctx).into_balance());
}
