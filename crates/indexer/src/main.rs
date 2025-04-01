use anyhow::Context;
use clap::Parser;
use deepbook_indexer::handlers::balances_handler::BalancesHandler;
use deepbook_indexer::handlers::flash_loan_handler::FlashLoanHandler;
use deepbook_indexer::handlers::order_fill_handler::OrderFillHandler;
use deepbook_indexer::handlers::order_update_handler::OrderUpdateHandler;
use deepbook_indexer::handlers::pool_price_handler::PoolPriceHandler;
use deepbook_indexer::handlers::proposals_handler::ProposalsHandler;
use deepbook_indexer::handlers::rebates_handler::RebatesHandler;
use deepbook_indexer::handlers::stakes_handler::StakesHandler;
use deepbook_indexer::handlers::trade_params_update_handler::TradeParamsUpdateHandler;
use deepbook_indexer::handlers::vote_handler::VotesHandler;
use deepbook_indexer::MAINNET_REMOTE_STORE_URL;
use deepbook_schema::MIGRATIONS;
use move_core_types::account_address::AccountAddress;
use prometheus::Registry;
use std::net::SocketAddr;
use sui_indexer_alt_framework::ingestion::ClientArgs;
use sui_indexer_alt_framework::{Indexer, IndexerArgs};
use sui_indexer_alt_metrics::{MetricsArgs, MetricsService};
use sui_pg_db::DbArgs;
use tokio_util::sync::CancellationToken;
use url::Url;

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
    /// Checkpoint remote store URL, defaulted to Sui mainnet remote store.
    #[clap(env, long, default_value = MAINNET_REMOTE_STORE_URL)]
    remote_store_url: Url,
    /// Deepbook package id override, defaulted to the mainnet deepbook package id.
    #[clap(env, long)]
    package_id_override: Option<AccountAddress>,
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
        remote_store_url,
        database_url,
        package_id_override,
    } = Args::parse();

    let cancel = CancellationToken::new();
    let registry = Registry::new_custom(Some("deepbook".into()), None)
        .context("Failed to create Prometheus registry.")?;
    let metrics = MetricsService::new(
        MetricsArgs { metrics_address },
        registry,
        cancel.child_token(),
    );

    let mut indexer = Indexer::new(
        database_url,
        db_args,
        indexer_args,
        ClientArgs {
            remote_store_url: Some(remote_store_url),
            local_ingestion_path: None,
            rpc_api_url: None,
            rpc_username: None,
            rpc_password: None,
        },
        Default::default(),
        Some(&MIGRATIONS),
        metrics.registry(),
        cancel.clone(),
    )
    .await?;

    indexer
        .concurrent_pipeline(
            BalancesHandler::new(package_id_override),
            Default::default(),
        )
        .await?;
    indexer
        .concurrent_pipeline(
            FlashLoanHandler::new(package_id_override),
            Default::default(),
        )
        .await?;
    indexer
        .concurrent_pipeline(
            OrderFillHandler::new(package_id_override),
            Default::default(),
        )
        .await?;
    indexer
        .concurrent_pipeline(
            OrderUpdateHandler::new(package_id_override),
            Default::default(),
        )
        .await?;
    indexer
        .concurrent_pipeline(
            PoolPriceHandler::new(package_id_override),
            Default::default(),
        )
        .await?;
    indexer
        .concurrent_pipeline(
            ProposalsHandler::new(package_id_override),
            Default::default(),
        )
        .await?;
    indexer
        .concurrent_pipeline(RebatesHandler::new(package_id_override), Default::default())
        .await?;
    indexer
        .concurrent_pipeline(StakesHandler::new(package_id_override), Default::default())
        .await?;
    indexer
        .concurrent_pipeline(
            TradeParamsUpdateHandler::new(package_id_override),
            Default::default(),
        )
        .await?;
    indexer
        .concurrent_pipeline(VotesHandler::new(package_id_override), Default::default())
        .await?;

    let h_indexer = indexer.run().await?;
    let h_metrics = metrics.run().await?;

    let _ = h_indexer.await;
    cancel.cancel();
    let _ = h_metrics.await;

    Ok(())
}
