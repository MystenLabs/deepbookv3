// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

use clap::Parser;
use deepbook_server::pyth::{
    PythChartHistoryConfig, PythProConfig, DEFAULT_CHART_HISTORY_CACHE_MAX_ENTRIES,
    DEFAULT_CHART_HISTORY_CACHE_TTL_SECS, DEFAULT_CHART_HISTORY_MAX_RANGE_SECS,
    DEFAULT_HISTORY_CACHE_MAX_ENTRIES, DEFAULT_HISTORY_CACHE_TTL_SECS, DEFAULT_LATEST_CACHE_TTL_MS,
    DEFAULT_PRO_HISTORY_URL, DEFAULT_PRO_URL,
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
    /// Network to serve. Supplies the defaults for `--rpc-url` and `--deepbook-package-id`.
    // The variable is `DEEPBOOK_ENV` rather than the `ENV` clap would derive from the field
    // name, which the shell already defines.
    #[clap(env = "DEEPBOOK_ENV", long = "env", default_value = "mainnet")]
    env: DeepbookEnv,
    /// Full node gRPC endpoint (`sui.rpc.v2`). Same host/port as the old JSON-RPC URL.
    /// Defaults to the public full node for `--env`.
    #[clap(env, long)]
    rpc_url: Option<Url>,
    /// DeepBook core package that `/orderbook` and `/fees` simulate against.
    /// Defaults to the latest published package for `--env`.
    #[clap(env, long)]
    deepbook_package_id: Option<String>,
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
    #[clap(env = "LIVE_OHCLV_POLL_INTERVAL_MS", long, default_value_t = 1000)]
    live_ohclv_poll_interval_ms: u64,
    #[clap(env = "LIVE_OHCLV_MAX_FILLS", long, default_value_t = 5000)]
    live_ohclv_max_fills: usize,
    /// Comma-separated list of valid admin bearer tokens
    #[clap(env = "ADMIN_TOKENS", long)]
    admin_tokens: Option<String>,
    /// Authenticated Pyth Pro Router API base URL.
    #[clap(env, long, default_value = DEFAULT_PRO_URL)]
    pyth_pro_url: Url,
    /// Comma-separated Pyth Pro numeric feed IDs the public routes may serve.
    #[clap(env, long, value_delimiter = ',')]
    pyth_pro_allowed_feed_ids: Vec<u32>,
    /// Cache lifetime for the shared latest-price snapshot, in milliseconds.
    #[clap(env, long, default_value_t = DEFAULT_LATEST_CACHE_TTL_MS)]
    pyth_pro_latest_cache_ttl_ms: u64,
    /// Cache lifetime for historical Pyth Pro prices, in seconds.
    #[clap(env, long, default_value_t = DEFAULT_HISTORY_CACHE_TTL_SECS)]
    pyth_pro_history_cache_ttl_secs: u64,
    /// Maximum historical feed/timestamp pairs cached in this process.
    #[clap(env, long, default_value_t = DEFAULT_HISTORY_CACHE_MAX_ENTRIES)]
    pyth_pro_history_cache_max_entries: u64,
    /// Authenticated Pyth Pro History API base URL.
    #[clap(env, long, default_value = DEFAULT_PRO_HISTORY_URL)]
    pyth_pro_history_url: Url,
    /// Comma-separated TradingView symbols the chart-history route may serve.
    #[clap(env, long, value_delimiter = ',')]
    pyth_pro_history_symbols: Vec<String>,
    /// Cache lifetime for Pyth Pro chart-history responses, in seconds.
    #[clap(env, long, default_value_t = DEFAULT_CHART_HISTORY_CACHE_TTL_SECS)]
    pyth_pro_chart_history_cache_ttl_secs: u64,
    /// Maximum chart-history responses cached in this process.
    #[clap(env, long, default_value_t = DEFAULT_CHART_HISTORY_CACHE_MAX_ENTRIES)]
    pyth_pro_chart_history_cache_max_entries: u64,
    /// Absolute maximum chart-history query range, in seconds.
    /// A resolution-aware candle limit may lower the effective range.
    #[clap(env, long, default_value_t = DEFAULT_CHART_HISTORY_MAX_RANGE_SECS)]
    pyth_pro_chart_history_max_range_secs: u64,
}

