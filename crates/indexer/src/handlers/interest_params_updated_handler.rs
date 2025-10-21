use crate::handlers::{is_deepbook_tx, try_extract_move_call_package};
use crate::models::deepbook_margin::margin_pool::InterestParamsUpdated;
use crate::DeepbookEnv;
use async_trait::async_trait;
use deepbook_schema::models::InterestParamsUpdated as InterestParamsUpdatedModel;
use deepbook_schema::schema::interest_params_updated;
use diesel_async::RunQueryDsl;
use move_core_types::language_storage::StructTag;
use serde_json;
use std::sync::Arc;
use sui_indexer_alt_framework::pipeline::concurrent::Handler;
use sui_indexer_alt_framework::pipeline::Processor;
use sui_pg_db::{Connection, Db};
use sui_types::full_checkpoint_content::CheckpointData;
use tracing::debug;

pub struct InterestParamsUpdatedHandler {
    interest_params_updated_event_type: StructTag,
    env: DeepbookEnv,
}

impl InterestParamsUpdatedHandler {
    pub fn new(env: DeepbookEnv) -> Self {
        Self {
            interest_params_updated_event_type: env.interest_params_updated_event_type(),
            env,
        }
    }
}

impl Processor for InterestParamsUpdatedHandler {
    const NAME: &'static str = "interest_params_updated";
    type Value = InterestParamsUpdatedModel;

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
                if ev.type_ == self.interest_params_updated_event_type {
                    let event: InterestParamsUpdated = bcs::from_bytes(&ev.contents)?;
                    let config_json = serde_json::to_value(&event.interest_config)?;
                    let data = InterestParamsUpdatedModel {
                        event_digest: format!("{digest}{index}"),
                        digest: digest.to_string(),
                        sender: tx.transaction.sender_address().to_string(),
                        checkpoint,
                        checkpoint_timestamp_ms,
                        package: package.clone(),
                        margin_pool_id: event.margin_pool_id.to_string(),
                        pool_cap_id: event.pool_cap_id.to_string(),
                        config_json,
                        onchain_timestamp: event.timestamp as i64,
                    };
                    debug!("Observed DeepBook Margin Interest Params Updated {:?}", data);
                    results.push(data);
                }
            }
        }
        Ok(results)
    }
}

#[async_trait]
impl Handler for InterestParamsUpdatedHandler {
    type Store = Db;

    async fn commit<'a>(
        values: &[Self::Value],
        conn: &mut Connection<'a>,
    ) -> anyhow::Result<usize> {
        Ok(diesel::insert_into(interest_params_updated::table)
            .values(values)
            .on_conflict_do_nothing()
            .execute(conn)
            .await?)
    }
}
