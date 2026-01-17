use prometheus::{
    register_gauge_vec_with_registry, register_histogram_with_registry,
    register_int_counter_with_registry, GaugeVec, Histogram, IntCounter, Registry,
};
use std::sync::Arc;

const LATENCY_SEC_BUCKETS: &[f64] = &[0.01, 0.05, 0.1, 0.25, 0.5, 1.0, 2.5, 5.0, 10.0, 30.0];

#[derive(Clone)]
pub struct MarginMetrics {
    // Per-pool metrics (labeled by pool_id and asset_type)
    pub total_supply: GaugeVec,
    pub total_borrow: GaugeVec,
    pub vault_balance: GaugeVec,
    pub supply_cap: GaugeVec,
    pub interest_rate: GaugeVec,
    pub available_withdrawal: GaugeVec,
    pub utilization_rate: GaugeVec,
    pub solvency_ratio: GaugeVec,
    pub available_liquidity_pct: GaugeVec,

    // Operational metrics
    pub poll_duration: Histogram,
    pub poll_errors: IntCounter,
    pub poll_success: IntCounter,
}

impl MarginMetrics {
    pub fn new(registry: &Registry) -> Arc<Self> {
        Arc::new(Self {
            total_supply: register_gauge_vec_with_registry!(
                "margin_pool_total_supply",
                "Total assets supplied to the margin pool (normalized by asset decimals)",
                &["pool_id", "asset_type"],
                registry
            )
            .unwrap(),

            total_borrow: register_gauge_vec_with_registry!(
                "margin_pool_total_borrow",
                "Total assets borrowed from the margin pool (normalized by asset decimals)",
                &["pool_id", "asset_type"],
                registry
            )
            .unwrap(),

            vault_balance: register_gauge_vec_with_registry!(
                "margin_pool_vault_balance",
                "Available liquidity in the margin pool vault (normalized by asset decimals)",
                &["pool_id", "asset_type"],
                registry
            )
            .unwrap(),

            supply_cap: register_gauge_vec_with_registry!(
                "margin_pool_supply_cap",
                "Maximum allowed supply for the margin pool (normalized by asset decimals)",
                &["pool_id", "asset_type"],
                registry
            )
            .unwrap(),

            interest_rate: register_gauge_vec_with_registry!(
                "margin_pool_interest_rate",
                "Current interest rate for the margin pool (normalized, 1.0 = 100%)",
                &["pool_id", "asset_type"],
                registry
            )
            .unwrap(),

            available_withdrawal: register_gauge_vec_with_registry!(
                "margin_pool_available_withdrawal",
                "Maximum amount withdrawable without hitting rate limits (normalized by asset decimals)",
                &["pool_id", "asset_type"],
                registry
            )
            .unwrap(),

            utilization_rate: register_gauge_vec_with_registry!(
                "margin_pool_utilization_rate",
                "Pool utilization rate (total_borrow / total_supply)",
                &["pool_id", "asset_type"],
                registry
            )
            .unwrap(),

            solvency_ratio: register_gauge_vec_with_registry!(
                "margin_pool_solvency_ratio",
                "Pool solvency ratio (vault_balance / total_borrow, >1 = healthy)",
                &["pool_id", "asset_type"],
                registry
            )
            .unwrap(),

            available_liquidity_pct: register_gauge_vec_with_registry!(
                "margin_pool_available_liquidity_pct",
                "Percentage of total supply available in vault",
                &["pool_id", "asset_type"],
                registry
            )
            .unwrap(),

            // Operational
            poll_duration: register_histogram_with_registry!(
                "margin_rpc_poll_duration_seconds",
                "Time taken to poll margin pool metrics via RPC",
                LATENCY_SEC_BUCKETS.to_vec(),
                registry
            )
            .unwrap(),

            poll_errors: register_int_counter_with_registry!(
                "margin_rpc_poll_errors_total",
                "Number of failed margin pool metric polls",
                registry
            )
            .unwrap(),

            poll_success: register_int_counter_with_registry!(
                "margin_rpc_poll_success_total",
                "Number of successful margin pool metric polls",
                registry
            )
            .unwrap(),
        })
    }

    pub fn update_pool_metrics(
        &self,
        pool_id: &str,
        asset_type: &str,
        total_supply: u64,
        total_borrow: u64,
        vault_balance: u64,
        supply_cap: u64,
        interest_rate: u64,
        available_withdrawal: u64,
        decimals: i16,
    ) {
        let divisor = 10_f64.powi(decimals as i32);

        self.total_supply
            .with_label_values(&[pool_id, asset_type])
            .set(total_supply as f64 / divisor);
        self.total_borrow
            .with_label_values(&[pool_id, asset_type])
            .set(total_borrow as f64 / divisor);
        self.vault_balance
            .with_label_values(&[pool_id, asset_type])
            .set(vault_balance as f64 / divisor);
        self.supply_cap
            .with_label_values(&[pool_id, asset_type])
            .set(supply_cap as f64 / divisor);
        // Interest rate uses 9 decimals
        self.interest_rate
            .with_label_values(&[pool_id, asset_type])
            .set(interest_rate as f64 / 1_000_000_000.0);
        self.available_withdrawal
            .with_label_values(&[pool_id, asset_type])
            .set(available_withdrawal as f64 / divisor);

        let utilization = if total_supply > 0 {
            total_borrow as f64 / total_supply as f64
        } else {
            0.0
        };
        self.utilization_rate
            .with_label_values(&[pool_id, asset_type])
            .set(utilization);

        let solvency = if total_borrow > 0 {
            vault_balance as f64 / total_borrow as f64
        } else {
            f64::INFINITY
        };
        if solvency.is_finite() {
            self.solvency_ratio
                .with_label_values(&[pool_id, asset_type])
                .set(solvency);
        }

        let liquidity_pct = if total_supply > 0 {
            (vault_balance as f64 / total_supply as f64) * 100.0
        } else {
            100.0
        };
        self.available_liquidity_pct
            .with_label_values(&[pool_id, asset_type])
            .set(liquidity_pct);
    }
}
