// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Builder-code lifecycle and attribution events for Predict.
module deepbook_predict::builder_code_events;

use sui::event;

/// Emitted when a derived BuilderCode is created.
public struct BuilderCodeCreated has copy, drop, store {
    builder_code_id: ID,
    owner: address,
    builder_code_index: u64,
}

/// Emitted when an account changes sticky builder-code attribution.
public struct BuilderCodeSet has copy, drop, store {
    account_id: ID,
    owner: address,
    builder_code_id: Option<ID>,
}

/// Emitted when a builder code owner claims accumulated builder fees.
public struct BuilderFeesClaimed has copy, drop, store {
    builder_code_id: ID,
    owner: address,
    amount: u64,
}

// === Public-Package Functions ===

public(package) fun emit_builder_code_created(
    builder_code_id: ID,
    owner: address,
    builder_code_index: u64,
) {
    event::emit(BuilderCodeCreated {
        builder_code_id,
        owner,
        builder_code_index,
    });
}

public(package) fun emit_builder_code_set(
    account_id: ID,
    owner: address,
    builder_code_id: Option<ID>,
) {
    event::emit(BuilderCodeSet {
        account_id,
        owner,
        builder_code_id,
    });
}

public(package) fun emit_builder_fees_claimed(builder_code_id: ID, owner: address, amount: u64) {
    event::emit(BuilderFeesClaimed {
        builder_code_id,
        owner,
        amount,
    });
}
