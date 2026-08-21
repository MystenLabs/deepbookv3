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
    /// Full trading fee assessed for the mint, including any sponsor-paid subsidy.
    trading_fee: u64,
    /// Portion of `trading_fee` paid from expiry-local fee incentives.
    fee_incentive_subsidy: u64,
    builder_fee: u64,
    /// EWMA gas-price congestion surcharge assessed for the mint, in DUSDC base units.
    penalty_fee: u64,
    /// Portion of the trader-paid trading fee and congestion surcharge delivered
    /// to the referrer.
    referral_fee: u64,
    /// Separate inventory-impact charge escrowed for live-close rebates.
    inventory_impact_charge: u64,
    /// Inventory-skew amounts for this mint; at most one is nonzero. A rebate
    /// reduces the withdrawal rather than paying the trader.
    skew_charge: u64,
    skew_rebate: u64,
    /// Builder credited for `builder_fee`; `none` when no builder fee was paid
    /// (attribution follows the fee — applied once, in the emit helper).
    builder_code_id: Option<ID>,
    /// Referrer recorded on the minting account, independent of the fee paid.
    referrer_account_id: Option<ID>,
    onchain_timestamp_ms: u64,
    /// Oracle source timestamps present when this mint was priced: Pyth's canonical source time
    /// and the Block Scholes batch-envelope times used for freshness. The SVI one is also the
    /// roll-down anchor. Pyth is `0` only when unusable.
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
    /// Separate inventory-impact rebate paid from its isolated escrow.
    inventory_impact_rebate: u64,
    /// Inventory-skew amounts for this close; at most one is nonzero. A close
    /// that unbalances the book is charged rather than rebated.
    skew_charge: u64,
    skew_rebate: u64,
    /// Builder credited for `builder_fee`; `none` when no builder fee was paid
    /// (attribution follows the fee — applied once, in the emit helper).
    builder_code_id: Option<ID>,
    onchain_timestamp_ms: u64,
    /// Oracle source timestamps present when this redemption was priced: Pyth's canonical source
    /// time and the Block Scholes batch-envelope times used for freshness. The SVI one is also the
    /// roll-down anchor. Pyth is `0` only when unusable.
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
    onchain_timestamp_ms: u64,
}

// === Public-Package Functions ===

public(package) fun emit_order_minted(
    expiry_market_id: ID,
    account_id: ID,
    owner: address,
    builder_code_id: Option<ID>,
    referrer_account_id: Option<ID>,
    order: &Order,
    pricer: &Pricer,
    entry_probability: u64,
    premium: u64,
    trading_fee: u64,
    fee_incentive_subsidy: u64,
    builder_fee: u64,
    penalty_fee: u64,
    referral_fee: u64,
    inventory_impact_charge: u64,
    skew_charge: u64,
    skew_rebate: u64,
    onchain_timestamp_ms: u64,
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
        referral_fee,
        inventory_impact_charge,
        skew_charge,
        skew_rebate,
        builder_code_id: if (builder_fee == 0) option::none() else builder_code_id,
        referrer_account_id,
        onchain_timestamp_ms,
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
    inventory_impact_rebate: u64,
    skew_charge: u64,
    skew_rebate: u64,
    onchain_timestamp_ms: u64,
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
        inventory_impact_rebate,
        skew_charge,
        skew_rebate,
        builder_code_id: if (builder_fee == 0) option::none() else builder_code_id,
        onchain_timestamp_ms,
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
    onchain_timestamp_ms: u64,
) {
    event::emit(SettledOrderRedeemed {
        expiry_market_id,
        account_id,
        order_id: order.id(),
        position_root_id,
        owner,
        payout_amount,
        onchain_timestamp_ms,
    });
}
