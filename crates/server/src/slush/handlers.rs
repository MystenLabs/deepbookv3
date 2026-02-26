// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

use axum::{
    extract::{Path, Query, State},
    http::StatusCode,
    response::{IntoResponse, Response},
    Json,
};
use serde_json::json;
use std::sync::Arc;
use sui_json_rpc_types::SuiObjectDataOptions;
use sui_types::base_types::ObjectID;

use crate::server::AppState;

use super::apy;
use super::ptb;
use super::types::*;

// ── Error type ──

#[derive(Debug)]
pub enum SlushApiError {
    NotFound(String),
    TransactionBuild(String),
    NotImplemented,
    Internal(String),
}

impl IntoResponse for SlushApiError {
    fn into_response(self) -> Response {
        match self {
            SlushApiError::NotFound(msg) => {
                let body = json!({ "_tag": "NotFoundError", "message": msg });
                (StatusCode::NOT_FOUND, Json(body)).into_response()
            }
            SlushApiError::TransactionBuild(msg) => {
                let body = json!({ "_tag": "TransactionBuildError", "message": msg });
                (StatusCode::UNPROCESSABLE_ENTITY, Json(body)).into_response()
            }
            SlushApiError::NotImplemented => {
                let body = json!({ "_tag": "NotImplementedError" });
                (StatusCode::NOT_IMPLEMENTED, Json(body)).into_response()
            }
            SlushApiError::Internal(msg) => {
                let body = json!({ "_tag": "InternalError", "message": msg });
                (StatusCode::INTERNAL_SERVER_ERROR, Json(body)).into_response()
            }
        }
    }
}

// ── Handlers ──

/// GET /version
pub async fn version() -> Json<VersionResponse> {
    Json(VersionResponse {
        version: "1.1.0".to_string(),
    })
}

/// GET /provider
pub async fn provider(
    State(state): State<Arc<AppState>>,
) -> Result<Json<ProviderMetadataResponse>, SlushApiError> {
    let snapshots = state
        .reader()
        .get_latest_margin_pool_snapshots()
        .await
        .map_err(|e| SlushApiError::Internal(format!("Failed to get snapshots: {}", e)))?;

    let pools = state
        .reader()
        .get_all_margin_pools()
        .await
        .map_err(|e| SlushApiError::Internal(format!("Failed to get pools: {}", e)))?;

    // Compute aggregate TVL from snapshots.
    // TODO: This is token quantity, not USD. Accurate only for stablecoins.
    // Integrate a price oracle for proper USD conversion.
    let total_tvl_usd: f64 = snapshots
        .iter()
        .map(|s| {
            let decimals = pools
                .iter()
                .find(|p| p.0 == s.margin_pool_id)
                .map(|p| p.2)
                .unwrap_or(9);
            s.total_supply as f64 / 10f64.powi(decimals as i32)
        })
        .sum();

    Ok(Json(ProviderMetadataResponse {
        provider: ProviderMetadata {
            name: "DeepBook".to_string(),
            description: "DeepBook is a decentralized order book on the Sui blockchain providing margin lending pools.".to_string(),
            tvl_usd: total_tvl_usd,
            launch_year: 2024,
            app_url: "https://deepbook.tech".to_string(),
            icon_url: "https://deepbook.tech/favicon.ico".to_string(),
        },
    }))
}

/// GET /strategies
pub async fn list_strategies(
    State(state): State<Arc<AppState>>,
) -> Result<Json<ListStrategiesResponse>, SlushApiError> {
    let strategies = build_strategies(&state).await?;
    Ok(Json(ListStrategiesResponse { strategies }))
}

/// GET /strategies/:strategy_id
pub async fn get_strategy(
    Path(strategy_id): Path<String>,
    State(state): State<Arc<AppState>>,
) -> Result<Json<GetStrategyResponse>, SlushApiError> {
    let strategies = build_strategies(&state).await?;
    let strategy = strategies
        .into_iter()
        .find(|s| s.id == strategy_id)
        .ok_or_else(|| SlushApiError::NotFound(format!("Strategy '{}' not found", strategy_id)))?;
    Ok(Json(GetStrategyResponse { strategy }))
}

