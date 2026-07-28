// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

use super::{
    client::PythProClient,
    config::{PythProConfig, LATEST_PRICE_PATH, PRICE_AT_TIMESTAMP_PATH, TRADINGVIEW_HISTORY_PATH},
    error::PythError,
    models::{
        normalize_history_symbol, ChartHistoryQuery, PriceQuery, PriceResponse, PriceUpdate,
        MICROS_PER_SECOND,
    },
};
use axum::{
    body::Bytes,
    extract::{Path, RawQuery, State},
    http::{header::CONTENT_TYPE, HeaderValue, StatusCode},
    response::{IntoResponse, Response},
    routing::get,
    Json, Router,
};
use moka::future::Cache;
use std::{
    collections::{HashMap, HashSet},
    sync::Arc,
    time::Duration,
};
use tokio::{sync::Mutex, time::Instant};
use url::Url;

const LATEST_RESPONSE_CACHE_MAX_ENTRIES: u64 = 128;

struct LatestSnapshot {
    prices: HashMap<u32, Arc<PriceUpdate>>,
    fetched_at: Instant,
    serialized_responses: Cache<Vec<u32>, Bytes>,
}

#[derive(Clone, Copy, Debug, Eq, Hash, PartialEq)]
struct HistoricalPriceKey {
    feed_id: u32,
    timestamp_us: u64,
}

/// Authenticated Pyth Pro access exposed through Hermes- and TradingView-like HTTP GET routes.
#[derive(Clone)]
pub struct PythProxy {
    client: PythProClient,
    allowed_feed_ids: Arc<Vec<u32>>,
    latest: Cache<(), Arc<LatestSnapshot>>,
    history: Cache<HistoricalPriceKey, Arc<PriceUpdate>>,
    // A timestamp-scoped guard lets one upstream request batch all feed IDs
    // missing at that timestamp. Moka's per-key `try_get_with` cannot coalesce
    // that cross-key batch the way it can for one chart-history response.
    history_load_guards: Cache<u64, Arc<Mutex<()>>>,
    chart_history_symbols: Arc<HashSet<String>>,
    chart_history_max_range: Duration,
    chart_history: Cache<ChartHistoryQuery, Bytes>,
}

impl PythProxy {
    pub fn new(
        upstream_url: Url,
        api_key: Option<String>,
        mut config: PythProConfig,
    ) -> Result<Self, anyhow::Error> {
        anyhow::ensure!(
            !config.latest_cache_ttl.is_zero(),
            "Pyth Pro latest cache TTL must be greater than zero"
        );
        anyhow::ensure!(
            !config.history_cache_ttl.is_zero(),
            "Pyth Pro history cache TTL must be greater than zero"
        );
        anyhow::ensure!(
            config.history_cache_max_entries > 0,
            "Pyth Pro history cache capacity must be greater than zero"
        );
        anyhow::ensure!(
            !config.chart_history.cache_ttl.is_zero(),
            "Pyth Pro chart history cache TTL must be greater than zero"
        );
        anyhow::ensure!(
            config.chart_history.cache_max_entries > 0,
            "Pyth Pro chart history cache capacity must be greater than zero"
        );
        anyhow::ensure!(
            !config.chart_history.max_range.is_zero(),
            "Pyth Pro chart history maximum range must be greater than zero"
        );

        config.allowed_feed_ids.sort_unstable();
        config.allowed_feed_ids.dedup();
        config.chart_history.symbols = config
            .chart_history
            .symbols
            .into_iter()
            .map(|symbol| normalize_history_symbol(&symbol))
            .filter(|symbol| !symbol.is_empty())
            .collect();
        config.chart_history.symbols.sort();
        config.chart_history.symbols.dedup();

        let client = PythProClient::new(
            upstream_url,
            config.chart_history.upstream_url.clone(),
            api_key,
        )?;
        if !client.is_configured() {
            tracing::warn!(
                "No Pyth Pro API key configured (PYTH_PRO_API_KEY); Pyth routes will return HTTP 503"
            );
        }
        if config.allowed_feed_ids.is_empty() {
            tracing::warn!(
                "No Pyth Pro feed IDs configured (PYTH_PRO_ALLOWED_FEED_IDS); Pyth price routes cannot serve feeds"
            );
        }
        if config.chart_history.symbols.is_empty() {
            tracing::warn!(
                "No Pyth Pro chart symbols configured (PYTH_PRO_HISTORY_SYMBOLS); Pyth chart history cannot serve symbols"
            );
        }

        let latest = Cache::builder()
            .max_capacity(1)
            .time_to_live(config.latest_cache_ttl)
            .build();
        let history = Cache::builder()
            .max_capacity(config.history_cache_max_entries)
            .time_to_live(config.history_cache_ttl)
            .build();
        let history_load_guards = Cache::builder()
            .max_capacity(config.history_cache_max_entries.max(1))
            .time_to_idle(Duration::from_secs(60))
            .build();
        let chart_history = Cache::builder()
            .max_capacity(config.chart_history.cache_max_entries)
            .time_to_live(config.chart_history.cache_ttl)
            .build();
        Ok(Self {
            client,
            allowed_feed_ids: Arc::new(config.allowed_feed_ids),
            latest,
            history,
            history_load_guards,
            chart_history_symbols: Arc::new(config.chart_history.symbols.into_iter().collect()),
            chart_history_max_range: config.chart_history.max_range,
            chart_history,
        })
    }

