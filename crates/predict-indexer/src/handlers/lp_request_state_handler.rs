//! Maintained `lp_request_state` pipeline: one row per async LP request, folded
//! from the request/cancel/fill events.
//!
//! Mirrors `order_state_handler`: a single pipeline consumes SupplyRequested,
//! WithdrawRequested, RequestCancelled, SupplyFilled, and WithdrawFilled, and
//! upserts a current-state row per `(pool_vault_id, is_supply, request_index)`
//! (the queue handle is unique only within a (vault, is_supply) queue). Order
//! independence:
//!
//! * **Write-once columns** (identity, requested amount, fill facts) keep the
//!   first non-null value (`COALESCE`). The fill events carry the manager id and
//!   recipient too, so identity survives even if a fill commits before its
//!   request.
//! * **`opened_at_ms`** takes `LEAST` of all events' timestamps — the request is
//!   always the earliest event for a handle, so this is the request time
//!   regardless of commit order.
//! * **`status` + the `(checkpoint, tx_index, event_index)` triple** are
//!   last-write-wins, guarded by a row-value comparison on the triple, so
//!   commits are idempotent and order-independent.

use crate::meta::PredictEventMeta;
use crate::models::{
    RequestCancelled, SupplyFilled, SupplyRequested, WithdrawFilled, WithdrawRequested,
};
use crate::PredictEnv;
use bigdecimal::BigDecimal;
use diesel::sql_types::{BigInt, Bool, Nullable, Numeric, Text};
use predict_schema::models::LpRequestState as Row;
use std::collections::BTreeMap;
use sui_indexer_alt_framework::pipeline::Processor;
use sui_indexer_alt_framework::types::full_checkpoint_content::Checkpoint;

/// `lp_request_state.status` values (shared with the server's queries).
pub use predict_schema::models::lp_request_status as status;

/// Skeleton row for one request handle with every optional column NULL. Maps
/// fill in what their event carries.
fn base_row(
    pool_vault_id: String,
    is_supply: bool,
    index: u64,
    st: &str,
    meta: &PredictEventMeta,
) -> Row {
    Row {
        pool_vault_id,
        is_supply,
        request_index: index as i64,
        predict_manager_id: None,
        recipient: None,
        requested_amount: None,
        status: st.to_string(),
        filled_dusdc: None,
        filled_shares: None,
        opened_at_ms: meta.checkpoint_timestamp_ms(),
        updated_at_ms: meta.checkpoint_timestamp_ms(),
        checkpoint: meta.checkpoint(),
        tx_index: meta.tx_index(),
        event_index: meta.event_index(),
    }
}

pub fn map_supply_requested(ev: &SupplyRequested, meta: &PredictEventMeta) -> Row {
    let mut row = base_row(
        ev.pool_vault_id.to_string(),
        true,
        ev.index,
        status::OPEN,
        meta,
    );
    row.predict_manager_id = Some(ev.predict_manager_id.to_string());
    row.recipient = Some(ev.recipient.to_string());
    row.requested_amount = Some(BigDecimal::from(ev.amount));
    row
}

pub fn map_withdraw_requested(ev: &WithdrawRequested, meta: &PredictEventMeta) -> Row {
    let mut row = base_row(
        ev.pool_vault_id.to_string(),
        false,
        ev.index,
        status::OPEN,
        meta,
    );
    row.predict_manager_id = Some(ev.predict_manager_id.to_string());
    row.recipient = Some(ev.recipient.to_string());
    row.requested_amount = Some(BigDecimal::from(ev.amount));
    row
}

pub fn map_request_cancelled(ev: &RequestCancelled, meta: &PredictEventMeta) -> Row {
    let mut row = base_row(
        ev.pool_vault_id.to_string(),
        ev.is_supply,
        ev.index,
        status::CANCELLED,
        meta,
    );
    row.predict_manager_id = Some(ev.predict_manager_id.to_string());
    row.recipient = Some(ev.recipient.to_string());
    row.requested_amount = Some(BigDecimal::from(ev.amount));
    row
}

pub fn map_supply_filled(ev: &SupplyFilled, meta: &PredictEventMeta) -> Row {
    let mut row = base_row(
        ev.pool_vault_id.to_string(),
        true,
        ev.index,
        status::FILLED,
        meta,
    );
    row.predict_manager_id = Some(ev.predict_manager_id.to_string());
    row.recipient = Some(ev.recipient.to_string());
    row.filled_dusdc = Some(BigDecimal::from(ev.dusdc_amount));
    row.filled_shares = Some(BigDecimal::from(ev.shares_minted));
    row
}

