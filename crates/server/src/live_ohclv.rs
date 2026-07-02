// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

use std::collections::{BTreeSet, HashMap};
use std::sync::{Arc, RwLock};
use std::time::{Duration, SystemTime, UNIX_EPOCH};
use tokio::time::{self, MissedTickBehavior};

use crate::error::DeepBookError;
use crate::reader::Reader;

const MINUTE_MS: i64 = 60_000;
pub const OHCLV_DEFAULT_LIMIT: i32 = 1000;
pub const OHCLV_DEFAULT_WINDOW_MS: i64 = 7 * 24 * 60 * MINUTE_MS;
const LIVE_OHCLV_POLL_LOOKBACK_MS: i64 = 10 * MINUTE_MS;
const LIVE_OHCLV_MAX_MATERIALIZER_LAG_MS: i64 = 3 * LIVE_OHCLV_POLL_LOOKBACK_MS;

#[derive(Clone, Debug, PartialEq)]
pub struct Candle {
    pub timestamp_ms: i64,
    pub open: f64,
    pub high: f64,
    pub low: f64,
    pub close: f64,
    pub base_volume: f64,
    pub first_trade_timestamp_ms: Option<i64>,
    pub last_trade_timestamp_ms: Option<i64>,
}

#[derive(Clone, Debug, PartialEq)]
pub struct LiveFill {
    pub event_digest: String,
    pub pool_id: String,
    pub checkpoint_timestamp_ms: i64,
    pub price: f64,
    pub base_volume: f64,
}

#[derive(Clone, Debug, Eq, Hash, PartialEq)]
pub struct MinuteKey {
    pub pool_id: String,
    pub bucket_start_ms: i64,
}

#[derive(Clone, Debug)]
pub struct LiveOhclvCache {
    state: Arc<RwLock<LiveOhclvState>>,
    max_fills: usize,
}

#[derive(Debug, Default)]
struct LiveOhclvState {
    fills_by_digest: HashMap<String, LiveFill>,
    fill_order: BTreeSet<FillOrderKey>,
    watermarks: HashMap<MinuteKey, i64>,
    latest_materialized_timestamp_ms: Option<i64>,
}

#[derive(Clone, Debug, Eq, Ord, PartialEq, PartialOrd)]
struct FillOrderKey {
    timestamp_ms: i64,
    event_digest: String,
}

struct LiveAggregate {
    open: f64,
    high: f64,
    low: f64,
    close: f64,
    base_volume: f64,
    first_trade_timestamp_ms: i64,
    last_trade_timestamp_ms: i64,
}

impl LiveOhclvCache {
    pub fn new(max_fills: usize) -> Self {
        Self {
            state: Arc::new(RwLock::new(LiveOhclvState::default())),
            max_fills,
        }
    }

    pub fn max_fills(&self) -> usize {
        self.max_fills
    }

    pub fn replace_watermarks(&self, watermarks: Vec<(MinuteKey, i64)>) {
        let mut state = self.state.write().expect("live OHCLV cache lock poisoned");
        let latest_materialized_timestamp_ms = watermarks
            .iter()
            .map(|(_, timestamp_ms)| *timestamp_ms)
            .max();
        replace_watermarks_locked(&mut state, latest_materialized_timestamp_ms, watermarks);
    }

    pub fn insert_fills(&self, fills: Vec<LiveFill>) {
        let mut state = self.state.write().expect("live OHCLV cache lock poisoned");

        for fill in fills {
            if is_fill_materialized(&state, &fill) {
                continue;
            }

            if let Some(existing) = state.fills_by_digest.remove(&fill.event_digest) {
                state.fill_order.remove(&FillOrderKey {
                    timestamp_ms: existing.checkpoint_timestamp_ms,
                    event_digest: existing.event_digest,
                });
            }

            state.fill_order.insert(FillOrderKey {
                timestamp_ms: fill.checkpoint_timestamp_ms,
                event_digest: fill.event_digest.clone(),
            });
            state
                .fills_by_digest
                .insert(fill.event_digest.clone(), fill);
        }

        let dropped = prune_to_capacity(&mut state, self.max_fills);
        if dropped > 0 {
            tracing::warn!(
                dropped,
                max_fills = self.max_fills,
                "Live OHCLV cache reached capacity; overlay may be incomplete"
            );
        }
    }

    #[doc(hidden)]
    pub fn cached_fills(&self) -> Vec<LiveFill> {
        let state = self.state.read().expect("live OHCLV cache lock poisoned");
        state
            .fill_order
            .iter()
            .filter_map(|key| state.fills_by_digest.get(&key.event_digest).cloned())
            .collect()
    }

