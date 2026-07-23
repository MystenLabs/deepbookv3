// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

use axum::{
    body::Body,
    extract::{Path, RawQuery, State},
    http::{
        header::{CACHE_CONTROL, CONTENT_TYPE, RETRY_AFTER},
        HeaderMap, StatusCode,
    },
    response::{IntoResponse, Response},
    routing::get,
    Router,
};
use bytes::Bytes;
use futures::future::{BoxFuture, FutureExt, Shared};
use secrecy::{ExposeSecret, Secret};
use std::{collections::HashMap, sync::Arc, time::Duration};
use tokio::{
    sync::{oneshot, Mutex},
    time::Instant,
};
use url::Url;

pub const DEFAULT_HERMES_URL: &str = "https://pyth.dourolabs.app/hermes";
pub const DEFAULT_LATEST_CACHE_TTL_MS: u64 = 1_000;
pub const DEFAULT_HISTORICAL_CACHE_TTL_SECS: u64 = 300;
pub const DEFAULT_CACHE_MAX_ENTRIES: usize = 1_024;
pub const LATEST_PRICE_PATH: &str = "/v2/updates/price/latest";
pub const PRICE_AT_TIMESTAMP_PATH: &str = "/v2/updates/price/:publish_time";

#[derive(Clone, Copy, Debug)]
pub struct PythCacheConfig {
    pub latest_ttl: Duration,
    pub historical_ttl: Duration,
    pub max_entries: usize,
}

impl Default for PythCacheConfig {
    fn default() -> Self {
        Self {
            latest_ttl: Duration::from_millis(DEFAULT_LATEST_CACHE_TTL_MS),
            historical_ttl: Duration::from_secs(DEFAULT_HISTORICAL_CACHE_TTL_SECS),
            max_entries: DEFAULT_CACHE_MAX_ENTRIES,
        }
    }
}

#[derive(Clone)]
struct CachedResponse {
    status: StatusCode,
    headers: HeaderMap,
    body: Bytes,
}

impl CachedResponse {
    fn into_response(self) -> Response {
        let mut response = Response::new(Body::from(self.body));
        *response.status_mut() = self.status;
        for name in [CONTENT_TYPE, CACHE_CONTROL, RETRY_AFTER] {
            if let Some(value) = self.headers.get(&name) {
                response.headers_mut().insert(name, value.clone());
            }
        }
        response
    }
}

#[derive(Clone, Debug, thiserror::Error)]
enum LoadError {
    #[error("request failed: {0}")]
    Request(String),
    #[error("response body failed: {0}")]
    ResponseBody(String),
    #[error("loader task stopped before returning a response")]
    LoaderTaskStopped,
}

type SharedLoad = Shared<BoxFuture<'static, Result<CachedResponse, LoadError>>>;

struct CacheEntry {
    response: CachedResponse,
    expires_at: Instant,
}

struct ResponseLoader {
    cache: Mutex<HashMap<String, CacheEntry>>,
    in_flight: Mutex<HashMap<String, SharedLoad>>,
    max_entries: usize,
}

impl ResponseLoader {
    fn new(max_entries: usize) -> Self {
        Self {
            cache: Mutex::new(HashMap::new()),
            in_flight: Mutex::new(HashMap::new()),
            max_entries,
        }
    }

    async fn cached(&self, key: &str) -> Option<CachedResponse> {
        let now = Instant::now();
        let mut cache = self.cache.lock().await;
        if let Some(entry) = cache.get(key) {
            if entry.expires_at > now {
                return Some(entry.response.clone());
            }
        }
        cache.remove(key);
        None
    }

    async fn insert(&self, key: String, response: CachedResponse, ttl: Duration) {
        if ttl.is_zero() || self.max_entries == 0 {
            return;
        }

        let now = Instant::now();
        let mut cache = self.cache.lock().await;
        cache.retain(|_, entry| entry.expires_at > now);
        if cache.len() >= self.max_entries && !cache.contains_key(&key) {
            if let Some(oldest) = cache
                .iter()
                .min_by_key(|(_, entry)| entry.expires_at)
                .map(|(key, _)| key.clone())
            {
                cache.remove(&oldest);
            }
        }
        cache.insert(
            key,
            CacheEntry {
                response,
                expires_at: now + ttl,
            },
        );
    }
}

/// Authenticated server-side access to Pyth's upgraded Hermes service.
///
/// The public routes deliberately preserve the Hermes paths, query parameters,
/// statuses, and response bodies so existing Hermes SDK clients can use the
/// DeepBook Server by changing only their base URL.
#[derive(Clone)]
pub struct PythProxy {
    upstream_url: Url,
    api_key: Option<Arc<Secret<String>>>,
    http: reqwest::Client,
    cache_config: PythCacheConfig,
    loader: Arc<ResponseLoader>,
}

