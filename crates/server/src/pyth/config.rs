// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

use std::time::Duration;
use url::Url;

pub const DEFAULT_PRO_URL: &str = "https://pyth-lazer-0.dourolabs.app/v1";
pub const DEFAULT_PRO_HISTORY_URL: &str = "https://pyth.dourolabs.app/v1";
pub const DEFAULT_LATEST_CACHE_TTL_MS: u64 = 1_000;
pub const DEFAULT_HISTORY_CACHE_TTL_SECS: u64 = 86_400;
pub const DEFAULT_HISTORY_CACHE_MAX_ENTRIES: u64 = 10_000;
pub const DEFAULT_CHART_HISTORY_CACHE_TTL_SECS: u64 = 60;
pub const DEFAULT_CHART_HISTORY_CACHE_MAX_ENTRIES: u64 = 256;
pub const DEFAULT_CHART_HISTORY_MAX_RANGE_SECS: u64 = 90 * 86_400;

pub const LATEST_PRICE_PATH: &str = "/updates/price/latest";
pub const PRICE_AT_TIMESTAMP_PATH: &str = "/updates/price/:publish_time";
pub const TRADINGVIEW_HISTORY_PATH: &str = "/shims/tradingview/history";

pub(super) const LATEST_UPSTREAM_PATH: &str = "latest_price";
pub(super) const HISTORY_UPSTREAM_PATH: &str = "price";
pub(super) const CHART_HISTORY_UPSTREAM_PATH: &str = "fixed_rate@200ms/history";

#[derive(Clone, Debug)]
pub struct PythChartHistoryConfig {
    pub upstream_url: Url,
    pub symbols: Vec<String>,
    pub cache_ttl: Duration,
    pub cache_max_entries: u64,
    pub max_range: Duration,
}

impl Default for PythChartHistoryConfig {
    fn default() -> Self {
        Self {
            upstream_url: Url::parse(DEFAULT_PRO_HISTORY_URL)
                .expect("default Pyth Pro History URL must be valid"),
            symbols: Vec::new(),
            cache_ttl: Duration::from_secs(DEFAULT_CHART_HISTORY_CACHE_TTL_SECS),
            cache_max_entries: DEFAULT_CHART_HISTORY_CACHE_MAX_ENTRIES,
            max_range: Duration::from_secs(DEFAULT_CHART_HISTORY_MAX_RANGE_SECS),
        }
    }
}

#[derive(Clone, Debug)]
pub struct PythProConfig {
    pub allowed_feed_ids: Vec<u32>,
    pub latest_cache_ttl: Duration,
    pub history_cache_ttl: Duration,
    pub history_cache_max_entries: u64,
    pub chart_history: PythChartHistoryConfig,
}

impl Default for PythProConfig {
    fn default() -> Self {
        Self {
            allowed_feed_ids: Vec::new(),
            latest_cache_ttl: Duration::from_millis(DEFAULT_LATEST_CACHE_TTL_MS),
            history_cache_ttl: Duration::from_secs(DEFAULT_HISTORY_CACHE_TTL_SECS),
            history_cache_max_entries: DEFAULT_HISTORY_CACHE_MAX_ENTRIES,
            chart_history: PythChartHistoryConfig::default(),
        }
    }
}
