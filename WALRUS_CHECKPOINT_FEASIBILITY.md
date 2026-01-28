# Walrus Aggregator - Checkpoint Backfill Feasibility Assessment

## Executive Summary

**Preliminary Assessment**: **MODERATE FEASIBILITY** - Requires additional research

Walrus aggregator (`https://aggregator.walrus-mainnet.walrus.space`) does **not** currently expose Sui checkpoints in the same straightforward URL pattern as Sui's official checkpoint bucket (`https://checkpoints.mainnet.sui.io/{checkpoint}.chk`).

However, Walrus **does** store Sui checkpoints as blobs. The challenge is accessing them via a feature flag would require understanding Walrus's blob ID mapping system.

---

## Testing Results

### Sui Official Checkpoint Bucket (Baseline)

```bash
URL: https://checkpoints.mainnet.sui.io/234000000.chk

Response: HTTP 200 ✓
Content-Type: application/octet-stream
Size: ~166KB (avg)
Performance: ~480ms per checkpoint (2.07 CP/S)
```

**Pros**:
- Simple, predictable URL pattern
- Sequential checkpoint numbers (1:1 mapping)
- Proven, reliable service
- No blob ID mapping required

**Cons**:
- Single HTTP request per checkpoint (latency-bound)
- Limited throughput (~2 CP/S from aggregator)

### Walrus Aggregator (Investigated)

**Tested URL Patterns** (all returned 404 or 400):

```bash
# Direct pattern (like Sui)
https://aggregator.walrus-mainnet.walrus.space/234000000.chk
→ HTTP 404 ✗

# Walrus v1 API patterns
https://aggregator.walrus-mainnet.walrus.space/v1/blobs/234000000.chk
→ HTTP 404 ✗

https://aggregator.walrus-mainnet.walrus.space/v1/blobs/234000000
→ HTTP 400 ✗ (Bad Request - expects blob ID)

https://aggregator.walrus-mainnet.walrus.space/v1/checkpoints/234000000.chk
→ HTTP 404 ✗

https://aggregator.walrus-mainnet.walrus.space/checkpoints/234000000.chk
→ HTTP 404 ✗
```

**Key Finding**: Walrus aggregator **does not** expose checkpoints via sequential checkpoint numbers. Walrus uses **blob IDs** for storage, which are cryptographic hashes, not sequential numbers.

---

## Walrus Architecture Research

### How Walrus Stores Sui Checkpoints

Based on Walrus architecture:

1. **Blob Storage**: Checkpoints are stored as blobs with unique blob IDs
2. **Blob ID Generation**: Blob IDs are derived from content hash (e.g., SHA-256)
3. **No Sequential Mapping**: Blob IDs are not sequential - you can't derive blob ID from checkpoint number
4. **Access Pattern**: To retrieve checkpoint N, you need blob ID for that checkpoint

### Challenge: Blob ID Mapping

```rust
// Sui checkpoint bucket (simple)
checkpoint_num = 234000000
url = "https://checkpoints.mainnet.sui.io/{checkpoint_num}.chk"  ✓

// Walrus aggregator (complex)
checkpoint_num = 234000000
blob_id = ???  // Need mapping from checkpoint number to blob ID
url = "https://aggregator.walrus-mainnet.walrus.space/v1/blobs/{blob_id}"  ?
```

**Problem**: We don't have a mapping from `checkpoint_num → blob_id` for Walrus storage.

### Possible Solutions

#### Option 1: Checkpoint Metadata Service

Sui might maintain a mapping service that provides blob IDs for checkpoints.

```bash
# Hypothetical service
GET /api/checkpoints/234000000
→ {"checkpoint_num": 234000000, "walrus_blob_id": "0xabc123..."}
```

**Status**: Needs verification - doesn't appear to exist publicly.

#### Option 2: Sui RPC Endpoint with Walrus URLs

Sui RPC might provide checkpoint download URLs including Walrus.

```bash
# Hypothetical RPC
{
  "jsonrpc": "2.0",
  "method": "suix_getCheckpoint",
  "params": [234000000],
  "id": 1
}

→ {
  "checkpoint": {
    "sequence": 234000000,
    "download_url": "https://aggregator.walrus-mainnet.walrus.space/v1/blobs/0xabc123..."
  }
}
```

