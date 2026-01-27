// Copyright (c) DeepBook V3. All rights reserved.
// SPDX-License-Identifier: Apache-2.0

use anyhow::{Context, Result};
use async_trait::async_trait;
use reqwest::Client;
use serde::Deserialize;
use std::collections::HashMap;
use std::fs;
use std::path::PathBuf;
use std::sync::Arc;
use tokio::sync::RwLock;
use sui_types::full_checkpoint_content::CheckpointData;
use sui_types::messages_checkpoint::CheckpointSequenceNumber;

use super::checkpoint_storage::CheckpointStorage;

/// Walrus blob metadata
#[derive(Debug, Clone, Deserialize)]
pub struct BlobMetadata {
    #[serde(rename = "blob_id")]
    pub blob_id: String,

    #[serde(rename = "start_checkpoint")]
    pub start_checkpoint: u64,

    #[serde(rename = "end_checkpoint")]
    pub end_checkpoint: u64,

    #[serde(rename = "entries_count")]
    pub entries_count: u64,

    pub total_size: u64,

    #[serde(default)]
    pub end_of_epoch: bool,

    #[serde(default)]
    pub expiry_epoch: u64,
}

/// Walrus blobs list response
#[derive(Debug, Deserialize)]
pub struct BlobsResponse {
    pub blobs: Vec<BlobMetadata>,
}

/// Walrus checkpoint response
#[derive(Debug, Deserialize)]
pub struct WalrusCheckpointResponse {
    pub checkpoint_number: u64,
    pub blob_id: String,
    pub object_id: String,
    pub index: u64,
    pub offset: u64,
    pub length: u64,
    #[serde(default)]
    pub content: Option<serde_json::Value>,
}

/// Blob cache entry
#[derive(Debug, Clone)]
struct BlobCacheEntry {
    pub blob_id: String,
    pub path: PathBuf,
    pub size: u64,
    pub accessed_at: std::time::Instant,
}

/// Walrus checkpoint storage (blob-based)
///
/// Downloads checkpoints from Walrus aggregator using blob-based storage:
/// 1. Fetch blob metadata from walrus-sui-archival service
/// 2. Download blobs (2-3 GB each) or use local cache
/// 3. Extract checkpoints from blobs
pub struct WalrusCheckpointStorage {
    archival_url: String,
    aggregator_url: String,
    client: Client,
    cache_dir: PathBuf,
    cache_max_size: u64,
    cache: Arc<RwLock<HashMap<String, BlobCacheEntry>>>,
    metadata: Vec<BlobMetadata>,
}

impl WalrusCheckpointStorage {
    /// Create a new Walrus checkpoint storage instance
    pub fn new(
        archival_url: String,
        aggregator_url: String,
        cache_dir: PathBuf,
        cache_max_size: u64,
    ) -> Result<Self> {
        // Create cache directory
        fs::create_dir_all(&cache_dir)
            .with_context(|| format!("failed to create cache directory: {}", cache_dir.display()))?;

        Ok(Self {
            archival_url,
            aggregator_url,
            client: Client::builder()
                .timeout(std::time::Duration::from_secs(300)) // 5 min timeout for blobs
                .build()
                .expect("Failed to create HTTP client"),
            cache_dir,
            cache_max_size: cache_max_size * 1024 * 1024 * 1024, // Convert GB to bytes
            cache: Arc::new(RwLock::new(HashMap::new())),
            metadata: Vec::new(),
        })
    }

    /// Initialize by fetching blob metadata from archival service
    pub async fn initialize(&mut self) -> Result<()> {
        tracing::info!("fetching Walrus blob metadata from: {}", self.archival_url);

        let url = format!("{}/v1/app_blobs", self.archival_url);
        let response = self
            .client
            .get(&url)
            .send()
            .await
            .with_context(|| format!("failed to fetch blobs from: {}", url))?;

        if !response.status().is_success() {
            return Err(anyhow::anyhow!(
                "Walrus archival service returned error status {}",
                response.status()
            ));
        }

        let blobs: BlobsResponse = response
            .json()
            .await
            .context("failed to parse blobs response")?;

        self.metadata = blobs.blobs;

        tracing::info!(
            "fetched {} Walrus blobs covering checkpoints {}..{}",
            self.metadata.len(),
            self.metadata.first().map(|b| b.start_checkpoint).unwrap_or(0),
            self.metadata.last().map(|b| b.end_checkpoint).unwrap_or(0)
        );

        // Load existing cache
        self.load_cache()?;

        Ok(())
    }

    /// Find blob containing a specific checkpoint
    fn find_blob_for_checkpoint(&self, checkpoint: u64) -> Option<&BlobMetadata> {
        self.metadata
            .iter()
            .find(|blob| checkpoint >= blob.start_checkpoint && checkpoint <= blob.end_checkpoint)
    }

