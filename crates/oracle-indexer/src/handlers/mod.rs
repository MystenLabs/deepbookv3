use crate::OracleEnv;
use sui_indexer_alt_framework::types::full_checkpoint_content::{ExecutedTransaction, ObjectSet};
use sui_types::transaction::{Command, TransactionDataAPI};

pub mod block_scholes_observation_inserted_handler;
pub mod block_scholes_observation_recorded_handler;
pub mod observation_map;
pub mod oracle_bound_handler;
pub mod oracle_source_registered_handler;
pub mod pyth_observation_inserted_handler;
pub mod pyth_observation_recorded_handler;

/// Macro to generate a complete flat oracle handler from minimal configuration.
///
/// Mirrors the predict indexer's `define_predict_handler!`; only the env/meta/
/// tx-filter differ. The `process` loop iterates
/// `checkpoint.transactions.iter().enumerate()` to capture `tx_index`, and per
/// event sets `package` from the event's own type address. The insert target is
/// `predict_schema::schema::$table`.
///
/// This is the right tool for the registry events (`OracleSourceRegistered`,
/// `OracleBound`) which are concrete (non-generic) structs. The observation
/// events are cross-package generics and need payload discrimination, so they
/// have hand-written handlers instead.
#[macro_export]
macro_rules! define_oracle_handler {
    {
        name: $handler:ident,
        processor_name: $proc_name:literal,
        event_type: $event:ty,
        db_model: $model:ty,
        table: $table:ident,
        map_event: |$ev:ident, $meta:ident| $body:expr
    } => {
        pub struct $handler {
            env: $crate::OracleEnv,
        }

        impl $handler {
            pub fn new(env: $crate::OracleEnv) -> Self {
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
                use $crate::handlers::is_propbook_tx;
                use $crate::meta::OracleEventMeta;
                use $crate::traits::MoveStruct;

                let mut results = vec![];
                for (tx_index, tx) in checkpoint.transactions.iter().enumerate() {
                    if !is_propbook_tx(tx, &checkpoint.object_set, self.env) {
                        continue;
                    }
                    let Some(events) = &tx.events else { continue };

                    let base_meta = OracleEventMeta::from_checkpoint_tx(checkpoint, tx, tx_index);

                    for (index, ev) in events.data.iter().enumerate() {
                        if <$event>::matches_event_type(&ev.type_, self.env) {
                            let $ev: $event = bcs::from_bytes(&ev.contents)?;
                            let $meta = base_meta
                                .with_event(index, ev.type_.address.to_canonical_string(true));
                            results.push($body);
                            tracing::debug!("Observed {} event", $proc_name);
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
                Ok(diesel::insert_into(predict_schema::schema::$table::table)
                    .values(values)
                    .on_conflict_do_nothing()
                    .execute(conn)
                    .await?)
            }
        }
    };
}

/// Used by oracle handlers to skip non-Propbook txs. Mirrors the predict
/// indexer's `is_predict_tx`, swapped to the Propbook package addresses.
pub(crate) fn is_propbook_tx(
    tx: &ExecutedTransaction,
    checkpoint_objects: &ObjectSet,
    env: OracleEnv,
) -> bool {
    let propbook_addresses = env.package_addresses();
    let propbook_packages = env.package_ids();

    // Check input objects against all known package versions
    let has_propbook_input = tx.input_objects(checkpoint_objects).any(|obj| {
        obj.data
            .type_()
            .map(|t| propbook_addresses.iter().any(|addr| t.address() == *addr))
            .unwrap_or_default()
    });

    if has_propbook_input {
        return true;
    }

    // Check if transaction has propbook events from any version
    if let Some(events) = &tx.events {
        let has_propbook_event = events
            .data
            .iter()
            .any(|event| propbook_addresses.contains(&event.type_.address));
        if has_propbook_event {
            return true;
        }
    }

    // Check if transaction calls a propbook function from any version
    let txn_kind = tx.transaction.kind();
    let has_propbook_call = txn_kind.iter_commands().any(|cmd| {
        if let Command::MoveCall(move_call) = cmd {
            propbook_packages.contains(&move_call.package)
        } else {
            false
        }
    });

    has_propbook_call
}
