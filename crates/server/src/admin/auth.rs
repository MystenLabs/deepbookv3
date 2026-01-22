// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

use std::sync::Arc;

use axum::{
    body::Body,
    extract::State,
    http::{header::AUTHORIZATION, Request, StatusCode},
    middleware::Next,
    response::Response,
};

use crate::server::AppState;

pub async fn require_admin_auth(
    State(state): State<Arc<AppState>>,
    req: Request<Body>,
    next: Next,
) -> Result<Response, StatusCode> {
    // Check rate limit before processing auth
    if !state.check_admin_rate_limit() {
        tracing::warn!("Admin auth rate limit exceeded");
        return Err(StatusCode::TOO_MANY_REQUESTS);
    }

    let auth_header = req
        .headers()
        .get(AUTHORIZATION)
        .and_then(|value| value.to_str().ok());

    match auth_header {
        Some(header) if header.starts_with("Bearer ") => {
            let token = header.trim_start_matches("Bearer ");
            if state.is_valid_admin_token(token) {
                Ok(next.run(req).await)
            } else {
                tracing::warn!("Invalid admin token provided");
                Err(StatusCode::UNAUTHORIZED)
            }
        }
        _ => {
            tracing::warn!("Missing or malformed admin authorization header");
            Err(StatusCode::UNAUTHORIZED)
        }
    }
}
