use anyhow::Context;
use clap::Parser;
use oracle_indexer::handlers::block_scholes_observation_inserted_handler::BlockScholesObservationInsertedHandler;
use oracle_indexer::handlers::block_scholes_observation_recorded_handler::BlockScholesObservationRecordedHandler;
use oracle_indexer::handlers::oracle_bound_handler::OracleBoundHandler;
use oracle_indexer::handlers::oracle_source_registered_handler::OracleSourceRegisteredHandler;
use oracle_indexer::handlers::pyth_observation_inserted_handler::PythObservationInsertedHandler;
use oracle_indexer::handlers::pyth_observation_recorded_handler::PythObservationRecordedHandler;
use oracle_indexer::materialized_view_refresh::{
    materialized_view_refresh_service, MaterializedViewRefreshMetrics,
};
use oracle_indexer::OracleEnv;
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
    /// Index all Propbook oracle events (registry + oracle_lane domains).
    Oracle,
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
    #[clap(env, long, default_value = "0.0.0.0:9186")]
    metrics_address: SocketAddr,
    #[clap(
        env,
        long,
        default_value = "postgres://postgres:postgrespw@localhost:5432/predict"
    )]
    database_url: Url,
    /// Oracle environment.
    #[clap(env, long)]
    env: OracleEnv,
    /// Packages to index events for (can specify multiple).
    #[clap(long, value_enum, default_values = ["oracle"])]
    packages: Vec<Package>,
    /// Interval between materialized-view refreshes; 0 disables the refresh task.
    #[clap(env, long, default_value_t = 60)]
    mv_refresh_interval_secs: u64,
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
        mv_refresh_interval_secs,
    } = Args::parse();

    // Validate the package addresses eagerly so the fail-fast unset-address panic
    // (TODO(testnet-deploy)) fires at process boot rather than on the first
    // checkpoint ingestion.
    let _ = env.package_addresses();

    let ingestion_args = IngestionClientArgs {
        remote_store_url: Some(env.remote_store_url()),
        ..Default::default()
    };

    let registry = Registry::new_custom(Some("oracle".into()), None)
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
        Some("oracle_indexer_db"),
        store.clone(),
    )))?;

    let mv_store = store.clone();
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
            Package::Oracle => {
                // Pyth spot lane: live + exact-ms history into pyth_observation.
                indexer
                    .concurrent_pipeline(
                        PythObservationRecordedHandler::new(env),
                        Default::default(),
                    )
                    .await?;
                indexer
                    .concurrent_pipeline(
                        PythObservationInsertedHandler::new(env),
                        Default::default(),
                    )
                    .await?;

                // Block Scholes surface lane: live + exact-ms history into
                // block_scholes_observation.
                indexer
                    .concurrent_pipeline(
                        BlockScholesObservationRecordedHandler::new(env),
                        Default::default(),
                    )
                    .await?;
                indexer
                    .concurrent_pipeline(
                        BlockScholesObservationInsertedHandler::new(env),
                        Default::default(),
                    )
                    .await?;

                // Registry: source catalog + canonical bindings.
                indexer
                    .concurrent_pipeline(
                        OracleSourceRegisteredHandler::new(env),
                        Default::default(),
                    )
                    .await?;
                indexer
                    .concurrent_pipeline(OracleBoundHandler::new(env), Default::default())
                    .await?;
            }
        }
    }

    let mv_metrics = MaterializedViewRefreshMetrics::new(&registry);
    let s_mv_refresh =
        materialized_view_refresh_service(mv_store, mv_metrics, mv_refresh_interval_secs)?;

    let s_indexer = indexer.run().await?;
    let s_metrics = metrics.run().await?;
    let mut service = s_indexer.attach(s_metrics);
    if let Some(s_mv) = s_mv_refresh {
        service = service.attach(s_mv);
    }

    service.main().await?;
    Ok(())
}
