// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

use clap::Parser;
use deepbook_server::server::run_server;
use std::net::{IpAddr, Ipv4Addr, SocketAddr};
use sui_pg_db::DbArgs;
use tokio_util::sync::CancellationToken;
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
    #[clap(env, long, default_value = "https://fullnode.mainnet.sui.io:443")]
    rpc_url: Url,
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
    } = Args::parse();
    let server_address = SocketAddr::new(IpAddr::V4(Ipv4Addr::new(0, 0, 0, 0)), server_port);
    let cancel = CancellationToken::new();

    run_server(
        server_address,
        database_url,
        db_args,
        rpc_url,
        cancel.child_token(),
        metrics_address,
    )
    .await?;

    Ok(())
}
