// Copyright (c) DeepBook V3. All rights reserved.
// SPDX-License-Identifier: Apache-2.0

use anyhow::{Context, Result};
use async_trait::async_trait;
use byteorder::{LittleEndian, ReadBytesExt};
use futures::stream::{self, StreamExt};
use reqwest::Client;
use serde::Deserialize;
use std::collections::HashMap;
use std::io::{Cursor, Read, Seek, SeekFrom};
use std::path::PathBuf;
use std::process::Stdio;
use std::sync::Arc;
use sui_types::full_checkpoint_content::CheckpointData;
use sui_types::messages_checkpoint::CheckpointSequenceNumber;
use tokio::process::Command;
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
#[derive(Clone)]
pub struct WalrusCheckpointStorage {
    inner: Arc<Inner>,
}

struct Inner {
    archival_url: String,
    aggregator_url: String,
    cache_dir: PathBuf,
    walrus_cli_path: Option<PathBuf>,
    client: Client,
    index_cache: RwLock<HashMap<String, HashMap<u64, BlobIndexEntry>>>,
    metadata: RwLock<Vec<BlobMetadata>>,
}

impl WalrusCheckpointStorage {
    /// Create a new Walrus checkpoint storage instance
    pub fn new(
        archival_url: String,
        aggregator_url: String,
        cache_dir: PathBuf,
        _cache_max_size: u64,
        walrus_cli_path: Option<PathBuf>,
    ) -> Result<Self> {
        if walrus_cli_path.is_some() {
            // Ensure cache directory exists if using CLI mode
            std::fs::create_dir_all(&cache_dir).context("failed to create cache dir for walrus cli")?;
        }

        Ok(Self {
            inner: Arc::new(Inner {
                archival_url,
                aggregator_url,
                cache_dir,
                walrus_cli_path,
                client: Client::builder()
                    .timeout(std::time::Duration::from_secs(30)) // 30s timeout is enough for small ranges
                    .build()
                    .expect("Failed to create HTTP client"),
                index_cache: RwLock::new(HashMap::new()),
                metadata: RwLock::new(Vec::new()),
            }),
        })
    }

    /// Initialize by fetching blob metadata from archival service
    pub async fn initialize(&self) -> Result<()> {
        tracing::info!("fetching Walrus blob metadata from: {}", self.inner.archival_url);

        let url = format!("{}/v1/app_blobs", self.inner.archival_url);
        let response = self.inner
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

        let mut metadata = self.inner.metadata.write().await;
        *metadata = blobs.blobs;

        tracing::info!(
            "fetched {} Walrus blobs covering checkpoints {}..{}",
            metadata.len(),
            metadata.first().map(|b| b.start_checkpoint).unwrap_or(0),
            metadata.last().map(|b| b.end_checkpoint).unwrap_or(0)
        );

        Ok(())
    }

    /// Find blob containing a specific checkpoint
    async fn find_blob_for_checkpoint(&self, checkpoint: u64) -> Option<BlobMetadata> {
        let metadata = self.inner.metadata.read().await;
        metadata
            .iter()
            .find(|blob| checkpoint >= blob.start_checkpoint && checkpoint <= blob.end_checkpoint)
            .cloned()
    }