impl PythProxy {
    pub fn new(
        upstream_url: Url,
        api_key: Option<String>,
        cache_config: PythCacheConfig,
    ) -> Result<Self, anyhow::Error> {
        let api_key = api_key
            .map(|key| key.trim().to_owned())
            .filter(|key| !key.is_empty())
            .map(Secret::new)
            .map(Arc::new);
        if api_key.is_none() {
            tracing::warn!(
                "No Pyth API key configured (PYTH_API_KEY); Pyth proxy routes will return HTTP 503"
            );
        }
        let http = reqwest::Client::builder()
            .user_agent("deepbook-server")
            .timeout(Duration::from_secs(10))
            .build()?;

        Ok(Self {
            upstream_url,
            api_key,
            http,
            cache_config,
            loader: Arc::new(ResponseLoader::new(cache_config.max_entries)),
        })
    }

    fn endpoint(&self, path: &str, query: Option<&str>) -> Url {
        let mut url = self.upstream_url.clone();
        let mut full_path = url.path().trim_end_matches('/').to_owned();
        full_path.push('/');
        full_path.push_str(path.trim_start_matches('/'));
        url.set_path(&full_path);
        url.set_query(query);
        url
    }

    async fn fetch_upstream(
        &self,
        path: &str,
        query: Option<&str>,
    ) -> Result<CachedResponse, LoadError> {
        let api_key = self
            .api_key
            .as_ref()
            .expect("fetch_upstream is called only when Pyth is configured");
        let upstream = match self
            .http
            .get(self.endpoint(path, query))
            .bearer_auth(api_key.expose_secret())
            .send()
            .await
        {
            Ok(response) => response,
            Err(error) => return Err(LoadError::Request(error.to_string())),
        };

        let status = upstream.status();
        let headers = upstream.headers().clone();
        let body = upstream
            .bytes()
            .await
            .map_err(|error| LoadError::ResponseBody(error.to_string()))?;

        Ok(CachedResponse {
            status,
            headers,
            body,
        })
    }

    async fn load(
        &self,
        path: &str,
        query: Option<&str>,
        ttl: Duration,
    ) -> Result<CachedResponse, LoadError> {
        let key = match query {
            Some(query) => format!("{path}?{query}"),
            None => path.to_owned(),
        };
        if let Some(response) = self.loader.cached(&key).await {
            return Ok(response);
        }

        let load = {
            let mut in_flight = self.loader.in_flight.lock().await;
            match in_flight.get(&key) {
                Some(load) => load.clone(),
                None => {
                    // The previous load may have populated the cache between
                    // the first cache lookup and acquiring this lock.
                    if let Some(response) = self.loader.cached(&key).await {
                        return Ok(response);
                    }
                    let proxy = self.clone();
                    let path = path.to_owned();
                    let query = query.map(str::to_owned);
                    let load_key = key.clone();
                    let (sender, receiver) = oneshot::channel();
                    let load =
                        async move { receiver.await.unwrap_or(Err(LoadError::LoaderTaskStopped)) }
                            .boxed()
                            .shared();
                    in_flight.insert(key.clone(), load.clone());
                    tokio::spawn(async move {
                        let result = proxy.fetch_upstream(&path, query.as_deref()).await;
                        if let Ok(response) = &result {
                            if response.status.is_success() {
                                proxy
                                    .loader
                                    .insert(load_key.clone(), response.clone(), ttl)
                                    .await;
                            }
                        }
                        proxy.loader.in_flight.lock().await.remove(&load_key);
                        let _ = sender.send(result);
                    });
                    load
                }
            }
        };

        load.await
    }

    async fn get(&self, path: &str, query: Option<&str>, ttl: Duration) -> Response {
        if self.api_key.is_none() {
            return (
                StatusCode::SERVICE_UNAVAILABLE,
                "Pyth price service is not configured",
            )
                .into_response();
        }

        match self.load(path, query, ttl).await {
            Ok(response) => response.into_response(),
            Err(error) => {
                tracing::error!(%error, "Pyth Hermes request failed");
                (StatusCode::BAD_GATEWAY, "Pyth price service is unavailable").into_response()
            }
        }
    }
}

pub fn routes(proxy: PythProxy) -> Router {
    Router::new()
        .route(LATEST_PRICE_PATH, get(latest_price))
        .route(PRICE_AT_TIMESTAMP_PATH, get(price_at_timestamp))
        .with_state(proxy)
}

async fn latest_price(State(proxy): State<PythProxy>, RawQuery(query): RawQuery) -> Response {
    proxy
        .get(
            LATEST_PRICE_PATH,
            query.as_deref(),
            proxy.cache_config.latest_ttl,
        )
        .await
}

