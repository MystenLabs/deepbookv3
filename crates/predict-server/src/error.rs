use axum::http::StatusCode;
use axum::response::{IntoResponse, Response};

#[derive(Debug, thiserror::Error)]
pub enum PredictError {
    #[error("Resource not found: {resource}")]
    NotFound { resource: String },

    #[error("Database error: {0}")]
    Database(String),

    #[error("Internal error: {0}")]
    Internal(String),
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

    pub fn internal(msg: impl Into<String>) -> Self {
        Self::Internal(msg.into())
    }
}

impl IntoResponse for PredictError {
    fn into_response(self) -> Response {
        let (status, message) = match &self {
            PredictError::NotFound { .. } => (StatusCode::NOT_FOUND, self.to_string()),
            PredictError::Database(_) | PredictError::Internal(_) => {
                (StatusCode::INTERNAL_SERVER_ERROR, self.to_string())
            }
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
