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
