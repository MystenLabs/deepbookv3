use crate::handlers::{is_deepbook_tx, struct_tag, try_extract_move_call_package};
use crate::models::deepbook::governance::TradeParamsUpdateEvent;
use crate::models::deepbook::pool;
use async_trait::async_trait;
use deepbook_schema::models::TradeParamsUpdate;
use deepbook_schema::schema::trade_params_update;
use diesel_async::RunQueryDsl;
use move_core_types::account_address::AccountAddress;
use move_core_types::language_storage::StructTag;
use std::sync::Arc;
use sui_indexer_alt_framework::pipeline::concurrent::Handler;
use sui_indexer_alt_framework::pipeline::Processor;
use sui_pg_db::Connection;
use sui_types::full_checkpoint_content::CheckpointData;
use tracing::debug;

pub struct TradeParamsUpdateHandler {
    event_type: StructTag,
}

impl TradeParamsUpdateHandler {
    pub fn new(package_id_override: Option<AccountAddress>) -> Self {
        Self {
            event_type: struct_tag::<TradeParamsUpdateEvent>(package_id_override),
        }
    }
}

impl Processor for TradeParamsUpdateHandler {
    const NAME: &'static str = "TradeParamsUpdate";
    type Value = TradeParamsUpdate;

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

                let pool = tx
                    .input_objects
                    .iter()
                    .find(|o| matches!(o.data.struct_tag(), Some(struct_tag)
                        if struct_tag.address == AccountAddress::new(*pool::PACKAGE_ID.inner()) && struct_tag.name.as_str() == "Pool"));
                let pool_id = pool
                    .map(|o| o.id().to_hex_uncompressed())
                    .unwrap_or("0x0".to_string());

                return events
                    .data
                    .iter()
                    .filter(|ev| ev.type_ == self.event_type)
                    .enumerate()
                    .try_fold(result, |mut result, (index, ev)| {
                        let event: TradeParamsUpdateEvent = bcs::from_bytes(&ev.contents)?;
                        let data = TradeParamsUpdate {
                            digest: digest.to_string(),
                            event_digest: format!("{digest}{index}"),
                            sender: tx.transaction.sender_address().to_string(),
                            checkpoint,
                            checkpoint_timestamp_ms,
                            package: package.clone(),
                            pool_id: pool_id.clone(),
                            taker_fee: event.taker_fee as i64,
                            maker_fee: event.maker_fee as i64,
                            stake_required: event.stake_required as i64,
                        };
                        debug!("Observed Deepbook Trade Params Update Event {:?}", data);
                        result.push(data);
                        Ok(result)
                    });
            })
    }
}

#[async_trait]
impl Handler for TradeParamsUpdateHandler {
    async fn commit(values: &[Self::Value], conn: &mut Connection<'_>) -> anyhow::Result<usize> {
        Ok(diesel::insert_into(trade_params_update::table)
            .values(values)
            .on_conflict_do_nothing()
            .execute(conn)
            .await?)
    }
}
