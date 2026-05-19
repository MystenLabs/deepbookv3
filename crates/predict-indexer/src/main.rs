use anyhow::Context;
use clap::Parser;
use deepbook_predict_indexer::handlers::minted_handler::MintedHandler;
use deepbook_predict_indexer::handlers::redeemed_handler::RedeemedHandler;
use deepbook_predict_indexer::handlers::settled_handler::SettledHandler;
use deepbook_predict_indexer::handlers::supplied_handler::SuppliedHandler;
use deepbook_predict_indexer::handlers::withdrawn_handler::WithdrawnHandler;
use deepbook_predict_indexer::DeepbookEnv;
use deepbook_predict_schema::MIGRATIONS;
use prometheus::Registry;
use std::net::SocketAddr;
use std::path::PathBuf;
use sui_indexer_alt_framework::ingestion::streaming_client::StreamingClientArgs;
use sui_indexer_alt_framework::{Indexer, IndexerArgs};
use sui_indexer_alt_metrics::db::DbConnectionStatsCollector;
use sui_indexer_alt_metrics::{MetricsArgs, MetricsService};
use sui_pg_db::{Db, DbArgs};
use url::Url;

#[derive(Parser)]
#[clap(rename_all = "kebab-case", author, version)]
struct Args {
    #[command(flatten)]
    db_args: DbArgs,
    #[command(flatten)]
    indexer_args: IndexerArgs,
    #[command(flatten)]
    streaming_args: StreamingClientArgs,
    #[command(flatten)]
    metrics_args: MetricsArgs,

    #[arg(long, value_enum, default_value = "testnet")]
    env: DeepbookEnv,

    #[arg(long)]
    remote_store_url: Option<Url>,
}

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    let args = Args::parse();

    // Initialize telemetry
    let _guard = telemetry_subscribers::TelemetryConfig::new()
        .with_env()
        .init();

    let env = args.env;

    // Initialize DB
    let mut db_config = args.db_args;
    if db_config.migration_path.is_none() {
        db_config.migration_path = Some(PathBuf::from("crates/predict-schema/migrations"));
    }
    let db = Db::new_for_all_queries(db_config, Some(MIGRATIONS)).await?;

    // Initialize Metrics
    let registry = Registry::new();
    let metrics = MetricsService::new(
        args.metrics_args,
        registry.clone(),
        Some(Box::new(DbConnectionStatsCollector::new(db.clone()))),
    );

    // Initialize Indexer
    let mut indexer_config = args.indexer_args;
    if indexer_config.remote_store_url.is_none() {
        indexer_config.remote_store_url = Some(args.remote_store_url.unwrap_or(env.remote_store_url()));
    }

    let mut indexer = Indexer::new(db, indexer_config, args.streaming_args, registry).await?;

    // Register Handlers
    indexer
        .concurrent_pipeline(MintedHandler::new(env), Default::default())
        .await?;
    indexer
        .concurrent_pipeline(RedeemedHandler::new(env), Default::default())
        .await?;
    indexer
        .concurrent_pipeline(SettledHandler::new(env), Default::default())
        .await?;
    indexer
        .concurrent_pipeline(SuppliedHandler::new(env), Default::default())
        .await?;
    indexer
        .concurrent_pipeline(WithdrawnHandler::new(env), Default::default())
        .await?;

    let s_indexer = indexer.run().await?;
    let s_metrics = metrics.run().await?;

    s_indexer.attach(s_metrics).main().await?;
    Ok(())
}
