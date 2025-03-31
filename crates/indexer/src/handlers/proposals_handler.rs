use crate::handlers::{is_deepbook_tx, struct_tag, try_extract_move_call_package};
use crate::models::deepbook::state::ProposalEvent;
use async_trait::async_trait;
use deepbook_schema::models::Proposals;
use deepbook_schema::schema::proposals;
use diesel_async::RunQueryDsl;
use move_core_types::account_address::AccountAddress;
use move_core_types::language_storage::StructTag;
use std::sync::Arc;
use sui_indexer_alt_framework::pipeline::concurrent::Handler;
use sui_indexer_alt_framework::pipeline::Processor;
use sui_pg_db::Connection;
use sui_types::full_checkpoint_content::CheckpointData;
use tracing::debug;

pub struct ProposalsHandler {
    event_type: StructTag,
}

impl ProposalsHandler {
    pub fn new(package_id_override: Option<AccountAddress>) -> Self {
        Self {
            event_type: struct_tag::<ProposalEvent>(package_id_override),
        }
    }
}

impl Processor for ProposalsHandler {
    const NAME: &'static str = "Proposals";
    type Value = Proposals;

    fn process(&self, checkpoint: &Arc<CheckpointData>) -> anyhow::Result<Vec<Self::Value>> {
        checkpoint
            .transactions
            .iter()
            .try_fold(vec![], |result, tx| {
                if !is_deepbook_tx(tx) {
                    return Ok(result);
                }
                let Some(events) = &tx.events else {
                    return Ok(result);
                };

                let package = try_extract_move_call_package(tx).unwrap_or_default();
                let checkpoint_timestamp_ms = checkpoint.checkpoint_summary.timestamp_ms as i64;
                let checkpoint = checkpoint.checkpoint_summary.sequence_number as i64;
                let digest = tx.transaction.digest();

                return events
                    .data
                    .iter()
                    .filter(|ev| ev.type_ == self.event_type)
                    .enumerate()
                    .try_fold(result, |mut result, (index, ev)| {
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
                        result.push(data);
                        Ok(result)
                    });
            })
    }
}

#[async_trait]
impl Handler for ProposalsHandler {
    async fn commit(values: &[Self::Value], conn: &mut Connection<'_>) -> anyhow::Result<usize> {
        Ok(diesel::insert_into(proposals::table)
            .values(values)
            .on_conflict_do_nothing()
            .execute(conn)
            .await?)
    }
}
