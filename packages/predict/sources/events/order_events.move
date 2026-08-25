// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Order-lifecycle events for Predict.
///
/// Events carry transition identities and deltas rather than account or market
/// balances. Partial closes link an old order ID to its replacement; the position
/// root remains constant across that chain.
module deepbook_predict::order_events;

use deepbook_predict::{order::Order, pricing::Pricer};
use sui::event;

/// Emitted when a live position interval is minted.
public struct OrderMinted has copy, drop, store {
    expiry_market_id: ID,
    account_id: ID,
    order_id: u256,
    /// Stable economic-position handle: the original mint's `order_id`, carried
    /// forward unchanged across partial-close replacements. Equals `order_id` here.
    position_root_id: u256,
    owner: address,
    /// Canonical strike range as absolute ticks: `lower_tick` (`0` = `-inf`) and
    /// `higher_tick` (`pos_inf_tick` = `+inf`). Raw strikes are the derived display
    /// form, `tick * tick_size` with the `tick_size` from `MarketCreated`.
    lower_tick: u64,
    higher_tick: u64,
    /// 1e9-scaled range probability quoted at entry.
    entry_probability: u64,
    quantity: u64,
    /// Premium the user paid into LP backing, in DUSDC base units.
    premium: u64,
    /// Full trading fee collected by the expiry, including any sponsor-paid subsidy.
    trading_fee: u64,
    /// Portion of `trading_fee` paid from expiry-local fee incentives.
    fee_incentive_subsidy: u64,
    builder_fee: u64,
    /// EWMA gas-price congestion surcharge retained by the pool, in DUSDC base units.
    penalty_fee: u64,
    /// Inventory-impact charge kept as ordinary expiry cash. Zero when the rate is off
    /// or the trade does not raise frozen-grid capital.
    inventory_impact_charge: u64,
    /// Frozen-grid capital before this mint, in DUSDC. Zero when the rate is off.
    k_before: u64,
    /// Frozen-grid capital after this mint, in DUSDC.
    k_after: u64,
    /// Builder credited for `builder_fee`; `none` when no builder fee was paid
    /// (attribution follows the fee — applied once, in the emit helper).
    builder_code_id: Option<ID>,
    minted_at_ms: u64,
    /// Oracle source timestamps present when this mint was priced: the provider model times the
    /// data is "as of" (the SVI one is also the roll-down anchor). Pyth is `0` only when unusable.
    pyth_spot_source_timestamp_ms: u64,
    block_scholes_spot_source_timestamp_ms: u64,
    block_scholes_forward_source_timestamp_ms: u64,
    block_scholes_svi_source_timestamp_ms: u64,
}

/// Emitted when a live position is closed fully or partially.
public struct LiveOrderRedeemed has copy, drop, store {
    expiry_market_id: ID,
    account_id: ID,
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
    /// Redeem value before fees.
    redeem_amount: u64,
    trading_fee: u64,
    builder_fee: u64,
    /// EWMA gas-price congestion surcharge retained by the pool, in DUSDC base units.
    penalty_fee: u64,
    /// Inventory-impact charge when the close raises frozen-grid capital. Zero when
    /// the close lowers it; there is no rebate.
    inventory_impact_charge: u64,
    /// Frozen-grid capital before this close, in DUSDC. Zero when the rate is off
    /// or no grid exists.
    k_before: u64,
    /// Frozen-grid capital after this close, in DUSDC.
    k_after: u64,
    /// Builder credited for `builder_fee`; `none` when no builder fee was paid
    /// (attribution follows the fee — applied once, in the emit helper).
    builder_code_id: Option<ID>,
    redeemed_at_ms: u64,
    /// Oracle source timestamps present when this redemption was priced: the provider model times
    /// the data is "as of" (the SVI one is also the roll-down anchor). Pyth is `0` only when
    /// unusable.
    pyth_spot_source_timestamp_ms: u64,
    block_scholes_spot_source_timestamp_ms: u64,
    block_scholes_forward_source_timestamp_ms: u64,
    block_scholes_svi_source_timestamp_ms: u64,
}

