use anyhow::Context;
use clap::Parser;
use deepbook_predict_server::reader::Reader;
use deepbook_predict_server::server::{predict_routes, AppState};
use std::net::SocketAddr;
use std::sync::Arc;
use sui_pg_db::{Db, DbArgs};
use tower_http::cors::CorsLayer;

#[derive(Parser)]
#[clap(rename_all = "kebab-case", author, version)]
struct Args {
    #[command(flatten)]
    db_args: DbArgs,

    #[arg(long, default_value = "127.0.0.1:8080")]
    listen_address: SocketAddr,
}

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    let args = Args::parse();

    // Initialize telemetry
    let _guard = telemetry_subscribers::TelemetryConfig::new()
        .with_env()
        .init();

    // Initialize DB
    let db = Db::new_for_all_queries(args.db_args, None).await?;

    // Initialize State
    let state = Arc::new(AppState {
        reader: Reader::new(db),
    });

    // Initialize Router
    let app = Router::new()
        .nest("/api/v1", predict_routes(state))
        .layer(CorsLayer::permissive());

    // Start Server
    tracing::info!("Listening on {}", args.listen_address);
    let listener = tokio::net::TcpListener::bind(args.listen_address).await?;
    axum::serve(listener, app).await.context("Server failed")?;

    Ok(())
}

use axum::Router;
