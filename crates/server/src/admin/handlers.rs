// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

use std::sync::Arc;

use axum::{
    extract::{Path, State},
    Json,
};
use serde::{Deserialize, Serialize};

use crate::error::DeepBookError;
use crate::server::AppState;

#[derive(Debug, Deserialize)]
pub struct CreatePoolRequest {
    pub pool_id: String,
    pub pool_name: String,
    pub base_asset_id: String,
    pub base_asset_decimals: i16,
    pub base_asset_symbol: String,
    pub base_asset_name: String,
    pub quote_asset_id: String,
    pub quote_asset_decimals: i16,
    pub quote_asset_symbol: String,
    pub quote_asset_name: String,
    pub min_size: i64,
    pub lot_size: i64,
    pub tick_size: i64,
}

#[derive(Debug, Deserialize)]
pub struct UpdatePoolRequest {
    pub pool_name: Option<String>,
    pub min_size: Option<i64>,
    pub lot_size: Option<i64>,
    pub tick_size: Option<i64>,
}

#[derive(Debug, Deserialize)]
pub struct CreateAssetRequest {
    pub asset_type: String,
    pub name: String,
    pub symbol: String,
    pub decimals: i16,
    pub ucid: Option<i32>,
    pub package_id: Option<String>,
    pub package_address_url: Option<String>,
}

#[derive(Debug, Serialize)]
pub struct AdminResponse {
    pub status: String,
}

pub async fn admin_health() -> &'static str {
    "admin_ok"
}

pub async fn create_pool(
    State(state): State<Arc<AppState>>,
    Json(payload): Json<CreatePoolRequest>,
) -> Result<Json<AdminResponse>, DeepBookError> {
    tracing::info!(
        action = "create_pool",
        pool_id = %payload.pool_id,
        pool_name = %payload.pool_name,
        base_asset = %payload.base_asset_symbol,
        quote_asset = %payload.quote_asset_symbol,
        "Admin creating pool"
    );
    state.writer().create_pool(payload).await?;
    Ok(Json(AdminResponse {
        status: "created".to_string(),
    }))
}

pub async fn update_pool(
    State(state): State<Arc<AppState>>,
    Path(pool_id): Path<String>,
    Json(payload): Json<UpdatePoolRequest>,
) -> Result<Json<AdminResponse>, DeepBookError> {
    tracing::info!(
        action = "update_pool",
        pool_id = %pool_id,
        pool_name = ?payload.pool_name,
        min_size = ?payload.min_size,
        lot_size = ?payload.lot_size,
        tick_size = ?payload.tick_size,
        "Admin updating pool"
    );
    state.writer().update_pool(&pool_id, payload).await?;
    Ok(Json(AdminResponse {
        status: "updated".to_string(),
    }))
}

pub async fn delete_pool(
    State(state): State<Arc<AppState>>,
    Path(pool_id): Path<String>,
) -> Result<Json<AdminResponse>, DeepBookError> {
    tracing::info!(
        action = "delete_pool",
        pool_id = %pool_id,
        "Admin deleting pool"
    );
    state.writer().delete_pool(&pool_id).await?;
    Ok(Json(AdminResponse {
        status: "deleted".to_string(),
    }))
}

pub async fn create_asset(
    State(state): State<Arc<AppState>>,
    Json(payload): Json<CreateAssetRequest>,
) -> Result<Json<AdminResponse>, DeepBookError> {
    tracing::info!(
        action = "create_asset",
        asset_type = %payload.asset_type,
        symbol = %payload.symbol,
        name = %payload.name,
        decimals = %payload.decimals,
        "Admin creating asset"
    );
    state.writer().create_asset(payload).await?;
    Ok(Json(AdminResponse {
        status: "created".to_string(),
    }))
}

pub async fn delete_asset(
    State(state): State<Arc<AppState>>,
    Path(asset_type): Path<String>,
) -> Result<Json<AdminResponse>, DeepBookError> {
    tracing::info!(
        action = "delete_asset",
        asset_type = %asset_type,
        "Admin deleting asset"
    );
    state.writer().delete_asset(&asset_type).await?;
    Ok(Json(AdminResponse {
        status: "deleted".to_string(),
    }))
}
