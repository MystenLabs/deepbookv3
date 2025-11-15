use crate::handlers::{is_deepbook_tx, try_extract_move_call_package};
use crate::models::deepbook_margin::margin_pool::MaintainerFeesWithdrawn;
use crate::traits::MoveStruct;
use crate::DeepbookEnv;
use async_trait::async_trait;
use deepbook_schema::models::MaintainerFeesWithdrawn as MaintainerFeesWithdrawnModel;
use deepbook_schema::schema::maintainer_fees_withdrawn;
use diesel_async::RunQueryDsl;
use std::sync::Arc;
use sui_indexer_alt_framework::pipeline::concurrent::Handler;
use sui_indexer_alt_framework::pipeline::Processor;
use sui_pg_db::{Connection, Db};
use sui_types::full_checkpoint_content::CheckpointData;
use tracing::debug;

pub struct MaintainerFeesWithdrawnHandler {
    env: DeepbookEnv,
}

impl MaintainerFeesWithdrawnHandler {
    pub fn new(env: DeepbookEnv) -> Self {
        Self { env }
    }
}

impl Processor for MaintainerFeesWithdrawnHandler {
    const NAME: &'static str = "maintainer_fees_withdrawn";
    type Value = MaintainerFeesWithdrawnModel;

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
                if MaintainerFeesWithdrawn::matches_event_type(&ev.type_, self.env) {
                    let event: MaintainerFeesWithdrawn = bcs::from_bytes(&ev.contents)?;
                    let data = MaintainerFeesWithdrawnModel {
                        event_digest: format!("{digest}{index}"),
                        digest: digest.to_string(),
                        sender: tx.transaction.sender_address().to_string(),
                        checkpoint,
                        checkpoint_timestamp_ms,
                        package: package.clone(),
                        margin_pool_id: event.margin_pool_id.to_string(),
                        margin_pool_cap_id: event.margin_pool_cap_id.to_string(),
                        maintainer_fees: event.maintainer_fees as i64,
                        onchain_timestamp: event.timestamp as i64,
                    };
                    debug!(
                        "Observed DeepBook Margin Maintainer Fees Withdrawn {:?}",
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
impl Handler for MaintainerFeesWithdrawnHandler {
    type Store = Db;

    async fn commit<'a>(
        values: &[Self::Value],
        conn: &mut Connection<'a>,
    ) -> anyhow::Result<usize> {
        Ok(diesel::insert_into(maintainer_fees_withdrawn::table)
            .values(values)
            .on_conflict_do_nothing()
            .execute(conn)
            .await?)
    }
}
