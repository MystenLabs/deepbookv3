// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Builder code identity and reward claiming for Predict.
///
/// Builder codes are deterministic shared objects derived from the Predict
/// registry. Trade flows send add-on builder fees to the code object's address
/// balance, and the code owner can later claim those accumulated DUSDC funds.
module deepbook_predict::builder_code;

use deepbook_predict::builder_code_events;
use dusdc::dusdc::DUSDC;
use sui::{accumulator::AccumulatorRoot, balance, coin::Coin, derived_object};

const ENotOwner: u64 = 0;

/// Key used to derive one builder code per `(owner, index)` pair.
public struct BuilderCodeKey(address, u64) has copy, drop, store;

/// Shared builder-code identity.
public struct BuilderCode has key {
    id: UID,
    owner: address,
    index: u64,
}

// === Public Functions ===

/// Return the builder code object ID.
public fun id(code: &BuilderCode): ID {
    code.id.to_inner()
}

/// Return the permanent owner of this builder code.
public fun owner(code: &BuilderCode): address {
    code.owner
}

/// Return this owner's builder-code index.
public fun index(code: &BuilderCode): u64 {
    code.index
}

/// Return the DUSDC builder fees currently visible for this code.
public fun claimable_builder_fees(root: &AccumulatorRoot, code: &BuilderCode): u64 {
    balance::settled_funds_value<DUSDC>(root, code.id.to_address())
}

/// Claim all settled DUSDC builder fees accumulated for this code.
public fun claim_all_builder_fees(
    code: &mut BuilderCode,
    root: &AccumulatorRoot,
    ctx: &mut TxContext,
): Coin<DUSDC> {
    code.assert_owner(ctx);
    let amount = claimable_builder_fees(root, code);
    if (amount == 0) return balance::zero<DUSDC>().into_coin(ctx);
    let withdrawal = balance::withdraw_funds_from_object<DUSDC>(&mut code.id, amount);
    let coin = balance::redeem_funds(withdrawal).into_coin(ctx);
    builder_code_events::emit_builder_fees_claimed(code.id(), code.owner, amount);
    coin
}

// === Public-Package Functions ===

/// Create and share a derived builder code for the transaction sender.
public(package) fun create_and_share(registry_uid: &mut UID, index: u64, ctx: &TxContext): ID {
    let owner = ctx.sender();
    let code = BuilderCode {
        id: derived_object::claim(registry_uid, BuilderCodeKey(owner, index)),
        owner,
        index,
    };
    let id = code.id();
    transfer::share_object(code);
    builder_code_events::emit_builder_code_created(id, owner, index);
    id
}

// === Private Functions ===

fun assert_owner(code: &BuilderCode, ctx: &TxContext) {
    assert!(ctx.sender() == code.owner, ENotOwner);
}
