// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

//! Parsed-only Pyth relay. A single hub per process fans redundant upstreams out
//! to browsers; it never verifies or submits an on-chain update.
use axum::{
    extract::{
        ws::{Message, WebSocket, WebSocketUpgrade},
        ConnectInfo, State,
    },
    http::{HeaderMap, StatusCode},
    response::{IntoResponse, Response},
};
use futures::{SinkExt, StreamExt};
use prometheus::{GaugeVec, IntCounter, IntCounterVec, IntGauge, IntGaugeVec, Opts, Registry};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::{
    collections::{HashMap, HashSet},
    net::{IpAddr, SocketAddr},
    sync::{Arc, Mutex},
    time::Duration,
};
use tokio::{
    sync::broadcast,
    time::{timeout, Instant},
};
use tokio_tungstenite::tungstenite::{client::IntoClientRequest, Message as UpstreamMessage};
use tokio_util::sync::CancellationToken;

const QUEUE: usize = 128;
const STALE: Duration = Duration::from_secs(2);
const WRITE_TIMEOUT: Duration = Duration::from_secs(5);
const MAX_FEEDS: usize = 16;
const MAX_CONNECTIONS: usize = 4096;
const MAX_PER_IP: usize = 20;
const ENDPOINTS: [&str; 3] = [
    "wss://pyth-lazer-0.dourolabs.app/v1/stream",
    "wss://pyth-lazer-1.dourolabs.app/v1/stream",
    "wss://pyth-lazer-2.dourolabs.app/v1/stream",
];

#[derive(Clone, Debug)]
pub struct PythStreamConfig {
    pub allowed_origins: Vec<String>,
    /// Zero uses the peer address. Only set behind a trusted, non-bypassable proxy.
    pub trusted_proxy_hops: usize,
}

#[derive(Clone, Debug, Serialize)]
struct Price {
    #[serde(rename = "type")]
    kind: &'static str,
    feed_id: u32,
    price: String,
    exponent: i16,
    timestamp_us: String,
    feed_update_us: String,
}

struct Feed {
    latest: Option<Price>,
    received: Instant,
    stale: bool,
    revision: u64,
}
struct Inner {
    feeds: HashMap<u32, Feed>,
    connections: HashMap<IpAddr, usize>,
}

#[derive(Clone)]
pub(super) struct Hub {
    inner: Arc<Mutex<Inner>>,
    events: broadcast::Sender<(u32, u64, Value)>,
    config: PythStreamConfig,
    shutdown: CancellationToken,
    metrics: Arc<StreamMetrics>,
}

struct StreamMetrics {
    clients: IntGauge,
    duplicates: IntCounter,
    slow_clients: IntCounter,
    reconnects: IntCounterVec,
    lag: GaugeVec,
    subscriptions: IntGaugeVec,
}
impl StreamMetrics {
    fn new() -> Self {
        Self {
            subscriptions: IntGaugeVec::new(
                Opts::new("pyth_ws_subscriptions", "Browser subscriptions by feed"),
                &["feed_id"],
            )
            .unwrap(),
            clients: IntGauge::new("pyth_ws_clients", "Connected browser sockets").unwrap(),
            duplicates: IntCounter::new(
                "pyth_ws_duplicate_frames_total",
                "Duplicate or late feed frames discarded",
            )
            .unwrap(),
            slow_clients: IntCounter::new(
                "pyth_ws_slow_clients_total",
                "Clients disconnected for queue overflow or write timeout",
            )
            .unwrap(),
            reconnects: IntCounterVec::new(
                Opts::new(
                    "pyth_ws_upstream_disconnects_total",
                    "Upstream disconnections",
                ),
                &["endpoint"],
            )
            .unwrap(),
            lag: GaugeVec::new(
                Opts::new(
                    "pyth_ws_upstream_lag_seconds",
                    "Seconds since the last accepted Pyth envelope; absent before the first price",
                ),
                &["feed_id"],
            )
            .unwrap(),
        }
    }
    fn register(&self, registry: &Registry) -> anyhow::Result<()> {
        registry.register(Box::new(self.clients.clone()))?;
        registry.register(Box::new(self.subscriptions.clone()))?;
        registry.register(Box::new(self.duplicates.clone()))?;
        registry.register(Box::new(self.slow_clients.clone()))?;
        registry.register(Box::new(self.reconnects.clone()))?;
        registry.register(Box::new(self.lag.clone()))?;
        Ok(())
    }
}

impl Hub {
    pub(super) fn new(ids: &[u32], config: PythStreamConfig) -> Self {
        let (events, _) = broadcast::channel(QUEUE);
        Self {
            inner: Arc::new(Mutex::new(Inner {
                feeds: ids
                    .iter()
                    .map(|id| {
                        (
                            *id,
                            Feed {
                                latest: None,
                                received: Instant::now(),
                                stale: true,
                                revision: 0,
                            },
                        )
                    })
                    .collect(),
                connections: HashMap::new(),
            })),
            events,
            config,
            shutdown: CancellationToken::new(),
            metrics: Arc::new(StreamMetrics::new()),
        }
    }

