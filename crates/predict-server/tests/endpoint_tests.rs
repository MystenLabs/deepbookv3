// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

//! Endpoint tests against a real Postgres (`TempDb`): each test runs the
//! embedded migrations, seeds hand-built rows with direct Diesel inserts, and
//! drives the real axum router (`make_router`) with in-process requests.
//!
//! Expected pages are hand-built from the documented endpoint contracts
//! (timestamp window `[start_time, end_time]` in unix seconds, default limit
//! 50 / cap 500, newest-first by `(checkpoint_timestamp_ms, checkpoint,
//! tx_index, event_index)`), never re-derived through the reader.

use axum::body::Body;
use axum::http::{Request, StatusCode};
use axum::Router;
use bigdecimal::BigDecimal;
use diesel::ExpressionMethods;
use diesel_async::RunQueryDsl;
use http_body_util::BodyExt;
use predict_schema::models::lp_request_status;
use predict_schema::models::order_status as status;
use predict_schema::models::{
    DeepStaked, DeepUnstaked, ExpiryCashRebalanced, ExpiryMarketMintPausedUpdated, FlushExecuted,
    LiquidatedOrderRedeemed, LiveOrderRedeemed, LpRequestState, MarketConfigSnapshot,
    MarketCreated, MarketSettled, OrderLiquidated, OrderMinted, OrderState, PricingConfigUpdated,
    SettledOrderRedeemed, SupplyFilled, SupplyRequested, WithdrawFilled, WithdrawRequested,
};
use predict_schema::schema;
use predict_server::server::{make_router, AppState};
use prometheus::Registry;
use serde_json::Value;
use std::sync::Arc;
use std::time::{SystemTime, UNIX_EPOCH};
use sui_pg_db::temp::TempDb;
use sui_pg_db::{Db, DbArgs};
use tower::ServiceExt;
use url::Url;

const MARKET: &str = "0xmarket-1";
const MANAGER: &str = "0xmanager-1";
const VAULT: &str = "0xvault-1";
const OWNER: &str = "0xowner-1";
const SENDER: &str = "0xsender";
const PKG: &str = "0xpkg";

/// Fixture base time (2023-11-14T22:13:20Z). Far enough in the past that the
/// default `end_time` (= now) always includes fixture rows, and second-aligned
/// so `?start_time`/`?end_time` (unix seconds) can hit exact boundaries.
const T0_MS: i64 = 1_700_000_000_000;
const T0_S: i64 = 1_700_000_000;

fn bd(v: i64) -> BigDecimal {
    BigDecimal::from(v)
}

/// Fresh migrated database plus the real router over it. The `TempDb` must
/// stay in scope for the whole test, otherwise the postgres process is torn
/// down.
async fn setup() -> (TempDb, Db, Router) {
    let temp_db = TempDb::new().expect("postgres binaries (initdb/postgres) must be on PATH");
    let url: Url = temp_db.database().url().clone();
    let db = Db::for_write(url.clone(), DbArgs::default()).await.unwrap();
    db.run_migrations(Some(&predict_schema::MIGRATIONS))
        .await
        .unwrap();

    let registry = Registry::new();
    // The rpc_url is only dialed by /status, which these tests never hit.
    let rpc_url: Url = "http://localhost:1/".parse().unwrap();
    let state = AppState::new(url, DbArgs::default(), &registry, rpc_url)
        .await
        .unwrap();
    (temp_db, db, make_router(Arc::new(state)))
}

/// GET `uri` through the router, asserting 200 and parsing the JSON body.
async fn get(router: &Router, uri: &str) -> Value {
    let response = router
        .clone()
        .oneshot(Request::builder().uri(uri).body(Body::empty()).unwrap())
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::OK, "GET {uri}");
    let body = response.into_body().collect().await.unwrap().to_bytes();
    serde_json::from_slice(&body).unwrap()
}

/// Insert rows into `schema::$table`.
macro_rules! seed {
    ($db:expr, $table:ident, $rows:expr) => {{
        let mut conn = $db.connect().await.unwrap();
        diesel::insert_into(schema::$table::table)
            .values($rows)
            .execute(&mut conn)
            .await
            .unwrap();
    }};
}

fn str_col<'a>(page: &'a Value, field: &str) -> Vec<&'a str> {
    page.as_array()
        .unwrap()
        .iter()
        .map(|r| r[field].as_str().unwrap())
        .collect()
}

fn i64_col(page: &Value, field: &str) -> Vec<i64> {
    page.as_array()
        .unwrap()
        .iter()
        .map(|r| r[field].as_i64().unwrap())
        .collect()
}

fn triples(page: &Value) -> Vec<(i64, i64, i64)> {
    page.as_array()
        .unwrap()
        .iter()
        .map(|r| {
            (
                r["checkpoint"].as_i64().unwrap(),
                r["tx_index"].as_i64().unwrap(),
                r["event_index"].as_i64().unwrap(),
            )
        })
        .collect()
}

// === Row builders (event header boilerplate filled deterministically) ===

fn order_minted_row(
    tag: &str,
    market: &str,
    manager: &str,
    (checkpoint, tx_index, event_index): (i64, i64, i64),
    ts_ms: i64,
) -> OrderMinted {
    OrderMinted {
        event_digest: format!("mint-{tag}"),
        digest: format!("d-mint-{tag}"),
        sender: SENDER.into(),
        checkpoint,
        tx_index,
        event_index,
        checkpoint_timestamp_ms: ts_ms,
        package: PKG.into(),
        expiry_market_id: market.into(),
        predict_manager_id: manager.into(),
        order_id: tag.into(),
        position_root_id: tag.into(),
        owner: OWNER.into(),
        lower_tick: 3,
        higher_tick: 7,
        leverage: 1_000_000_000,
        entry_probability: 450_000_000,
        quantity: bd(70_000),
        net_premium: bd(54),
        trading_fee: bd(7),
        builder_fee: bd(2),
        penalty_fee: bd(1),
        builder_code_id: None,
    }
}

