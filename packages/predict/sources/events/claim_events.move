// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Builder-fee claim events for Predict.
module deepbook_predict::claim_events;

use sui::event;

/// Emitted when a builder code owner claims accumulated builder fees.
public struct BuilderFeesClaimed has copy, drop, store {
    builder_code_id: ID,
    owner: address,
    amount: u64,
}

// === Public-Package Functions ===

public(package) fun emit_builder_fees_claimed(builder_code_id: ID, owner: address, amount: u64) {
    event::emit(BuilderFeesClaimed {
        builder_code_id,
        owner,
        amount,
    });
}
