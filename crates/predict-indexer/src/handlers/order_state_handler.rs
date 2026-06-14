//! Maintained `order_state` pipeline: one row per packed order id, folded from
//! all five order-lifecycle events.
//!
//! Unlike the raw per-event handlers (append-only, `on_conflict_do_nothing`),
//! this single pipeline consumes OrderMinted, LiveOrderRedeemed,
//! SettledOrderRedeemed, LiquidatedOrderRedeemed, and OrderLiquidated, and
//! upserts a current-state row per order. Correctness does not depend on
//! commit order:
//!
//! * **Write-once columns** (identity, entry facts, `replacement_order_id`)
//!   are only ever provided by one event for a given order, so the upsert
//!   keeps the first non-null value (`COALESCE(existing, EXCLUDED)`).
//! * **Mutable columns** (`status`, `updated_at_ms`, and the
//!   `(checkpoint, tx_index, event_index)` triple) are last-write-wins,
//!   guarded by a row-value comparison on the triple. Reprocessing the same
//!   checkpoint re-applies identical values, so commits are idempotent.
//!
//! A partial live close synthesizes the replacement order's row from the
//! redeem event (replacements do not emit OrderMinted); the replacement's
//! contract terms are decoded from its packed id and its entry facts stay
//! NULL — consumers join `position_root_id` to the root row for those.

use crate::meta::PredictEventMeta;
use crate::models::{
    LiquidatedOrderRedeemed, LiveOrderRedeemed, OrderLiquidated, OrderMinted, SettledOrderRedeemed,
};
use crate::order_id::decode_order_id;
use crate::PredictEnv;
use bigdecimal::BigDecimal;
use diesel::sql_types::{BigInt, Nullable, Numeric, Text};
use move_core_types::u256::U256;
use predict_schema::models::OrderState as Row;
use std::collections::BTreeMap;
use sui_indexer_alt_framework::pipeline::Processor;
use sui_indexer_alt_framework::types::full_checkpoint_content::Checkpoint;

/// `order_state.status` values (shared with the server's queries).
pub use predict_schema::models::order_status as status;

/// Skeleton row for `order_id` with the decoded packed terms filled in and
/// every optional column NULL. Maps fill in what their event carries.
fn base_row(order_id: U256, expiry_market_id: String, st: &str, meta: &PredictEventMeta) -> Row {
    let decoded = decode_order_id(order_id);
    Row {
        expiry_market_id,
        order_id: order_id.to_string(),
        predict_manager_id: None,
        position_root_id: None,
        owner: None,
        status: st.to_string(),
        replacement_order_id: None,
        opened_at_ms: decoded.opened_at_ms as i64,
        lower_boundary_index: decoded.lower_boundary_index as i64,
        higher_boundary_index: decoded.higher_boundary_index as i64,
        floor_shares: BigDecimal::from(decoded.floor_shares),
        quantity: BigDecimal::from(decoded.quantity),
        sequence: decoded.sequence as i64,
        leverage: None,
        entry_probability: None,
        net_premium: None,
        updated_at_ms: meta.checkpoint_timestamp_ms(),
        checkpoint: meta.checkpoint(),
        tx_index: meta.tx_index(),
        event_index: meta.event_index(),
    }
}

pub fn map_minted(ev: &OrderMinted, meta: &PredictEventMeta) -> Row {
    let mut row = base_row(
        ev.order_id,
        ev.expiry_market_id.to_string(),
        status::OPEN,
        meta,
    );
    row.predict_manager_id = Some(ev.predict_manager_id.to_string());
    row.position_root_id = Some(ev.position_root_id.to_string());
    row.owner = Some(ev.owner.to_string());
    row.leverage = Some(ev.leverage as i64);
    row.entry_probability = Some(ev.entry_probability as i64);
    row.net_premium = Some(BigDecimal::from(ev.net_premium));
    row
}

/// The closed/replaced row for the redeemed order, plus the synthesized open
/// row for the replacement order on a partial close.
pub fn map_live_redeemed(ev: &LiveOrderRedeemed, meta: &PredictEventMeta) -> Vec<Row> {
    let market = ev.expiry_market_id.to_string();
    let closed_status = if ev.replacement_order_id.is_some() {
        status::REPLACED
    } else {
        status::CLOSED
    };

    let mut closed = base_row(ev.order_id, market.clone(), closed_status, meta);
    closed.predict_manager_id = Some(ev.predict_manager_id.to_string());
    closed.position_root_id = Some(ev.position_root_id.to_string());
    closed.owner = Some(ev.owner.to_string());
    closed.replacement_order_id = ev.replacement_order_id.map(|id| id.to_string());

    let mut rows = vec![closed];
    if let Some(replacement_id) = ev.replacement_order_id {
        let mut replacement = base_row(replacement_id, market, status::OPEN, meta);
        replacement.predict_manager_id = Some(ev.predict_manager_id.to_string());
        replacement.position_root_id = Some(ev.position_root_id.to_string());
        replacement.owner = Some(ev.owner.to_string());
        rows.push(replacement);
    }
    rows
}

