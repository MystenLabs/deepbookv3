use anyhow::Context;
use diesel_async::RunQueryDsl;
use prometheus::{register_int_counter_with_registry, IntCounter, Registry};
use std::sync::Arc;
use std::time::Duration;
use sui_pg_db::Db;
use tokio::time::{interval, MissedTickBehavior};

pub const NET_DEPOSITS_REFRESH_SQL: &str =
    "REFRESH MATERIALIZED VIEW CONCURRENTLY net_deposits_hourly";

#[derive(Clone)]
pub struct NetDepositsRefreshMetrics {
    pub refresh_failures: IntCounter,
}

impl NetDepositsRefreshMetrics {
    pub fn new(registry: &Registry) -> Arc<Self> {
        Arc::new(Self {
            refresh_failures: register_int_counter_with_registry!(
                "net_deposits_refresh_failures_total",
                "Number of failed net_deposits_hourly materialized view refresh attempts",
                registry
            )
            .unwrap(),
        })
    }
}

pub fn net_deposits_refresh_interval(refresh_interval_secs: u64) -> Option<Duration> {
    if refresh_interval_secs == 0 {
        None
    } else {
        Some(Duration::from_secs(refresh_interval_secs))
    }
}

pub async fn refresh_net_deposits_view_once(db: &Db) -> anyhow::Result<usize> {
    let mut conn = db
        .connect()
        .await
        .context("Failed to connect to database for net_deposits_hourly refresh")?;

    diesel::sql_query(NET_DEPOSITS_REFRESH_SQL)
        .execute(&mut conn)
        .await
        .context("Failed to refresh net_deposits_hourly materialized view")
}

pub fn spawn_net_deposits_refresh_task(
    db: Db,
    metrics: Arc<NetDepositsRefreshMetrics>,
    refresh_interval: Duration,
) -> Option<tokio::task::JoinHandle<()>> {
    if refresh_interval.is_zero() {
        tracing::info!("net_deposits_hourly refresh task disabled");
        return None;
    }

    tracing::info!(
        refresh_interval_secs = refresh_interval.as_secs(),
        "Starting net_deposits_hourly refresh task"
    );

    Some(tokio::spawn(async move {
        let mut ticker = interval(refresh_interval);
        ticker.set_missed_tick_behavior(MissedTickBehavior::Skip);

        loop {
            ticker.tick().await;

            match refresh_net_deposits_view_once(&db).await {
                Ok(_) => {
                    tracing::debug!("Refreshed net_deposits_hourly materialized view");
                }
                Err(error) => {
                    metrics.refresh_failures.inc();
                    tracing::error!(
                        ?error,
                        "Failed to refresh net_deposits_hourly materialized view"
                    );
                }
            }
        }
    }))
}
