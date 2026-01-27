// Copyright (c) DeepBook V3. All rights reserved.
// SPDX-License-Identifier: Apache-2.0

use anyhow::{Context, Result};
use async_trait::async_trait;
use byteorder::{LittleEndian, ReadBytesExt};
use futures::stream::{self, StreamExt};
use reqwest::Client;
use serde::Deserialize;
use std::collections::HashMap;
use std::fs;
use std::io::{Cursor, Read};
use std::path::PathBuf;
use std::sync::Arc;
use sui_types::full_checkpoint_content::CheckpointData;
use sui_types::messages_checkpoint::CheckpointSequenceNumber;
use tokio::sync::RwLock;

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

/// Parsed index entry from a blob
#[derive(Debug, Clone)]
struct BlobIndexEntry {
    #[allow(dead_code)]
    pub checkpoint_number: u64,
    pub offset: u64,
    pub length: u64,
}

/// Walrus checkpoint storage (blob-based)
///
/// Downloads checkpoints from Walrus aggregator using blob-based storage:
/// 1. Fetch blob metadata from walrus-sui-archival service
/// 2. Download blobs (2-3 GB each) or use local cache
/// 3. Extract checkpoints from blobs using internal index
pub struct WalrusCheckpointStorage {
    archival_url: String,
    aggregator_url: String,
    client: Client,
    // Cache for parsed blob indices: blob_id -> (checkpoint_number -> entry)
    index_cache: Arc<RwLock<HashMap<String, HashMap<u64, BlobIndexEntry>>>>,
    metadata: Vec<BlobMetadata>,
}