/// Network the server reads from, mirroring the indexer's `--env`.
#[derive(Debug, Clone, Copy, clap::ValueEnum)]
enum DeepbookEnv {
    Mainnet,
    Testnet,
}

impl DeepbookEnv {
    fn rpc_url(&self) -> Url {
        let url = match self {
            DeepbookEnv::Mainnet => "https://fullnode.mainnet.sui.io:443",
            DeepbookEnv::Testnet => "https://fullnode.testnet.sui.io:443",
        };
        Url::parse(url).unwrap()
    }

    /// Latest published DeepBook core package, matching `packages/deepbook/Published.toml`.
    ///
    /// This tracks the newest package address, never the original one. A pool caches an
    /// `allowed_versions` set and `pool::load_inner` asserts the calling package's
    /// `CURRENT_VERSION` belongs to it, so calls through a package whose version has been
    /// retired by `registry::disable_version` abort. An aborted command produces no outputs,
    /// which surfaces as an empty simulation result rather than as a version error — see
    /// `grpc::simulate_returns`.
    fn deepbook_package_id(&self) -> &'static str {
        match self {
            DeepbookEnv::Mainnet => {
                "0x0e735f8c93a95722efd73521aca7a7652c0bb71ed1daf41b26dfd7d1ff71f748"
            }
            DeepbookEnv::Testnet => {
                "0xd874d2417a55bfa6479bffa06ad950fea144ef93a94cc6c49f32b03e386bbb24"
            }
        }
    }
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
        env,
        rpc_url,
        deepbook_package_id,
        deep_token_package_id,
        deep_treasury_id,
        margin_poll_interval_secs,
        margin_package_id,
        live_ohclv_poll_interval_ms,
        live_ohclv_max_fills,
        admin_tokens,
        pyth_pro_url,
        pyth_pro_allowed_feed_ids,
        pyth_pro_latest_cache_ttl_ms,
        pyth_pro_history_cache_ttl_secs,
        pyth_pro_history_cache_max_entries,
        pyth_pro_history_url,
        pyth_pro_history_symbols,
        pyth_pro_chart_history_cache_ttl_secs,
        pyth_pro_chart_history_cache_max_entries,
        pyth_pro_chart_history_max_range_secs,
    } = Args::parse();
    let rpc_url = rpc_url.unwrap_or_else(|| env.rpc_url());
    let deepbook_package_id =
        deepbook_package_id.unwrap_or_else(|| env.deepbook_package_id().to_string());
    // Read the secret from the environment only so it never needs to appear in
    // process arguments or clap's help output.
    let pyth_pro_api_key = std::env::var("PYTH_PRO_API_KEY").ok();
    let pyth_pro_config = PythProConfig {
        allowed_feed_ids: pyth_pro_allowed_feed_ids,
        latest_cache_ttl: Duration::from_millis(pyth_pro_latest_cache_ttl_ms),
        history_cache_ttl: Duration::from_secs(pyth_pro_history_cache_ttl_secs),
        history_cache_max_entries: pyth_pro_history_cache_max_entries,
        chart_history: PythChartHistoryConfig {
            upstream_url: pyth_pro_history_url,
            symbols: pyth_pro_history_symbols,
            cache_ttl: Duration::from_secs(pyth_pro_chart_history_cache_ttl_secs),
            cache_max_entries: pyth_pro_chart_history_cache_max_entries,
            max_range: Duration::from_secs(pyth_pro_chart_history_max_range_secs),
        },
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
        live_ohclv_poll_interval_ms,
        live_ohclv_max_fills,
        pyth_pro_url,
        pyth_pro_api_key,
        pyth_pro_config,
    )
    .await?;

    Ok(())
}
