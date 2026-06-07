// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Order-lifecycle and liquidation events for Predict.
///
/// Hot-path events stay lean: each carries the deltas and identities a consumer
/// needs to reconstruct money flows off-chain, with no absolute balances.
/// `order_id` joins minted, redeemed, and liquidated rows for one position;
/// the network envelope supplies timestamp and sender, so neither is a field.
module deepbook_predict::order_events;

use deepbook_predict::{order::Order, predict_manager::PredictManager};
use sui::event;

/// Emitted when a live position interval is minted.
public struct OrderMinted has copy, drop, store {
    expiry_market_id: ID,
    predict_manager_id: ID,
    order_id: u256,
    /// Stable economic-position handle: the original mint's `order_id`, carried
    /// forward unchanged across partial-close replacements. Equals `order_id` here.
    position_root_id: u256,
    owner: address,
    lower_strike: u64,
    higher_strike: u64,
    leverage: u64,
    /// 1e9-scaled range probability quoted at entry.
    entry_probability: u64,
    quantity: u64,
    /// User cash contributed into LP backing, in DUSDC base units.
    contribution: u64,
    trading_fee: u64,
    builder_fee: u64,
    /// EWMA gas-price congestion surcharge retained by the pool, in DUSDC base units.
    penalty_fee: u64,
    builder_code_id: Option<ID>,
}

/// Emitted when a live position is closed fully or partially.
public struct LiveOrderRedeemed has copy, drop, store {
    expiry_market_id: ID,
    predict_manager_id: ID,
    order_id: u256,
    /// Stable economic-position handle, constant across the replacement chain.
    /// On a partial close the replacement inherits this same root.
    position_root_id: u256,
    owner: address,
    quantity_closed: u64,
    /// `0` means the position was fully closed.
    remaining_quantity: u64,
    /// New order ID minted to carry the remainder on a partial live close.
    replacement_order_id: Option<u256>,
    /// Redeem value before fees, after any floor deduction.
    redeem_amount: u64,
    trading_fee: u64,
    builder_fee: u64,
    /// EWMA gas-price congestion surcharge retained by the pool, in DUSDC base units.
    penalty_fee: u64,
    builder_code_id: Option<ID>,
}

/// Emitted when a settled position is redeemed for terminal payout.
public struct SettledOrderRedeemed has copy, drop, store {
    expiry_market_id: ID,
    predict_manager_id: ID,
    order_id: u256,
    /// Stable economic-position handle, constant across the replacement chain.
    position_root_id: u256,
    owner: address,
    quantity_closed: u64,
    settlement_price: u64,
    payout_amount: u64,
}

/// Emitted when a manager clears a liquidated position with zero payout.
public struct LiquidatedOrderRedeemed has copy, drop, store {
    expiry_market_id: ID,
    predict_manager_id: ID,
    order_id: u256,
    /// Stable economic-position handle, constant across the replacement chain.
    position_root_id: u256,
    owner: address,
    quantity_closed: u64,
}

/// Emitted once per order removed by liquidation.
///
/// Liquidation is permissionless and does not touch managers, so manager/owner
/// are not known here; consumers join `order_id` to `OrderMinted`.
public struct OrderLiquidated has copy, drop, store {
    expiry_market_id: ID,
    order_id: u256,
    quantity: u64,
    /// Probability-weighted value checked against the liquidation threshold.
    gross_value: u64,
    /// Current contract floor in DUSDC base units.
    floor_amount: u64,
    /// 1e9-scaled floor-to-live-value threshold used for this expiry.
    liquidation_ltv: u64,
}

// === Public-Package Functions ===

public(package) fun emit_order_minted(
    expiry_market_id: ID,
    manager: &PredictManager,
    order: &Order,
    lower_strike: u64,
    higher_strike: u64,
    leverage: u64,
    entry_probability: u64,
    contribution: u64,
    trading_fee: u64,
    builder_fee: u64,
    penalty_fee: u64,
) {
    event::emit(OrderMinted {
        expiry_market_id,
        predict_manager_id: manager.id(),
        order_id: order.id(),
        position_root_id: order.id(),
        owner: manager.owner(),
        lower_strike,
        higher_strike,
        leverage,
        entry_probability,
        quantity: order.quantity(),
        contribution,
        trading_fee,
        builder_fee,
        penalty_fee,
        builder_code_id: if (builder_fee == 0) option::none() else manager.builder_code_id(),
    });
}

public(package) fun emit_live_order_redeemed(
    expiry_market_id: ID,
    manager: &PredictManager,
    order: &Order,
    position_root_id: u256,
    quantity_closed: u64,
    replacement_order_id: Option<u256>,
    redeem_amount: u64,
    trading_fee: u64,
    builder_fee: u64,
    penalty_fee: u64,
) {
    event::emit(LiveOrderRedeemed {
        expiry_market_id,
        predict_manager_id: manager.id(),
        order_id: order.id(),
        position_root_id,
        owner: manager.owner(),
        quantity_closed,
        remaining_quantity: order.quantity() - quantity_closed,
        replacement_order_id,
        redeem_amount,
        trading_fee,
        builder_fee,
        penalty_fee,
        builder_code_id: if (builder_fee == 0) option::none() else manager.builder_code_id(),
    });
}

public(package) fun emit_settled_order_redeemed(
    expiry_market_id: ID,
    manager: &PredictManager,
    order: &Order,
    position_root_id: u256,
    settlement_price: u64,
    payout_amount: u64,
) {
    event::emit(SettledOrderRedeemed {
        expiry_market_id,
        predict_manager_id: manager.id(),
        order_id: order.id(),
        position_root_id,
        owner: manager.owner(),
        quantity_closed: order.quantity(),
        settlement_price,
        payout_amount,
    });
}

public(package) fun emit_liquidated_order_redeemed(
    expiry_market_id: ID,
    manager: &PredictManager,
    order: &Order,
    position_root_id: u256,
) {
    event::emit(LiquidatedOrderRedeemed {
        expiry_market_id,
        predict_manager_id: manager.id(),
        order_id: order.id(),
        position_root_id,
        owner: manager.owner(),
        quantity_closed: order.quantity(),
    });
}

public(package) fun emit_order_liquidated(
    expiry_market_id: ID,
    order: &Order,
    quantity: u64,
    gross_value: u64,
    floor_amount: u64,
    liquidation_ltv: u64,
) {
    event::emit(OrderLiquidated {
        expiry_market_id,
        order_id: order.id(),
        quantity,
        gross_value,
        floor_amount,
        liquidation_ltv,
    });
}
