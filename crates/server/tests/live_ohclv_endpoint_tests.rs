use axum::body::Body;
use axum::http::{Request, StatusCode};
use axum::Router;
use diesel_async::RunQueryDsl;
use http_body_util::BodyExt;
use prometheus::Registry;
use serde_json::Value;
use std::sync::Arc;
use std::time::{Duration, SystemTime, UNIX_EPOCH};
use sui_pg_db::temp::TempDb;
use sui_pg_db::{Db, DbArgs};
use tokio::time::sleep;
use tower::ServiceExt;
use url::Url;

use deepbook_server::{
    pyth::{PythProConfig, DEFAULT_PRO_URL},
    server::{make_router, AppState},
};

const POOL_NAME: &str = "BASE_USDC";
const POOL_ID: &str = "pool-1";
const STALE_T0_MS: i64 = 1_699_999_980_000;
const MINUTE_MS: i64 = 60_000;

#[derive(Clone, Copy, Debug)]
struct CandleValues {
    timestamp_ms: i64,
    open: f64,
    high: f64,
    low: f64,
    close: f64,
    base_volume: f64,
}

#[derive(Clone, Copy, Debug)]
struct MaterializedCandle {
    values: CandleValues,
    quote_volume: f64,
    trade_count: i32,
    first_trade_timestamp_ms: i64,
    last_trade_timestamp_ms: i64,
}

#[derive(Clone, Copy, Debug)]
struct LiveFillSeed {
    tag: &'static str,
    timestamp_ms: i64,
    price: i64,
    base_volume: i64,
}

async fn setup(candles: &[MaterializedCandle]) -> (TempDb, Db, Arc<AppState>, Router) {
    let temp_db = TempDb::new().expect("postgres binaries must be on PATH");
    let url: Url = temp_db.database().url().clone();
    let db = Db::for_write(url.clone(), DbArgs::default()).await.unwrap();
    db.run_migrations(Some(&deepbook_schema::MIGRATIONS))
        .await
        .unwrap();

    seed_pool(&db).await;
    for candle in candles {
        seed_materialized_candle(&db, *candle).await;
    }

    let registry = Registry::new();
    let rpc_url: Url = "http://localhost:1/".parse().unwrap();
    let state = Arc::new(
        AppState::new(
            url,
            DbArgs::default(),
            &registry,
            rpc_url,
            "deepbook-package".to_string(),
            "deep-token-package".to_string(),
            "deep-treasury".to_string(),
            None,
            None,
            100,
            Url::parse(DEFAULT_PRO_URL).unwrap(),
            None,
            PythProConfig::default(),
        )
        .await
        .unwrap(),
    );

    let router = make_router(state.clone());
    (temp_db, db, state, router)
}

fn candle(
    timestamp_ms: i64,
    open: i64,
    high: i64,
    low: i64,
    close: i64,
    base_volume: i64,
) -> CandleValues {
    CandleValues {
        timestamp_ms,
        open: open as f64,
        high: high as f64,
        low: low as f64,
        close: close as f64,
        base_volume: base_volume as f64,
    }
}

fn materialized_candle(
    values: CandleValues,
    quote_volume: i64,
    trade_count: i32,
    first_trade_timestamp_ms: i64,
    last_trade_timestamp_ms: i64,
) -> MaterializedCandle {
    MaterializedCandle {
        values,
        quote_volume: quote_volume as f64,
        trade_count,
        first_trade_timestamp_ms,
        last_trade_timestamp_ms,
    }
}

fn fill(tag: &'static str, timestamp_ms: i64, price: i64, base_volume: i64) -> LiveFillSeed {
    LiveFillSeed {
        tag,
        timestamp_ms,
        price,
        base_volume,
    }
}

fn fresh_t0_ms() -> i64 {
    let now_ms = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap()
        .as_millis() as i64;
    (now_ms / MINUTE_MS - 2) * MINUTE_MS
}

fn raw_amount(value: i64) -> i64 {
    value * 1_000_000_000
}

fn uri(start_time_ms: i64, end_time_ms: i64, limit: i32) -> String {
    format!(
        "/ohclv/{POOL_NAME}?interval=1m&start_time={start_time_ms}&end_time={end_time_ms}&limit={limit}",
    )
}

async fn seed_pool(db: &Db) {
    let mut conn = db.connect().await.unwrap();
    diesel::sql_query(
        "INSERT INTO pools (
            pool_id, pool_name,
            base_asset_id, base_asset_decimals, base_asset_symbol, base_asset_name,
            quote_asset_id, quote_asset_decimals, quote_asset_symbol, quote_asset_name,
            min_size, lot_size, tick_size
        ) VALUES (
            'pool-1', 'BASE_USDC',
            'base-coin', 9, 'BASE', 'Base Coin',
            'quote-coin', 9, 'USDC', 'USD Coin',
            1, 1, 1
        )",
    )
    .execute(&mut conn)
    .await
    .unwrap();
}

