use crate::handlers::{is_deepbook_tx, try_extract_move_call_package};
use crate::models::deepbook_margin::margin_registry::{
    DeepbookPoolConfigUpdated, DeepbookPoolRegistered, DeepbookPoolUpdated, MaintainerCapUpdated,
};
use crate::DeepbookEnv;
use async_trait::async_trait;
use deepbook_schema::models::MarginRegistryEvents;
use deepbook_schema::schema::margin_registry_events;
use diesel_async::RunQueryDsl;
use move_core_types::language_storage::StructTag;
use serde_json;
use std::sync::Arc;
use sui_indexer_alt_framework::pipeline::concurrent::Handler;
use sui_indexer_alt_framework::pipeline::Processor;
use sui_pg_db::{Connection, Db};
use sui_types::full_checkpoint_content::CheckpointData;
use tracing::debug;

pub struct MarginRegistryHandler {
    maintainer_cap_updated_event_type: StructTag,
    deepbook_pool_registered_event_type: StructTag,
    deepbook_pool_updated_event_type: StructTag,
    deepbook_pool_config_updated_event_type: StructTag,
    env: DeepbookEnv,
}

impl MarginRegistryHandler {
    pub fn new(env: DeepbookEnv) -> Self {
        Self {
            maintainer_cap_updated_event_type: env.maintainer_cap_updated_event_type(),
            deepbook_pool_registered_event_type: env.deepbook_pool_registered_event_type(),
            deepbook_pool_updated_event_type: env.deepbook_margin_pool_updated_event_type(),
            deepbook_pool_config_updated_event_type: env.deepbook_pool_config_updated_event_type(),
            env,
        }
    }
}

impl Processor for MarginRegistryHandler {
    const NAME: &'static str = "margin_registry_events";
    type Value = MarginRegistryEvents;

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
                if ev.type_ == self.maintainer_cap_updated_event_type {
                    let event: MaintainerCapUpdated = bcs::from_bytes(&ev.contents)?;
                    let data = MarginRegistryEvents {
                        event_digest: format!("{digest}{index}"),
                        digest: digest.to_string(),
                        sender: tx.transaction.sender_address().to_string(),
                        checkpoint,
                        checkpoint_timestamp_ms,
                        package: package.clone(),
                        event_type: "maintainer_cap_updated".to_string(),
                        maintainer_cap_id: Some(event.maintainer_cap_id.to_string()),
                        allowed: Some(event.allowed),
                        pool_id: None,
                        enabled: None,
                        config_json: None,
                        onchain_timestamp: event.timestamp as i64,
                    };
                    debug!("Observed DeepBook Margin Maintainer Cap Updated {:?}", data);
                    results.push(data);
                } else if ev.type_ == self.deepbook_pool_registered_event_type {
                    let event: DeepbookPoolRegistered = bcs::from_bytes(&ev.contents)?;
                    let data = MarginRegistryEvents {
                        event_digest: format!("{digest}{index}"),
                        digest: digest.to_string(),
                        sender: tx.transaction.sender_address().to_string(),
                        checkpoint,
                        checkpoint_timestamp_ms,
                        package: package.clone(),
                        event_type: "pool_registered".to_string(),
                        maintainer_cap_id: None,
                        allowed: None,
                        pool_id: Some(event.pool_id.to_string()),
                        enabled: None,
                        config_json: None,
                        onchain_timestamp: event.timestamp as i64,
                    };
                    debug!("Observed DeepBook Margin Pool Registered {:?}", data);
                    results.push(data);
                } else if ev.type_ == self.deepbook_pool_updated_event_type {
                    let event: DeepbookPoolUpdated = bcs::from_bytes(&ev.contents)?;
                    let data = MarginRegistryEvents {
                        event_digest: format!("{digest}{index}"),
                        digest: digest.to_string(),
                        sender: tx.transaction.sender_address().to_string(),
                        checkpoint,
                        checkpoint_timestamp_ms,
                        package: package.clone(),
                        event_type: "pool_updated".to_string(),
                        maintainer_cap_id: None,
                        allowed: None,
                        pool_id: Some(event.pool_id.to_string()),
                        enabled: Some(event.enabled),
                        config_json: None,
                        onchain_timestamp: event.timestamp as i64,
                    };
                    debug!("Observed DeepBook Margin Pool Updated {:?}", data);
                    results.push(data);
                } else if ev.type_ == self.deepbook_pool_config_updated_event_type {
                    let event: DeepbookPoolConfigUpdated = bcs::from_bytes(&ev.contents)?;
                    let config_json = serde_json::to_value(&event.config).ok();
                    let data = MarginRegistryEvents {
                        event_digest: format!("{digest}{index}"),
                        digest: digest.to_string(),
                        sender: tx.transaction.sender_address().to_string(),
                        checkpoint,
                        checkpoint_timestamp_ms,
                        package: package.clone(),
                        event_type: "pool_config_updated".to_string(),
                        maintainer_cap_id: None,
                        allowed: None,
                        pool_id: Some(event.pool_id.to_string()),
                        enabled: None,
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
impl Handler for MarginRegistryHandler {
    type Store = Db;

    async fn commit<'a>(
        values: &[Self::Value],
        conn: &mut Connection<'a>,
    ) -> anyhow::Result<usize> {
        Ok(diesel::insert_into(margin_registry_events::table)
            .values(values)
            .on_conflict_do_nothing()
            .execute(conn)
            .await?)
    }
}
