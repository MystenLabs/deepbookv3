use anyhow::{bail, Context};
use diesel_async::RunQueryDsl;
use prometheus::{register_int_counter_vec_with_registry, IntCounterVec, Registry};
use std::collections::HashSet;
use std::sync::Arc;
use std::time::Duration;
use sui_futures::service::Service;
use sui_pg_db::Db;
use tokio::time::{interval, MissedTickBehavior};

#[derive(Clone)]
pub struct MaterializedViewRefreshMetrics {
    pub refresh_failures: IntCounterVec,
}

impl MaterializedViewRefreshMetrics {
    pub fn new(registry: &Registry) -> Arc<Self> {
        Arc::new(Self {
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

fn materialized_view_names_from_config(config: &str) -> anyhow::Result<Vec<MaterializedViewName>> {
    let mut seen = HashSet::new();
    let mut views = Vec::new();

    for raw_view in config.split(',') {
        let raw_view = raw_view.trim();
        if raw_view.is_empty() {
            continue;
        }

        let view = MaterializedViewName::parse(raw_view)?;
        if seen.insert(view.name().to_string()) {
            views.push(view);
        }
    }

    Ok(views)
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
    refresh_views: &str,
) -> anyhow::Result<Option<Service>> {
    let Some(refresh_interval) = materialized_view_refresh_interval(refresh_interval_secs) else {
        tracing::info!("materialized view refresh task disabled");
        return Ok(None);
    };

    let views = materialized_view_names_from_config(refresh_views)?;
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
            match refresh_materialized_view_once(&db, view).await {
                Ok(_) => {
                    tracing::debug!(view = view.name(), "Refreshed materialized view");
                }
                Err(error) => {
                    metrics
                        .refresh_failures
                        .with_label_values(&[view.name()])
                        .inc();
                    tracing::error!(
                        ?error,
                        view = view.name(),
                        "Failed to refresh materialized view"
                    );
                }
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_configured_materialized_views() {
        let views = materialized_view_names_from_config(
            "net_deposits_hourly, public.pool_summary_hourly,net_deposits_hourly",
        )
        .unwrap();

        assert_eq!(
            views.iter().map(|view| view.name()).collect::<Vec<_>>(),
            vec!["net_deposits_hourly", "public.pool_summary_hourly"]
        );
    }

    #[test]
    fn rejects_invalid_materialized_view_names() {
        let error = MaterializedViewName::parse("net_deposits_hourly; DROP TABLE balances")
            .unwrap_err()
            .to_string();

        assert!(error.contains("Invalid materialized view name"));
    }

    #[test]
    fn quotes_schema_qualified_refresh_sql() {
        let view = MaterializedViewName::parse("public.pool_summary_hourly").unwrap();

        assert_eq!(
            view.refresh_sql(),
            "REFRESH MATERIALIZED VIEW CONCURRENTLY \"public\".\"pool_summary_hourly\""
        );
    }
}
