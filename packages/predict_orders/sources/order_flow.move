// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// The companion's authority over Predict's order-flow primitives.
///
/// Predict lets admission, commit, and fills run only for an allowlisted witness
/// type (`protocol_config::set_order_flow<OrderFlow>`). This module defines that
/// witness and is the only place that builds it: each Predict call that needs
/// it goes through a package-only function here, so no caller outside this
/// package can obtain the witness or reach Predict with it. `release` and
/// `try_pay_settled` need no authority and are called directly.
///
/// Admission takes an optional `BuilderFee` and passes it to Predict's
/// oracle-free `_v2` admission, which records the code and the capped fee in the
/// receipt for the fill. An order that names none pays no builder fee.
module deepbook_predict_orders::order_flow;

use account::account::Account;
use deepbook_predict::{
    builder_code::BuilderFee,
    expiry_market::{Self, ExpiryMarket, OrderReceipt},
    protocol_config::ProtocolConfig
};
use deepbook_predict_math::{block_scholes::BsVol, lazer_price::LazerPrice};
use sui::{balance::Balance, clock::Clock, deny_list::DenyList};
use usdc::usdc::USDC;

/// This companion's witness for Predict's order-flow primitives.
public struct OrderFlow() has drop;

// === Public-Package Functions ===

public(package) fun admit_mint(
    market: &mut ExpiryMarket,
    config: &ProtocolConfig,
    account: &mut Account,
    builder: Option<BuilderFee>,
    kind: u8,
    lower_tick: u64,
    higher_tick: u64,
    quantity: u64,
    max_premium: u64,
    min_quantity: u64,
    max_probability: u64,
    budget: u64,
    order_fee: u64,
    channel: u8,
    tau_ms: u64,
    deadline_ms: u64,
    clock: &Clock,
): OrderReceipt {
    expiry_market::admit_mint_v2(
        OrderFlow(),
        market,
        config,
        account,
        builder,
        kind,
        lower_tick,
        higher_tick,
        quantity,
        max_premium,
        min_quantity,
        max_probability,
        budget,
        order_fee,
        channel,
        tau_ms,
        deadline_ms,
        clock,
    )
}

public(package) fun admit_sell(
    market: &mut ExpiryMarket,
    config: &ProtocolConfig,
    account: &mut Account,
    receipt: &mut OrderReceipt,
    builder: Option<BuilderFee>,
    close_quantity: u64,
    min_probability: u64,
    min_proceeds: u64,
    order_fee: u64,
    channel: u8,
    tau_ms: u64,
    deadline_ms: u64,
    clock: &Clock,
) {
    expiry_market::admit_sell_v2(
        OrderFlow(),
        market,
        config,
        account,
        receipt,
        builder,
        close_quantity,
        min_probability,
        min_proceeds,
        order_fee,
        channel,
        tau_ms,
        deadline_ms,
        clock,
    );
}

public(package) fun commit(
    market: &mut ExpiryMarket,
    config: &ProtocolConfig,
    receipt: &mut OrderReceipt,
    price: &LazerPrice,
    vol: &BsVol,
    clock: &Clock,
): Balance<USDC> {
    expiry_market::commit_v2(OrderFlow(), market, config, receipt, price, vol, clock)
}

public(package) fun try_fill(
    market: &mut ExpiryMarket,
    config: &ProtocolConfig,
    receipt: OrderReceipt,
    escrow: Balance<USDC>,
    deny_list: &DenyList,
    clock: &Clock,
    ctx: &TxContext,
): (u8, Option<OrderReceipt>, Balance<USDC>, u64, u64, u64, u64, u64, u64, u64) {
    expiry_market::try_fill(OrderFlow(), market, config, receipt, escrow, deny_list, clock, ctx)
}
