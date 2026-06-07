//! Snapshot (integration) tests for Predict event handlers.
//!
//! These replay a real serialized checkpoint (`.chk` = a bcs `Blob` of
//! `CheckpointData`) through a handler and snapshot the resulting DB rows with
//! `insta`, mirroring `crates/indexer/tests/snapshot_tests.rs`.
//!
//! Predict is not deployed to a public network yet, so there is no checkpoint
//! to download (core fetches fixtures from `https://checkpoints.testnet.sui.io`;
//! see `crates/indexer/tests/README.md`). Until then these are `#[ignore]`'d
//! stubs; the fixture-free `decode_map_tests.rs` carries the coverage.
//!
//! TODO(testnet-deploy): once Predict is on testnet:
//!   1. testnet GraphQL: events(filter:{ type:
//!      "<predict_pkg>::order_events::OrderMinted" }) -> checkpoint seq number
//!   2. `curl -o <n>.chk "https://checkpoints.testnet.sui.io/<n>.chk"` into
//!      `crates/predict-indexer/tests/checkpoints/order_minted/`
//!   3. Copy the `data_test` / `run_pipeline` / `read_table` /
//!      `get_checkpoints_in_folder` harness from
//!      `crates/indexer/tests/snapshot_tests.rs:517-675`, swapping the
//!      migrations to `predict_schema::MIGRATIONS` and the handler to
//!      `OrderMintedHandler`.
//!   4. Remove the `#[ignore]` and accept the snapshot (`cargo insta accept`).

#[tokio::test]
#[ignore = "TODO(testnet-deploy): capture order_minted.chk from testnet, copy the harness, then remove this ignore"]
async fn order_minted() {
    // Intentionally empty until a testnet checkpoint fixture exists. See the
    // module-level TODO(testnet-deploy) for the capture + wiring recipe.
}
