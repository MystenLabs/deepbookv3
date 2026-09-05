use axum::body::Body;
use axum::http::{Request, StatusCode};
use axum::Router;
use diesel_async::RunQueryDsl;
use http_body_util::BodyExt;
use prometheus::Registry;
use serde_json::Value;
use std::sync::Arc;
use sui_pg_db::temp::TempDb;
use sui_pg_db::{Db, DbArgs};
use tower::ServiceExt;
use url::Url;

use deepbook_server::{
    pyth::{PythProConfig, DEFAULT_PRO_URL},
    server::{make_router, AppState},
};

const POOL_NAME: &str = "BASE_USDC";
const POOL_ID: &str = "pool-1";
const MANAGER_ID: &str = "manager-1";
const OTHER_MANAGER_ID: &str = "manager-2";
const HOUR_S: i64 = 3600;
const DAY_S: i64 = 24 * HOUR_S;
/// Fixed window start (Unix seconds) so bucket keys are deterministic.
const T0_S: i64 = 1_700_000_000;

#[derive(Clone, Copy, Debug)]
struct FillSeed {
    tag: &'static str,
    timestamp_ms: i64,
    maker_balance_manager_id: &'static str,
    taker_balance_manager_id: &'static str,
    base_quantity: i64,
}

async fn setup(fills: &[FillSeed]) -> (TempDb, Router) {
    let temp_db = TempDb::new().expect("postgres binaries must be on PATH");
    let url: Url = temp_db.database().url().clone();
    let db = Db::for_write(url.clone(), DbArgs::default()).await.unwrap();
    db.run_migrations(Some(&deepbook_schema::MIGRATIONS))
        .await
        .unwrap();

    seed_pool(&db).await;
    for fill in fills {
        seed_fill(&db, *fill).await;
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

    let router = make_router(state);
    (temp_db, router)
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

async fn seed_fill(db: &Db, fill: FillSeed) {
    let mut conn = db.connect().await.unwrap();
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
            1, 0, false, 0, false,
            false, {base_quantity}, {quote_quantity},
            '{maker}', '{taker}', {timestamp_ms}
        )",
        tag = fill.tag,
        timestamp_ms = fill.timestamp_ms,
        base_quantity = fill.base_quantity,
        quote_quantity = fill.base_quantity * 2,
        maker = fill.maker_balance_manager_id,
        taker = fill.taker_balance_manager_id,
    ))
    .execute(&mut conn)
    .await
    .unwrap();
}

fn uri(start_time_s: i64, end_time_s: i64, interval_s: &str) -> String {
    uri_for_pools(
        POOL_NAME,
        start_time_s,
        end_time_s,
        &format!("&interval={interval_s}"),
    )
}

fn uri_for_pools(pool_names: &str, start_time_s: i64, end_time_s: i64, interval: &str) -> String {
    format!(
        "/historical_volume_by_balance_manager_id_with_interval/{pool_names}/{MANAGER_ID}\
         ?start_time={start_time_s}&end_time={end_time_s}{interval}&volume_in_base=true",
    )
}

async fn send(router: &Router, uri: &str) -> (StatusCode, String) {
    let response = router
        .clone()
        .oneshot(Request::builder().uri(uri).body(Body::empty()).unwrap())
        .await
        .unwrap();
    let status = response.status();
    let body = response.into_body().collect().await.unwrap().to_bytes();
    (status, String::from_utf8_lossy(&body).into_owned())
}

async fn assert_rejected(router: &Router, uri: &str, expected_fragment: &str) {
    let (status, body) = send(router, uri).await;
    assert_eq!(status, StatusCode::BAD_REQUEST, "GET {uri} -> {body}");
    assert!(
        body.contains(expected_fragment),
        "GET {uri} -> {body}, expected it to mention {expected_fragment:?}",
    );
}

fn bucket(start_s: i64, end_s: i64) -> String {
    format!("[{start_s}, {end_s}]")
}

