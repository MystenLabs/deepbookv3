// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

use super::{
    config::{PythChartHistoryConfig, PythProConfig, DEFAULT_PRO_URL},
    models::normalize_history_resolution,
    proxy::{routes, PythProxy},
};
use axum::{
    extract::{OriginalUri, State},
    http::{
        header::{AUTHORIZATION, RETRY_AFTER},
        HeaderMap, StatusCode,
    },
    response::IntoResponse,
    routing::{get, post},
    Json, Router,
};
use futures::future::join_all;
use serde_json::{json, Value};
use std::{
    collections::HashMap,
    sync::{
        atomic::{AtomicUsize, Ordering},
        Arc, Mutex as StdMutex,
    },
    time::Duration,
};
use tokio::{
    net::TcpListener,
    task::JoinHandle,
    time::{sleep, timeout},
};
use url::Url;

const TEST_TIMESTAMP_US: u64 = 1_700_000_000_123_456;

#[derive(Clone, Default)]
struct MockPyth {
    latest_requests: Arc<AtomicUsize>,
    history_requests: Arc<AtomicUsize>,
    chart_history_requests: Arc<AtomicUsize>,
    captured: Arc<StdMutex<Vec<(String, String, Value)>>>,
    chart_history_captured: Arc<StdMutex<Vec<(String, String, String)>>>,
    delay: Duration,
}

async fn mock_prices(
    State(mock): State<MockPyth>,
    OriginalUri(uri): OriginalUri,
    headers: HeaderMap,
    Json(body): Json<Value>,
) -> impl IntoResponse {
    if uri.path().ends_with("/latest_price") {
        mock.latest_requests.fetch_add(1, Ordering::SeqCst);
    } else {
        mock.history_requests.fetch_add(1, Ordering::SeqCst);
    }
    let authorization = headers
        .get(AUTHORIZATION)
        .and_then(|value| value.to_str().ok())
        .unwrap_or_default()
        .to_owned();
    mock.captured
        .lock()
        .unwrap()
        .push((uri.path().to_owned(), authorization, body.clone()));

    if !mock.delay.is_zero() {
        sleep(mock.delay).await;
    }

    let timestamp_us = body
        .get("timestamp")
        .and_then(Value::as_u64)
        .unwrap_or(TEST_TIMESTAMP_US);
    let feed_ids = body["priceFeedIds"].as_array().unwrap();
    Json(json!({
        "parsed": {
            "timestampUs": timestamp_us.to_string(),
            "priceFeeds": feed_ids.iter().map(|id| {
                let id = id.as_u64().unwrap();
                json!({
                    "priceFeedId": id,
                    "price": (id * 100).to_string(),
                    "confidence": id + 3,
                    "exponent": -2,
                    "emaPrice": (id * 99).to_string(),
                    "emaConfidence": id + 4,
                    "feedUpdateTimestamp": timestamp_us
                })
            }).collect::<Vec<_>>()
        }
    }))
}

async fn mock_chart_history(
    State(mock): State<MockPyth>,
    OriginalUri(uri): OriginalUri,
    headers: HeaderMap,
) -> impl IntoResponse {
    mock.chart_history_requests.fetch_add(1, Ordering::SeqCst);
    let authorization = headers
        .get(AUTHORIZATION)
        .and_then(|value| value.to_str().ok())
        .unwrap_or_default()
        .to_owned();
    mock.chart_history_captured.lock().unwrap().push((
        uri.path().to_owned(),
        uri.query().unwrap_or_default().to_owned(),
        authorization,
    ));

    if !mock.delay.is_zero() {
        sleep(mock.delay).await;
    }

    Json(json!({
        "s": "ok",
        "t": [1_700_000_100_u64, 1_700_000_160_u64],
        "o": [100.0, 101.0],
        "h": [102.0, 103.0],
        "l": [99.0, 100.0],
        "c": [101.0, 102.0],
        "v": [0, 0]
    }))
}

async fn spawn(app: Router) -> (Url, JoinHandle<()>) {
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let address = listener.local_addr().unwrap();
    let task = tokio::spawn(async move {
        axum::serve(listener, app).await.unwrap();
    });
    (Url::parse(&format!("http://{address}")).unwrap(), task)
}

