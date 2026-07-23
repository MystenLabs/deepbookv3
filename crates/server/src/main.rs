// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

use clap::Parser;
use deepbook_server::pyth::{
    PythCacheConfig, DEFAULT_CACHE_MAX_ENTRIES, DEFAULT_HERMES_URL,
    DEFAULT_HISTORICAL_CACHE_TTL_SECS, DEFAULT_LATEST_CACHE_TTL_MS,
};
use deepbook_server::server::run_server;
use std::{net::SocketAddr, time::Duration};
use sui_pg_db::DbArgs;
use url::Url;

#[derive(Parser)]
#[clap(rename_all = "kebab-case", author, version)]
struct Args {
    #[command(flatten)]
    db_args: DbArgs,
    #[clap(env, long, default_value_t = 9008)]
    server_port: u16,
    #[clap(env, long, default_value = "0.0.0.0:9184")]
    metrics_address: SocketAddr,
    #[clap(
        env,
        long,
        default_value = "postgres://postgres:postgrespw@localhost:5432/deepbook"
    )]
    database_url: Url,
    /// Full node gRPC endpoint (`sui.rpc.v2`). Same host/port as the old JSON-RPC URL.
    #[clap(env, long, default_value = "https://fullnode.mainnet.sui.io:443")]
    rpc_url: Url,
    #[clap(
        env,
        long,
        default_value = "0x2c8d603bc51326b8c13cef9dd07031a408a48dddb541963357661df5d3204809"
    )]
    deepbook_package_id: String,
    #[clap(
        env,
        long,
        default_value = "0xdeeb7a4662eec9f2f3def03fb937a663dddaa2e215b8078a284d026b7946c270"
    )]
    deep_token_package_id: String,
    #[clap(
        env,
        long,
        default_value = "0x032abf8948dda67a271bcc18e776dbbcfb0d58c8d288a700ff0d5521e57a1ffe"
    )]
    deep_treasury_id: String,

    // Margin metrics polling configuration
    #[clap(env, long, default_value_t = 30)]
    margin_poll_interval_secs: u64,
    #[clap(env, long)]
    margin_package_id: Option<String>,
    /// Comma-separated list of valid admin bearer tokens
    #[clap(env = "ADMIN_TOKENS", long)]
    admin_tokens: Option<String>,
    /// Authenticated Pyth Hermes base URL.
    #[clap(env, long, default_value = DEFAULT_HERMES_URL)]
    pyth_hermes_url: Url,
    /// Cache lifetime for the latest-price endpoint, in milliseconds.
    #[clap(env, long, default_value_t = DEFAULT_LATEST_CACHE_TTL_MS)]
    pyth_latest_cache_ttl_ms: u64,
    /// Cache lifetime for historical-price responses, in seconds.
    #[clap(env, long, default_value_t = DEFAULT_HISTORICAL_CACHE_TTL_SECS)]
    pyth_historical_cache_ttl_secs: u64,
    /// Maximum number of successful Pyth responses cached in this server process.
    #[clap(env, long, default_value_t = DEFAULT_CACHE_MAX_ENTRIES)]
    pyth_cache_max_entries: usize,
}

#[tokio::main]
async fn main() -> Result<(), anyhow::Error> {
    let _guard = telemetry_subscribers::TelemetryConfig::new()
        .with_env()
        .init();

    let Args {
        db_args,
        server_port,
        metrics_address,
        database_url,
        rpc_url,
        deepbook_package_id,
        deep_token_package_id,
        deep_treasury_id,
        margin_poll_interval_secs,
        margin_package_id,
        admin_tokens,
        pyth_hermes_url,
        pyth_latest_cache_ttl_ms,
        pyth_historical_cache_ttl_secs,
        pyth_cache_max_entries,
    } = Args::parse();
    // Read the secret from the environment only so it never needs to appear in
    // process arguments or clap's help output.
    let pyth_api_key = std::env::var("PYTH_API_KEY").ok();
    let pyth_cache_config = PythCacheConfig {
        latest_ttl: Duration::from_millis(pyth_latest_cache_ttl_ms),
        historical_ttl: Duration::from_secs(pyth_historical_cache_ttl_secs),
        max_entries: pyth_cache_max_entries,
    };

    run_server(
        server_port,
        database_url,
        db_args,
        rpc_url,
        metrics_address,
        deepbook_package_id,
        deep_token_package_id,
        deep_treasury_id,
        margin_poll_interval_secs,
        margin_package_id,
        admin_tokens,
        pyth_hermes_url,
        pyth_api_key,
        pyth_cache_config,
    )
    .await?;

    Ok(())
}
