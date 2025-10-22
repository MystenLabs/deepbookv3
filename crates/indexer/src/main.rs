use anyhow::Context;
use clap::Parser;
use deepbook_indexer::handlers::balances_handler::BalancesHandler;
use deepbook_indexer::handlers::deep_burned_handler::DeepBurnedHandler;
use deepbook_indexer::handlers::flash_loan_handler::FlashLoanHandler;
use deepbook_indexer::handlers::order_fill_handler::OrderFillHandler;
use deepbook_indexer::handlers::order_update_handler::OrderUpdateHandler;
use deepbook_indexer::handlers::pool_price_handler::PoolPriceHandler;
use deepbook_indexer::handlers::proposals_handler::ProposalsHandler;
use deepbook_indexer::handlers::rebates_handler::RebatesHandler;
use deepbook_indexer::handlers::stakes_handler::StakesHandler;
use deepbook_indexer::handlers::trade_params_update_handler::TradeParamsUpdateHandler;
use deepbook_indexer::handlers::vote_handler::VotesHandler;

// Margin Manager Events
use deepbook_indexer::handlers::liquidation_handler::LiquidationHandler;
use deepbook_indexer::handlers::loan_borrowed_handler::LoanBorrowedHandler;
use deepbook_indexer::handlers::loan_repaid_handler::LoanRepaidHandler;
use deepbook_indexer::handlers::margin_manager_created_handler::MarginManagerCreatedHandler;

// Margin Pool Operations Events
use deepbook_indexer::handlers::asset_supplied_handler::AssetSuppliedHandler;
use deepbook_indexer::handlers::asset_withdrawn_handler::AssetWithdrawnHandler;

// Margin Pool Admin Events
use deepbook_indexer::handlers::deepbook_pool_updated_handler::DeepbookPoolUpdatedHandler;
use deepbook_indexer::handlers::interest_params_updated_handler::InterestParamsUpdatedHandler;
use deepbook_indexer::handlers::margin_pool_config_updated_handler::MarginPoolConfigUpdatedHandler;
use deepbook_indexer::handlers::margin_pool_created_handler::MarginPoolCreatedHandler;

// Margin Registry Events
use deepbook_indexer::handlers::deepbook_pool_config_updated_handler::DeepbookPoolConfigUpdatedHandler;
use deepbook_indexer::handlers::deepbook_pool_registered_handler::DeepbookPoolRegisteredHandler;
use deepbook_indexer::handlers::deepbook_pool_updated_registry_handler::DeepbookPoolUpdatedRegistryHandler;
use deepbook_indexer::handlers::maintainer_cap_updated_handler::MaintainerCapUpdatedHandler;
use deepbook_indexer::DeepbookEnv;
use deepbook_schema::MIGRATIONS;
use prometheus::Registry;
use std::net::SocketAddr;
use sui_indexer_alt_framework::ingestion::ClientArgs;
use sui_indexer_alt_framework::{Indexer, IndexerArgs};
use sui_indexer_alt_metrics::db::DbConnectionStatsCollector;
use sui_indexer_alt_metrics::{MetricsArgs, MetricsService};
use sui_pg_db::{Db, DbArgs};
use tokio_util::sync::CancellationToken;
use url::Url;

#[derive(Debug, Clone, clap::ValueEnum)]
pub enum Package {
    /// Index DeepBook core events (order fills, updates, pools, etc.)
    Deepbook,
    /// Index DeepBook margin events (lending, borrowing, liquidations, etc.)
    DeepbookMargin,
}

