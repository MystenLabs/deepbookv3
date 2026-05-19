use std::sync::Arc;
use sui_indexer_alt_framework::types::full_checkpoint_content::{
    Checkpoint, ExecutedTransaction, ObjectSet,
};
use sui_types::effects::TransactionEffectsAPI;
use sui_types::transaction::{Command, TransactionDataAPI};
use crate::DeepbookEnv;

pub struct EventMeta {
    digest: Arc<str>,
    sender: Arc<str>,
    checkpoint: i64,
    checkpoint_timestamp_ms: i64,
    package: Arc<str>,
    event_index: usize,
}

impl EventMeta {
    pub fn from_checkpoint_tx(checkpoint: &Checkpoint, tx: &ExecutedTransaction) -> Self {
        Self {
            digest: tx.effects.transaction_digest().to_string().into(),
            sender: tx.transaction.sender().to_string().into(),
            checkpoint: checkpoint.summary.sequence_number as i64,
            checkpoint_timestamp_ms: checkpoint.summary.timestamp_ms as i64,
            package: try_extract_move_call_package(tx).unwrap_or_default().into(),
            event_index: 0,
        }
    }

    pub fn with_index(&self, index: usize) -> Self {
        Self {
            digest: Arc::clone(&self.digest),
            sender: Arc::clone(&self.sender),
            checkpoint: self.checkpoint,
            checkpoint_timestamp_ms: self.checkpoint_timestamp_ms,
            package: Arc::clone(&self.package),
            event_index: index,
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

    pub fn checkpoint_timestamp_ms(&self) -> i64 {
        self.checkpoint_timestamp_ms
    }

    pub fn package(&self) -> String {
        self.package.to_string()
    }
}

#[macro_export]
macro_rules! define_predict_handler {
    {
        name: $handler:ident,
        processor_name: $proc_name:literal,
        event_type: $event:ty,
        db_model: $model:ty,
        table: $table:ident,
        map_event: |$ev:ident, $meta:ident| $body:expr
    } => {
        pub struct $handler {
            env: $crate::DeepbookEnv,
        }

        impl $handler {
            pub fn new(env: $crate::DeepbookEnv) -> Self {
                Self { env }
            }
        }

        #[async_trait::async_trait]
        impl sui_indexer_alt_framework::pipeline::Processor for $handler {
            const NAME: &'static str = $proc_name;
            type Value = $model;

            async fn process(
                &self,
                checkpoint: &std::sync::Arc<sui_indexer_alt_framework::types::full_checkpoint_content::Checkpoint>,
            ) -> anyhow::Result<Vec<Self::Value>> {
                use $crate::handlers::{is_predict_tx, EventMeta};
                use $crate::traits::MoveStruct;

                let mut results = vec![];
                for tx in &checkpoint.transactions {
                    if !is_predict_tx(tx, &checkpoint.object_set, self.env) {
                        continue;
                    }
                    let Some(events) = &tx.events else { continue };

                    let base_meta = EventMeta::from_checkpoint_tx(checkpoint, tx);

                    for (index, ev) in events.data.iter().enumerate() {
                        if <$event>::matches_event_type(&ev.type_, self.env) {
                            let $ev: $event = bcs::from_bytes(&ev.contents)?;
                            let $meta = base_meta.with_index(index);
                            results.push($body);
                        }
                    }
                }
                Ok(results)
            }
        }

        #[async_trait::async_trait]
        impl sui_indexer_alt_framework::postgres::handler::Handler for $handler {
            async fn commit<'a>(
                values: &[Self::Value],
                conn: &mut sui_pg_db::Connection<'a>,
            ) -> anyhow::Result<usize> {
                use diesel_async::RunQueryDsl;
                Ok(diesel::insert_into(deepbook_predict_schema::schema::$table::table)
                    .values(values)
                    .on_conflict_do_nothing()
                    .execute(conn)
                    .await?)
            }
        }
    };
}

pub mod minted_handler;
pub mod redeemed_handler;
pub mod settled_handler;
pub mod supplied_handler;
pub mod withdrawn_handler;

pub(crate) fn is_predict_tx(
    tx: &ExecutedTransaction,
    _checkpoint_objects: &ObjectSet,
    env: DeepbookEnv,
) -> bool {
    let predict_addresses = env.package_addresses();
    let predict_packages = env.package_ids();

    // Check if transaction has predict events
    if let Some(events) = &tx.events {
        let has_predict_event = events.data.iter().any(|event| {
            predict_addresses
                .iter()
                .any(|addr| event.type_.address == *addr)
        });
        if has_predict_event {
            return true;
        }
    }

    // Check if transaction calls a predict function
    let txn_kind = tx.transaction.kind();
    let has_predict_call = txn_kind.iter_commands().any(|cmd| {
        if let Command::MoveCall(move_call) = cmd {
            predict_packages
                .iter()
                .any(|pkg| *pkg == move_call.package)
        } else {
            false
        }
    });

    has_predict_call
}

pub(crate) fn try_extract_move_call_package(tx: &ExecutedTransaction) -> Option<String> {
    let txn_kind = tx.transaction.kind();
    let first_command = txn_kind.iter_commands().next()?;
    if let Command::MoveCall(move_call) = first_command {
        Some(move_call.package.to_string())
    } else {
        None
    }
}
