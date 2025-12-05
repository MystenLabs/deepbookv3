use crate::handlers::{is_deepbook_tx, try_extract_move_call_package};
use crate::models::deepbook_margin::protocol_fees::ProtocolFeesIncreasedEvent;
use crate::traits::MoveStruct;
use crate::DeepbookEnv;
use async_trait::async_trait;
use deepbook_schema::models::ProtocolFeesIncreasedEvent as ProtocolFeesIncreasedEventModel;
use deepbook_schema::schema::protocol_fees_increased;
use diesel_async::RunQueryDsl;
use std::sync::Arc;
use sui_indexer_alt_framework::pipeline::concurrent::Handler;
use sui_indexer_alt_framework::pipeline::Processor;
use sui_pg_db::{Connection, Db};
use sui_types::full_checkpoint_content::CheckpointData;
use tracing::debug;

pub struct ProtocolFeesIncreasedHandler {
    env: DeepbookEnv,
}

impl ProtocolFeesIncreasedHandler {
    pub fn new(env: DeepbookEnv) -> Self {
        Self { env }
    }
}

impl Processor for ProtocolFeesIncreasedHandler {
    const NAME: &'static str = "protocol_fees_increased";
    type Value = ProtocolFeesIncreasedEventModel;

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
                if ProtocolFeesIncreasedEvent::matches_event_type(&ev.type_, self.env) {
                    let event: ProtocolFeesIncreasedEvent = bcs::from_bytes(&ev.contents)?;
                    let data = ProtocolFeesIncreasedEventModel {
                        event_digest: format!("{digest}{index}"),
                        digest: digest.to_string(),
                        sender: tx.transaction.sender_address().to_string(),
                        checkpoint,
                        checkpoint_timestamp_ms,
                        package: package.clone(),
                        margin_pool_id: event.margin_pool_id.to_string(),
                        total_shares: event.total_shares as i64,
                        referral_fees: event.referral_fees as i64,
                        maintainer_fees: event.maintainer_fees as i64,
                        protocol_fees: event.protocol_fees as i64,
                        onchain_timestamp: checkpoint_timestamp_ms, // No timestamp in event, use checkpoint timestamp
                    };
                    debug!(
                        "Observed DeepBook Margin Protocol Fees Increased {:?}",
                        data
                    );
                    results.push(data);
                }
            }
        }
        Ok(results)
    }
}

#[async_trait]
impl Handler for ProtocolFeesIncreasedHandler {
    type Store = Db;

    async fn commit<'a>(
        values: &[Self::Value],
        conn: &mut Connection<'a>,
    ) -> anyhow::Result<usize> {
        Ok(diesel::insert_into(protocol_fees_increased::table)
            .values(values)
            .on_conflict_do_nothing()
            .execute(conn)
            .await?)
    }
}
