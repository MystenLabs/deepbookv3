// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

use super::{
    client::PythProClient,
    config::{PythProConfig, LATEST_PRICE_PATH, PRICE_AT_TIMESTAMP_PATH, TRADINGVIEW_HISTORY_PATH},
    error::{response_with_retry_after, PythError},
    models::{
        normalize_history_symbol, ChartHistoryQuery, PriceQuery, PriceResponse, PriceUpdate,
        MICROS_PER_SECOND,
    },
};
use axum::{
    extract::{Path, RawQuery, State},
    http::StatusCode,
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
use tokio::{
    sync::{watch, Mutex},
    time::{Instant, MissedTickBehavior},
};
use url::Url;

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

/// Authenticated Pyth Pro access exposed through Hermes- and TradingView-like HTTP GET routes.
#[derive(Clone)]
pub struct PythProxy {
    client: PythProClient,
    feed_ids: Arc<HashSet<u32>>,
    latest_snapshot: watch::Receiver<Option<Arc<LatestSnapshot>>>,
    max_staleness: Duration,
    history: Cache<HistoricalPriceKey, Arc<PriceUpdate>>,
    history_load_guards: Cache<u64, Arc<Mutex<()>>>,
    chart_history_symbols: Arc<HashSet<String>>,
    chart_history_max_range: Duration,
    chart_history: Cache<ChartHistoryQuery, Arc<serde_json::Value>>,
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

        config.feed_ids.sort_unstable();
        config.feed_ids.dedup();
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
        if config.feed_ids.is_empty() {
            tracing::warn!(
                "No Pyth Pro feed IDs configured (PYTH_PRO_FEED_IDS); Pyth price routes cannot serve feeds"
            );
        }
        if config.chart_history.symbols.is_empty() {
            tracing::warn!(
                "No Pyth Pro chart symbols configured (PYTH_PRO_HISTORY_SYMBOLS); Pyth chart history cannot serve symbols"
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
        let chart_history = Cache::builder()
            .max_capacity(config.chart_history.cache_max_entries)
            .time_to_live(config.chart_history.cache_ttl)
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

    #[cfg(test)]
    pub(super) fn has_latest_snapshot(&self) -> bool {
        self.latest_snapshot.borrow().is_some()
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
        match self
            .chart_history
            .try_get_with(query, async move {
                client.chart_history(&request).await.map(Arc::new)
            })
            .await
        {
            Ok(body) => Json((*body).clone()).into_response(),
            Err(error) => (*error).clone().into_response(),
        }
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
