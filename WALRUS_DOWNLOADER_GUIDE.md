# Walrus Checkpoint Downloader

This tool allows you to efficiently download Sui checkpoints from Walrus storage to a local directory. The downloaded files are in the standard `.chk` format (BCS encoded `CheckpointData`) and can be consumed by standard Sui indexers using the `local_ingestion_path` configuration.

## Usage

The downloader is integrated into the `deepbook-indexer` binary.

### Command

```bash
cargo run --release --bin deepbook-indexer -- \
  --download-walrus-to <OUTPUT_DIR> \
  --verification-start <START_CHECKPOINT> \
  --verification-limit <COUNT> \
  --env mainnet
```

### Parameters

- `--download-walrus-to <DIR>`: The target directory where checkpoint files will be saved. The directory will be created if it doesn't exist.
- `--verification-start <CP>`: The starting checkpoint sequence number (default: 0).
- `--verification-limit <COUNT>`: The number of checkpoints to download (default: 10000).
- `--env`: The environment (`mainnet` or `testnet`).
- `--walrus-cli-path <PATH>`: (Optional) Path to the `walrus` CLI binary. If provided, full blobs will be downloaded via storage nodes (avoiding aggregator timeouts) and cached locally.
- `WALRUS_ARCHIVAL_URL`: (Optional Env Var) URL for the Walrus archival service.
- `WALRUS_AGGREGATOR_URL`: (Optional Env Var) URL for the Walrus aggregator.

### Example (Standard Aggregator)

Download 1,000 checkpoints using the HTTP aggregator:

```bash
cargo run --release --bin deepbook-indexer -- \
  --download-walrus-to ./checkpoints \
  --verification-start 238300000 \
  --verification-limit 1000 \
  --env mainnet
```

### Example (Walrus CLI - Recommended for Backfills)

Download checkpoints using the `walrus` CLI for maximum reliability:

```bash
cargo run --release --bin deepbook-indexer -- \
  --download-walrus-to ./checkpoints \
  --verification-start 238300000 \
  --verification-limit 1000 \
  --env mainnet \
  --walrus-cli-path walrus
```

> **Note:** The first time a blob is needed, the CLI will download the full 3GB blob to the cache directory (`./checkpoint_cache` by default). Subsequent extractions from the same blob will be extremely fast.
>
> **Robustness:** In CLI mode, the downloader parses blob indices directly from the downloaded files. This makes the process fully independent of the Walrus Aggregator's HTTP endpoints once the blobs are cached, protecting against aggregator timeouts or downtime.

### Output

The tool will save files named `<SEQUENCE_NUMBER>.chk` in the specified directory:

```
./checkpoints/
├── 238300000.chk
├── 238300001.chk
├── 238300002.chk
...
```

## Performance & Benchmarks

The downloader supports two modes: **Aggregator (HTTP)** and **CLI (Direct Node)**.

### **Aggregator Mode (Default)**
The default mode uses the Walrus Aggregator (HTTP Range requests). It is best for smaller ranges or limited disk space.
- **Throughput:** ~130 Checkpoints/sec.
- **Reliability:** High (now uses intra-blob chunking and automatic retries to handle proxy errors).
- **Usage:** Run the command normally without `--walrus-cli-path`.

### **Walrus CLI Mode (Optional)**
Optional high-reliability mode for massive historical backfills. Downloads full blobs (3GB) directly from storage nodes.
- **End-to-End Rate:** ~6 to 12 Checkpoints/sec (initial download).
- **Extraction Rate:** **>12,000 Checkpoints/sec** (once cached).
- **Reliability:** Absolute (direct p2p retrieval).
- **Usage:** Provide `--walrus-cli-path <PATH>` (e.g., `--walrus-cli-path walrus`).

**Verified Benchmark Data (Mainnet):**

Tests performed on a 15,000 checkpoint backfill spanning multiple blobs.

| Metric | Aggregator (HTTP) | Walrus CLI (Direct) |
| :--- | :--- | :--- |
| **Download Speed** | N/A | 1.20 - 2.10 MB/s |
| **Avg. Throughput** | **130.40 cp/s** | **6.16 - 11.84 cp/s** |
| **Max Extraction** | ~200 cp/s | **>12,000 cp/s** |

## Integration

The downloaded checkpoints can be used with any Sui indexer that supports local file ingestion:

```bash
cargo run --bin sui-indexer -- --local-ingestion-path ./checkpoints ...
```

