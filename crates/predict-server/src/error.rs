// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

use axum::http::StatusCode;
use axum::response::{IntoResponse, Response};

#[derive(Debug, thiserror::Error)]
pub enum PredictError {
    #[error("Resource not found: {resource}")]
    NotFound { resource: String },

    #[error("Database error: {0}")]
    Database(String),

    #[error("Invalid request: {0}")]
    BadRequest(String),

    #[error("RPC error: {0}")]
    Rpc(String),

    #[error("Deserialization error: {0}")]
    Deserialization(String),

    #[error("Internal error: {0}")]
    Internal(String),

    #[error("Unauthorized")]
    Unauthorized,
}

impl PredictError {
    pub fn not_found(resource: impl Into<String>) -> Self {
        Self::NotFound {
            resource: resource.into(),
        }
    }

    pub fn database(msg: impl Into<String>) -> Self {
        Self::Database(msg.into())
    }

    pub fn bad_request(msg: impl Into<String>) -> Self {
        Self::BadRequest(msg.into())
    }

    pub fn rpc(msg: impl Into<String>) -> Self {
        Self::Rpc(msg.into())
    }

    pub fn deserialization(msg: impl Into<String>) -> Self {
        Self::Deserialization(msg.into())
    }

    pub fn internal(msg: impl Into<String>) -> Self {
        Self::Internal(msg.into())
    }
}

impl IntoResponse for PredictError {
    fn into_response(self) -> Response {
        let (status, message) = match &self {
            PredictError::NotFound { .. } => (StatusCode::NOT_FOUND, self.to_string()),
            PredictError::BadRequest(_) => (StatusCode::BAD_REQUEST, self.to_string()),
            PredictError::Unauthorized => (StatusCode::UNAUTHORIZED, self.to_string()),
            PredictError::Database(_)
            | PredictError::Rpc(_)
            | PredictError::Deserialization(_)
            | PredictError::Internal(_) => (StatusCode::INTERNAL_SERVER_ERROR, self.to_string()),
        };

        (status, message).into_response()
    }
}

impl From<diesel::result::Error> for PredictError {
    fn from(err: diesel::result::Error) -> Self {
        Self::Database(err.to_string())
    }
}

impl From<anyhow::Error> for PredictError {
    fn from(err: anyhow::Error) -> Self {
        Self::Internal(err.to_string())
    }
}

impl From<sui_sdk::error::Error> for PredictError {
    fn from(err: sui_sdk::error::Error) -> Self {
        Self::Rpc(err.to_string())
    }
}

impl From<sui_types::base_types::ObjectIDParseError> for PredictError {
    fn from(err: sui_types::base_types::ObjectIDParseError) -> Self {
        Self::BadRequest(err.to_string())
    }
}
