// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

use axum::{
    http::{
        header::{HeaderValue, RETRY_AFTER},
        StatusCode,
    },
    response::{IntoResponse, Response},
};

#[derive(Clone, Debug, thiserror::Error)]
pub(super) enum PythError {
    #[error("Pyth Pro is not configured")]
    NotConfigured,
    #[error("Pyth Pro request failed: {0}")]
    Transport(String),
    #[error("Pyth Pro returned HTTP {status}: {message}")]
    Upstream {
        status: StatusCode,
        message: String,
        retry_after: Option<String>,
    },
    #[error("invalid Pyth Pro response: {0}")]
    InvalidResponse(String),
}

impl PythError {
    pub(super) fn into_response(self) -> Response {
        let (status, message, retry_after) = match self {
            Self::NotConfigured => (
                StatusCode::SERVICE_UNAVAILABLE,
                "Pyth Pro is not configured".to_owned(),
                None,
            ),
            Self::Transport(message) | Self::InvalidResponse(message) => (
                StatusCode::BAD_GATEWAY,
                format!("Pyth Pro is unavailable: {message}"),
                None,
            ),
            Self::Upstream {
                status,
                message,
                retry_after,
            } => (status, message, retry_after),
        };
        response_with_retry_after(status, message, retry_after.as_deref())
    }
}

pub(super) fn response_with_retry_after(
    status: StatusCode,
    message: impl Into<String>,
    retry_after: Option<&str>,
) -> Response {
    let mut response = (status, message.into()).into_response();
    if let Some(retry_after) = retry_after {
        if let Ok(value) = HeaderValue::from_str(retry_after) {
            response.headers_mut().insert(RETRY_AFTER, value);
        }
    }
    response
}
