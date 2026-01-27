// Copyright (c) DeepBook V3. All rights reserved.
// SPDX-License-Identifier: Apache-2.0

use anyhow::Result;
use async_trait::async_trait;
use sui_types::full_checkpoint_content::CheckpointData;
use sui_types::messages_checkpoint::CheckpointSequenceNumber;

/// Trait for checkpoint storage backends
///
/// This abstraction allows switching between different checkpoint sources:
/// - Sui's official checkpoint bucket (sequential downloads)
/// - Walrus aggregator with blob-based storage (fast backfill)
#[async_trait]
pub trait CheckpointStorage: Send + Sync {
    /// Get a single checkpoint by sequence number
    async fn get_checkpoint(
        &self,
        checkpoint: CheckpointSequenceNumber,
    ) -> Result<CheckpointData>;

    /// Get multiple checkpoints in a range
    ///
    /// This is optimized for batch operations (e.g., backfills)
    async fn get_checkpoints(
        &self,
        range: std::ops::Range<CheckpointSequenceNumber>,
    ) -> Result<Vec<CheckpointData>>;

    /// Check if a checkpoint is available
    async fn has_checkpoint(
        &self,
        checkpoint: CheckpointSequenceNumber,
    ) -> Result<bool>;

    /// Get the latest checkpoint number available
    async fn get_latest_checkpoint(&self) -> Result<Option<CheckpointSequenceNumber>>;
}

/// Sui checkpoint storage (existing behavior)
///
/// Downloads checkpoints sequentially from Sui's official checkpoint bucket:
/// https://checkpoints.mainnet.sui.io/{checkpoint_num}.chk
pub struct SuiCheckpointStorage {
    remote_store_url: url::Url,
    client: reqwest::Client,
}

impl SuiCheckpointStorage {
    /// Create a new Sui checkpoint storage instance
    pub fn new(remote_store_url: url::Url) -> Self {
        Self {
            remote_store_url,
            client: reqwest::Client::builder()
                .timeout(std::time::Duration::from_secs(60))
                .build()
                .expect("Failed to create HTTP client"),
        }
    }

    /// Get the URL for a specific checkpoint
    fn checkpoint_url(&self, checkpoint: CheckpointSequenceNumber) -> String {
        format!("{}/{}.chk", self.remote_store_url, checkpoint)
    }
}

#[async_trait]
impl CheckpointStorage for SuiCheckpointStorage {
    async fn get_checkpoint(
        &self,
        checkpoint: CheckpointSequenceNumber,
    ) -> Result<CheckpointData> {
        let url = self.checkpoint_url(checkpoint);
        tracing::debug!("downloading checkpoint {} from: {}", checkpoint, url);

        let response = self
            .client
            .get(&url)
            .send()
            .await
            .map_err(|e| anyhow::anyhow!("failed to fetch checkpoint {} from Sui bucket: {}", checkpoint, e))?;

        if !response.status().is_success() {
            return Err(anyhow::anyhow!(
                "Sui bucket returned error status {} for checkpoint {}",
                response.status(),
                checkpoint
            ));
        }

        let bytes = response
            .bytes()
            .await
            .map_err(|e| anyhow::anyhow!("failed to read checkpoint {} response: {}", checkpoint, e))?;

        // Parse BCS checkpoint data
        let checkpoint_data = sui_storage::blob::Blob::from_bytes::<CheckpointData>(&bytes)
            .map_err(|e| anyhow::anyhow!("failed to deserialize checkpoint {}: {}", checkpoint, e))?;

        Ok(checkpoint_data)
    }

    async fn get_checkpoints(
        &self,
        range: std::ops::Range<CheckpointSequenceNumber>,
    ) -> Result<Vec<CheckpointData>> {
        // Download checkpoints sequentially
        let count = (range.end - range.start) as usize;
        let mut checkpoints = Vec::with_capacity(count);

        tracing::info!(
            "downloading checkpoints {}..{} from Sui bucket ({} checkpoints)",
            range.start,
            range.end - 1,
            count
        );

        for checkpoint in range {
            let cp = self.get_checkpoint(checkpoint).await?;
            checkpoints.push(cp);
        }

        tracing::info!("downloaded {} checkpoints from Sui bucket", checkpoints.len());

        Ok(checkpoints)
    }

    async fn has_checkpoint(
        &self,
        checkpoint: CheckpointSequenceNumber,
    ) -> Result<bool> {
        let url = self.checkpoint_url(checkpoint);

        let response = self
            .client
            .head(&url)
            .send()
            .await
            .map_err(|e| anyhow::anyhow!("failed to check checkpoint {}: {}", checkpoint, e))?;

        Ok(response.status().is_success())
    }

    async fn get_latest_checkpoint(&self) -> Result<Option<CheckpointSequenceNumber>> {
        // Try consecutive checkpoints to find latest
        // This is a simple approach - for production, consider using Sui RPC
        let mut low: u64 = 0;
        let mut high: u64 = 500_000_000; // Adjust based on network

        tracing::debug!("finding latest checkpoint using binary search");

        while low <= high {
            let mid = (low + high) / 2;

            if self.has_checkpoint(mid).await? {
                low = mid + 1;
            } else {
                high = mid - 1;
            }
        }

        Ok(if high > 0 { Some(high) } else { None })
    }
}
