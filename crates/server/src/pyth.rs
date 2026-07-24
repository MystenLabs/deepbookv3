// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

use axum::{
    extract::{Path, RawQuery, State},
    http::{
        header::{HeaderValue, RETRY_AFTER},
        StatusCode,
    },
    response::{IntoResponse, Response},
    routing::get,
    Json, Router,
};
use moka::future::Cache;
use secrecy::{ExposeSecret, Secret};
use serde::{Deserialize, Serialize};
use std::{
    collections::{HashMap, HashSet},
    sync::Arc,
    time::Duration,
};
use tokio::{
    sync::{watch, Mutex},
    time::{Instant, MissedTickBehavior},
};
use url::Url;

pub const DEFAULT_PRO_URL: &str = "https://pyth-lazer-0.dourolabs.app/v1";
pub const DEFAULT_POLL_INTERVAL_MS: u64 = 1_000;
pub const DEFAULT_MAX_STALENESS_MS: u64 = 5_000;
pub const DEFAULT_HISTORY_CACHE_TTL_SECS: u64 = 86_400;
pub const DEFAULT_HISTORY_CACHE_MAX_ENTRIES: u64 = 10_000;
pub const LATEST_PRICE_PATH: &str = "/v2/updates/price/latest";
pub const PRICE_AT_TIMESTAMP_PATH: &str = "/v2/updates/price/:publish_time";

const MICROS_PER_SECOND: u64 = 1_000_000;
const LATEST_UPSTREAM_PATH: &str = "latest_price";
const HISTORY_UPSTREAM_PATH: &str = "price";

#[derive(Clone, Debug)]
pub struct PythProConfig {
    pub feed_ids: Vec<u32>,
    pub poll_interval: Duration,
    pub max_staleness: Duration,
    pub history_cache_ttl: Duration,
    pub history_cache_max_entries: u64,
}

impl Default for PythProConfig {
    fn default() -> Self {
        Self {
            feed_ids: Vec::new(),
            poll_interval: Duration::from_millis(DEFAULT_POLL_INTERVAL_MS),
            max_staleness: Duration::from_millis(DEFAULT_MAX_STALENESS_MS),
            history_cache_ttl: Duration::from_secs(DEFAULT_HISTORY_CACHE_TTL_SECS),
            history_cache_max_entries: DEFAULT_HISTORY_CACHE_MAX_ENTRIES,
        }
    }
}

#[derive(Clone, Debug)]
struct PriceQuery {
    ids: Vec<u32>,
    ignore_invalid_price_ids: bool,
}

impl PriceQuery {
    fn parse(raw_query: Option<&str>) -> Result<Self, String> {
        let mut ids = Vec::new();
        let mut parsed = true;
        let mut ignore_invalid_price_ids = false;

        for (name, value) in url::form_urlencoded::parse(raw_query.unwrap_or_default().as_bytes()) {
            match name.as_ref() {
                "ids[]" | "ids" => {
                    let id = value.parse::<u32>().map_err(|_| {
                        format!("invalid Pyth Pro feed id `{value}`; expected an unsigned integer")
                    })?;
                    ids.push(id);
                }
                "parsed" => {
                    parsed = value
                        .parse::<bool>()
                        .map_err(|_| "`parsed` must be true or false".to_owned())?;
                }
                "ignore_invalid_price_ids" => {
                    ignore_invalid_price_ids = value.parse::<bool>().map_err(|_| {
                        "`ignore_invalid_price_ids` must be true or false".to_owned()
                    })?;
                }
                _ => {}
            }
        }

        if ids.is_empty() {
            return Err("at least one `ids[]` Pyth Pro feed id is required".to_owned());
        }
        if !parsed {
            return Err("only parsed Pyth Pro price responses are supported".to_owned());
        }

        Ok(Self {
            ids,
            ignore_invalid_price_ids,
        })
    }

    fn unique_ids(&self) -> Vec<u32> {
        let mut seen = HashSet::new();
        self.ids
            .iter()
            .copied()
            .filter(|id| seen.insert(*id))
            .collect()
    }
}

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct PythProRequest {
    price_feed_ids: Vec<u32>,
    properties: Vec<PythProProperty>,
    formats: Vec<String>,
    channel: PythProChannel,
    parsed: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    timestamp: Option<u64>,
}

