use crate::handlers::{is_deepbook_tx, try_extract_move_call_package};
use crate::models::deepbook_margin::margin_pool::{
    MaintainerFeesWithdrawn, ProtocolFeesWithdrawn,
};
use crate::models::deepbook_margin::referral_fees::{
    ProtocolFeesIncreasedEvent, ReferralFeesClaimedEvent,
};
use crate::DeepbookEnv;
use async_trait::async_trait;
use deepbook_schema::models::MarginFees;
use deepbook_schema::schema::margin_fees;
use diesel_async::RunQueryDsl;
use move_core_types::language_storage::StructTag;
use std::sync::Arc;
use sui_indexer_alt_framework::pipeline::concurrent::Handler;
use sui_indexer_alt_framework::pipeline::Processor;
use sui_pg_db::{Connection, Db};
use sui_types::full_checkpoint_content::CheckpointData;
use tracing::debug;

pub struct MarginFeesHandler {
    maintainer_fees_withdrawn_event_type: StructTag,
    protocol_fees_withdrawn_event_type: StructTag,
    referral_fees_claimed_event_type: StructTag,
    protocol_fees_increased_event_type: StructTag,
    env: DeepbookEnv,
}

impl MarginFeesHandler {
    pub fn new(env: DeepbookEnv) -> Self {
        Self {
            maintainer_fees_withdrawn_event_type: env.maintainer_fees_withdrawn_event_type(),
            protocol_fees_withdrawn_event_type: env.protocol_fees_withdrawn_event_type(),
            referral_fees_claimed_event_type: env.referral_fees_claimed_event_type(),
            protocol_fees_increased_event_type: env.protocol_fees_increased_event_type(),
            env,
        }
    }
}

impl Processor for MarginFeesHandler {
    const NAME: &'static str = "margin_fees";
    type Value = MarginFees;

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

                if ev.type_ == self.maintainer_fees_withdrawn_event_type {
                    let event: MaintainerFeesWithdrawn = bcs::from_bytes(&ev.contents)?;
                    let data = MarginFees {
                        event_digest: format!("{digest}{index}"),
                        digest: digest.to_string(),
                        sender: tx.transaction.sender_address().to_string(),
                        checkpoint,
                        checkpoint_timestamp_ms,
                        package: package.clone(),
                        fee_type: "maintainer_withdrawn".to_string(),
                        margin_pool_id: Some(event.margin_pool_id.to_string()),
                        maintainer_cap_id: Some(event.maintainer_cap_id.to_string()),
                        referral_id: None,
                        owner: None,
                        fees: Some(event.maintainer_fees as i64),
                        maintainer_fees: None,
                        protocol_fees: None,
                        referral_fees: None,
                        total_shares: None,
                        onchain_timestamp: event.timestamp as i64,
                    };
                    debug!("Observed DeepBook Margin Maintainer Fees Withdrawn {:?}", data);
                    results.push(data);
                } else if ev.type_ == self.protocol_fees_withdrawn_event_type {
                    let event: ProtocolFeesWithdrawn = bcs::from_bytes(&ev.contents)?;
                    let data = MarginFees {
                        event_digest: format!("{digest}{index}"),
                        digest: digest.to_string(),
                        sender: tx.transaction.sender_address().to_string(),
                        checkpoint,
                        checkpoint_timestamp_ms,
                        package: package.clone(),
                        fee_type: "protocol_withdrawn".to_string(),
                        margin_pool_id: Some(event.margin_pool_id.to_string()),
                        maintainer_cap_id: None,
                        referral_id: None,
                        owner: None,
                        fees: Some(event.protocol_fees as i64),
                        maintainer_fees: None,
                        protocol_fees: Some(event.protocol_fees as i64),
                        referral_fees: None,
                        total_shares: None,
                        onchain_timestamp: event.timestamp as i64,
                    };
                    debug!("Observed DeepBook Margin Protocol Fees Withdrawn {:?}", data);
                    results.push(data);
                } else if ev.type_ == self.referral_fees_claimed_event_type {
                    let event: ReferralFeesClaimedEvent = bcs::from_bytes(&ev.contents)?;
                    let data = MarginFees {
                        event_digest: format!("{digest}{index}"),
                        digest: digest.to_string(),
                        sender: tx.transaction.sender_address().to_string(),
                        checkpoint,
                        checkpoint_timestamp_ms,
                        package: package.clone(),
                        fee_type: "referral_claimed".to_string(),
                        margin_pool_id: None,
                        maintainer_cap_id: None,
                        referral_id: Some(event.referral_id.to_string()),
                        owner: Some(event.owner.to_string()),
                        fees: Some(event.fees as i64),
                        maintainer_fees: None,
                        protocol_fees: None,
                        referral_fees: None,
                        total_shares: None,
                        onchain_timestamp: event.timestamp as i64,
                    };
                    debug!("Observed DeepBook Margin Referral Fees Claimed {:?}", data);
                    results.push(data);
                } else if ev.type_ == self.protocol_fees_increased_event_type {
                    let event: ProtocolFeesIncreasedEvent = bcs::from_bytes(&ev.contents)?;
                    let data = MarginFees {
                        event_digest: format!("{digest}{index}"),
                        digest: digest.to_string(),
                        sender: tx.transaction.sender_address().to_string(),
                        checkpoint,
                        checkpoint_timestamp_ms,
                        package: package.clone(),
                        fee_type: "protocol_increased".to_string(),
                        margin_pool_id: None,
                        maintainer_cap_id: None,
                        referral_id: None,
                        owner: None,
                        fees: None,
                        maintainer_fees: Some(event.maintainer_fees as i64),
                        protocol_fees: Some(event.protocol_fees as i64),
                        referral_fees: Some(event.referral_fees as i64),
                        total_shares: Some(event.total_shares as i64),
                        onchain_timestamp: event.timestamp as i64,
                    };
                    debug!("Observed DeepBook Margin Protocol Fees Increased {:?}", data);
                    results.push(data);
                }
            }
        }
        Ok(results)
    }
}

#[async_trait]
impl Handler for MarginFeesHandler {
    type Store = Db;

    async fn commit<'a>(
        values: &[Self::Value],
        conn: &mut Connection<'a>,
    ) -> anyhow::Result<usize> {
        Ok(diesel::insert_into(margin_fees::table)
            .values(values)
            .on_conflict_do_nothing()
            .execute(conn)
            .await?)
    }
}
