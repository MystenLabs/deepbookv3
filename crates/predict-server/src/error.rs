use thiserror::Error;
use axum::{
    http::StatusCode,
    response::{IntoResponse, Response},
    Json,
};
use serde_json::json;

#[derive(Error, Debug)]
pub enum PredictError {
    #[error("Internal server error: {0}")]
    Internal(String),
    #[error("Not found: {0}")]
    NotFound(String),
}

impl IntoResponse for PredictError {
    fn into_response(self) -> Response {
        let (status, error_message) = match self {
            PredictError::Internal(msg) => (StatusCode::INTERNAL_SERVER_ERROR, msg),
            PredictError::NotFound(msg) => (StatusCode::NOT_FOUND, msg),
        };

        let body = Json(json!({
            "error": error_message,
        }));

        (status, body).into_response()
    }
}
