# PR: Robust Walrus Backfill via CLI Integration

## Problem
Historical backfills using the Walrus Aggregator (HTTP) consistently failed for large blobs (2-3 GB) due to gateway timeouts.

## Solution
This PR implements a robust **Dual-Mode Walrus Backend** (defaults to Aggregator):
1.  **Aggregator Mode (Default):** Uses HTTP Range requests with new **intra-blob chunking** and **automatic retries** to provide stable ~130 CP/s throughput.
2.  **CLI-Native Mode (Optional):** Uses the `walrus` CLI to download full blobs directly from storage nodes for 100% reliability during massive historical backfills.
3.  **Parallelization:** Added support for concurrent blob processing to maximize bandwidth utilization.
4.  **Local Indexing:** Parses blob indices directly from cached files in CLI mode, removing dependency on HTTP proxies.

## Performance Data (Verified)
We implemented a **Dual-Mode Benchmark** on Mainnet (Range: 238,350,000 - 238,365,000).

### **1. Aggregator Mode (HTTP Range)**
Optimized with intra-blob chunking (200 CP batches) and automatic retries (5 attempts).
- **Average Throughput:** **130.40 CP/s**
- **Pros:** Fast for small/medium ranges, low bandwidth.
- **Cons:** Dependent on proxy stability.

### **2. Walrus CLI Mode (Direct Node)**
Direct P2P reconstruction of full 3GB blobs.
- **Initial Rate:** **~6.16 - 11.84 CP/s** (bound by network download).
- **Cached Rate:** **>12,000 CP/s** (instant extraction).
- **Pros:** 100% reliable for massive historical backfills.

| Metric | Aggregator | Walrus CLI (Initial) |
| :--- | :--- | :--- |
| **Network Speed** | N/A | 1.20 - 2.10 MB/s |
| **Throughput** | **130.40 CP/s** | **6.16 - 11.84 CP/s** |
| **Extraction Speed**| ~200 CP/s | **>12,000 CP/s** |

## How to Test

## Changes
- `crates/indexer/src/walrus_storage.rs`: Integrated CLI mode, parallel blob streams, and performance logging.
- `crates/indexer/src/main.rs`: Added CLI path arguments.
- `WALRUS_DOWNLOADER_GUIDE.md`: Full usage instructions.