impl PythProRequest {
    fn latest(price_feed_ids: Vec<u32>) -> Self {
        Self::new(price_feed_ids, None)
    }

    fn historical(price_feed_ids: Vec<u32>, timestamp_us: u64) -> Self {
        Self::new(price_feed_ids, Some(timestamp_us))
    }

    fn new(price_feed_ids: Vec<u32>, timestamp: Option<u64>) -> Self {
        Self {
            price_feed_ids,
            properties: vec![
                PythProProperty::Price,
                PythProProperty::Confidence,
                PythProProperty::Exponent,
                PythProProperty::EmaPrice,
                PythProProperty::EmaConfidence,
                PythProProperty::FeedUpdateTimestamp,
            ],
            formats: Vec::new(),
            channel: PythProChannel::FixedRate1000Ms,
            parsed: true,
            timestamp,
        }
    }
}

#[derive(Clone, Debug, Serialize)]
enum PythProChannel {
    #[serde(rename = "fixed_rate@1000ms")]
    FixedRate1000Ms,
}

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
enum PythProProperty {
    Price,
    Confidence,
    Exponent,
    EmaPrice,
    EmaConfidence,
    FeedUpdateTimestamp,
}

#[derive(Clone, Debug, Deserialize)]
struct PythProJsonUpdate {
    parsed: Option<PythProParsedPayload>,
}

#[derive(Clone, Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct PythProParsedPayload {
    #[allow(dead_code)]
    timestamp_us: String,
    price_feeds: Vec<PythProFeed>,
}

#[derive(Clone, Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct PythProFeed {
    price_feed_id: u32,
    price: Option<JsonScalar>,
    confidence: Option<JsonScalar>,
    exponent: Option<i16>,
    ema_price: Option<JsonScalar>,
    ema_confidence: Option<JsonScalar>,
    feed_update_timestamp: Option<u64>,
}

#[derive(Clone, Debug, Deserialize)]
#[serde(untagged)]
enum JsonScalar {
    String(String),
    Signed(i64),
    Unsigned(u64),
}

impl JsonScalar {
    fn into_string(self) -> String {
        match self {
            Self::String(value) => value,
            Self::Signed(value) => value.to_string(),
            Self::Unsigned(value) => value.to_string(),
        }
    }
}

#[derive(Clone, Debug, Serialize)]
struct PriceResponse {
    parsed: Vec<PriceUpdate>,
}

#[derive(Clone, Debug, Serialize)]
struct PriceUpdate {
    id: String,
    price: Price,
    #[serde(skip_serializing_if = "Option::is_none")]
    ema_price: Option<Price>,
    metadata: PriceMetadata,
}

#[derive(Clone, Debug, Serialize)]
struct Price {
    price: String,
    conf: String,
    expo: i16,
    publish_time: u64,
}

#[derive(Clone, Debug, Serialize)]
struct PriceMetadata {
    publish_time_us: String,
}

impl TryFrom<PythProFeed> for PriceUpdate {
    type Error = String;

    fn try_from(feed: PythProFeed) -> Result<Self, Self::Error> {
        let feed_id = feed.price_feed_id;
        let price = feed
            .price
            .ok_or_else(|| format!("feed {feed_id} has no price"))?
            .into_string();
        let confidence = feed
            .confidence
            .ok_or_else(|| format!("feed {feed_id} has no confidence"))?
            .into_string();
        let exponent = feed
            .exponent
            .ok_or_else(|| format!("feed {feed_id} has no exponent"))?;
        let publish_time_us = feed
            .feed_update_timestamp
            .ok_or_else(|| format!("feed {feed_id} has no update timestamp"))?;
        let publish_time = publish_time_us / MICROS_PER_SECOND;
        let ema_price = match (feed.ema_price, feed.ema_confidence) {
            (Some(price), Some(confidence)) => Some(Price {
                price: price.into_string(),
                conf: confidence.into_string(),
                expo: exponent,
                publish_time,
            }),
            _ => None,
        };

        Ok(Self {
            id: feed_id.to_string(),
            price: Price {
                price,
                conf: confidence,
                expo: exponent,
                publish_time,
            },
            ema_price,
            metadata: PriceMetadata {
                publish_time_us: publish_time_us.to_string(),
            },
        })
    }
}

