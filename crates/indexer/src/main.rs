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

use deepbook_indexer::{DeepbookEnv, TESTNET_REMOTE_STORE_URL};
use deepbook_schema::MIGRATIONS;
use prometheus::Registry;
use std::net::SocketAddr;
use std::path::PathBuf;
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
    #[command(flatten)]
    streaming_args: StreamingClientArgs,
    #[clap(env, long, default_value = "0.0.0.0:9184")]
    metrics_address: SocketAddr,
    #[clap(
        env,
        long,
        default_value = "postgres://postgres:postgrespw@localhost:5432/deepbook"
    )]
    database_url: Url,
    /// Deepbook environment (required in production mode, ignored with sandbox subcommand)
    #[clap(env, long)]
    env: Option<DeepbookEnv>,
    /// Packages to index events for (can specify multiple)
    #[clap(long, value_enum, default_values = ["deepbook", "deepbook-margin"])]
    packages: Vec<Package>,
    #[command(subcommand)]
    sandbox: Option<Command>,
}

#[derive(clap::Subcommand)]
enum Command {
    /// Run the indexer in sandbox mode with custom package IDs
    Sandbox(SandboxArgs),
}

#[derive(clap::Args)]
#[clap(rename_all = "kebab-case")]
struct SandboxArgs {
    /// Sandbox environment
    #[clap(long, default_value = "localnet")]
    env: SandboxEnv,
    /// DeepBook core package ID(s) — can be specified multiple times
    #[clap(long, required = true)]
    deepbook_package_id: Vec<String>,
    /// Margin package ID(s) — optional, skip margin indexing if omitted
    #[clap(long)]
    margin_packages: Vec<String>,
    /// Path to local checkpoint directory (required for localnet)
    #[clap(long)]
    local_ingestion_path: Option<PathBuf>,
}

#[derive(Debug, Clone, Copy, clap::ValueEnum)]
enum SandboxEnv {
    Testnet,
    Localnet,
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
        sandbox,
    } = Args::parse();

    // Resolve mode-specific config: env, ingestion source, and which packages to index
    let (env, ingestion_args, packages) = match sandbox {
        None => {
            // Production mode — --env is required
            let env = env.expect("--env is required when not using a subcommand");
            let ingestion = IngestionClientArgs {
                remote_store_url: Some(env.remote_store_url()),
                ..Default::default()
            };
            (env, ingestion, packages)
        }
        Some(Command::Sandbox(sb)) => {
            // Sandbox mode — override package addresses (even on testnet, because
            // sandbox deploys its own DeepBook instance), then pick ingestion source
            let has_margin = !sb.margin_packages.is_empty();
            deepbook_indexer::sandbox::init_package_override(
                sb.deepbook_package_id,
                sb.margin_packages,
            );

            let ingestion = match sb.env {
                SandboxEnv::Localnet => IngestionClientArgs {
                    local_ingestion_path: Some(
                        sb.local_ingestion_path
                            .expect("--local-ingestion-path is required for localnet"),
                    ),
                    ..Default::default()
                },
                SandboxEnv::Testnet => IngestionClientArgs {
                    remote_store_url: Some(
                        Url::parse(TESTNET_REMOTE_STORE_URL)
                            .expect("invalid testnet remote store URL"),
                    ),
                    ..Default::default()
                },
            };

            // Skip margin handlers if no margin packages provided
            let mut packages = packages;
            if !has_margin {
                packages.retain(|p| matches!(p, Package::Deepbook));
            }

            // In sandbox mode the OnceLock override handles all package resolution,
            // so this env value is only used for type compatibility in handler constructors.
            // It does not affect which packages are indexed.
            (env.unwrap_or(DeepbookEnv::Mainnet), ingestion, packages)
        }
    };

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