/// GET /positions?address=...
pub async fn list_positions(
    Query(params): Query<PositionsQuery>,
    State(state): State<Arc<AppState>>,
) -> Result<Json<ListPositionsResponse>, SlushApiError> {
    let positions = build_positions(&state, &params.address).await?;
    Ok(Json(ListPositionsResponse { positions }))
}

/// GET /positions/:position_id
pub async fn get_position(
    Path(position_id): Path<String>,
    State(state): State<Arc<AppState>>,
) -> Result<Json<GetPositionResponse>, SlushApiError> {
    // Look up the supplier_cap events to find the sender address
    let cap_events = state
        .reader()
        .get_supplier_caps_by_cap_id(&position_id)
        .await
        .map_err(|e| SlushApiError::Internal(format!("Failed to query supplier cap: {}", e)))?;

    let cap = cap_events
        .first()
        .ok_or_else(|| SlushApiError::NotFound(format!("Position '{}' not found", position_id)))?;

    let positions = build_positions(&state, &cap.sender).await?;
    let position = positions
        .into_iter()
        .find(|p| p.id == position_id)
        .ok_or_else(|| SlushApiError::NotFound(format!("Position '{}' not found", position_id)))?;

    Ok(Json(GetPositionResponse { position }))
}

/// POST /deposit
pub async fn deposit(
    State(state): State<Arc<AppState>>,
    Json(req): Json<DepositRequest>,
) -> Result<Json<DepositResponse>, SlushApiError> {
    let config = state
        .slush_config()
        .ok_or_else(|| SlushApiError::Internal("Slush API not configured".to_string()))?;

    // Validate strategy exists
    let pools = state
        .reader()
        .get_all_margin_pools()
        .await
        .map_err(|e| SlushApiError::Internal(format!("Failed to get pools: {}", e)))?;

    let pool = pools
        .iter()
        .find(|p| p.0 == req.strategy_id)
        .ok_or_else(|| {
            SlushApiError::NotFound(format!("Strategy '{}' not found", req.strategy_id))
        })?;

    let asset_type = ptb::normalize_asset_type(&pool.1);

    // Get pool initial_shared_version via RPC
    let sui_client = state
        .sui_client()
        .await
        .map_err(|e| SlushApiError::Internal(format!("Failed to get Sui client: {}", e)))?;

    let pool_isv = get_shared_object_version(sui_client, &req.strategy_id)
        .await
        .map_err(|e| {
            SlushApiError::TransactionBuild(format!("Failed to get pool object version: {}", e))
        })?;

    let registry_isv = get_shared_object_version(sui_client, &config.margin_registry_id)
        .await
        .map_err(|e| {
            SlushApiError::TransactionBuild(format!("Failed to get registry object version: {}", e))
        })?;

    let bytes = ptb::build_deposit_ptb(
        &config.margin_package_id,
        &req.strategy_id,
        pool_isv,
        &config.margin_registry_id,
        registry_isv,
        &asset_type,
        &req.sender_address,
    )
    .map_err(|e| SlushApiError::TransactionBuild(format!("Failed to build deposit PTB: {}", e)))?;

    Ok(Json(DepositResponse {
        bytes,
        net_deposit: CoinValue {
            coin_type: asset_type,
            amount: "0".to_string(), // placeholder — Slush wallet fills the actual amount
            value_usd: None,
        },
        fees: None,
    }))
}