async fn price_at_timestamp(
    Path(publish_time): Path<u64>,
    State(proxy): State<PythProxy>,
    RawQuery(query): RawQuery,
) -> Response {
    proxy
        .get(
            &format!("/v2/updates/price/{publish_time}"),
            query.as_deref(),
            proxy.cache_config.historical_ttl,
        )
        .await
}

#[cfg(test)]
mod tests {
    use super::*;
    use axum::{
        extract::{OriginalUri, State},
        http::{header::AUTHORIZATION, HeaderMap},
        Json,
    };
    use serde_json::json;
    use std::sync::{
        atomic::{AtomicUsize, Ordering},
        Mutex,
    };
    use tokio::{net::TcpListener, task::JoinHandle, time::sleep};

    #[derive(Clone, Default)]
    struct Capture {
        request: Arc<Mutex<Option<(String, String, String)>>>,
        request_count: Arc<AtomicUsize>,
    }

    async fn mock_hermes(
        State(capture): State<Capture>,
        OriginalUri(uri): OriginalUri,
        RawQuery(query): RawQuery,
        headers: HeaderMap,
    ) -> impl IntoResponse {
        capture.request_count.fetch_add(1, Ordering::SeqCst);
        let authorization = headers
            .get(AUTHORIZATION)
            .and_then(|value| value.to_str().ok())
            .unwrap_or_default()
            .to_owned();
        *capture.request.lock().unwrap() = Some((
            uri.path().to_owned(),
            query.unwrap_or_default(),
            authorization,
        ));

        (
            [(CONTENT_TYPE, "application/json")],
            Json(json!({
                "binary": { "encoding": "hex", "data": [] },
                "parsed": [{
                    "id": "abc",
                    "price": {
                        "price": "123",
                        "conf": "4",
                        "expo": -2,
                        "publish_time": 1_700_000_000
                    }
                }]
            })),
        )
    }

    async fn spawn(app: Router) -> (Url, JoinHandle<()>) {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let address = listener.local_addr().unwrap();
        let task = tokio::spawn(async move {
            axum::serve(listener, app).await.unwrap();
        });
        (Url::parse(&format!("http://{address}")).unwrap(), task)
    }

    #[tokio::test]
    async fn latest_price_preserves_hermes_contract_and_injects_api_key() {
        let capture = Capture::default();
        let upstream = Router::new()
            .route("/hermes/v2/updates/price/latest", get(mock_hermes))
            .with_state(capture.clone());
        let (upstream_url, upstream_task) = spawn(upstream).await;
        let proxy = PythProxy::new(
            upstream_url.join("/hermes").unwrap(),
            Some("test-key".to_owned()),
            PythCacheConfig::default(),
        )
        .unwrap();
        let (server_url, server_task) = spawn(Router::new().nest("/pyth", routes(proxy))).await;

        let response = reqwest::get(
            server_url
                .join("/pyth/v2/updates/price/latest?ids%5B%5D=abc&parsed=true")
                .unwrap(),
        )
        .await
        .unwrap();

        assert_eq!(response.status(), StatusCode::OK);
        assert_eq!(
            response.headers().get(CONTENT_TYPE).unwrap(),
            "application/json"
        );
        assert_eq!(
            response.json::<serde_json::Value>().await.unwrap()["parsed"][0]["id"],
            "abc"
        );
        assert_eq!(
            capture.request.lock().unwrap().clone().unwrap(),
            (
                "/hermes/v2/updates/price/latest".to_owned(),
                "ids%5B%5D=abc&parsed=true".to_owned(),
                "Bearer test-key".to_owned(),
            )
        );

        let cached_response = reqwest::get(
            server_url
                .join("/pyth/v2/updates/price/latest?ids%5B%5D=abc&parsed=true")
                .unwrap(),
        )
        .await
        .unwrap();
        assert_eq!(cached_response.status(), StatusCode::OK);
        assert_eq!(capture.request_count.load(Ordering::SeqCst), 1);

        server_task.abort();
        upstream_task.abort();
    }