    /// Load (or fetch) the index for a blob
    async fn load_blob_index(&self, blob_id: &str) -> Result<HashMap<u64, BlobIndexEntry>> {
        // 1. Check memory cache
        {
            let cache = self.inner.index_cache.read().await;
            if let Some(index) = cache.get(blob_id) {
                return Ok(index.clone());
            }
        }

        // 2. Try reading from local file (CLI/Cache mode)
        let cached_path = self.get_cached_blob_path(blob_id);
        if cached_path.exists() {
            tracing::info!("loading index from cached blob {}", cached_path.display());
            let mut file = std::fs::File::open(&cached_path)?;
            
            // Read Footer (last 24 bytes)
            let file_len = file.metadata()?.len();
            if file_len < 24 {
                return Err(anyhow::anyhow!("cached blob too small"));
            }
            file.seek(SeekFrom::Start(file_len - 24))?;
            let magic = file.read_u32::<LittleEndian>()?;
            if magic != 0x574c4244 {
                return Err(anyhow::anyhow!("invalid blob footer magic"));
            }
            let _version = file.read_u32::<LittleEndian>()?;
            let index_start_offset = file.read_u64::<LittleEndian>()?;
            let count = file.read_u32::<LittleEndian>()?;

            // Read Index
            file.seek(SeekFrom::Start(index_start_offset))?;
            // Read remaining bytes for index
            let mut index_bytes = Vec::new();
            file.read_to_end(&mut index_bytes)?;
            
            let mut cursor = Cursor::new(&index_bytes);
            let mut index = HashMap::with_capacity(count as usize);

            for _ in 0..count {
                let name_len = cursor.read_u32::<LittleEndian>()?;
                let mut name_bytes = vec![0u8; name_len as usize];
                cursor.read_exact(&mut name_bytes)?;
                let name_str = String::from_utf8(name_bytes)?;
                let checkpoint_number = name_str.parse::<u64>()?;
                let offset = cursor.read_u64::<LittleEndian>()?;
                let length = cursor.read_u64::<LittleEndian>()?;
                let _entry_crc = cursor.read_u32::<LittleEndian>()?;

                index.insert(checkpoint_number, BlobIndexEntry { checkpoint_number, offset, length });
            }

            // Update Cache
            let mut cache = self.inner.index_cache.write().await;
            cache.insert(blob_id.to_string(), index.clone());
            return Ok(index);
        }

        tracing::info!("fetching index for blob {} from aggregator", blob_id);

        // 3. Fetch Footer (last 24 bytes) from Aggregator
        let url = format!("{}/v1/blobs/{}", self.inner.aggregator_url, blob_id);
        let response = self.inner.client.get(&url)
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
        let response = self.inner.client.get(&url)
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
            let mut cache = self.inner.index_cache.write().await;
            cache.insert(blob_id.to_string(), index.clone());
        }

