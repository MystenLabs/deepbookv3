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
module deepbook_predict_orders::order_flow;

use account::account::Account;
use deepbook_predict::{
    expiry_market::{Self, ExpiryMarket, OrderReceipt},
    protocol_config::ProtocolConfig
};
use deepbook_predict_math::lazer_price::LazerPrice;
use propbook::{
    block_scholes_store::{BlockScholesSVIStore, BlockScholesValueStore},
    pyth_feed::PythFeed,
    registry::OracleRegistry
};
use sui::{balance::Balance, clock::Clock, deny_list::DenyList};
use usdc::usdc::USDC;

/// This companion's witness for Predict's order-flow primitives.
public struct OrderFlow() has drop;

// === Public-Package Functions ===

public(package) fun admit_mint(
    market: &mut ExpiryMarket,
    config: &ProtocolConfig,
    account: &mut Account,
    propbook_registry: &OracleRegistry,
    pyth: &PythFeed,
    bs_values: &BlockScholesValueStore,
    bs_svi: &BlockScholesSVIStore,
    kind: u8,
    lower_tick: u64,
    higher_tick: u64,
    quantity: u64,
    max_premium: u64,
    min_quantity: u64,
    max_probability: u64,
    budget: u64,
    order_fee: u64,
    svi_max_age_ms: u64,
    channel: u8,
    tau_ms: u64,
    deadline_ms: u64,
    clock: &Clock,
    ctx: &TxContext,
): OrderReceipt {
    expiry_market::admit_mint(
        OrderFlow(),
        market,
        config,
        account,
        propbook_registry,
        pyth,
        bs_values,
        bs_svi,
        kind,
        lower_tick,
        higher_tick,
        quantity,
        max_premium,
        min_quantity,
        max_probability,
        budget,
        order_fee,
        svi_max_age_ms,
        channel,
        tau_ms,
        deadline_ms,
        clock,
        ctx,
    )
}

public(package) fun admit_sell(
    market: &mut ExpiryMarket,
    config: &ProtocolConfig,
    account: &mut Account,
    receipt: &mut OrderReceipt,
    propbook_registry: &OracleRegistry,
    pyth: &PythFeed,
    bs_values: &BlockScholesValueStore,
    bs_svi: &BlockScholesSVIStore,
    close_quantity: u64,
    min_probability: u64,
    min_proceeds: u64,
    order_fee: u64,
    svi_max_age_ms: u64,
    channel: u8,
    tau_ms: u64,
    deadline_ms: u64,
    clock: &Clock,
    ctx: &TxContext,
) {
    expiry_market::admit_sell(
        OrderFlow(),
        market,
        config,
        account,
        receipt,
        propbook_registry,
        pyth,
        bs_values,
        bs_svi,
        close_quantity,
        min_probability,
        min_proceeds,
        order_fee,
        svi_max_age_ms,
        channel,
        tau_ms,
        deadline_ms,
        clock,
        ctx,
    );
}

public(package) fun commit(
    market: &mut ExpiryMarket,
    config: &ProtocolConfig,
    receipt: &mut OrderReceipt,
    price: &LazerPrice,
    clock: &Clock,
): Balance<USDC> {
    expiry_market::commit(OrderFlow(), market, config, receipt, price, clock)
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