    pub(super) fn start(
        &self,
        key: String,
        registry: &Registry,
    ) -> anyhow::Result<CancellationToken> {
        self.metrics.register(registry)?;
        for endpoint in ENDPOINTS {
            let hub = self.clone();
            let key = key.clone();
            tokio::spawn(async move {
                let mut delay = Duration::from_millis(500);
                loop {
                    let started = Instant::now();
                    tokio::select! {
                        _ = hub.shutdown.cancelled() => break,
                        result = hub.upstream(endpoint, &key) => {
                            // Do not log upstream errors: handshake errors can contain credentials.
                            self::record_disconnect(&hub, endpoint, result.is_err());
                        }
                    }
                    if started.elapsed() > Duration::from_secs(30) {
                        delay = Duration::from_millis(500);
                    }
                    let jitter = rand::random::<u64>() % 250;
                    tokio::select! {
                        _ = hub.shutdown.cancelled() => break,
                        _ = tokio::time::sleep(delay + Duration::from_millis(jitter)) => {}
                    }
                    delay = (delay * 2).min(Duration::from_secs(10));
                }
            });
        }
        let hub = self.clone();
        tokio::spawn(async move {
            let mut tick = tokio::time::interval(Duration::from_millis(100));
            loop {
                tokio::select! {
                    _ = hub.shutdown.cancelled() => break,
                    _ = tick.tick() => hub.mark_stale(),
                }
            }
        });
        Ok(self.shutdown.clone())
    }

    async fn upstream(&self, endpoint: &str, key: &str) -> anyhow::Result<()> {
        let mut request = endpoint.into_client_request()?;
        request
            .headers_mut()
            .insert("Authorization", format!("Bearer {key}").parse()?);
        let (mut socket, _) = timeout(
            Duration::from_secs(15),
            tokio_tungstenite::connect_async_with_config(
                request,
                Some(
                    tokio_tungstenite::tungstenite::protocol::WebSocketConfig::default()
                        .max_message_size(Some(1_048_576))
                        .max_frame_size(Some(1_048_576)),
                ),
                false,
            ),
        )
        .await??;
        let ids: Vec<_> = self.inner.lock().unwrap().feeds.keys().copied().collect();
        timeout(
            WRITE_TIMEOUT,
            socket.send(UpstreamMessage::Text(
                json!({
                    "type":"subscribe", "subscriptionId":1, "priceFeedIds":ids,
                    "properties":["price","exponent","feedUpdateTimestamp"],
                    "formats":[], "deliveryFormat":"json", "parsed":true,
                    "channel":"fixed_rate@200ms", "ignoreInvalidFeeds":true
                })
                .to_string()
                .into(),
            )),
        )
        .await??;
        loop {
            let message = timeout(Duration::from_secs(10), socket.next())
                .await?
                .ok_or_else(|| anyhow::anyhow!("upstream closed"))??;
            match message {
                UpstreamMessage::Text(text) => {
                    let value: Value = serde_json::from_str(&text)?;
                    match value["type"].as_str() {
                        Some("streamUpdated") => self.accept(&value)?,
                        Some("error" | "subscriptionError") => {
                            anyhow::bail!("subscription rejected")
                        }
                        _ => {}
                    }
                }
                UpstreamMessage::Ping(payload) => {
                    timeout(WRITE_TIMEOUT, socket.send(UpstreamMessage::Pong(payload))).await??;
                }
                UpstreamMessage::Close(_) => anyhow::bail!("upstream closed"),
                _ => {}
            }
        }
    }