        Ok(index)
    }

    /// Check if blob exists in cache
    fn get_cached_blob_path(&self, blob_id: &str) -> PathBuf {
        self.inner.cache_dir.join(blob_id)
    }

    /// Download full blob using Walrus CLI
    async fn download_blob_via_cli(&self, blob_id: &str) -> Result<PathBuf> {
        let cli_path = self.inner.walrus_cli_path.as_ref()
            .ok_or_else(|| anyhow::anyhow!("Walrus CLI path not configured"))?;
        
        let output_path = self.get_cached_blob_path(blob_id);
        
        // If file exists and size matches metadata, skip
        if output_path.exists() {
            // Optional: verify size matches metadata
            return Ok(output_path);
        }

        tracing::info!("downloading blob {} via CLI to {}", blob_id, output_path.display());

        let status = Command::new(cli_path)
            .arg("read")
            .arg(blob_id)
            .arg("--out")
            .arg(&output_path)
            .stdout(Stdio::inherit())
            .stderr(Stdio::inherit())
            .status()
            .await
            .context("failed to execute walrus cli")?;

        if !status.success() {
            return Err(anyhow::anyhow!("walrus cli failed with status {}", status));
        }

        Ok(output_path)
    }

    /// Download a specific range from a blob (HTTP or Local File)
    async fn download_range(&self, blob_id: &str, start: u64, length: u64) -> Result<Vec<u8>> {
        // 1. Check if we have the file locally (or should force download it via CLI)
        let cached_path = self.get_cached_blob_path(blob_id);
        
        // If configured to use CLI, ensure it's downloaded
        if self.inner.walrus_cli_path.is_some() {
            // This is a heavy operation (downloading full blob), but guarantees availability
            // Only performed once per blob
            if !cached_path.exists() {
                self.download_blob_via_cli(blob_id).await?;
            }
        }

        // 2. If local file exists, read from it
        if cached_path.exists() {
            // tracing::debug!("reading range {}-{} from local file {}", start, start + length, cached_path.display());
            let mut file = std::fs::File::open(&cached_path)
                .with_context(|| format!("failed to open cached blob {}", cached_path.display()))?;
            
            file.seek(SeekFrom::Start(start))?;
            let mut buffer = vec![0u8; length as usize];
            file.read_exact(&mut buffer)?;
            
            return Ok(buffer);
        }

        // 3. Fallback to HTTP Range request (Aggregator)
        let url = format!("{}/v1/blobs/{}", self.inner.aggregator_url, blob_id);
        let end = start + length - 1;
        
        tracing::debug!("downloading range {}-{} (len {}) from {}", start, end, length, blob_id);

        let response = self.inner.client.get(&url)
            .header("Range", format!("bytes={}-{}", start, end))
            .send()
            .await?;

        if !response.status().is_success() {
             return Err(anyhow::anyhow!("failed to fetch range: status {}", response.status()));
        }

        let bytes = response.bytes().await?.to_vec();
        if bytes.len() as u64 != length {
             tracing::warn!("expected {} bytes, got {}", length, bytes.len());
        }

        Ok(bytes)
    }

    /// Download checkpoints to a local directory as .chk files
    /// Files contain the raw BCS bytes of the CheckpointData
    pub async fn download_checkpoints_to_dir(
        &self,
        range: std::ops::Range<CheckpointSequenceNumber>,
        output_dir: PathBuf,
    ) -> Result<()> {
        tokio::fs::create_dir_all(&output_dir).await?;

        let metadata = self.inner.metadata.read().await;
        // Find all needed blobs
        let blobs: Vec<BlobMetadata> = metadata.iter()
            .filter(|b| b.end_checkpoint >= range.start && b.start_checkpoint < range.end)
            .cloned()
            .collect();
        drop(metadata); // Release lock

        if blobs.is_empty() {
            return Ok(());
        }

        // Process blobs sequentially
        for blob in blobs {
             // If using CLI, ensure blob is downloaded ONCE before parsing index
             if self.inner.walrus_cli_path.is_some() {
                 self.download_blob_via_cli(&blob.blob_id).await?;
             }

             // Load index
             let index = self.load_blob_index(&blob.blob_id).await?;

             // Identify checkpoints to fetch
             let mut tasks = Vec::new();
             for cp_num in range.start..range.end {
                 if let Some(entry) = index.get(&cp_num) {
                     tasks.push((cp_num, entry.clone()));
                 }
             }

             if tasks.is_empty() {
                 continue;
             }

             tracing::info!("downloading {} checkpoints from blob {} to {}", tasks.len(), blob.blob_id, output_dir.display());

             // Download in parallel
             let concurrency = 50;
             let output_dir = output_dir.clone();
             
             let results: Vec<Result<()>> = stream::iter(tasks)
                .map(|(cp_num, entry)| {
                    let storage = self.clone();
                    let blob_id = blob.blob_id.clone();
                    let file_path = output_dir.join(format!("{}.chk", cp_num));
                    
                    async move {
                        // Check if file already exists to avoid re-downloading
                        if tokio::fs::try_exists(&file_path).await.unwrap_or(false) {
                            return Ok(());
                        }

                        let bytes = storage.download_range(&blob_id, entry.offset, entry.length).await?;
                        tokio::fs::write(&file_path, bytes).await?;
                        Ok(())
                    }
                })
                .buffer_unordered(concurrency)
                .collect()
                .await;

             // Check for errors
             for result in results {
                 result?;
             }
        }
        
        Ok(())
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
            .await
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
        let metadata: tokio::sync::RwLockReadGuard<Vec<BlobMetadata>> = self.inner.metadata.read().await;
        // Find all needed blobs
        let blobs: Vec<BlobMetadata> = metadata.iter()
            .filter(|b| b.end_checkpoint >= range.start && b.start_checkpoint < range.end)
            .cloned()
            .collect();
        drop(metadata);

        if blobs.is_empty() {
            return Ok(Vec::new());
        }

        let mut checkpoints = Vec::new();

        // Process blobs sequentially (metadata is light), but downloads in parallel
        for blob in blobs {
             // If using CLI, ensure blob is downloaded ONCE before parsing index
             if self.inner.walrus_cli_path.is_some() {
                 self.download_blob_via_cli(&blob.blob_id).await?;
             }

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
                    let storage = self.clone();
                    let blob_id = blob.blob_id.clone();
                    
                    async move {
                        let cp_bytes = storage.download_range(&blob_id, entry.offset, entry.length).await?;
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
        Ok(self.find_blob_for_checkpoint(checkpoint).await.is_some())
    }

    async fn get_latest_checkpoint(&self) -> Result<Option<CheckpointSequenceNumber>> {
        let metadata: tokio::sync::RwLockReadGuard<Vec<BlobMetadata>> = self.inner.metadata.read().await;
        // Find highest checkpoint in blob metadata
        metadata
            .iter()
            .map(|blob| blob.end_checkpoint)
            .max()
            .map(|cp| Ok::<CheckpointSequenceNumber, anyhow::Error>(cp))
            .transpose()
            .context("failed to find latest checkpoint in Walrus blobs")
    }
}
