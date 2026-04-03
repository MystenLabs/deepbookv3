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

use deepbook_incentives::scoring::compute_scores;
use deepbook_incentives::types::*;
use deepbook_incentives::{AppState, IncentiveError};

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

    // 1. Fetch raw data from the deepbook-server.
    let url = format!(
        "{}/incentives/pool_data/{}?start_ms={}&end_ms={}",
        state.server_url, req.pool_id, req.epoch_start_ms, req.epoch_end_ms,
    );

    let client = reqwest::Client::new();
    let pool_data: PoolDataResponse = client
        .get(&url)
        .send()
        .await
        .map_err(|e| IncentiveError::Internal(format!("failed to fetch pool data: {e}")))?
        .json()
        .await
        .map_err(|e| IncentiveError::Internal(format!("failed to parse pool data: {e}")))?;

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

    // 2. Run scoring.
    let config = ScoringConfig {
        pool_id: req.pool_id.clone(),
        epoch_start_ms: req.epoch_start_ms as i64,
        epoch_end_ms: req.epoch_end_ms as i64,
        window_duration_ms: req.window_duration_ms as i64,
        alpha: req.alpha,
    };

    let scores = compute_scores(
        &pool_data.order_events,
        &pool_data.fill_events,
        &config,
        &pool_data.stake_events,
        pool_data.stake_required,
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

    let state = Arc::new(AppState {
        eph_kp,
        server_url: args.server_url,
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