#[derive(Debug, thiserror::Error)]
enum PythError {
    #[error("Pyth Pro is not configured")]
    NotConfigured,
    #[error("Pyth Pro request failed: {0}")]
    Transport(String),
    #[error("Pyth Pro returned HTTP {status}: {message}")]
    Upstream {
        status: StatusCode,
        message: String,
        retry_after: Option<String>,
    },
    #[error("invalid Pyth Pro response: {0}")]
    InvalidResponse(String),
}

impl PythError {
    fn into_response(self) -> Response {
        let (status, message, retry_after) = match self {
            Self::NotConfigured => (
                StatusCode::SERVICE_UNAVAILABLE,
                "Pyth Pro is not configured".to_owned(),
                None,
            ),
            Self::Transport(message) | Self::InvalidResponse(message) => (
                StatusCode::BAD_GATEWAY,
                format!("Pyth Pro is unavailable: {message}"),
                None,
            ),
            Self::Upstream {
                status,
                message,
                retry_after,
            } => (status, message, retry_after),
        };
        response_with_retry_after(status, message, retry_after.as_deref())
    }
}

#[derive(Clone)]
struct PythProClient {
    upstream_url: Url,
    api_key: Option<Arc<Secret<String>>>,
    http: reqwest::Client,
}

impl PythProClient {
    fn new(upstream_url: Url, api_key: Option<String>) -> Result<Self, anyhow::Error> {
        let api_key = api_key
            .map(|key| key.trim().to_owned())
            .filter(|key| !key.is_empty())
            .map(Secret::new)
            .map(Arc::new);
        let http = reqwest::Client::builder()
            .user_agent("deepbook-server")
            .timeout(Duration::from_secs(10))
            .build()?;

        Ok(Self {
            upstream_url,
            api_key,
            http,
        })
    }

    fn is_configured(&self) -> bool {
        self.api_key.is_some()
    }

    fn endpoint(&self, path: &str) -> Url {
        let mut url = self.upstream_url.clone();
        let mut full_path = url.path().trim_end_matches('/').to_owned();
        full_path.push('/');
        full_path.push_str(path.trim_start_matches('/'));
        url.set_path(&full_path);
        url
    }

    async fn latest(&self, feed_ids: Vec<u32>) -> Result<PythProParsedPayload, PythError> {
        self.request(LATEST_UPSTREAM_PATH, PythProRequest::latest(feed_ids))
            .await
    }

    async fn historical(
        &self,
        feed_ids: Vec<u32>,
        timestamp_us: u64,
    ) -> Result<PythProParsedPayload, PythError> {
        self.request(
            HISTORY_UPSTREAM_PATH,
            PythProRequest::historical(feed_ids, timestamp_us),
        )
        .await
    }

    async fn request(
        &self,
        path: &str,
        request: PythProRequest,
    ) -> Result<PythProParsedPayload, PythError> {
        let api_key = self.api_key.as_ref().ok_or(PythError::NotConfigured)?;
        let response = self
            .http
            .post(self.endpoint(path))
            .bearer_auth(api_key.expose_secret())
            .json(&request)
            .send()
            .await
            .map_err(|error| PythError::Transport(error.to_string()))?;

        let status = response.status();
        let retry_after = response
            .headers()
            .get(RETRY_AFTER)
            .and_then(|value| value.to_str().ok())
            .map(str::to_owned);
        if !status.is_success() {
            let message = response
                .text()
                .await
                .unwrap_or_else(|_| format!("Pyth Pro returned HTTP {status}"));
            return Err(PythError::Upstream {
                status,
                message,
                retry_after,
            });
        }

        response
            .json::<PythProJsonUpdate>()
            .await
            .map_err(|error| PythError::InvalidResponse(error.to_string()))?
            .parsed
            .ok_or_else(|| {
                PythError::InvalidResponse("response did not include parsed prices".to_owned())
            })
    }
}

