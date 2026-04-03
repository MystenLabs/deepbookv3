// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

use anyhow::{Context, Result};
use redis::AsyncCommands;
use serde::{Deserialize, Serialize};
use std::sync::Arc;

/// Run info stored in Redis. Serialized as JSON.
/// Key: `run:{run_id}`
/// TTL: 24 hours
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct RunInfo {
    pub run_id: String,
    pub sha: String,
    pub status: String,
    /// "all" or a number like "200".
    pub max_rows: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub error: Option<String>,
    /// Unix timestamp (seconds) when the run started executing.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub started_at_ts: Option<u64>,
}

const KEY_PREFIX: &str = "run:";
const TTL_SECS: u64 = 86400; // 24 hours

#[derive(Clone)]
pub struct RunStore {
    conn: redis::aio::ConnectionManager,
}

impl RunStore {
    pub async fn new(redis_url: &str) -> Result<Arc<Self>> {
        let client = redis::Client::open(redis_url).context("parse redis URL")?;
        let mut last_err = None;
        for attempt in 1..=30 {
            match client.get_connection_manager().await {
                Ok(conn) => {
                    tracing::info!("connected to redis");
                    return Ok(Arc::new(Self { conn }));
                }
                Err(e) => {
                    tracing::warn!(attempt, "redis not ready, retrying in 2s: {}", e);
                    last_err = Some(e);
                    tokio::time::sleep(std::time::Duration::from_secs(2)).await;
                }
            }
        }
        Err(last_err.unwrap()).context("connect to redis after 30 attempts")
    }

    fn key(run_id: &str) -> String {
        format!("{}{}", KEY_PREFIX, run_id)
    }

    pub async fn insert(&self, info: &RunInfo) -> Result<()> {
        let mut conn = self.conn.clone();
        let json = serde_json::to_string(info)?;
        conn.set_ex::<_, _, ()>(Self::key(&info.run_id), json, TTL_SECS)
            .await
            .context("redis SET")?;
        Ok(())
    }

    pub async fn get(&self, run_id: &str) -> Result<Option<RunInfo>> {
        let mut conn = self.conn.clone();
        let val: Option<String> = conn.get(Self::key(run_id)).await.context("redis GET")?;
        match val {
            Some(json) => Ok(Some(serde_json::from_str(&json)?)),
            None => Ok(None),
        }
    }

    pub async fn update_status(&self, run_id: &str, status: &str) -> Result<()> {
        if let Some(mut info) = self.get(run_id).await? {
            info.status = status.to_string();
            self.insert(&info).await?;
        } else {
            tracing::warn!(run_id, "update_status: run not found");
        }
        Ok(())
    }

    pub async fn update_started(&self, run_id: &str) -> Result<()> {
        if let Some(mut info) = self.get(run_id).await? {
            info.status = "running".to_string();
            info.started_at_ts = Some(
                std::time::SystemTime::now()
                    .duration_since(std::time::UNIX_EPOCH)
                    .unwrap()
                    .as_secs(),
            );
            self.insert(&info).await?;
        } else {
            tracing::warn!(run_id, "update_started: run not found");
        }
        Ok(())
    }

    pub async fn update_failed(&self, run_id: &str, error: String) -> Result<()> {
        if let Some(mut info) = self.get(run_id).await? {
            info.status = "failed".to_string();
            info.error = Some(error);
            self.insert(&info).await?;
        } else {
            tracing::warn!(run_id, "update_failed: run not found");
        }
        Ok(())
    }

    pub async fn update_success(&self, run_id: &str) -> Result<()> {
        if let Some(mut info) = self.get(run_id).await? {
            info.status = "success".to_string();
            self.insert(&info).await?;
        } else {
            tracing::warn!(run_id, "update_success: run not found");
        }
        Ok(())
    }

    /// Returns elapsed seconds since started_at_ts, if set.
    pub fn elapsed_secs(info: &RunInfo) -> Option<f64> {
        let started = info.started_at_ts?;
        let now = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_secs();
        Some((now - started) as f64)
    }
}
