// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

use crate::config::Config;
use crate::metrics::{self, BenchMetrics, RunStatus};
use crate::queue::{max_rows_label, Job};
use crate::store::{RunInfo, RunStore};
use axum::body::Body;
use axum::extract::{Path, State};
use axum::http::{Request, StatusCode};
use axum::middleware::{self, Next};
use axum::response::{IntoResponse, Json, Response};
use axum::routing::{get, post};
use axum::Router;
use serde::{Deserialize, Serialize};
use std::sync::Arc;
use tokio::sync::mpsc;
use tracing::warn;

pub struct AppState {
    pub config: Config,
    pub metrics: Arc<BenchMetrics>,
    pub tx: mpsc::Sender<Job>,
    pub runs: Arc<RunStore>,
}

pub fn router(state: Arc<AppState>) -> Router {
    let authed = Router::new()
        .route("/api/v1/benchmark", post(create_benchmark))
        .route("/api/v1/benchmark/{run_id}", get(get_benchmark))
        .route("/api/v1/benchmark/{run_id}/started", post(receive_started))
        .route("/api/v1/benchmark/{run_id}/results", post(receive_results))
        .route("/api/v1/benchmark/{run_id}/failure", post(receive_failure))
        .route_layer(middleware::from_fn_with_state(
            state.clone(),
            auth_middleware,
        ));

    let public = Router::new().route("/api/v1/health", get(health));

    Router::new().merge(authed).merge(public).with_state(state)
}

// -- Handlers --

async fn health() -> &'static str {
    "ok"
}

#[derive(Deserialize)]
struct BenchmarkRequest {
    sha: String,
    max_rows: Option<u32>,
}

#[derive(Serialize)]
struct BenchmarkResponse {
    run_id: String,
    status: String,
}

#[derive(Serialize)]
struct ErrorResponse {
    error: String,
}

type ApiResult<T> = Result<Json<T>, (StatusCode, Json<ErrorResponse>)>;

fn api_err(status: StatusCode, msg: impl Into<String>) -> (StatusCode, Json<ErrorResponse>) {
    (status, Json(ErrorResponse { error: msg.into() }))
}

fn is_valid_sha(sha: &str) -> bool {
    sha.len() == 40 && sha.chars().all(|c| c.is_ascii_hexdigit())
}

async fn create_benchmark(
    State(state): State<Arc<AppState>>,
    Json(req): Json<BenchmarkRequest>,
) -> ApiResult<BenchmarkResponse> {
    if !is_valid_sha(&req.sha) {
        return Err(api_err(
            StatusCode::BAD_REQUEST,
            "sha must be a 40-character hex string",
        ));
    }

    let (run_id, job) = make_job(req.sha.clone(), req.max_rows);

    let info = RunInfo {
        run_id: run_id.clone(),
        sha: req.sha,
        status: "queued".to_string(),
        max_rows: max_rows_label(req.max_rows),
        error: None,
        started_at_ts: None,
    };
    state
        .runs
        .insert(&info)
        .await
        .map_err(|e| api_err(StatusCode::INTERNAL_SERVER_ERROR, format!("redis: {}", e)))?;

    state.tx.send(job).await.map_err(|_| {
        warn!("job queue full or closed");
        api_err(StatusCode::SERVICE_UNAVAILABLE, "job queue unavailable")
    })?;

    Ok(Json(BenchmarkResponse {
        run_id,
        status: "queued".to_string(),
    }))
}

async fn get_benchmark(
    State(state): State<Arc<AppState>>,
    Path(run_id): Path<String>,
) -> Result<Json<RunInfo>, (StatusCode, Json<ErrorResponse>)> {
    match state.runs.get(&run_id).await {
        Ok(Some(info)) => Ok(Json(info)),
        Ok(None) => Err(api_err(StatusCode::NOT_FOUND, "run not found")),
        Err(e) => {
            tracing::error!(run_id = %run_id, error = %e, "redis error on GET");
            Err(api_err(
                StatusCode::INTERNAL_SERVER_ERROR,
                format!("redis error: {}", e),
            ))
        }
    }
}

// -- Started Callback (called when sim job begins running) --

