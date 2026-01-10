use super::metrics::MarginMetrics;
use super::rpc_client::{MarginPoolState, MarginRpcClient};
use anyhow::Result;
use deepbook_schema::models::NewMarginPoolSnapshot;
use deepbook_schema::schema::{assets, margin_pool_created, margin_pool_snapshots};
use diesel::QueryDsl;
use diesel_async::RunQueryDsl;
use std::sync::Arc;
use std::time::Duration;
use sui_pg_db::Db;
use sui_sdk::SuiClientBuilder;
use tokio_util::sync::CancellationToken;
use url::Url;

#[derive(Debug, Clone)]
struct MarginPoolInfo {
    pool_id: String,
    asset_type: String,
    decimals: i16,
}

pub struct MarginPoller {
    db: Db,
    rpc_url: Url,
    margin_package_id: String,
    metrics: Arc<MarginMetrics>,
    poll_interval: Duration,
    cancellation_token: CancellationToken,
}

impl MarginPoller {
    pub fn new(
        db: Db,
        rpc_url: Url,
        margin_package_id: String,
        metrics: Arc<MarginMetrics>,
        poll_interval_secs: u64,
        cancellation_token: CancellationToken,
    ) -> Self {
        Self {
            db,
            rpc_url,
            margin_package_id,
            metrics,
            poll_interval: Duration::from_secs(poll_interval_secs),
            cancellation_token,
        }
    }

    pub async fn run(self) -> Result<()> {
        loop {
            tokio::select! {
                _ = self.cancellation_token.cancelled() => {
                    break;
                }
                _ = tokio::time::sleep(self.poll_interval) => {
                    if let Err(e) = self.poll_once().await {
                        eprintln!("[margin_poller] Failed to poll margin pool metrics: {}", e);
                        self.metrics.poll_errors.inc();
                    } else {
                        self.metrics.poll_success.inc();
                    }
                }
            }
        }

        Ok(())
    }

    async fn poll_once(&self) -> Result<()> {
        let timer = self.metrics.poll_duration.start_timer();

        // 1. Get all margin pools from DB
        let pools = self.get_margin_pools().await?;

        if pools.is_empty() {
            timer.observe_duration();
            return Ok(());
        }

        // 2. Create RPC client
        let sui_client = SuiClientBuilder::default()
            .build(self.rpc_url.as_str())
            .await?;
        let rpc_client = MarginRpcClient::new(sui_client, &self.margin_package_id)?;

        // 3. Query each pool and update metrics
        for pool_info in &pools {
            match rpc_client
                .get_pool_state(&pool_info.pool_id, &pool_info.asset_type)
                .await
            {
                Ok(state) => {
                    // Update Prometheus metrics with decimal normalization
                    self.metrics.update_pool_metrics(
                        &state.pool_id,
                        &state.asset_type,
                        state.total_supply,
                        state.total_borrow,
                        state.vault_balance,
                        state.supply_cap,
                        state.interest_rate,
                        state.available_withdrawal,
                        pool_info.decimals,
                    );

                    // Save snapshot to database
                    if let Err(e) = self.save_snapshot(&state).await {
                        eprintln!(
                            "[margin_poller] Failed to save snapshot for pool {}: {}",
                            state.pool_id, e
                        );
                    }
                }
                Err(e) => {
                    eprintln!(
                        "[margin_poller] Failed to query pool {}: {}",
                        pool_info.pool_id, e
                    );
                }
            }
        }

        timer.observe_duration();

        Ok(())
    }

    async fn get_margin_pools(&self) -> Result<Vec<MarginPoolInfo>> {
        let mut conn = self.db.connect().await?;

        // Get distinct margin pools from margin_pool_created table
        let pools: Vec<(String, String)> = margin_pool_created::table
            .select((
                margin_pool_created::margin_pool_id,
                margin_pool_created::asset_type,
            ))
            .distinct()
            .load(&mut conn)
            .await?;

        // Build a map of normalized asset_type -> decimals from the assets table
        let asset_decimals: Vec<(String, i16)> = assets::table
            .select((assets::asset_type, assets::decimals))
            .load(&mut conn)
            .await?;

        let decimals_map: std::collections::HashMap<String, i16> = asset_decimals
            .into_iter()
            .map(|(asset_type, decimals)| {
                // Normalize by removing 0x prefix for comparison
                let normalized = if asset_type.starts_with("0x") || asset_type.starts_with("0X") {
                    asset_type[2..].to_string()
                } else {
                    asset_type
                };
                (normalized, decimals)
            })
            .collect();

        Ok(pools
            .into_iter()
            .filter_map(|(pool_id, asset_type)| {
                // Normalize the margin pool asset_type for lookup
                let normalized = if asset_type.starts_with("0x") || asset_type.starts_with("0X") {
                    asset_type[2..].to_string()
                } else {
                    asset_type.clone()
                };

                decimals_map
                    .get(&normalized)
                    .map(|&decimals| MarginPoolInfo {
                        pool_id,
                        asset_type,
                        decimals,
                    })
            })
            .collect())
    }

    async fn save_snapshot(&self, state: &MarginPoolState) -> Result<()> {
        let mut conn = self.db.connect().await?;

        // Compute derived metrics
        let utilization_rate = if state.total_supply > 0 {
            state.total_borrow as f64 / state.total_supply as f64
        } else {
            0.0
        };

        let solvency_ratio = if state.total_borrow > 0 {
            Some(state.vault_balance as f64 / state.total_borrow as f64)
        } else {
            None
        };

        let available_liquidity_pct = if state.total_supply > 0 {
            Some((state.vault_balance as f64 / state.total_supply as f64) * 100.0)
        } else {
            None
        };

        let snapshot = NewMarginPoolSnapshot {
            margin_pool_id: state.pool_id.clone(),
            asset_type: state.asset_type.clone(),
            total_supply: state.total_supply as i64,
            total_borrow: state.total_borrow as i64,
            vault_balance: state.vault_balance as i64,
            supply_cap: state.supply_cap as i64,
            interest_rate: state.interest_rate as i64,
            available_withdrawal: state.available_withdrawal as i64,
            utilization_rate,
            solvency_ratio,
            available_liquidity_pct,
        };

        diesel::insert_into(margin_pool_snapshots::table)
            .values(&snapshot)
            .execute(&mut conn)
            .await?;

        Ok(())
    }
}