    fn accept(&self, value: &Value) -> anyhow::Result<()> {
        let parsed = &value["parsed"];
        let timestamp = scalar(&parsed["timestampUs"])
            .and_then(|v| v.parse::<u64>().ok())
            .ok_or_else(|| anyhow::anyhow!("missing envelope timestamp"))?;
        anyhow::ensure!(
            timestamp > 0 && timestamp % 200_000 == 0,
            "off-grid timestamp"
        );
        let feeds = parsed["priceFeeds"]
            .as_array()
            .ok_or_else(|| anyhow::anyhow!("missing feeds"))?;
        let mut inner = self.inner.lock().unwrap();
        for raw in feeds {
            let Some(id) = raw["priceFeedId"]
                .as_u64()
                .and_then(|id| u32::try_from(id).ok())
            else {
                continue;
            };
            let Some(feed) = inner.feeds.get_mut(&id) else {
                continue;
            };
            let Some(price) = scalar(&raw["price"]).filter(|p| p.parse::<i64>().is_ok()) else {
                continue;
            };
            let Some(exponent) = raw["exponent"].as_i64().and_then(|v| i16::try_from(v).ok())
            else {
                continue;
            };
            let Some(generated) = scalar(&raw["feedUpdateTimestamp"])
                .and_then(|v| v.parse::<u64>().ok())
                .filter(|v| *v > 0 && *v <= timestamp)
            else {
                continue;
            };
            if feed
                .latest
                .as_ref()
                .is_some_and(|last| timestamp <= last.timestamp_us.parse::<u64>().unwrap())
            {
                self.metrics.duplicates.inc();
                continue;
            }
            let price = Price {
                kind: "price",
                feed_id: id,
                price,
                exponent,
                timestamp_us: timestamp.to_string(),
                feed_update_us: generated.to_string(),
            };
            feed.latest = Some(price.clone());
            feed.received = Instant::now();
            feed.revision += 1;
            let _ = self
                .events
                .send((id, feed.revision, serde_json::to_value(price)?));
            if feed.stale {
                feed.stale = false;
                feed.revision += 1;
                let _ = self.events.send((id, feed.revision, status(id, feed)));
            }
        }
        Ok(())
    }

    fn mark_stale(&self) {
        for (id, feed) in &mut self.inner.lock().unwrap().feeds {
            if let Some(price) = &feed.latest {
                let now = std::time::SystemTime::now()
                    .duration_since(std::time::UNIX_EPOCH)
                    .unwrap_or_default()
                    .as_secs_f64();
                self.metrics
                    .lag
                    .with_label_values(&[&id.to_string()])
                    .set(now - price.timestamp_us.parse::<u64>().unwrap() as f64 / 1_000_000.0);
            }
            if !feed.stale && feed.received.elapsed() >= STALE {
                feed.stale = true;
                feed.revision += 1;
                let _ = self.events.send((*id, feed.revision, status(*id, feed)));
                tracing::warn!(feed_id = id, "Pyth feed stale");
            }
        }
    }
}

fn record_disconnect(hub: &Hub, endpoint: &str, failed: bool) {
    hub.metrics.reconnects.with_label_values(&[endpoint]).inc();
    tracing::warn!(endpoint, failed, "Pyth stream disconnected");
}

fn scalar(value: &Value) -> Option<String> {
    match value {
        Value::String(s) => Some(s.clone()),
        Value::Number(n) => Some(n.to_string()),
        _ => None,
    }
}
fn status(id: u32, feed: &Feed) -> Value {
    json!({"type":"status", "feed_id":id, "stale":feed.stale,
        "last_timestamp_us":feed.latest.as_ref().map(|p| &p.timestamp_us)})
}

struct Permit {
    hub: Hub,
    ip: IpAddr,
    feeds: HashSet<u32>,
}
impl Drop for Permit {
    fn drop(&mut self) {
        self.hub.metrics.clients.dec();
        for id in &self.feeds {
            self.hub
                .metrics
                .subscriptions
                .with_label_values(&[&id.to_string()])
                .dec();
        }
        let mut inner = self.hub.inner.lock().unwrap();
        if let Some(count) = inner.connections.get_mut(&self.ip) {
            *count -= 1;
            if *count == 0 {
                inner.connections.remove(&self.ip);
            }
        }
    }
}

pub(super) async fn upgrade(
    State(proxy): State<super::PythProxy>,
    ConnectInfo(peer): ConnectInfo<SocketAddr>,
    headers: HeaderMap,
    ws: WebSocketUpgrade,
) -> Response {
    let Some(hub) = proxy.stream.clone() else {
        return StatusCode::SERVICE_UNAVAILABLE.into_response();
    };
    let origin = headers.get("origin").and_then(|h| h.to_str().ok());
    if !origin.is_some_and(|origin| {
        hub.config
            .allowed_origins
            .iter()
            .any(|allowed| allowed == origin)
    }) {
        return StatusCode::FORBIDDEN.into_response();
    }
    let ip = if hub.config.trusted_proxy_hops == 0 {
        peer.ip()
    } else {
        let Some(ip) = headers
            .get("x-forwarded-for")
            .and_then(|h| h.to_str().ok())
            .and_then(|h| h.split(',').rev().nth(hub.config.trusted_proxy_hops - 1))
            .and_then(|h| h.trim().parse::<IpAddr>().ok())
        else {
            return StatusCode::BAD_REQUEST.into_response();
        };
        ip
    };
    {
        let mut inner = hub.inner.lock().unwrap();
        if inner.connections.values().sum::<usize>() >= MAX_CONNECTIONS
            || inner.connections.get(&ip).copied().unwrap_or_default() >= MAX_PER_IP
        {
            return StatusCode::TOO_MANY_REQUESTS.into_response();
        }
        *inner.connections.entry(ip).or_default() += 1;
    }
    hub.metrics.clients.inc();
    let permit = Permit {
        hub: hub.clone(),
        ip,
        feeds: HashSet::new(),
    };
    ws.max_message_size(4096)
        .max_frame_size(4096)
        .on_upgrade(move |socket| browser(socket, hub, permit))
        .into_response()
}

