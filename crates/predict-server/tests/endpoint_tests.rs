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

#[test]
#[ignore = "TODO(testnet-deploy): assert composed market state against TempDb (needs Postgres)"]
fn market_state_composes_latest_rows() {
    // TODO(testnet-deploy): insert market_created + two market_config_snapshot rows (different
    // triples) + mint_paused + oracle rows; GET /markets/:id/state -> "config" is the
    // newest-by-triple snapshot, oracle components resolved through market_created.market_oracle_id,
    // unknown id -> all components null.
}

#[test]
#[ignore = "TODO(testnet-deploy): assert vault state picks newest *_after across tables (needs Postgres)"]
fn vault_state_current_uses_newest_triple_across_tables() {
    // TODO(testnet-deploy): insert supply_executed (older) + expiry_cash_rebalanced (newer) for one
    // vault; GET /vaults/:id/state -> current.idle_balance_after comes from the rebalance row,
    // current.total_supply_after from the supply row (only supply/withdraw carry it).
}

#[test]
#[ignore = "TODO(testnet-deploy): assert positions endpoint root join against TempDb (needs Postgres)"]
fn manager_positions_filters_status_and_joins_root() {
    // TODO(testnet-deploy): insert order_state rows: root (status replaced, entry facts) +
    // replacement (status open, entry facts NULL, position_root_id = root). GET
    // /managers/:id/positions -> only open rows by default, replacement row carries "root" with the
    // root's entry facts; ?status=replaced returns the root row with "root": null.
}

#[test]
#[ignore = "TODO(testnet-deploy): assert open-interest sums over open rows only (needs Postgres)"]
fn market_open_interest_sums_open_rows_only() {
    // TODO(testnet-deploy): insert open + closed + liquidated order_state rows for one market; GET
    // /markets/:id/open-interest -> count/quantity/floor_shares cover only status='open' rows,
    // NUMERIC sums serialized as strings, empty market -> zeros.
}

#[test]
#[ignore = "TODO(testnet-deploy): assert MV bucket feeds window/order/limit (needs Postgres)"]
fn mv_bucket_feeds_window_and_limit() {
    // TODO(testnet-deploy): refresh market_activity_1h / vault_flows_1h / liquidation_stats_1h /
    // oracle_prices_1m over seeded raw rows; GET each feed -> buckets bounded by
    // ?start_time/?end_time, newest bucket first, default limit 50 / cap 500, each row carrying its
    // MV "kind".
}

#[test]
#[ignore = "TODO(testnet-deploy): assert /config returns latest of each config table (needs Postgres)"]
fn protocol_config_returns_latest_of_each_table() {
    // TODO(testnet-deploy): insert two pricing_config_updated rows (different triples); GET /config
    // -> "pricing" is the newer row, unseeded config kinds are null.
}
