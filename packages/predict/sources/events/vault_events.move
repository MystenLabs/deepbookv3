// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Pool-vault DEEP-staking events for Predict.
module deepbook_predict::vault_events;

use sui::event;

/// Emitted when a manager stakes DEEP for trading benefits.
public struct DeepStaked has copy, drop, store {
    pool_vault_id: ID,
    predict_manager_id: ID,
    amount: u64,
    /// Manager active/inactive stake after the deposit. Freshly staked DEEP is
    /// inactive until it rolls active in a later epoch, so both are reported.
    active_stake_after: u64,
    inactive_stake_after: u64,
}

/// Emitted when a manager unstakes all of its DEEP (active and inactive).
public struct DeepUnstaked has copy, drop, store {
    pool_vault_id: ID,
    predict_manager_id: ID,
    amount: u64,
}

// === Public-Package Functions ===

public(package) fun emit_deep_staked(
    pool_vault_id: ID,
    predict_manager_id: ID,
    amount: u64,
    active_stake_after: u64,
    inactive_stake_after: u64,
) {
    event::emit(DeepStaked {
        pool_vault_id,
        predict_manager_id,
        amount,
        active_stake_after,
        inactive_stake_after,
    });
}

public(package) fun emit_deep_unstaked(pool_vault_id: ID, predict_manager_id: ID, amount: u64) {
    event::emit(DeepUnstaked {
        pool_vault_id,
        predict_manager_id,
        amount,
    });
}
