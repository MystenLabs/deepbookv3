use crate::DeepbookEnv;
use std::sync::Arc;
use sui_indexer_alt_framework::types::full_checkpoint_content::{
    Checkpoint, ExecutedTransaction, ObjectSet,
};
use sui_types::effects::TransactionEffectsAPI;
use sui_types::transaction::{Command, TransactionDataAPI};

/// Captures common transaction metadata for event processing.
/// Used by the `define_handler!` macro to avoid repetitive field extraction.
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

/// Macro to generate a complete handler from minimal configuration.
///
/// This macro generates the handler struct, constructor, `Processor` impl,
/// and `Handler` impl from a declarative specification.
///
/// # Example
/// ```ignore
/// define_handler! {
///     name: BalancesHandler,
///     processor_name: "balances",
///     event_type: BalanceEvent,
///     db_model: Balances,
///     table: balances,
///     map_event: |event, meta| Balances {
///         event_digest: meta.event_digest(),
///         digest: meta.digest(),
///         // ... field mappings
///     }
/// }
/// ```
#[macro_export]
macro_rules! define_handler {
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
                use $crate::handlers::{is_deepbook_tx, EventMeta};
                use $crate::traits::MoveStruct;

                let mut results = vec![];
                for tx in &checkpoint.transactions {
                    if !is_deepbook_tx(tx, &checkpoint.object_set, self.env) {
                        continue;
                    }
                    let Some(events) = &tx.events else { continue };

                    let base_meta = EventMeta::from_checkpoint_tx(checkpoint, tx);

                    for (index, ev) in events.data.iter().enumerate() {
                        if <$event>::matches_event_type(&ev.type_, self.env) {
                            let $ev: $event = bcs::from_bytes(&ev.contents)?;
                            let $meta = base_meta.with_index(index);
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
                Ok(diesel::insert_into(deepbook_schema::schema::$table::table)
                    .values(values)
                    .on_conflict_do_nothing()
                    .execute(conn)
                    .await?)
            }
        }
    };
}
pub mod asset_supplied_handler;
pub mod asset_withdrawn_handler;
pub mod balances_handler;
pub mod conditional_order_added_handler;
pub mod conditional_order_cancelled_handler;
pub mod conditional_order_executed_handler;
pub mod conditional_order_insufficient_funds_handler;
pub mod deep_burned_handler;
pub mod deepbook_pool_config_updated_handler;
pub mod deepbook_pool_registered_handler;
pub mod deepbook_pool_updated_handler;
pub mod deepbook_pool_updated_registry_handler;
pub mod deposit_collateral_handler;
pub mod flash_loan_handler;
pub mod interest_params_updated_handler;
pub mod liquidation_handler;
pub mod loan_borrowed_handler;
pub mod loan_repaid_handler;
pub mod maintainer_cap_updated_handler;
pub mod maintainer_fees_withdrawn_handler;
pub mod margin_manager_created_handler;
pub mod margin_pool_config_updated_handler;
pub mod margin_pool_created_handler;
pub mod order_fill_handler;
pub mod order_update_handler;
pub mod pause_cap_updated_handler;
pub mod pool_created_handler;
pub mod pool_price_handler;
pub mod proposals_handler;
pub mod protocol_fees_increased_handler;
pub mod protocol_fees_withdrawn_handler;
pub mod rebates_handler;
pub mod referral_fee_event_handler;
pub mod referral_fees_claimed_handler;
pub mod stakes_handler;
pub mod supplier_cap_minted_handler;
pub mod supply_referral_minted_handler;
pub mod trade_params_update_handler;
pub mod vote_handler;
pub mod withdraw_collateral_handler;

pub(crate) fn is_deepbook_tx(
    tx: &ExecutedTransaction,
    checkpoint_objects: &ObjectSet,
    env: DeepbookEnv,
) -> bool {
    let deepbook_addresses = env.package_addresses();
    let deepbook_packages = env.package_ids();

    // Check input objects against all known package versions
    let has_deepbook_input = tx.input_objects(checkpoint_objects).any(|obj| {
        obj.data
            .type_()
            .map(|t| deepbook_addresses.iter().any(|addr| t.address() == *addr))
            .unwrap_or_default()
    });

    if has_deepbook_input {
        return true;
    }

    // Check if transaction has deepbook events from any version
    if let Some(events) = &tx.events {
        let has_deepbook_event = events.data.iter().any(|event| {
            deepbook_addresses
                .iter()
                .any(|addr| event.type_.address == *addr)
        });
        if has_deepbook_event {
            return true;
        }
    }

    // Check if transaction calls a deepbook function from any version
    let txn_kind = tx.transaction.kind();
    let has_deepbook_call = txn_kind.iter_commands().any(|cmd| {
        if let Command::MoveCall(move_call) = cmd {
            deepbook_packages
                .iter()
                .any(|pkg| *pkg == move_call.package)
        } else {
            false
        }
    });

    has_deepbook_call
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
