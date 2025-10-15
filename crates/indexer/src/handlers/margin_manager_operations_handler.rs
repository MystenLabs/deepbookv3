use crate::handlers::{is_deepbook_tx, try_extract_move_call_package};
use crate::models::deepbook_margin::margin_manager::{
    LiquidationEvent, LoanBorrowedEvent, LoanRepaidEvent, MarginManagerEvent,
};
use crate::DeepbookEnv;
use async_trait::async_trait;
use deepbook_schema::models::MarginManagerOperations;
use deepbook_schema::schema::margin_manager_operations;
use diesel_async::RunQueryDsl;
use move_core_types::language_storage::StructTag;
use std::sync::Arc;
use sui_indexer_alt_framework::pipeline::concurrent::Handler;
use sui_indexer_alt_framework::pipeline::Processor;
use sui_pg_db::{Connection, Db};
use sui_types::full_checkpoint_content::CheckpointData;
use tracing::debug;

pub struct MarginManagerOperationsHandler {
    margin_manager_event_type: StructTag,
    loan_borrowed_event_type: StructTag,
    loan_repaid_event_type: StructTag,
    liquidation_event_type: StructTag,
    env: DeepbookEnv,
}

impl MarginManagerOperationsHandler {
    pub fn new(env: DeepbookEnv) -> Self {
        Self {
            margin_manager_event_type: env.margin_manager_event_type(),
            loan_borrowed_event_type: env.loan_borrowed_event_type(),
            loan_repaid_event_type: env.loan_repaid_event_type(),
            liquidation_event_type: env.liquidation_event_type(),
            env,
        }
    }
}

impl Processor for MarginManagerOperationsHandler {
    const NAME: &'static str = "margin_manager_operations";
    type Value = MarginManagerOperations;

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
                if ev.type_ == self.margin_manager_event_type {
                    let event: MarginManagerEvent = bcs::from_bytes(&ev.contents)?;
                    let data = MarginManagerOperations {
                        event_digest: format!("{digest}{index}"),
                        digest: digest.to_string(),
                        sender: tx.transaction.sender_address().to_string(),
                        checkpoint,
                        checkpoint_timestamp_ms,
                        package: package.clone(),
                        margin_manager_id: event.margin_manager_id.to_string(),
                        balance_manager_id: Some(event.balance_manager_id.to_string()),
                        owner: Some(event.owner.to_string()),
                        margin_pool_id: None,
                        operation_type: "created".to_string(),
                        loan_amount: None,
                        total_borrow: None,
                        total_shares: None,
                        repay_amount: None,
                        repay_shares: None,
                        liquidation_amount: None,
                        pool_reward: None,
                        pool_default: None,
                        risk_ratio: None,
                        onchain_timestamp: event.timestamp as i64,
                    };
                    debug!("Observed DeepBook Margin Manager Created {:?}", data);
                    results.push(data);
                } else if ev.type_ == self.loan_borrowed_event_type {
                    let event: LoanBorrowedEvent = bcs::from_bytes(&ev.contents)?;
                    let data = MarginManagerOperations {
                        event_digest: format!("{digest}{index}"),
                        digest: digest.to_string(),
                        sender: tx.transaction.sender_address().to_string(),
                        checkpoint,
                        checkpoint_timestamp_ms,
                        package: package.clone(),
                        margin_manager_id: event.margin_manager_id.to_string(),
                        balance_manager_id: None,
                        owner: None,
                        margin_pool_id: Some(event.margin_pool_id.to_string()),
                        operation_type: "borrow".to_string(),
                        loan_amount: Some(event.loan_amount as i64),
                        total_borrow: Some(event.total_borrow as i64),
                        total_shares: Some(event.total_shares as i64),
                        repay_amount: None,
                        repay_shares: None,
                        liquidation_amount: None,
                        pool_reward: None,
                        pool_default: None,
                        risk_ratio: None,
                        onchain_timestamp: event.timestamp as i64,
                    };
                    debug!("Observed DeepBook Margin Loan Borrowed {:?}", data);
                    results.push(data);
                } else if ev.type_ == self.loan_repaid_event_type {
                    let event: LoanRepaidEvent = bcs::from_bytes(&ev.contents)?;
                    let data = MarginManagerOperations {
                        event_digest: format!("{digest}{index}"),
                        digest: digest.to_string(),
                        sender: tx.transaction.sender_address().to_string(),
                        checkpoint,
                        checkpoint_timestamp_ms,
                        package: package.clone(),
                        margin_manager_id: event.margin_manager_id.to_string(),
                        balance_manager_id: None,
                        owner: None,
                        margin_pool_id: Some(event.margin_pool_id.to_string()),
                        operation_type: "repay".to_string(),
                        loan_amount: None,
                        total_borrow: None,
                        total_shares: None,
                        repay_amount: Some(event.repay_amount as i64),
                        repay_shares: Some(event.repay_shares as i64),
                        liquidation_amount: None,
                        pool_reward: None,
                        pool_default: None,
                        risk_ratio: None,
                        onchain_timestamp: event.timestamp as i64,
                    };
                    debug!("Observed DeepBook Margin Loan Repaid {:?}", data);
                    results.push(data);
                } else if ev.type_ == self.liquidation_event_type {
                    let event: LiquidationEvent = bcs::from_bytes(&ev.contents)?;
                    let data = MarginManagerOperations {
                        event_digest: format!("{digest}{index}"),
                        digest: digest.to_string(),
                        sender: tx.transaction.sender_address().to_string(),
                        checkpoint,
                        checkpoint_timestamp_ms,
                        package: package.clone(),
                        margin_manager_id: event.margin_manager_id.to_string(),
                        balance_manager_id: None,
                        owner: None,
                        margin_pool_id: Some(event.margin_pool_id.to_string()),
                        operation_type: "liquidate".to_string(),
                        loan_amount: None,
                        total_borrow: None,
                        total_shares: None,
                        repay_amount: None,
                        repay_shares: None,
                        liquidation_amount: Some(event.liquidation_amount as i64),
                        pool_reward: Some(event.pool_reward as i64),
                        pool_default: Some(event.pool_default as i64),
                        risk_ratio: Some(event.risk_ratio as i64),
                        onchain_timestamp: event.timestamp as i64,
                    };
                    debug!("Observed DeepBook Margin Liquidation {:?}", data);
                    results.push(data);
                }
            }
        }
        Ok(results)
    }
}

#[async_trait]
impl Handler for MarginManagerOperationsHandler {
    type Store = Db;

    async fn commit<'a>(
        values: &[Self::Value],
        conn: &mut Connection<'a>,
    ) -> anyhow::Result<usize> {
        Ok(diesel::insert_into(margin_manager_operations::table)
            .values(values)
            .on_conflict_do_nothing()
            .execute(conn)
            .await?)
    }
}
