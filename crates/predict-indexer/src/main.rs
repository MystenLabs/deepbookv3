use anyhow::Context;
use clap::Parser;
use predict_indexer::handlers::builder_code_created_handler::BuilderCodeCreatedHandler;
use predict_indexer::handlers::builder_code_set_handler::BuilderCodeSetHandler;
use predict_indexer::handlers::builder_fees_claimed_handler::BuilderFeesClaimedHandler;
use predict_indexer::handlers::deep_staked_handler::DeepStakedHandler;
use predict_indexer::handlers::deep_unstaked_handler::DeepUnstakedHandler;
use predict_indexer::handlers::ewma_config_updated_handler::EwmaConfigUpdatedHandler;
use predict_indexer::handlers::expiry_cash_rebalanced_handler::ExpiryCashRebalancedHandler;
use predict_indexer::handlers::expiry_cash_received_handler::ExpiryCashReceivedHandler;
use predict_indexer::handlers::expiry_cash_template_config_updated_handler::ExpiryCashTemplateConfigUpdatedHandler;
use predict_indexer::handlers::expiry_market_mint_paused_updated_handler::ExpiryMarketMintPausedUpdatedHandler;
use predict_indexer::handlers::expiry_profit_materialized_handler::ExpiryProfitMaterializedHandler;
use predict_indexer::handlers::flush_executed_handler::FlushExecutedHandler;
use predict_indexer::handlers::liquidated_order_redeemed_handler::LiquidatedOrderRedeemedHandler;
use predict_indexer::handlers::live_order_redeemed_handler::LiveOrderRedeemedHandler;
use predict_indexer::handlers::lp_request_state_handler::LpRequestStateHandler;
use predict_indexer::handlers::market_config_snapshot_handler::MarketConfigSnapshotHandler;
use predict_indexer::handlers::market_created_handler::MarketCreatedHandler;
use predict_indexer::handlers::market_settled_handler::MarketSettledHandler;
use predict_indexer::handlers::order_liquidated_handler::OrderLiquidatedHandler;
use predict_indexer::handlers::order_minted_handler::OrderMintedHandler;
use predict_indexer::handlers::order_state_handler::OrderStateHandler;
use predict_indexer::handlers::predict_deposit_cap_minted_handler::PredictDepositCapMintedHandler;
use predict_indexer::handlers::predict_manager_created_handler::PredictManagerCreatedHandler;
use predict_indexer::handlers::predict_trade_cap_minted_handler::PredictTradeCapMintedHandler;
use predict_indexer::handlers::predict_withdraw_cap_minted_handler::PredictWithdrawCapMintedHandler;
use predict_indexer::handlers::pricing_config_updated_handler::PricingConfigUpdatedHandler;
use predict_indexer::handlers::request_cancelled_handler::RequestCancelledHandler;
use predict_indexer::handlers::risk_config_updated_handler::RiskConfigUpdatedHandler;
use predict_indexer::handlers::settled_order_redeemed_handler::SettledOrderRedeemedHandler;
use predict_indexer::handlers::stake_config_updated_handler::StakeConfigUpdatedHandler;
use predict_indexer::handlers::strike_exposure_template_config_updated_handler::StrikeExposureTemplateConfigUpdatedHandler;
use predict_indexer::handlers::supply_filled_handler::SupplyFilledHandler;
use predict_indexer::handlers::supply_requested_handler::SupplyRequestedHandler;
use predict_indexer::handlers::trading_paused_updated_handler::TradingPausedUpdatedHandler;
use predict_indexer::handlers::withdraw_filled_handler::WithdrawFilledHandler;
use predict_indexer::handlers::withdraw_requested_handler::WithdrawRequestedHandler;
use predict_indexer::materialized_view_refresh::{
    materialized_view_refresh_service, MaterializedViewRefreshMetrics,
};
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
    /// Index all Predict events (order, account, config, vault domains).
    Predict,
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
    #[clap(long, value_enum, default_values = ["predict"])]
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
            Package::Predict => {
                // Order lifecycle (raw feeds + maintained order_state).
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
                indexer
                    .concurrent_pipeline(OrderStateHandler::new(env), Default::default())
                    .await?;

                // Accounts, caps, builder codes.
                indexer
                    .concurrent_pipeline(PredictManagerCreatedHandler::new(env), Default::default())
                    .await?;
                indexer
                    .concurrent_pipeline(BuilderCodeCreatedHandler::new(env), Default::default())
                    .await?;
                indexer
                    .concurrent_pipeline(BuilderCodeSetHandler::new(env), Default::default())
                    .await?;
                indexer
                    .concurrent_pipeline(PredictTradeCapMintedHandler::new(env), Default::default())
                    .await?;
                indexer
                    .concurrent_pipeline(
                        PredictDepositCapMintedHandler::new(env),
                        Default::default(),
                    )
                    .await?;
                indexer
                    .concurrent_pipeline(
                        PredictWithdrawCapMintedHandler::new(env),
                        Default::default(),
                    )
                    .await?;
                indexer
                    .concurrent_pipeline(BuilderFeesClaimedHandler::new(env), Default::default())
                    .await?;

                // Config + market lifecycle.
                indexer
                    .concurrent_pipeline(PricingConfigUpdatedHandler::new(env), Default::default())
                    .await?;
                indexer
                    .concurrent_pipeline(RiskConfigUpdatedHandler::new(env), Default::default())
                    .await?;
                indexer
                    .concurrent_pipeline(
                        ExpiryCashTemplateConfigUpdatedHandler::new(env),
                        Default::default(),
                    )
                    .await?;
                indexer
                    .concurrent_pipeline(
                        StrikeExposureTemplateConfigUpdatedHandler::new(env),
                        Default::default(),
                    )
                    .await?;
                indexer
                    .concurrent_pipeline(EwmaConfigUpdatedHandler::new(env), Default::default())
                    .await?;
                indexer
                    .concurrent_pipeline(StakeConfigUpdatedHandler::new(env), Default::default())
                    .await?;
                indexer
                    .concurrent_pipeline(TradingPausedUpdatedHandler::new(env), Default::default())
                    .await?;
                indexer
                    .concurrent_pipeline(MarketCreatedHandler::new(env), Default::default())
                    .await?;
                indexer
                    .concurrent_pipeline(MarketConfigSnapshotHandler::new(env), Default::default())
                    .await?;
                indexer
                    .concurrent_pipeline(
                        ExpiryMarketMintPausedUpdatedHandler::new(env),
                        Default::default(),
                    )
                    .await?;
                indexer
                    .concurrent_pipeline(MarketSettledHandler::new(env), Default::default())
                    .await?;

                // Pool vault + async LP (raw feeds + maintained lp_request_state).
                indexer
                    .concurrent_pipeline(ExpiryCashRebalancedHandler::new(env), Default::default())
                    .await?;
                indexer
                    .concurrent_pipeline(ExpiryCashReceivedHandler::new(env), Default::default())
                    .await?;
                indexer
                    .concurrent_pipeline(
                        ExpiryProfitMaterializedHandler::new(env),
                        Default::default(),
                    )
                    .await?;
                indexer
                    .concurrent_pipeline(DeepStakedHandler::new(env), Default::default())
                    .await?;
                indexer
                    .concurrent_pipeline(DeepUnstakedHandler::new(env), Default::default())
                    .await?;
                indexer
                    .concurrent_pipeline(SupplyRequestedHandler::new(env), Default::default())
                    .await?;
                indexer
                    .concurrent_pipeline(WithdrawRequestedHandler::new(env), Default::default())
                    .await?;
                indexer
                    .concurrent_pipeline(RequestCancelledHandler::new(env), Default::default())
                    .await?;
                indexer
                    .concurrent_pipeline(SupplyFilledHandler::new(env), Default::default())
                    .await?;
                indexer
                    .concurrent_pipeline(WithdrawFilledHandler::new(env), Default::default())
                    .await?;
                indexer
                    .concurrent_pipeline(FlushExecutedHandler::new(env), Default::default())
                    .await?;
                indexer
                    .concurrent_pipeline(LpRequestStateHandler::new(env), Default::default())
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
