// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Owns deterministic builder referral codes and the DUSDC fees delivered to their object addresses through the funds accumulator.
/// Codes are derived per owner and index, and only the immutable owner may withdraw accumulated fees.
module deepbook_predict::builder_code;

use deepbook_predict::builder_code_events;
use dusdc::dusdc::DUSDC;
use sui::{accumulator::AccumulatorRoot, balance, coin::Coin, derived_object};

const ENotOwner: u64 = 0;

/// Derivation key for one builder code per owner-selected index.
public struct BuilderCodeKey(address, u64) has copy, drop, store;

/// Shared referral identity whose object address receives builder-fee settlements.
public struct BuilderCode has key {
    id: UID,
    owner: address,
    index: u64,
}

// === Public Functions ===

/// Returns the code identity for trade construction and external discovery.
public fun id(code: &BuilderCode): ID {
    code.id.to_inner()
}

/// Returns the immutable owner authorized to claim fees.
public fun owner(code: &BuilderCode): address {
    code.owner
}

/// Returns the owner-selected derivation index for external discovery.
public fun index(code: &BuilderCode): u64 {
    code.index
}

/// Return visible DUSDC builder fees for SDK and dev-inspect reads.
public fun claimable_builder_fees(root: &AccumulatorRoot, code: &BuilderCode): u64 {
    balance::settled_funds_value<DUSDC>(root, code.id.to_address())
}

/// Claims all settled DUSDC builder fees for the immutable owner; an empty accumulator returns a zero coin.
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

/// Derives and shares a builder code for the transaction sender and index under the registry root.
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
