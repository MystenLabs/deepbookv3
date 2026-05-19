// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

module deepbook_predict::deploy_scripts;

use deepbook_predict::registry::{Self, Registry, AdminCap};
use deepbook_predict::predict::Predict;
use deepbook_predict::oracle::OracleSVICap;
use sui::clock::Clock;
use sui::coin::TreasuryCap;
use sui::coin_registry::Currency;
use deepbook_predict::plp::PLP;
use std::string::String;

/// Helper to create Predict and an initial oracle cap in one transaction.
entry fun setup_protocol<Quote>(
    registry: &mut Registry,
    admin_cap: &AdminCap,
    currency: &Currency<Quote>,
    treasury_cap: TreasuryCap<PLP>,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    registry::create_predict<Quote>(registry, admin_cap, currency, treasury_cap, clock, ctx);
    let oracle_cap = registry::create_oracle_cap(admin_cap, ctx);
    transfer::public_transfer(oracle_cap, ctx.sender());
}

/// Helper to register an asset and create its first oracle.
entry fun add_asset_and_oracle(
    registry: &mut Registry,
    predict: &mut Predict,
    admin_cap: &AdminCap,
    oracle_cap: &OracleSVICap,
    asset: String,
    feed_id: u64,
    expiry: u64,
    min_strike: u64,
    tick_size: u64,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    registry::set_asset_feed_id(predict, admin_cap, asset, feed_id);
    registry::create_oracle(
        registry,
        predict,
        oracle_cap,
        asset,
        expiry,
        min_strike,
        tick_size,
        clock,
        ctx
    );
}
