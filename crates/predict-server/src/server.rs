use crate::error::PredictError;
use crate::metrics::encode_metrics;
use crate::reader::Reader;
use axum::{
    extract::{Path, Query, State},
    routing::get,
    Json, Router,
    response::IntoResponse,
};
use deepbook_predict_schema::models::*;
use serde::Deserialize;
use std::sync::Arc;

pub struct AppState {
    pub reader: Reader,
}

#[derive(Deserialize)]
pub struct TraderQuery {
    pub trader: Option<String>,
}

#[derive(Deserialize)]
pub struct OwnerQuery {
    pub owner: Option<String>,
}

pub fn predict_routes(state: Arc<AppState>) -> Router {
    Router::new()
        .route("/vaults", get(get_vaults))
        .route("/oracles", get(get_oracles))
        .route("/positions/:manager_id", get(get_user_positions))
        .route("/events/minted", get(get_mint_events))
        .route("/events/redeemed", get(get_redeem_events))
        .route("/metrics", get(metrics_handler))
        .with_state(state)
}

async fn metrics_handler() -> impl IntoResponse {
    (
        axum::http::StatusCode::OK,
        [(axum::http::header::CONTENT_TYPE, "text/plain; version=0.0.4")],
        encode_metrics(),
    )
}

async fn get_vaults(
    State(state): State<Arc<AppState>>,
) -> Result<Json<Vec<PredictVault>>, PredictError> {
    let vaults = state.reader.get_vaults().await?;
    Ok(Json(vaults))
}

async fn get_oracles(
    State(state): State<Arc<AppState>>,
) -> Result<Json<Vec<PredictOracle>>, PredictError> {
    let oracles = state.reader.get_oracles().await?;
    Ok(Json(oracles))
}

async fn get_user_positions(
    State(state): State<Arc<AppState>>,
    Path(manager_id): Path<String>,
) -> Result<Json<Vec<PredictUserPosition>>, PredictError> {
    let positions = state.reader.get_user_positions(manager_id).await?;
    Ok(Json(positions))
}

async fn get_mint_events(
    State(state): State<Arc<AppState>>,
    Query(query): Query<TraderQuery>,
) -> Result<Json<Vec<PredictEventMinted>>, PredictError> {
    let events = state.reader.get_mint_events(query.trader).await?;
    Ok(Json(events))
}

async fn get_redeem_events(
    State(state): State<Arc<AppState>>,
    Query(query): Query<OwnerQuery>,
) -> Result<Json<Vec<PredictEventRedeemed>>, PredictError> {
    let events = state.reader.get_redeem_events(query.owner).await?;
    Ok(Json(events))
}
