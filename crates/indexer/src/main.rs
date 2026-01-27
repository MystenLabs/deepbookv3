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
use deepbook_indexer::handlers::referral_fee_event_handler::ReferralFeeEventHandler;
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
use deepbook_indexer::handlers::maintainer_fees_withdrawn_handler::MaintainerFeesWithdrawnHandler;
use deepbook_indexer::handlers::protocol_fees_withdrawn_handler::ProtocolFeesWithdrawnHandler;
use deepbook_indexer::handlers::supplier_cap_minted_handler::SupplierCapMintedHandler;
use deepbook_indexer::handlers::supply_referral_minted_handler::SupplyReferralMintedHandler;

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
use deepbook_indexer::handlers::pause_cap_updated_handler::PauseCapUpdatedHandler;

// Protocol Fees Events
use deepbook_indexer::handlers::protocol_fees_increased_handler::ProtocolFeesIncreasedHandler;
use deepbook_indexer::handlers::referral_fees_claimed_handler::ReferralFeesClaimedHandler;

// Collateral Events
use deepbook_indexer::handlers::deposit_collateral_handler::DepositCollateralHandler;
use deepbook_indexer::handlers::withdraw_collateral_handler::WithdrawCollateralHandler;

// TPSL (Take Profit / Stop Loss) Events
use deepbook_indexer::handlers::conditional_order_added_handler::ConditionalOrderAddedHandler;
use deepbook_indexer::handlers::conditional_order_cancelled_handler::ConditionalOrderCancelledHandler;
use deepbook_indexer::handlers::conditional_order_executed_handler::ConditionalOrderExecutedHandler;
use deepbook_indexer::handlers::conditional_order_insufficient_funds_handler::ConditionalOrderInsufficientFundsHandler;

use deepbook_indexer::{
    CheckpointStorage, CheckpointStorageConfig, CheckpointStorageType, DeepbookEnv,
    SuiCheckpointStorage, WalrusCheckpointStorage,
};
use deepbook_schema::MIGRATIONS;
use prometheus::Registry;
use std::net::SocketAddr;
use sui_indexer_alt_framework::ingestion::ingestion_client::IngestionClientArgs;
use sui_indexer_alt_framework::ingestion::{ClientArgs, IngestionConfig};
use sui_indexer_alt_framework::{Indexer, IndexerArgs};
use sui_indexer_alt_metrics::db::DbConnectionStatsCollector;
use sui_indexer_alt_metrics::{MetricsArgs, MetricsService};
use sui_pg_db::{Db, DbArgs};

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
    #[clap(long, value_enum, default_values = ["deepbook", "deepbook-margin"])]
    packages: Vec<Package>,

    /// Checkpoint storage configuration
    #[command(flatten)]
    storage_config: CheckpointStorageConfig,

    /// Run a Walrus backfill verification test and exit
    #[clap(long)]
    verify_walrus_backfill: bool,
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
        storage_config,
        verify_walrus_backfill,
    } = Args::parse();

    if verify_walrus_backfill {
        tracing::info!("Starting Walrus backfill verification...");
        return run_walrus_verification(storage_config).await;
    }

    let registry = Registry::new_custom(Some("deepbook".into()), None)
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
        Some("deepbook_indexer_db"),
        store.clone(),
    )))?;

    let mut indexer = Indexer::new(
        store,
        indexer_args,
        ClientArgs {
            ingestion: IngestionClientArgs {
                remote_store_url: Some(env.remote_store_url()),
                local_ingestion_path: None,
                rpc_api_url: None,
                rpc_username: None,
                rpc_password: None,
            },
            streaming: Default::default(),
        },
        IngestionConfig::default(),
        None,
        metrics.registry(),
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
                    .concurrent_pipeline(ReferralFeeEventHandler::new(env), Default::default())
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
                indexer
                    .concurrent_pipeline(AssetSuppliedHandler::new(env), Default::default())
                    .await?;
                indexer
                    .concurrent_pipeline(AssetWithdrawnHandler::new(env), Default::default())
                    .await?;
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
                indexer
                    .concurrent_pipeline(
                        MaintainerFeesWithdrawnHandler::new(env),
                        Default::default(),
                    )
                    .await?;
                indexer
                    .concurrent_pipeline(ProtocolFeesWithdrawnHandler::new(env), Default::default())
                    .await?;
                indexer
                    .concurrent_pipeline(SupplierCapMintedHandler::new(env), Default::default())
                    .await?;
                indexer
                    .concurrent_pipeline(SupplyReferralMintedHandler::new(env), Default::default())
                    .await?;
                indexer
                    .concurrent_pipeline(PauseCapUpdatedHandler::new(env), Default::default())
                    .await?;
                indexer
                    .concurrent_pipeline(ProtocolFeesIncreasedHandler::new(env), Default::default())
                    .await?;
                indexer
                    .concurrent_pipeline(ReferralFeesClaimedHandler::new(env), Default::default())
                    .await?;

                // Collateral Events
                indexer
                    .concurrent_pipeline(DepositCollateralHandler::new(env), Default::default())
                    .await?;
                indexer
                    .concurrent_pipeline(WithdrawCollateralHandler::new(env), Default::default())
                    .await?;

                // TPSL (Take Profit / Stop Loss) Events
                indexer
                    .concurrent_pipeline(ConditionalOrderAddedHandler::new(env), Default::default())
                    .await?;
                indexer
                    .concurrent_pipeline(
                        ConditionalOrderCancelledHandler::new(env),
                        Default::default(),
                    )
                    .await?;
                indexer
                    .concurrent_pipeline(
                        ConditionalOrderExecutedHandler::new(env),
                        Default::default(),
                    )
                    .await?;
                indexer
                    .concurrent_pipeline(
                        ConditionalOrderInsufficientFundsHandler::new(env),
                        Default::default(),
                    )
                    .await?;
            }
        }
    }

    let s_indexer = indexer.run().await?;
    let s_metrics = metrics.run().await?;

    s_indexer.attach(s_metrics).main().await?;
    Ok(())
}

