use anyhow::Context;
use clap::Parser;
use predict_indexer::handlers::liquidated_order_redeemed_handler::LiquidatedOrderRedeemedHandler;
use predict_indexer::handlers::live_order_redeemed_handler::LiveOrderRedeemedHandler;
use predict_indexer::handlers::order_liquidated_handler::OrderLiquidatedHandler;
use predict_indexer::handlers::order_minted_handler::OrderMintedHandler;
use predict_indexer::handlers::settled_order_redeemed_handler::SettledOrderRedeemedHandler;
use predict_indexer::PredictEnv;
use predict_schema::MIGRATIONS;
use prometheus::Registry;
use std::net::SocketAddr;
use sui_indexer_alt_framework::ingestion::ingestion_client::IngestionClientArgs;
use sui_indexer_alt_framework::ingestion::streaming_client::StreamingClientArgs;
use sui_indexer_alt_framework::ingestion::{ClientArgs, IngestionConfig};
use sui_indexer_alt_framework::{Indexer, IndexerArgs};
use sui_indexer_alt_metrics::db::DbConnectionStatsCollector;
use sui_indexer_alt_metrics::{MetricsArgs, MetricsService};
use sui_pg_db::{Db, DbArgs};
use url::Url;

#[derive(Debug, Clone, clap::ValueEnum)]
pub enum Package {
    /// Index Predict order events (mints, redeems, liquidations).
    PredictOrders,
}

#[derive(Parser)]
#[clap(rename_all = "kebab-case", author, version)]
struct Args {
    #[command(flatten)]
    db_args: DbArgs,
    #[command(flatten)]
    indexer_args: IndexerArgs,
    #[command(flatten)]
    streaming_args: StreamingClientArgs,
    #[clap(env, long, default_value = "0.0.0.0:9184")]
    metrics_address: SocketAddr,
    #[clap(
        env,
        long,
        default_value = "postgres://postgres:postgrespw@localhost:5432/predict"
    )]
    database_url: Url,
    /// Predict environment.
    #[clap(env, long)]
    env: PredictEnv,
    /// Packages to index events for (can specify multiple).
    #[clap(long, value_enum, default_values = ["predict-orders"])]
    packages: Vec<Package>,
}

#[tokio::main]
async fn main() -> Result<(), anyhow::Error> {
    let _guard = telemetry_subscribers::TelemetryConfig::new()
        .with_env()
        .init();

    let Args {
        db_args,
        indexer_args,
        streaming_args,
        metrics_address,
        database_url,
        env,
        packages,
    } = Args::parse();

    let ingestion_args = IngestionClientArgs {
        remote_store_url: Some(env.remote_store_url()),
        ..Default::default()
    };

    let registry = Registry::new_custom(Some("predict".into()), None)
        .context("Failed to create Prometheus registry.")?;
    let metrics = MetricsService::new(MetricsArgs { metrics_address }, registry.clone());

    // Prepare the store for the indexer
    let store = Db::for_write(database_url, db_args)
        .await
        .context("Failed to connect to database")?;

    store
        .run_migrations(Some(&MIGRATIONS))
        .await
        .context("Failed to run pending migrations")?;

    registry.register(Box::new(DbConnectionStatsCollector::new(
        Some("predict_indexer_db"),
        store.clone(),
    )))?;

    let mut indexer = Indexer::new(
        store,
        indexer_args,
        ClientArgs {
            ingestion: ingestion_args,
            streaming: streaming_args,
        },
        IngestionConfig::default(),
        None,
        metrics.registry(),
    )
    .await?;

    // Register handlers based on selected packages
    for package in &packages {
        match package {
            Package::PredictOrders => {
                indexer
                    .concurrent_pipeline(OrderMintedHandler::new(env), Default::default())
                    .await?;
                indexer
                    .concurrent_pipeline(LiveOrderRedeemedHandler::new(env), Default::default())
                    .await?;
                indexer
                    .concurrent_pipeline(SettledOrderRedeemedHandler::new(env), Default::default())
                    .await?;
                indexer
                    .concurrent_pipeline(
                        LiquidatedOrderRedeemedHandler::new(env),
                        Default::default(),
                    )
                    .await?;
                indexer
                    .concurrent_pipeline(OrderLiquidatedHandler::new(env), Default::default())
                    .await?;
            }
        }
    }

    let s_indexer = indexer.run().await?;
    let s_metrics = metrics.run().await?;
    let service = s_indexer.attach(s_metrics);

    service.main().await?;
    Ok(())
}
