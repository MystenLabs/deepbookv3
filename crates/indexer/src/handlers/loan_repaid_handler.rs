use crate::handlers::{is_deepbook_tx, try_extract_move_call_package};
use crate::models::deepbook_margin::margin_manager::LoanRepaidEvent;
use crate::DeepbookEnv;
use async_trait::async_trait;
use deepbook_schema::models::LoanRepaid;
use deepbook_schema::schema::loan_repaid;
use diesel_async::RunQueryDsl;
use move_core_types::language_storage::StructTag;
use std::sync::Arc;
use sui_indexer_alt_framework::pipeline::concurrent::Handler;
use sui_indexer_alt_framework::pipeline::Processor;
use sui_pg_db::{Connection, Db};
use sui_types::full_checkpoint_content::CheckpointData;
use tracing::debug;

pub struct LoanRepaidHandler {
    loan_repaid_event_type: StructTag,
    env: DeepbookEnv,
}

impl LoanRepaidHandler {
    pub fn new(env: DeepbookEnv) -> Self {
        Self {
            loan_repaid_event_type: env.loan_repaid_event_type(),
            env,
        }
    }
}

impl Processor for LoanRepaidHandler {
    const NAME: &'static str = "loan_repaid";
    type Value = LoanRepaid;

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
                if ev.type_ == self.loan_repaid_event_type {
                    let event: LoanRepaidEvent = bcs::from_bytes(&ev.contents)?;
                    let data = LoanRepaid {
                        event_digest: format!("{digest}{index}"),
                        digest: digest.to_string(),
                        sender: tx.transaction.sender_address().to_string(),
                        checkpoint,
                        checkpoint_timestamp_ms,
                        package: package.clone(),
                        margin_manager_id: event.margin_manager_id.to_string(),
                        margin_pool_id: event.margin_pool_id.to_string(),
                        repay_amount: event.repay_amount as i64,
                        repay_shares: event.repay_shares as i64,
                        onchain_timestamp: event.timestamp as i64,
                    };
                    debug!("Observed DeepBook Margin Loan Repaid {:?}", data);
                    results.push(data);
                }
            }
        }
        Ok(results)
    }
}

#[async_trait]
impl Handler for LoanRepaidHandler {
    type Store = Db;

    async fn commit<'a>(
        values: &[Self::Value],
        conn: &mut Connection<'a>,
    ) -> anyhow::Result<usize> {
        Ok(diesel::insert_into(loan_repaid::table)
            .values(values)
            .on_conflict_do_nothing()
            .execute(conn)
            .await?)
    }
}
