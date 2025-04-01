// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

use diesel::{Identifiable, Insertable, Queryable, QueryableByName, Selectable};

use serde::Serialize;

use crate::schema::{balances_summary, pools};

#[derive(Queryable)]
pub struct OrderFillSummary {
    pub pool_id: String,
    pub maker_balance_manager_id: String,
    pub taker_balance_manager_id: String,
    pub quantity: i64,
}

#[derive(QueryableByName, Debug, Serialize)]
#[diesel(table_name = balances_summary)]
pub struct BalancesSummary {
    pub asset: String,
    pub amount: i64,
    pub deposit: bool,
}

#[derive(Queryable, Selectable, Insertable, Identifiable, Debug, Serialize)]
#[diesel(table_name = pools, primary_key(pool_id))]
pub struct Pools {
    pub pool_id: String,
    pub pool_name: String,
    pub base_asset_id: String,
    pub base_asset_decimals: i16,
    pub base_asset_symbol: String,
    pub base_asset_name: String,
    pub quote_asset_id: String,
    pub quote_asset_decimals: i16,
    pub quote_asset_symbol: String,
    pub quote_asset_name: String,
    pub min_size: i32,
    pub lot_size: i32,
    pub tick_size: i32,
}
