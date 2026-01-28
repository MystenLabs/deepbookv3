// Copyright (c) DeepBook V3. All rights reserved.
// SPDX-License-Identifier: Apache-2.0

use clap::{Parser, ValueEnum};
use std::path::PathBuf;

/// Checkpoint storage backend selection
#[derive(Debug, Clone, Copy, PartialEq, Eq, ValueEnum)]
pub enum CheckpointStorageType {
    /// Sui's official checkpoint bucket (sequential downloads)
    #[clap(name = "sui")]
    Sui,

    /// Walrus aggregator with blob-based storage (fast backfill)
    #[clap(name = "walrus")]
    Walrus,
}

impl std::fmt::Display for CheckpointStorageType {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Sui => write!(f, "sui"),
            Self::Walrus => write!(f, "walrus"),
        }
    }
}

impl std::str::FromStr for CheckpointStorageType {
    type Err = String;

    fn from_str(s: &str) -> Result<Self, Self::Err> {
        match s.to_lowercase().as_str() {
            "sui" => Ok(CheckpointStorageType::Sui),
            "walrus" => Ok(CheckpointStorageType::Walrus),
            _ => Err(format!("invalid checkpoint storage: {}", s)),
        }
    }
}

/// Checkpoint storage configuration
#[derive(Debug, Clone, Parser)]
pub struct CheckpointStorageConfig {
    /// Which checkpoint storage backend to use
    #[arg(long, env = "CHECKPOINT_STORAGE", default_value = "sui")]
    pub storage: CheckpointStorageType,

    /// Walrus archival service URL (for blob metadata)
    #[arg(long, env = "WALRUS_ARCHIVAL_URL", default_value = "https://walrus-sui-archival.mainnet.walrus.space")]
    pub walrus_archival_url: String,

    /// Walrus aggregator URL (for blob downloads)
    #[arg(long, env = "WALRUS_AGGREGATOR_URL", default_value = "https://aggregator.walrus-mainnet.walrus.space")]
    pub walrus_aggregator_url: String,

    /// Enable local blob caching (highly recommended)
    #[arg(long, env = "CHECKPOINT_CACHE_ENABLED", default_value = "true")]
    pub cache_enabled: bool,

    /// Directory for checkpoint blob cache
    #[arg(long, env = "CHECKPOINT_CACHE_DIR", default_value = "./checkpoint_cache")]
    pub cache_dir: PathBuf,

    /// Maximum cache size in GB (0 = unlimited)
    #[arg(long, env = "CHECKPOINT_CACHE_MAX_SIZE_GB", default_value = "100")]
    pub cache_max_size_gb: u64,

    /// Path to the Walrus CLI binary (optional, used if aggregator is skipped)
    #[arg(long, env = "WALRUS_CLI_PATH")]
    pub walrus_cli_path: Option<PathBuf>,
}