async fn seed_materialized_candle(db: &Db, candle: MaterializedCandle) {
    let mut conn = db.connect().await.unwrap();
    let values = candle.values;
    diesel::sql_query(format!(
        "INSERT INTO ohclv_1m (
            pool_id, bucket_time,
            open, high, low, close, base_volume, quote_volume, trade_count,
            first_trade_timestamp, last_trade_timestamp
        ) VALUES (
            '{POOL_ID}', to_timestamp({}::double precision / 1000)::timestamp,
            {}, {}, {}, {}, {}, {}, {},
            {}, {}
        )",
        values.timestamp_ms,
        values.open,
        values.high,
        values.low,
        values.close,
        values.base_volume,
        candle.quote_volume,
        candle.trade_count,
        candle.first_trade_timestamp_ms,
        candle.last_trade_timestamp_ms,
    ))
    .execute(&mut conn)
    .await
    .unwrap();
}

async fn update_materialized_watermark(
    db: &Db,
    bucket_start_ms: i64,
    last_trade_timestamp_ms: i64,
) {
    let mut conn = db.connect().await.unwrap();
    diesel::sql_query(format!(
        "UPDATE ohclv_1m
         SET last_trade_timestamp = {}
         WHERE pool_id = '{POOL_ID}'
           AND bucket_time = to_timestamp({}::double precision / 1000)::timestamp",
        last_trade_timestamp_ms, bucket_start_ms
    ))
    .execute(&mut conn)
    .await
    .unwrap();
}

async fn insert_live_fill(db: &Db, fill: LiveFillSeed) {
    let mut conn = db.connect().await.unwrap();
    // Pool decimals are 9/9, so raw N * 1e9 becomes human price/volume N.
    diesel::sql_query(format!(
        "INSERT INTO order_fills (
            event_digest, digest, sender, checkpoint, checkpoint_timestamp_ms, package,
            pool_id, maker_order_id, taker_order_id,
            maker_client_order_id, taker_client_order_id,
            price, taker_fee, taker_fee_is_deep, maker_fee, maker_fee_is_deep,
            taker_is_bid, base_quantity, quote_quantity,
            maker_balance_manager_id, taker_balance_manager_id, onchain_timestamp
        ) VALUES (
            'fill-{tag}', 'tx-{tag}', 'sender', 1, {timestamp_ms}, 'package',
            '{POOL_ID}', 'maker-order-{tag}', 'taker-order-{tag}',
            1, 2,
            {price}, 0, false, 0, false,
            false, {base_quantity}, {quote_quantity},
            'maker-manager', 'taker-manager', {timestamp_ms}
        )",
        tag = fill.tag,
        timestamp_ms = fill.timestamp_ms,
        price = raw_amount(fill.price),
        base_quantity = raw_amount(fill.base_volume),
        quote_quantity = raw_amount(fill.price * fill.base_volume),
    ))
    .execute(&mut conn)
    .await
    .unwrap();
}

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

fn assert_candle(response: &Value, expected: CandleValues) {
    let candles = response["candles"].as_array().unwrap();
    assert_eq!(candles.len(), 1);
    let candle = candles[0].as_array().unwrap();
    assert_eq!(candle[0].as_i64().unwrap(), expected.timestamp_ms);
    assert_eq!(candle[1].as_f64().unwrap(), expected.open);
    assert_eq!(candle[2].as_f64().unwrap(), expected.high);
    assert_eq!(candle[3].as_f64().unwrap(), expected.low);
    assert_eq!(candle[4].as_f64().unwrap(), expected.close);
    assert_eq!(candle[5].as_f64().unwrap(), expected.base_volume);
}

fn response_matches_candle(response: &Value, expected: CandleValues) -> bool {
    let Some(candles) = response["candles"].as_array() else {
        return false;
    };
    if candles.len() != 1 {
        return false;
    }
    let Some(candle) = candles[0].as_array() else {
        return false;
    };

    candle[0].as_i64() == Some(expected.timestamp_ms)
        && candle[1].as_f64() == Some(expected.open)
        && candle[2].as_f64() == Some(expected.high)
        && candle[3].as_f64() == Some(expected.low)
        && candle[4].as_f64() == Some(expected.close)
        && candle[5].as_f64() == Some(expected.base_volume)
}

async fn wait_for_candle(router: &Router, uri: &str, expected: CandleValues) -> Value {
    let mut last_response = None;
    for _ in 0..50 {
        let response = get(router, uri).await;
        if response_matches_candle(&response, expected) {
            return response;
        }
        last_response = Some(response);
        sleep(Duration::from_millis(20)).await;
    }

    panic!(
        "OHCLV endpoint did not return expected candle {:?}; last response: {:?}",
        expected, last_response
    );
}

