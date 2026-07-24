// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

use serde::{Deserialize, Serialize};
use std::collections::HashSet;

pub(super) const MICROS_PER_SECOND: u64 = 1_000_000;
const SECONDS_PER_MINUTE: u64 = 60;

#[derive(Clone, Debug)]
pub(super) struct PriceQuery {
    pub(super) ids: Vec<u32>,
    pub(super) ignore_invalid_price_ids: bool,
}

impl PriceQuery {
    pub(super) fn parse(raw_query: Option<&str>) -> Result<Self, String> {
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

    pub(super) fn unique_ids(&self) -> Vec<u32> {
        let mut seen = HashSet::new();
        self.ids
            .iter()
            .copied()
            .filter(|id| seen.insert(*id))
            .collect()
    }
}

#[derive(Clone, Debug, Eq, Hash, PartialEq, Serialize)]
pub(super) struct ChartHistoryQuery {
    pub(super) symbol: String,
    resolution: String,
    from: u64,
    to: u64,
}

impl ChartHistoryQuery {
    pub(super) fn parse(raw_query: Option<&str>) -> Result<Self, String> {
        let mut symbol = None;
        let mut resolution = None;
        let mut from = None;
        let mut to = None;

        for (name, value) in url::form_urlencoded::parse(raw_query.unwrap_or_default().as_bytes()) {
            match name.as_ref() {
                "symbol" => symbol = Some(normalize_history_symbol(&value)),
                "resolution" => resolution = Some(normalize_history_resolution(&value)?),
                "from" => {
                    from = Some(
                        value
                            .parse::<u64>()
                            .map_err(|_| "`from` must be a Unix timestamp in seconds".to_owned())?,
                    )
                }
                "to" => {
                    to = Some(
                        value
                            .parse::<u64>()
                            .map_err(|_| "`to` must be a Unix timestamp in seconds".to_owned())?,
                    )
                }
                _ => {}
            }
        }

        // Pyth Pro History requires all four parameters. Rejecting malformed
        // requests here avoids spending upstream quota on calls it cannot serve.
        let symbol = symbol
            .filter(|symbol| !symbol.is_empty())
            .ok_or_else(|| "`symbol` is required (for example, `Crypto.BTC/USD`)".to_owned())?;
        let resolution = resolution.ok_or_else(|| "`resolution` is required".to_owned())?;
        let from = from.ok_or_else(|| "`from` is required".to_owned())?;
        let to = to.ok_or_else(|| "`to` is required".to_owned())?;
        if from > to {
            return Err("`from` must be less than or equal to `to`".to_owned());
        }
        // TradingView bars are minute-aligned. Canonicalizing inclusive bounds
        // makes requests from different browser sessions share the same cache key
        // without changing which complete bars fall inside the requested window.
        let aligned_from = from
            .checked_add(SECONDS_PER_MINUTE - 1)
            .map(|value| value / SECONDS_PER_MINUTE * SECONDS_PER_MINUTE)
            .ok_or_else(|| "`from` is too large".to_owned())?;
        let aligned_to = to / SECONDS_PER_MINUTE * SECONDS_PER_MINUTE;
        let (from, to) = if aligned_from <= aligned_to {
            (aligned_from, aligned_to)
        } else {
            (from, to)
        };

        Ok(Self {
            symbol,
            resolution,
            from,
            to,
        })
    }
}

pub(super) fn normalize_history_symbol(symbol: &str) -> String {
    symbol.trim().to_ascii_lowercase()
}

pub(super) fn normalize_history_resolution(resolution: &str) -> Result<String, String> {
    let resolution = resolution.trim().to_ascii_uppercase();
    let canonical = match resolution.as_str() {
        "1" | "2" | "5" | "15" | "30" | "60" | "120" | "240" | "360" | "720" => {
            resolution
        }
        "D" | "1D" => "D".to_owned(),
        "W" | "1W" => "W".to_owned(),
        "M" | "1M" => "M".to_owned(),
        _ => {
            return Err(format!(
                "unsupported `resolution` `{resolution}`; expected 1, 2, 5, 15, 30, 60, 120, 240, 360, 720, D, W, or M"
            ))
        }
    };
    Ok(canonical)
}

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub(super) struct PythProRequest {
    price_feed_ids: Vec<u32>,
    properties: Vec<PythProProperty>,
    formats: Vec<String>,
    channel: PythProChannel,
    parsed: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    timestamp: Option<u64>,
}

impl PythProRequest {
    pub(super) fn latest(price_feed_ids: Vec<u32>) -> Self {
        Self::new(price_feed_ids, None)
    }

    pub(super) fn historical(price_feed_ids: Vec<u32>, timestamp_us: u64) -> Self {
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
pub(super) struct PythProJsonUpdate {
    pub(super) parsed: Option<PythProParsedPayload>,
}

#[derive(Clone, Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(super) struct PythProParsedPayload {
    #[allow(dead_code)]
    timestamp_us: String,
    pub(super) price_feeds: Vec<PythProFeed>,
}

#[derive(Clone, Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(super) struct PythProFeed {
    pub(super) price_feed_id: u32,
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
pub(super) struct PriceResponse {
    pub(super) parsed: Vec<PriceUpdate>,
}

#[derive(Clone, Debug, Serialize)]
pub(super) struct PriceUpdate {
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