    pub fn overlay_candles(
        &self,
        interval: &str,
        pool_id: &str,
        start_time_ms: i64,
        end_time_ms: i64,
        limit: i32,
        stored: Vec<Candle>,
    ) -> Vec<Candle> {
        let Some(interval_ms) = interval_width_ms(interval) else {
            return stored;
        };

        // Only overlay fills that match this request and are still newer than the
        // corresponding materialized 1m candle watermark.
        let state = self.state.read().expect("live OHCLV cache lock poisoned");
        let mut live_fills: Vec<LiveFill> = state
            .fills_by_digest
            .values()
            .filter(|fill| {
                fill.pool_id == pool_id
                    && fill.checkpoint_timestamp_ms >= start_time_ms
                    && fill.checkpoint_timestamp_ms <= end_time_ms
                    && !is_fill_materialized(&state, fill)
            })
            .cloned()
            .collect();
        drop(state);

        // Open/close depend on fill order. Event digest gives deterministic
        // ordering for same-millisecond fills.
        live_fills.sort_by(|a, b| {
            a.checkpoint_timestamp_ms
                .cmp(&b.checkpoint_timestamp_ms)
                .then_with(|| a.event_digest.cmp(&b.event_digest))
        });

        let stored_watermarks: HashMap<i64, i64> = if interval_ms == MINUTE_MS {
            stored
                .iter()
                .filter_map(|candle| {
                    candle
                        .last_trade_timestamp_ms
                        .map(|last_trade_timestamp_ms| {
                            (candle.timestamp_ms, last_trade_timestamp_ms)
                        })
                })
                .collect()
        } else {
            HashMap::new()
        };

        // Aggregate raw live fills into the requested interval before merging
        // them with DB candles.
        let mut live_by_bucket: HashMap<i64, LiveAggregate> = HashMap::new();
        for fill in live_fills {
            let bucket_start_ms = bucket_start_ms(fill.checkpoint_timestamp_ms, interval_ms);
            if bucket_start_ms < start_time_ms {
                continue;
            }

            if stored_watermarks
                .get(&bucket_start_ms)
                .is_some_and(|last_trade_timestamp_ms| {
                    fill.checkpoint_timestamp_ms <= *last_trade_timestamp_ms
                })
            {
                continue;
            }

            live_by_bucket
                .entry(bucket_start_ms)
                .and_modify(|aggregate| {
                    aggregate.high = aggregate.high.max(fill.price);
                    aggregate.low = aggregate.low.min(fill.price);
                    aggregate.close = fill.price;
                    aggregate.base_volume += fill.base_volume;
                    aggregate.last_trade_timestamp_ms = fill.checkpoint_timestamp_ms;
                })
                .or_insert(LiveAggregate {
                    open: fill.price,
                    high: fill.price,
                    low: fill.price,
                    close: fill.price,
                    base_volume: fill.base_volume,
                    first_trade_timestamp_ms: fill.checkpoint_timestamp_ms,
                    last_trade_timestamp_ms: fill.checkpoint_timestamp_ms,
                });
        }

        let mut candles_by_bucket: HashMap<i64, Candle> = stored
            .into_iter()
            .map(|candle| (candle.timestamp_ms, candle))
            .collect();

        // Preserve the stored open when a DB candle exists, but let live fills
        // extend high/low/close/volume. Missing DB buckets are pure live candles.
        for (bucket_start_ms, live) in live_by_bucket {
            candles_by_bucket
                .entry(bucket_start_ms)
                .and_modify(|candle| {
                    if candle
                        .first_trade_timestamp_ms
                        .is_some_and(|first_trade_timestamp_ms| {
                            live.first_trade_timestamp_ms < first_trade_timestamp_ms
                        })
                    {
                        candle.open = live.open;
                    }
                    candle.high = candle.high.max(live.high);
                    candle.low = candle.low.min(live.low);
                    if candle
                        .last_trade_timestamp_ms
                        .map_or(true, |last_trade_timestamp_ms| {
                            live.last_trade_timestamp_ms > last_trade_timestamp_ms
                        })
                    {
                        candle.close = live.close;
                    }
                    candle.base_volume += live.base_volume;
                })
                .or_insert(Candle {
                    timestamp_ms: bucket_start_ms,
                    open: live.open,
                    high: live.high,
                    low: live.low,
                    close: live.close,
                    base_volume: live.base_volume,
                    first_trade_timestamp_ms: None,
                    last_trade_timestamp_ms: None,
                });
        }

        let mut candles: Vec<Candle> = candles_by_bucket.into_values().collect();
        candles.sort_by(|a, b| b.timestamp_ms.cmp(&a.timestamp_ms));

        candles.truncate(normalized_limit(limit));

        candles
    }

    pub(crate) async fn poll_once(&self, reader: &Reader) -> Result<(), DeepBookError> {
        self.poll_once_at(reader, current_time_ms()).await
    }

