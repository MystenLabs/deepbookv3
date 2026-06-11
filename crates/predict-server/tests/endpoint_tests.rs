// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

#[test]
#[ignore = "TODO(testnet-deploy): assert timestamp-window paging against TempDb (needs Postgres)"]
fn window_pagination_bounds_and_limit() {
    // TODO(testnet-deploy): insert order_minted rows with distinct
    // checkpoint_timestamp_ms; assert ?start_time/?end_time bound the window
    // (rows outside are excluded), the default limit is 50, and ?limit is
    // clamped to the 500 cap. Rows come back newest-first by
    // (checkpoint_timestamp_ms, tx_index, event_index) DESC.
}

#[test]
#[ignore = "TODO(testnet-deploy): assert interleaved 5-table market feed ordering against TempDb (needs Postgres)"]
fn market_feed_interleaves_all_tables() {
    // TODO(testnet-deploy): insert one row in each of the 5 order tables for one expiry_market_id
    // with interleaved (checkpoint_timestamp_ms,tx_index,event_index); GET /markets/:id/orders ->
    // all 5 rows in strict DESC order, each carrying its "kind".
}

#[test]
#[ignore = "TODO(testnet-deploy): assert manager feed excludes order_liquidated against TempDb (needs Postgres)"]
fn manager_feed_excludes_order_liquidated() {
    // TODO(testnet-deploy): order_liquidated has no predict_manager_id; insert rows in the 4
    // manager tables + 1 order_liquidated row; GET /managers/:id/orders -> only the 4 manager rows,
    // never the order_liquidated row.
}

#[test]
#[ignore = "TODO(testnet-deploy): assert single-table oracle-prices window feed against TempDb (needs Postgres)"]
fn oracle_prices_single_table_window() {
    // TODO(testnet-deploy): representative single-table window feed. Insert several
    // block_scholes_prices_updated rows for one market_oracle_id with distinct
    // (checkpoint_timestamp_ms, tx_index, event_index); GET /oracles/:id/prices -> only that
    // oracle's rows, windowed by ?start_time/?end_time, newest-first DESC, capped at ?limit, each
    // carrying "kind":"block_scholes_prices_updated".
}

#[test]
#[ignore = "TODO(testnet-deploy): assert staking merge feed against TempDb (needs Postgres)"]
fn manager_staking_merges_stake_and_unstake() {
    // TODO(testnet-deploy): representative two-table merge feed. Insert interleaved deep_staked +
    // deep_unstaked rows for one predict_manager_id; GET /managers/:id/staking -> both tables
    // interleaved in strict (checkpoint_timestamp_ms, tx_index, event_index) DESC order, each
    // carrying its "kind" ("deep_staked" / "deep_unstaked").
}