#[derive(Debug)]
struct LatestSnapshot {
    prices: HashMap<u32, Arc<PriceUpdate>>,
    refreshed_at: Instant,
}

#[derive(Clone, Copy, Debug, Eq, Hash, PartialEq)]
struct HistoricalPriceKey {
    feed_id: u32,
    timestamp_us: u64,
}

/// Authenticated Pyth Pro access exposed through Hermes-like HTTP GET routes.
#[derive(Clone)]
pub struct PythProxy {
    client: PythProClient,
    feed_ids: Arc<HashSet<u32>>,
    latest_snapshot: watch::Receiver<Option<Arc<LatestSnapshot>>>,
    max_staleness: Duration,
    history: Cache<HistoricalPriceKey, Arc<PriceUpdate>>,
    history_load_guards: Cache<u64, Arc<Mutex<()>>>,
}

impl PythProxy {
    pub fn new(
        upstream_url: Url,
        api_key: Option<String>,
        mut config: PythProConfig,
    ) -> Result<Self, anyhow::Error> {
        anyhow::ensure!(
            !config.poll_interval.is_zero(),
            "Pyth Pro poll interval must be greater than zero"
        );
        anyhow::ensure!(
            !config.max_staleness.is_zero(),
            "Pyth Pro maximum staleness must be greater than zero"
        );
        anyhow::ensure!(
            !config.history_cache_ttl.is_zero(),
            "Pyth Pro history cache TTL must be greater than zero"
        );
        anyhow::ensure!(
            config.history_cache_max_entries > 0,
            "Pyth Pro history cache capacity must be greater than zero"
        );

        config.feed_ids.sort_unstable();
        config.feed_ids.dedup();

        let client = PythProClient::new(upstream_url, api_key)?;
        if !client.is_configured() {
            tracing::warn!(
                "No Pyth Pro API key configured (PYTH_PRO_API_KEY); Pyth routes will return HTTP 503"
            );
        }
        if config.feed_ids.is_empty() {
            tracing::warn!(
                "No Pyth Pro feed IDs configured (PYTH_PRO_FEED_IDS); Pyth price routes cannot serve feeds"
            );
        }

        let history = Cache::builder()
            .max_capacity(config.history_cache_max_entries)
            .time_to_live(config.history_cache_ttl)
            .build();
        let history_load_guards = Cache::builder()
            .max_capacity(config.history_cache_max_entries.max(1))
            .time_to_idle(Duration::from_secs(60))
            .build();
        let (latest_sender, latest_snapshot) = watch::channel(None);

        if client.is_configured() && !config.feed_ids.is_empty() {
            spawn_latest_poller(
                client.clone(),
                config.feed_ids.clone(),
                config.poll_interval,
                latest_sender,
            );
        }

        Ok(Self {
            client,
            feed_ids: Arc::new(config.feed_ids.into_iter().collect()),
            latest_snapshot,
            max_staleness: config.max_staleness,
            history,
            history_load_guards,
        })
    }

    fn configured(&self) -> Result<(), PythError> {
        self.client
            .is_configured()
            .then_some(())
            .ok_or(PythError::NotConfigured)
    }

    async fn latest(&self, query: PriceQuery) -> Response {
        if let Err(error) = self.configured() {
            return error.into_response();
        }

        let invalid_ids: Vec<_> = query
            .unique_ids()
            .into_iter()
            .filter(|id| !self.feed_ids.contains(id))
            .collect();
        if !query.ignore_invalid_price_ids && !invalid_ids.is_empty() {
            return (
                StatusCode::BAD_REQUEST,
                format!("latest prices are not configured for feed IDs {invalid_ids:?}"),
            )
                .into_response();
        }

        let Some(snapshot) = self.latest_snapshot.borrow().clone() else {
            return response_with_retry_after(
                StatusCode::SERVICE_UNAVAILABLE,
                "Pyth Pro latest prices are warming up",
                Some("1"),
            );
        };
        if snapshot.refreshed_at.elapsed() > self.max_staleness {
            return (
                StatusCode::BAD_GATEWAY,
                "Pyth Pro latest-price snapshot is stale",
            )
                .into_response();
        }

        let mut prices = Vec::with_capacity(query.ids.len());
        for id in query.ids {
            match snapshot.prices.get(&id) {
                Some(price) => prices.push((**price).clone()),
                None if query.ignore_invalid_price_ids => {}
                None => {
                    return (
                        StatusCode::BAD_GATEWAY,
                        format!("latest price is unavailable for feed ID {id}"),
                    )
                        .into_response();
                }
            }
        }

        Json(PriceResponse { parsed: prices }).into_response()
    }

