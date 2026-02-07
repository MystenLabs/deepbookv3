// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

use std::sync::Arc;

use axum::{
    middleware::from_fn_with_state,
    routing::{delete, get, post, put},
    Router,
};

use super::auth::require_admin_auth;
use super::handlers;
use crate::server::AppState;

pub fn admin_routes(state: Arc<AppState>) -> Router<Arc<AppState>> {
    // Authenticated routes
    let protected = Router::new()
        .route("/pools", post(handlers::create_pool))
        .route("/pools/{pool_id}", put(handlers::update_pool))
        .route("/pools/{pool_id}", delete(handlers::delete_pool))
        .route("/assets", post(handlers::create_asset))
        .route("/assets/{asset_type}", delete(handlers::delete_asset))
        .layer(from_fn_with_state(state, require_admin_auth));

    // Health check is unauthenticated for load balancer probes
    Router::new()
        .route("/health", get(handlers::admin_health))
        .merge(protected)
}