fn live_redeemed_row(
    tag: &str,
    market: &str,
    manager: &str,
    (checkpoint, tx_index, event_index): (i64, i64, i64),
    ts_ms: i64,
) -> LiveOrderRedeemed {
    LiveOrderRedeemed {
        event_digest: format!("live-{tag}"),
        digest: format!("d-live-{tag}"),
        sender: SENDER.into(),
        checkpoint,
        tx_index,
        event_index,
        checkpoint_timestamp_ms: ts_ms,
        package: PKG.into(),
        expiry_market_id: market.into(),
        predict_manager_id: manager.into(),
        order_id: tag.into(),
        position_root_id: tag.into(),
        owner: OWNER.into(),
        quantity_closed: bd(50_000),
        remaining_quantity: bd(20_000),
        replacement_order_id: None,
        redeem_amount: bd(20),
        trading_fee: bd(1),
        builder_fee: bd(0),
        penalty_fee: bd(0),
        builder_code_id: None,
    }
}

fn settled_redeemed_row(
    tag: &str,
    market: &str,
    manager: &str,
    (checkpoint, tx_index, event_index): (i64, i64, i64),
    ts_ms: i64,
) -> SettledOrderRedeemed {
    SettledOrderRedeemed {
        event_digest: format!("settled-{tag}"),
        digest: format!("d-settled-{tag}"),
        sender: SENDER.into(),
        checkpoint,
        tx_index,
        event_index,
        checkpoint_timestamp_ms: ts_ms,
        package: PKG.into(),
        expiry_market_id: market.into(),
        predict_manager_id: manager.into(),
        order_id: tag.into(),
        position_root_id: tag.into(),
        owner: OWNER.into(),
        quantity_closed: bd(70_000),
        settlement_price: bd(99_000),
        payout_amount: bd(120),
    }
}

fn liquidated_redeemed_row(
    tag: &str,
    market: &str,
    manager: &str,
    (checkpoint, tx_index, event_index): (i64, i64, i64),
    ts_ms: i64,
) -> LiquidatedOrderRedeemed {
    LiquidatedOrderRedeemed {
        event_digest: format!("liqred-{tag}"),
        digest: format!("d-liqred-{tag}"),
        sender: SENDER.into(),
        checkpoint,
        tx_index,
        event_index,
        checkpoint_timestamp_ms: ts_ms,
        package: PKG.into(),
        expiry_market_id: market.into(),
        predict_manager_id: manager.into(),
        order_id: tag.into(),
        position_root_id: tag.into(),
        owner: OWNER.into(),
        quantity_closed: bd(70_000),
    }
}

fn order_liquidated_row(
    tag: &str,
    market: &str,
    (checkpoint, tx_index, event_index): (i64, i64, i64),
    ts_ms: i64,
) -> OrderLiquidated {
    OrderLiquidated {
        event_digest: format!("liq-{tag}"),
        digest: format!("d-liq-{tag}"),
        sender: SENDER.into(),
        checkpoint,
        tx_index,
        event_index,
        checkpoint_timestamp_ms: ts_ms,
        package: PKG.into(),
        expiry_market_id: market.into(),
        order_id: tag.into(),
        quantity: bd(70_000),
        gross_value: bd(30),
        floor_amount: bd(28),
        liquidation_ltv: 900_000_000,
    }
}

fn staked_row(tag: &str, manager: &str, checkpoint: i64, ts_ms: i64) -> DeepStaked {
    DeepStaked {
        event_digest: format!("stake-{tag}"),
        digest: format!("d-stake-{tag}"),
        sender: SENDER.into(),
        checkpoint,
        tx_index: 0,
        event_index: 0,
        checkpoint_timestamp_ms: ts_ms,
        package: PKG.into(),
        pool_vault_id: VAULT.into(),
        predict_manager_id: manager.into(),
        amount: bd(10),
        active_stake_after: bd(10),
        inactive_stake_after: bd(0),
    }
}

fn unstaked_row(tag: &str, manager: &str, checkpoint: i64, ts_ms: i64) -> DeepUnstaked {
    DeepUnstaked {
        event_digest: format!("unstake-{tag}"),
        digest: format!("d-unstake-{tag}"),
        sender: SENDER.into(),
        checkpoint,
        tx_index: 0,
        event_index: 0,
        checkpoint_timestamp_ms: ts_ms,
        package: PKG.into(),
        pool_vault_id: VAULT.into(),
        predict_manager_id: manager.into(),
        amount: bd(5),
    }
}

fn market_created_row(market: &str, checkpoint: i64, ts_ms: i64) -> MarketCreated {
    MarketCreated {
        event_digest: format!("mkt-{market}"),
        digest: format!("d-mkt-{market}"),
        sender: SENDER.into(),
        checkpoint,
        tx_index: 0,
        event_index: 0,
        checkpoint_timestamp_ms: ts_ms,
        package: PKG.into(),
        expiry_market_id: market.into(),
        pool_vault_id: VAULT.into(),
        propbook_underlying_id: 42,
        expiry: T0_MS + 86_400_000,
        tick_size: bd(1_000),
    }
}

fn config_snapshot_row(
    tag: &str,
    market: &str,
    checkpoint: i64,
    ts_ms: i64,
    base_fee: i64,
) -> MarketConfigSnapshot {
    MarketConfigSnapshot {
        event_digest: format!("cfg-{tag}"),
        digest: format!("d-cfg-{tag}"),
        sender: SENDER.into(),
        checkpoint,
        tx_index: 0,
        event_index: 0,
        checkpoint_timestamp_ms: ts_ms,
        package: PKG.into(),
        expiry_market_id: market.into(),
        terminal_floor_index: 3,
        liquidation_ltv: 900_000_000,
        backing_buffer_lambda: 500_000_000,
        base_fee: bd(base_fee),
        min_fee: bd(1),
        min_ask_price: bd(10),
        max_ask_price: bd(990),
        expiry_fee_window_ms: 3_600_000,
        expiry_fee_max_multiplier: 4,
        trading_loss_rebate_rate: 100_000_000,
    }
}