#[tokio::test]
async fn serves_one_bucket_per_interval_inside_the_budget() {
    let (_temp_db, router) = setup(&[
        // Mid-bucket so an inclusive range bound cannot double-count across buckets.
        FillSeed {
            tag: "maker-b0",
            timestamp_ms: (T0_S + HOUR_S / 2) * 1000,
            maker_balance_manager_id: MANAGER_ID,
            taker_balance_manager_id: OTHER_MANAGER_ID,
            base_quantity: 100,
        },
        FillSeed {
            tag: "taker-b2",
            timestamp_ms: (T0_S + 2 * HOUR_S + HOUR_S / 2) * 1000,
            maker_balance_manager_id: OTHER_MANAGER_ID,
            taker_balance_manager_id: MANAGER_ID,
            base_quantity: 250,
        },
        // Another manager's fill in the same bucket must not appear.
        FillSeed {
            tag: "other-b3",
            timestamp_ms: (T0_S + 3 * HOUR_S + HOUR_S / 2) * 1000,
            maker_balance_manager_id: OTHER_MANAGER_ID,
            taker_balance_manager_id: OTHER_MANAGER_ID,
            base_quantity: 900,
        },
    ])
    .await;

    let (status, body) = send(&router, &uri(T0_S, T0_S + 4 * HOUR_S, "3600")).await;
    assert_eq!(status, StatusCode::OK, "{body}");
    let response: Value = serde_json::from_str(&body).unwrap();
    let buckets = response.as_object().unwrap();

    assert_eq!(buckets.len(), 4, "{body}");
    assert_eq!(
        buckets[&bucket(T0_S, T0_S + HOUR_S)][POOL_NAME],
        serde_json::json!([100, 0])
    );
    assert_eq!(
        buckets[&bucket(T0_S + HOUR_S, T0_S + 2 * HOUR_S)],
        serde_json::json!({})
    );
    assert_eq!(
        buckets[&bucket(T0_S + 2 * HOUR_S, T0_S + 3 * HOUR_S)][POOL_NAME],
        serde_json::json!([0, 250])
    );
    assert_eq!(
        buckets[&bucket(T0_S + 3 * HOUR_S, T0_S + 4 * HOUR_S)],
        serde_json::json!({})
    );
}

#[tokio::test]
async fn serves_a_window_that_lands_exactly_on_the_bucket_budget() {
    let (_temp_db, router) = setup(&[]).await;

    let (status, body) = send(&router, &uri(T0_S, T0_S + 500 * HOUR_S, "3600")).await;
    assert_eq!(status, StatusCode::OK, "{body}");
    let response: Value = serde_json::from_str(&body).unwrap();
    assert_eq!(response.as_object().unwrap().len(), 500, "{body}");
}

#[tokio::test]
async fn rejects_a_window_one_bucket_over_the_budget() {
    let (_temp_db, router) = setup(&[]).await;

    assert_rejected(
        &router,
        &uri(T0_S, T0_S + 501 * HOUR_S, "3600"),
        "needs 501 buckets",
    )
    .await;
}

#[tokio::test]
async fn rejects_a_multi_decade_window() {
    let (_temp_db, router) = setup(&[]).await;

    // The report's shape: an unauthenticated decades-wide request at a one-second interval.
    // The window cap fires first here, whatever the interval — the bucket budget is pinned
    // separately by rejects_a_window_one_bucket_over_the_budget.
    assert_rejected(&router, &uri(0, T0_S, "1"), "exceeds the maximum").await;
}

#[tokio::test]
async fn serves_a_year_of_daily_buckets() {
    let (_temp_db, router) = setup(&[]).await;

    // The widest window the endpoint exists to serve: a year at daily granularity.
    let (status, body) = send(&router, &uri(T0_S, T0_S + 365 * DAY_S, "86400")).await;
    assert_eq!(status, StatusCode::OK, "{body}");
    let response: Value = serde_json::from_str(&body).unwrap();
    assert_eq!(response.as_object().unwrap().len(), 365, "{body}");
}

#[tokio::test]
async fn rejects_a_window_wider_than_the_maximum_range() {
    let (_temp_db, router) = setup(&[]).await;

    // A day past the cap, at a bucket count the budget would otherwise allow.
    assert_rejected(
        &router,
        &uri(T0_S, T0_S + 366 * DAY_S, "86400"),
        "exceeds the maximum",
    )
    .await;
}

#[tokio::test]
async fn rejects_an_unordered_or_negative_window() {
    let (_temp_db, router) = setup(&[]).await;

    assert_rejected(
        &router,
        &uri(T0_S + HOUR_S, T0_S, "3600"),
        "end_time must be greater than start_time",
    )
    .await;
    assert_rejected(
        &router,
        &uri(-1, T0_S, "3600"),
        "start_time must not be negative",
    )
    .await;
}