/// POST /withdraw
pub async fn withdraw(
    State(state): State<Arc<AppState>>,
    Json(req): Json<WithdrawRequest>,
) -> Result<Json<WithdrawResponse>, SlushApiError> {
    let config = state
        .slush_config()
        .ok_or_else(|| SlushApiError::Internal("Slush API not configured".to_string()))?;

    // Look up supplier_cap object ref via RPC
    let sui_client = state
        .sui_client()
        .await
        .map_err(|e| SlushApiError::Internal(format!("Failed to get Sui client: {}", e)))?;

    let cap_object_id = ObjectID::from_hex_literal(&req.position_id)
        .map_err(|e| SlushApiError::TransactionBuild(format!("Invalid position ID: {}", e)))?;

    let cap_response = sui_client
        .read_api()
        .get_object_with_options(cap_object_id, SuiObjectDataOptions::new())
        .await
        .map_err(|e| {
            SlushApiError::TransactionBuild(format!("Failed to get supplier cap object: {}", e))
        })?;

    let cap_data = cap_response.data.as_ref().ok_or_else(|| {
        SlushApiError::NotFound(format!(
            "SupplierCap '{}' not found on chain",
            req.position_id
        ))
    })?;

    let cap_ref = cap_data.object_ref();

    // Find the pool associated with this position
    let supply_events = state
        .reader()
        .get_supply_events_for_cap(&req.position_id)
        .await
        .map_err(|e| SlushApiError::Internal(format!("Failed to get supply events: {}", e)))?;

    let (margin_pool_id, asset_type) = supply_events
        .first()
        .map(|(pool_id, at, _, _)| (pool_id.clone(), at.clone()))
        .ok_or_else(|| {
            SlushApiError::NotFound(format!(
                "No supply events found for position '{}'",
                req.position_id
            ))
        })?;

    let normalized_asset = ptb::normalize_asset_type(&asset_type);

    let pool_isv = get_shared_object_version(sui_client, &margin_pool_id)
        .await
        .map_err(|e| {
            SlushApiError::TransactionBuild(format!("Failed to get pool object version: {}", e))
        })?;

    let registry_isv = get_shared_object_version(sui_client, &config.margin_registry_id)
        .await
        .map_err(|e| {
            SlushApiError::TransactionBuild(format!("Failed to get registry object version: {}", e))
        })?;

    // Parse the requested withdrawal amount.
    // An empty string means "withdraw all"; otherwise it must be a valid u64.
    let withdraw_amount: Option<u64> = if req.principal.amount.is_empty() {
        None
    } else {
        Some(req.principal.amount.parse::<u64>().map_err(|_| {
            SlushApiError::TransactionBuild(format!(
                "Invalid withdrawal amount '{}': must be a non-negative integer",
                req.principal.amount
            ))
        })?)
    };

    let bytes = ptb::build_withdraw_ptb(
        &config.margin_package_id,
        &margin_pool_id,
        pool_isv,
        &config.margin_registry_id,
        registry_isv,
        cap_ref,
        &normalized_asset,
        withdraw_amount,
        &req.sender_address,
    )
    .map_err(|e| SlushApiError::TransactionBuild(format!("Failed to build withdraw PTB: {}", e)))?;

    Ok(Json(WithdrawResponse {
        bytes,
        principal: CoinValue {
            coin_type: normalized_asset.clone(),
            amount: req.principal.amount,
            value_usd: None,
        },
        rewards: vec![],
        fees: None,
    }))
}

/// POST /withdraw/cancel
pub async fn withdraw_cancel(
    Json(_req): Json<WithdrawCancelRequest>,
) -> Result<Json<serde_json::Value>, SlushApiError> {
    // DeepBook margin withdrawals are instant — no hold period, no cancellation needed
    Err(SlushApiError::NotImplemented)
}

// ── Helper functions ──

/// Get the initial_shared_version for a shared object.
async fn get_shared_object_version(
    sui_client: &sui_sdk::SuiClient,
    object_id: &str,
) -> Result<u64, anyhow::Error> {
    let oid = ObjectID::from_hex_literal(object_id)?;
    let response = sui_client
        .read_api()
        .get_object_with_options(oid, SuiObjectDataOptions::new().with_owner())
        .await?;

    let data = response
        .data
        .as_ref()
        .ok_or_else(|| anyhow::anyhow!("Object {} not found", object_id))?;

    match &data.owner {
        Some(sui_types::object::Owner::Shared {
            initial_shared_version,
        }) => Ok(initial_shared_version.value()),
        _ => Err(anyhow::anyhow!(
            "Object {} is not a shared object",
            object_id
        )),
    }
}