    /// Get or download blob (with caching)
    async fn get_or_download_blob(&self, blob_id: &str, total_size: u64) -> Result<Vec<u8>> {
        // Check cache
        {
            let cache = self.cache.read().await;
            if let Some(entry) = cache.get(blob_id) {
                if entry.path.exists() {
                    tracing::debug!(
                        "using cached blob: {} ({} MB)",
                        blob_id,
                        entry.size / 1024 / 1024
                    );
                    return Ok(fs::read(&entry.path).with_context(|| {
                        format!("failed to read cached blob: {}", entry.path.display())
                    })?);
                }
            }
        }

        // Download blob
        let size_mb = total_size / 1024 / 1024;
        tracing::info!("downloading Walrus blob: {} ({} MB)", blob_id, size_mb);

        let url = format!(
            "{}/v1/blobs/{}/byte-range?start=0&length={}",
            self.aggregator_url, blob_id, total_size
        );

        let start = std::time::Instant::now();
        let response = self
            .client
            .get(&url)
            .send()
            .await
            .with_context(|| format!("failed to download blob from: {}", url))?;

        if !response.status().is_success() {
            return Err(anyhow::anyhow!(
                "Walrus aggregator returned error status {} for blob {}",
                response.status(),
                blob_id
            ));
        }

        let blob_data = response
            .bytes()
            .await
            .with_context(|| "failed to read blob response")?
            .to_vec();

        let elapsed = start.elapsed();

        let throughput_mbps = (total_size as f64) / 1024.0 / 1024.0 / elapsed.as_secs_f64();
        tracing::info!(
            "downloaded blob {} in {:.2}s ({:.2} MB/s)",
            blob_id,
            elapsed.as_secs_f64(),
            throughput_mbps
        );

        // Evict if cache is full
        self.evict_cache_if_needed(total_size).await?;

        // Write to cache
        let cache_path = self.cache_dir.join(format!("{}.bin", blob_id));
        fs::write(&cache_path, &blob_data).with_context(|| {
            format!("failed to write blob to cache: {}", cache_path.display())
        })?;

        // Add to cache
        {
            let mut cache = self.cache.write().await;
            cache.insert(
                blob_id.to_string(),
                BlobCacheEntry {
                    blob_id: blob_id.to_string(),
                    path: cache_path,
                    size: total_size,
                    accessed_at: std::time::Instant::now(),
                },
            );
        }

        Ok(blob_data)
    }

    /// Evict old cache entries if needed (LRU)
    async fn evict_cache_if_needed(&self, needed_size: u64) -> Result<()> {
        let cache_size: u64 = {
            let cache = self.cache.read().await;
            cache.values().map(|e| e.size).sum()
        };

        let target_size = self.cache_max_size / 2; // Evict to 50%

        if cache_size + needed_size <= self.cache_max_size {
            return Ok(());
        }

        tracing::info!(
            "evicting cache (current: {} MB, needed: {} MB, max: {} MB)",
            cache_size / 1024 / 1024,
            needed_size / 1024 / 1024,
            self.cache_max_size / 1024 / 1024
        );

        // Sort by last accessed time
        let mut entries: Vec<_> = {
            let cache = self.cache.read().await;
            cache.values().cloned().collect()
        };
        entries.sort_by_key(|e| e.accessed_at);

        // Evict oldest entries
        let mut evicted = 0;
        let mut cache = self.cache.write().await;

        for entry in entries {
            let current_size: u64 = cache.values().map(|e| e.size).sum();

            if current_size <= target_size {
                break;
            }

            if let Err(e) = fs::remove_file(&entry.path) {
                tracing::warn!("failed to evict blob {}: {}", entry.blob_id, e);
            } else {
                cache.remove(&entry.blob_id);
                evicted += 1;
                tracing::debug!(
                    "evicted blob: {} ({} MB)",
                    entry.blob_id,
                    entry.size / 1024 / 1024
                );
            }
        }

        tracing::info!("evicted {} blobs from cache", evicted);

        Ok(())
    }

    /// Load existing cache entries from disk
    fn load_cache(&self) -> Result<()> {
        if !self.cache_dir.exists() {
            return Ok(());
        }

        tracing::info!(
            "loading Walrus blob cache from: {}",
            self.cache_dir.display()
        );

        let mut loaded = 0;
        let mut total_size = 0;

        for entry in fs::read_dir(&self.cache_dir).with_context(|| {
            format!(
                "failed to read cache directory: {}",
                self.cache_dir.display()
            )
        })? {
            let entry = entry?;
            let path = entry.path();

            if path.extension().map_or(false, |ext| ext == "bin") {
                let blob_id = path
                    .file_stem()
                    .and_then(|s| s.to_str())
                    .ok_or_else(|| anyhow::anyhow!("invalid cache file name: {}", path.display()))?
                    .to_string();

                let metadata = fs::metadata(&path).with_context(|| {
                    format!("failed to read cache file metadata: {}", path.display())
                })?;
                let size = metadata.len();

                // Add to cache via runtime (for RwLock)
                let cache = Arc::clone(&self.cache);
                tokio::task::block_in_place(|| {
                    let mut cache = cache.blocking_write();
                    cache.insert(
                        blob_id.clone(),
                        BlobCacheEntry {
                            blob_id,
                            path,
                            size,
                            accessed_at: std::time::Instant::now(),
                        },
                    );
                    Ok::<_, anyhow::Error>(())
                })?;

                loaded += 1;
                total_size += size;
            }
        }

        tracing::info!(
            "loaded {} cached blobs ({} MB)",
            loaded,
            total_size / 1024 / 1024
        );

        Ok(())
    }
}

