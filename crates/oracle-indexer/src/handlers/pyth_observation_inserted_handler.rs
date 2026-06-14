//! Exact-ms Pyth spot history (`oracle_lane::ObservationInserted<OracleRead<
//! pyth_feed::RawSpot>>`, emitted by `pyth_feed::insert_at`). Writes
//! `pyth_observation` rows with `is_exact = true`.

use crate::handlers::is_propbook_tx;
use crate::handlers::observation_map::{map_pyth, payload_is_pyth_spot};
use crate::meta::OracleEventMeta;
use crate::models::{ObservationInserted, PythObservationEvent};
use crate::traits::MoveStruct;
use crate::OracleEnv;
use predict_schema::models::PythObservation as Row;
use sui_indexer_alt_framework::pipeline::Processor;
use sui_indexer_alt_framework::types::full_checkpoint_content::Checkpoint;

pub struct PythObservationInsertedHandler {
    env: OracleEnv,
}

impl PythObservationInsertedHandler {
    pub fn new(env: OracleEnv) -> Self {
        Self { env }
    }
}

#[async_trait::async_trait]
impl Processor for PythObservationInsertedHandler {
    const NAME: &'static str = "pyth_observation_inserted";
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
                if ObservationInserted::matches_event_type(&ev.type_, self.env)
                    && payload_is_pyth_spot(&ev.type_)
                {
                    let decoded: PythObservationEvent = bcs::from_bytes(&ev.contents)?;
                    let meta =
                        base_meta.with_event(index, ev.type_.address.to_canonical_string(true));
                    results.push(map_pyth(&decoded, &meta, true));
                    tracing::debug!("Observed pyth_observation_inserted event");
                }
            }
        }
        Ok(results)
    }
}

#[async_trait::async_trait]
impl sui_indexer_alt_framework::postgres::handler::Handler for PythObservationInsertedHandler {
    async fn commit<'a>(
        values: &[Self::Value],
        conn: &mut sui_pg_db::Connection<'a>,
    ) -> anyhow::Result<usize> {
        use diesel_async::RunQueryDsl;
        Ok(
            diesel::insert_into(predict_schema::schema::pyth_observation::table)
                .values(values)
                .on_conflict_do_nothing()
                .execute(conn)
                .await?,
        )
    }
}