fn mint_paused_row(
    market: &str,
    paused: bool,
    checkpoint: i64,
    ts_ms: i64,
) -> ExpiryMarketMintPausedUpdated {
    ExpiryMarketMintPausedUpdated {
        event_digest: format!("pause-{market}-{checkpoint}"),
        digest: format!("d-pause-{market}-{checkpoint}"),
        sender: SENDER.into(),
        checkpoint,
        tx_index: 0,
        event_index: 0,
        checkpoint_timestamp_ms: ts_ms,
        package: PKG.into(),
        expiry_market_id: market.into(),
        paused,
    }
}

fn market_settled_row(
    market: &str,
    checkpoint: i64,
    ts_ms: i64,
    settlement_price: i64,
) -> MarketSettled {
    MarketSettled {
        event_digest: format!("settled-{market}-{checkpoint}"),
        digest: format!("d-settled-{market}-{checkpoint}"),
        sender: SENDER.into(),
        checkpoint,
        tx_index: 0,
        event_index: 0,
        checkpoint_timestamp_ms: ts_ms,
        package: PKG.into(),
        expiry_market_id: market.into(),
        propbook_underlying_id: 42,
        expiry: T0_MS + 86_400_000,
        settlement_price: bd(settlement_price),
        settled_at_ms: ts_ms,
    }
}

fn supply_requested_row(
    tag: &str,
    vault: &str,
    manager: &str,
    request_index: i64,
    checkpoint: i64,
    ts_ms: i64,
) -> SupplyRequested {
    SupplyRequested {
        event_digest: format!("sreq-{tag}"),
        digest: format!("d-sreq-{tag}"),
        sender: SENDER.into(),
        checkpoint,
        tx_index: 0,
        event_index: 0,
        checkpoint_timestamp_ms: ts_ms,
        package: PKG.into(),
        pool_vault_id: vault.into(),
        predict_manager_id: manager.into(),
        recipient: OWNER.into(),
        request_index,
        amount: bd(100),
    }
}

fn withdraw_requested_row(
    tag: &str,
    vault: &str,
    manager: &str,
    request_index: i64,
    checkpoint: i64,
    ts_ms: i64,
) -> WithdrawRequested {
    WithdrawRequested {
        event_digest: format!("wreq-{tag}"),
        digest: format!("d-wreq-{tag}"),
        sender: SENDER.into(),
        checkpoint,
        tx_index: 0,
        event_index: 0,
        checkpoint_timestamp_ms: ts_ms,
        package: PKG.into(),
        pool_vault_id: vault.into(),
        predict_manager_id: manager.into(),
        recipient: OWNER.into(),
        request_index,
        amount: bd(50),
    }
}

fn supply_filled_row(
    tag: &str,
    vault: &str,
    manager: &str,
    request_index: i64,
    checkpoint: i64,
    ts_ms: i64,
) -> SupplyFilled {
    SupplyFilled {
        event_digest: format!("sfill-{tag}"),
        digest: format!("d-sfill-{tag}"),
        sender: SENDER.into(),
        checkpoint,
        tx_index: 0,
        event_index: 0,
        checkpoint_timestamp_ms: ts_ms,
        package: PKG.into(),
        pool_vault_id: vault.into(),
        predict_manager_id: manager.into(),
        recipient: OWNER.into(),
        request_index,
        dusdc_amount: bd(100),
        shares_minted: bd(99),
    }
}

fn withdraw_filled_row(
    tag: &str,
    vault: &str,
    manager: &str,
    request_index: i64,
    checkpoint: i64,
    ts_ms: i64,
) -> WithdrawFilled {
    WithdrawFilled {
        event_digest: format!("wfill-{tag}"),
        digest: format!("d-wfill-{tag}"),
        sender: SENDER.into(),
        checkpoint,
        tx_index: 0,
        event_index: 0,
        checkpoint_timestamp_ms: ts_ms,
        package: PKG.into(),
        pool_vault_id: vault.into(),
        predict_manager_id: manager.into(),
        recipient: OWNER.into(),
        request_index,
        shares_burned: bd(50),
        dusdc_amount: bd(51),
    }
}

fn flush_row(
    tag: &str,
    vault: &str,
    checkpoint: i64,
    ts_ms: i64,
    pool_value: i64,
    total_supply: i64,
    idle_after: i64,
) -> FlushExecuted {
    FlushExecuted {
        event_digest: format!("flush-{tag}"),
        digest: format!("d-flush-{tag}"),
        sender: SENDER.into(),
        checkpoint,
        tx_index: 0,
        event_index: 0,
        checkpoint_timestamp_ms: ts_ms,
        package: PKG.into(),
        pool_vault_id: vault.into(),
        epoch: 1,
        pool_value: bd(pool_value),
        total_supply: bd(total_supply),
        active_market_nav: bd(0),
        market_count: 0,
        idle_balance_before: bd(idle_after),
        supplies_filled: 1,
        withdrawals_filled: 0,
        requests_processed: 1,
        idle_balance_after: bd(idle_after),
    }
}

