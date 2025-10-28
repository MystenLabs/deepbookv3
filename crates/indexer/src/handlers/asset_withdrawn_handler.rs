use crate::handlers::{is_deepbook_tx, try_extract_move_call_package};
use crate::models::deepbook_margin::margin_pool::AssetWithdrawn;
use crate::traits::MoveStruct;
use crate::DeepbookEnv;
use async_trait::async_trait;
use deepbook_schema::models::AssetWithdrawn as AssetWithdrawnModel;
use deepbook_schema::schema::asset_withdrawn;
use diesel_async::RunQueryDsl;
use std::sync::Arc;
use sui_indexer_alt_framework::pipeline::concurrent::Handler;
use sui_indexer_alt_framework::pipeline::Processor;
use sui_pg_db::{Connection, Db};
use sui_types::full_checkpoint_content::CheckpointData;
use tracing::debug;

pub struct AssetWithdrawnHandler {
    env: DeepbookEnv,
}

impl AssetWithdrawnHandler {
    pub fn new(env: DeepbookEnv) -> Self {
        Self { env }
    }
}

impl Processor for AssetWithdrawnHandler {
    const NAME: &'static str = "asset_withdrawn";
    type Value = AssetWithdrawnModel;

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
                if AssetWithdrawn::matches_event_type(&ev.type_, self.env) {
                    let event: AssetWithdrawn = bcs::from_bytes(&ev.contents)?;
                    let data = AssetWithdrawnModel {
                        event_digest: format!("{digest}{index}"),
                        digest: digest.to_string(),
                        sender: tx.transaction.sender_address().to_string(),
                        checkpoint,
                        checkpoint_timestamp_ms,
                        package: package.clone(),
                        margin_pool_id: event.margin_pool_id.to_string(),
                        asset_type: event.asset_type.to_string(),
                        supplier: event.supplier.to_string(),
                        amount: event.withdraw_amount as i64,
                        shares: event.withdraw_shares as i64,
                        onchain_timestamp: event.timestamp as i64,
                    };
                    debug!("Observed DeepBook Margin Asset Withdrawn {:?}", data);
                    results.push(data);
                }
            }
        }
        Ok(results)
    }
}

#[async_trait]
impl Handler for AssetWithdrawnHandler {
    type Store = Db;

    async fn commit<'a>(
        values: &[Self::Value],
        conn: &mut Connection<'a>,
    ) -> anyhow::Result<usize> {
        Ok(diesel::insert_into(asset_withdrawn::table)
            .values(values)
            .on_conflict_do_nothing()
            .execute(conn)
            .await?)
    }
}
