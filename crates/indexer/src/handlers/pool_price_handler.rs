use crate::handlers::{is_deepbook_tx, try_extract_move_call_package};
use crate::models::deepbook::deep_price::PriceAdded;
use crate::traits::MoveStruct;
use crate::DeepbookEnv;
use async_trait::async_trait;
use deepbook_schema::models::PoolPrice;
use deepbook_schema::schema::pool_prices;
use diesel_async::RunQueryDsl;
use std::sync::Arc;
use sui_indexer_alt_framework::pipeline::concurrent::Handler;
use sui_indexer_alt_framework::pipeline::Processor;
use sui_pg_db::{Connection, Db};
use sui_types::full_checkpoint_content::CheckpointData;
use tracing::debug;

pub struct PoolPriceHandler {
    env: DeepbookEnv,
}

impl PoolPriceHandler {
    pub fn new(env: DeepbookEnv) -> Self {
        Self { env }
    }
}

impl Processor for PoolPriceHandler {
    const NAME: &'static str = "pool_price";
    type Value = PoolPrice;

    fn process(&self, checkpoint: &Arc<CheckpointData>) -> anyhow::Result<Vec<Self::Value>> {
        let mut results = Vec::new();
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
                if !PriceAdded::matches_event_type(&ev.type_, self.env) {
                    continue;
                }
                let event: PriceAdded = bcs::from_bytes(&ev.contents)?;
                let data = PoolPrice {
                    digest: digest.to_string(),
                    event_digest: format!("{digest}{index}"),
                    sender: tx.transaction.sender_address().to_string(),
                    checkpoint,
                    checkpoint_timestamp_ms,
                    package: package.clone(),
                    target_pool: event.target_pool.to_string(),
                    conversion_rate: event.conversion_rate as i64,
                    reference_pool: event.reference_pool.to_string(),
                };
                debug!("Observed Deepbook Price Addition {:?}", data);
                results.push(data);
            }
        }
        Ok(results)
    }
}

#[async_trait]
impl Handler for PoolPriceHandler {
    type Store = Db;

    async fn commit<'a>(
        values: &[Self::Value],
        conn: &mut Connection<'a>,
    ) -> anyhow::Result<usize> {
        Ok(diesel::insert_into(pool_prices::table)
            .values(values)
            .on_conflict_do_nothing()
            .execute(conn)
            .await?)
    }
}