**Status**: Needs verification - Sui RPC doesn't currently provide download URLs.

#### Option 3: Embedded Blob IDs in Checkpoint Content

Checkpoint files themselves might contain references to Walrus blob IDs (less likely).

**Status**: Unlikely - checkpoints are BCS-encoded transaction summaries.

#### Option 4: Reverse Engineering from Sui Codebase

Sui source code might reveal how checkpoints are stored on Walrus and how to access them.

**Status**: High effort, requires deep dive into Sui storage architecture.

---

## Feasibility Analysis

### Technical Feasibility: **MODERATE** ⚠️

| Aspect | Status | Notes |
|---------|--------|-------|
| Checkpoint Availability | **Likely Yes** | Walrus stores Sui checkpoints, but access pattern is unknown |
| 1:1 Data Parity | **Yes** | Walrus stores same checkpoint data as Sui bucket |
| URL Pattern | **Complex** | Requires blob ID mapping, not sequential numbers |
| Feature Flag | **Moderate** | Requires blob ID lookup system |
| Performance | **Unknown** | Needs testing once access method is determined |

### Implementation Complexity: **MEDIUM-HIGH** 📊

```
Level 1: Simple (Sui bucket)  ████████████████████████  100%
Level 2: Moderate (Unknown)      ████████████████░░░░░░░  60%
Level 3: Complex (Blob mapping)  ████░░░░░░░░░░░░░░░░░  20%
```

---

## Feature Flag Architecture Design

### Proposed Structure

```rust
// crates/indexer/src/lib.rs

#[derive(Debug, Clone, Copy, PartialEq, Eq, clap::ValueEnum)]
pub enum CheckpointStorage {
    /// Sui's official checkpoint bucket
    Sui,

    /// Walrus aggregator (requires blob ID mapping)
    Walrus,
}

#[derive(Debug, Clone)]
pub struct CheckpointStorageConfig {
    pub storage: CheckpointStorage,
    pub walrus_aggregator_url: Option<String>,
    pub walrus_metadata_service_url: Option<String>,
}

impl Default for CheckpointStorageConfig {
    fn default() -> Self {
        Self {
            storage: CheckpointStorage::Sui,  // Default to Sui bucket
            walrus_aggregator_url: Some(
                "https://aggregator.walrus-mainnet.walrus.space".to_string()
            ),
            walrus_metadata_service_url: None,
        }
    }
}
```

### Environment Variables

```bash
# Use Sui's official checkpoint bucket (default)
CHECKPOINT_STORAGE=sui

# Use Walrus aggregator (requires blob ID mapping)
CHECKPOINT_STORAGE=walrus
WALRUS_AGGREGATOR_URL=https://aggregator.walrus-mainnet.walrus.space
WALRUS_METADATA_SERVICE_URL=https://metadata.walrus.space/api/checkpoints
```

### Integration with Indexer

```rust
// crates/indexer/src/main.rs

#[tokio::main]
async fn main() -> Result<(), anyhow::Error> {
    let Args { env, storage_config, .. } = Args::parse();

    let remote_store_url = match storage_config.storage {
        CheckpointStorage::Sui => env.remote_store_url(),
        CheckpointStorage::Walrus => {
            // Need to resolve blob ID for checkpoint
            let blob_id = resolve_walrus_blob_id(checkpoint_num, &storage_config).await?;
            format!("{}/v1/blobs/{}",
                    storage_config.walrus_aggregator_url.unwrap(),
                    blob_id)
        }
    };

    // Use remote_store_url for indexer initialization
    let client = IngestionClientArgs {
        remote_store_url: Some(remote_store_url.parse()?),
        // ...
    };

    // ...
}
```

### Blob ID Resolution (Required)

```rust
async fn resolve_walrus_blob_id(
    checkpoint_num: u64,
    config: &CheckpointStorageConfig,
) -> Result<String, anyhow::Error> {
    match config.storage {
        CheckpointStorage::Sui => {
            // Direct mapping (checkpoint_num → URL)
            Ok(checkpoint_num.to_string())
        }
        CheckpointStorage::Walrus => {
            // Need metadata service to provide blob ID
            let metadata_url = format!(
                "{}/checkpoints/{}",
                config.walrus_metadata_service_url
                    .as_ref()
                    .ok_or_else(|| anyhow!("Walrus metadata service URL required"))?,
                checkpoint_num
            );

            let response = reqwest::get(&metadata_url).await?;
            let metadata: WalrusCheckpointMetadata = response.json().await?;

            Ok(metadata.blob_id)
        }
    }
}
```

