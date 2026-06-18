// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Account-domain events: canonical-account lifecycle, app-whitelist governance,
/// and per-coin custody movement. Emitted by the modules that own each transition
/// (`account_registry` for lifecycle, `account` for custody). This is the
/// package's only event surface; indexing lives in follow-up account indexer work.
module account::account_events;

use std::ascii::String;
use sui::event;

/// A canonical derived account was created. `self_owned` is true when it was
/// created via `new_self_owned` (the owner is an object address) rather than `new`
/// (the owner is the transaction sender).
public struct AccountCreated has copy, drop {
    account_id: ID,
    wrapper_id: ID,
    owner: address,
    self_owned: bool,
}

public(package) fun emit_account_created(
    account_id: ID,
    wrapper_id: ID,
    owner: address,
    self_owned: bool,
) {
    event::emit(AccountCreated { account_id, wrapper_id, owner, self_owned });
}

/// An app witness type was added to the registry's mutable-load whitelist.
public struct AppAuthorized has copy, drop {
    /// Fully-qualified `App` witness type name.
    app: String,
}

/// An app witness type was removed from the whitelist.
public struct AppDeauthorized has copy, drop {
    app: String,
}

public(package) fun emit_app_authorized(app: String) {
    event::emit(AppAuthorized { app });
}

public(package) fun emit_app_deauthorized(app: String) {
    event::emit(AppDeauthorized { app });
}

/// `amount` of `coin_type` was deposited into the account; `new_balance` is the
/// resulting stored balance of that coin.
public struct Deposited has copy, drop {
    account_id: ID,
    coin_type: String,
    amount: u64,
    new_balance: u64,
}

/// `amount` of `coin_type` was withdrawn; `new_balance` is the resulting stored
/// balance.
public struct Withdrawn has copy, drop {
    account_id: ID,
    coin_type: String,
    amount: u64,
    new_balance: u64,
}

/// `amount` of `coin_type` arrived through the accumulator settlement barrier and
/// was settled into stored balance; `new_balance` is the resulting stored balance.
/// Only emitted when `amount > 0`.
public struct FundsSettled has copy, drop {
    account_id: ID,
    coin_type: String,
    amount: u64,
    new_balance: u64,
}

public(package) fun emit_deposited(account_id: ID, coin_type: String, amount: u64, new_balance: u64) {
    event::emit(Deposited { account_id, coin_type, amount, new_balance });
}

public(package) fun emit_withdrawn(account_id: ID, coin_type: String, amount: u64, new_balance: u64) {
    event::emit(Withdrawn { account_id, coin_type, amount, new_balance });
}

public(package) fun emit_funds_settled(
    account_id: ID,
    coin_type: String,
    amount: u64,
    new_balance: u64,
) {
    event::emit(FundsSettled { account_id, coin_type, amount, new_balance });
}
