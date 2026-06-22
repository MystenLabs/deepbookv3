//! Live Block Scholes surface observations (`oracle_lane::ObservationRecorded<
//! OracleRead<block_scholes_feed::RawSurface>>`, emitted by
//! `block_scholes_feed::update`). Writes `block_scholes_observation` rows with
//! `is_exact = false`.

use crate::handlers::is_propbook_tx;
use crate::handlers::observation_map::{map_bs, payload_is_bs_surface};
use crate::meta::OracleEventMeta;
use crate::models::{BlockScholesObservationEvent, ObservationRecorded};
use crate::traits::MoveStruct;
use crate::OracleEnv;
use predict_schema::models::BlockScholesObservation as Row;
use sui_indexer_alt_framework::pipeline::Processor;
use sui_indexer_alt_framework::types::full_checkpoint_content::Checkpoint;

pub struct BlockScholesObservationRecordedHandler {
    env: OracleEnv,
}

impl BlockScholesObservationRecordedHandler {
    pub fn new(env: OracleEnv) -> Self {
        Self { env }
    }
}

#[async_trait::async_trait]
impl Processor for BlockScholesObservationRecordedHandler {
    const NAME: &'static str = "block_scholes_observation_recorded";
    type Value = Row;

    async fn process(
        &self,
        checkpoint: &std::sync::Arc<Checkpoint>,
    ) -> anyhow::Result<Vec<Self::Value>> {
        let mut results = vec![];
        for (tx_index, tx) in checkpoint.transactions.iter().enumerate() {
            if !is_propbook_tx(tx, &checkpoint.object_set, self.env) {
                continue;
            }
            let Some(events) = &tx.events else { continue };

            let base_meta = OracleEventMeta::from_checkpoint_tx(checkpoint, tx, tx_index);

            for (index, ev) in events.data.iter().enumerate() {
                if ObservationRecorded::matches_event_type(&ev.type_, self.env)
                    && payload_is_bs_surface(&ev.type_)
                {
                    let decoded: BlockScholesObservationEvent = bcs::from_bytes(&ev.contents)?;
                    let meta =
                        base_meta.with_event(index, ev.type_.address.to_canonical_string(true));
                    results.push(map_bs(&decoded, &meta, false));
                    tracing::debug!("Observed block_scholes_observation_recorded event");
                }
            }
        }
        Ok(results)
    }
}

#[async_trait::async_trait]
impl sui_indexer_alt_framework::postgres::handler::Handler
    for BlockScholesObservationRecordedHandler
{
    async fn commit<'a>(
        values: &[Self::Value],
        conn: &mut sui_pg_db::Connection<'a>,
    ) -> anyhow::Result<usize> {
        use diesel_async::RunQueryDsl;
        Ok(
            diesel::insert_into(predict_schema::schema::block_scholes_observation::table)
                .values(values)
                .on_conflict_do_nothing()
                .execute(conn)
                .await?,
        )
    }
}