#[async_trait]
impl CheckpointStorage for WalrusCheckpointStorage {
    async fn get_checkpoint(
        &self,
        checkpoint: CheckpointSequenceNumber,
    ) -> Result<CheckpointData> {
        // For individual checkpoint, use Walrus API to get offset/length
        let url = format!(
            "{}/v1/app_checkpoint?checkpoint={}",
            self.archival_url, checkpoint
        );

        tracing::debug!("fetching checkpoint {} from: {}", checkpoint, url);

        let response = self
            .client
            .get(&url)
            .send()
            .await
            .with_context(|| format!("failed to fetch checkpoint {} metadata", checkpoint))?;

        if !response.status().is_success() {
            if response.status() == 404 {
                return Err(anyhow::anyhow!(
                    "checkpoint {} not found in Walrus archival service",
                    checkpoint
                ));
            }
            return Err(anyhow::anyhow!(
                "Walrus archival service returned error status {} for checkpoint {}",
                response.status(),
                checkpoint
            ));
        }

        let checkpoint_info: WalrusCheckpointResponse = response
            .json()
            .await
            .context("failed to parse checkpoint metadata")?;

        // Fetch checkpoint byte range from blob
        let blob_url = format!(
            "{}/v1/blobs/{}/byte-range?start={}&length={}",
            self.aggregator_url,
            checkpoint_info.blob_id,
            checkpoint_info.offset,
            checkpoint_info.length
        );

        tracing::debug!("downloading checkpoint {} from blob: {}", checkpoint, blob_url);

        let response = self
            .client
            .get(&blob_url)
            .send()
            .await
            .with_context(|| format!("failed to download checkpoint {} from blob", checkpoint))?;

        if !response.status().is_success() {
            return Err(anyhow::anyhow!(
                "Walrus aggregator returned error status {} for checkpoint {}",
                response.status(),
                checkpoint
            ));
        }

        let blob_data = response
            .bytes()
            .await
            .context("failed to read checkpoint data")?;

        // Parse BCS checkpoint data
        let checkpoint_data = sui_storage::blob::Blob::from_bytes::<CheckpointData>(&blob_data)
            .with_context(|| format!("failed to deserialize checkpoint {}", checkpoint))?;

        Ok(checkpoint_data)
    }

    async fn get_checkpoints(
        &self,
        range: std::ops::Range<CheckpointSequenceNumber>,
    ) -> Result<Vec<CheckpointData>> {
        // For initial implementation, download checkpoints individually
        // (Future optimization: download full blobs and extract locally)

        let count = (range.end - range.start) as usize;

        if count > 1000 {
            tracing::warn!(
                "downloading {} checkpoints individually from Walrus (consider blob optimization for >1000 checkpoints)",
                count
            );
        }

        tracing::info!(
            "downloading checkpoints {}..{} from Walrus ({} checkpoints)",
            range.start,
            range.end - 1,
            count
        );

        let mut checkpoints = Vec::with_capacity(count);

        for checkpoint in range {
            let cp = self.get_checkpoint(checkpoint).await?;
            checkpoints.push(cp);
        }

        // Sort by checkpoint number
        checkpoints.sort_by_key(|cp| cp.checkpoint_summary.sequence_number);

        tracing::info!("downloaded {} checkpoints from Walrus", checkpoints.len());

        Ok(checkpoints)
    }

    async fn has_checkpoint(
        &self,
        checkpoint: CheckpointSequenceNumber,
    ) -> Result<bool> {
        // Check if any blob contains this checkpoint
        Ok(self.find_blob_for_checkpoint(checkpoint).is_some())
    }

    async fn get_latest_checkpoint(&self) -> Result<Option<CheckpointSequenceNumber>> {
        // Find highest checkpoint in blob metadata
        self.metadata
            .iter()
            .map(|blob| blob.end_checkpoint)
            .max()
            .map(|cp| Ok::<CheckpointSequenceNumber, anyhow::Error>(cp))
            .transpose()
            .context("failed to find latest checkpoint in Walrus blobs")
    }
}
