use crate::handlers::{is_deepbook_tx, try_extract_move_call_package};
use crate::models::deepbook_margin::margin_manager::LiquidationEvent;
use crate::traits::MoveStruct;
use crate::DeepbookEnv;
use async_trait::async_trait;
use deepbook_schema::models::Liquidation;
use deepbook_schema::schema::liquidation;
use diesel_async::RunQueryDsl;
use std::sync::Arc;
use sui_indexer_alt_framework::pipeline::concurrent::Handler;
use sui_indexer_alt_framework::pipeline::Processor;
use sui_pg_db::{Connection, Db};
use sui_types::full_checkpoint_content::CheckpointData;
use tracing::debug;

pub struct LiquidationHandler {
    env: DeepbookEnv,
}

impl LiquidationHandler {
    pub fn new(env: DeepbookEnv) -> Self {
        Self { env }
    }
}

impl Processor for LiquidationHandler {
    const NAME: &'static str = "liquidation";
    type Value = Liquidation;

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
                if LiquidationEvent::matches_event_type(&ev.type_, self.env) {
                    let event: LiquidationEvent = bcs::from_bytes(&ev.contents)?;
                    let data = Liquidation {
                        event_digest: format!("{digest}{index}"),
                        digest: digest.to_string(),
                        sender: tx.transaction.sender_address().to_string(),
                        checkpoint,
                        checkpoint_timestamp_ms,
                        package: package.clone(),
                        margin_manager_id: event.margin_manager_id.to_string(),
                        margin_pool_id: event.margin_pool_id.to_string(),
                        liquidation_amount: event.liquidation_amount as i64,
                        pool_reward: event.pool_reward as i64,
                        pool_default: event.pool_default as i64,
                        risk_ratio: event.risk_ratio as i64,
                        onchain_timestamp: event.timestamp as i64,
                    };
                    debug!("Observed DeepBook Margin Liquidation {:?}", data);
                    results.push(data);
                }
            }
        }
        Ok(results)
    }
}

#[async_trait]
impl Handler for LiquidationHandler {
    type Store = Db;

    async fn commit<'a>(
        values: &[Self::Value],
        conn: &mut Connection<'a>,
    ) -> anyhow::Result<usize> {
        Ok(diesel::insert_into(liquidation::table)
            .values(values)
            .on_conflict_do_nothing()
            .execute(conn)
            .await?)
    }
}
