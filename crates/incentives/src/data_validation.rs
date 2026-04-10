// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

//! Pre-scoring validation of deepbook-server responses: indexer watermarks via
//! `/status` (sui-indexer-alt style) and structural checks on incentive pool JSON.

use std::fmt;

use reqwest::Client;
use serde::Deserialize;

use crate::types::PoolDataResponse;

/// Thresholds passed to `GET /status` and optional pipeline / epoch checks.
#[derive(Debug, Clone)]
pub struct ServerDataValidationConfig {
    /// Forwarded as `max_checkpoint_lag` query param (default on server: 100).
    pub max_checkpoint_lag: i64,
    /// Forwarded as `max_time_lag_seconds` query param (default on server: 60).
    pub max_time_lag_seconds: i64,
    /// Each name must match a live (non-backfill) pipeline in `/status`.
    /// Empty = rely only on top-level `status` from the server.
    pub required_pipelines: Vec<String>,
    /// If set, every pipeline checked for timestamp coverage must have
    /// `indexed_timestamp_ms >= min_indexed_timestamp_ms`.
    /// Use the incentive epoch end (ms) so indexed high-water marks cover the window.
    pub min_indexed_timestamp_ms: Option<i64>,
}

impl Default for ServerDataValidationConfig {
    fn default() -> Self {
        Self {
            max_checkpoint_lag: 100,
            max_time_lag_seconds: 60,
            required_pipelines: Vec::new(),
            min_indexed_timestamp_ms: None,
        }
    }
}

#[derive(Debug)]
pub enum DataValidationError {
    Configuration(String),
    Http(String),
    StatusNotOk {
        status: String,
        max_checkpoint_lag: i64,
        max_time_lag_seconds: i64,
        max_lag_pipeline: Option<String>,
    },
    MissingPipeline(String),
    PipelineTimestampNotCovered {
        pipeline: String,
        indexed_timestamp_ms: i64,
        required_min_ms: i64,
    },
    PoolData(String),
}

impl fmt::Display for DataValidationError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            DataValidationError::Configuration(msg) => write!(f, "{msg}"),
            DataValidationError::Http(msg) => write!(f, "{msg}"),
            DataValidationError::StatusNotOk {
                status,
                max_checkpoint_lag,
                max_time_lag_seconds,
                max_lag_pipeline,
            } => write!(
                f,
                "indexer /status reports {status:?} (thresholds: max_checkpoint_lag={max_checkpoint_lag}, max_time_lag_seconds={max_time_lag_seconds}){}",
                max_lag_pipeline
                    .as_ref()
                    .map(|p| format!(", worst pipeline: {p}"))
                    .unwrap_or_default()
            ),
            DataValidationError::MissingPipeline(name) => {
                write!(f, "required indexer pipeline {name:?} not found in /status (non-backfill)")
            }
            DataValidationError::PipelineTimestampNotCovered {
                pipeline,
                indexed_timestamp_ms,
                required_min_ms,
            } => write!(
                f,
                "pipeline {pipeline:?} indexed_timestamp_ms={indexed_timestamp_ms} is below required epoch bound {required_min_ms}"
            ),
            DataValidationError::PoolData(msg) => write!(f, "{msg}"),
        }
    }
}

impl std::error::Error for DataValidationError {}

#[derive(Debug, Deserialize)]
struct StatusResponse {
    status: String,
    #[serde(default)]
    max_lag_pipeline: Option<String>,
    max_checkpoint_lag: i64,
    max_time_lag_seconds: i64,
    pipelines: Vec<PipelineStatus>,
}

#[derive(Debug, Deserialize)]
struct PipelineStatus {
    pipeline: String,
    indexed_timestamp_ms: i64,
    checkpoint_lag: i64,
    time_lag_seconds: i64,
    #[serde(default)]
    is_backfill: bool,
}

fn join_url(base: &str, path: &str) -> String {
    format!("{}{}", base.trim_end_matches('/'), path)
}

/// Merge per-epoch watermark bound: when `required_pipelines` is set and no explicit
/// `min_indexed_timestamp_ms` is configured, require indexer high watermarks ≥ epoch end.
pub fn indexer_validation_for_epoch(
    base: &ServerDataValidationConfig,
    epoch_end_ms: u64,
) -> ServerDataValidationConfig {
    let mut c = base.clone();
    if c.min_indexed_timestamp_ms.is_none() && !c.required_pipelines.is_empty() {
        c.min_indexed_timestamp_ms = Some(epoch_end_ms as i64);
    }
    c
}

