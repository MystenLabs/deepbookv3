use anyhow::{bail, Context};
use diesel::sql_types::{BigInt, Text};
use diesel::OptionalExtension;
use diesel::QueryableByName;
use diesel_async::RunQueryDsl;
use prometheus::{register_int_counter_vec_with_registry, IntCounterVec, Registry};
use std::sync::Arc;
use std::time::Duration;
use sui_futures::service::Service;
use sui_pg_db::Db;
use tokio::time::{interval, MissedTickBehavior};

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
struct MaterializedViewRefreshConfig {
    view_name: &'static str,
    source_pipeline: &'static str,
    bucket_ms: i64,
}

const MATERIALIZED_VIEWS_TO_REFRESH: &[MaterializedViewRefreshConfig] =
    &[MaterializedViewRefreshConfig {
        view_name: "net_deposits_hourly",
        source_pipeline: "balances",
        bucket_ms: 3_600_000,
    }];

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
    config: MaterializedViewRefreshConfig,
    name: String,
    quoted_name: String,
}

impl MaterializedViewName {
    fn parse(config: MaterializedViewRefreshConfig) -> anyhow::Result<Self> {
        let name = config.view_name.trim();
        if name.is_empty() {
            bail!("Invalid materialized view name: view name cannot be empty");
        }

        if config.bucket_ms <= 0 {
            bail!("Invalid materialized view bucket for `{name}`");
        }

        let mut quoted_parts = Vec::new();
        for part in name.split('.') {
            if !is_valid_identifier(part) {
                bail!("Invalid materialized view name `{name}`");
            }
            quoted_parts.push(format!("\"{part}\""));
        }

        Ok(Self {
            config,
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

    fn source_pipeline(&self) -> &str {
        self.config.source_pipeline
    }

    fn refresh_watermark_ms(&self, source_watermark_ms: i64) -> i64 {
        (source_watermark_ms / self.config.bucket_ms) * self.config.bucket_ms
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
        .copied()
        .map(MaterializedViewName::parse)
        .collect()
}

#[derive(QueryableByName)]
struct SourceWatermark {
    #[diesel(sql_type = BigInt)]
    timestamp_ms_hi_inclusive: i64,
}

async fn refresh_materialized_view_once(
    db: &Db,
    view: &MaterializedViewName,
) -> anyhow::Result<usize> {
    let mut conn = db
        .connect()
        .await
        .with_context(|| format!("Failed to connect to database for {} refresh", view.name()))?;

    let source_watermark = diesel::sql_query(
        r#"
        SELECT timestamp_ms_hi_inclusive
        FROM watermarks
        WHERE pipeline = $1
        "#,
    )
    .bind::<Text, _>(view.source_pipeline())
    .get_result::<SourceWatermark>(&mut conn)
    .await
    .optional()
    .with_context(|| {
        format!(
            "Failed to fetch {} source watermark for {} refresh",
            view.source_pipeline(),
            view.name()
        )
    })?
    .with_context(|| {
        format!(
            "Missing {} source watermark for {} refresh",
            view.source_pipeline(),
            view.name()
        )
    })?;

    let refresh_watermark_ms =
        view.refresh_watermark_ms(source_watermark.timestamp_ms_hi_inclusive);

    let refreshed_rows = diesel::sql_query(view.refresh_sql())
        .execute(&mut conn)
        .await
        .with_context(|| format!("Failed to refresh {} materialized view", view.name()))?;

    diesel::sql_query(
        r#"
        INSERT INTO materialized_view_refresh_watermarks (
            view_name,
            timestamp_ms_hi_inclusive,
            updated_at
        )
        VALUES ($1, $2, NOW())
        ON CONFLICT (view_name) DO UPDATE SET
            timestamp_ms_hi_inclusive = GREATEST(
                materialized_view_refresh_watermarks.timestamp_ms_hi_inclusive,
                EXCLUDED.timestamp_ms_hi_inclusive
            ),
            updated_at = NOW()
        "#,
    )
    .bind::<Text, _>(view.name())
    .bind::<BigInt, _>(refresh_watermark_ms)
    .execute(&mut conn)
    .await
    .with_context(|| format!("Failed to publish {} refresh watermark", view.name()))?;

    tracing::debug!(
        view = view.name(),
        refresh_watermark_ms,
        "Published materialized view refresh watermark"
    );

    Ok(refreshed_rows)
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