pub fn map_withdraw_filled(ev: &WithdrawFilled, meta: &PredictEventMeta) -> Row {
    let mut row = base_row(
        ev.pool_vault_id.to_string(),
        false,
        ev.index,
        status::FILLED,
        meta,
    );
    row.predict_manager_id = Some(ev.predict_manager_id.to_string());
    row.recipient = Some(ev.recipient.to_string());
    row.filled_dusdc = Some(BigDecimal::from(ev.dusdc_amount));
    row.filled_shares = Some(BigDecimal::from(ev.shares_burned));
    row
}

fn triple(row: &Row) -> (i64, i64, i64) {
    (row.checkpoint, row.tx_index, row.event_index)
}

/// Merge two rows for the same handle, `later` having the >= event triple.
/// Mirrors the SQL upsert: write-once columns keep the first non-null value,
/// `opened_at_ms` is the earliest, mutable columns take the later event.
pub fn merge_rows(earlier: Row, later: Row) -> Row {
    Row {
        predict_manager_id: earlier.predict_manager_id.or(later.predict_manager_id),
        recipient: earlier.recipient.or(later.recipient),
        requested_amount: earlier.requested_amount.or(later.requested_amount),
        filled_dusdc: earlier.filled_dusdc.or(later.filled_dusdc),
        filled_shares: earlier.filled_shares.or(later.filled_shares),
        opened_at_ms: earlier.opened_at_ms.min(later.opened_at_ms),
        ..later
    }
}

/// Collapse a batch to one row per `(pool_vault_id, is_supply, request_index)`,
/// applying events in triple order.
pub fn fold_rows(values: &[Row]) -> Vec<Row> {
    let mut by_handle: BTreeMap<(String, bool, i64), Vec<Row>> = BTreeMap::new();
    for row in values {
        by_handle
            .entry((row.pool_vault_id.clone(), row.is_supply, row.request_index))
            .or_default()
            .push(row.clone());
    }
    by_handle
        .into_values()
        .map(|mut rows| {
            rows.sort_by_key(triple);
            let mut rows = rows.into_iter();
            let first = rows.next().expect("group is non-empty");
            rows.fold(first, merge_rows)
        })
        .collect()
}

/// Assembled as `UPSERT_PREFIX` + a generated `($1,...,$14),($15,...,$28),...`
/// VALUES list + `UPSERT_SUFFIX`.
const UPSERT_PREFIX: &str = r#"
INSERT INTO lp_request_state (
    pool_vault_id, is_supply, request_index,
    predict_manager_id, recipient, requested_amount,
    status, filled_dusdc, filled_shares,
    opened_at_ms, updated_at_ms, checkpoint, tx_index, event_index
) VALUES "#;

const UPSERT_SUFFIX: &str = r#"
ON CONFLICT (pool_vault_id, is_supply, request_index) DO UPDATE SET
    predict_manager_id = COALESCE(lp_request_state.predict_manager_id, EXCLUDED.predict_manager_id),
    recipient          = COALESCE(lp_request_state.recipient, EXCLUDED.recipient),
    requested_amount   = COALESCE(lp_request_state.requested_amount, EXCLUDED.requested_amount),
    filled_dusdc       = COALESCE(lp_request_state.filled_dusdc, EXCLUDED.filled_dusdc),
    filled_shares      = COALESCE(lp_request_state.filled_shares, EXCLUDED.filled_shares),
    opened_at_ms       = LEAST(lp_request_state.opened_at_ms, EXCLUDED.opened_at_ms),
    status = CASE WHEN (EXCLUDED.checkpoint, EXCLUDED.tx_index, EXCLUDED.event_index)
                       >= (lp_request_state.checkpoint, lp_request_state.tx_index, lp_request_state.event_index)
             THEN EXCLUDED.status ELSE lp_request_state.status END,
    updated_at_ms = CASE WHEN (EXCLUDED.checkpoint, EXCLUDED.tx_index, EXCLUDED.event_index)
                              >= (lp_request_state.checkpoint, lp_request_state.tx_index, lp_request_state.event_index)
                    THEN EXCLUDED.updated_at_ms ELSE lp_request_state.updated_at_ms END,
    checkpoint = CASE WHEN (EXCLUDED.checkpoint, EXCLUDED.tx_index, EXCLUDED.event_index)
                           >= (lp_request_state.checkpoint, lp_request_state.tx_index, lp_request_state.event_index)
                 THEN EXCLUDED.checkpoint ELSE lp_request_state.checkpoint END,
    tx_index = CASE WHEN (EXCLUDED.checkpoint, EXCLUDED.tx_index, EXCLUDED.event_index)
                         >= (lp_request_state.checkpoint, lp_request_state.tx_index, lp_request_state.event_index)
               THEN EXCLUDED.tx_index ELSE lp_request_state.tx_index END,
    event_index = CASE WHEN (EXCLUDED.checkpoint, EXCLUDED.tx_index, EXCLUDED.event_index)
                            >= (lp_request_state.checkpoint, lp_request_state.tx_index, lp_request_state.event_index)
                  THEN EXCLUDED.event_index ELSE lp_request_state.event_index END