/// Emitted when a settled position is redeemed for terminal payout.
public struct SettledOrderRedeemed has copy, drop, store {
    expiry_market_id: ID,
    account_id: ID,
    order_id: u256,
    /// Stable economic-position handle, constant across the replacement chain.
    position_root_id: u256,
    owner: address,
    payout_amount: u64,
    redeemed_at_ms: u64,
}

// === Public-Package Functions ===

public(package) fun emit_order_minted(
    expiry_market_id: ID,
    account_id: ID,
    owner: address,
    builder_code_id: Option<ID>,
    order: &Order,
    pricer: &Pricer,
    entry_probability: u64,
    premium: u64,
    trading_fee: u64,
    fee_incentive_subsidy: u64,
    builder_fee: u64,
    penalty_fee: u64,
    inventory_impact_charge: u64,
    k_before: u64,
    k_after: u64,
    minted_at_ms: u64,
) {
    event::emit(OrderMinted {
        expiry_market_id,
        account_id,
        order_id: order.id(),
        position_root_id: order.id(),
        owner,
        lower_tick: order.lower_tick(),
        higher_tick: order.higher_tick(),
        entry_probability,
        quantity: order.quantity(),
        premium,
        trading_fee,
        fee_incentive_subsidy,
        builder_fee,
        penalty_fee,
        inventory_impact_charge,
        k_before,
        k_after,
        builder_code_id: if (builder_fee == 0) option::none() else builder_code_id,
        minted_at_ms,
        pyth_spot_source_timestamp_ms: pricer.pyth_spot_source_timestamp_ms(),
        block_scholes_spot_source_timestamp_ms: pricer.block_scholes_spot_source_timestamp_ms(),
        block_scholes_forward_source_timestamp_ms: pricer.block_scholes_forward_source_timestamp_ms(),
        block_scholes_svi_source_timestamp_ms: pricer.block_scholes_svi_source_timestamp_ms(),
    });
}

public(package) fun emit_live_order_redeemed(
    expiry_market_id: ID,
    account_id: ID,
    owner: address,
    builder_code_id: Option<ID>,
    order: &Order,
    pricer: &Pricer,
    position_root_id: u256,
    quantity_closed: u64,
    replacement_order_id: Option<u256>,
    redeem_amount: u64,
    trading_fee: u64,
    builder_fee: u64,
    penalty_fee: u64,
    inventory_impact_charge: u64,
    k_before: u64,
    k_after: u64,
    redeemed_at_ms: u64,
) {
    event::emit(LiveOrderRedeemed {
        expiry_market_id,
        account_id,
        order_id: order.id(),
        position_root_id,
        owner,
        quantity_closed,
        remaining_quantity: order.quantity() - quantity_closed,
        replacement_order_id,
        redeem_amount,
        trading_fee,
        builder_fee,
        penalty_fee,
        inventory_impact_charge,
        k_before,
        k_after,
        builder_code_id: if (builder_fee == 0) option::none() else builder_code_id,
        redeemed_at_ms,
        pyth_spot_source_timestamp_ms: pricer.pyth_spot_source_timestamp_ms(),
        block_scholes_spot_source_timestamp_ms: pricer.block_scholes_spot_source_timestamp_ms(),
        block_scholes_forward_source_timestamp_ms: pricer.block_scholes_forward_source_timestamp_ms(),
        block_scholes_svi_source_timestamp_ms: pricer.block_scholes_svi_source_timestamp_ms(),
    });
}

public(package) fun emit_settled_order_redeemed(
    expiry_market_id: ID,
    account_id: ID,
    owner: address,
    order: &Order,
    position_root_id: u256,
    payout_amount: u64,
    redeemed_at_ms: u64,
) {
    event::emit(SettledOrderRedeemed {
        expiry_market_id,
        account_id,
        order_id: order.id(),
        position_root_id,
        owner,
        payout_amount,
        redeemed_at_ms,
    });
}

#[test_only]
public fun order_minted_inventory(event: &OrderMinted): (u64, u64, u64) {
    (event.inventory_impact_charge, event.k_before, event.k_after)
}

#[test_only]
public fun live_order_redeemed_inventory(event: &LiveOrderRedeemed): (u64, u64, u64) {
    (event.inventory_impact_charge, event.k_before, event.k_after)
}
