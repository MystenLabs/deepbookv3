// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Pool-owned expiry registration and cash-flow accounting.
///
/// This module owns pool idle DUSDC custody, the durable set of expiries
/// registered to a pool, the active expiry index used for valuation, DUSDC sent
/// from the main pool into each expiry, DUSDC received back from each expiry,
/// terminal cash watermarks, and per-expiry net funding cap checks. It does not
/// classify expiry-local liabilities or apply PLP reserve policy; PoolVault uses
/// the aggregate profit basis to price PLP and decide protocol reserve transfers.
module deepbook_predict::pool_accounting;

use deepbook_predict::constants;
use dusdc::dusdc::DUSDC;
use sui::{balance::{Self, Balance}, table::{Self, Table}};

const EUnknownRegisteredExpiry: u64 = 0;
const ERegisteredExpiryAlreadyExists: u64 = 1;
const EMaxExpiryFundingExceeded: u64 = 2;
const ETerminalAccountingStarted: u64 = 3;
const EMaxActiveExpiryMarkets: u64 = 4;

/// Aggregate and per-expiry DUSDC accounting ledger.
public struct Ledger has store {
    /// Idle LP-owned DUSDC available for withdrawals and expiry funding.
    idle_balance: Balance<DUSDC>,
    /// Expiry markets that still contribute active pool valuation/risk.
    active_expiry_markets: vector<ID>,
    /// Permanent per-expiry accounting rows. Presence means the expiry belongs to this pool.
    registered_expiries: Table<ID, RegisteredExpiry>,
    /// Pricing debit basis: DUSDC sent to expiries plus materialized terminal profit.
    profit_basis_debits: u64,
    /// Pricing credit basis: all DUSDC received back from expiries.
    profit_basis_credits: u64,
    /// Aggregate terminal losses that future terminal profits must recover first.
    net_losses_to_fill: u64,
}

/// Durable accounting row for one registered expiry market.
public struct RegisteredExpiry has store {
    /// DUSDC sent from the main pool into this expiry.
    sent_to_expiry: u64,
    /// DUSDC returned from this expiry to the main pool.
    received_from_expiry: u64,
    /// True once this expiry has started terminal profit/loss accounting.
    terminal_accounting_started: bool,
    /// Received amount already consumed by terminal accounting.
    terminal_received_watermark: u64,
}

public(package) fun idle_balance(ledger: &Ledger): u64 {
    ledger.idle_balance.value()
}

