// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

use anyhow::{Context, Result};
use prometheus::{
    register_gauge_vec_with_registry, register_int_counter_with_registry, GaugeVec, IntCounter,
    Registry,
};
use serde::Deserialize;
use std::collections::{HashMap, VecDeque};
use std::sync::Arc;
use tokio::sync::Mutex;

const LABELS: &[&str] = &["sha", "run_id", "max_rows"];
/// Ring buffer cap. max_rows is constrained to "200" or "all" by the CI workflow,
/// so cardinality is bounded by MAX_ENTRIES * 2 label combinations at most.
const MAX_ENTRIES: usize = 50;

#[derive(Clone)]
struct RunLabels {
    sha: String,
    run_id: String,
    max_rows: String,
}

#[derive(Clone)]
pub struct BenchMetrics {
    pub mint_gas_total: GaugeVec,
    pub mint_gas_computation: GaugeVec,
    pub mint_gas_storage: GaugeVec,
    pub mint_gas_min: GaugeVec,
    pub mint_gas_max: GaugeVec,
    pub update_prices_gas: GaugeVec,
    pub update_svi_gas: GaugeVec,
    pub mint_latency_ms: GaugeVec,
    pub total_txs: GaugeVec,
    pub run_status: GaugeVec,
    pub run_duration_s: GaugeVec,
    pub runs_total: IntCounter,
    ring: Arc<Mutex<VecDeque<RunLabels>>>,
}

impl BenchMetrics {
    pub fn new(registry: &Registry) -> Arc<Self> {
        Arc::new(Self {
            mint_gas_total: register_gauge_vec_with_registry!(
                "predict_bench_mint_gas_total",
                "Average total gas per mint (MIST)",
                LABELS,
                registry
            )
            .unwrap(),
            mint_gas_computation: register_gauge_vec_with_registry!(
                "predict_bench_mint_gas_computation",
                "Average computation cost per mint",
                LABELS,
                registry
            )
            .unwrap(),
            mint_gas_storage: register_gauge_vec_with_registry!(
                "predict_bench_mint_gas_storage",
                "Average net storage cost per mint",
                LABELS,
                registry
            )
            .unwrap(),
            mint_gas_min: register_gauge_vec_with_registry!(
                "predict_bench_mint_gas_min",
                "Minimum gas across all mints",
                LABELS,
                registry
            )
            .unwrap(),
            mint_gas_max: register_gauge_vec_with_registry!(
                "predict_bench_mint_gas_max",
                "Maximum gas across all mints",
                LABELS,
                registry
            )
            .unwrap(),
            update_prices_gas: register_gauge_vec_with_registry!(
                "predict_bench_update_prices_gas",
                "Average gas for update_prices",
                LABELS,
                registry
            )
            .unwrap(),
            update_svi_gas: register_gauge_vec_with_registry!(
                "predict_bench_update_svi_gas",
                "Average gas for update_svi",
                LABELS,
                registry
            )
            .unwrap(),
            mint_latency_ms: register_gauge_vec_with_registry!(
                "predict_bench_mint_latency_ms",
                "Average wall-clock latency per mint (ms)",
                LABELS,
                registry
            )
            .unwrap(),
            total_txs: register_gauge_vec_with_registry!(
                "predict_bench_total_txs",
                "Total transactions executed in the benchmark",
                LABELS,
                registry
            )
            .unwrap(),
            run_status: register_gauge_vec_with_registry!(
                "predict_bench_run_status",
                "Run status: 1=running, 2=success, 3=failed",
                LABELS,
                registry
            )
            .unwrap(),
            run_duration_s: register_gauge_vec_with_registry!(
                "predict_bench_run_duration_s",
                "Total run duration in seconds",
                LABELS,
                registry
            )
            .unwrap(),
            runs_total: register_int_counter_with_registry!(
                "predict_bench_runs_total",
                "Total benchmark runs triggered",
                registry
            )
            .unwrap(),
            ring: Arc::new(Mutex::new(VecDeque::with_capacity(MAX_ENTRIES))),
        })
    }

    async fn track_run(&self, sha: &str, run_id: &str, max_rows: &str) {
        let mut ring = self.ring.lock().await;

        if ring.iter().any(|r| r.run_id == run_id) {
            return;
        }

        if ring.len() >= MAX_ENTRIES {
            if let Some(old) = ring.pop_front() {
                self.evict(&old);
            }
        }

        ring.push_back(RunLabels {
            sha: sha.to_string(),
            run_id: run_id.to_string(),
            max_rows: max_rows.to_string(),
        });
    }

