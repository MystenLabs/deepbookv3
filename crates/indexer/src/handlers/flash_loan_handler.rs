use crate::handlers::{is_deepbook_tx, try_extract_move_call_package};
use crate::models::deepbook::vault::FlashLoanBorrowed;
use crate::traits::MoveStruct;
use crate::DeepbookEnv;
use async_trait::async_trait;
use deepbook_schema::models::Flashloan;
use deepbook_schema::schema::flashloans;
use diesel_async::RunQueryDsl;
use std::sync::Arc;
use sui_indexer_alt_framework::pipeline::concurrent::Handler;
use sui_indexer_alt_framework::pipeline::Processor;
use sui_pg_db::{Connection, Db};
use sui_types::full_checkpoint_content::CheckpointData;
use tracing::debug;

pub struct FlashLoanHandler {
    env: DeepbookEnv,
}

impl FlashLoanHandler {
    pub fn new(env: DeepbookEnv) -> Self {
        Self { env }
    }
}

impl Processor for FlashLoanHandler {
    const NAME: &'static str = "flash_loan";
    type Value = Flashloan;

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
                if !FlashLoanBorrowed::matches_event_type(&ev.type_, self.env) {
                    continue;
                }
                let event: FlashLoanBorrowed = bcs::from_bytes(&ev.contents)?;
                let data = Flashloan {
                    digest: digest.to_string(),
                    event_digest: format!("{digest}{index}"),
                    sender: tx.transaction.sender_address().to_string(),
                    checkpoint,
                    checkpoint_timestamp_ms,
                    package: package.clone(),
                    pool_id: event.pool_id.to_string(),
                    borrow_quantity: event.borrow_quantity as i64,
                    borrow: true,
                    type_name: event.type_name.to_string(),
                };
                debug!("Observed Deepbook Flash Loan Borrowed {:?}", data);
                results.push(data);
            }
        }
        Ok(results)
    }
}

#[async_trait]
impl Handler for FlashLoanHandler {
    type Store = Db;

    async fn commit<'a>(
        values: &[Self::Value],
        conn: &mut Connection<'a>,
    ) -> anyhow::Result<usize> {
        Ok(diesel::insert_into(flashloans::table)
            .values(values)
            .on_conflict_do_nothing()
            .execute(conn)
            .await?)
    }
}
