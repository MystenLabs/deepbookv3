use crate::handlers::{is_deepbook_tx, try_extract_move_call_package};
use crate::models::deepbook_margin::margin_pool::{AssetSupplied, AssetWithdrawn};
use crate::DeepbookEnv;
use async_trait::async_trait;
use deepbook_schema::models::MarginPoolOperations;
use deepbook_schema::schema::margin_pool_operations;
use diesel_async::RunQueryDsl;
use move_core_types::language_storage::StructTag;
use std::sync::Arc;
use sui_indexer_alt_framework::pipeline::concurrent::Handler;
use sui_indexer_alt_framework::pipeline::Processor;
use sui_pg_db::{Connection, Db};
use sui_types::full_checkpoint_content::CheckpointData;
use tracing::debug;

pub struct MarginPoolOperationsHandler {
    asset_supplied_event_type: StructTag,
    asset_withdrawn_event_type: StructTag,
    env: DeepbookEnv,
}

impl MarginPoolOperationsHandler {
    pub fn new(env: DeepbookEnv) -> Self {
        Self {
            asset_supplied_event_type: env.asset_supplied_event_type(),
            asset_withdrawn_event_type: env.asset_withdrawn_event_type(),
            env,
        }
    }
}

impl Processor for MarginPoolOperationsHandler {
    const NAME: &'static str = "margin_pool_operations";
    type Value = MarginPoolOperations;

    fn process(&self, checkpoint: &Arc<CheckpointData>) -> anyhow::Result<Vec<Self::Value>> {
        let mut results = vec![];

        for tx in &checkpoint.transactions {
            if !is_deepbook_tx(tx, self.env) {
                continue;
            }
            let Some(events) = &tx.events else {
                continue;
            };

            let package = try_extract_move_call_package(tx).unwrap_or_default();
            let checkpoint_timestamp_ms = checkpoint.checkpoint_summary.timestamp_ms as i64;
            let checkpoint = checkpoint.checkpoint_summary.sequence_number as i64;
            let digest = tx.transaction.digest();

            for (index, ev) in events.data.iter().enumerate() {
                if ev.type_ == self.asset_supplied_event_type {
                    let event: AssetSupplied = bcs::from_bytes(&ev.contents)?;
                    let data = MarginPoolOperations {
                        event_digest: format!("{digest}{index}"),
                        digest: digest.to_string(),
                        sender: tx.transaction.sender_address().to_string(),
                        checkpoint,
                        checkpoint_timestamp_ms,
                        package: package.clone(),
                        margin_pool_id: event.margin_pool_id.to_string(),
                        asset_type: event.asset_type.to_string(),
                        supplier: event.supplier.to_string(),
                        amount: event.supply_amount as i64,
                        shares: event.supply_shares as i64,
                        operation_type: "supply".to_string(),
                        onchain_timestamp: event.timestamp as i64,
                    };
                    debug!("Observed DeepBook Margin Asset Supplied {:?}", data);
                    results.push(data);
                } else if ev.type_ == self.asset_withdrawn_event_type {
                    let event: AssetWithdrawn = bcs::from_bytes(&ev.contents)?;
                    let data = MarginPoolOperations {
                        event_digest: format!("{digest}{index}"),
                        digest: digest.to_string(),
                        sender: tx.transaction.sender_address().to_string(),
                        checkpoint,
                        checkpoint_timestamp_ms,
                        package: package.clone(),
                        margin_pool_id: event.margin_pool_id.to_string(),
                        asset_type: event.asset_type.to_string(),
                        supplier: event.supplier.to_string(),
                        amount: event.withdraw_amount as i64,
                        shares: event.withdraw_shares as i64,
                        operation_type: "withdraw".to_string(),
                        onchain_timestamp: event.timestamp as i64,
                    };
                    debug!("Observed DeepBook Margin Asset Withdrawn {:?}", data);
                    results.push(data);
                }
            }
        }
        Ok(results)
    }
}

#[async_trait]
impl Handler for MarginPoolOperationsHandler {
    type Store = Db;

    async fn commit<'a>(
        values: &[Self::Value],
        conn: &mut Connection<'a>,
    ) -> anyhow::Result<usize> {
        Ok(diesel::insert_into(margin_pool_operations::table)
            .values(values)
            .on_conflict_do_nothing()
            .execute(conn)
            .await?)
    }
}