    fn evict(&self, labels: &RunLabels) {
        let l = &[
            labels.sha.as_str(),
            labels.run_id.as_str(),
            labels.max_rows.as_str(),
        ];
        let _ = self.mint_gas_total.remove_label_values(l);
        let _ = self.mint_gas_computation.remove_label_values(l);
        let _ = self.mint_gas_storage.remove_label_values(l);
        let _ = self.mint_gas_min.remove_label_values(l);
        let _ = self.mint_gas_max.remove_label_values(l);
        let _ = self.update_prices_gas.remove_label_values(l);
        let _ = self.update_svi_gas.remove_label_values(l);
        let _ = self.mint_latency_ms.remove_label_values(l);
        let _ = self.total_txs.remove_label_values(l);
        let _ = self.run_status.remove_label_values(l);
        let _ = self.run_duration_s.remove_label_values(l);
    }

    fn labels<'a>(sha: &'a str, run_id: &'a str, max_rows: &'a str) -> [&'a str; 3] {
        [sha, run_id, max_rows]
    }

    pub async fn record_results(
        &self,
        sha: &str,
        run_id: &str,
        max_rows: &str,
        results: &ResultsFile,
    ) {
        self.track_run(sha, run_id, max_rows).await;
        let l = Self::labels(sha, run_id, max_rows);

        self.total_txs
            .with_label_values(&l)
            .set(results.summary.total_txs as f64);

        if let Some(mint) = results.summary.by_action.get("mint") {
            self.mint_gas_total.with_label_values(&l).set(mint.gas.avg);
            self.mint_gas_min.with_label_values(&l).set(mint.gas.min);
            self.mint_gas_max.with_label_values(&l).set(mint.gas.max);
            self.mint_latency_ms
                .with_label_values(&l)
                .set(mint.wall_ms.avg);
        }

        if !results.mints.is_empty() {
            let n = results.mints.len() as f64;
            let avg_computation: f64 = results
                .mints
                .iter()
                .map(|m| m.computation_cost)
                .sum::<f64>()
                / n;
            let avg_storage: f64 = results
                .mints
                .iter()
                .map(|m| m.storage_cost - m.storage_rebate)
                .sum::<f64>()
                / n;
            self.mint_gas_computation
                .with_label_values(&l)
                .set(avg_computation);
            self.mint_gas_storage.with_label_values(&l).set(avg_storage);
        }

        if let Some(prices) = results.summary.by_action.get("update_prices") {
            self.update_prices_gas
                .with_label_values(&l)
                .set(prices.gas.avg);
        }

        if let Some(svi) = results.summary.by_action.get("update_svi") {
            self.update_svi_gas.with_label_values(&l).set(svi.gas.avg);
        }
    }

    pub async fn set_status(&self, sha: &str, run_id: &str, max_rows: &str, status: RunStatus) {
        self.track_run(sha, run_id, max_rows).await;
        self.run_status
            .with_label_values(&Self::labels(sha, run_id, max_rows))
            .set(status as i64 as f64);
    }

    pub async fn set_duration(&self, sha: &str, run_id: &str, max_rows: &str, seconds: f64) {
        self.run_duration_s
            .with_label_values(&Self::labels(sha, run_id, max_rows))
            .set(seconds);
    }
}

#[derive(Debug, Clone, Copy)]
#[repr(u8)]
pub enum RunStatus {
    Running = 1,
    Success = 2,
    Failed = 3,
}

// -- results.json schema (matches simulations/src/shared.ts) --

#[derive(Debug, Deserialize)]
pub struct ResultsFile {
    pub summary: Summary,
    pub mints: Vec<MintResult>,
}

#[derive(Debug, Deserialize)]
pub struct Summary {
    #[serde(rename = "totalTxs")]
    pub total_txs: u64,
    #[serde(rename = "byAction")]
    pub by_action: HashMap<String, ActionSummary>,
}

#[derive(Debug, Deserialize)]
pub struct ActionSummary {
    pub gas: StatGroup,
    #[serde(rename = "wallMs")]
    pub wall_ms: StatGroup,
}

#[derive(Debug, Deserialize)]
pub struct StatGroup {
    pub avg: f64,
    pub min: f64,
    pub max: f64,
}

#[derive(Debug, Deserialize)]
pub struct MintResult {
    #[serde(rename = "computationCost")]
    pub computation_cost: f64,
    #[serde(rename = "storageCost")]
    pub storage_cost: f64,
    #[serde(rename = "storageRebate")]
    pub storage_rebate: f64,
}

pub fn parse_results(json: &str) -> Result<ResultsFile> {
    serde_json::from_str(json).context("parse results.json")
}
