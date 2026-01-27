# PR: Robust Walrus Backfill via CLI Integration

## Problem
The existing Walrus backfill implementation relied on the Walrus Aggregator's HTTP API. Large blob downloads (2-3 GB) were consistently failing with `504 Gateway Timeout` or `500 Internal Server Error`, making historical backfills impossible.

## Solution
This PR introduces a **Hybrid CLI/HTTP Storage Backend** for Walrus:
1.  **Direct Node Download:** Integrates the `walrus` CLI to download full blobs directly from storage nodes, bypassing the Aggregator's HTTP proxy limitations.
2.  **Offline Indexing:** Refactors the indexing logic to parse blob indices directly from the downloaded local files, removing *all* dependency on the Aggregator during the extraction phase.
3.  **Local Caching:** Blobs are cached in `./checkpoint_cache`. Subsequent runs or re-processing of the same range are instantaneous (>12,000 CP/s).

## Performance Data (Verified)
We ran a verification backfill of **15,000 checkpoints** (Range: 238,350,000 - 238,365,000) on Mainnet.

| Metric | Blob 1 (`Nsaw5...`) | Blob 2 (`m7aWF...`) |
| :--- | :--- | :--- |
| **Blob Size** | 2.72 GB | 2.58 GB |
| **Total Checkpoints in Blob** | 13,985 | 14,561 |
| **Download Time** | 37m 47s (2267s) | 20m 29s (1229s) |
| **Network Speed** | 1.20 MB/s | 2.10 MB/s |
| **Effective Rate** | **6.16 CP/s** | **11.84 CP/s** |
| **Extraction Speed** | >12,000 CP/s (Disk I/O) | >11,000 CP/s (Disk I/O) |

**Key Takeaway:** The bottleneck is strictly network download speed. While slow (~6-12 CP/s), it is **100% reliable**, whereas the HTTP Aggregator method yielded 0% success for these ranges.

## How to Test
1.  Install the [Walrus CLI](https://docs.walrus.site/usage/client-cli.html) and ensure `walrus` is in your PATH.
2.  Run the downloader:
    ```bash
    cargo run --release --bin deepbook-indexer -- \
      --download-walrus-to ./checkpoints \
      --verification-start 238350000 \
      --verification-limit 1000 \
      --env mainnet \
      --walrus-cli-path walrus
    ```
3.  Verify logs show `downloading blob ... via CLI` followed by `extracted ... checkpoints`.

## Changes
- `crates/indexer/src/walrus_storage.rs`: 
    - Added `download_blob_via_cli` using `Command`.
    - Added `load_blob_index` fallback to local file parsing.
    - Reordered `download_checkpoints_to_dir` to guarantee file presence before processing.
    - Added performance instrumentation.
- `crates/indexer/src/main.rs`: Added `--walrus-cli-path` argument.
- `crates/indexer/src/checkpoint_storage_config.rs`: Added config field.
- `WALRUS_DOWNLOADER_GUIDE.md`: Updated with CLI usage and performance notes.
