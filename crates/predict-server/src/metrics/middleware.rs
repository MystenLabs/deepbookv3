use std::sync::Arc;

use crate::server::AppState;
use axum::{
    body::Body,
    extract::{MatchedPath, State},
    http::Request,
    middleware::Next,
    response::IntoResponse,
};

pub(crate) async fn track_metrics(
    State(app): State<Arc<AppState>>,
    req: Request<Body>,
    next: Next,
) -> impl IntoResponse {
    let axum_route = req
        .extensions()
        .get::<MatchedPath>()
        .map(|p| p.as_str())
        .unwrap_or("/UNSUPPORTED")
        .to_string();

    let route_labels = [axum_route.as_str()];

    let _guard = app
        .metrics()
        .request_latency
        .with_label_values(&route_labels)
        .start_timer();

    app.metrics()
        .requests_received
        .with_label_values(&route_labels)
        .inc();

    let response = next.run(req).await;
    let status = response.status();

    if status.is_success() {
        app.metrics()
            .requests_succeeded
            .with_label_values(&route_labels)
            .inc();
    } else {
        app.metrics()
            .requests_failed
            .with_label_values(&[axum_route.as_str(), status.as_str()])
            .inc();
    }

    response
}