impl WalrusCheckpointStorage {
    /// Create a new Walrus checkpoint storage instance
    pub fn new(
        archival_url: String,
        aggregator_url: String,
        _cache_dir: PathBuf,
        _cache_max_size: u64, // Unused in partial download strategy
    ) -> Result<Self> {
        Ok(Self {
            archival_url,
            aggregator_url,
            client: Client::builder()
                .timeout(std::time::Duration::from_secs(30)) // 30s timeout is enough for small ranges
                .build()
                .expect("Failed to create HTTP client"),
            index_cache: Arc::new(RwLock::new(HashMap::new())),
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

        Ok(())
    }

    /// Find blob containing a specific checkpoint
    fn find_blob_for_checkpoint(&self, checkpoint: u64) -> Option<&BlobMetadata> {
        self.metadata
            .iter()
            .find(|blob| checkpoint >= blob.start_checkpoint && checkpoint <= blob.end_checkpoint)
    }

    /// Load (or fetch) the index for a blob
    async fn load_blob_index(&self, blob_id: &str) -> Result<HashMap<u64, BlobIndexEntry>> {
        // 1. Check memory cache
        {
            let cache = self.index_cache.read().await;
            if let Some(index) = cache.get(blob_id) {
                return Ok(index.clone());
            }
        }

        tracing::info!("fetching index for blob {}", blob_id);

        // 2. Fetch Footer (last 24 bytes)
        let url = format!("{}/v1/blobs/{}", self.aggregator_url, blob_id);
        let response = self.client.get(&url)
            .header("Range", "bytes=-24")
            .send()
            .await
            .with_context(|| format!("failed to fetch footer for blob {}", blob_id))?;

        if !response.status().is_success() {
             return Err(anyhow::anyhow!(
                "failed to fetch footer: status {}", response.status()
            ));
        }

        let footer_bytes = response.bytes().await?;
        if footer_bytes.len() != 24 {
             return Err(anyhow::anyhow!("invalid footer length: {}", footer_bytes.len()));
        }

        // Parse Footer
        let mut cursor = Cursor::new(&footer_bytes);
        let magic = cursor.read_u32::<LittleEndian>()?;
        if magic != 0x574c4244 { // "DBLW"
            return Err(anyhow::anyhow!("invalid blob footer magic: {:x}", magic));
        }

        let _version = cursor.read_u32::<LittleEndian>()?;
        let index_start_offset = cursor.read_u64::<LittleEndian>()?;
        let count = cursor.read_u32::<LittleEndian>()?;
        // CRC ignored for now

        tracing::debug!("blob {} index: count={}, start={}", blob_id, count, index_start_offset);

        // 3. Fetch Index (from start offset to end)
        let response = self.client.get(&url)
            .header("Range", format!("bytes={}-", index_start_offset))
            .send()
            .await
            .with_context(|| format!("failed to fetch index for blob {}", blob_id))?;

        if !response.status().is_success() {
             return Err(anyhow::anyhow!("failed to fetch index: status {}", response.status()));
        }

        let index_bytes = response.bytes().await?;
        
        // Parse Index
        let mut cursor = Cursor::new(&index_bytes);
        let mut index = HashMap::with_capacity(count as usize);

        for _ in 0..count {
            let name_len = cursor.read_u32::<LittleEndian>()?;
            let mut name_bytes = vec![0u8; name_len as usize];
            cursor.read_exact(&mut name_bytes)?;

            let name_str = String::from_utf8(name_bytes)
                .context("invalid utf8 in checkpoint name")?;
            let checkpoint_number = name_str
                .parse::<u64>()
                .context("invalid checkpoint number string")?;

            let offset = cursor.read_u64::<LittleEndian>()?;
            let length = cursor.read_u64::<LittleEndian>()?;
            let _entry_crc = cursor.read_u32::<LittleEndian>()?;

            index.insert(
                checkpoint_number,
                BlobIndexEntry {
                    checkpoint_number,
                    offset,
                    length,
                },
            );
        }

        // 4. Update Cache
        {
            let mut cache = self.index_cache.write().await;
            cache.insert(blob_id.to_string(), index.clone());
        }

        Ok(index)
    }

    /// Download a specific range from a blob
    async fn download_range(&self, blob_id: &str, start: u64, length: u64) -> Result<Vec<u8>> {
        let url = format!("{}/v1/blobs/{}", self.aggregator_url, blob_id);
        let end = start + length - 1;
        
        tracing::debug!("downloading range {}-{} (len {}) from {}", start, end, length, blob_id);

        let response = self.client.get(&url)
            .header("Range", format!("bytes={}-{}", start, end))
            .send()
            .await?;

        if !response.status().is_success() {
             return Err(anyhow::anyhow!("failed to fetch range: status {}", response.status()));
        }

        let bytes = response.bytes().await?.to_vec();
        if bytes.len() as u64 != length {
             // It's possible we got less if we hit EOF, but for checkpoints we expect exact match
             // unless the index was wrong.
             tracing::warn!("expected {} bytes, got {}", length, bytes.len());
        }

        Ok(bytes)
    }
}

#[async_trait]
impl CheckpointStorage for WalrusCheckpointStorage {
    async fn get_checkpoint(
        &self,
        checkpoint: CheckpointSequenceNumber,
    ) -> Result<CheckpointData> {
        // Find blob containing this checkpoint
        let blob = self
            .find_blob_for_checkpoint(checkpoint)
            .ok_or_else(|| anyhow::anyhow!("no blob found for checkpoint {}", checkpoint))?;

        // Load index (cached or fetch)
        let index = self.load_blob_index(&blob.blob_id).await?;

        // Find checkpoint in index
        let entry = index.get(&checkpoint)
            .ok_or_else(|| anyhow::anyhow!("checkpoint {} not found in blob index", checkpoint))?;

        // Download checkpoint data
        let cp_bytes = self.download_range(&blob.blob_id, entry.offset, entry.length).await?;

        // Deserialize
        let checkpoint = sui_storage::blob::Blob::from_bytes::<CheckpointData>(&cp_bytes)
            .with_context(|| format!("failed to deserialize checkpoint {}", checkpoint))?;

        Ok(checkpoint)
    }

    async fn get_checkpoints(
        &self,
        range: std::ops::Range<CheckpointSequenceNumber>,
    ) -> Result<Vec<CheckpointData>> {
        // Find all needed blobs
        let blobs: Vec<&BlobMetadata> = self.metadata.iter()
            .filter(|b| b.end_checkpoint >= range.start && b.start_checkpoint < range.end)
            .collect();

        if blobs.is_empty() {
            return Ok(Vec::new());
        }

        let mut checkpoints = Vec::new();

        // Process blobs sequentially (metadata is light), but downloads in parallel
        for blob in blobs {
             // Load index (cached or fetch - light operation)
             let index = self.load_blob_index(&blob.blob_id).await?;

             // Identify checkpoints to fetch from this blob
             let mut tasks = Vec::new();
             for cp_num in range.start..range.end {
                 if let Some(entry) = index.get(&cp_num) {
                     tasks.push((cp_num, entry.clone()));
                 }
             }

             if tasks.is_empty() {
                 continue;
             }

             tracing::debug!("downloading {} checkpoints from blob {}", tasks.len(), blob.blob_id);

             // Download in parallel with concurrency limit
             let concurrency = 50; // High concurrency for small ranges
             let downloaded: Vec<Result<CheckpointData>> = stream::iter(tasks)
                .map(|(cp_num, entry)| {
                    // Capture necessary data to avoid lifetime issues with &self
                    let client = self.client.clone();
                    let url = format!("{}/v1/blobs/{}", self.aggregator_url, blob.blob_id);
                    
                    async move {
                        let end = entry.offset + entry.length - 1;
                        let response = client.get(&url)
                            .header("Range", format!("bytes={}-{}", entry.offset, end))
                            .send()
                            .await?;

                        if !response.status().is_success() {
                             return Err(anyhow::anyhow!("failed to fetch range: status {}", response.status()));
                        }

                        let cp_bytes = response.bytes().await?;
                        sui_storage::blob::Blob::from_bytes::<CheckpointData>(&cp_bytes)
                             .with_context(|| format!("failed to deserialize checkpoint {}", cp_num))
                    }
                })
                .buffer_unordered(concurrency)
                .collect()
                .await;

             for result in downloaded {
                 checkpoints.push(result?);
             }
        }
        
        // Sort
        checkpoints.sort_by_key(|cp| cp.checkpoint_summary.sequence_number);
        
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