fn rebalance_row(
    tag: &str,
    vault: &str,
    checkpoint: i64,
    ts_ms: i64,
    idle_after: i64,
) -> ExpiryCashRebalanced {
    ExpiryCashRebalanced {
        event_digest: format!("rebal-{tag}"),
        digest: format!("d-rebal-{tag}"),
        sender: SENDER.into(),
        checkpoint,
        tx_index: 0,
        event_index: 0,
        checkpoint_timestamp_ms: ts_ms,
        package: PKG.into(),
        pool_vault_id: vault.into(),
        expiry_market_id: MARKET.into(),
        amount: bd(50),
        to_expiry: true,
        target_cash: bd(50),
        expiry_cash_after: bd(50),
        idle_balance_after: bd(idle_after),
        sent_to_expiry_after: bd(50),
        received_from_expiry_after: bd(0),
        protocol_reserve_balance_after: bd(77),
        pending_protocol_profit_after: bd(7),
    }
}

fn pricing_config_row(
    tag: &str,
    checkpoint: i64,
    ts_ms: i64,
    freshness_ms: i64,
) -> PricingConfigUpdated {
    PricingConfigUpdated {
        event_digest: format!("pricing-{tag}"),
        digest: format!("d-pricing-{tag}"),
        sender: SENDER.into(),
        checkpoint,
        tx_index: 0,
        event_index: 0,
        checkpoint_timestamp_ms: ts_ms,
        package: PKG.into(),
        protocol_config_id: "0xprotocol-config".into(),
        pyth_spot_freshness_ms: freshness_ms,
        block_scholes_surface_freshness_ms: freshness_ms,
    }
}

/// `order_state` row with every optional column NULL apart from identity;
/// tests override the fields they exercise.
fn state_row(
    market: &str,
    order_id: &str,
    st: &str,
    opened_at_ms: i64,
    sequence: i64,
) -> OrderState {
    OrderState {
        expiry_market_id: market.into(),
        order_id: order_id.into(),
        predict_manager_id: Some(MANAGER.into()),
        position_root_id: Some(order_id.into()),
        owner: Some(OWNER.into()),
        status: st.into(),
        replacement_order_id: None,
        opened_at_ms,
        lower_boundary_index: 3,
        higher_boundary_index: 7,
        floor_shares: bd(0),
        quantity: bd(70_000),
        sequence,
        leverage: None,
        entry_probability: None,
        net_premium: None,
        updated_at_ms: opened_at_ms,
        checkpoint: 1,
        tx_index: 0,
        event_index: sequence,
    }
}

/// `order_state` has no Insertable model (the indexer writes it through raw
/// upsert SQL), so tests seed it column-by-column.
async fn insert_order_state(db: &Db, r: &OrderState) {
    use schema::order_state as os;
    let mut conn = db.connect().await.unwrap();
    diesel::insert_into(os::table)
        .values((
            os::expiry_market_id.eq(r.expiry_market_id.clone()),
            os::order_id.eq(r.order_id.clone()),
            os::predict_manager_id.eq(r.predict_manager_id.clone()),
            os::position_root_id.eq(r.position_root_id.clone()),
            os::owner.eq(r.owner.clone()),
            os::status.eq(r.status.clone()),
            os::replacement_order_id.eq(r.replacement_order_id.clone()),
            os::opened_at_ms.eq(r.opened_at_ms),
            os::lower_boundary_index.eq(r.lower_boundary_index),
            os::higher_boundary_index.eq(r.higher_boundary_index),
            os::floor_shares.eq(r.floor_shares.clone()),
            os::quantity.eq(r.quantity.clone()),
            os::sequence.eq(r.sequence),
            os::leverage.eq(r.leverage),
            os::entry_probability.eq(r.entry_probability),
            os::net_premium.eq(r.net_premium.clone()),
            os::updated_at_ms.eq(r.updated_at_ms),
            os::checkpoint.eq(r.checkpoint),
            os::tx_index.eq(r.tx_index),
            os::event_index.eq(r.event_index),
        ))
        .execute(&mut conn)
        .await
        .unwrap();
}

/// `lp_request_state` row with the identity/amount columns set and the fill
/// columns NULL; tests override the fields they exercise.
fn lp_state_row(
    vault: &str,
    is_supply: bool,
    request_index: i64,
    st: &str,
    opened_at_ms: i64,
) -> LpRequestState {
    LpRequestState {
        pool_vault_id: vault.into(),
        is_supply,
        request_index,
        predict_manager_id: Some(MANAGER.into()),
        recipient: Some(OWNER.into()),
        requested_amount: Some(bd(100)),
        status: st.into(),
        filled_dusdc: None,
        filled_shares: None,
        opened_at_ms,
        updated_at_ms: opened_at_ms,
        checkpoint: 1,
        tx_index: 0,
        event_index: request_index,
    }
}

/// `lp_request_state` has no Insertable model (the indexer writes it through raw
/// upsert SQL), so tests seed it column-by-column.
async fn insert_lp_request_state(db: &Db, r: &LpRequestState) {
    use schema::lp_request_state as lrs;
    let mut conn = db.connect().await.unwrap();
    diesel::insert_into(lrs::table)
        .values((
            lrs::pool_vault_id.eq(r.pool_vault_id.clone()),
            lrs::is_supply.eq(r.is_supply),
            lrs::request_index.eq(r.request_index),
            lrs::predict_manager_id.eq(r.predict_manager_id.clone()),
            lrs::recipient.eq(r.recipient.clone()),
            lrs::requested_amount.eq(r.requested_amount.clone()),
            lrs::status.eq(r.status.clone()),
            lrs::filled_dusdc.eq(r.filled_dusdc.clone()),
            lrs::filled_shares.eq(r.filled_shares.clone()),
            lrs::opened_at_ms.eq(r.opened_at_ms),
            lrs::updated_at_ms.eq(r.updated_at_ms),
            lrs::checkpoint.eq(r.checkpoint),
            lrs::tx_index.eq(r.tx_index),
            lrs::event_index.eq(r.event_index),
        ))
        .execute(&mut conn)
        .await
        .unwrap();
}

// === Tests ===

