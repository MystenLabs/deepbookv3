use crate::PredictEnv;
use sui_indexer_alt_framework::types::full_checkpoint_content::{ExecutedTransaction, ObjectSet};
use sui_types::transaction::{Command, TransactionDataAPI};

pub mod builder_code_created_handler;
pub mod builder_code_set_handler;
pub mod builder_fees_claimed_handler;
pub mod deep_staked_handler;
pub mod deep_unstaked_handler;
pub mod ewma_config_updated_handler;
pub mod expiry_cash_rebalanced_handler;
pub mod expiry_cash_received_handler;
pub mod expiry_cash_template_config_updated_handler;
pub mod expiry_market_mint_paused_updated_handler;
pub mod expiry_profit_materialized_handler;
pub mod flush_executed_handler;
pub mod liquidated_order_redeemed_handler;
pub mod live_order_redeemed_handler;
pub mod lp_request_state_handler;
pub mod market_config_snapshot_handler;
pub mod market_created_handler;
pub mod market_settled_handler;
pub mod order_liquidated_handler;
pub mod order_minted_handler;
pub mod order_state_handler;
pub mod predict_deposit_cap_minted_handler;
pub mod predict_manager_created_handler;
pub mod predict_trade_cap_minted_handler;
pub mod predict_withdraw_cap_minted_handler;
pub mod pricing_config_updated_handler;
pub mod request_cancelled_handler;
pub mod risk_config_updated_handler;
pub mod settled_order_redeemed_handler;
pub mod stake_config_updated_handler;
pub mod strike_exposure_template_config_updated_handler;
pub mod supply_filled_handler;
pub mod supply_requested_handler;
pub mod trading_paused_updated_handler;
pub mod withdraw_filled_handler;
pub mod withdraw_requested_handler;

/// Macro to generate a complete Predict handler from minimal configuration.
///
/// Mirrors core's `define_handler!` (`crates/indexer/src/handlers/mod.rs`) with
/// two changes in the `process` loop:
/// 1. It iterates `checkpoint.transactions.iter().enumerate()` to capture
///    `tx_index`, threaded into `PredictEventMeta::from_checkpoint_tx`.
/// 2. Per event it sets `package` from the event's own type address via
///    `base_meta.with_event(index, ev.type_.address.to_canonical_string(true))`,
///    matching the `0x`-prefixed, zero-padded form of every other id column.
///
/// The insert target is `predict_schema::schema::$table`.
///
/// # Example
/// ```ignore
/// define_predict_handler! {
///     name: OrderMintedHandler,
///     processor_name: "order_minted",
///     event_type: OrderMintedEvent,
///     db_model: OrderMinted,
///     table: order_minted,
///     map_event: |event, meta| OrderMinted {
///         event_digest: meta.event_digest(),
///         // ... field mappings
///     }
/// }
/// ```
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
            env: $crate::PredictEnv,
        }

        impl $handler {
            pub fn new(env: $crate::PredictEnv) -> Self {
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
                use $crate::handlers::is_predict_tx;
                use $crate::meta::PredictEventMeta;
                use $crate::traits::MoveStruct;

                let mut results = vec![];
                for (tx_index, tx) in checkpoint.transactions.iter().enumerate() {
                    if !is_predict_tx(tx, &checkpoint.object_set, self.env) {
                        continue;
                    }
                    let Some(events) = &tx.events else { continue };

                    let base_meta = PredictEventMeta::from_checkpoint_tx(checkpoint, tx, tx_index);

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

/// Used by `define_predict_handler!`-generated handlers to skip non-Predict txs.
pub(crate) fn is_predict_tx(
    tx: &ExecutedTransaction,
    checkpoint_objects: &ObjectSet,
    env: PredictEnv,
) -> bool {
    let predict_addresses = env.package_addresses();
    let predict_packages = env.package_ids();

    // Check input objects against all known package versions
    let has_predict_input = tx.input_objects(checkpoint_objects).any(|obj| {
        obj.data
            .type_()
            .map(|t| predict_addresses.iter().any(|addr| t.address() == *addr))
            .unwrap_or_default()
    });

    if has_predict_input {
        return true;
    }

    // Check if transaction has predict events from any version
    if let Some(events) = &tx.events {
        let has_predict_event = events
            .data
            .iter()
            .any(|event| predict_addresses.contains(&event.type_.address));
        if has_predict_event {
            return true;
        }
    }

    // Check if transaction calls a predict function from any version
    let txn_kind = tx.transaction.kind();
    let has_predict_call = txn_kind.iter_commands().any(|cmd| {
        if let Command::MoveCall(move_call) = cmd {
            predict_packages.contains(&move_call.package)
        } else {
            false
        }
    });

    has_predict_call
}
