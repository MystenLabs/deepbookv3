// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

use crate::config::Config;
use crate::metrics::{BenchMetrics, RunStatus};
use crate::runner::create_sim_job;
use crate::store::RunStore;
use std::sync::Arc;
use tokio::sync::mpsc;
use tracing::{error, info};

#[derive(Debug, Clone, serde::Serialize)]
pub struct Job {
    pub run_id: String,
    pub sha: String,
    pub max_rows: Option<u32>,
}

fn max_rows_label(max_rows: Option<u32>) -> String {
    max_rows.map(|n| n.to_string()).unwrap_or("all".to_string())
}

pub fn spawn_worker(
    mut rx: mpsc::Receiver<Job>,
    config: Config,
    metrics: Arc<BenchMetrics>,
    runs: Arc<RunStore>,
) {
    tokio::spawn(async move {
        while let Some(job) = rx.recv().await {
            let mr = max_rows_label(job.max_rows);
            metrics.runs_total.inc();

            info!(run_id = %job.run_id, sha = %job.sha, "creating benchmark job");
            let _ = runs.update_status(&job.run_id, "creating").await;

            match create_sim_job(&config, &job.run_id, &job.sha, job.max_rows).await {
                Ok(job_name) => {
                    info!(
                        run_id = %job.run_id,
                        sha = %job.sha,
                        k8s_job = %job_name,
                        "benchmark job created, waiting for callback"
                    );
                }
                Err(e) => {
                    metrics
                        .set_status(&job.sha, &job.run_id, &mr, RunStatus::Failed)
                        .await;
                    let _ = runs
                        .update_failed(&job.run_id, format!("job creation failed: {}", e))
                        .await;

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
