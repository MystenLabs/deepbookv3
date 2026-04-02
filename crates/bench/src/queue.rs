// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

use crate::config::Config;
use crate::metrics::{BenchMetrics, RunStatus};
use crate::runner::create_sim_job;
use std::collections::HashMap;
use std::sync::Arc;
use tokio::sync::{mpsc, RwLock};
use tracing::{error, info};

#[derive(Debug, Clone, serde::Serialize)]
pub struct Job {
    pub run_id: String,
    pub sha: String,
}

#[derive(Debug, Clone, serde::Serialize)]
pub struct RunInfo {
    pub run_id: String,
    pub sha: String,
    pub status: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub error: Option<String>,
    #[serde(skip)]
    pub started_at: Option<std::time::Instant>,
}

pub type RunStore = Arc<RwLock<HashMap<String, RunInfo>>>;

pub fn new_run_store() -> RunStore {
    Arc::new(RwLock::new(HashMap::new()))
}

pub fn spawn_worker(
    mut rx: mpsc::Receiver<Job>,
    config: Config,
    metrics: Arc<BenchMetrics>,
    runs: RunStore,
) {
    tokio::spawn(async move {
        while let Some(job) = rx.recv().await {
            metrics.runs_total.inc();
            metrics.set_status(&job.sha, RunStatus::Running).await;

            info!(run_id = %job.run_id, sha = %job.sha, "creating benchmark job");
            {
                let mut store = runs.write().await;
                if let Some(info) = store.get_mut(&job.run_id) {
                    info.status = "running".to_string();
                    info.started_at = Some(std::time::Instant::now());
                }
            }

            match create_sim_job(&config, &job.run_id, &job.sha).await {
                Ok(job_name) => {
                    info!(
                        run_id = %job.run_id,
                        sha = %job.sha,
                        k8s_job = %job_name,
                        "benchmark job created, waiting for callback"
                    );
                }
                Err(e) => {
                    metrics.set_status(&job.sha, RunStatus::Failed).await;
                    update_run(&runs, &job.run_id, "failed").await;

                    error!(
                        run_id = %job.run_id,
                        sha = %job.sha,
                        error = %e,
                        "failed to create benchmark job"
                    );
                }
            }
        }
    });
}

async fn update_run(runs: &RunStore, run_id: &str, status: &str) {
    let mut store = runs.write().await;
    if let Some(info) = store.get_mut(run_id) {
        info.status = status.to_string();
    }
}
