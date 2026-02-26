// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

use std::collections::HashMap;
use std::sync::Arc;
use std::time::{Duration, Instant};
use tokio::sync::RwLock;

const APY_CACHE_TTL: Duration = Duration::from_secs(300); // 5 minutes
const ABYSS_API_BASE: &str = "https://beta.abyssprotocol.xyz/api/vaults/vaults";

/// Response from the Abyss Protocol vault indexer endpoint.
#[derive(Debug, serde::Deserialize)]
struct AbyssApyResponse {
    current_apy: f64,
    #[allow(dead_code)]
    current_incentive_apy: f64,
}

/// Cached APY entry: (apy_decimal, fetched_at).
type ApyCacheEntry = (f64, Instant);

/// Thread-safe APY cache shared across handlers.
pub type ApyCache = Arc<RwLock<HashMap<String, ApyCacheEntry>>>;

/// Create a new empty APY cache.
pub fn new_apy_cache() -> ApyCache {
    Arc::new(RwLock::new(HashMap::new()))
}

/// Fetch APY for a given Abyss vault address, with caching.
/// Returns the APY as a decimal (e.g. 0.1024 for 10.24%).
pub async fn get_apy(
    http_client: &reqwest::Client,
    cache: &ApyCache,
    vault_address: &str,
) -> Result<f64, anyhow::Error> {
    // Check cache first
    {
        let cache_read = cache.read().await;
        if let Some((apy, fetched_at)) = cache_read.get(vault_address) {
            if fetched_at.elapsed() < APY_CACHE_TTL {
                return Ok(*apy);
            }
        }
    }

    // Fetch from Abyss API
    let url = format!("{}/{}/current-apy", ABYSS_API_BASE, vault_address);
    let resp = http_client
        .get(&url)
        .timeout(Duration::from_secs(10))
        .send()
        .await?
        .error_for_status()?
        .json::<AbyssApyResponse>()
        .await?;

    // Convert percentage to decimal (10.24 → 0.1024)
    let apy_decimal = resp.current_apy / 100.0;
    let apy_decimal = if apy_decimal < 0.0 { 0.0 } else { apy_decimal };

    // Update cache
    {
        let mut cache_write = cache.write().await;
        cache_write.insert(vault_address.to_string(), (apy_decimal, Instant::now()));
    }

    Ok(apy_decimal)
}