/// Query deepbook-server `/status` and enforce indexer health + optional pipeline rules.
pub async fn validate_indexer_readiness(
    client: &Client,
    server_url: &str,
    config: &ServerDataValidationConfig,
) -> Result<(), DataValidationError> {
    let url = format!(
        "{}?max_checkpoint_lag={}&max_time_lag_seconds={}",
        join_url(server_url, "/status"),
        config.max_checkpoint_lag,
        config.max_time_lag_seconds
    );

    let resp = client
        .get(&url)
        .send()
        .await
        .map_err(|e| DataValidationError::Http(format!("GET /status failed: {e}")))?;

    if !resp.status().is_success() {
        let status = resp.status();
        let body = resp.text().await.unwrap_or_default();
        return Err(DataValidationError::Http(format!(
            "/status returned {status}: {body}"
        )));
    }

    let body: StatusResponse = resp
        .json()
        .await
        .map_err(|e| DataValidationError::Http(format!("invalid /status JSON: {e}")))?;

    if body.status != "OK" {
        return Err(DataValidationError::StatusNotOk {
            status: body.status,
            max_checkpoint_lag: body.max_checkpoint_lag,
            max_time_lag_seconds: body.max_time_lag_seconds,
            max_lag_pipeline: body.max_lag_pipeline,
        });
    }

    let required: Vec<String> = config
        .required_pipelines
        .iter()
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty())
        .collect();

    if config.min_indexed_timestamp_ms.is_some() && required.is_empty() {
        return Err(DataValidationError::Configuration(
            "min_indexed_timestamp_ms is set but required_pipelines is empty; list the \
             indexer pipelines that feed order_updates / order_fills / stakes (e.g. deepbook_indexer)"
                .into(),
        ));
    }

    // When names are configured, re-check those pipelines individually. `/status` OK already
    // bounds worst-case lag across non-backfill pipelines; this verifies required rows exist and
    // (optionally) that watermark timestamps cover the incentive epoch end.
    for name in &required {
        let p = body
            .pipelines
            .iter()
            .find(|p| p.pipeline == *name && !p.is_backfill)
            .ok_or_else(|| DataValidationError::MissingPipeline(name.clone()))?;

        if p.checkpoint_lag > config.max_checkpoint_lag {
            return Err(DataValidationError::StatusNotOk {
                status: "UNHEALTHY".into(),
                max_checkpoint_lag: p.checkpoint_lag,
                max_time_lag_seconds: body.max_time_lag_seconds,
                max_lag_pipeline: Some(p.pipeline.clone()),
            });
        }
        if p.time_lag_seconds > config.max_time_lag_seconds {
            return Err(DataValidationError::StatusNotOk {
                status: "UNHEALTHY".into(),
                max_checkpoint_lag: body.max_checkpoint_lag,
                max_time_lag_seconds: p.time_lag_seconds,
                max_lag_pipeline: Some(p.pipeline.clone()),
            });
        }

        if let Some(min_ts) = config.min_indexed_timestamp_ms {
            if p.indexed_timestamp_ms < min_ts {
                return Err(DataValidationError::PipelineTimestampNotCovered {
                    pipeline: p.pipeline.clone(),
                    indexed_timestamp_ms: p.indexed_timestamp_ms,
                    required_min_ms: min_ts,
                });
            }
        }
    }

    Ok(())
}

