// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// The custody kernel for `account`: a `Vault` value that holds `Coin<T>`
/// balances and moves them only against a `Proof`.
///
/// The kernel performs NO authorization. It enforces one thing only: that a
/// `Proof` is bound to this vault. It trusts that whoever obtained the proof
/// checked authority — proofs can only be minted through `issue_proof`, which is
/// package-private, so the sole issuer is `account::account`. The movement
/// functions are themselves `public(package)`: `account::account` is the only
/// front door, so the kernel has no public surface of its own.
module account::account_core;

use sui::{bag::{Self, Bag}, balance::Balance};

// === Errors ===
const EProofAccountMismatch: u64 = 0;
const EBalanceTooLow: u64 = 1;

// === Structs ===
/// Embedded custody value. Owns the balances and carries the id of the
/// `Account` that wraps it, so proofs can be bound to a specific account.
public struct Vault has store {
    account_id: ID,
    balances: Bag,
}

/// Ephemeral movement capability. Its existence asserts that an issuer checked
/// authorization; the kernel only enforces that it is bound to this vault.
public struct Proof has drop {
    account_id: ID,
}

/// Balance bag key.
public struct BalanceKey<phantom T> has copy, drop, store {}

// === Public-Package Functions ===
/// Returns the balance of `T` held by the vault.
public(package) fun balance<T>(self: &Vault): u64 {
    let key = BalanceKey<T> {};
    if (self.balances.contains(key)) {
        let bal: &Balance<T> = &self.balances[key];
        bal.value()
    } else {
        0
    }
}

/// Deposit `balance`. Requires a proof bound to this vault.
public(package) fun deposit_with_proof<T>(self: &mut Vault, proof: &Proof, balance: Balance<T>) {
    self.assert_bound(proof);
    self.deposit_balance(balance);
}

/// Withdraw `amount` of `T`. Requires a proof bound to this vault.
public(package) fun withdraw_with_proof<T>(
    self: &mut Vault,
    proof: &Proof,
    amount: u64,
): Balance<T> {
    self.assert_bound(proof);
    self.withdraw_balance(amount)
}

/// Create an empty vault bound to `account_id`. The wrapping `Account`
/// constructor owns identity.
public(package) fun new_vault(account_id: ID, ctx: &mut TxContext): Vault {
    Vault { account_id, balances: bag::new(ctx) }
}

/// Stamp a movement proof bound to this vault. Dumb by design: performs NO
/// authorization — the caller must have checked it.
public(package) fun issue_proof(self: &Vault): Proof {
    Proof { account_id: self.account_id }
}

/// Abort unless `proof` is bound to this vault. This is the binding check spent on
/// every deposit/withdraw, exposed so the authority layer can gate non-value owner
/// actions on the same proof — a `Proof` is the single "may mutate this account"
/// authority.
public(package) fun assert_bound(self: &Vault, proof: &Proof) {
    assert!(self.account_id == proof.account_id, EProofAccountMismatch);
}

// === Private Functions ===
fun deposit_balance<T>(self: &mut Vault, balance: Balance<T>) {
    let key = BalanceKey<T> {};
    if (self.balances.contains(key)) {
        let bal: &mut Balance<T> = &mut self.balances[key];
        bal.join(balance);
    } else {
        self.balances.add(key, balance);
    }
}

fun withdraw_balance<T>(self: &mut Vault, amount: u64): Balance<T> {
    let key = BalanceKey<T> {};
    assert!(self.balances.contains(key), EBalanceTooLow);
    let bal: &mut Balance<T> = &mut self.balances[key];
    assert!(bal.value() >= amount, EBalanceTooLow);
    if (bal.value() == amount) {
        self.balances.remove(key)
    } else {
        bal.split(amount)
    }
}