async fn receive_started(
    State(state): State<Arc<AppState>>,
    Path(run_id): Path<String>,
) -> Result<StatusCode, (StatusCode, Json<ErrorResponse>)> {
    let info = state
        .runs
        .get(&run_id)
        .await
        .ok()
        .flatten()
        .ok_or_else(|| api_err(StatusCode::NOT_FOUND, "unknown run_id"))?;

    tracing::info!(run_id = %run_id, sha = %info.sha, "benchmark started");

    state
        .runs
        .update_started(&run_id)
        .await
        .map_err(|e| api_err(StatusCode::INTERNAL_SERVER_ERROR, format!("redis: {}", e)))?;
    state
        .metrics
        .set_status(&info.sha, &run_id, &info.max_rows, RunStatus::Running)
        .await;

    Ok(StatusCode::OK)
}

// -- Results Callback (called by k8s sim jobs) --

async fn receive_results(
    State(state): State<Arc<AppState>>,
    Path(run_id): Path<String>,
    body: axum::body::Bytes,
) -> Result<StatusCode, (StatusCode, Json<ErrorResponse>)> {
    let info = state
        .runs
        .get(&run_id)
        .await
        .ok()
        .flatten()
        .ok_or_else(|| api_err(StatusCode::NOT_FOUND, "unknown run_id"))?;

    let json =
        std::str::from_utf8(&body).map_err(|_| api_err(StatusCode::BAD_REQUEST, "invalid utf8"))?;

    let results = metrics::parse_results(json)
        .map_err(|e| api_err(StatusCode::BAD_REQUEST, format!("invalid results: {}", e)))?;

    tracing::info!(
        run_id = %run_id,
        sha = %info.sha,
        total_txs = results.summary.total_txs,
        max_rows = %info.max_rows,
        "received benchmark results"
    );

    state
        .metrics
        .record_results(&info.sha, &run_id, &info.max_rows, &results)
        .await;
    state
        .metrics
        .set_status(&info.sha, &run_id, &info.max_rows, RunStatus::Success)
        .await;

    if let Some(elapsed) = RunStore::elapsed_secs(&info) {
        state
            .metrics
            .set_duration(&info.sha, &run_id, &info.max_rows, elapsed)
            .await;
    }

    state
        .runs
        .update_success(&run_id)
        .await
        .map_err(|e| api_err(StatusCode::INTERNAL_SERVER_ERROR, format!("redis: {}", e)))?;

    Ok(StatusCode::OK)
}

// -- Failure Callback (called by k8s sim jobs on error) --

#[derive(Deserialize)]
struct FailureReport {
    error: String,
    logs: Option<String>,
}

async fn receive_failure(
    State(state): State<Arc<AppState>>,
    Path(run_id): Path<String>,
    Json(report): Json<FailureReport>,
) -> Result<StatusCode, (StatusCode, Json<ErrorResponse>)> {
    let info = state
        .runs
        .get(&run_id)
        .await
        .ok()
        .flatten()
        .ok_or_else(|| api_err(StatusCode::NOT_FOUND, "unknown run_id"))?;

    tracing::error!(run_id = %run_id, sha = %info.sha, error = %report.error, "benchmark failed");

    if let Some(ref logs) = report.logs {
        tracing::error!(run_id = %run_id, "sim logs:\n{}", logs);
    }

    state
        .metrics
        .set_status(&info.sha, &run_id, &info.max_rows, RunStatus::Failed)
        .await;

    state
        .runs
        .update_failed(&run_id, report.error)
        .await
        .map_err(|e| api_err(StatusCode::INTERNAL_SERVER_ERROR, format!("redis: {}", e)))?;

    Ok(StatusCode::OK)
}

// -- Helpers --

fn make_job(sha: String, max_rows: Option<u32>) -> (String, Job) {
    let short_sha = &sha[..8];
    let id = uuid::Uuid::new_v4().simple().to_string();
    let run_id = format!("{}-{}", short_sha, &id[..12]);
    let job = Job {
        run_id: run_id.clone(),
        sha,
        max_rows,
    };
    (run_id, job)
}

// -- Auth Middleware --

async fn auth_middleware(
    State(state): State<Arc<AppState>>,
    request: Request<Body>,
    next: Next,
) -> Response {
    let auth_header = request
        .headers()
        .get("authorization")
        .and_then(|v| v.to_str().ok());

    let Some(header) = auth_header else {
        return StatusCode::UNAUTHORIZED.into_response();
    };
    let Some(token) = header.strip_prefix("Bearer ") else {
        return StatusCode::UNAUTHORIZED.into_response();
    };
    if !state.config.validate_token(token) {
        return StatusCode::UNAUTHORIZED.into_response();
    }

    next.run(request).await
}