#[tokio::test]
async fn window_pagination_bounds_and_limit() {
    let (_temp_db, db, router) = setup().await;

    // 501 mints, one per checkpoint i at T0 + i seconds.
    let rows: Vec<OrderMinted> = (0..=500i64)
        .map(|i| order_minted_row(&i.to_string(), MARKET, MANAGER, (i, 0, 0), T0_MS + i * 1000))
        .collect();
    seed!(db, order_minted, &rows);

    // Explicit window [T0+100s, T0+103s], inclusive on both ends.
    let page = get(
        &router,
        &format!(
            "/markets/{MARKET}/orders?start_time={}&end_time={}",
            T0_S + 100,
            T0_S + 103
        ),
    )
    .await;
    assert_eq!(i64_col(&page, "checkpoint"), vec![103, 102, 101, 100]);

    // No ?limit -> default 50, newest-first.
    let page = get(&router, &format!("/markets/{MARKET}/orders")).await;
    assert_eq!(
        i64_col(&page, "checkpoint"),
        (451..=500).rev().collect::<Vec<i64>>()
    );

    // ?limit above the cap is clamped to 500 (the oldest row falls off).
    let page = get(&router, &format!("/markets/{MARKET}/orders?limit=9999")).await;
    assert_eq!(
        i64_col(&page, "checkpoint"),
        (1..=500).rev().collect::<Vec<i64>>()
    );

    // Small explicit limit.
    let page = get(&router, &format!("/markets/{MARKET}/orders?limit=3")).await;
    assert_eq!(i64_col(&page, "checkpoint"), vec![500, 499, 498]);
}

#[tokio::test]
async fn market_feed_interleaves_all_tables() {
    let (_temp_db, db, router) = setup().await;

    // One row in each of the 5 order tables, ALL sharing checkpoint_timestamp_ms
    // T0: the feed order must come entirely from the (checkpoint, tx_index,
    // event_index) tiebreak, never from the timestamp.
    seed!(
        db,
        order_minted,
        &order_minted_row("m", MARKET, MANAGER, (3, 1, 0), T0_MS)
    );
    seed!(
        db,
        live_order_redeemed,
        &live_redeemed_row("l", MARKET, MANAGER, (3, 0, 5), T0_MS)
    );
    seed!(
        db,
        settled_order_redeemed,
        &settled_redeemed_row("s", MARKET, MANAGER, (4, 0, 0), T0_MS)
    );
    seed!(
        db,
        liquidated_order_redeemed,
        &liquidated_redeemed_row("q", MARKET, MANAGER, (2, 9, 9), T0_MS)
    );
    seed!(
        db,
        order_liquidated,
        &order_liquidated_row("o", MARKET, (3, 1, 1), T0_MS)
    );

    let page = get(&router, &format!("/markets/{MARKET}/orders")).await;
    assert_eq!(
        str_col(&page, "kind"),
        vec![
            "settled_order_redeemed",
            "order_liquidated",
            "order_minted",
            "live_order_redeemed",
            "liquidated_order_redeemed",
        ]
    );
    assert_eq!(
        triples(&page),
        vec![(4, 0, 0), (3, 1, 1), (3, 1, 0), (3, 0, 5), (2, 9, 9)]
    );
}

#[tokio::test]
async fn manager_feed_excludes_order_liquidated() {
    let (_temp_db, db, router) = setup().await;

    seed!(
        db,
        order_minted,
        &order_minted_row("m", MARKET, MANAGER, (1, 0, 0), T0_MS)
    );
    seed!(
        db,
        live_order_redeemed,
        &live_redeemed_row("l", MARKET, MANAGER, (2, 0, 0), T0_MS + 1000)
    );
    seed!(
        db,
        settled_order_redeemed,
        &settled_redeemed_row("s", MARKET, MANAGER, (3, 0, 0), T0_MS + 2000)
    );
    seed!(
        db,
        liquidated_order_redeemed,
        &liquidated_redeemed_row("q", MARKET, MANAGER, (4, 0, 0), T0_MS + 3000)
    );
    // order_liquidated has no predict_manager_id and must never appear.
    seed!(
        db,
        order_liquidated,
        &order_liquidated_row("o", MARKET, (5, 0, 0), T0_MS + 4000)
    );

    let page = get(&router, &format!("/managers/{MANAGER}/orders")).await;
    assert_eq!(
        str_col(&page, "kind"),
        vec![
            "liquidated_order_redeemed",
            "settled_order_redeemed",
            "live_order_redeemed",
            "order_minted",
        ]
    );
}

#[tokio::test]
async fn vault_supply_requests_single_table_window() {
    const OTHER_VAULT: &str = "0xvault-2";
    let (_temp_db, db, router) = setup().await;

    seed!(
        db,
        supply_requested,
        &supply_requested_row("a1", VAULT, MANAGER, 1, 1, T0_MS)
    );
    seed!(
        db,
        supply_requested,
        &supply_requested_row("a2", VAULT, MANAGER, 2, 2, T0_MS + 1000)
    );
    seed!(
        db,
        supply_requested,
        &supply_requested_row("a3", VAULT, MANAGER, 3, 3, T0_MS + 2000)
    );
    // A different vault's request must never appear in this vault's feed.
    seed!(
        db,
        supply_requested,
        &supply_requested_row("b1", OTHER_VAULT, MANAGER, 9, 4, T0_MS + 1000)
    );

    // Only this vault's rows, newest-first, each carrying its kind.
    let page = get(&router, &format!("/vaults/{VAULT}/supply-requests")).await;
    assert_eq!(i64_col(&page, "request_index"), vec![3, 2, 1]);
    assert_eq!(str_col(&page, "kind"), vec!["supply_requested"; 3]);

    // Window pinning exactly the middle second.
    let page = get(
        &router,
        &format!(
            "/vaults/{VAULT}/supply-requests?start_time={}&end_time={}",
            T0_S + 1,
            T0_S + 1
        ),
    )
    .await;
    assert_eq!(i64_col(&page, "request_index"), vec![2]);

    // Limit keeps the newest rows.
    let page = get(&router, &format!("/vaults/{VAULT}/supply-requests?limit=2")).await;
    assert_eq!(i64_col(&page, "request_index"), vec![3, 2]);
}