async fn run_walrus_verification(config: CheckpointStorageConfig) -> Result<(), anyhow::Error> {
    tracing::info!("Initializing checkpoint storage: {}", config.storage);

    // Create checkpoint storage service
    let checkpoint_storage: Box<dyn CheckpointStorage> = match config.storage {
        CheckpointStorageType::Sui => {
            let storage = SuiCheckpointStorage::new(
                Url::parse("https://checkpoints.mainnet.sui.io").unwrap(),
            );
            Box::new(storage)
        }
        CheckpointStorageType::Walrus => {
            let mut storage = WalrusCheckpointStorage::new(
                config.walrus_archival_url.clone(),
                config.walrus_aggregator_url.clone(),
                config.cache_dir.clone(),
                config.cache_max_size_gb,
            )?;

            // Initialize blob metadata
            storage.initialize().await?;
            Box::new(storage)
        }
    };

    // Run a small backfill test
    let start_cp = 238300000;
    let count = 1000; // Increased count to test blob optimization
    tracing::info!(
        "Fetching {} checkpoints starting from {}...",
        count,
        start_cp
    );

    let start_time = std::time::Instant::now();

    match checkpoint_storage
        .get_checkpoints(start_cp..start_cp + count)
        .await
    {
        Ok(checkpoints) => {
            for data in checkpoints {
                tracing::info!(
                    "✓ Fetched checkpoint {}: txs={}, time={}",
                    data.checkpoint_summary.sequence_number,
                    data.transactions.len(),
                    data.checkpoint_summary.timestamp_ms
                );
            }
        }
        Err(e) => {
            tracing::error!("✗ Failed to fetch batch of checkpoints: {}", e);
            return Err(e);
        }
    }

    let elapsed = start_time.elapsed();
    tracing::info!(
        "Verification complete! Fetched {} checkpoints in {:.2}s ({:.2} cp/s)",
        count,
        elapsed.as_secs_f64(),
        count as f64 / elapsed.as_secs_f64()
    );

    Ok(())
}
