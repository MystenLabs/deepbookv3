// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Account-domain events: canonical-account lifecycle, app-whitelist governance,
/// and per-coin custody movement. Emitted by the modules that own each transition
/// (`account_registry` for lifecycle, `account` for custody), and indexed by the
/// standalone `account-indexer` crate. This is the package's only event surface.
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

#[test_only]
public fun created_account_id(self: &AccountCreated): ID { self.account_id }

#[test_only]
public fun created_owner(self: &AccountCreated): address { self.owner }

#[test_only]
public fun created_self_owned(self: &AccountCreated): bool { self.self_owned }