pub fn map_settled_redeemed(ev: &SettledOrderRedeemed, meta: &PredictEventMeta) -> Row {
    let mut row = base_row(
        ev.order_id,
        ev.expiry_market_id.to_string(),
        status::SETTLED_REDEEMED,
        meta,
    );
    row.predict_manager_id = Some(ev.predict_manager_id.to_string());
    row.position_root_id = Some(ev.position_root_id.to_string());
    row.owner = Some(ev.owner.to_string());
    row
}

pub fn map_liquidated_redeemed(ev: &LiquidatedOrderRedeemed, meta: &PredictEventMeta) -> Row {
    let mut row = base_row(
        ev.order_id,
        ev.expiry_market_id.to_string(),
        status::LIQUIDATED_REDEEMED,
        meta,
    );
    row.predict_manager_id = Some(ev.predict_manager_id.to_string());
    row.position_root_id = Some(ev.position_root_id.to_string());
    row.owner = Some(ev.owner.to_string());
    row
}

/// Liquidation is permissionless and carries no manager/owner; identity stays
/// NULL until (or unless) another event fills it.
pub fn map_order_liquidated(ev: &OrderLiquidated, meta: &PredictEventMeta) -> Row {
    base_row(
        ev.order_id,
        ev.expiry_market_id.to_string(),
        status::LIQUIDATED,
        meta,
    )
}

fn triple(row: &Row) -> (i64, i64, i64) {
    (row.checkpoint, row.tx_index, row.event_index)
}

/// Merge two rows for the same `(expiry_market_id, order_id)`, `later` having
/// the >= event triple. Mirrors the SQL upsert: write-once columns keep the
/// first non-null value, mutable columns take the later event's values.
pub fn merge_rows(earlier: Row, later: Row) -> Row {
    Row {
        predict_manager_id: earlier.predict_manager_id.or(later.predict_manager_id),
        position_root_id: earlier.position_root_id.or(later.position_root_id),
        owner: earlier.owner.or(later.owner),
        replacement_order_id: earlier.replacement_order_id.or(later.replacement_order_id),
        leverage: earlier.leverage.or(later.leverage),
        entry_probability: earlier.entry_probability.or(later.entry_probability),
        net_premium: earlier.net_premium.or(later.net_premium),
        ..later
    }
}

/// Collapse a batch to one row per `(expiry_market_id, order_id)` (Postgres
/// rejects two rows for the same conflict key in one statement; packed order
/// ids are expiry-local so the bare id is not a key), applying events in
/// triple order.
pub fn fold_rows(values: &[Row]) -> Vec<Row> {
    let mut by_order: BTreeMap<(String, String), Vec<Row>> = BTreeMap::new();
    for row in values {
        by_order
            .entry((row.expiry_market_id.clone(), row.order_id.clone()))
            .or_default()
            .push(row.clone());
    }
    by_order
        .into_values()
        .map(|mut rows| {
            rows.sort_by_key(triple);
            let mut rows = rows.into_iter();
            let first = rows.next().expect("group is non-empty");
            rows.fold(first, merge_rows)
        })
        .collect()
}

/// One multi-row upsert per chunk of folded rows. Write-once columns
/// COALESCE-keep the existing value; mutable columns apply only when the
/// incoming triple is >= the stored one (idempotent under at-least-once
/// reprocessing, order-independent across out-of-order batch commits).
///
/// The statement is assembled as `UPSERT_PREFIX` + a generated
/// `($1,...,$20),($21,...,$40),...` VALUES list + `UPSERT_SUFFIX`, so the
/// column list and ON CONFLICT clause are each written exactly once.
const UPSERT_PREFIX: &str = r#"
INSERT INTO order_state (
    expiry_market_id, order_id, predict_manager_id, position_root_id, owner,
    status, replacement_order_id,
    opened_at_ms, lower_boundary_index, higher_boundary_index, floor_shares, quantity, sequence,
    leverage, entry_probability, net_premium,
    updated_at_ms, checkpoint, tx_index, event_index
) VALUES "#;