    #[tokio::test]
    async fn concurrent_identical_requests_share_one_upstream_load() {
        async fn delayed(State(request_count): State<Arc<AtomicUsize>>) -> impl IntoResponse {
            request_count.fetch_add(1, Ordering::SeqCst);
            sleep(Duration::from_millis(50)).await;
            ([(CONTENT_TYPE, "application/json")], "{}")
        }

        let request_count = Arc::new(AtomicUsize::new(0));
        let upstream = Router::new()
            .route("/hermes/v2/updates/price/latest", get(delayed))
            .with_state(request_count.clone());
        let (upstream_url, upstream_task) = spawn(upstream).await;
        let proxy = PythProxy::new(
            upstream_url.join("/hermes").unwrap(),
            Some("test-key".to_owned()),
            PythCacheConfig::default(),
        )
        .unwrap();
        let (server_url, server_task) = spawn(Router::new().nest("/pyth", routes(proxy))).await;
        let url = server_url
            .join("/pyth/v2/updates/price/latest?ids%5B%5D=abc")
            .unwrap();

        let (first, second) = tokio::join!(reqwest::get(url.clone()), reqwest::get(url));
        assert_eq!(first.unwrap().status(), StatusCode::OK);
        assert_eq!(second.unwrap().status(), StatusCode::OK);
        assert_eq!(request_count.load(Ordering::SeqCst), 1);

        server_task.abort();
        upstream_task.abort();
    }

    #[tokio::test]
    async fn response_cache_is_bounded_and_expires_entries() {
        fn cached_response(body: &'static str) -> CachedResponse {
            CachedResponse {
                status: StatusCode::OK,
                headers: HeaderMap::new(),
                body: Bytes::from_static(body.as_bytes()),
            }
        }

        let loader = ResponseLoader::new(1);
        loader
            .insert(
                "first".to_owned(),
                cached_response("first"),
                Duration::from_secs(60),
            )
            .await;
        loader
            .insert(
                "second".to_owned(),
                cached_response("second"),
                Duration::from_secs(60),
            )
            .await;

        assert!(loader.cached("first").await.is_none());
        assert_eq!(
            loader.cached("second").await.unwrap().body,
            Bytes::from_static(b"second")
        );

        loader
            .insert(
                "expiring".to_owned(),
                cached_response("expiring"),
                Duration::from_millis(10),
            )
            .await;
        sleep(Duration::from_millis(30)).await;
        assert!(loader.cached("expiring").await.is_none());
    }

    #[tokio::test]
    async fn timestamp_route_preserves_upstream_errors_without_caching_them() {
        async fn unavailable(
            State(request_count): State<Arc<AtomicUsize>>,
            OriginalUri(uri): OriginalUri,
        ) -> impl IntoResponse {
            request_count.fetch_add(1, Ordering::SeqCst);
            assert_eq!(uri.path(), "/hermes/v2/updates/price/1700000000");
            (
                StatusCode::TOO_MANY_REQUESTS,
                [(RETRY_AFTER, "3")],
                "rate limited",
            )
        }

        let request_count = Arc::new(AtomicUsize::new(0));
        let upstream = Router::new()
            .route("/hermes/v2/updates/price/:publish_time", get(unavailable))
            .with_state(request_count.clone());
        let (upstream_url, upstream_task) = spawn(upstream).await;
        let proxy = PythProxy::new(
            upstream_url.join("/hermes").unwrap(),
            Some("test-key".to_owned()),
            PythCacheConfig::default(),
        )
        .unwrap();
        let (server_url, server_task) = spawn(Router::new().nest("/pyth", routes(proxy))).await;

        let response = reqwest::get(
            server_url
                .join("/pyth/v2/updates/price/1700000000?ids%5B%5D=abc")
                .unwrap(),
        )
        .await
        .unwrap();

        assert_eq!(response.status(), StatusCode::TOO_MANY_REQUESTS);
        assert_eq!(response.headers().get(RETRY_AFTER).unwrap(), "3");
        assert_eq!(response.text().await.unwrap(), "rate limited");

        let retry = reqwest::get(
            server_url
                .join("/pyth/v2/updates/price/1700000000?ids%5B%5D=abc")
                .unwrap(),
        )
        .await
        .unwrap();
        assert_eq!(retry.status(), StatusCode::TOO_MANY_REQUESTS);
        assert_eq!(request_count.load(Ordering::SeqCst), 2);

        server_task.abort();
        upstream_task.abort();
    }

    #[tokio::test]
    async fn routes_are_unavailable_without_an_api_key() {
        let proxy = PythProxy::new(
            Url::parse(DEFAULT_HERMES_URL).unwrap(),
            None,
            PythCacheConfig::default(),
        )
        .unwrap();
        let (server_url, server_task) = spawn(Router::new().nest("/pyth", routes(proxy))).await;

        let response = reqwest::get(
            server_url
                .join("/pyth/v2/updates/price/latest?ids%5B%5D=abc")
                .unwrap(),
        )
        .await
        .unwrap();

        assert_eq!(response.status(), StatusCode::SERVICE_UNAVAILABLE);
        assert_eq!(
            response.text().await.unwrap(),
            "Pyth price service is not configured"
        );

        server_task.abort();
    }
}
