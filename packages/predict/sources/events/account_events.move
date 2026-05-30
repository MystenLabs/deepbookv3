// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Account, manager, and builder-code lifecycle events for Predict.
module deepbook_predict::account_events;

use sui::event;

/// Emitted when a derived PredictManager is created.
public struct PredictManagerCreated has copy, drop, store {
    predict_manager_id: ID,
    owner: address,
}

/// Emitted when a derived BuilderCode is created.
public struct BuilderCodeCreated has copy, drop, store {
    builder_code_id: ID,
    owner: address,
    builder_code_index: u64,
}

/// Emitted when a manager owner changes sticky builder-code attribution.
public struct BuilderCodeSet has copy, drop, store {
    predict_manager_id: ID,
    owner: address,
    builder_code_id: Option<ID>,
}

// === Public-Package Functions ===

public(package) fun emit_predict_manager_created(predict_manager_id: ID, owner: address) {
    event::emit(PredictManagerCreated {
        predict_manager_id,
        owner,
    });
}

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
    predict_manager_id: ID,
    owner: address,
    builder_code_id: Option<ID>,
) {
    event::emit(BuilderCodeSet {
        predict_manager_id,
        owner,
        builder_code_id,
    });
}