const UPSERT_SUFFIX: &str = r#"
ON CONFLICT (expiry_market_id, order_id) DO UPDATE SET
    predict_manager_id   = COALESCE(order_state.predict_manager_id, EXCLUDED.predict_manager_id),
    position_root_id     = COALESCE(order_state.position_root_id, EXCLUDED.position_root_id),
    owner                = COALESCE(order_state.owner, EXCLUDED.owner),
    replacement_order_id = COALESCE(order_state.replacement_order_id, EXCLUDED.replacement_order_id),
    leverage             = COALESCE(order_state.leverage, EXCLUDED.leverage),
    entry_probability    = COALESCE(order_state.entry_probability, EXCLUDED.entry_probability),
    net_premium          = COALESCE(order_state.net_premium, EXCLUDED.net_premium),
    status = CASE WHEN (EXCLUDED.checkpoint, EXCLUDED.tx_index, EXCLUDED.event_index)
                       >= (order_state.checkpoint, order_state.tx_index, order_state.event_index)
             THEN EXCLUDED.status ELSE order_state.status END,
    updated_at_ms = CASE WHEN (EXCLUDED.checkpoint, EXCLUDED.tx_index, EXCLUDED.event_index)
                              >= (order_state.checkpoint, order_state.tx_index, order_state.event_index)
                    THEN EXCLUDED.updated_at_ms ELSE order_state.updated_at_ms END,
    checkpoint = CASE WHEN (EXCLUDED.checkpoint, EXCLUDED.tx_index, EXCLUDED.event_index)
                           >= (order_state.checkpoint, order_state.tx_index, order_state.event_index)
                 THEN EXCLUDED.checkpoint ELSE order_state.checkpoint END,
    tx_index = CASE WHEN (EXCLUDED.checkpoint, EXCLUDED.tx_index, EXCLUDED.event_index)
                         >= (order_state.checkpoint, order_state.tx_index, order_state.event_index)
               THEN EXCLUDED.tx_index ELSE order_state.tx_index END,
    event_index = CASE WHEN (EXCLUDED.checkpoint, EXCLUDED.tx_index, EXCLUDED.event_index)
                            >= (order_state.checkpoint, order_state.tx_index, order_state.event_index)
                  THEN EXCLUDED.event_index ELSE order_state.event_index END
"#;

/// Bind parameters per row tuple in the VALUES list.
const BINDS_PER_ROW: usize = 20;

/// Rows per upsert statement: 500 * 20 = 10,000 binds, far below Postgres's
/// 65,535 bind-parameter limit.
const UPSERT_CHUNK_ROWS: usize = 500;

/// `($1,$2,...,$22),($23,...,$44),...` for `n_rows` row tuples.
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

pub struct OrderStateHandler {
    env: PredictEnv,
}

impl OrderStateHandler {
    pub fn new(env: PredictEnv) -> Self {
        Self { env }
    }
}

#[async_trait::async_trait]
impl Processor for OrderStateHandler {
    const NAME: &'static str = "order_state";
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
                if OrderMinted::matches_event_type(&ev.type_, self.env) {
                    let decoded: OrderMinted = bcs::from_bytes(&ev.contents)?;
                    results.push(map_minted(&decoded, &meta));
                } else if LiveOrderRedeemed::matches_event_type(&ev.type_, self.env) {
                    let decoded: LiveOrderRedeemed = bcs::from_bytes(&ev.contents)?;
                    results.extend(map_live_redeemed(&decoded, &meta));
                } else if SettledOrderRedeemed::matches_event_type(&ev.type_, self.env) {
                    let decoded: SettledOrderRedeemed = bcs::from_bytes(&ev.contents)?;
                    results.push(map_settled_redeemed(&decoded, &meta));
                } else if LiquidatedOrderRedeemed::matches_event_type(&ev.type_, self.env) {
                    let decoded: LiquidatedOrderRedeemed = bcs::from_bytes(&ev.contents)?;
                    results.push(map_liquidated_redeemed(&decoded, &meta));
                } else if OrderLiquidated::matches_event_type(&ev.type_, self.env) {
                    let decoded: OrderLiquidated = bcs::from_bytes(&ev.contents)?;
                    results.push(map_order_liquidated(&decoded, &meta));
                }
            }
        }
        Ok(results)
    }
}

#[async_trait::async_trait]
impl sui_indexer_alt_framework::postgres::handler::Handler for OrderStateHandler {
    async fn commit<'a>(
        values: &[Self::Value],
        conn: &mut sui_pg_db::Connection<'a>,
    ) -> anyhow::Result<usize> {
        use diesel_async::RunQueryDsl;

        let rows = fold_rows(values);
        let mut affected = 0;
        // Precondition for the multi-row form: `fold_rows` returns at most one
        // row per `(expiry_market_id, order_id)` conflict key — a single
        // INSERT ... ON CONFLICT DO UPDATE statement cannot affect the same
        // row twice.
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
                    .bind::<Text, _>(&row.expiry_market_id)
                    .bind::<Text, _>(&row.order_id)
                    .bind::<Nullable<Text>, _>(&row.predict_manager_id)
                    .bind::<Nullable<Text>, _>(&row.position_root_id)
                    .bind::<Nullable<Text>, _>(&row.owner)
                    .bind::<Text, _>(&row.status)
                    .bind::<Nullable<Text>, _>(&row.replacement_order_id)
                    .bind::<BigInt, _>(row.opened_at_ms)
                    .bind::<BigInt, _>(row.lower_boundary_index)
                    .bind::<BigInt, _>(row.higher_boundary_index)
                    .bind::<Numeric, _>(&row.floor_shares)
                    .bind::<Numeric, _>(&row.quantity)
                    .bind::<BigInt, _>(row.sequence)
                    .bind::<Nullable<BigInt>, _>(row.leverage)
                    .bind::<Nullable<BigInt>, _>(row.entry_probability)
                    .bind::<Nullable<Numeric>, _>(&row.net_premium)
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