"#;

/// Bind parameters per row tuple in the VALUES list.
const BINDS_PER_ROW: usize = 14;

/// Rows per upsert statement: 500 * 14 = 7,000 binds, far below Postgres's
/// 65,535 bind-parameter limit.
const UPSERT_CHUNK_ROWS: usize = 500;

fn values_placeholders(n_rows: usize) -> String {
    let mut sql = String::new();
    for row in 0..n_rows {
        if row > 0 {
            sql.push(',');
        }
        sql.push('(');
        for col in 0..BINDS_PER_ROW {
            if col > 0 {
                sql.push(',');
            }
            sql.push('$');
            sql.push_str(&(row * BINDS_PER_ROW + col + 1).to_string());
        }
        sql.push(')');
    }
    sql
}

pub struct LpRequestStateHandler {
    env: PredictEnv,
}

impl LpRequestStateHandler {
    pub fn new(env: PredictEnv) -> Self {
        Self { env }
    }
}

#[async_trait::async_trait]
impl Processor for LpRequestStateHandler {
    const NAME: &'static str = "lp_request_state";
    type Value = Row;

    async fn process(
        &self,
        checkpoint: &std::sync::Arc<Checkpoint>,
    ) -> anyhow::Result<Vec<Self::Value>> {
        use crate::handlers::is_predict_tx;
        use crate::traits::MoveStruct;

        let mut results = vec![];
        for (tx_index, tx) in checkpoint.transactions.iter().enumerate() {
            if !is_predict_tx(tx, &checkpoint.object_set, self.env) {
                continue;
            }
            let Some(events) = &tx.events else { continue };

            let base_meta = PredictEventMeta::from_checkpoint_tx(checkpoint, tx, tx_index);

            for (index, ev) in events.data.iter().enumerate() {
                let meta = base_meta.with_event(index, ev.type_.address.to_canonical_string(true));
                if SupplyRequested::matches_event_type(&ev.type_, self.env) {
                    let decoded: SupplyRequested = bcs::from_bytes(&ev.contents)?;
                    results.push(map_supply_requested(&decoded, &meta));
                } else if WithdrawRequested::matches_event_type(&ev.type_, self.env) {
                    let decoded: WithdrawRequested = bcs::from_bytes(&ev.contents)?;
                    results.push(map_withdraw_requested(&decoded, &meta));
                } else if RequestCancelled::matches_event_type(&ev.type_, self.env) {
                    let decoded: RequestCancelled = bcs::from_bytes(&ev.contents)?;
                    results.push(map_request_cancelled(&decoded, &meta));
                } else if SupplyFilled::matches_event_type(&ev.type_, self.env) {
                    let decoded: SupplyFilled = bcs::from_bytes(&ev.contents)?;
                    results.push(map_supply_filled(&decoded, &meta));
                } else if WithdrawFilled::matches_event_type(&ev.type_, self.env) {
                    let decoded: WithdrawFilled = bcs::from_bytes(&ev.contents)?;
                    results.push(map_withdraw_filled(&decoded, &meta));
                }
            }
        }
        Ok(results)
    }
}

#[async_trait::async_trait]
impl sui_indexer_alt_framework::postgres::handler::Handler for LpRequestStateHandler {
    async fn commit<'a>(
        values: &[Self::Value],
        conn: &mut sui_pg_db::Connection<'a>,
    ) -> anyhow::Result<usize> {
        use diesel_async::RunQueryDsl;

        let rows = fold_rows(values);
        let mut affected = 0;
        for chunk in rows.chunks(UPSERT_CHUNK_ROWS) {
            let sql = format!(
                "{}{}{}",
                UPSERT_PREFIX,
                values_placeholders(chunk.len()),
                UPSERT_SUFFIX
            );
            let mut query = diesel::sql_query(sql).into_boxed();
            for row in chunk {
                query = query
                    .bind::<Text, _>(&row.pool_vault_id)
                    .bind::<Bool, _>(row.is_supply)
                    .bind::<BigInt, _>(row.request_index)
                    .bind::<Nullable<Text>, _>(&row.predict_manager_id)
                    .bind::<Nullable<Text>, _>(&row.recipient)
                    .bind::<Nullable<Numeric>, _>(&row.requested_amount)
                    .bind::<Text, _>(&row.status)
                    .bind::<Nullable<Numeric>, _>(&row.filled_dusdc)
                    .bind::<Nullable<Numeric>, _>(&row.filled_shares)
                    .bind::<BigInt, _>(row.opened_at_ms)
                    .bind::<BigInt, _>(row.updated_at_ms)
                    .bind::<BigInt, _>(row.checkpoint)
                    .bind::<BigInt, _>(row.tx_index)
                    .bind::<BigInt, _>(row.event_index);
            }
            affected += query.execute(conn).await?;
        }
        Ok(affected)
    }
}
