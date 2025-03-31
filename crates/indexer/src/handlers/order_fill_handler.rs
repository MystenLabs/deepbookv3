use crate::handlers::{is_deepbook_tx, struct_tag, try_extract_move_call_package};
use crate::models::deepbook::order_info::OrderFilled;
use async_trait::async_trait;
use deepbook_schema::models::OrderFill;
use deepbook_schema::schema::order_fills;
use diesel_async::RunQueryDsl;
use move_core_types::account_address::AccountAddress;
use move_core_types::language_storage::StructTag;
use std::sync::Arc;
use sui_indexer_alt_framework::pipeline::concurrent::Handler;
use sui_indexer_alt_framework::pipeline::Processor;
use sui_pg_db::Connection;
use sui_types::full_checkpoint_content::CheckpointData;
use tracing::debug;

pub struct OrderFillHandler {
    event_type: StructTag,
}

impl OrderFillHandler {
    pub fn new(package_id_override: Option<AccountAddress>) -> Self {
        Self {
            event_type: struct_tag::<OrderFilled>(package_id_override),
        }
    }
}

impl Processor for OrderFillHandler {
    const NAME: &'static str = "OrderFill";
    type Value = OrderFill;

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
                        let event: OrderFilled = bcs::from_bytes(&ev.contents)?;
                        let data = OrderFill {
                            digest: digest.to_string(),
                            event_digest: format!("{digest}{index}"),
                            sender: tx.transaction.sender_address().to_string(),
                            checkpoint,
                            checkpoint_timestamp_ms,
                            package: package.clone(),
                            pool_id: event.pool_id.to_string(),
                            maker_order_id: event.maker_order_id.to_string(),
                            taker_order_id: event.taker_order_id.to_string(),
                            maker_client_order_id: event.maker_client_order_id as i64,
                            taker_client_order_id: event.taker_client_order_id as i64,
                            price: event.price as i64,
                            taker_is_bid: event.taker_is_bid,
                            taker_fee: event.taker_fee as i64,
                            taker_fee_is_deep: event.taker_fee_is_deep,
                            maker_fee: event.maker_fee as i64,
                            maker_fee_is_deep: event.maker_fee_is_deep,
                            base_quantity: event.base_quantity as i64,
                            quote_quantity: event.quote_quantity as i64,
                            maker_balance_manager_id: event.maker_balance_manager_id.to_string(),
                            taker_balance_manager_id: event.taker_balance_manager_id.to_string(),
                            onchain_timestamp: event.timestamp as i64,
                        };
                        debug!("Observed Deepbook Order Filled {:?}", data);
                        result.push(data);
                        Ok(result)
                    });
            })
    }
}

#[async_trait]
impl Handler for OrderFillHandler {
    async fn commit(values: &[Self::Value], conn: &mut Connection<'_>) -> anyhow::Result<usize> {
        Ok(diesel::insert_into(order_fills::table)
            .values(values)
            .on_conflict_do_nothing()
            .execute(conn)
            .await?)
    }
}
