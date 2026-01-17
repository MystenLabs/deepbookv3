use crate::handlers::{is_deepbook_tx, try_extract_move_call_package};
use crate::models::deepbook::pool::PoolCreated as PoolCreatedEvent;
use crate::models::sui::sui::SUI;
use crate::traits::MoveStruct;
use crate::DeepbookEnv;
use async_trait::async_trait;
use deepbook_schema::models::PoolCreated;
use deepbook_schema::schema::pool_created;
use diesel_async::RunQueryDsl;
use std::sync::Arc;
use sui_indexer_alt_framework::pipeline::Processor;
use sui_indexer_alt_framework::postgres::handler::Handler;
use sui_indexer_alt_framework::postgres::Connection;
use sui_indexer_alt_framework::types::full_checkpoint_content::Checkpoint;
use sui_types::transaction::TransactionDataAPI;
use tracing::debug;

pub struct PoolCreatedHandler {
    env: DeepbookEnv,
}

impl PoolCreatedHandler {
    pub fn new(env: DeepbookEnv) -> Self {
        Self { env }
    }
}

#[async_trait]
impl Processor for PoolCreatedHandler {
    const NAME: &'static str = "pool_created";
    type Value = PoolCreated;

    async fn process(&self, checkpoint: &Arc<Checkpoint>) -> anyhow::Result<Vec<Self::Value>> {
        let mut results = vec![];

        for tx in &checkpoint.transactions {
            if !is_deepbook_tx(tx, &checkpoint.object_set, self.env) {
                continue;
            }
            let Some(events) = &tx.events else {
                continue;
            };

            let package = try_extract_move_call_package(tx).unwrap_or_default();
            let checkpoint_timestamp_ms = checkpoint.summary.timestamp_ms as i64;
            let checkpoint_seq = checkpoint.summary.sequence_number as i64;
            let digest = tx.transaction.digest();

            for (index, ev) in events.data.iter().enumerate() {
                if !PoolCreatedEvent::<SUI, SUI>::matches_event_type(&ev.type_, self.env) {
                    continue;
                }

                let event: PoolCreatedEvent<SUI, SUI> = bcs::from_bytes(&ev.contents)?;
                let data = PoolCreated {
                    digest: digest.to_string(),
                    event_digest: format!("{digest}{index}"),
                    sender: tx.transaction.sender().to_string(),
                    checkpoint: checkpoint_seq,
                    checkpoint_timestamp_ms,
                    package: package.clone(),
                    pool_id: event.pool_id.to_string(),
                    taker_fee: event.taker_fee as i64,
                    maker_fee: event.maker_fee as i64,
                    tick_size: event.tick_size as i64,
                    lot_size: event.lot_size as i64,
                    min_size: event.min_size as i64,
                    whitelisted_pool: event.whitelisted_pool,
                    treasury_address: event.treasury_address.to_string(),
                };
                debug!("Observed Deepbook PoolCreated {:?}", data);
                results.push(data);
            }
        }
        Ok(results)
    }
}

#[async_trait]
impl Handler for PoolCreatedHandler {
    async fn commit<'a>(
        values: &[Self::Value],
        conn: &mut Connection<'a>,
    ) -> anyhow::Result<usize> {
        Ok(diesel::insert_into(pool_created::table)
            .values(values)
            .on_conflict_do_nothing()
            .execute(conn)
            .await?)
    }
}