#[derive(Deserialize)]
#[serde(tag = "type", rename_all = "snake_case", deny_unknown_fields)]
enum Command {
    Subscribe { feed_ids: Vec<u32> },
    Unsubscribe { feed_ids: Vec<u32> },
}

async fn send(socket: &mut WebSocket, hub: &Hub, value: Value) -> anyhow::Result<()> {
    let result = timeout(WRITE_TIMEOUT, socket.send(Message::Text(value.to_string()))).await;
    if result.is_err() {
        hub.metrics.slow_clients.inc();
    }
    result??;
    Ok(())
}

async fn browser(mut socket: WebSocket, hub: Hub, mut permit: Permit) {
    let subscriptions = &mut permit.feeds;
    let mut revisions = HashMap::new();
    let mut events = hub.events.subscribe();
    let mut ping = tokio::time::interval(Duration::from_secs(15));
    ping.tick().await;
    let deadline = tokio::time::sleep(Duration::from_secs(10));
    tokio::pin!(deadline);
    let mut subscribed = false;
    let mut command_window = Instant::now();
    let mut command_count = 0;
    let mut missed_pongs = 0;
    loop {
        tokio::select! {
            _ = hub.shutdown.cancelled() => break,
            _ = &mut deadline, if !subscribed => break,
            _ = ping.tick() => {
                if missed_pongs >= 2 { break; }
                missed_pongs += 1;
                if !matches!(timeout(WRITE_TIMEOUT, socket.send(Message::Ping(vec![]))).await, Ok(Ok(()))) { break; }
            }
            event = events.recv() => match event {
                Ok((id, revision, value)) if subscriptions.contains(&id) && revision > revisions.get(&id).copied().unwrap_or_default() => {
                    revisions.insert(id, revision);
                    if send(&mut socket, &hub, value).await.is_err() { break; }
                },
                Ok(_) => {},
                // Never silently drop a boundary frame for a slow reader.
                Err(_) => { hub.metrics.slow_clients.inc(); break },
            },
            message = socket.recv() => match message {
                Some(Ok(Message::Pong(_))) => missed_pongs = 0,
                Some(Ok(Message::Ping(_))) => {}, // Axum queues the pong automatically.
                Some(Ok(Message::Text(text))) => {
                    if command_window.elapsed() >= Duration::from_secs(1) { command_window = Instant::now(); command_count = 0; }
                    command_count += 1;
                    if command_count > 10 { break; }
                    let Ok(command) = serde_json::from_str::<Command>(&text) else {
                        if send(&mut socket, &hub, json!({"type":"error","code":"invalid_message","message":"expected subscribe or unsubscribe with feed_ids"})).await.is_err() { break; }
                        continue;
                    };
                    let values = match command {
                        Command::Unsubscribe { feed_ids } => {
                            for id in &feed_ids { if subscriptions.remove(id) { hub.metrics.subscriptions.with_label_values(&[&id.to_string()]).dec(); } }
                            vec![json!({"type":"unsubscribed","feed_ids":feed_ids})]
                        }
                        Command::Subscribe { feed_ids } => {
                            // Snapshot under the producer lock; revisions suppress events already
                            // represented in the snapshot without dropping existing feeds' frames.
                            let inner = hub.inner.lock().unwrap();
                            let mut next = subscriptions.clone();
                            let mut rejected = Vec::new();
                            let mut accepted = Vec::new();
                            let mut added = Vec::new();
                            for id in feed_ids {
                                if !inner.feeds.contains_key(&id) || (!next.contains(&id) && next.len() >= MAX_FEEDS) { rejected.push(id); }
                                else if !accepted.contains(&id) { if next.insert(id) { added.push(id); } accepted.push(id); }
                            }
                            *subscriptions = next;
                            for id in &added { hub.metrics.subscriptions.with_label_values(&[&id.to_string()]).inc(); }
                            let mut values = vec![json!({"type":"subscribed","feed_ids":accepted,"rejected":rejected})];
                            for id in &added {
                                let feed = &inner.feeds[id];
                                revisions.insert(*id, feed.revision);
                                if let Some(price) = &feed.latest { values.push(serde_json::to_value(price).unwrap()); }
                                values.push(status(*id, feed));
                            }
                            subscribed |= !subscriptions.is_empty();
                            values
                        }
                    };
                    for value in values { if send(&mut socket, &hub, value).await.is_err() { return; } }
                }
                _ => break,
            }
        }
    }
    let _ = timeout(WRITE_TIMEOUT, socket.close()).await;
}

#[cfg(test)]
mod tests;