    fn configured(&self) -> Result<(), PythError> {
        self.client
            .is_configured()
            .then_some(())
            .ok_or(PythError::NotConfigured)
    }

    fn disallowed_ids(&self, feed_ids: &[u32]) -> Option<Vec<u32>> {
        if feed_ids
            .iter()
            .all(|id| self.allowed_feed_ids.binary_search(id).is_ok())
        {
            return None;
        }

        let mut seen = HashSet::new();
        Some(
            feed_ids
                .iter()
                .copied()
                .filter(|id| self.allowed_feed_ids.binary_search(id).is_err() && seen.insert(*id))
                .collect(),
        )
    }

    async fn latest(&self, query: PriceQuery) -> Response {
        if let Err(error) = self.configured() {
            return error.into_response();
        }

        if !query.ignore_invalid_price_ids {
            if let Some(invalid_ids) = self.disallowed_ids(&query.ids) {
                return (
                    StatusCode::BAD_REQUEST,
                    format!("latest prices are not allowed for feed IDs {invalid_ids:?}"),
                )
                    .into_response();
            }
        }

        let client = self.client.clone();
        let allowed_feed_ids = self.allowed_feed_ids.clone();
        // Every query shares one snapshot key. Moka both expires it after the
        // configured TTL and coalesces concurrent misses into one upstream
        // request, even when callers ask for different feed subsets.
        let snapshot = match self
            .latest
            .try_get_with((), async move {
                load_latest_snapshot(client, allowed_feed_ids).await
            })
            .await
        {
            Ok(snapshot) => snapshot,
            Err(error) => return (*error).clone().into_response(),
        };
        tracing::trace!(
            cache_age_ms = snapshot.fetched_at.elapsed().as_millis(),
            "Serving Pyth Pro latest-price snapshot"
        );

        let response_key = query.ids.clone();
        let response_cache = snapshot.serialized_responses.clone();
        let snapshot_for_load = snapshot.clone();
        let ignore_invalid_price_ids = query.ignore_invalid_price_ids;
        match response_cache
            .try_get_with(response_key, async move {
                let mut prices = Vec::with_capacity(query.ids.len());
                for id in query.ids {
                    match snapshot_for_load.prices.get(&id) {
                        Some(price) => prices.push((**price).clone()),
                        None if ignore_invalid_price_ids => {}
                        None => {
                            return Err(PythError::InvalidResponse(format!(
                                "latest price is unavailable for feed ID {id}"
                            )))
                        }
                    }
                }
                serialize_price_response(prices)
            })
            .await
        {
            Ok(body) => json_bytes_response(body),
            Err(error) => (*error).clone().into_response(),
        }
    }

