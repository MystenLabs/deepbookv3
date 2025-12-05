use crate::handlers::{is_deepbook_tx, try_extract_move_call_package};
use crate::models::deepbook_margin::margin_registry::DeepbookPoolConfigUpdated;
use crate::traits::MoveStruct;
use crate::DeepbookEnv;
use async_trait::async_trait;
use deepbook_schema::models::DeepbookPoolConfigUpdated as DeepbookPoolConfigUpdatedModel;
use deepbook_schema::schema::deepbook_pool_config_updated;
use diesel_async::RunQueryDsl;
use serde_json;
use std::sync::Arc;
use sui_indexer_alt_framework::pipeline::concurrent::Handler;
use sui_indexer_alt_framework::pipeline::Processor;
use sui_pg_db::{Connection, Db};
use sui_types::full_checkpoint_content::CheckpointData;
use tracing::debug;

pub struct DeepbookPoolConfigUpdatedHandler {
    env: DeepbookEnv,
}

impl DeepbookPoolConfigUpdatedHandler {
    pub fn new(env: DeepbookEnv) -> Self {
        Self { env }
    }
}

impl Processor for DeepbookPoolConfigUpdatedHandler {
    const NAME: &'static str = "deepbook_pool_config_updated";
    type Value = DeepbookPoolConfigUpdatedModel;

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
                if DeepbookPoolConfigUpdated::matches_event_type(&ev.type_, self.env) {
                    let event: DeepbookPoolConfigUpdated = bcs::from_bytes(&ev.contents)?;
                    let config_json = serde_json::to_value(&event.config)?;
                    let data = DeepbookPoolConfigUpdatedModel {
                        event_digest: format!("{digest}{index}"),
                        digest: digest.to_string(),
                        sender: tx.transaction.sender_address().to_string(),
                        checkpoint,
                        checkpoint_timestamp_ms,
                        package: package.clone(),
                        pool_id: event.pool_id.to_string(),
                        config_json,
                        onchain_timestamp: event.timestamp as i64,
                    };
                    debug!("Observed DeepBook Margin Pool Config Updated {:?}", data);
                    results.push(data);
                }
            }
        }
        Ok(results)
    }
}

#[async_trait]
impl Handler for DeepbookPoolConfigUpdatedHandler {
    type Store = Db;

    async fn commit<'a>(
        values: &[Self::Value],
        conn: &mut Connection<'a>,
    ) -> anyhow::Result<usize> {
        Ok(diesel::insert_into(deepbook_pool_config_updated::table)
            .values(values)
            .on_conflict_do_nothing()
            .execute(conn)
            .await?)
    }
}
