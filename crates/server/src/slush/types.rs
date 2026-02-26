// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

use serde::{Deserialize, Serialize};

// ── Response wrappers ──

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct VersionResponse {
    pub version: String,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ProviderMetadataResponse {
    pub provider: ProviderMetadata,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ListStrategiesResponse {
    pub strategies: Vec<Strategy>,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct GetStrategyResponse {
    pub strategy: Strategy,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ListPositionsResponse {
    pub positions: Vec<Position>,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct GetPositionResponse {
    pub position: Position,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct DepositResponse {
    pub bytes: String,
    pub net_deposit: CoinValue,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub fees: Option<Vec<CoinValue>>,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct WithdrawResponse {
    pub bytes: String,
    pub principal: CoinValue,
    pub rewards: Vec<CoinValue>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub fees: Option<Vec<CoinValue>>,
}

// ── Domain types ──

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ProviderMetadata {
    pub name: String,
    pub description: String,
    pub tvl_usd: f64,
    pub launch_year: u32,
    pub app_url: String,
    pub icon_url: String,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Strategy {
    pub id: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub url: Option<String>,
    #[serde(rename = "type")]
    pub type_field: String,
    pub strategy_type: String,
    pub coin_type: String,
    pub min_deposit: Vec<CoinValue>,
    pub apy: ApyInfo,
    pub depositors_count: i64,
    pub tvl_usd: f64,
    pub volume_24h_usd: f64,
    pub fees: FeesInfo,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ApyInfo {
    pub current: f64,
    pub avg_24h: f64,
    pub avg_7d: f64,
    pub avg_30d: f64,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct FeesInfo {
    pub deposit_bps: String,
    pub withdraw_bps: String,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct CoinValue {
    pub coin_type: String,
    #[serde(rename = "amount")]
    pub amount: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub value_usd: Option<f64>,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Position {
    pub id: String,
    pub strategy_id: String,
    #[serde(rename = "type")]
    pub type_field: String,
    pub principal: CoinValue,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub balance: Option<CoinValue>,
    pub pending_rewards: Vec<CoinValue>,
    pub url: String,
}

// ── Error types ──

#[derive(Debug, Serialize)]
pub struct NotImplementedError {
    pub _tag: String,
}

#[derive(Debug, Serialize)]
pub struct TransactionBuildError {
    pub _tag: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub message: Option<String>,
}

// ── Request types ──

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct DepositRequest {
    #[serde(rename = "type")]
    pub type_field: String,
    pub strategy_id: String,
    pub sender_address: String,
    pub coin_type: String,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct WithdrawRequest {
    #[serde(rename = "type")]
    pub type_field: String,
    pub position_id: String,
    pub sender_address: String,
    pub principal: CoinValueInput,
    pub mode: String,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CoinValueInput {
    pub coin_type: String,
    pub amount: String,
    #[serde(default)]
    pub value_usd: Option<f64>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct WithdrawCancelRequest {
    #[serde(rename = "type")]
    pub type_field: String,
    pub position_id: String,
    pub withdrawal_id: String,
    pub sender_address: String,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PositionsQuery {
    pub address: String,
}