    async fn historical(&self, query: PriceQuery, publish_time: u64) -> Response {
        if let Err(error) = self.configured() {
            return error.into_response();
        }
        let invalid_ids: Vec<_> = query
            .unique_ids()
            .into_iter()
            .filter(|id| !self.feed_ids.contains(id))
            .collect();
        if !query.ignore_invalid_price_ids && !invalid_ids.is_empty() {
            return (
                StatusCode::BAD_REQUEST,
                format!("historical prices are not configured for feed IDs {invalid_ids:?}"),
            )
                .into_response();
        }
        let Some(timestamp_us) = publish_time.checked_mul(MICROS_PER_SECOND) else {
            return (
                StatusCode::BAD_REQUEST,
                "publish_time is too large to convert to microseconds",
            )
                .into_response();
        };

        let mut prices = HashMap::new();
        let mut missing_ids = Vec::new();
        for feed_id in query
            .unique_ids()
            .into_iter()
            .filter(|id| self.feed_ids.contains(id))
        {
            let key = HistoricalPriceKey {
                feed_id,
                timestamp_us,
            };
            match self.history.get(&key).await {
                Some(price) => {
                    prices.insert(feed_id, price);
                }
                None => missing_ids.push(feed_id),
            }
        }

        if !missing_ids.is_empty() {
            let load_guard = self
                .history_load_guards
                .get_with(timestamp_us, async { Arc::new(Mutex::new(())) })
                .await;
            let _load = load_guard.lock().await;

            let mut still_missing = Vec::new();
            for feed_id in missing_ids {
                let key = HistoricalPriceKey {
                    feed_id,
                    timestamp_us,
                };
                match self.history.get(&key).await {
                    Some(price) => {
                        prices.insert(feed_id, price);
                    }
                    None => still_missing.push(feed_id),
                }
            }

            if !still_missing.is_empty() {
                let payload = match self
                    .client
                    .historical(still_missing.clone(), timestamp_us)
                    .await
                {
                    Ok(payload) => payload,
                    Err(error) => return error.into_response(),
                };

                for feed in payload.price_feeds {
                    let feed_id = feed.price_feed_id;
                    if !still_missing.contains(&feed_id) {
                        continue;
                    }
                    let price = match PriceUpdate::try_from(feed) {
                        Ok(price) => Arc::new(price),
                        Err(error) => {
                            tracing::error!(%error, "Invalid historical Pyth Pro price");
                            continue;
                        }
                    };
                    let key = HistoricalPriceKey {
                        feed_id,
                        timestamp_us,
                    };
                    self.history.insert(key, price.clone()).await;
                    prices.insert(feed_id, price);
                }
            }
        }

        let mut ordered = Vec::with_capacity(query.ids.len());
        for feed_id in query.ids {
            match prices.get(&feed_id) {
                Some(price) => ordered.push((**price).clone()),
                None if query.ignore_invalid_price_ids => {}
                None => {
                    return (
                        StatusCode::NOT_FOUND,
                        format!(
                            "Pyth Pro has no historical price for feed ID {feed_id} at {timestamp_us}"
                        ),
                    )
                        .into_response();
                }
            }
        }

        Json(PriceResponse { parsed: ordered }).into_response()
    }
}

