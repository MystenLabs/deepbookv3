// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// One convex ticket, stored in a venue slot on the trader's Account.
/// `side` is 0 for a long and 1 for a short.
/// The ticket keeps the mid and the standard deviation from Open, for the trader's record.
/// Exit prices from the live mid.
module venue::index_ticket;

use account::account::Account;
use std::internal::permit;
use sui::table::{Self, Table};

public struct VenueApp has drop {}

public struct VenueData has store {
    tickets: Table<ID, Ticket>,
}

public struct Ticket has store {
    id: ID,
    market_id: ID,
    side: u8,
    floor: u64,
    cap: u64,
    size: u64,
    std: u64,
    entry_mid: u64,
    premium: u64,
    open_cash: u64,
    worst: u64,
}

/// Returns the witness a cap holder passes to `enclave::new_cap`.
public fun witness(): VenueApp { VenueApp {} }

/// Returns the mid stored when the ticket was opened.
public fun entry_mid(account: &Account, ticket_id: ID): u64 {
    account.borrow_data<VenueApp, VenueData>().tickets.borrow(ticket_id).entry_mid
}

/// Returns the standard deviation stored when the ticket was opened.
public fun std(account: &Account, ticket_id: ID): u64 {
    account.borrow_data<VenueApp, VenueData>().tickets.borrow(ticket_id).std
}

public fun premium(account: &Account, ticket_id: ID): u64 {
    account.borrow_data<VenueApp, VenueData>().tickets.borrow(ticket_id).premium
}

public fun open_cash(account: &Account, ticket_id: ID): u64 {
    account.borrow_data<VenueApp, VenueData>().tickets.borrow(ticket_id).open_cash
}

public(package) fun new(
    market_id: ID,
    side: u8,
    floor: u64,
    cap: u64,
    size: u64,
    std: u64,
    entry_mid: u64,
    premium: u64,
    open_cash: u64,
    worst: u64,
    ctx: &mut TxContext,
): Ticket {
    let id = object::new(ctx);
    let ticket_id = id.to_inner();
    id.delete();
    Ticket { id: ticket_id, market_id, side, floor, cap, size, std, entry_mid, premium, open_cash, worst }
}

public(package) fun insert(account: &mut Account, ticket: Ticket, ctx: &mut TxContext) {
    if (!account.has_data<VenueApp>()) {
        account.attach(permit<VenueApp>(), VenueData { tickets: table::new(ctx) });
    };
    let data = account.borrow_data_mut<VenueApp, VenueData>(permit<VenueApp>());
    let ticket_id = ticket.id;
    data.tickets.add(ticket_id, ticket);
}

public(package) fun remove(account: &mut Account, ticket_id: ID): Ticket {
    let data = account.borrow_data_mut<VenueApp, VenueData>(permit<VenueApp>());
    data.tickets.remove(ticket_id)
}

public(package) fun destroy(ticket: Ticket) {
    let Ticket { .. } = ticket;
}

public(package) fun market_id(ticket: &Ticket): ID { ticket.market_id }

public(package) fun side(ticket: &Ticket): u8 { ticket.side }

public(package) fun floor(ticket: &Ticket): u64 { ticket.floor }

public(package) fun cap(ticket: &Ticket): u64 { ticket.cap }

public(package) fun size(ticket: &Ticket): u64 { ticket.size }

public(package) fun std_of(ticket: &Ticket): u64 { ticket.std }

public(package) fun premium_of(ticket: &Ticket): u64 { ticket.premium }

public(package) fun open_cash_of(ticket: &Ticket): u64 { ticket.open_cash }

public(package) fun worst(ticket: &Ticket): u64 { ticket.worst }

public(package) fun id(ticket: &Ticket): ID { ticket.id }
