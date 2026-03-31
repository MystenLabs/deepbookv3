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

const LABELS: &[&str] = &["sha"];
const MAX_ENTRIES: usize = 50;

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
    pub run_status: GaugeVec,
    pub run_duration_s: GaugeVec,
    pub runs_total: IntCounter,
    /// Ring buffer tracking SHA insertion order for eviction.
    ring: Arc<Mutex<VecDeque<String>>>,
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

    /// Track a SHA in the ring buffer, evicting the oldest if at capacity.
    async fn track_sha(&self, sha: &str) {
        let mut ring = self.ring.lock().await;

        // If this SHA is already tracked, don't double-add.
        if ring.iter().any(|s| s == sha) {
            return;
        }

        // Evict oldest if at capacity.
        if ring.len() >= MAX_ENTRIES {
            if let Some(old_sha) = ring.pop_front() {
                self.evict_sha(&old_sha);
            }
        }

        ring.push_back(sha.to_string());
    }

    /// Remove all metric label values for a SHA.
    fn evict_sha(&self, sha: &str) {
        let labels = &[sha];
        let _ = self.mint_gas_total.remove_label_values(labels);
        let _ = self.mint_gas_computation.remove_label_values(labels);
        let _ = self.mint_gas_storage.remove_label_values(labels);
        let _ = self.mint_gas_min.remove_label_values(labels);
        let _ = self.mint_gas_max.remove_label_values(labels);
        let _ = self.update_prices_gas.remove_label_values(labels);
        let _ = self.update_svi_gas.remove_label_values(labels);
        let _ = self.mint_latency_ms.remove_label_values(labels);
        let _ = self.run_status.remove_label_values(labels);
        let _ = self.run_duration_s.remove_label_values(labels);
    }

    pub async fn record_results(&self, sha: &str, results: &ResultsFile) {
        self.track_sha(sha).await;
        let labels = &[sha];

        if let Some(mint) = results.summary.by_action.get("mint") {
            self.mint_gas_total.with_label_values(labels).set(mint.gas.avg);
            self.mint_gas_min.with_label_values(labels).set(mint.gas.min);
            self.mint_gas_max.with_label_values(labels).set(mint.gas.max);
            self.mint_latency_ms.with_label_values(labels).set(mint.wall_ms.avg);
        }

        if !results.mints.is_empty() {
            let n = results.mints.len() as f64;
            let avg_computation: f64 =
                results.mints.iter().map(|m| m.computation_cost).sum::<f64>() / n;
            let avg_storage: f64 = results
                .mints
                .iter()
                .map(|m| m.storage_cost - m.storage_rebate)
                .sum::<f64>()
                / n;
            self.mint_gas_computation.with_label_values(labels).set(avg_computation);
            self.mint_gas_storage.with_label_values(labels).set(avg_storage);
        }

        if let Some(prices) = results.summary.by_action.get("update_prices") {
            self.update_prices_gas.with_label_values(labels).set(prices.gas.avg);
        }

        if let Some(svi) = results.summary.by_action.get("update_svi") {
            self.update_svi_gas.with_label_values(labels).set(svi.gas.avg);
        }
    }

    pub async fn set_status(&self, sha: &str, status: RunStatus) {
        self.track_sha(sha).await;
        self.run_status
            .with_label_values(&[sha])
            .set(status as i64 as f64);
    }

    pub async fn set_duration(&self, sha: &str, seconds: f64) {
        self.run_duration_s
            .with_label_values(&[sha])
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
