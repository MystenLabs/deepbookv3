use crate::handlers::{is_deepbook_tx, try_extract_move_call_package};
use crate::models::deepbook::state::ProposalEvent;
use crate::traits::MoveStruct;
use crate::DeepbookEnv;
use async_trait::async_trait;
use deepbook_schema::models::Proposals;
use deepbook_schema::schema::proposals;
use diesel_async::RunQueryDsl;
use std::sync::Arc;
use sui_indexer_alt_framework::pipeline::concurrent::Handler;
use sui_indexer_alt_framework::pipeline::Processor;
use sui_pg_db::{Connection, Db};
use sui_types::full_checkpoint_content::CheckpointData;
use tracing::debug;

pub struct ProposalsHandler {
    env: DeepbookEnv,
}

impl ProposalsHandler {
    pub fn new(env: DeepbookEnv) -> Self {
        Self { env }
    }
}

impl Processor for ProposalsHandler {
    const NAME: &'static str = "proposals";
    type Value = Proposals;

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
                if !ProposalEvent::matches_event_type(&ev.type_, self.env) {
                    continue;
                }
                let event: ProposalEvent = bcs::from_bytes(&ev.contents)?;
                let data = Proposals {
                    digest: digest.to_string(),
                    event_digest: format!("{digest}{index}"),
                    sender: tx.transaction.sender_address().to_string(),
                    checkpoint,
                    checkpoint_timestamp_ms,
                    package: package.clone(),
                    pool_id: event.pool_id.to_string(),
                    balance_manager_id: event.balance_manager_id.to_string(),
                    epoch: event.epoch as i64,
                    taker_fee: event.taker_fee as i64,
                    maker_fee: event.maker_fee as i64,
                    stake_required: event.stake_required as i64,
                };
                debug!("Observed Deepbook Proposal Event {:?}", data);
                results.push(data);
            }
        }
        Ok(results)
    }
}

#[async_trait]
impl Handler for ProposalsHandler {
    type Store = Db;

    async fn commit<'a>(
        values: &[Self::Value],
        conn: &mut Connection<'a>,
    ) -> anyhow::Result<usize> {
        Ok(diesel::insert_into(proposals::table)
            .values(values)
            .on_conflict_do_nothing()
            .execute(conn)
            .await?)
    }
}
