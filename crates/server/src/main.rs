// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

use clap::Parser;
use deepbook_server::postgres_manager::get_connection_pool;
use deepbook_server::server::run_server;
use std::net::{IpAddr, Ipv4Addr, SocketAddr};
use url::Url;

#[derive(Parser)]
#[clap(rename_all = "kebab-case", author, version)]
struct Args {
    #[clap(env, long, default_value_t = 9008)]
    server_port: u16,
    #[clap(
        env,
        long,
        default_value = "postgres://postgres:46B6nJp_09not_cUZHw@34.105.11.255:5432/defaultdb"
    )]
    database_url: Url,
    #[clap(env, long, default_value = "https://fullnode.mainnet.sui.io:443")]
    rpc_url: Url,
}

#[tokio::main]
async fn main() -> Result<(), anyhow::Error> {
    let Args {
        server_port,
        database_url,
        rpc_url,
    } = Args::parse();
    let server_address = SocketAddr::new(IpAddr::V4(Ipv4Addr::new(0, 0, 0, 0)), server_port);
    let pg_pool = get_connection_pool(database_url).await;
    run_server(server_address, pg_pool, rpc_url).await?;

    Ok(())
}
