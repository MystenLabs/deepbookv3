// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Account, manager, and builder-code lifecycle events for Predict.
module deepbook_predict::account_events;

use sui::event;

/// Emitted when a derived PredictManager is created.
public struct PredictManagerCreated has copy, drop, store {
    predict_manager_id: ID,
    /// Inner BalanceManager that holds DUSDC custody. Its ID is random (not
    /// derived), so off-chain consumers need it here to join DeepBook
    /// `BalanceEvent` deposit/withdraw flows back to this manager.
    balance_manager_id: ID,
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

/// Emitted when a `PredictTradeCap` is minted.
public struct PredictTradeCapMinted has copy, drop, store {
    predict_manager_id: ID,
    cap_id: ID,
}

/// Emitted when a `PredictDepositCap` is minted.
public struct PredictDepositCapMinted has copy, drop, store {
    predict_manager_id: ID,
    cap_id: ID,
}

/// Emitted when a `PredictWithdrawCap` is minted.
public struct PredictWithdrawCapMinted has copy, drop, store {
    predict_manager_id: ID,
    cap_id: ID,
}

// === Public-Package Functions ===

public(package) fun emit_predict_manager_created(
    predict_manager_id: ID,
    balance_manager_id: ID,
    owner: address,
) {
    event::emit(PredictManagerCreated {
        predict_manager_id,
        balance_manager_id,
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

public(package) fun emit_predict_trade_cap_minted(predict_manager_id: ID, cap_id: ID) {
    event::emit(PredictTradeCapMinted { predict_manager_id, cap_id });
}

public(package) fun emit_predict_deposit_cap_minted(predict_manager_id: ID, cap_id: ID) {
    event::emit(PredictDepositCapMinted { predict_manager_id, cap_id });
}

public(package) fun emit_predict_withdraw_cap_minted(predict_manager_id: ID, cap_id: ID) {
    event::emit(PredictWithdrawCapMinted { predict_manager_id, cap_id });
}
