use crate::handlers::{is_deepbook_tx, struct_tag, try_extract_move_call_package};
use crate::models::deepbook::order::{OrderCanceled, OrderModified};
use crate::models::deepbook::order_info::{OrderExpired, OrderPlaced};
use deepbook_schema::models::{OrderUpdate, OrderUpdateStatus};
use deepbook_schema::schema::order_updates;
use diesel_async::RunQueryDsl;
use move_core_types::account_address::AccountAddress;
use move_core_types::language_storage::StructTag;
use std::sync::Arc;
use sui_indexer_alt_framework::pipeline::concurrent::Handler;
use sui_indexer_alt_framework::pipeline::Processor;
use sui_pg_db::Connection;
use sui_types::full_checkpoint_content::CheckpointData;
use tracing::debug;

type TransactionMetadata = (String, u64, u64, String, String);

pub struct OrderUpdateHandler {
    order_placed_type: StructTag,
    order_modified_type: StructTag,
    order_canceled_type: StructTag,
    order_expired_type: StructTag,
}

impl OrderUpdateHandler {
    pub fn new(package_id_override: Option<AccountAddress>) -> Self {
        Self {
            order_placed_type: struct_tag::<OrderPlaced>(package_id_override),
            order_modified_type: struct_tag::<OrderModified>(package_id_override),
            order_canceled_type: struct_tag::<OrderCanceled>(package_id_override),
            order_expired_type: struct_tag::<OrderExpired>(package_id_override),
        }
    }
}

impl Processor for OrderUpdateHandler {
    const NAME: &'static str = "OrderUpdate";
    type Value = OrderUpdate;
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
                let metadata = (
                    tx.transaction.sender_address().to_string(),
                    checkpoint.checkpoint_summary.sequence_number,
                    checkpoint.checkpoint_summary.timestamp_ms,
                    tx.transaction.digest().to_string(),
                    package.clone(),
                );

                return events.data.iter().enumerate().try_fold(
                    result,
                    |mut result, (index, ev)| {
                        if ev.type_ == self.order_placed_type {
                            let event = bcs::from_bytes(&ev.contents)?;
                            result.push(process_order_placed(event, metadata.clone(), index));
                            debug!("Observed Deepbook Order Placed {:?}", tx);
                        } else if ev.type_ == self.order_modified_type {
                            let event = bcs::from_bytes(&ev.contents)?;
                            result.push(process_order_modified(event, metadata.clone(), index));
                            debug!("Observed Deepbook Order Modified {:?}", tx);
                        } else if ev.type_ == self.order_canceled_type {
                            let event = bcs::from_bytes(&ev.contents)?;
                            result.push(process_order_canceled(event, metadata.clone(), index));
                            debug!("Observed Deepbook Order Canceled {:?}", tx);
                        } else if ev.type_ == self.order_expired_type {
                            let event = bcs::from_bytes(&ev.contents)?;
                            result.push(process_order_expired(event, metadata.clone(), index));
                            debug!("Observed Deepbook Order Expired {:?}", tx);
                        }
                        Ok(result)
                    },
                );
            })
    }
}

#[async_trait::async_trait]
impl Handler for OrderUpdateHandler {
    async fn commit(values: &[Self::Value], conn: &mut Connection<'_>) -> anyhow::Result<usize> {
        Ok(diesel::insert_into(order_updates::table)
            .values(values)
            .on_conflict_do_nothing()
            .execute(conn)
            .await?)
    }
}

fn process_order_placed(
    order_placed: OrderPlaced,
    (sender, checkpoint, checkpoint_timestamp_ms, digest, package): TransactionMetadata,
    event_index: usize,
) -> OrderUpdate {
    let event_digest = format!("{digest}{event_index}");
    OrderUpdate {
        event_digest,
        digest,
        sender,
        checkpoint: checkpoint as i64,
        checkpoint_timestamp_ms: checkpoint_timestamp_ms as i64,
        package,
        status: OrderUpdateStatus::Placed,
        pool_id: order_placed.pool_id.to_string(),
        order_id: order_placed.order_id.to_string(),
        client_order_id: order_placed.client_order_id as i64,
        price: order_placed.price as i64,
        is_bid: order_placed.is_bid,
        onchain_timestamp: order_placed.timestamp as i64,
        original_quantity: order_placed.placed_quantity as i64,
        quantity: order_placed.placed_quantity as i64,
        filled_quantity: 0,
        trader: order_placed.trader.to_string(),
        balance_manager_id: order_placed.balance_manager_id.to_string(),
    }
}

