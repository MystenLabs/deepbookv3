// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

//! Nautilus-compatible server for the DeepBook maker incentive scoring engine.
//!
//! In production this binary runs inside an AWS Nitro Enclave and signs
//! results with an ephemeral Ed25519 key attested by the enclave's PCR
//! measurements. For local development, use the default (non-`nautilus`)
//! build which generates a random keypair without NSM attestation.

use std::sync::Arc;
use std::time::{SystemTime, UNIX_EPOCH};

use anyhow::Result;
use axum::extract::State;
use axum::routing::{get, post};
use axum::{Json, Router};
use clap::Parser;
use fastcrypto::ed25519::Ed25519KeyPair;
use fastcrypto::encoding::{Encoding, Hex};
use fastcrypto::traits::{KeyPair, Signer, ToFromBytes};
use serde::{Deserialize, Serialize};
use tower_http::cors::{Any, CorsLayer};
use tracing::info;

use deepbook_incentives::data_validation::{
    indexer_validation_for_epoch, validate_indexer_readiness, validate_pool_data,
};
use deepbook_incentives::pool_info::fetch_pool_metadata_from_node;
use deepbook_incentives::ServerDataValidationConfig;
use deepbook_incentives::scoring::{compute_scores, loyalty_candidate_balance_managers};
use deepbook_incentives::types::{
    hex_to_address, EpochResults, IncentiveRequest, IncentiveResponse, IntentMessage,
    MakerRewardEntry, PoolDataResponse, ScoringConfig, INCENTIVE_EPOCH_DURATION_MS,
    INCENTIVE_WINDOW_DURATION_MS,
};
use deepbook_incentives::{
    compute_fund_loyalty_streak, fund_streak_to_loyalty_map, AppState, IncentiveError,
};

const INCENTIVE_INTENT: u8 = 1;
const SCORE_SCALE: f64 = 1_000_000_000.0;

// ---------------------------------------------------------------------------
// CLI
// ---------------------------------------------------------------------------
#[derive(Parser, Debug)]
#[command(name = "deepbook-incentives")]
struct Args {
    /// URL of the deepbook-server that serves order/fill data.
    #[arg(long, env = "DEEPBOOK_SERVER_URL")]
    server_url: String,

    /// Port to bind the incentive server to.
    #[arg(long, env = "PORT", default_value = "3000")]
    port: u16,

    /// Passed to `GET /status` — max checkpoint lag for a healthy indexer (sui-indexer-alt watermarks).
    #[arg(long, env = "DEEPBOOK_STATUS_MAX_CHECKPOINT_LAG", default_value = "100")]
    max_checkpoint_lag: i64,

    /// Passed to `GET /status` — max indexed-vs-wall-clock lag in seconds.
    #[arg(long, env = "DEEPBOOK_STATUS_MAX_TIME_LAG_SECONDS", default_value = "60")]
    max_time_lag_seconds: i64,

    /// Comma-separated pipeline names that must appear in `/status` and pass lag + watermark checks.
    /// Example: `deepbook_indexer`. When non-empty, indexed_timestamp_ms must cover each epoch end.
    #[arg(long, env = "DEEPBOOK_INCENTIVE_REQUIRED_PIPELINES", value_delimiter = ',', default_value = "")]
    required_pipelines: Vec<String>,

    /// Override min indexed_timestamp_ms (ms). When unset and `required_pipelines` is non-empty,
    /// each `/process_data` call uses the request's `epoch_end_ms` as the minimum watermark time.
    #[arg(long, env = "DEEPBOOK_INCENTIVE_MIN_INDEXED_TIMESTAMP_MS")]
    min_indexed_timestamp_ms: Option<i64>,

    /// Skip `GET /status` before scoring (local testing only).
    #[arg(long, env = "DEEPBOOK_INCENTIVE_SKIP_INDEXER_CHECK", default_value = "false")]
    skip_indexer_check: bool,

    /// SUI full-node RPC URL for fetching pool metadata directly (bypasses
    /// indexer `pools` table). Example: `https://fullnode.mainnet.sui.io:443`.
    #[arg(long, env = "SUI_RPC_URL")]
    sui_rpc_url: Option<String>,
}

