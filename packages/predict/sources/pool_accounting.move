// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Pool-owned expiry registration and cash-flow accounting.
///
/// This module owns the durable set of expiries registered to a pool, the active
/// expiry index used for valuation, DUSDC sent from the main pool into each
/// expiry, DUSDC received back from each expiry, and per-expiry net funding
/// caps. It does not custody funds or classify expiry-local liabilities;
/// PoolVault uses the aggregate profit basis to materialize excess DUSDC.
module deepbook_predict::pool_accounting;

use deepbook_predict::config_constants;
use sui::table::{Self, Table};

const EUnknownRegisteredExpiry: u64 = 0;
const ERegisteredExpiryAlreadyExists: u64 = 1;
const EMaxExpiryFundingExceeded: u64 = 2;

/// Aggregate and per-expiry DUSDC accounting ledger.
public struct Ledger has store {
    /// Expiry markets that still contribute active pool valuation/risk.
    active_expiry_markets: vector<ID>,
    /// Permanent per-expiry accounting rows. Presence means the expiry belongs to this pool.
    registered_expiries: Table<ID, RegisteredExpiry>,
    /// Money-out side of aggregate profit basis.
    profit_basis_debits: u64,
    /// Money-in side of aggregate profit basis.
    profit_basis_credits: u64,
}

/// Durable accounting row for one registered expiry market.
public struct RegisteredExpiry has store {
    /// DUSDC sent from the main pool into this expiry.
    sent_to_expiry: u64,
    /// DUSDC returned from this expiry to the main pool.
    received_from_expiry: u64,
    /// Max net DUSDC the pool may have funded into this expiry.
    max_expiry_funding: u64,
}

public(package) fun active_expiry_markets(ledger: &Ledger): &vector<ID> {
    &ledger.active_expiry_markets
}

public(package) fun is_active_expiry(ledger: &Ledger, expiry_market_id: ID): bool {
    ledger.active_expiry_markets.contains(&expiry_market_id)
}

public(package) fun profit_basis_debits(ledger: &Ledger): u64 {
    ledger.profit_basis_debits
}

public(package) fun profit_basis_credits(ledger: &Ledger): u64 {
    ledger.profit_basis_credits
}

public(package) fun expiry_flow_amounts(ledger: &Ledger, expiry_market_id: ID): (u64, u64) {
    ledger.assert_registered_expiry(expiry_market_id);
    let flow = ledger.registered_expiries.borrow(expiry_market_id);
    (flow.sent_to_expiry, flow.received_from_expiry)
}

public(package) fun max_expiry_funding(ledger: &Ledger, expiry_market_id: ID): u64 {
    ledger.assert_registered_expiry(expiry_market_id);
    ledger.registered_expiries.borrow(expiry_market_id).max_expiry_funding
}

/// Return remaining net DUSDC the pool may fund into one expiry.
public(package) fun available_expiry_funding(ledger: &Ledger, expiry_market_id: ID): u64 {
    ledger.assert_registered_expiry(expiry_market_id);
    let flow = ledger.registered_expiries.borrow(expiry_market_id);
    let net_funding = flow_net_funding(flow);
    if (net_funding < flow.max_expiry_funding) {
        flow.max_expiry_funding - net_funding
    } else {
        0
    }
}

/// Abort unless this expiry is registered to the pool.
public(package) fun assert_registered_expiry(ledger: &Ledger, expiry_market_id: ID) {
    assert!(ledger.registered_expiries.contains(expiry_market_id), EUnknownRegisteredExpiry);
}

public(package) fun new(ctx: &mut TxContext): Ledger {
    Ledger {
        active_expiry_markets: vector[],
        registered_expiries: table::new(ctx),
        profit_basis_debits: 0,
        profit_basis_credits: 0,
    }
}

public(package) fun register_expiry(ledger: &mut Ledger, expiry_market_id: ID) {
    assert!(!ledger.registered_expiries.contains(expiry_market_id), ERegisteredExpiryAlreadyExists);
    let max_expiry_funding = config_constants::default_max_expiry_funding!();
    ledger.active_expiry_markets.push_back(expiry_market_id);
    ledger
        .registered_expiries
        .add(
            expiry_market_id,
            RegisteredExpiry {
                sent_to_expiry: 0,
                received_from_expiry: 0,
                max_expiry_funding,
            },
        );
}

/// Remove an expiry from active valuation if present, returning whether it was active.
public(package) fun deactivate_expiry_if_present(ledger: &mut Ledger, expiry_market_id: ID): bool {
    ledger.assert_registered_expiry(expiry_market_id);
    let mut i = 0;
    let len = ledger.active_expiry_markets.length();
    while (i < len && ledger.active_expiry_markets[i] != expiry_market_id) {
        i = i + 1;
    };
    if (i == len) {
        return false
    };
    ledger.active_expiry_markets.swap_remove(i);
    true
}

public(package) fun set_max_expiry_funding(
    ledger: &mut Ledger,
    expiry_market_id: ID,
    max_expiry_funding: u64,
): u64 {
    config_constants::assert_max_expiry_funding(max_expiry_funding);
    ledger.assert_registered_expiry(expiry_market_id);
    let net_funding = ledger.expiry_net_funding(expiry_market_id);
    assert!(net_funding <= max_expiry_funding, EMaxExpiryFundingExceeded);
    ledger.registered_expiries.borrow_mut(expiry_market_id).max_expiry_funding = max_expiry_funding;
    net_funding
}

public(package) fun record_sent_to_expiry(ledger: &mut Ledger, expiry_market_id: ID, amount: u64) {
    if (amount == 0) return;
    ledger.assert_registered_expiry(expiry_market_id);
    let flow = ledger.registered_expiries.borrow_mut(expiry_market_id);
    let current_net_funding = flow_net_funding(flow);
    assert!(current_net_funding + amount <= flow.max_expiry_funding, EMaxExpiryFundingExceeded);
    flow.sent_to_expiry = flow.sent_to_expiry + amount;
    ledger.profit_basis_debits = ledger.profit_basis_debits + amount;
}

public(package) fun record_received_from_expiry(
    ledger: &mut Ledger,
    expiry_market_id: ID,
    amount: u64,
) {
    if (amount == 0) return;
    ledger.assert_registered_expiry(expiry_market_id);
    let flow = ledger.registered_expiries.borrow_mut(expiry_market_id);
    flow.received_from_expiry = flow.received_from_expiry + amount;
    ledger.profit_basis_credits = ledger.profit_basis_credits + amount;
}

/// Return newly materializable cash-backed DUSDC profit and mark it as realized.
public(package) fun materialize_profit(ledger: &mut Ledger): u64 {
    if (ledger.profit_basis_credits <= ledger.profit_basis_debits) {
        return 0
    };
    let profit = ledger.profit_basis_credits - ledger.profit_basis_debits;
    ledger.profit_basis_debits = ledger.profit_basis_credits;
    profit
}

fun expiry_net_funding(ledger: &Ledger, expiry_market_id: ID): u64 {
    ledger.assert_registered_expiry(expiry_market_id);
    let flow = ledger.registered_expiries.borrow(expiry_market_id);
    flow_net_funding(flow)
}

fun flow_net_funding(flow: &RegisteredExpiry): u64 {
    if (flow.sent_to_expiry > flow.received_from_expiry) {
        flow.sent_to_expiry - flow.received_from_expiry
    } else {
        0
    }
}