async fn spawn_mock(mock: MockPyth) -> (Url, JoinHandle<()>) {
    let app = Router::new()
        .route("/v1/latest_price", post(mock_prices))
        .route("/v1/price", post(mock_prices))
        .route("/v1/fixed_rate@200ms/history", get(mock_chart_history))
        .with_state(mock);
    let (url, task) = spawn(app).await;
    (url.join("/v1").unwrap(), task)
}

fn test_config(feed_ids: Vec<u32>) -> PythProConfig {
    PythProConfig {
        feed_ids,
        poll_interval: Duration::from_secs(60),
        max_staleness: Duration::from_secs(30),
        history_cache_ttl: Duration::from_secs(60),
        history_cache_max_entries: 100,
        chart_history: PythChartHistoryConfig {
            symbols: vec!["Crypto.BTC/USD".to_owned()],
            cache_ttl: Duration::from_secs(60),
            cache_max_entries: 100,
            max_range: Duration::from_secs(86_400),
            ..PythChartHistoryConfig::default()
        },
    }
}

async fn wait_for_latest(proxy: &PythProxy) {
    timeout(Duration::from_secs(1), async {
        loop {
            if proxy.has_latest_snapshot() {
                return;
            }
            sleep(Duration::from_millis(5)).await;
        }
    })
    .await
    .expect("latest-price poller did not populate the snapshot");
}

#[tokio::test]
async fn latest_handler_reads_only_the_background_snapshot() {
    let mock = MockPyth {
        delay: Duration::from_millis(40),
        ..Default::default()
    };
    let (upstream_url, upstream_task) = spawn_mock(mock.clone()).await;
    let proxy = PythProxy::new(
        upstream_url,
        Some("test-key".to_owned()),
        test_config(vec![1, 2]),
    )
    .unwrap();
    let (server_url, server_task) = spawn(Router::new().nest("/pyth", routes(proxy.clone()))).await;
    let url = server_url
        .join("/pyth/v2/updates/price/latest?ids%5B%5D=2&ids%5B%5D=1&parsed=true")
        .unwrap();

    let warming = reqwest::get(url.clone()).await.unwrap();
    assert_eq!(warming.status(), StatusCode::SERVICE_UNAVAILABLE);
    assert_eq!(warming.headers().get(RETRY_AFTER).unwrap(), "1");

    wait_for_latest(&proxy).await;
    let responses = join_all((0..20).map(|_| reqwest::get(url.clone()))).await;
    for response in responses {
        assert_eq!(response.unwrap().status(), StatusCode::OK);
    }
    assert_eq!(mock.latest_requests.load(Ordering::SeqCst), 1);

    let response = reqwest::get(url).await.unwrap();
    let json = response.json::<Value>().await.unwrap();
    assert_eq!(json["parsed"][0]["id"], "2");
    assert_eq!(json["parsed"][1]["id"], "1");
    assert_eq!(
        json["parsed"][0]["metadata"]["publish_time_us"],
        TEST_TIMESTAMP_US.to_string()
    );

    let captured = mock.captured.lock().unwrap();
    assert_eq!(captured[0].0, "/v1/latest_price");
    assert_eq!(captured[0].1, "Bearer test-key");
    assert_eq!(captured[0].2["priceFeedIds"], json!([1, 2]));
    assert_eq!(captured[0].2["channel"], "fixed_rate@1000ms");
    assert_eq!(captured[0].2["parsed"], true);
    assert!(captured[0].2.get("timestamp").is_none());

    server_task.abort();
    upstream_task.abort();
}

