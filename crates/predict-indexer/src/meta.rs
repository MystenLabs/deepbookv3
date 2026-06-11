use std::sync::Arc;
use sui_indexer_alt_framework::types::full_checkpoint_content::{Checkpoint, ExecutedTransaction};
use sui_types::effects::TransactionEffectsAPI;
use sui_types::transaction::TransactionDataAPI;

/// Captures common transaction metadata for event processing.
///
/// Mirrors core's `EventMeta` (`crates/indexer/src/handlers/mod.rs`) with two
/// deliberate improvements:
/// 1. Adds `tx_index` (the transaction's position within the checkpoint) so raw
///    rows can be totally ordered by `(checkpoint, tx_index, event_index)` instead
///    of tying on `checkpoint_timestamp_ms`.
/// 2. `package` is set per-event from the event's own type address
///    (`ev.type_.address.to_canonical_string(true)`, i.e. `0x`-prefixed and
///    zero-padded) rather than the PTB's first MoveCall, which is wrong for
///    router/aggregator txs.
pub struct PredictEventMeta {
    digest: Arc<str>,
    sender: Arc<str>,
    checkpoint: i64,
    tx_index: i64,
    checkpoint_timestamp_ms: i64,
    event_index: usize,
    package: Arc<str>,
}

impl PredictEventMeta {
    pub fn from_checkpoint_tx(
        checkpoint: &Checkpoint,
        tx: &ExecutedTransaction,
        tx_index: usize,
    ) -> Self {
        Self {
            digest: tx.effects.transaction_digest().to_string().into(),
            sender: tx.transaction.sender().to_string().into(),
            checkpoint: checkpoint.summary.sequence_number as i64,
            tx_index: tx_index as i64,
            checkpoint_timestamp_ms: checkpoint.summary.timestamp_ms as i64,
            event_index: 0,
            package: Arc::from(""),
        }
    }

    /// Clone with the per-event index AND the event's own type address as `package`.
    pub fn with_event(&self, index: usize, package: String) -> Self {
        Self {
            digest: Arc::clone(&self.digest),
            sender: Arc::clone(&self.sender),
            checkpoint: self.checkpoint,
            tx_index: self.tx_index,
            checkpoint_timestamp_ms: self.checkpoint_timestamp_ms,
            event_index: index,
            package: package.into(),
        }
    }

    /// Always-compiled test constructor so `tests/` integration tests (which
    /// cannot see `#[cfg(test)]` items) can build a meta for `map()` unit tests.
    pub fn for_test(
        digest: &str,
        sender: &str,
        checkpoint: i64,
        tx_index: i64,
        ts_ms: i64,
        event_index: usize,
        package: &str,
    ) -> Self {
        Self {
            digest: digest.into(),
            sender: sender.into(),
            checkpoint,
            tx_index,
            checkpoint_timestamp_ms: ts_ms,
            event_index,
            package: package.into(),
        }
    }

    pub fn event_digest(&self) -> String {
        format!("{}{}", self.digest, self.event_index)
    }

    pub fn digest(&self) -> String {
        self.digest.to_string()
    }

    pub fn sender(&self) -> String {
        self.sender.to_string()
    }

    pub fn checkpoint(&self) -> i64 {
        self.checkpoint
    }

    pub fn tx_index(&self) -> i64 {
        self.tx_index
    }

    pub fn event_index(&self) -> i64 {
        self.event_index as i64
    }

    pub fn checkpoint_timestamp_ms(&self) -> i64 {
        self.checkpoint_timestamp_ms
    }

    pub fn package(&self) -> String {
        self.package.to_string()
    }
}