/// Build all strategy objects from DB + APY data.
async fn build_strategies(state: &Arc<AppState>) -> Result<Vec<Strategy>, SlushApiError> {
    let pools = state
        .reader()
        .get_all_margin_pools()
        .await
        .map_err(|e| SlushApiError::Internal(format!("Failed to get margin pools: {}", e)))?;

    let snapshots = state
        .reader()
        .get_latest_margin_pool_snapshots()
        .await
        .map_err(|e| SlushApiError::Internal(format!("Failed to get snapshots: {}", e)))?;

    let config = state.slush_config();
    let http_client = state.http_client();
    let apy_cache = state.apy_cache();

    let mut strategies = Vec::new();

    for (pool_id, asset_type, decimals) in &pools {
        let normalized_asset = ptb::normalize_asset_type(asset_type);

        // Get TVL from latest snapshot.
        // TODO: This computes token quantity, not USD value. It is only correct
        // for stablecoins with a 1:1 USD peg. Integrate a price oracle to get
        // accurate USD values for non-stablecoin assets.
        let snapshot = snapshots.iter().find(|s| s.margin_pool_id == *pool_id);
        let tvl_raw = snapshot.map(|s| s.total_supply).unwrap_or(0);
        let tvl_usd = tvl_raw as f64 / 10f64.powi(*decimals as i32);

        // Get APY from Abyss if configured
        let current_apy = if let Some(cfg) = &config {
            if let Some(vault_addr) = cfg.vault_mapping.get(pool_id) {
                apy::get_apy(http_client, apy_cache, vault_addr)
                    .await
                    .unwrap_or(0.0)
            } else {
                0.0
            }
        } else {
            0.0
        };

        // Count active depositors
        let depositors_count = state
            .reader()
            .count_active_depositors(pool_id)
            .await
            .unwrap_or(0);

        strategies.push(Strategy {
            id: pool_id.clone(),
            url: Some(format!("https://deepbook.tech/margin/{}", pool_id)),
            type_field: "StrategyV1".to_string(),
            strategy_type: "LENDING".to_string(),
            coin_type: normalized_asset.clone(),
            min_deposit: vec![CoinValue {
                coin_type: normalized_asset,
                amount: "0".to_string(),
                value_usd: None,
            }],
            // TODO: avg_24h/7d/30d currently mirror current_apy. Persist
            // historical APY snapshots and compute rolling averages.
            apy: ApyInfo {
                current: current_apy,
                avg_24h: current_apy,
                avg_7d: current_apy,
                avg_30d: current_apy,
            },
            depositors_count,
            tvl_usd,
            volume_24h_usd: 0.0, // TODO: Compute from recent trade events
            fees: FeesInfo {
                deposit_bps: "0".to_string(),
                withdraw_bps: "0".to_string(),
            },
        });
    }

    Ok(strategies)
}

/// Build position objects for a given wallet address.
async fn build_positions(
    state: &Arc<AppState>,
    address: &str,
) -> Result<Vec<Position>, SlushApiError> {
    // Find all supplier_caps minted by this address
    let caps = state
        .reader()
        .get_supplier_caps_for_address(address)
        .await
        .map_err(|e| SlushApiError::Internal(format!("Failed to get supplier caps: {}", e)))?;

    let mut positions = Vec::new();

    for cap in &caps {
        let supplier_cap_id = &cap.supplier_cap_id;

        // Get supply/withdraw events for this supplier cap
        let events = state
            .reader()
            .get_supply_events_for_cap(supplier_cap_id)
            .await
            .map_err(|e| SlushApiError::Internal(format!("Failed to get events for cap: {}", e)))?;

        if events.is_empty() {
            continue;
        }

        // Compute net position from events
        let margin_pool_id = events[0].0.clone();
        let asset_type = ptb::normalize_asset_type(&events[0].1);

        let total_supplied: i64 = events
            .iter()
            .filter(|(_, _, is_supply, _)| *is_supply)
            .fold(0i64, |acc, (_, _, _, amount)| acc.saturating_add(*amount));
        let total_withdrawn: i64 = events
            .iter()
            .filter(|(_, _, is_supply, _)| !(*is_supply))
            .fold(0i64, |acc, (_, _, _, amount)| acc.saturating_add(*amount));

        let net_amount = total_supplied.saturating_sub(total_withdrawn).max(0);

        if net_amount == 0 {
            continue;
        }

        positions.push(Position {
            id: supplier_cap_id.clone(),
            strategy_id: margin_pool_id.clone(),
            type_field: "PositionV1".to_string(),
            principal: CoinValue {
                coin_type: asset_type.clone(),
                amount: net_amount.to_string(),
                value_usd: None,
            },
            balance: None,
            pending_rewards: vec![],
            url: format!(
                "https://deepbook.tech/margin/{}/{}",
                margin_pool_id, supplier_cap_id
            ),
        });
    }

    Ok(positions)
}