#[tokio::test]
async fn vault_fill_and_flush_feeds_carry_kind() {
    let (_temp_db, db, router) = setup().await;

    seed!(
        db,
        withdraw_requested,
        &withdraw_requested_row("w1", VAULT, MANAGER, 1, 1, T0_MS)
    );
    seed!(
        db,
        supply_filled,
        &supply_filled_row("sf1", VAULT, MANAGER, 1, 2, T0_MS + 1000)
    );
    seed!(
        db,
        withdraw_filled,
        &withdraw_filled_row("wf1", VAULT, MANAGER, 1, 3, T0_MS + 2000)
    );
    seed!(
        db,
        flush_executed,
        &flush_row("f1", VAULT, 4, T0_MS + 3000, 1000, 900, 500)
    );

    let page = get(&router, &format!("/vaults/{VAULT}/withdraw-requests")).await;
    assert_eq!(str_col(&page, "kind"), vec!["withdraw_requested"]);
    assert_eq!(str_col(&page, "amount"), vec!["50"]);

    let page = get(&router, &format!("/vaults/{VAULT}/supply-fills")).await;
    assert_eq!(str_col(&page, "kind"), vec!["supply_filled"]);
    assert_eq!(str_col(&page, "shares_minted"), vec!["99"]);

    let page = get(&router, &format!("/vaults/{VAULT}/withdraw-fills")).await;
    assert_eq!(str_col(&page, "kind"), vec!["withdraw_filled"]);
    assert_eq!(str_col(&page, "dusdc_amount"), vec!["51"]);

    let page = get(&router, &format!("/vaults/{VAULT}/flushes")).await;
    assert_eq!(str_col(&page, "kind"), vec!["flush_executed"]);
    assert_eq!(str_col(&page, "pool_value"), vec!["1000"]);
    assert_eq!(str_col(&page, "total_supply"), vec!["900"]);
}

#[tokio::test]
async fn manager_staking_merges_stake_and_unstake() {
    let (_temp_db, db, router) = setup().await;

    // s1 and u1 share a timestamp; the higher checkpoint (u1) must come first.
    seed!(db, deep_staked, &staked_row("s1", MANAGER, 1, T0_MS));
    seed!(db, deep_unstaked, &unstaked_row("u1", MANAGER, 2, T0_MS));
    seed!(db, deep_staked, &staked_row("s2", MANAGER, 3, T0_MS + 1000));

    let page = get(&router, &format!("/managers/{MANAGER}/staking")).await;
    assert_eq!(
        str_col(&page, "kind"),
        vec!["deep_staked", "deep_unstaked", "deep_staked"]
    );
    assert_eq!(i64_col(&page, "checkpoint"), vec![3, 2, 1]);
}

#[tokio::test]
async fn market_state_composes_latest_rows() {
    let (_temp_db, db, router) = setup().await;

    seed!(db, market_created, &market_created_row(MARKET, 1, T0_MS));
    // Two config snapshots sharing checkpoint_timestamp_ms: the row from the
    // HIGHER checkpoint must win the "latest" read.
    seed!(
        db,
        market_config_snapshot,
        &config_snapshot_row("c5", MARKET, 5, T0_MS, 100)
    );
    seed!(
        db,
        market_config_snapshot,
        &config_snapshot_row("c9", MARKET, 9, T0_MS, 200)
    );
    seed!(
        db,
        expiry_market_mint_paused_updated,
        &mint_paused_row(MARKET, true, 2, T0_MS)
    );
    // Terminal settlement component (present once the market has settled).
    seed!(
        db,
        market_settled,
        &market_settled_row(MARKET, 3, T0_MS, 99_000)
    );

    let state = get(&router, &format!("/markets/{MARKET}/state")).await;
    assert_eq!(state["market"]["pool_vault_id"], VAULT);
    assert_eq!(state["market"]["propbook_underlying_id"], 42);
    assert_eq!(state["config"]["checkpoint"], 9);
    assert_eq!(state["config"]["base_fee"], "200");
    assert_eq!(state["mint_paused"]["paused"], true);
    assert_eq!(state["settlement"]["settlement_price"], "99000");
    assert_eq!(state["settlement"]["kind"], "market_settled");

    // Unknown market: every component is null.
    let state = get(&router, "/markets/0xunknown/state").await;
    for component in ["market", "config", "mint_paused", "settlement"] {
        assert!(state[component].is_null(), "{component} should be null");
    }
}

#[tokio::test]
async fn vault_state_current_uses_newest_triple_across_tables() {
    let (_temp_db, db, router) = setup().await;

    // Flush (older, checkpoint 10) is the valuation: total_supply/pool_value
    // come only from it, and it carries idle_balance_after=500. Rebalance
    // (newer, checkpoint 20) carries a newer idle_balance_after=600.
    seed!(
        db,
        flush_executed,
        &flush_row("f1", VAULT, 10, T0_MS, 1000, 111, 500)
    );
    seed!(
        db,
        expiry_cash_rebalanced,
        &rebalance_row("r1", VAULT, 20, T0_MS + 1000, 600)
    );

    let state = get(&router, &format!("/vaults/{VAULT}/state")).await;
    // idle_balance_after = newest triple = the rebalance.
    assert_eq!(state["current"]["idle_balance_after"], "600");
    // total_supply / pool_value come from the latest flush (the valuation).
    assert_eq!(state["current"]["total_supply"], "111");
    assert_eq!(state["current"]["pool_value"], "1000");
    // Reserve and carried cut now reconcile across profit + rebalance; here only the
    // rebalance carries them, so they surface from it (newest triple).
    assert_eq!(state["current"]["protocol_reserve_balance_after"], "77");
    assert_eq!(state["current"]["pending_protocol_profit_after"], "7");
    // profit_basis_after is still carried only by the profit event (none seeded).
    assert!(state["current"]["profit_basis_after"].is_null());
    assert_eq!(state["latest_flush"]["kind"], "flush_executed");
    assert_eq!(state["latest_cash_rebalance"]["checkpoint"], 20);
    assert!(state["latest_supply_fill"].is_null());
    assert!(state["latest_withdraw_fill"].is_null());
    assert!(state["latest_profit"].is_null());
}

