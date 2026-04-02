// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

use crate::config::Config;
use crate::metrics::{self, BenchMetrics, RunStatus};
use crate::queue::{Job, RunInfo, RunStore};
use axum::body::Body;
use axum::extract::{Path, State};
use axum::http::{Request, StatusCode};
use axum::middleware::{self, Next};
use axum::response::{IntoResponse, Json, Response};
use axum::routing::{get, post};
use axum::Router;
use serde::{Deserialize, Serialize};
use std::sync::Arc;
use std::time::{SystemTime, UNIX_EPOCH};
use tokio::sync::mpsc;
use tracing::warn;

pub struct AppState {
    pub config: Config,
    pub metrics: Arc<BenchMetrics>,
    pub tx: mpsc::Sender<Job>,
    pub runs: RunStore,
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

async fn create_benchmark(
    State(state): State<Arc<AppState>>,
    Json(req): Json<BenchmarkRequest>,
) -> ApiResult<BenchmarkResponse> {
    let (run_id, job) = make_job(req.sha);
    register_run(&state.runs, &run_id, &job.sha).await;

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
) -> Result<Json<RunInfo>, StatusCode> {
    let runs = state.runs.read().await;
    runs.get(&run_id)
        .cloned()
        .map(Json)
        .ok_or(StatusCode::NOT_FOUND)
}

// -- Started Callback (called when sim job begins running) --

async fn receive_started(
    State(state): State<Arc<AppState>>,
    Path(run_id): Path<String>,
) -> Result<StatusCode, (StatusCode, Json<ErrorResponse>)> {
    let sha = {
        let mut runs = state.runs.write().await;
        let info = runs
            .get_mut(&run_id)
            .ok_or_else(|| api_err(StatusCode::NOT_FOUND, "unknown run_id"))?;
        info.status = "running".to_string();
        info.started_at = Some(std::time::Instant::now());
        info.sha.clone()
    };

    tracing::info!(run_id = %run_id, sha = %sha, "benchmark started");
    state.metrics.set_status(&sha, RunStatus::Running).await;

    Ok(StatusCode::OK)
}

// -- Results Callback (called by k8s sim jobs) --

async fn receive_results(
    State(state): State<Arc<AppState>>,
    Path(run_id): Path<String>,
    body: axum::body::Bytes,
) -> Result<StatusCode, (StatusCode, Json<ErrorResponse>)> {
    let (sha, started_at) = {
        let runs = state.runs.read().await;
        let info = runs
            .get(&run_id)
            .ok_or_else(|| api_err(StatusCode::NOT_FOUND, "unknown run_id"))?;
        (info.sha.clone(), info.started_at)
    };

    let json =
        std::str::from_utf8(&body).map_err(|_| api_err(StatusCode::BAD_REQUEST, "invalid utf8"))?;

    let results = metrics::parse_results(json)
        .map_err(|e| api_err(StatusCode::BAD_REQUEST, format!("invalid results: {}", e)))?;

    tracing::info!(run_id = %run_id, sha = %sha, total_txs = results.summary.total_txs, "received benchmark results");

    state.metrics.record_results(&sha, &results).await;
    state.metrics.set_status(&sha, RunStatus::Success).await;

    if let Some(start) = started_at {
        state
            .metrics
            .set_duration(&sha, start.elapsed().as_secs_f64())
            .await;
    }

    {
        let mut runs = state.runs.write().await;
        if let Some(info) = runs.get_mut(&run_id) {
            info.status = "success".to_string();
        }
    }

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
    let sha = {
        let runs = state.runs.read().await;
        let info = runs
            .get(&run_id)
            .ok_or_else(|| api_err(StatusCode::NOT_FOUND, "unknown run_id"))?;
        info.sha.clone()
    };

    tracing::error!(run_id = %run_id, sha = %sha, error = %report.error, "benchmark failed");

    if let Some(ref logs) = report.logs {
        tracing::error!(run_id = %run_id, "sim logs:\n{}", logs);
    }

    state.metrics.set_status(&sha, RunStatus::Failed).await;

    {
        let mut runs = state.runs.write().await;
        if let Some(info) = runs.get_mut(&run_id) {
            info.status = "failed".to_string();
            info.error = Some(report.error);
        }
    }

    Ok(StatusCode::OK)
}

// -- Helpers --

fn make_job(sha: String) -> (String, Job) {
    let timestamp = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap()
        .as_secs();
    let short_sha = &sha[..8.min(sha.len())];
    let run_id = format!("{}-{}", short_sha, timestamp);
    let job = Job {
        run_id: run_id.clone(),
        sha,
    };
    (run_id, job)
}

async fn register_run(runs: &RunStore, run_id: &str, sha: &str) {
    let mut store = runs.write().await;
    store.insert(
        run_id.to_string(),
        RunInfo {
            run_id: run_id.to_string(),
            sha: sha.to_string(),
            status: "queued".to_string(),
            error: None,
            started_at: None,
        },
    );
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