// ---------------------------------------------------------------------------
// Request / response wrappers
// ---------------------------------------------------------------------------
#[derive(Debug, Deserialize)]
struct ProcessDataRequest {
    payload: IncentiveRequest,
}

// Attestation response (Nautilus pattern)
#[derive(Debug, Serialize)]
struct AttestationResponse {
    pk: String,
}

#[derive(Debug, Serialize)]
struct HealthCheckResponse {
    pk: String,
    status: String,
}

// ---------------------------------------------------------------------------
// Handlers
// ---------------------------------------------------------------------------

async fn health_check(
    State(state): State<Arc<AppState>>,
) -> Result<Json<HealthCheckResponse>, IncentiveError> {
    let pk = Hex::encode(state.eph_kp.public().as_bytes());
    Ok(Json(HealthCheckResponse {
        pk,
        status: "healthy".into(),
    }))
}

async fn get_attestation(
    State(state): State<Arc<AppState>>,
) -> Result<Json<AttestationResponse>, IncentiveError> {
    #[cfg(feature = "nautilus")]
    {
        use nsm_api::api::{Request as NsmRequest, Response as NsmResponse};
        use nsm_api::driver;
        use serde_bytes::ByteBuf;

        let pk = state.eph_kp.public();
        let fd = driver::nsm_init();
        let request = NsmRequest::Attestation {
            user_data: None,
            nonce: None,
            public_key: Some(ByteBuf::from(pk.as_bytes().to_vec())),
        };
        let response = driver::nsm_process_request(fd, request);
        driver::nsm_exit(fd);

        match response {
            NsmResponse::Attestation { document } => Ok(Json(AttestationResponse {
                pk: Hex::encode(document),
            })),
            _ => Err(IncentiveError::Internal(
                "unexpected NSM response".into(),
            )),
        }
    }

    #[cfg(not(feature = "nautilus"))]
    {
        let pk = Hex::encode(state.eph_kp.public().as_bytes());
        Ok(Json(AttestationResponse { pk }))
    }
}

