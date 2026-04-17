// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

//! DeepBook maker incentive scoring engine.
//!
//! This crate computes per-maker reward scores from on-chain order book events
//! and signs them inside a Nautilus secure enclave. The signed results are
//! verified on-chain by the `maker_incentives` Move contract.

pub mod data_validation;
pub mod pool_info;
pub mod scoring;
pub mod types;

pub use data_validation::ServerDataValidationConfig;
pub use types::{INCENTIVE_EPOCH_DURATION_MS, INCENTIVE_WINDOW_DURATION_MS};

use std::collections::HashMap;

use axum::http::StatusCode;
use axum::response::{IntoResponse, Response};
use axum::Json;
use fastcrypto::ed25519::Ed25519KeyPair;
use serde_json::json;

pub struct AppState {
    pub eph_kp: Ed25519KeyPair,
    pub server_url: String,
    /// Base indexer `/status` thresholds and optional required pipeline names (see `data_validation`).
    pub indexer_validation: ServerDataValidationConfig,
    /// When true, skip `GET /status` (local development only).
    pub skip_indexer_check: bool,
    /// Optional SUI full-node RPC URL for fetching pool metadata directly.
    pub sui_rpc_url: Option<String>,
}

/// Compute a fund-level loyalty streak by counting consecutive prior epochs
/// (stepping back by `epoch_duration_ms`) where the indexer has an on-chain
/// `EpochResultsSubmitted` event for the given fund.
///
/// This replaces the old approach of reading from the writable
/// `maker_incentive_maker_participation` table, which was gameable because
/// anyone could call `POST /incentives/record_maker_participation`.
pub async fn compute_fund_loyalty_streak(
    client: &reqwest::Client,
    server_url: &str,
    fund_id: &str,
    epoch_start_ms: u64,
    epoch_duration_ms: u64,
) -> Result<u32, String> {
    let mut streak: u32 = 0;
    let mut k: u64 = 1;

    loop {
        let Some(delta) = k.checked_mul(epoch_duration_ms) else {
            break;
        };
        let Some(prior_start) = epoch_start_ms.checked_sub(delta) else {
            break;
        };
        let prior_end = prior_start + epoch_duration_ms;

        let url = format!(
            "{}/maker_incentive_epoch_results_submitted?start_time={}&end_time={}&fund_id={}&limit=1",
            server_url.trim_end_matches('/'),
            prior_start,
            prior_end,
            fund_id,
        );

        let resp = client
            .get(&url)
            .send()
            .await
            .map_err(|e| format!("loyalty streak query failed: {e}"))?;

        if !resp.status().is_success() {
            let status = resp.status();
            let body = resp.text().await.unwrap_or_default();
            return Err(format!(
                "loyalty streak query returned {status}: {body}"
            ));
        }

        let events: Vec<serde_json::Value> = resp
            .json()
            .await
            .map_err(|e| format!("loyalty streak response parse error: {e}"))?;

        let has_submission = events.iter().any(|ev| {
            ev.get("fund_id")
                .and_then(|v| v.as_str())
                .map(|fid| fid == fund_id)
                .unwrap_or(false)
        });

        if has_submission {
            streak += 1;
            k += 1;
        } else {
            break;
        }
    }

    Ok(streak)
}

/// Build a loyalty map from a fund-level streak: every candidate maker gets
/// the same streak count.
pub fn fund_streak_to_loyalty_map(
    candidates: &[String],
    fund_streak: u32,
) -> HashMap<String, u32> {
    candidates
        .iter()
        .map(|id| (id.clone(), fund_streak))
        .collect()
}

#[derive(Debug)]
pub enum IncentiveError {
    BadRequest(String),
    Internal(String),
}

impl IntoResponse for IncentiveError {
    fn into_response(self) -> Response {
        let (status, msg) = match self {
            IncentiveError::BadRequest(e) => (StatusCode::BAD_REQUEST, e),
            IncentiveError::Internal(e) => (StatusCode::INTERNAL_SERVER_ERROR, e),
        };
        (status, Json(json!({ "error": msg }))).into_response()
    }
}
