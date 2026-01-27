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

The downloader uses parallel fetching (concurrency: 50) for extraction, but the primary bottleneck is the Walrus blob download speed.

**Observed Metrics (Mainnet):**
- **Network Speed:** ~1.2 MB/s to 2.1 MB/s (varies by network/node).
- **Throughput:** ~6 to 12 Checkpoints/sec (end-to-end including download).
- **Extraction Speed:** >12,000 Checkpoints/sec (once blob is cached).

**Example Data:**
- **Blob Size:** ~2.7 GB
- **Checkpoints per Blob:** ~14,000
- **Download Time:** ~20-40 minutes per blob.

## Integration

The downloaded checkpoints can be used with any Sui indexer that supports local file ingestion:

```bash
cargo run --bin sui-indexer -- --local-ingestion-path ./checkpoints ...
```