#[tokio::test]
async fn rejects_an_interval_that_overflows_or_does_not_parse() {
    let (_temp_db, router) = setup(&[]).await;

    // i64::MAX seconds overflows the conversion to milliseconds.
    assert_rejected(
        &router,
        &uri(T0_S, T0_S + HOUR_S, "9223372036854775807"),
        "is too large",
    )
    .await;
    assert_rejected(&router, &uri(T0_S, T0_S + HOUR_S, "0"), "greater than 0").await;
    assert_rejected(
        &router,
        &uri(T0_S, T0_S + HOUR_S, "-3600"),
        "greater than 0",
    )
    .await;
    assert_rejected(&router, &uri(T0_S, T0_S + HOUR_S, "1h"), "Invalid interval").await;
}

#[tokio::test]
async fn rejects_timestamps_that_overflow_the_millisecond_conversion() {
    let (_temp_db, router) = setup(&[]).await;

    // Seconds this large do not fit in milliseconds; the conversion saturates instead of wrapping
    // into a plausible window, and the saturated window is then rejected on its own terms.
    assert_rejected(&router, &uri(0, i64::MAX, "3600"), "exceeds the maximum").await;
    assert_rejected(
        &router,
        &uri(i64::MAX, i64::MAX, "3600"),
        "end_time must be greater than start_time",
    )
    .await;
}

#[tokio::test]
async fn terminates_when_end_time_saturates_to_the_i64_ceiling() {
    let (_temp_db, router) = setup(&[]).await;

    // end_time in seconds * 1000 clamps to exactly i64::MAX, and start_time defaults to one day
    // before it, so every budget check passes with 24 buckets. The walk must still terminate.
    let uri = format!(
        "/historical_volume_by_balance_manager_id_with_interval/{POOL_NAME}/{MANAGER_ID}\
         ?end_time=9223372036854776&interval=3600&volume_in_base=true",
    );
    let result =
        tokio::time::timeout(std::time::Duration::from_secs(30), send(&router, &uri)).await;
    let (status, body) = result.expect("request must terminate");
    assert_eq!(status, StatusCode::OK, "{body}");
    let response: Value = serde_json::from_str(&body).unwrap();
    assert_eq!(response.as_object().unwrap().len(), 24, "{body}");
}

#[tokio::test]
async fn repeated_pool_names_do_not_change_the_result() {
    let (_temp_db, router) = setup(&[FillSeed {
        tag: "maker-b0",
        timestamp_ms: (T0_S + HOUR_S / 2) * 1000,
        maker_balance_manager_id: MANAGER_ID,
        taker_balance_manager_id: OTHER_MANAGER_ID,
        base_quantity: 100,
    }])
    .await;

    let interval = format!("&interval={HOUR_S}");
    let end = T0_S + 4 * HOUR_S;
    let (single_status, single) =
        send(&router, &uri_for_pools(POOL_NAME, T0_S, end, &interval)).await;
    let repeated_names = format!("{POOL_NAME},{POOL_NAME},{POOL_NAME}");
    let (repeated_status, repeated) = send(
        &router,
        &uri_for_pools(&repeated_names, T0_S, end, &interval),
    )
    .await;

    assert_eq!(single_status, StatusCode::OK, "{single}");
    assert_eq!(repeated_status, StatusCode::OK, "{repeated}");
    assert_eq!(
        serde_json::from_str::<Value>(&single).unwrap(),
        serde_json::from_str::<Value>(&repeated).unwrap(),
        "deduplicating the pool list must not change what is served",
    );
}

#[tokio::test]
async fn defaults_to_hourly_buckets_when_no_interval_is_given() {
    let (_temp_db, router) = setup(&[]).await;

    let (status, body) = send(
        &router,
        &uri_for_pools(POOL_NAME, T0_S, T0_S + 4 * HOUR_S, ""),
    )
    .await;
    assert_eq!(status, StatusCode::OK, "{body}");
    let response: Value = serde_json::from_str(&body).unwrap();
    let buckets = response.as_object().unwrap();
    assert_eq!(buckets.len(), 4, "{body}");
    assert!(buckets.contains_key(&bucket(T0_S, T0_S + HOUR_S)), "{body}");
}
