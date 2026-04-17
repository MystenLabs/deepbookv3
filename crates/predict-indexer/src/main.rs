use anyhow::Context;
use clap::Parser;
use predict_indexer::handlers::{
    OracleActivatedHandler, OracleAskBoundsClearedHandler, OracleAskBoundsSetHandler,
    OracleCreatedHandler, OraclePricesUpdatedHandler, OracleSettledHandler,
    OracleSviUpdatedHandler, PositionMintedHandler, PositionRedeemedHandler, PredictCreatedHandler,
    PredictManagerCreatedHandler, PricingConfigUpdatedHandler, QuoteAssetDisabledHandler,
    QuoteAssetEnabledHandler, RangeMintedHandler, RangeRedeemedHandler, RiskConfigUpdatedHandler,
    SuppliedHandler, TradingPauseUpdatedHandler, WithdrawnHandler,
};
use predict_indexer::{PredictConfig, TESTNET_REMOTE_STORE_URL};
use predict_schema::MIGRATIONS;
use prometheus::Registry;
use std::net::SocketAddr;
use std::sync::Arc;
use sui_indexer_alt_framework::ingestion::ingestion_client::IngestionClientArgs;
use sui_indexer_alt_framework::ingestion::streaming_client::StreamingClientArgs;
use sui_indexer_alt_framework::ingestion::{ClientArgs, IngestionConfig};
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
    #[clap(env, long, default_value = "0.0.0.0:9185")]
    metrics_address: SocketAddr,
    #[clap(env, long, default_value = "postgres://localhost:5432/predict_v2")]
    database_url: Url,
    /// Override predict package ID (for new deployments)
    #[clap(env, long)]
    predict_package_id: Option<String>,
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
        predict_package_id,
    } = Args::parse();

    // Build config from CLI override or default testnet packages
    let config = match predict_package_id {
        Some(pkg) => Arc::new(PredictConfig::new([pkg])),
        None => PredictConfig::testnet(),
    };

    let ingestion_args = IngestionClientArgs {
        remote_store_url: Some(
            Url::parse(TESTNET_REMOTE_STORE_URL).expect("invalid testnet remote store URL"),
        ),
        ..Default::default()
    };

    let registry = Registry::new_custom(Some("predict".into()), None)
        .context("Failed to create Prometheus registry.")?;
    let metrics = MetricsService::new(MetricsArgs { metrics_address }, registry.clone());

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

    // Oracle handlers
    indexer
        .concurrent_pipeline(
            OracleActivatedHandler::new(config.clone()),
            Default::default(),
        )
        .await?;
    indexer
        .concurrent_pipeline(
            OracleSettledHandler::new(config.clone()),
            Default::default(),
        )
        .await?;
    indexer
        .concurrent_pipeline(
            OraclePricesUpdatedHandler::new(config.clone()),
            Default::default(),
        )
        .await?;
    indexer
        .concurrent_pipeline(
            OracleSviUpdatedHandler::new(config.clone()),
            Default::default(),
        )
        .await?;

    // Registry handlers
    indexer
        .concurrent_pipeline(
            PredictCreatedHandler::new(config.clone()),
            Default::default(),
        )
        .await?;
    indexer
        .concurrent_pipeline(
            OracleCreatedHandler::new(config.clone()),
            Default::default(),
        )
        .await?;

    // Trading handlers
    indexer
        .concurrent_pipeline(
            PositionMintedHandler::new(config.clone()),
            Default::default(),
        )
        .await?;
    indexer
        .concurrent_pipeline(
            PositionRedeemedHandler::new(config.clone()),
            Default::default(),
        )
        .await?;
    indexer
        .concurrent_pipeline(RangeMintedHandler::new(config.clone()), Default::default())
        .await?;
    indexer
        .concurrent_pipeline(
            RangeRedeemedHandler::new(config.clone()),
            Default::default(),
        )
        .await?;

    // Admin handlers
    indexer
        .concurrent_pipeline(
            TradingPauseUpdatedHandler::new(config.clone()),
            Default::default(),
        )
        .await?;
    indexer
        .concurrent_pipeline(
            PricingConfigUpdatedHandler::new(config.clone()),
            Default::default(),
        )
        .await?;
    indexer
        .concurrent_pipeline(
            RiskConfigUpdatedHandler::new(config.clone()),
            Default::default(),
        )
        .await?;
    indexer
        .concurrent_pipeline(
            OracleAskBoundsSetHandler::new(config.clone()),
            Default::default(),
        )
        .await?;
    indexer
        .concurrent_pipeline(
            OracleAskBoundsClearedHandler::new(config.clone()),
            Default::default(),
        )
        .await?;
    indexer
        .concurrent_pipeline(
            QuoteAssetEnabledHandler::new(config.clone()),
            Default::default(),
        )
        .await?;
    indexer
        .concurrent_pipeline(
            QuoteAssetDisabledHandler::new(config.clone()),
            Default::default(),
        )
        .await?;

    // LP vault handlers
    indexer
        .concurrent_pipeline(SuppliedHandler::new(config.clone()), Default::default())
        .await?;
    indexer
        .concurrent_pipeline(WithdrawnHandler::new(config.clone()), Default::default())
        .await?;

    // User handlers
    indexer
        .concurrent_pipeline(
            PredictManagerCreatedHandler::new(config),
            Default::default(),
        )
        .await?;

    let s_indexer = indexer.run().await?;
    let s_metrics = metrics.run().await?;

    s_indexer.attach(s_metrics).main().await?;
    Ok(())
}