fn spawn_latest_poller(
    client: PythProClient,
    feed_ids: Vec<u32>,
    poll_interval: Duration,
    latest_sender: watch::Sender<Option<Arc<LatestSnapshot>>>,
) {
    tokio::spawn(async move {
        let configured_feed_ids: HashSet<_> = feed_ids.iter().copied().collect();
        let mut ticker = tokio::time::interval(poll_interval);
        ticker.set_missed_tick_behavior(MissedTickBehavior::Skip);

        loop {
            tokio::select! {
                _ = latest_sender.closed() => break,
                _ = ticker.tick() => {
                    match client.latest(feed_ids.clone()).await {
                        Ok(payload) => {
                            let mut prices = HashMap::with_capacity(feed_ids.len());
                            let mut invalid = None;
                            for feed in payload.price_feeds {
                                let feed_id = feed.price_feed_id;
                                if !configured_feed_ids.contains(&feed_id) {
                                    continue;
                                }
                                match PriceUpdate::try_from(feed) {
                                    Ok(price) => {
                                        prices.insert(feed_id, Arc::new(price));
                                    }
                                    Err(error) => {
                                        invalid = Some(error);
                                        break;
                                    }
                                }
                            }

                            if let Some(error) = invalid {
                                tracing::error!(%error, "Invalid latest Pyth Pro price");
                                continue;
                            }
                            let missing: Vec<_> = feed_ids
                                .iter()
                                .filter(|id| !prices.contains_key(id))
                                .copied()
                                .collect();
                            if !missing.is_empty() {
                                tracing::error!(
                                    ?missing,
                                    "Pyth Pro latest response omitted configured feeds"
                                );
                                continue;
                            }

                            latest_sender.send_replace(Some(Arc::new(LatestSnapshot {
                                prices,
                                refreshed_at: Instant::now(),
                            })));
                        }
                        Err(error) => {
                            tracing::error!(%error, "Pyth Pro latest-price refresh failed");
                        }
                    }
                }
            }
        }
    });
}

fn response_with_retry_after(
    status: StatusCode,
    message: impl Into<String>,
    retry_after: Option<&str>,
) -> Response {
    let mut response = (status, message.into()).into_response();
    if let Some(retry_after) = retry_after {
        if let Ok(value) = HeaderValue::from_str(retry_after) {
            response.headers_mut().insert(RETRY_AFTER, value);
        }
    }
    response
}

pub fn routes(proxy: PythProxy) -> Router {
    Router::new()
        .route(LATEST_PRICE_PATH, get(latest_price))
        .route(PRICE_AT_TIMESTAMP_PATH, get(price_at_timestamp))
        .with_state(proxy)
}

async fn latest_price(State(proxy): State<PythProxy>, RawQuery(query): RawQuery) -> Response {
    match PriceQuery::parse(query.as_deref()) {
        Ok(query) => proxy.latest(query).await,
        Err(error) => (StatusCode::BAD_REQUEST, error).into_response(),
    }
}

async fn price_at_timestamp(
    Path(publish_time): Path<u64>,
    State(proxy): State<PythProxy>,
    RawQuery(query): RawQuery,
) -> Response {
    match PriceQuery::parse(query.as_deref()) {
        Ok(query) => proxy.historical(query, publish_time).await,
        Err(error) => (StatusCode::BAD_REQUEST, error).into_response(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use axum::{
        extract::{OriginalUri, State},
        http::{header::AUTHORIZATION, HeaderMap},
        routing::post,
    };
    use futures::future::join_all;
    use serde_json::{json, Value};
    use std::sync::{
        atomic::{AtomicUsize, Ordering},
        Mutex as StdMutex,
    };
    use tokio::{
        net::TcpListener,
        task::JoinHandle,
        time::{sleep, timeout},
    };

    const TEST_TIMESTAMP_US: u64 = 1_700_000_000_123_456;

    #[derive(Clone, Default)]
    struct MockPyth {
        latest_requests: Arc<AtomicUsize>,
        history_requests: Arc<AtomicUsize>,
        captured: Arc<StdMutex<Vec<(String, String, Value)>>>,
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
        }
    }

    async fn wait_for_latest(proxy: &PythProxy) {
        timeout(Duration::from_secs(1), async {
            loop {
                let ready = proxy.latest_snapshot.borrow().is_some();
                if ready {
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
        let (server_url, server_task) =
            spawn(Router::new().nest("/pyth", routes(proxy.clone()))).await;
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
}