fn process_order_modified(
    order_modified: OrderModified,
    (sender, checkpoint, checkpoint_timestamp_ms, digest, package): TransactionMetadata,
    event_index: usize,
) -> OrderUpdate {
    let event_digest = format!("{digest}{event_index}");
    OrderUpdate {
        digest,
        event_digest,
        sender,
        checkpoint: checkpoint as i64,
        checkpoint_timestamp_ms: checkpoint_timestamp_ms as i64,
        package,
        status: OrderUpdateStatus::Modified,
        pool_id: order_modified.pool_id.to_string(),
        order_id: order_modified.order_id.to_string(),
        client_order_id: order_modified.client_order_id as i64,
        price: order_modified.price as i64,
        is_bid: order_modified.is_bid,
        onchain_timestamp: order_modified.timestamp as i64,
        original_quantity: order_modified.previous_quantity as i64,
        quantity: order_modified.new_quantity as i64,
        filled_quantity: order_modified.filled_quantity as i64,
        trader: order_modified.trader.to_string(),
        balance_manager_id: order_modified.balance_manager_id.to_string(),
    }
}

fn process_order_canceled(
    order_canceled: OrderCanceled,
    (sender, checkpoint, checkpoint_timestamp_ms, digest, package): TransactionMetadata,
    event_index: usize,
) -> OrderUpdate {
    let event_digest = format!("{digest}{event_index}");
    OrderUpdate {
        digest,
        event_digest,
        sender,
        checkpoint: checkpoint as i64,
        checkpoint_timestamp_ms: checkpoint_timestamp_ms as i64,
        package,
        status: OrderUpdateStatus::Canceled,
        pool_id: order_canceled.pool_id.to_string(),
        order_id: order_canceled.order_id.to_string(),
        client_order_id: order_canceled.client_order_id as i64,
        price: order_canceled.price as i64,
        is_bid: order_canceled.is_bid,
        onchain_timestamp: order_canceled.timestamp as i64,
        original_quantity: order_canceled.original_quantity as i64,
        quantity: order_canceled.base_asset_quantity_canceled as i64,
        filled_quantity: (order_canceled.original_quantity
            - order_canceled.base_asset_quantity_canceled) as i64,
        trader: order_canceled.trader.to_string(),
        balance_manager_id: order_canceled.balance_manager_id.to_string(),
    }
}

fn process_order_expired(
    order_expired: OrderExpired,
    (sender, checkpoint, checkpoint_timestamp_ms, digest, package): TransactionMetadata,
    event_index: usize,
) -> OrderUpdate {
    let event_digest = format!("{digest}{event_index}");
    OrderUpdate {
        digest,
        event_digest,
        sender,
        checkpoint: checkpoint as i64,
        checkpoint_timestamp_ms: checkpoint_timestamp_ms as i64,
        package,
        status: OrderUpdateStatus::Expired,
        pool_id: order_expired.pool_id.to_string(),
        order_id: order_expired.order_id.to_string(),
        client_order_id: order_expired.client_order_id as i64,
        price: order_expired.price as i64,
        is_bid: order_expired.is_bid,
        onchain_timestamp: order_expired.timestamp as i64,
        original_quantity: order_expired.original_quantity as i64,
        quantity: order_expired.base_asset_quantity_canceled as i64,
        filled_quantity: (order_expired.original_quantity
            - order_expired.base_asset_quantity_canceled) as i64,
        trader: order_expired.trader.to_string(),
        balance_manager_id: order_expired.balance_manager_id.to_string(),
    }
}
