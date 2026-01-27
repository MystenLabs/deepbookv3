# DeepBook Indexer Backfill Performance Analysis

## Overview

This document analyzes the checkpoint download throughput for DeepBook indexer backfill operations, which is the primary bottleneck when backfilling historical data.

## Test Methodology

We created a lightweight Python benchmark script (`_local_scripts/backfill_bench.py`) that:
1. Downloads consecutive checkpoints from Sui's remote checkpoint bucket
2. Measures download time and throughput
3. Calculates checkpoints/second rate
4. Provides backfill time estimates

The benchmark was run on both **testnet** and **mainnet** to compare performance.

## Configuration

- **Testnet URL**: `https://checkpoints.testnet.sui.io`
- **Mainnet URL**: `https://checkpoints.mainnet.sui.io`
- **Sample Size**: 50 consecutive checkpoints per test
- **Network**: Standard residential internet connection

## Test Results

### Testnet (Checkpoints 234918000-234918049)

```
Checkpoints Downloaded: 50
Total Time: 19.04s
Total Size: 0.38MB

Throughput:
  Checkpoints/Second: 2.63
  Average Throughput: 0.02 MB/s

Per-Checkpoint Statistics:
  Average Download Time: 380.76ms
  Min Download Time: 265.05ms
  Max Download Time: 532.05ms
  Average Checkpoint Size: 7.81KB
  Min Checkpoint Size: 3.46KB
  Max Checkpoint Size: 24.59KB
```

**Note**: Testnet checkpoints are quite small because testnet has minimal activity compared to mainnet.

### Mainnet (Checkpoints 234000000-234000049)

```
Checkpoints Downloaded: 50
Total Time: 24.16s
Total Size: 8.08MB

Throughput:
  Checkpoints/Second: 2.07
  Average Throughput: 0.33 MB/s

Per-Checkpoint Statistics:
  Average Download Time: 483.19ms
  Min Download Time: 320.63ms
  Max Download Time: 691.54ms
  Average Checkpoint Size: 165.52KB
  Min Checkpoint Size: 11.47KB
  Max Checkpoint Size: 702.22KB
```

**Note**: Mainnet has significantly larger checkpoints due to higher transaction volume and activity.

## Key Findings

### 1. Download Throughput is the Limiting Factor

- **Mainnet**: 2.07 checkpoints/second (avg 483ms per checkpoint)
- **Testnet**: 2.63 checkpoints/second (avg 381ms per checkpoint)

The throughput is constrained by **network round-trip time (RTT)**, not bandwidth. Each checkpoint requires a separate HTTP request, and the average RTT to `checkpoints.mainnet.sui.io` is ~480ms.

### 2. Checkpoint Size Variability

- **Mainnet**: 11KB - 702KB per checkpoint (avg: 166KB)
- **Testnet**: 3.5KB - 25KB per checkpoint (avg: 7.8KB)

Mainnet checkpoints vary significantly based on:
- Transaction volume in that checkpoint
- Number of DeepBook trades/events
- General network activity

### 3. Performance Grade

Based on checkpoints/second:

- **≥50 CP/S**: EXCELLENT
- **≥20 CP/S**: GOOD
- **≥10 CP/S**: ACCEPTABLE
- **≥5 CP/S**: MODERATE
- **<5 CP/S**: NEEDS IMPROVEMENT ← **Current: 2.07 CP/S**

## Backfill Time Estimates

Based on mainnet performance (2.07 CP/S):

| Checkpoints | Time (Minutes) | Time (Hours) |
|-------------|----------------|--------------|
| 1,000       | 8.1 minutes    | 0.1 hours    |
| 10,000      | 80.5 minutes   | 1.3 hours    |
| 50,000      | 402.4 minutes  | 6.7 hours    |
| 100,000     | 805.3 minutes  | 13.4 hours   |
| 500,000     | 4,026 minutes  | 67.1 hours   |
| 1,000,000   | 8,053 minutes  | 134.2 hours  |

**Example**: Backfilling the last 50,000 checkpoints (~34 days of mainnet history) would take approximately **6.7 hours** just for downloading, excluding processing time.

## Optimization Opportunities

### 1. Parallel Downloads (High Impact)

**Current**: Sequential downloads (1 at a time)
**Optimized**: Parallel downloads (e.g., 10 concurrent)

Expected improvement: **8-10x faster** (limited by network latency and throughput)

```python
# With 10 concurrent downloads:
# 2.07 CP/S * 10 = ~20 CP/S (GOOD grade)
# 50,000 checkpoints: 40 minutes instead of 6.7 hours
```

### 2. Checkpoint Bundles (High Impact)

**Current**: Individual checkpoint files (1 per request)
**Optimized**: Bundled checkpoints or range requests

Expected improvement: **5-10x faster** (fewer HTTP round-trips)

### 3. Local Caching (Medium Impact)

**Current**: Re-download checkpoints for each backfill
**Optimized**: Cache downloaded checkpoints locally

Expected improvement: **Significant for repeated backfills**

### 4. CDN or Regional Endpoint (Medium Impact)

**Current**: `https://checkpoints.mainnet.sui.io`
**Optimized**: Use regional CDN endpoint closer to indexer server

Expected improvement: **2-3x faster** (reduced network latency)

### 5. Compressed Checkpoints (Low Impact)

**Current**: Uncompressed checkpoint files
**Optimized**: Compressed (gzip, zstd) checkpoints

Expected improvement: **1.5-2x faster** (smaller payload, but adds decompression overhead)

## Recommendations

### Short-Term (Easy Wins)

1. **Implement Parallel Downloads**
   - Add concurrent download support to the indexer
   - Start with 5-10 parallel connections
   - This alone could improve throughput to 10-20 CP/S

2. **Add Download Progress Tracking**
   - Implement real-time progress reporting
   - Show estimated remaining time during backfill
   - Helps operators monitor long-running backfills

### Medium-Term

3. **Checkpoint Caching**
   - Store downloaded checkpoints locally
   - Reuse cached checkpoints for subsequent backfills
   - Configurable cache size and retention policy

4. **Retry and Timeout Handling**
   - Implement robust retry logic for failed downloads
   - Configurable timeouts for network issues
   - Backoff strategies to avoid overwhelming the endpoint

### Long-Term

5. **Collaborate with Sui Foundation**
   - Request checkpoint bundle support or range downloads
   - Discuss CDN improvements or regional endpoints
   - Provide feedback on checkpoint service optimization

## Running the Benchmark

To run the backfill performance benchmark yourself:

```bash
# Testnet (50 checkpoints, starting at 234918000)
python3 _local_scripts/backfill_bench.py --count 50

# Mainnet (50 checkpoints, starting at 234000000)
python3 _local_scripts/backfill_bench.py --count 50 --mainnet

# Custom range
python3 _local_scripts/backfill_bench.py --count 100 --start 233500000 --mainnet
```

## Conclusion

The current checkpoint download throughput of **2.07 CP/S** is the primary bottleneck for DeepBook indexer backfill operations. With parallel downloads, we could achieve **10-20 CP/S** (GOOD to EXCELLENT grade), reducing backfill times by 5-10x.

For example, backfilling 50,000 checkpoints would take:
- **Current**: 6.7 hours
- **With 10x parallelization**: 40 minutes

This optimization would significantly improve operational efficiency for DeepBook indexer deployments and reduce time-to-value for new indexers.