    pub(crate) async fn poll_once_at(
        &self,
        reader: &Reader,
        now_ms: i64,
    ) -> Result<(), DeepBookError> {
        let Some(latest_materialized_timestamp_ms) = reader
            .get_live_ohclv_latest_materialized_timestamp()
            .await?
        else {
            self.clear(None);
            return Ok(());
        };

        if latest_materialized_timestamp_ms
            < now_ms.saturating_sub(LIVE_OHCLV_MAX_MATERIALIZER_LAG_MS)
        {
            self.clear(Some(latest_materialized_timestamp_ms));
            tracing::warn!(
                latest_materialized_timestamp_ms,
                now_ms,
                max_lag_ms = LIVE_OHCLV_MAX_MATERIALIZER_LAG_MS,
                "Live OHCLV overlay disabled because materialized OHCLV is stale"
            );
            return Ok(());
        }

        let start_timestamp_ms =
            latest_materialized_timestamp_ms.saturating_sub(LIVE_OHCLV_POLL_LOOKBACK_MS);

        let watermarks = reader
            .get_live_ohclv_watermarks_since(start_timestamp_ms)
            .await?;
        self.replace_watermarks_with_latest(latest_materialized_timestamp_ms, watermarks);

        let fills = reader
            .get_live_ohclv_fills_since(start_timestamp_ms, self.max_fills())
            .await?;
        self.insert_fills(fills);

        Ok(())
    }

    fn replace_watermarks_with_latest(
        &self,
        latest_materialized_timestamp_ms: i64,
        watermarks: Vec<(MinuteKey, i64)>,
    ) {
        let mut state = self.state.write().expect("live OHCLV cache lock poisoned");
        replace_watermarks_locked(
            &mut state,
            Some(latest_materialized_timestamp_ms),
            watermarks,
        );
    }

    fn clear(&self, latest_materialized_timestamp_ms: Option<i64>) {
        let mut state = self.state.write().expect("live OHCLV cache lock poisoned");
        state.fills_by_digest.clear();
        state.fill_order.clear();
        state.watermarks.clear();
        state.latest_materialized_timestamp_ms = latest_materialized_timestamp_ms;
    }

    pub(crate) async fn run_poll_loop(&self, reader: Reader, poll_interval: Duration) {
        let mut ticker = time::interval(poll_interval);
        ticker.set_missed_tick_behavior(MissedTickBehavior::Skip);

        loop {
            ticker.tick().await;
            if let Err(error) = self.poll_once(&reader).await {
                tracing::warn!("Live OHCLV cache poll failed: {}", error);
            }
        }
    }
}

fn interval_width_ms(interval: &str) -> Option<i64> {
    match interval {
        "1m" => Some(MINUTE_MS),
        "5m" => Some(5 * MINUTE_MS),
        "15m" => Some(15 * MINUTE_MS),
        "30m" => Some(30 * MINUTE_MS),
        "1h" => Some(60 * MINUTE_MS),
        "4h" => Some(4 * 60 * MINUTE_MS),
        _ => None,
    }
}

fn normalized_limit(limit: i32) -> usize {
    match limit {
        limit if limit <= 0 => 0,
        limit => limit as usize,
    }
}

fn bucket_start_ms(timestamp_ms: i64, interval_ms: i64) -> i64 {
    timestamp_ms.div_euclid(interval_ms) * interval_ms
}

fn minute_bucket_start_ms(timestamp_ms: i64) -> i64 {
    bucket_start_ms(timestamp_ms, MINUTE_MS)
}

fn is_fill_materialized(state: &LiveOhclvState, fill: &LiveFill) -> bool {
    let minute_key = MinuteKey {
        pool_id: fill.pool_id.clone(),
        bucket_start_ms: minute_bucket_start_ms(fill.checkpoint_timestamp_ms),
    };
    state
        .watermarks
        .get(&minute_key)
        .is_some_and(|last_trade_timestamp| fill.checkpoint_timestamp_ms <= *last_trade_timestamp)
}

fn replace_watermarks_locked(
    state: &mut LiveOhclvState,
    latest_materialized_timestamp_ms: Option<i64>,
    watermarks: Vec<(MinuteKey, i64)>,
) {
    if latest_materialized_timestamp_ms.is_some() {
        state.latest_materialized_timestamp_ms = latest_materialized_timestamp_ms;
    }
    state.watermarks = watermarks.into_iter().collect();
    prune_materialized_fills(state);
}

fn prune_materialized_fills(state: &mut LiveOhclvState) {
    let digests_to_remove: Vec<String> = state
        .fills_by_digest
        .values()
        .filter(|fill| is_fill_materialized(state, fill))
        .map(|fill| fill.event_digest.clone())
        .collect();

    for event_digest in digests_to_remove {
        remove_fill(state, &event_digest);
    }
}

fn prune_to_capacity(state: &mut LiveOhclvState, max_fills: usize) -> usize {
    let mut dropped = 0;
    while state.fills_by_digest.len() > max_fills {
        let Some(oldest) = state.fill_order.iter().next().cloned() else {
            break;
        };
        remove_fill(state, &oldest.event_digest);
        dropped += 1;
    }
    dropped
}

fn remove_fill(state: &mut LiveOhclvState, event_digest: &str) {
    if let Some(fill) = state.fills_by_digest.remove(event_digest) {
        state.fill_order.remove(&FillOrderKey {
            timestamp_ms: fill.checkpoint_timestamp_ms,
            event_digest: fill.event_digest,
        });
    }
}

fn current_time_ms() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis() as i64
}