async fn process_data(
    State(state): State<Arc<AppState>>,
    Json(request): Json<ProcessDataRequest>,
) -> Result<Json<IncentiveResponse>, IncentiveError> {
    let req = &request.payload;
    info!(
        pool_id = %req.pool_id,
        epoch_start = req.epoch_start_ms,
        epoch_end = req.epoch_end_ms,
        "processing incentive epoch"
    );

    if req.quality_p < 1 {
        return Err(IncentiveError::BadRequest(
            "quality_p must be >= 1".into(),
        ));
    }

    let span = req.epoch_end_ms.saturating_sub(req.epoch_start_ms);
    if span != INCENTIVE_EPOCH_DURATION_MS {
        return Err(IncentiveError::BadRequest(format!(
            "incentive epoch must span exactly {} ms (24h); got {} ms",
            INCENTIVE_EPOCH_DURATION_MS, span
        )));
    }

    let client = reqwest::Client::new();

    if !state.skip_indexer_check {
        let val_cfg = indexer_validation_for_epoch(&state.indexer_validation, req.epoch_end_ms);
        validate_indexer_readiness(&client, &state.server_url, &val_cfg)
            .await
            .map_err(|e| IncentiveError::Internal(e.to_string()))?;
    }

    // 1. Fetch raw data from the deepbook-server.
    let url = format!(
        "{}/incentives/pool_data/{}?start_ms={}&end_ms={}",
        state.server_url, req.pool_id, req.epoch_start_ms, req.epoch_end_ms,
    );

    let mut pool_data: PoolDataResponse = client
        .get(&url)
        .send()
        .await
        .map_err(|e| IncentiveError::Internal(format!("failed to fetch pool data: {e}")))?
        .json()
        .await
        .map_err(|e| IncentiveError::Internal(format!("failed to parse pool data: {e}")))?;

    validate_pool_data(
        &pool_data,
        &req.pool_id,
        req.epoch_start_ms as i64,
        req.epoch_end_ms as i64,
    )
    .map_err(|e| IncentiveError::Internal(e.to_string()))?;

    // If a SUI RPC URL is configured, fetch pool metadata directly from the
    // full node so we don't depend on the indexer's `pools` table.
    if let Some(ref rpc_url) = state.sui_rpc_url {
        if pool_data.pool_metadata.is_none() {
            match fetch_pool_metadata_from_node(&client, rpc_url, &req.pool_id).await {
                Ok(meta) => {
                    info!(
                        base = %meta.base_symbol, quote = %meta.quote_symbol,
                        "fetched pool metadata from SUI full node"
                    );
                    pool_data.pool_metadata = Some(meta);
                }
                Err(e) => {
                    info!("could not fetch pool metadata from full node: {e}");
                }
            }
        }
    }

    info!(
        orders = pool_data.order_events.len(),
        fills = pool_data.fill_events.len(),
        stakes = pool_data.stake_events.len(),
        stake_required = pool_data.stake_required,
        pool_pair = %pool_data.pool_metadata.as_ref()
            .map(|m| format!("{}/{}", m.base_symbol, m.quote_symbol))
            .unwrap_or_else(|| "unknown".into()),
        "fetched pool data"
    );

    // 1b. Loyalty streak from on-chain EpochResultsSubmitted events.
    //
    // Count consecutive prior epochs where the indexer has an on-chain
    // submission event for this fund. This is non-gameable because the
    // data comes from indexed Move events, not a writable DB table.
    let candidates = loyalty_candidate_balance_managers(
        &pool_data.order_events,
        &pool_data.stake_events,
        pool_data.stake_required,
    );

    let epoch_duration_ms = if req.epoch_duration_ms > 0 {
        req.epoch_duration_ms
    } else {
        INCENTIVE_EPOCH_DURATION_MS
    };

    let fund_streak = compute_fund_loyalty_streak(
        &client,
        &state.server_url,
        &req.fund_id,
        req.epoch_start_ms,
        epoch_duration_ms,
    )
    .await
    .map_err(|e| IncentiveError::Internal(e))?;

    let loyalty_prior = fund_streak_to_loyalty_map(&candidates, fund_streak);

    info!(
        fund_streak,
        num_candidates = candidates.len(),
        "loyalty streak computed from on-chain events"
    );

    // 2. Run scoring.
    let alpha = req.alpha_bps as f64 / 10_000.0;
    let config = ScoringConfig {
        pool_id: req.pool_id.clone(),
        epoch_start_ms: req.epoch_start_ms as i64,
        epoch_end_ms: req.epoch_end_ms as i64,
        window_duration_ms: INCENTIVE_WINDOW_DURATION_MS as i64,
        alpha,
        quality_p: req.quality_p,
    };

    let scores = compute_scores(
        &pool_data.order_events,
        &pool_data.fill_events,
        &config,
        &pool_data.stake_events,
        pool_data.stake_required,
        &loyalty_prior,
    );

    // 3. Convert to BCS-compatible types.
    let pool_addr = hex_to_address(&req.pool_id);
    let fund_addr = hex_to_address(&req.fund_id);
    let total_score: u64 = scores
        .iter()
        .map(|s| (s.score * SCORE_SCALE) as u64)
        .sum();

    let maker_rewards: Vec<MakerRewardEntry> = scores
        .iter()
        .map(|s| MakerRewardEntry {
            balance_manager_id: hex_to_address(&s.balance_manager_id),
            score: (s.score * SCORE_SCALE) as u64,
        })
        .collect();

    let results = EpochResults {
        pool_id: pool_addr,
        fund_id: fund_addr,
        epoch_start_ms: req.epoch_start_ms,
        epoch_end_ms: req.epoch_end_ms,
        total_score,
        maker_rewards,
        alpha_bps: req.alpha_bps,
        quality_p: req.quality_p,
    };

    // 4. Sign.
    let timestamp_ms = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap()
        .as_millis() as u64;

    let intent_msg = IntentMessage {
        intent: INCENTIVE_INTENT,
        timestamp_ms,
        payload: results.clone(),
    };
    let bcs_bytes =
        bcs::to_bytes(&intent_msg).map_err(|e| IncentiveError::Internal(e.to_string()))?;
    let sig = state.eph_kp.sign(&bcs_bytes);
    let sig_hex = Hex::encode(sig.as_ref());

    info!(
        num_makers = intent_msg.payload.maker_rewards.len(),
        total_score,
        "epoch scored and signed"
    );

    Ok(Json(IncentiveResponse {
        response: intent_msg,
        signature: sig_hex,
        pool_health: None,
    }))
}