#[tokio::test]
async fn manager_positions_filters_status_and_joins_root() {
    let (_temp_db, db, router) = setup().await;

    // Root: replaced, carries the entry facts.
    let mut root = state_row(MARKET, "1001", status::REPLACED, T0_MS, 1);
    root.replacement_order_id = Some("1002".into());
    root.leverage = Some(2_000_000_000);
    root.entry_probability = Some(450_000_000);
    root.net_premium = Some(bd(54));
    insert_order_state(&db, &root).await;
    // Replacement: open, entry facts NULL, points at the root.
    let mut replacement = state_row(MARKET, "1002", status::OPEN, T0_MS, 2);
    replacement.position_root_id = Some("1001".into());
    insert_order_state(&db, &replacement).await;

    // Default ?status=open: only the replacement, carrying the root's entry
    // facts in "root".
    let page = get(&router, &format!("/managers/{MANAGER}/positions")).await;
    assert_eq!(str_col(&page, "order_id"), vec!["1002"]);
    let row = &page.as_array().unwrap()[0];
    assert_eq!(row["kind"], "order_state");
    assert!(row["net_premium"].is_null());
    assert_eq!(row["root"]["order_id"], "1001");
    assert_eq!(row["root"]["net_premium"], "54");
    assert_eq!(row["root"]["leverage"], 2_000_000_000i64);

    // ?status=replaced: the root row, which is its own root ("root": null).
    let page = get(
        &router,
        &format!("/managers/{MANAGER}/positions?status=replaced"),
    )
    .await;
    assert_eq!(str_col(&page, "order_id"), vec!["1001"]);
    assert!(page.as_array().unwrap()[0]["root"].is_null());
}

#[tokio::test]
async fn manager_positions_window_and_ordering() {
    let (_temp_db, db, router) = setup().await;

    // Two rows share opened_at_ms T0 (ties are common: opened_at_ms is
    // checkpoint-quantized); sequence is the deterministic tiebreak.
    insert_order_state(&db, &state_row(MARKET, "2001", status::OPEN, T0_MS, 1)).await;
    insert_order_state(&db, &state_row(MARKET, "2002", status::OPEN, T0_MS, 5)).await;
    insert_order_state(
        &db,
        &state_row(MARKET, "2003", status::OPEN, T0_MS + 10_000, 2),
    )
    .await;
    insert_order_state(
        &db,
        &state_row(MARKET, "2004", status::OPEN, T0_MS + 20_000, 3),
    )
    .await;

    // Full order: (opened_at_ms DESC, sequence DESC).
    let page = get(&router, &format!("/managers/{MANAGER}/positions")).await;
    assert_eq!(
        str_col(&page, "order_id"),
        vec!["2004", "2003", "2002", "2001"]
    );

    // LIMIT boundary inside the opened_at_ms tie: seq 5 ("2002") survives,
    // seq 1 ("2001") falls off.
    let page = get(&router, &format!("/managers/{MANAGER}/positions?limit=3")).await;
    assert_eq!(str_col(&page, "order_id"), vec!["2004", "2003", "2002"]);

    // Window over opened_at_ms (unix seconds, inclusive).
    let page = get(
        &router,
        &format!(
            "/managers/{MANAGER}/positions?start_time={}&end_time={}",
            T0_S + 1,
            T0_S + 15
        ),
    )
    .await;
    assert_eq!(str_col(&page, "order_id"), vec!["2003"]);
}

#[tokio::test]
async fn manager_lp_requests_filters_status_window_and_ordering() {
    let (_temp_db, db, router) = setup().await;

    // Two open supply requests share opened_at_ms T0; request_index is the
    // deterministic tiebreak (DESC). A cancelled one must be excluded by the
    // default ?status=open. A withdraw request at a later time leads the feed.
    insert_lp_request_state(
        &db,
        &lp_state_row(VAULT, true, 1, lp_request_status::OPEN, T0_MS),
    )
    .await;
    insert_lp_request_state(
        &db,
        &lp_state_row(VAULT, true, 5, lp_request_status::OPEN, T0_MS),
    )
    .await;
    insert_lp_request_state(
        &db,
        &lp_state_row(VAULT, false, 2, lp_request_status::OPEN, T0_MS + 10_000),
    )
    .await;
    insert_lp_request_state(
        &db,
        &lp_state_row(VAULT, true, 3, lp_request_status::CANCELLED, T0_MS),
    )
    .await;

    // Default ?status=open: the three open rows, newest-opened first with
    // request_index DESC inside the T0 tie. The cancelled row is excluded.
    let page = get(&router, &format!("/managers/{MANAGER}/lp-requests")).await;
    assert_eq!(i64_col(&page, "request_index"), vec![2, 5, 1]);
    let row = &page.as_array().unwrap()[0];
    assert_eq!(row["kind"], "lp_request_state");
    assert_eq!(row["is_supply"], false);
    assert_eq!(row["status"], lp_request_status::OPEN);
    assert_eq!(row["requested_amount"], "100");

    // ?status=cancelled: only the cancelled handle.
    let page = get(
        &router,
        &format!("/managers/{MANAGER}/lp-requests?status=cancelled"),
    )
    .await;
    assert_eq!(i64_col(&page, "request_index"), vec![3]);

    // Window over opened_at_ms (unix seconds, inclusive) catches only the
    // withdraw request opened at T0 + 10s.
    let page = get(
        &router,
        &format!(
            "/managers/{MANAGER}/lp-requests?start_time={}&end_time={}",
            T0_S + 1,
            T0_S + 15
        ),
    )
    .await;
    assert_eq!(i64_col(&page, "request_index"), vec![2]);

    // Limit keeps the newest-opened rows.
    let page = get(&router, &format!("/managers/{MANAGER}/lp-requests?limit=2")).await;
    assert_eq!(i64_col(&page, "request_index"), vec![2, 5]);
}