/// Validate decoded incentive pool payload: pool id, time range, and numeric invariants.
pub fn validate_pool_data(
    data: &PoolDataResponse,
    expected_pool_id: &str,
    epoch_start_ms: i64,
    epoch_end_ms: i64,
) -> Result<(), DataValidationError> {
    if epoch_start_ms >= epoch_end_ms {
        return Err(DataValidationError::PoolData(format!(
            "invalid epoch range: start {epoch_start_ms} >= end {epoch_end_ms}"
        )));
    }

    if let Some(meta) = &data.pool_metadata {
        if meta.base_symbol.is_empty() || meta.quote_symbol.is_empty() {
            return Err(DataValidationError::PoolData(
                "pool_metadata has empty base_symbol or quote_symbol".into(),
            ));
        }
    }

    for (i, o) in data.order_events.iter().enumerate() {
        if o.pool_id != expected_pool_id {
            return Err(DataValidationError::PoolData(format!(
                "order_events[{i}].pool_id mismatch: expected {expected_pool_id}, got {}",
                o.pool_id
            )));
        }
        if o.order_id.is_empty() {
            return Err(DataValidationError::PoolData(format!(
                "order_events[{i}].order_id is empty"
            )));
        }
        if o.balance_manager_id.is_empty() {
            return Err(DataValidationError::PoolData(format!(
                "order_events[{i}].balance_manager_id is empty"
            )));
        }
        if o.checkpoint_timestamp_ms < epoch_start_ms || o.checkpoint_timestamp_ms > epoch_end_ms {
            return Err(DataValidationError::PoolData(format!(
                "order_events[{i}].checkpoint_timestamp_ms {} outside epoch [{epoch_start_ms}, {epoch_end_ms}]",
                o.checkpoint_timestamp_ms
            )));
        }
        if o.original_quantity < 0 || o.quantity < 0 {
            return Err(DataValidationError::PoolData(format!(
                "order_events[{i}] has negative quantity fields"
            )));
        }
    }

    for (i, f) in data.fill_events.iter().enumerate() {
        if f.pool_id != expected_pool_id {
            return Err(DataValidationError::PoolData(format!(
                "fill_events[{i}].pool_id mismatch: expected {expected_pool_id}, got {}",
                f.pool_id
            )));
        }
        if f.maker_order_id.is_empty() {
            return Err(DataValidationError::PoolData(format!(
                "fill_events[{i}].maker_order_id is empty"
            )));
        }
        if f.checkpoint_timestamp_ms < epoch_start_ms || f.checkpoint_timestamp_ms > epoch_end_ms {
            return Err(DataValidationError::PoolData(format!(
                "fill_events[{i}].checkpoint_timestamp_ms {} outside epoch [{epoch_start_ms}, {epoch_end_ms}]",
                f.checkpoint_timestamp_ms
            )));
        }
        if f.base_quantity <= 0 || f.quote_quantity <= 0 {
            return Err(DataValidationError::PoolData(format!(
                "fill_events[{i}] non-positive base_quantity or quote_quantity"
            )));
        }
    }

    for (i, s) in data.stake_events.iter().enumerate() {
        if s.balance_manager_id.is_empty() {
            return Err(DataValidationError::PoolData(format!(
                "stake_events[{i}].balance_manager_id is empty"
            )));
        }
        if s.amount <= 0 {
            return Err(DataValidationError::PoolData(format!(
                "stake_events[{i}].amount must be positive"
            )));
        }
    }

    if data.stake_required < 0 {
        return Err(DataValidationError::PoolData(
            "stake_required must be >= 0".into(),
        ));
    }

    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::types::{FillEvent, OrderEvent, PoolMetadata, StakeEntry};

    #[test]
    fn pool_data_rejects_fill_outside_epoch() {
        let data = PoolDataResponse {
            order_events: vec![],
            fill_events: vec![FillEvent {
                pool_id: "0xabc".into(),
                maker_order_id: "o1".into(),
                base_quantity: 1,
                quote_quantity: 1,
                checkpoint_timestamp_ms: 50,
            }],
            stake_events: vec![],
            stake_required: 0,
            pool_metadata: None,
        };
        let err = validate_pool_data(&data, "0xabc", 0, 40).unwrap_err();
        assert!(matches!(err, DataValidationError::PoolData(_)));
    }

    #[test]
    fn pool_data_accepts_empty_events() {
        let data = PoolDataResponse {
            order_events: vec![],
            fill_events: vec![],
            stake_events: vec![],
            stake_required: 0,
            pool_metadata: Some(PoolMetadata {
                base_decimals: 9,
                base_symbol: "SUI".into(),
                quote_decimals: 6,
                quote_symbol: "USDC".into(),
            }),
        };
        validate_pool_data(&data, "0xabc", 0, 100).unwrap();
    }

    #[test]
    fn pool_data_rejects_pool_id_mismatch() {
        let data = PoolDataResponse {
            order_events: vec![OrderEvent {
                order_id: "a".into(),
                status: "Placed".into(),
                pool_id: "wrong".into(),
                price: 1,
                is_bid: true,
                original_quantity: 1,
                quantity: 1,
                balance_manager_id: "bm".into(),
                checkpoint_timestamp_ms: 10,
            }],
            fill_events: vec![],
            stake_events: vec![],
            stake_required: 0,
            pool_metadata: None,
        };
        assert!(validate_pool_data(&data, "0xabc", 0, 100).is_err());
    }

    #[test]
    fn pool_data_rejects_bad_stake() {
        let data = PoolDataResponse {
            order_events: vec![],
            fill_events: vec![],
            stake_events: vec![StakeEntry {
                balance_manager_id: "bm".into(),
                amount: 0,
                stake: true,
            }],
            stake_required: 0,
            pool_metadata: None,
        };
        assert!(validate_pool_data(&data, "0xabc", 0, 100).is_err());
    }
}