public(package) fun active_expiry_markets(ledger: &Ledger): &vector<ID> {
    &ledger.active_expiry_markets
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

/// Return remaining net DUSDC the pool may fund into one expiry under the
/// caller-supplied current max-funding cap.
public(package) fun available_expiry_funding(
    ledger: &Ledger,
    expiry_market_id: ID,
    max_expiry_funding: u64,
): u64 {
    ledger.assert_registered_expiry(expiry_market_id);
    let flow = ledger.registered_expiries.borrow(expiry_market_id);
    let net_funding = flow_net_funding(flow);
    max_expiry_funding.saturating_sub(net_funding)
}

/// Abort unless this expiry is registered to the pool.
public(package) fun assert_registered_expiry(ledger: &Ledger, expiry_market_id: ID) {
    assert!(ledger.registered_expiries.contains(expiry_market_id), EUnknownRegisteredExpiry);
}

public(package) fun new(ctx: &mut TxContext): Ledger {
    Ledger {
        idle_balance: balance::zero(),
        active_expiry_markets: vector[],
        registered_expiries: table::new(ctx),
        profit_basis_debits: 0,
        profit_basis_credits: 0,
        net_losses_to_fill: 0,
    }
}

/// Register an expiry as active pool risk.
public(package) fun register_expiry(ledger: &mut Ledger, expiry_market_id: ID) {
    assert!(!ledger.registered_expiries.contains(expiry_market_id), ERegisteredExpiryAlreadyExists);
    assert!(
        ledger.active_expiry_markets.length() < constants::max_active_expiry_markets!(),
        EMaxActiveExpiryMarkets,
    );
    ledger.active_expiry_markets.push_back(expiry_market_id);
    ledger
        .registered_expiries
        .add(
            expiry_market_id,
            RegisteredExpiry {
                sent_to_expiry: 0,
                received_from_expiry: 0,
                terminal_accounting_started: false,
                terminal_received_watermark: 0,
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

/// Validate the new max-funding cap against current net funding and return that net funding.
public(package) fun validate_max_expiry_funding(
    ledger: &Ledger,
    expiry_market_id: ID,
    new_max_expiry_funding: u64,
): u64 {
    let net_funding = ledger.net_expiry_funding(expiry_market_id);
    assert!(net_funding <= new_max_expiry_funding, EMaxExpiryFundingExceeded);
    net_funding
}

/// Join idle DUSDC.
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

/// Materialize one terminal expiry's unapplied raw profit.
public(package) fun materialize_expiry_profit(ledger: &mut Ledger, expiry_market_id: ID): u64 {
    ledger.assert_registered_expiry(expiry_market_id);
    let (initial_loss, profit) = {
        let flow = ledger.registered_expiries.borrow_mut(expiry_market_id);
        let initial_loss = start_terminal_accounting_if_needed(flow);
        let received = flow.received_from_expiry;
        let profit = if (received > flow.terminal_received_watermark) {
            let profit = received - flow.terminal_received_watermark;
            flow.terminal_received_watermark = received;
            profit
        } else {
            0
        };
        (initial_loss, profit)
    };
    ledger.net_losses_to_fill = ledger.net_losses_to_fill + initial_loss;
    if (profit == 0) {
        return 0
    };
    if (profit <= ledger.net_losses_to_fill) {
        ledger.net_losses_to_fill = ledger.net_losses_to_fill - profit;
        0
    } else {
        let materialized_profit = profit - ledger.net_losses_to_fill;
        ledger.net_losses_to_fill = 0;
        ledger.profit_basis_debits = ledger.profit_basis_debits + materialized_profit;
        materialized_profit
    }
}

/// Return current net DUSDC funded into an expiry.
fun net_expiry_funding(ledger: &Ledger, expiry_market_id: ID): u64 {
    ledger.assert_registered_expiry(expiry_market_id);
    flow_net_funding(ledger.registered_expiries.borrow(expiry_market_id))
}

fun record_sent_to_expiry(
    ledger: &mut Ledger,
    expiry_market_id: ID,
    max_expiry_funding: u64,
    amount: u64,
) {
    if (amount == 0) return;
    ledger.assert_registered_expiry(expiry_market_id);
    let flow = ledger.registered_expiries.borrow_mut(expiry_market_id);
    assert!(!flow.terminal_accounting_started, ETerminalAccountingStarted);
    let current_net_funding = flow_net_funding(flow);
    assert!(current_net_funding + amount <= max_expiry_funding, EMaxExpiryFundingExceeded);
    flow.sent_to_expiry = flow.sent_to_expiry + amount;
    ledger.profit_basis_debits = ledger.profit_basis_debits + amount;
}

fun record_received_from_expiry(ledger: &mut Ledger, expiry_market_id: ID, amount: u64) {
    if (amount == 0) return;
    ledger.assert_registered_expiry(expiry_market_id);
    let flow = ledger.registered_expiries.borrow_mut(expiry_market_id);
    flow.received_from_expiry = flow.received_from_expiry + amount;
    ledger.profit_basis_credits = ledger.profit_basis_credits + amount;
}

fun flow_net_funding(flow: &RegisteredExpiry): u64 {
    if (flow.sent_to_expiry > flow.received_from_expiry) {
        flow.sent_to_expiry - flow.received_from_expiry
    } else {
        0
    }
}

fun start_terminal_accounting_if_needed(flow: &mut RegisteredExpiry): u64 {
    if (flow.terminal_accounting_started) {
        return 0
    };
    flow.terminal_accounting_started = true;
    if (flow.sent_to_expiry > flow.received_from_expiry) {
        flow.terminal_received_watermark = flow.received_from_expiry;
        flow.sent_to_expiry - flow.received_from_expiry
    } else {
        // Start at sent cash so the normal received-delta path consumes any
        // initial terminal profit without special-case materialization logic.
        flow.terminal_received_watermark = flow.sent_to_expiry;
        0
    }
}