fn assert_no_candles(response: &Value) {
    assert_eq!(
        response["candles"].as_array().unwrap(),
        &Vec::<Value>::new()
    );
}

#[tokio::test]
async fn ohclv_endpoint_overlays_new_fill_before_materialized_candle_catches_up() {
    let t0_ms = fresh_t0_ms();
    let stored = candle(t0_ms, 10, 12, 9, 11, 5);
    let live_fill = fill("live-1", t0_ms + 20_000, 15, 2);
    let (_temp_db, db, state, router) =
        setup(&[materialized_candle(stored, 55, 2, t0_ms, t0_ms + 10_000)]).await;
    let uri = uri(t0_ms, t0_ms + MINUTE_MS - 1, 1);

    let materialized = get(&router, &uri).await;
    assert_candle(&materialized, stored);

    let poller = state.start_live_ohclv_poller(Duration::from_millis(10));
    insert_live_fill(&db, live_fill).await;

    let live = wait_for_candle(&router, &uri, candle(t0_ms, 10, 15, 9, 15, 7)).await;
    assert_candle(&live, candle(t0_ms, 10, 15, 9, 15, 7));
    poller.abort();
}

#[tokio::test]
async fn ohclv_endpoint_creates_live_candle_when_materialized_bucket_is_missing() {
    let t0_ms = fresh_t0_ms();
    let previous = candle(t0_ms, 10, 12, 9, 11, 5);
    let live_fill = fill("missing-minute", t0_ms + MINUTE_MS + 2_000, 20, 3);
    let (_temp_db, db, state, router) =
        setup(&[materialized_candle(previous, 55, 2, t0_ms, t0_ms + 10_000)]).await;
    let uri = uri(t0_ms + MINUTE_MS, t0_ms + 2 * MINUTE_MS - 1, 1);

    insert_live_fill(&db, live_fill).await;
    let poller = state.start_live_ohclv_poller(Duration::from_millis(10));

    let live = wait_for_candle(&router, &uri, candle(t0_ms + MINUTE_MS, 20, 20, 20, 20, 3)).await;
    assert_candle(&live, candle(t0_ms + MINUTE_MS, 20, 20, 20, 20, 3));
    poller.abort();
}

#[tokio::test]
async fn ohclv_endpoint_does_not_overlay_when_no_materialized_watermark_exists() {
    let t0_ms = fresh_t0_ms();
    let live_fill = fill("no-watermark", t0_ms + 2_000, 20, 3);
    let (_temp_db, db, state, router) = setup(&[]).await;
    let uri = uri(t0_ms, t0_ms + MINUTE_MS - 1, 1);

    insert_live_fill(&db, live_fill).await;
    let poller = state.start_live_ohclv_poller(Duration::from_millis(10));
    sleep(Duration::from_millis(50)).await;

    let response = get(&router, &uri).await;
    assert_no_candles(&response);
    poller.abort();
}

#[tokio::test]
async fn ohclv_endpoint_does_not_overlay_when_materialized_watermark_is_stale() {
    let t0_ms = STALE_T0_MS;
    let stored = candle(t0_ms, 10, 12, 9, 11, 5);
    let live_fill = fill("stale-materializer", t0_ms + 20_000, 15, 2);
    let (_temp_db, db, state, router) =
        setup(&[materialized_candle(stored, 55, 2, t0_ms, t0_ms + 10_000)]).await;
    let uri = uri(t0_ms, t0_ms + MINUTE_MS - 1, 1);

    insert_live_fill(&db, live_fill).await;
    let poller = state.start_live_ohclv_poller(Duration::from_millis(10));
    sleep(Duration::from_millis(50)).await;

    let response = get(&router, &uri).await;
    assert_candle(&response, stored);
    poller.abort();
}

#[tokio::test]
async fn ohclv_endpoint_stops_overlaying_fill_after_materialized_watermark_catches_up() {
    let t0_ms = fresh_t0_ms();
    let stored = candle(t0_ms, 10, 12, 9, 11, 5);
    let live_fill = fill("caught-up", t0_ms + 20_000, 15, 2);
    let (_temp_db, db, state, router) =
        setup(&[materialized_candle(stored, 55, 2, t0_ms, t0_ms + 10_000)]).await;
    let uri = uri(t0_ms, t0_ms + MINUTE_MS - 1, 1);

    insert_live_fill(&db, live_fill).await;
    let poller = state.start_live_ohclv_poller(Duration::from_millis(10));

    let overlaid = wait_for_candle(&router, &uri, candle(t0_ms, 10, 15, 9, 15, 7)).await;
    assert_candle(&overlaid, candle(t0_ms, 10, 15, 9, 15, 7));

    update_materialized_watermark(&db, t0_ms, live_fill.timestamp_ms).await;

    let materialized = wait_for_candle(&router, &uri, stored).await;
    assert_candle(&materialized, stored);
    poller.abort();
}
