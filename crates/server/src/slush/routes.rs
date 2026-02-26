// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

use std::sync::Arc;

use axum::{
    routing::{get, post},
    Router,
};

use super::handlers;
use crate::server::AppState;

/// Build the Slush DeFi Quickstart Provider API router.
/// Routes are relative to the `/slush` prefix (registered in server.rs).
pub fn slush_routes() -> Router<Arc<AppState>> {
    Router::new()
        // Metadata
        .route("/v1/version", get(handlers::get_version))
        .route("/v1/provider", get(handlers::get_provider))
        // Strategies
        .route("/v1/strategies", get(handlers::list_strategies))
        .route("/v1/strategies/{strategyId}", get(handlers::get_strategy))
        // Positions
        .route("/v1/positions", get(handlers::list_positions))
        .route("/v1/positions/{positionId}", get(handlers::get_position))
        // Transactions
        .route("/v1/deposit", post(handlers::create_deposit))
        .route("/v1/withdraw", post(handlers::create_withdraw))
        .route("/v1/withdraw/cancel", post(handlers::cancel_withdraw))
}