#[tokio::test]
async fn stale_latest_snapshot_is_not_served() {
    let mock = MockPyth::default();
    let (upstream_url, upstream_task) = spawn_mock(mock).await;
    let mut config = test_config(vec![1]);
    config.max_staleness = Duration::from_millis(20);
    let proxy = PythProxy::new(upstream_url, Some("test-key".to_owned()), config).unwrap();
    wait_for_latest(&proxy).await;
    sleep(Duration::from_millis(30)).await;
    let (server_url, server_task) = spawn(Router::new().nest("/pyth", routes(proxy))).await;

    let response = reqwest::get(
        server_url
            .join("/pyth/v2/updates/price/latest?ids%5B%5D=1")
            .unwrap(),
    )
    .await
    .unwrap();
    assert_eq!(response.status(), StatusCode::BAD_GATEWAY);
    assert_eq!(
        response.text().await.unwrap(),
        "Pyth Pro latest-price snapshot is stale"
    );

    server_task.abort();
    upstream_task.abort();
}

#[tokio::test]
async fn historical_cache_is_keyed_by_feed_and_timestamp() {
    let mock = MockPyth::default();
    let (upstream_url, upstream_task) = spawn_mock(mock.clone()).await;
    let proxy = PythProxy::new(
        upstream_url,
        Some("test-key".to_owned()),
        test_config(vec![1, 2, 3]),
    )
    .unwrap();
    let (server_url, server_task) = spawn(Router::new().nest("/pyth", routes(proxy))).await;
    let first_url = server_url
        .join("/pyth/v2/updates/price/1700000000?ids%5B%5D=1&ids%5B%5D=2&parsed=true")
        .unwrap();

    let first = reqwest::get(first_url).await.unwrap();
    assert_eq!(first.status(), StatusCode::OK);
    assert_eq!(mock.history_requests.load(Ordering::SeqCst), 1);

    let cached = reqwest::get(
        server_url
            .join("/pyth/v2/updates/price/1700000000?ids%5B%5D=2")
            .unwrap(),
    )
    .await
    .unwrap();
    assert_eq!(cached.status(), StatusCode::OK);
    assert_eq!(mock.history_requests.load(Ordering::SeqCst), 1);

    let partial_miss = reqwest::get(
        server_url
            .join("/pyth/v2/updates/price/1700000000?ids%5B%5D=2&ids%5B%5D=3")
            .unwrap(),
    )
    .await
    .unwrap();
    assert_eq!(partial_miss.status(), StatusCode::OK);
    let json = partial_miss.json::<Value>().await.unwrap();
    assert_eq!(json["parsed"][0]["id"], "2");
    assert_eq!(json["parsed"][1]["id"], "3");
    assert_eq!(mock.history_requests.load(Ordering::SeqCst), 2);

    let captured = mock.captured.lock().unwrap();
    let history_calls: Vec<_> = captured
        .iter()
        .filter(|(path, _, _)| path == "/v1/price")
        .collect();
    assert_eq!(history_calls.len(), 2);
    assert_eq!(
        history_calls[0].2["timestamp"],
        json!(1_700_000_000_000_000_u64)
    );
    assert_eq!(history_calls[0].2["priceFeedIds"], json!([1, 2]));
    assert_eq!(history_calls[1].2["priceFeedIds"], json!([3]));

    server_task.abort();
    upstream_task.abort();
}

#[tokio::test]
async fn concurrent_identical_history_misses_share_one_load() {
    let mock = MockPyth {
        delay: Duration::from_millis(40),
        ..Default::default()
    };
    let (upstream_url, upstream_task) = spawn_mock(mock.clone()).await;
    let proxy = PythProxy::new(
        upstream_url,
        Some("test-key".to_owned()),
        test_config(vec![1, 2]),
    )
    .unwrap();
    let (server_url, server_task) = spawn(Router::new().nest("/pyth", routes(proxy))).await;
    let url = server_url
        .join("/pyth/v2/updates/price/1700000000?ids%5B%5D=1&ids%5B%5D=2")
        .unwrap();

    let (first, second) = tokio::join!(reqwest::get(url.clone()), reqwest::get(url));
    assert_eq!(first.unwrap().status(), StatusCode::OK);
    assert_eq!(second.unwrap().status(), StatusCode::OK);
    assert_eq!(mock.history_requests.load(Ordering::SeqCst), 1);

    server_task.abort();
    upstream_task.abort();
}

