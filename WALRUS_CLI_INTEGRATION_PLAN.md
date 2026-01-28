# Walrus CLI Integration Plan

## Goal
Integrate the `walrus` CLI as an alternative to the Aggregator URL for downloading checkpoints. This is intended to improve reliability and avoid timeouts by leveraging the CLI's direct connection to storage nodes.

## Design

### Configuration
- Add `walrus_cli_path: Option<PathBuf>` to `CheckpointStorageConfig`.
- If provided, the indexer will use the CLI for downloading blobs.

### Storage Logic (`WalrusCheckpointStorage`)
- **Hybrid Mode:** The storage will support both HTTP (Aggregator) and CLI (File-based) access.
- **CLI Download:** When `walrus_cli_path` is configured:
    - Before fetching checkpoints from a blob, the system will ensure the *full* blob is downloaded to the `cache_dir` using `walrus read <blob_id> -o <path>`.
    - Once downloaded, `download_range` will read bytes directly from the local file instead of making HTTP range requests.
- **Fallback/Legacy:** If `walrus_cli_path` is not set, it defaults to the existing HTTP Aggregator behavior (Range requests).

### Performance Considerations
- **Full Blob Download:** The CLI approach requires downloading the entire blob (2-3 GB). This is optimal for "full backfills" where we need most data, but heavier for random access.
- **Caching:** The downloaded blobs are cached in `cache_dir`. Subsequent reads are local and instant.
- **Concurrency:** 
    - Blob downloading via CLI is sequential per-blob (to avoid race conditions on the file).
    - Checkpoint extraction from the local file is parallelized.

## Changes

1.  **`crates/indexer/src/checkpoint_storage_config.rs`**: Add `walrus_cli_path` field.
2.  **`crates/indexer/src/walrus_storage.rs`**:
    - Refactor `WalrusCheckpointStorage` to use `Arc<Inner>` for cheap cloning (enabling `self` usage in async tasks).
    - Add `download_blob_via_cli` method.
    - Update `download_range` to check for local file -> CLI download -> HTTP fallback.
    - Update `get_checkpoints` and `download_checkpoints_to_dir` to trigger CLI download before parallel processing.
3.  **`crates/indexer/src/main.rs`**: Pass the CLI path from config to the storage constructor.

## Verification
- Test with `walrus` binary available in path.
- Verify full blob download occurs.
- Verify checkpoints are extracted correctly from the local file.
