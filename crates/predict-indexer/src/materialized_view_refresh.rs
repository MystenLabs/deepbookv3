//! Periodic materialized-view refresh for the Predict analytics views.
//!
//! Mirrors core's `crates/indexer/src/materialized_view_refresh.rs`; only the
//! view list differs. Every view here must have a UNIQUE index (required for
//! `REFRESH MATERIALIZED VIEW CONCURRENTLY`) — see the consolidated
//! `predict_schema` init migration.

use anyhow::{bail, Context};
use diesel_async::RunQueryDsl;
use prometheus::{
    register_histogram_vec_with_registry, register_int_counter_vec_with_registry, HistogramVec,
    IntCounterVec, Registry,
};
use std::sync::Arc;
use std::time::{Duration, Instant};
use sui_futures::service::Service;
use sui_pg_db::Db;
use tokio::time::{interval, MissedTickBehavior};

const MATERIALIZED_VIEWS_TO_REFRESH: &[&str] = &[
    "market_activity_1h",
    "vault_flows_1h",
    "liquidation_stats_1h",
    "position_cashflow",
];
const REFRESH_DURATION_SEC_BUCKETS: &[f64] = &[
    0.01, 0.05, 0.1, 0.25, 0.5, 1.0, 2.5, 5.0, 10.0, 30.0, 60.0, 120.0,
];

#[derive(Clone)]
pub struct MaterializedViewRefreshMetrics {
    pub refresh_duration: HistogramVec,
    pub refresh_successes: IntCounterVec,
    pub refresh_failures: IntCounterVec,
}

impl MaterializedViewRefreshMetrics {
    pub fn new(registry: &Registry) -> Arc<Self> {
        Arc::new(Self {
            refresh_duration: register_histogram_vec_with_registry!(
                "materialized_view_refresh_duration_seconds",
                "Time taken to refresh materialized views by view",
                &["view"],
                REFRESH_DURATION_SEC_BUCKETS.to_vec(),
                registry
            )
            .unwrap(),
            refresh_successes: register_int_counter_vec_with_registry!(
                "materialized_view_refresh_successes_total",
                "Number of successful materialized view refresh attempts by view",
                &["view"],
                registry
            )
            .unwrap(),
            refresh_failures: register_int_counter_vec_with_registry!(
                "materialized_view_refresh_failures_total",
                "Number of failed materialized view refresh attempts by view",
                &["view"],
                registry
            )
            .unwrap(),
        })
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
struct MaterializedViewName {
    name: String,
    quoted_name: String,
}

impl MaterializedViewName {
    fn parse(raw_name: &str) -> anyhow::Result<Self> {
        let name = raw_name.trim();
        if name.is_empty() {
            bail!("Invalid materialized view name: view name cannot be empty");
        }

        let mut quoted_parts = Vec::new();
        for part in name.split('.') {
            if !is_valid_identifier(part) {
                bail!("Invalid materialized view name `{name}`");
            }
            quoted_parts.push(format!("\"{part}\""));
        }

        Ok(Self {
            name: name.to_string(),
            quoted_name: quoted_parts.join("."),
        })
    }

    fn name(&self) -> &str {
        &self.name
    }

    fn refresh_sql(&self) -> String {
        format!(
            "REFRESH MATERIALIZED VIEW CONCURRENTLY {}",
            self.quoted_name
        )
    }
}

fn is_valid_identifier(identifier: &str) -> bool {
    let mut chars = identifier.chars();
    let Some(first) = chars.next() else {
        return false;
    };

    if !(first == '_' || first.is_ascii_alphabetic()) {
        return false;
    }

    chars.all(|char| char == '_' || char.is_ascii_alphanumeric())
}

fn materialized_view_refresh_interval(refresh_interval_secs: u64) -> Option<Duration> {
    if refresh_interval_secs == 0 {
        None
    } else {
        Some(Duration::from_secs(refresh_interval_secs))
    }
}

fn materialized_view_names() -> anyhow::Result<Vec<MaterializedViewName>> {
    MATERIALIZED_VIEWS_TO_REFRESH
        .iter()
        .map(|view| MaterializedViewName::parse(view))
        .collect()
}

async fn refresh_materialized_view_once(
    db: &Db,
    view: &MaterializedViewName,
) -> anyhow::Result<usize> {
    let mut conn = db
        .connect()
        .await
        .with_context(|| format!("Failed to connect to database for {} refresh", view.name()))?;

    diesel::sql_query(view.refresh_sql())
        .execute(&mut conn)
        .await
        .with_context(|| format!("Failed to refresh {} materialized view", view.name()))
}

pub fn materialized_view_refresh_service(
    db: Db,
    metrics: Arc<MaterializedViewRefreshMetrics>,
    refresh_interval_secs: u64,
) -> anyhow::Result<Option<Service>> {
    let Some(refresh_interval) = materialized_view_refresh_interval(refresh_interval_secs) else {
        tracing::info!("materialized view refresh task disabled");
        return Ok(None);
    };

    let views = materialized_view_names()?;
    if views.is_empty() {
        tracing::info!("materialized view refresh task disabled because no views were configured");
        return Ok(None);
    }

    let view_names = views
        .iter()
        .map(|view| view.name())
        .collect::<Vec<_>>()
        .join(",");
    tracing::info!(
        refresh_interval_secs = refresh_interval.as_secs(),
        views = view_names,
        "Starting materialized view refresh task"
    );

    Ok(Some(Service::new().spawn_aborting(
        refresh_materialized_view_loop(db, metrics, refresh_interval, views),
    )))
}

async fn refresh_materialized_view_loop(
    db: Db,
    metrics: Arc<MaterializedViewRefreshMetrics>,
    refresh_interval: Duration,
    views: Vec<MaterializedViewName>,
) -> anyhow::Result<()> {
    let mut ticker = interval(refresh_interval);
    ticker.set_missed_tick_behavior(MissedTickBehavior::Skip);

    loop {
        ticker.tick().await;

        for view in &views {
            let refresh_started_at = Instant::now();
            let timer = metrics
                .refresh_duration
                .with_label_values(&[view.name()])
                .start_timer();
            let result = refresh_materialized_view_once(&db, view).await;
            timer.observe_duration();
            let refresh_duration_secs = refresh_started_at.elapsed().as_secs_f64();

            match result {
                Ok(_) => {
                    metrics
                        .refresh_successes
                        .with_label_values(&[view.name()])
                        .inc();
                    tracing::debug!(
                        view = view.name(),
                        refresh_duration_secs,
                        "Refreshed materialized view"
                    );
                }
                Err(error) => {
                    metrics
                        .refresh_failures
                        .with_label_values(&[view.name()])
                        .inc();
                    tracing::error!(
                        ?error,
                        view = view.name(),
                        refresh_duration_secs,
                        "Failed to refresh materialized view"
                    );
                }
            }
        }
    }
}
