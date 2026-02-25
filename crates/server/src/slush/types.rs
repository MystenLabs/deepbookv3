// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

//! Request and response types for the Slush DeFi Quickstart Provider API v1.1.0.
//! See: https://apps-backend.sui.io/slush/defi-quick-start/openapi.json

use serde::{Deserialize, Serialize};

// === Metadata ===

#[derive(Serialize)]
pub struct OpenApiVersionResponse {
    pub version: String,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ProviderMetadataResponse {
    pub provider: ProviderMetadata,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ProviderMetadata {
    pub name: String,
    pub description: String,
    pub tvl_usd: f64,
    pub launch_year: i32,
    pub app_url: String,
    pub icon_url: String,
}

// === Strategies ===

#[derive(Serialize)]
pub struct ListStrategiesResponse {
    pub strategies: Vec<Strategy>,
}

#[derive(Serialize, Clone)]
#[serde(rename_all = "camelCase")]
pub struct Strategy {
    pub id: String,
    #[serde(rename = "type")]
    pub type_tag: String,
    pub strategy_type: String,
    pub coin_type: String,
    pub min_deposit: Vec<CoinValue>,
    pub apy: ApyInfo,
    pub depositors_count: i64,
    pub tvl_usd: f64,
    pub volume24h_usd: f64,
    pub fees: FeesInfo,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub url: Option<String>,
}

#[derive(Serialize, Clone)]
#[serde(rename_all = "camelCase")]
pub struct CoinValue {
    pub coin_type: String,
    pub amount: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub value_usd: Option<f64>,
}

#[derive(Serialize, Clone)]
#[serde(rename_all = "camelCase")]
pub struct ApyInfo {
    pub current: f64,
    pub avg24h: f64,
    pub avg7d: f64,
    pub avg30d: f64,
}

#[derive(Serialize, Clone)]
#[serde(rename_all = "camelCase")]
pub struct FeesInfo {
    pub deposit_bps: String,
    pub withdraw_bps: String,
}

#[derive(Serialize)]
pub struct GetStrategyResponse {
    pub strategy: Strategy,
}

// === Positions ===

#[derive(Serialize)]
pub struct ListPositionsResponse {
    pub positions: Vec<Position>,
}

#[derive(Serialize, Clone)]
#[serde(rename_all = "camelCase")]
pub struct Position {
    pub id: String,
    pub strategy_id: String,
    #[serde(rename = "type")]
    pub type_tag: String,
    pub principal: CoinValue,
    pub pending_rewards: Vec<CoinValue>,
    pub url: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub balance: Option<CoinValue>,
}

#[derive(Serialize)]
pub struct GetPositionResponse {
    pub position: Position,
}

// === Positions query ===

#[derive(Deserialize)]
pub struct PositionsQuery {
    pub address: String,
}

// === Transactions ===

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct DepositRequest {
    #[serde(rename = "type")]
    pub type_tag: String,
    pub strategy_id: String,
    pub sender_address: String,
    pub coin_type: String,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct DepositResponse {
    pub bytes: String,
    pub net_deposit: CoinValue,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub fees: Option<Vec<CoinValue>>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct WithdrawRequest {
    #[serde(rename = "type")]
    pub type_tag: String,
    pub position_id: String,
    pub sender_address: String,
    pub principal: WithdrawPrincipal,
    pub mode: String,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct WithdrawPrincipal {
    pub coin_type: String,
    pub amount: String,
    #[serde(default)]
    pub value_usd: Option<f64>,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct WithdrawResponse {
    pub bytes: String,
    pub principal: CoinValue,
    pub rewards: Vec<CoinValue>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub fees: Option<Vec<CoinValue>>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct WithdrawCancelRequest {
    #[serde(rename = "type")]
    pub type_tag: String,
    pub position_id: String,
    pub withdrawal_id: String,
    pub sender_address: String,
}

#[derive(Serialize)]
pub struct WithdrawCancelResponse {
    pub bytes: String,
}

// === Error types ===

#[derive(Serialize)]
pub struct NotImplementedError {
    pub _tag: String,
}

#[derive(Serialize)]
pub struct TransactionBuildError {
    pub _tag: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub message: Option<String>,
}
