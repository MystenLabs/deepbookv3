use clap::Parser;
use predict_server::server::run_server;
use std::net::SocketAddr;
use sui_pg_db::DbArgs;
use url::Url;

#[derive(Parser)]
#[clap(rename_all = "kebab-case", author, version)]
struct Args {
    #[command(flatten)]
    db_args: DbArgs,
    #[clap(env, long, default_value_t = 9009)]
    server_port: u16,
    #[clap(env, long, default_value = "0.0.0.0:9186")]
    metrics_address: SocketAddr,
    #[clap(
        env,
        long,
        default_value = "postgres://localhost:5432/predict_v2"
    )]
    database_url: Url,
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
    } = Args::parse();

    run_server(server_port, database_url, db_args, metrics_address).await?;

    Ok(())
}