/// Test endpoint that returns hardcoded dummy scores without fetching real data.
/// Useful for verifying the on-chain submission pipeline end-to-end.
async fn test_process_data(
    State(state): State<Arc<AppState>>,
    Json(request): Json<ProcessDataRequest>,
) -> Result<Json<IncentiveResponse>, IncentiveError> {
    let req = &request.payload;
    info!(
        pool_id = %req.pool_id,
        fund_id = %req.fund_id,
        "test_process_data: returning dummy scores"
    );

    let span = req.epoch_end_ms.saturating_sub(req.epoch_start_ms);
    if span != INCENTIVE_EPOCH_DURATION_MS {
        return Err(IncentiveError::BadRequest(format!(
            "incentive epoch must span exactly {} ms (24h); got {} ms",
            INCENTIVE_EPOCH_DURATION_MS, span
        )));
    }

    let pool_addr = hex_to_address(&req.pool_id);
    let fund_addr = hex_to_address(&req.fund_id);

    let maker_a = MakerRewardEntry {
        balance_manager_id: hex_to_address(
            "0x000000000000000000000000000000000000000000000000000000000000aaaa",
        ),
        score: 700_000_000,
    };
    let maker_b = MakerRewardEntry {
        balance_manager_id: hex_to_address(
            "0x000000000000000000000000000000000000000000000000000000000000bbbb",
        ),
        score: 300_000_000,
    };

    let results = EpochResults {
        pool_id: pool_addr,
        fund_id: fund_addr,
        epoch_start_ms: req.epoch_start_ms,
        epoch_end_ms: req.epoch_end_ms,
        total_score: 1_000_000_000,
        maker_rewards: vec![maker_a, maker_b],
        alpha_bps: req.alpha_bps,
        quality_p: req.quality_p.max(1),
    };

    let timestamp_ms = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap()
        .as_millis() as u64;

    let intent_msg = IntentMessage {
        intent: INCENTIVE_INTENT,
        timestamp_ms,
        payload: results,
    };
    let bcs_bytes =
        bcs::to_bytes(&intent_msg).map_err(|e| IncentiveError::Internal(e.to_string()))?;
    let sig = state.eph_kp.sign(&bcs_bytes);
    let sig_hex = Hex::encode(sig.as_ref());

    info!("test_process_data: signed dummy epoch");

    Ok(Json(IncentiveResponse {
        response: intent_msg,
        signature: sig_hex,
        pool_health: None,
    }))
}

// ---------------------------------------------------------------------------
// main
// ---------------------------------------------------------------------------
#[tokio::main]
async fn main() -> Result<()> {
    tracing_subscriber::fmt::init();

    let args = Args::parse();
    let eph_kp = Ed25519KeyPair::generate(&mut rand::thread_rng());

    info!(
        pk = %Hex::encode(eph_kp.public().as_bytes()),
        "incentive enclave started"
    );

    let required_pipelines: Vec<String> = args
        .required_pipelines
        .into_iter()
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty())
        .collect();

    let indexer_validation = ServerDataValidationConfig {
        max_checkpoint_lag: args.max_checkpoint_lag,
        max_time_lag_seconds: args.max_time_lag_seconds,
        required_pipelines,
        min_indexed_timestamp_ms: args.min_indexed_timestamp_ms,
    };

    let state = Arc::new(AppState {
        eph_kp,
        server_url: args.server_url,
        indexer_validation,
        skip_indexer_check: args.skip_indexer_check,
        sui_rpc_url: args.sui_rpc_url,
    });

    let cors = CorsLayer::new()
        .allow_methods(Any)
        .allow_headers(Any)
        .allow_origin(Any);

    let app = Router::new()
        .route("/health_check", get(health_check))
        .route("/get_attestation", get(get_attestation))
        .route("/process_data", post(process_data))
        .route("/test_process_data", post(test_process_data))
        .with_state(state)
        .layer(cors);

    let addr = format!("0.0.0.0:{}", args.port);
    let listener = tokio::net::TcpListener::bind(&addr).await?;
    info!("listening on {}", listener.local_addr()?);
    axum::serve(listener, app.into_make_service())
        .await
        .map_err(|e| anyhow::anyhow!("server error: {e}"))
}
