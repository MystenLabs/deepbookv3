// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

use axum::{
    routing::{get, post},
    Router,
};
use std::sync::Arc;

use super::handlers;
use crate::server::AppState;

pub fn slush_routes() -> Router<Arc<AppState>> {
    Router::new()
        .route("/version", get(handlers::version))
        .route("/provider", get(handlers::provider))
        .route("/strategies", get(handlers::list_strategies))
        .route("/strategies/{strategy_id}", get(handlers::get_strategy))
        .route("/positions", get(handlers::list_positions))
        .route("/positions/{position_id}", get(handlers::get_position))
        .route("/deposit", post(handlers::deposit))
        .route("/withdraw", post(handlers::withdraw))
        .route("/withdraw/cancel", post(handlers::withdraw_cancel))
}
