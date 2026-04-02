// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

mod api;
mod config;
mod metrics;
mod queue;
mod runner;
mod store;

use crate::api::AppState;
use crate::config::Config;
use crate::metrics::BenchMetrics;
use crate::queue::spawn_worker;
use crate::store::RunStore;
use axum::routing::get;
use axum::Router;
use clap::Parser;
use prometheus::{Registry, TextEncoder};
use std::sync::Arc;
use tokio::net::TcpListener;
use tokio::sync::mpsc;
use tracing::info;

const METRICS_PORT: u16 = 9184;

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    tracing_subscriber::fmt::init();

    let config = Config::parse();
    let registry = Registry::new();
    let metrics = BenchMetrics::new(&registry);
    let runs = RunStore::new(&config.redis_url).await?;
    let (tx, rx) = mpsc::channel(64);

    spawn_worker(rx, config.clone(), metrics.clone(), runs.clone());

    let state = Arc::new(AppState {
        config: config.clone(),
        metrics: metrics.clone(),
        tx,
        runs,
    });

    let app = api::router(state);

    let metrics_registry = Arc::new(registry);
    let metrics_app = Router::new().route(
        "/metrics",
        get(move || {
            let reg = metrics_registry.clone();
            async move {
                let encoder = TextEncoder::new();
                encoder.encode_to_string(&reg.gather()).unwrap_or_default()
            }
        }),
    );

    let api_addr = format!("0.0.0.0:{}", config.api_port);
    let metrics_addr = format!("0.0.0.0:{}", METRICS_PORT);

    info!("API server on {}", api_addr);
    info!("Metrics on {}", metrics_addr);

    let api_listener = TcpListener::bind(&api_addr).await?;
    let metrics_listener = TcpListener::bind(&metrics_addr).await?;

    tokio::select! {
        r = axum::serve(api_listener, app) => r?,
        r = axum::serve(metrics_listener, metrics_app) => r?,
    }

    Ok(())
}
