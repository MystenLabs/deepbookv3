// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Pool-owned expiry registration and cash-flow accounting.
///
/// This module owns pool idle DUSDC custody, the durable set of expiries
/// registered to a pool, the active expiry index, DUSDC sent from the main pool
/// into each expiry, and DUSDC received back from each expiry. It does not value
/// expiries or apply PLP reserve/profit policy: per-expiry profit is the B-rest
/// reconciliation (`received_from_expiry` minus `sent_to_expiry`), derived later,
/// so no terminal-accounting watermark state lives here.
module deepbook_predict::pool_accounting;

use deepbook_predict::constants;
use dusdc::dusdc::DUSDC;
use sui::{balance::{Self, Balance}, table::{Self, Table}};

const EUnknownRegisteredExpiry: u64 = 0;
const ERegisteredExpiryAlreadyExists: u64 = 1;
const EMaxExpiryFundingExceeded: u64 = 2;
const EMaxActiveExpiryMarkets: u64 = 3;

/// Aggregate and per-expiry DUSDC accounting ledger.
public struct Ledger has store {
    /// Idle LP-owned DUSDC available for withdrawals and expiry funding.
    idle_balance: Balance<DUSDC>,
    /// Expiry markets that still contribute active pool valuation/risk.
    active_expiry_markets: vector<ID>,
    /// Permanent per-expiry accounting rows. Presence means the expiry belongs to this pool.
    registered_expiries: Table<ID, RegisteredExpiry>,
}

/// Durable accounting row for one registered expiry market.
public struct RegisteredExpiry has store {
    /// DUSDC sent from the main pool into this expiry.
    sent_to_expiry: u64,
    /// DUSDC returned from this expiry to the main pool.
    received_from_expiry: u64,
}

public(package) fun new(ctx: &mut TxContext): Ledger {
    Ledger {
        idle_balance: balance::zero(),
        active_expiry_markets: vector[],
        registered_expiries: table::new(ctx),
    }
}

public(package) fun idle_balance(ledger: &Ledger): u64 {
    ledger.idle_balance.value()
}

/// Return remaining net DUSDC the pool may fund into one expiry under the
/// caller-supplied current max-funding cap.
public(package) fun available_expiry_funding(
    ledger: &Ledger,
    expiry_market_id: ID,
    max_expiry_funding: u64,
): u64 {
    max_expiry_funding.saturating_sub(ledger.net_expiry_funding(expiry_market_id))
}

/// Abort unless this expiry is registered to the pool.
public(package) fun assert_registered_expiry(ledger: &Ledger, expiry_market_id: ID) {
    assert!(ledger.registered_expiries.contains(expiry_market_id), EUnknownRegisteredExpiry);
}

/// Register an expiry as active pool risk. Records an accounting row only; no
/// cash moves, so the expiry is not yet funded.
public(package) fun register_expiry(ledger: &mut Ledger, expiry_market_id: ID) {
    assert!(!ledger.registered_expiries.contains(expiry_market_id), ERegisteredExpiryAlreadyExists);
    assert!(
        ledger.active_expiry_markets.length() < constants::max_active_expiry_markets!(),
        EMaxActiveExpiryMarkets,
    );
    ledger.active_expiry_markets.push_back(expiry_market_id);
    ledger
        .registered_expiries
        .add(expiry_market_id, RegisteredExpiry { sent_to_expiry: 0, received_from_expiry: 0 });
}

/// Join idle DUSDC. Idle is fundable only internally for now; the async LP
/// supply flow (Track C) is the future external caller.
public(package) fun receive_idle(ledger: &mut Ledger, cash: Balance<DUSDC>) {
    ledger.idle_balance.join(cash);
}

/// Split idle DUSDC.
public(package) fun withdraw_idle(ledger: &mut Ledger, amount: u64): Balance<DUSDC> {
    ledger.idle_balance.split(amount)
}

/// Split idle DUSDC into an expiry while recording the funding flow and enforcing
/// the caller-supplied current max-funding cap.
public(package) fun send_expiry_cash(
    ledger: &mut Ledger,
    expiry_market_id: ID,
    max_expiry_funding: u64,
    amount: u64,
): Balance<DUSDC> {
    if (amount == 0) return balance::zero();
    ledger.record_sent_to_expiry(expiry_market_id, max_expiry_funding, amount);
    ledger.idle_balance.split(amount)
}

/// Receive DUSDC returned from an expiry.
public(package) fun receive_expiry_cash(
    ledger: &mut Ledger,
    expiry_market_id: ID,
    cash: Balance<DUSDC>,
): u64 {
    let amount = cash.value();
    if (amount == 0) {
        cash.destroy_zero();
        return 0
    };
    ledger.idle_balance.join(cash);
    ledger.record_received_from_expiry(expiry_market_id, amount);
    amount
}

/// Return current net DUSDC funded into an expiry (sent minus received, floored).
fun net_expiry_funding(ledger: &Ledger, expiry_market_id: ID): u64 {
    ledger.assert_registered_expiry(expiry_market_id);
    let flow = ledger.registered_expiries.borrow(expiry_market_id);
    flow.sent_to_expiry.saturating_sub(flow.received_from_expiry)
}

fun record_sent_to_expiry(
    ledger: &mut Ledger,
    expiry_market_id: ID,
    max_expiry_funding: u64,
    amount: u64,
) {
    if (amount == 0) return;
    let current_net_funding = ledger.net_expiry_funding(expiry_market_id);
    assert!(current_net_funding + amount <= max_expiry_funding, EMaxExpiryFundingExceeded);
    let flow = ledger.registered_expiries.borrow_mut(expiry_market_id);
    flow.sent_to_expiry = flow.sent_to_expiry + amount;
}

fun record_received_from_expiry(ledger: &mut Ledger, expiry_market_id: ID, amount: u64) {
    if (amount == 0) return;
    ledger.assert_registered_expiry(expiry_market_id);
    let flow = ledger.registered_expiries.borrow_mut(expiry_market_id);
    flow.received_from_expiry = flow.received_from_expiry + amount;
}
