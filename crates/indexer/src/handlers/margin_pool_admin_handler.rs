use crate::handlers::{is_deepbook_tx, try_extract_move_call_package};
use crate::models::deepbook_margin::margin_pool::{
    DeepbookPoolUpdated, InterestParamsUpdated, MarginPoolConfigUpdated, MarginPoolCreated,
};
use crate::DeepbookEnv;
use async_trait::async_trait;
use deepbook_schema::models::MarginPoolAdmin;
use deepbook_schema::schema::margin_pool_admin;
use diesel_async::RunQueryDsl;
use move_core_types::language_storage::StructTag;
use serde_json;
use std::sync::Arc;
use sui_indexer_alt_framework::pipeline::concurrent::Handler;
use sui_indexer_alt_framework::pipeline::Processor;
use sui_pg_db::{Connection, Db};
use sui_types::full_checkpoint_content::CheckpointData;
use tracing::debug;

pub struct MarginPoolAdminHandler {
    margin_pool_created_event_type: StructTag,
    deepbook_pool_updated_event_type: StructTag,
    interest_params_updated_event_type: StructTag,
    margin_pool_config_updated_event_type: StructTag,
    env: DeepbookEnv,
}

impl MarginPoolAdminHandler {
    pub fn new(env: DeepbookEnv) -> Self {
        Self {
            margin_pool_created_event_type: env.margin_pool_created_event_type(),
            deepbook_pool_updated_event_type: env.deepbook_pool_updated_event_type(),
            interest_params_updated_event_type: env.interest_params_updated_event_type(),
            margin_pool_config_updated_event_type: env.margin_pool_config_updated_event_type(),
            env,
        }
    }
}

impl Processor for MarginPoolAdminHandler {
    const NAME: &'static str = "margin_pool_admin";
    type Value = MarginPoolAdmin;

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

                if ev.type_ == self.margin_pool_created_event_type {
                    let event: MarginPoolCreated = bcs::from_bytes(&ev.contents)?;
                    let config_json = serde_json::to_value(&event.config).ok();
                    let data = MarginPoolAdmin {
                        event_digest: format!("{digest}{index}"),
                        digest: digest.to_string(),
                        sender: tx.transaction.sender_address().to_string(),
                        checkpoint,
                        checkpoint_timestamp_ms,
                        package: package.clone(),
                        margin_pool_id: event.margin_pool_id.to_string(),
                        event_type: "created".to_string(),
                        maintainer_cap_id: Some(event.maintainer_cap_id.to_string()),
                        asset_type: Some(event.asset_type.to_string()),
                        deepbook_pool_id: None,
                        pool_cap_id: None,
                        enabled: None,
                        config_json,
                        onchain_timestamp: event.timestamp as i64,
                    };
                    debug!("Observed DeepBook Margin Pool Created {:?}", data);
                    results.push(data);
                } else if ev.type_ == self.deepbook_pool_updated_event_type {
                    let event: DeepbookPoolUpdated = bcs::from_bytes(&ev.contents)?;
                    let data = MarginPoolAdmin {
                        event_digest: format!("{digest}{index}"),
                        digest: digest.to_string(),
                        sender: tx.transaction.sender_address().to_string(),
                        checkpoint,
                        checkpoint_timestamp_ms,
                        package: package.clone(),
                        margin_pool_id: event.margin_pool_id.to_string(),
                        event_type: "pool_updated".to_string(),
                        maintainer_cap_id: None,
                        asset_type: None,
                        deepbook_pool_id: Some(event.deepbook_pool_id.to_string()),
                        pool_cap_id: Some(event.pool_cap_id.to_string()),
                        enabled: Some(event.enabled),
                        config_json: None,
                        onchain_timestamp: event.timestamp as i64,
                    };
                    debug!("Observed DeepBook Margin Pool Updated {:?}", data);
                    results.push(data);
                } else if ev.type_ == self.interest_params_updated_event_type {
                    let event: InterestParamsUpdated = bcs::from_bytes(&ev.contents)?;
                    let config_json = serde_json::to_value(&event.interest_config).ok();
                    let data = MarginPoolAdmin {
                        event_digest: format!("{digest}{index}"),
                        digest: digest.to_string(),
                        sender: tx.transaction.sender_address().to_string(),
                        checkpoint,
                        checkpoint_timestamp_ms,
                        package: package.clone(),
                        margin_pool_id: event.margin_pool_id.to_string(),
                        event_type: "interest_updated".to_string(),
                        maintainer_cap_id: None,
                        asset_type: None,
                        deepbook_pool_id: None,
                        pool_cap_id: Some(event.pool_cap_id.to_string()),
                        enabled: None,
                        config_json,
                        onchain_timestamp: event.timestamp as i64,
                    };
                    debug!("Observed DeepBook Margin Interest Params Updated {:?}", data);
                    results.push(data);
                } else if ev.type_ == self.margin_pool_config_updated_event_type {
                    let event: MarginPoolConfigUpdated = bcs::from_bytes(&ev.contents)?;
                    let config_json = serde_json::to_value(&event.margin_pool_config).ok();
                    let data = MarginPoolAdmin {
                        event_digest: format!("{digest}{index}"),
                        digest: digest.to_string(),
                        sender: tx.transaction.sender_address().to_string(),
                        checkpoint,
                        checkpoint_timestamp_ms,
                        package: package.clone(),
                        margin_pool_id: event.margin_pool_id.to_string(),
                        event_type: "config_updated".to_string(),
                        maintainer_cap_id: None,
                        asset_type: None,
                        deepbook_pool_id: None,
                        pool_cap_id: Some(event.pool_cap_id.to_string()),
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
impl Handler for MarginPoolAdminHandler {
    type Store = Db;

    async fn commit<'a>(
        values: &[Self::Value],
        conn: &mut Connection<'a>,
    ) -> anyhow::Result<usize> {
        Ok(diesel::insert_into(margin_pool_admin::table)
            .values(values)
            .on_conflict_do_nothing()
            .execute(conn)
            .await?)
    }
}
