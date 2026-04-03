// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

//! DeepBook maker incentive scoring engine.
//!
//! This crate computes per-maker reward scores from on-chain order book events
//! and signs them inside a Nautilus secure enclave. The signed results are
//! verified on-chain by the `maker_incentives` Move contract.

pub mod scoring;
pub mod types;

use axum::http::StatusCode;
use axum::response::{IntoResponse, Response};
use axum::Json;
use fastcrypto::ed25519::Ed25519KeyPair;
use serde_json::json;

pub struct AppState {
    pub eph_kp: Ed25519KeyPair,
    pub server_url: String,
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