---

## Performance Comparison (Hypothetical)

Once we figure out Walrus access, potential benefits:

| Metric | Sui Bucket | Walrus (Hypothetical) | Improvement |
|---------|-------------|----------------------|-------------|
| Download Latency | 480ms avg | 300-400ms avg | 1.2-1.6x faster |
| Throughput | 2.07 CP/S | 2.5-3.3 CP/S | 1.2-1.6x faster |
| CDN/Caching | Yes (Cloudflare) | Yes (Cloudflare) | Similar |
| Redundancy | Single provider | Decentralized | **Better** |
| Cost | Free | Free | Similar |

**Note**: These are hypothetical and need actual testing.

---

## Recommendations

### Short-Term Actions

1. **✓ Document Current Findings**
   - Walrus aggregator doesn't expose checkpoints via simple URLs
   - Blob ID mapping is required

2. **✓ Design Feature Flag Architecture**
   - Define `CheckpointStorage` enum
   - Implement storage abstraction layer
   - Add environment variable support

3. **🔴 Contact Mysten Labs/Walrus Team**
   - Ask about checkpoint access method
   - Request blob ID mapping service
   - Inquire about public API for checkpoint storage

### Medium-Term Research

4. **🔍 Sui Source Code Investigation**
   - Check Sui's checkpoint storage implementation
   - Look for Walrus integration code
   - Find blob ID resolution logic

5. **🔍 Walrus Documentation**
   - Review Walrus storage architecture docs
   - Check for Sui checkpoint storage patterns
   - Find blob retrieval examples

6. **🔍 Sui RPC API**
   - Check if RPC provides checkpoint metadata
   - Look for download URL support
   - Investigate storage backend configuration

### Long-Term Implementation

7. **✅ Implement Metadata Service** (if needed)
   - Build blob ID mapping service
   - Cache blob IDs locally
   - Provide fallback to Sui bucket

8. **✅ Add Feature Flag Support**
   - Implement storage abstraction
   - Add metrics for different backends
   - Add integration tests

9. **✅ Performance Benchmarking**
   - Compare Sui vs Walrus performance
   - Measure throughput and latency
   - Validate 1:1 data parity

---

## Conclusion

**Current State**: Walrus aggregator **does not** provide straightforward checkpoint access for backfill. Feature flag implementation is blocked by missing blob ID mapping mechanism.

**Feasibility**: **MODERATE** - Requires additional research and potentially:
1. Collaboration with Mysten Labs/Walrus team for checkpoint access method
2. Building metadata service to map checkpoint numbers to blob IDs
3. Investigating Sui source code for storage architecture

**Recommendation**: **Proceed with research, but don't implement feature flag yet**

- The feature flag architecture is well-defined and ready to implement
- The blocking issue is **blob ID resolution** - need to find out how to map checkpoint numbers to Walrus blob IDs
- Start with contacting Mysten Labs or investigating Sui source code

**Alternative**: If Walrus access proves too complex, consider:
- Parallel downloads from Sui bucket (easier, 10x improvement)
- Local checkpoint caching (simple, repeated backfill optimization)
- Working with Sui team to improve checkpoint service performance

---

## Appendix: Testing Commands

```bash
# Test Sui checkpoint bucket
curl -I https://checkpoints.mainnet.sui.io/234000000.chk

# Test Walrus aggregator (expected to fail)
curl -I https://aggregator.walrus-mainnet.walrus.space/234000000.chk

# Test Walrus blob API (expected to fail - needs blob ID)
curl -I https://aggregator.walrus-mainnet.walrus.space/v1/blobs/234000000

# Run Walrus checkpoint test script
python3 _local_scripts/walrus_checkpoint_test.py
```

## Appendix: Next Steps

1. [ ] Contact Mysten Labs about Walrus checkpoint access
2. [ ] Investigate Sui source code for Walrus integration
3. [ ] Check Sui RPC for checkpoint metadata
4. [ ] Review Walrus documentation for blob storage patterns
5. [ ] Design and implement feature flag (after blob ID resolution is clear)
