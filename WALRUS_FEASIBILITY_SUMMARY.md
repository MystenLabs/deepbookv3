# Walrus Checkpoint Backfill - Quick Summary

## TL;DR

**Walrus aggregator does NOT currently support simple checkpoint backfill feature flag.**

The blocking issue: Walrus uses **blob IDs** (cryptographic hashes) for storage, not sequential checkpoint numbers. We can't map checkpoint numbers → blob IDs without additional metadata service.

---

## Test Results

### What We Tested

✓ **Sui Checkpoint Bucket** (working)
- URL: `https://checkpoints.mainnet.sui.io/234000000.chk`
- Status: HTTP 200 ✓
- Throughput: 2.07 CP/S

✗ **Walrus Aggregator** (not working)
- URL: `https://aggregator.walrus-mainnet.walrus.space/234000000.chk`
- Status: HTTP 404 ✗
- Tested patterns: All returned 404 or 400

### The Problem

```rust
// Sui bucket (simple)
checkpoint_num = 234000000
url = "https://checkpoints.mainnet.sui.io/{checkpoint_num}.chk"
→ Works! ✓

// Walrus aggregator (complex)
checkpoint_num = 234000000
blob_id = ???  // We don't know the blob ID for this checkpoint
url = "https://aggregator.walrus-mainnet.walrus.space/v1/blobs/{blob_id}"
→ Can't work without blob ID! ✗
```

---

## Feasibility: MODERATE ⚠️

| Factor | Status | Notes |
|---------|---------|-------|
| Walrus has checkpoints | **Yes** | Stores Sui checkpoints as blobs |
| 1:1 data parity | **Yes** | Same checkpoint data |
| Simple URL pattern | **No** | Requires blob ID mapping |
| Feature flag | **Moderate** | Blocked by blob ID lookup |

---

## Possible Solutions

### Option 1: Metadata Service (Best if Available)

Sui/Walrus might provide checkpoint → blob ID mapping:

```bash
GET /api/checkpoints/234000000
→ {"blob_id": "0xabc123...", "checkpoint_num": 234000000}
```

**Status**: Unknown - doesn't appear to exist publicly.

### Option 2: Sui RPC with Download URLs

Sui RPC might return checkpoint download URLs:

```bash
{
  "checkpoint": {
    "download_url": "https://aggregator.walrus-mainnet.walrus.space/v1/blobs/0xabc123..."
  }
}
```

**Status**: Unknown - Sui RPC doesn't currently provide this.

### Option 3: Build Metadata Service (Complex)

Maintain our own blob ID mapping:

```rust
// On first backfill, resolve and cache blob IDs
async fn resolve_blob_id(checkpoint_num: u64) -> Result<String> {
    // 1. Download from Sui bucket (we know it works)
    // 2. Calculate hash/extract blob ID
    // 3. Upload to Walrus (or use existing)
    // 4. Cache mapping: checkpoint_num → blob_id
}
```

**Status**: High effort, but technically feasible.

---

## Recommendations

### Short-Term: Use Parallel Downloads from Sui Bucket 🚀

**Quick Win**: Implement parallel checkpoint downloads (10-20 concurrent)

- **Current**: 2.07 CP/S (sequential)
- **With 10x parallelization**: ~20 CP/S
- **Improvement**: 10x faster, same codebase, no Walrus complexity

**Implementation**:
```rust
// Add concurrent download support to indexer
let checkpoints = download_concurrent(start, count, concurrency=10)?;
```

### Medium-Term: Research Walrus Access 🔍

1. **Contact Mysten Labs/Walrus team**
   - Ask: "How can we access Sui checkpoints via Walrus aggregator?"
   - Request: "Is there a checkpoint → blob ID mapping service?"

2. **Investigate Sui source code**
   - Look for Walrus checkpoint storage implementation
   - Find blob ID resolution logic

3. **Check Sui RPC API**
   - Look for checkpoint metadata
   - Search for download URL support

### Long-Term: Implement Feature Flag (if Walrus access is clear)

```rust
// Feature flag structure (ready to implement)
pub enum CheckpointStorage {
    Sui,    // Current: https://checkpoints.mainnet.sui.io
    Walrus,   // Future: https://aggregator.walrus-mainnet.walrus.space (with blob ID lookup)
}
```

---

## Quick Decision Matrix

| Approach | Complexity | Time to Implement | Performance Gain |
|-----------|-------------|-------------------|-------------------|
| **Parallel downloads (Sui)** | Low | 1-2 days | 10x (~20 CP/S) |
| **Walrus with metadata service** | Medium | 1-2 weeks (if service exists) | 1.5-2x (~3-4 CP/S) |
| **Walrus with custom blob mapping** | High | 2-4 weeks | Unknown |

**Recommendation**: Start with parallel downloads (easy win), research Walrus in parallel.

---

## Files Created

1. **`WALRUS_CHECKPOINT_FEASIBILITY.md`** - Detailed analysis (architecture, testing, implementation)
2. **`WALRUS_FEASIBILITY_SUMMARY.md`** - This quick summary
3. **`_local_scripts/walrus_checkpoint_test.py`** - Test script for Walrus endpoint discovery

---

## Next Steps

1. [ ] Implement parallel checkpoint downloads from Sui bucket
2. [ ] Contact Mysten Labs/Walrus team about checkpoint access
3. [ ] Investigate Sui source code for Walrus integration
4. [ ] Re-assess Walrus feature flag after research

---

**Bottom Line**: Walrus aggregator is **not ready** for simple checkpoint backfill feature flag. Use parallel downloads from Sui bucket for now (10x improvement), research Walrus access method separately.
