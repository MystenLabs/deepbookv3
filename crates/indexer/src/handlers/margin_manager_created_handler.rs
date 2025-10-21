use crate::handlers::{is_deepbook_tx, try_extract_move_call_package};
use crate::models::deepbook_margin::margin_manager::MarginManagerEvent;
use crate::DeepbookEnv;
use async_trait::async_trait;
use deepbook_schema::models::MarginManagerCreated;
use deepbook_schema::schema::margin_manager_created;
use diesel_async::RunQueryDsl;
use move_core_types::language_storage::StructTag;
use std::sync::Arc;
use sui_indexer_alt_framework::pipeline::concurrent::Handler;
use sui_indexer_alt_framework::pipeline::Processor;
use sui_pg_db::{Connection, Db};
use sui_types::full_checkpoint_content::CheckpointData;
use tracing::debug;

pub struct MarginManagerCreatedHandler {
    margin_manager_event_type: StructTag,
    env: DeepbookEnv,
}

impl MarginManagerCreatedHandler {
    pub fn new(env: DeepbookEnv) -> Self {
        Self {
            margin_manager_event_type: env.margin_manager_event_type(),
            env,
        }
    }
}

impl Processor for MarginManagerCreatedHandler {
    const NAME: &'static str = "margin_manager_created";
    type Value = MarginManagerCreated;

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
                if ev.type_ == self.margin_manager_event_type {
                    let event: MarginManagerEvent = bcs::from_bytes(&ev.contents)?;
                    let data = MarginManagerCreated {
                        event_digest: format!("{digest}{index}"),
                        digest: digest.to_string(),
                        sender: tx.transaction.sender_address().to_string(),
                        checkpoint,
                        checkpoint_timestamp_ms,
                        package: package.clone(),
                        margin_manager_id: event.margin_manager_id.to_string(),
                        balance_manager_id: event.balance_manager_id.to_string(),
                        owner: event.owner.to_string(),
                        onchain_timestamp: event.timestamp as i64,
                    };
                    debug!("Observed DeepBook Margin Manager Created {:?}", data);
                    results.push(data);
                }
            }
        }
        Ok(results)
    }
}

#[async_trait]
impl Handler for MarginManagerCreatedHandler {
    type Store = Db;

    async fn commit<'a>(
        values: &[Self::Value],
        conn: &mut Connection<'a>,
    ) -> anyhow::Result<usize> {
        Ok(diesel::insert_into(margin_manager_created::table)
            .values(values)
            .on_conflict_do_nothing()
            .execute(conn)
            .await?)
    }
}