#[tokio::test]
async fn history_errors_are_not_cached() {
    #[derive(Clone, Default)]
    struct Count(Arc<AtomicUsize>);

    async fn rate_limited(State(count): State<Count>) -> impl IntoResponse {
        count.0.fetch_add(1, Ordering::SeqCst);
        (
            StatusCode::TOO_MANY_REQUESTS,
            [(RETRY_AFTER, "3")],
            "rate limited",
        )
    }

    let count = Count::default();
    let upstream = Router::new()
        .route("/v1/price", post(rate_limited))
        .with_state(count.clone());
    let (upstream_url, upstream_task) = spawn(upstream).await;
    let proxy = PythProxy::new(
        upstream_url.join("/v1").unwrap(),
        Some("test-key".to_owned()),
        test_config(vec![1]),
    )
    .unwrap();
    let (server_url, server_task) = spawn(Router::new().nest("/pyth", routes(proxy))).await;
    let url = server_url
        .join("/pyth/v2/updates/price/1700000000?ids%5B%5D=1")
        .unwrap();

    for _ in 0..2 {
        let response = reqwest::get(url.clone()).await.unwrap();
        assert_eq!(response.status(), StatusCode::TOO_MANY_REQUESTS);
        assert_eq!(response.headers().get(RETRY_AFTER).unwrap(), "3");
        assert_eq!(response.text().await.unwrap(), "rate limited");
    }
    assert_eq!(count.0.load(Ordering::SeqCst), 2);

    server_task.abort();
    upstream_task.abort();
}

#[tokio::test]
async fn chart_history_normalizes_and_coalesces_requests() {
    let mock = MockPyth {
        delay: Duration::from_millis(40),
        ..Default::default()
    };
    let (upstream_url, upstream_task) = spawn_mock(mock.clone()).await;
    let mut config = test_config(Vec::new());
    config.chart_history.upstream_url = upstream_url.clone();
    let proxy = PythProxy::new(upstream_url, Some("test-key".to_owned()), config).unwrap();
    let (server_url, server_task) = spawn(Router::new().nest("/pyth", routes(proxy))).await;
    let url = server_url
        .join(
            "/pyth/v1/shims/tradingview/history?symbol=Crypto.BTC%2FUSD&resolution=1&from=1700000041&to=1700003699",
        )
        .unwrap();

    let responses = join_all((0..20).map(|_| reqwest::get(url.clone()))).await;
    for response in responses {
        let response = response.unwrap();
        assert_eq!(response.status(), StatusCode::OK);
        let body = response.json::<Value>().await.unwrap();
        assert_eq!(body["s"], "ok");
        assert_eq!(body["c"], json!([101.0, 102.0]));
    }
    assert_eq!(mock.chart_history_requests.load(Ordering::SeqCst), 1);

    let captured = mock.chart_history_captured.lock().unwrap();
    assert_eq!(captured.len(), 1);
    assert_eq!(captured[0].0, "/v1/fixed_rate@200ms/history");
    assert_eq!(captured[0].2, "Bearer test-key");
    let query: HashMap<_, _> = url::form_urlencoded::parse(captured[0].1.as_bytes())
        .into_owned()
        .collect();
    assert_eq!(query["symbol"], "crypto.btc/usd");
    assert_eq!(query["resolution"], "1");
    assert_eq!(query["from"], "1700000100");
    assert_eq!(query["to"], "1700003640");
    drop(captured);

    let equivalent_url = server_url
        .join(
            "/pyth/v1/shims/tradingview/history?symbol=crypto.btc%2Fusd&resolution=1&from=1700000100&to=1700003641",
        )
        .unwrap();
    let cached = reqwest::get(equivalent_url).await.unwrap();
    assert_eq!(cached.status(), StatusCode::OK);
    assert_eq!(mock.chart_history_requests.load(Ordering::SeqCst), 1);

    server_task.abort();
    upstream_task.abort();
}

#[test]
fn chart_history_canonicalizes_tradingview_resolution_aliases() {
    for (resolution, canonical) in [
        ("d", "D"),
        ("1D", "D"),
        ("w", "W"),
        ("1W", "W"),
        ("m", "M"),
        ("1M", "M"),
    ] {
        assert_eq!(normalize_history_resolution(resolution).unwrap(), canonical);
    }
}