    async fn historical(&self, query: PriceQuery, publish_time: u64) -> Response {
        if let Err(error) = self.configured() {
            return error.into_response();
        }

        let unique_ids = query.unique_ids();
        if !query.ignore_invalid_price_ids {
            if let Some(invalid_ids) = self.disallowed_ids(&unique_ids) {
                return (
                    StatusCode::BAD_REQUEST,
                    format!("historical prices are not allowed for feed IDs {invalid_ids:?}"),
                )
                    .into_response();
            }
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
        for feed_id in unique_ids
            .into_iter()
            .filter(|id| self.allowed_feed_ids.binary_search(id).is_ok())
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
            // A waiting request must recheck after acquiring the guard because
            // the request ahead of it may have populated some or all misses.
            // Guard eviction can permit a redundant load under capacity
            // pressure, but cached values are idempotent, so correctness is
            // unaffected.
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

    async fn chart_history(&self, query: ChartHistoryQuery) -> Response {
        if let Err(error) = self.configured() {
            return error.into_response();
        }
        if !self.chart_history_symbols.contains(&query.symbol) {
            return (
                StatusCode::BAD_REQUEST,
                format!(
                    "chart history is not configured for symbol `{}`",
                    query.symbol
                ),
            )
                .into_response();
        }

        let client = self.client.clone();
        let request = query.clone();
        // `try_get_with` stores only a successful loader result and coalesces
        // concurrent misses for this exact query. Errors are returned uncached.
        match self
            .chart_history
            .try_get_with(query, async move { client.chart_history(&request).await })
            .await
        {
            Ok(body) => json_bytes_response(body),
            Err(error) => (*error).clone().into_response(),
        }
    }
}

async fn load_latest_snapshot(
    client: PythProClient,
    allowed_feed_ids: Arc<Vec<u32>>,
) -> Result<Arc<LatestSnapshot>, PythError> {
    let payload = client.latest(allowed_feed_ids.as_ref().clone()).await?;
    let mut prices = HashMap::with_capacity(allowed_feed_ids.len());
    for feed in payload.price_feeds {
        let feed_id = feed.price_feed_id;
        if allowed_feed_ids.binary_search(&feed_id).is_err() {
            continue;
        }
        let price = PriceUpdate::try_from(feed).map_err(PythError::InvalidResponse)?;
        prices.insert(feed_id, Arc::new(price));
    }

    let missing: Vec<_> = allowed_feed_ids
        .iter()
        .filter(|id| !prices.contains_key(id))
        .copied()
        .collect();
    if !missing.is_empty() {
        return Err(PythError::InvalidResponse(format!(
            "latest response omitted allowed feed IDs {missing:?}"
        )));
    }

    Ok(Arc::new(LatestSnapshot {
        prices,
        fetched_at: Instant::now(),
        serialized_responses: Cache::builder()
            .max_capacity(LATEST_RESPONSE_CACHE_MAX_ENTRIES)
            .build(),
    }))
}

fn serialize_price_response(prices: Vec<PriceUpdate>) -> Result<Bytes, PythError> {
    serde_json::to_vec(&PriceResponse { parsed: prices })
        .map(Bytes::from)
        .map_err(|error| PythError::InvalidResponse(error.to_string()))
}

fn json_bytes_response(body: Bytes) -> Response {
    let mut response = body.into_response();
    response
        .headers_mut()
        .insert(CONTENT_TYPE, HeaderValue::from_static("application/json"));
    response
}

pub fn routes(proxy: PythProxy) -> Router {
    Router::new()
        .route(LATEST_PRICE_PATH, get(latest_price))
        .route(PRICE_AT_TIMESTAMP_PATH, get(price_at_timestamp))
        .route(TRADINGVIEW_HISTORY_PATH, get(tradingview_history))
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

async fn tradingview_history(
    State(proxy): State<PythProxy>,
    RawQuery(query): RawQuery,
) -> Response {
    match ChartHistoryQuery::parse(query.as_deref(), proxy.chart_history_max_range) {
        Ok(query) => proxy.chart_history(query).await,
        Err(error) => (StatusCode::BAD_REQUEST, error).into_response(),
    }
}
