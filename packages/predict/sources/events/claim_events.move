// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Reward and rebate claim events for Predict.
module deepbook_predict::claim_events;

use sui::event;

/// Emitted when a builder code owner claims accumulated builder fees.
public struct BuilderFeesClaimed has copy, drop, store {
    builder_code_id: ID,
    owner: address,
    amount: u64,
}

/// Emitted when an expiry trading-loss rebate is resolved for one manager.
public struct TradingLossRebateClaimed has copy, drop, store {
    expiry_market_id: ID,
    predict_manager_id: ID,
    trading_fees_paid: u64,
    gross_profit: u64,
    eligible_rebate: u64,
    rebate_amount: u64,
}

// === Public-Package Functions ===

public(package) fun emit_builder_fees_claimed(builder_code_id: ID, owner: address, amount: u64) {
    event::emit(BuilderFeesClaimed {
        builder_code_id,
        owner,
        amount,
    });
}

public(package) fun emit_trading_loss_rebate_claimed(
    expiry_market_id: ID,
    predict_manager_id: ID,
    trading_fees_paid: u64,
    gross_profit: u64,
    eligible_rebate: u64,
    rebate_amount: u64,
) {
    event::emit(TradingLossRebateClaimed {
        expiry_market_id,
        predict_manager_id,
        trading_fees_paid,
        gross_profit,
        eligible_rebate,
        rebate_amount,
    });
}