#[tokio::test]
async fn chart_history_rejects_unsupported_queries_without_loading() {
    let mock = MockPyth::default();
    let (upstream_url, upstream_task) = spawn_mock(mock.clone()).await;
    let mut config = test_config(Vec::new());
    config.chart_history.upstream_url = upstream_url.clone();
    let proxy = PythProxy::new(upstream_url, Some("test-key".to_owned()), config).unwrap();
    let (server_url, server_task) = spawn(Router::new().nest("/pyth", routes(proxy))).await;

    for query in [
        "symbol=Crypto.ETH%2FUSD&resolution=1&from=1700000000&to=1700003600",
        "symbol=Crypto.BTC%2FUSD&resolution=3&from=1700000000&to=1700003600",
        "symbol=Crypto.BTC%2FUSD&resolution=1&from=1700003600&to=1700000000",
        "symbol=Crypto.BTC%2FUSD&resolution=1&from=1700000000&to=1700100000",
    ] {
        let response = reqwest::get(
            server_url
                .join(&format!("/pyth/v1/shims/tradingview/history?{query}"))
                .unwrap(),
        )
        .await
        .unwrap();
        assert_eq!(response.status(), StatusCode::BAD_REQUEST);
    }
    assert_eq!(mock.chart_history_requests.load(Ordering::SeqCst), 0);

    server_task.abort();
    upstream_task.abort();
}

#[tokio::test]
async fn chart_history_errors_are_not_cached() {
    #[derive(Clone, Default)]
    struct Count(Arc<AtomicUsize>);

    async fn rate_limited(State(count): State<Count>) -> impl IntoResponse {
        count.0.fetch_add(1, Ordering::SeqCst);
        (
            StatusCode::TOO_MANY_REQUESTS,
            [(RETRY_AFTER, "3")],
            "rate limited",
        )
    }

    let count = Count::default();
    let upstream = Router::new()
        .route("/v1/fixed_rate@200ms/history", get(rate_limited))
        .with_state(count.clone());
    let (upstream_url, upstream_task) = spawn(upstream).await;
    let history_url = upstream_url.join("/v1").unwrap();
    let mut config = test_config(Vec::new());
    config.chart_history.upstream_url = history_url.clone();
    let proxy = PythProxy::new(history_url, Some("test-key".to_owned()), config).unwrap();
    let (server_url, server_task) = spawn(Router::new().nest("/pyth", routes(proxy))).await;
    let url = server_url
        .join(
            "/pyth/v1/shims/tradingview/history?symbol=Crypto.BTC%2FUSD&resolution=1&from=1700000000&to=1700003600",
        )
        .unwrap();

    for _ in 0..2 {
        let response = reqwest::get(url.clone()).await.unwrap();
        assert_eq!(response.status(), StatusCode::TOO_MANY_REQUESTS);
        assert_eq!(response.headers().get(RETRY_AFTER).unwrap(), "3");
        assert_eq!(response.text().await.unwrap(), "rate limited");
    }
    assert_eq!(count.0.load(Ordering::SeqCst), 2);

    server_task.abort();
    upstream_task.abort();
}

#[tokio::test]
async fn invalid_queries_and_missing_configuration_are_rejected() {
    let proxy = PythProxy::new(
        Url::parse(DEFAULT_PRO_URL).unwrap(),
        None,
        test_config(Vec::new()),
    )
    .unwrap();
    let (server_url, server_task) = spawn(Router::new().nest("/pyth", routes(proxy))).await;

    let invalid = reqwest::get(
        server_url
            .join("/pyth/v2/updates/price/latest?ids%5B%5D=not-a-number")
            .unwrap(),
    )
    .await
    .unwrap();
    assert_eq!(invalid.status(), StatusCode::BAD_REQUEST);

    let unavailable = reqwest::get(
        server_url
            .join("/pyth/v2/updates/price/latest?ids%5B%5D=1")
            .unwrap(),
    )
    .await
    .unwrap();
    assert_eq!(unavailable.status(), StatusCode::SERVICE_UNAVAILABLE);
    assert_eq!(
        unavailable.text().await.unwrap(),
        "Pyth Pro is not configured"
    );

    server_task.abort();
}