#[derive(Parser)]
#[clap(rename_all = "kebab-case", author, version)]
struct Args {
    #[command(flatten)]
    db_args: DbArgs,
    #[command(flatten)]
    indexer_args: IndexerArgs,
    #[clap(env, long, default_value = "0.0.0.0:9184")]
    metrics_address: SocketAddr,
    #[clap(
        env,
        long,
        default_value = "postgres://postgres:postgrespw@localhost:5432/deepbook"
    )]
    database_url: Url,
    /// Deepbook environment, defaulted to SUI mainnet.
    #[clap(env, long)]
    env: DeepbookEnv,
    /// Packages to index events for (can specify multiple)
    #[clap(long, value_enum, default_values = ["deepbook"])]
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
        metrics_address,
        database_url,
        env,
        packages,
    } = Args::parse();

    let cancel = CancellationToken::new();
    let registry = Registry::new_custom(Some("deepbook".into()), None)
        .context("Failed to create Prometheus registry.")?;
    let metrics = MetricsService::new(
        MetricsArgs { metrics_address },
        registry.clone(),
        cancel.child_token(),
    );

    // Prepare the store for the indexer
    let store = Db::for_write(database_url, db_args)
        .await
        .context("Failed to connect to database")?;

    store
        .run_migrations(Some(&MIGRATIONS))
        .await
        .context("Failed to run pending migrations")?;

    registry.register(Box::new(DbConnectionStatsCollector::new(
        Some("deepbook_indexer_db"),
        store.clone(),
    )))?;

    let mut indexer = Indexer::new(
        store,
        indexer_args,
        ClientArgs {
            remote_store_url: Some(env.remote_store_url()),
            local_ingestion_path: None,
            rpc_api_url: None,
            rpc_username: None,
            rpc_password: None,
        },
        Default::default(),
        None,
        metrics.registry(),
        cancel.clone(),
    )
    .await?;

    // Register handlers based on selected packages
    for package in &packages {
        match package {
            Package::Deepbook => {
                // DeepBook core event handlers
                indexer
                    .concurrent_pipeline(BalancesHandler::new(env), Default::default())
                    .await?;
                indexer
                    .concurrent_pipeline(DeepBurnedHandler::new(env), Default::default())
                    .await?;
                indexer
                    .concurrent_pipeline(FlashLoanHandler::new(env), Default::default())
                    .await?;
                indexer
                    .concurrent_pipeline(OrderFillHandler::new(env), Default::default())
                    .await?;
                indexer
                    .concurrent_pipeline(OrderUpdateHandler::new(env), Default::default())
                    .await?;
                indexer
                    .concurrent_pipeline(PoolPriceHandler::new(env), Default::default())
                    .await?;
                indexer
                    .concurrent_pipeline(ProposalsHandler::new(env), Default::default())
                    .await?;
                indexer
                    .concurrent_pipeline(RebatesHandler::new(env), Default::default())
                    .await?;
                indexer
                    .concurrent_pipeline(StakesHandler::new(env), Default::default())
                    .await?;
                indexer
                    .concurrent_pipeline(TradeParamsUpdateHandler::new(env), Default::default())
                    .await?;
                indexer
                    .concurrent_pipeline(VotesHandler::new(env), Default::default())
                    .await?;
            }
            Package::DeepbookMargin => {
                // Margin Manager Events
                indexer
                    .concurrent_pipeline(MarginManagerCreatedHandler::new(env), Default::default())
                    .await?;
                indexer
                    .concurrent_pipeline(LoanBorrowedHandler::new(env), Default::default())
                    .await?;
                indexer
                    .concurrent_pipeline(LoanRepaidHandler::new(env), Default::default())
                    .await?;
                indexer
                    .concurrent_pipeline(LiquidationHandler::new(env), Default::default())
                    .await?;

                // Margin Pool Operations Events
                indexer
                    .concurrent_pipeline(AssetSuppliedHandler::new(env), Default::default())
                    .await?;
                indexer
                    .concurrent_pipeline(AssetWithdrawnHandler::new(env), Default::default())
                    .await?;

                // Margin Pool Admin Events
                indexer
                    .concurrent_pipeline(MarginPoolCreatedHandler::new(env), Default::default())
                    .await?;
                indexer
                    .concurrent_pipeline(DeepbookPoolUpdatedHandler::new(env), Default::default())
                    .await?;
                indexer
                    .concurrent_pipeline(InterestParamsUpdatedHandler::new(env), Default::default())
                    .await?;
                indexer
                    .concurrent_pipeline(
                        MarginPoolConfigUpdatedHandler::new(env),
                        Default::default(),
                    )
                    .await?;

                // Margin Registry Events
                indexer
                    .concurrent_pipeline(MaintainerCapUpdatedHandler::new(env), Default::default())
                    .await?;
                indexer
                    .concurrent_pipeline(
                        DeepbookPoolRegisteredHandler::new(env),
                        Default::default(),
                    )
                    .await?;
                indexer
                    .concurrent_pipeline(
                        DeepbookPoolUpdatedRegistryHandler::new(env),
                        Default::default(),
                    )
                    .await?;
                indexer
                    .concurrent_pipeline(
                        DeepbookPoolConfigUpdatedHandler::new(env),
                        Default::default(),
                    )
                    .await?;
            }
        }
    }

    let h_indexer = indexer.run().await?;
    let h_metrics = metrics.run().await?;

    let _ = h_indexer.await;
    cancel.cancel();
    let _ = h_metrics.await;

    Ok(())
}