#[tokio::test]
async fn market_open_interest_sums_open_rows_only() {
    let (_temp_db, db, router) = setup().await;

    let mut open1 = state_row(MARKET, "3001", status::OPEN, T0_MS, 1);
    open1.quantity = bd(70_000);
    open1.floor_shares = bd(50_000);
    insert_order_state(&db, &open1).await;
    let mut open2 = state_row(MARKET, "3002", status::OPEN, T0_MS, 2);
    open2.quantity = bd(120_000);
    open2.floor_shares = bd(0);
    insert_order_state(&db, &open2).await;
    // Non-open rows must not count.
    insert_order_state(&db, &state_row(MARKET, "3003", status::CLOSED, T0_MS, 3)).await;
    insert_order_state(
        &db,
        &state_row(MARKET, "3004", status::LIQUIDATED, T0_MS, 4),
    )
    .await;

    let oi = get(&router, &format!("/markets/{MARKET}/open-interest")).await;
    assert_eq!(oi["open_order_count"], 2);
    // 70_000 + 120_000 and 50_000 + 0, NUMERIC sums serialized as strings.
    assert_eq!(oi["open_quantity"], "190000");
    assert_eq!(oi["open_floor_shares"], "50000");

    // Empty market: zeros.
    let oi = get(&router, "/markets/0xunknown/open-interest").await;
    assert_eq!(oi["open_order_count"], 0);
    assert_eq!(oi["open_quantity"], "0");
    assert_eq!(oi["open_floor_shares"], "0");
}

#[tokio::test]
async fn mv_bucket_feeds_window_and_limit() {
    let (_temp_db, db, router) = setup().await;

    // The MV source windows are now()-relative (trailing 30 days, evaluated
    // at refresh), so seed relative to the wall clock: an hour bucket two
    // hours ago. Everything else (bucket key, expected sums) is derived from
    // the seeded timestamps, not from the clock.
    let now_ms = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap()
        .as_millis() as i64;
    let bucket_ms = ((now_ms - 7_200_000) / 3_600_000) * 3_600_000;

    seed!(
        db,
        order_minted,
        &order_minted_row("m1", MARKET, MANAGER, (1, 0, 0), bucket_ms + 1000)
    );
    seed!(
        db,
        order_minted,
        &order_minted_row("m2", MARKET, MANAGER, (2, 0, 0), bucket_ms + 2000)
    );

    {
        let mut conn = db.connect().await.unwrap();
        diesel::sql_query("REFRESH MATERIALIZED VIEW market_activity_1h")
            .execute(&mut conn)
            .await
            .unwrap();
    }

    // market_activity_1h: one bucket aggregating both mints.
    let page = get(&router, &format!("/markets/{MARKET}/activity")).await;
    assert_eq!(i64_col(&page, "bucket_ms"), vec![bucket_ms]);
    let bucket = &page.as_array().unwrap()[0];
    assert_eq!(bucket["kind"], "market_activity_1h");
    assert_eq!(bucket["mint_count"], 2);
    assert_eq!(bucket["mint_quantity"], "140000"); // 2 * 70_000
    assert_eq!(bucket["mint_premium"], "108"); // 2 * 54
    assert_eq!(bucket["mint_fees"], "20"); // 2 * (7 + 2 + 1)
    assert_eq!(bucket["unique_minters"], 1);

    // Window excluding the bucket -> empty page.
    let page = get(
        &router,
        &format!(
            "/markets/{MARKET}/activity?end_time={}",
            bucket_ms / 1000 - 1
        ),
    )
    .await;
    assert_eq!(page.as_array().unwrap().len(), 0);

    // Unseeded MV feeds return empty pages (not errors).
    let page = get(&router, &format!("/markets/{MARKET}/liquidation-stats")).await;
    assert_eq!(page.as_array().unwrap().len(), 0);
    let page = get(&router, &format!("/vaults/{VAULT}/flows")).await;
    assert_eq!(page.as_array().unwrap().len(), 0);
}

#[tokio::test]
async fn protocol_config_returns_latest_of_each_table() {
    let (_temp_db, db, router) = setup().await;

    // Two updates sharing checkpoint_timestamp_ms: the HIGHER checkpoint is
    // the current config.
    seed!(
        db,
        pricing_config_updated,
        &pricing_config_row("c5", 5, T0_MS, 1000)
    );
    seed!(
        db,
        pricing_config_updated,
        &pricing_config_row("c9", 9, T0_MS, 2000)
    );

    let config = get(&router, "/config").await;
    assert_eq!(config["pricing"]["checkpoint"], 9);
    assert_eq!(config["pricing"]["pyth_spot_freshness_ms"], 2000);
    assert_eq!(config["pricing"]["kind"], "pricing_config_updated");
    for unseeded in [
        "risk",
        "expiry_cash_template",
        "strike_exposure_template",
        "ewma",
        "stake",
        "trading_paused",
    ] {
        assert!(config[unseeded].is_null(), "{unseeded} should be null");
    }
}
