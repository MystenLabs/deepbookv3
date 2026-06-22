// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

//! Unit tests for the packed order-id decoder and the `order_state` pipeline's
//! map/merge/fold logic.
//!
//! The packed-id reference values are the independently-derived ids from
//! `packages/predict/tests/order/order_tests.move` (derived there from the
//! documented u256 layout, not from the contract's pack expression), so these
//! tests pin the Rust decoder to the same independent layout the Move tests
//! pin the contract to.

use bigdecimal::BigDecimal;
use move_core_types::u256::U256;
use predict_indexer::handlers::order_state_handler::{
    fold_rows, map_liquidated_redeemed, map_live_redeemed, map_minted, map_order_liquidated,
    map_settled_redeemed, status,
};
use predict_indexer::meta::PredictEventMeta;
use predict_indexer::models::{
    LiquidatedOrderRedeemed, LiveOrderRedeemed, OrderLiquidated, OrderMinted,
};
use predict_indexer::order_id::{decode_order_id, DecodedOrderId, POSITION_LOT_SIZE};
use std::str::FromStr;
use sui_types::base_types::ObjectID;

// === Independently packed reference ids (packages/predict/tests/order/order_tests.move) ===

// pack(opened=1000, lower=0, higher=100001, floor=50000, qlots=7, seq=12345)
const LEVERAGED_ID: &str = "6901746335541997477621819577781881932119187661683188027568322148053049";
const LEV_OPENED: u64 = 1000;
const LEV_LOWER: u64 = 0;
const LEV_HIGHER: u64 = 100_001;
const LEV_FLOOR: u64 = 50_000;
const LEV_QLOTS: u64 = 7;
const LEV_QUANTITY: u64 = 70_000; // 7 * position_lot_size (10_000)
const LEV_SEQ: u64 = 12_345;

// pack(opened=2000, lower=3, higher=7, floor=0, qlots=12, seq=88)
const NONLEV_ID: &str = "6901746327507307256326872555686368058426016465277024760643844810211416";
const NONLEV_OPENED: u64 = 2000;
const NONLEV_LOWER: u64 = 3;
const NONLEV_HIGHER: u64 = 7;
const NONLEV_FLOOR: u64 = 0;
const NONLEV_QLOTS: u64 = 12;
const NONLEV_QUANTITY: u64 = 120_000; // 12 * 10_000
const NONLEV_SEQ: u64 = 88;

// Full-length ids so ObjectID/Address round-trip to the exact same literal.
const MARKET_ID: &str = "0x1111111111111111111111111111111111111111111111111111111111111111";
const MANAGER_ID: &str = "0x2222222222222222222222222222222222222222222222222222222222222222";
const OWNER: &str = "0x3333333333333333333333333333333333333333333333333333333333333333";

fn u256(s: &str) -> U256 {
    U256::from_str(s).unwrap()
}

fn meta(checkpoint: i64, tx_index: i64, event_index: usize) -> PredictEventMeta {
    PredictEventMeta::for_test(
        "digest",
        "sender",
        checkpoint,
        tx_index,
        // Distinct-but-deterministic timestamp so updated_at_ms assertions are exact.
        1_000_000 + checkpoint,
        event_index,
        "0xpkg",
    )
}

// === Decoder ===

#[test]
fn decoder_recovers_every_leveraged_field() {
    assert_eq!(
        decode_order_id(u256(LEVERAGED_ID)),
        DecodedOrderId {
            quantity_lots: LEV_QLOTS,
            quantity: LEV_QUANTITY,
            floor_shares: LEV_FLOOR,
            opened_at_ms: LEV_OPENED,
            lower_boundary_index: LEV_LOWER,
            higher_boundary_index: LEV_HIGHER,
            sequence: LEV_SEQ,
        }
    );
}

#[test]
fn decoder_recovers_every_nonleveraged_field() {
    // floor = 0 exercises the complement encoding's identity case
    // (floor_shares_key == u64::MAX).
    assert_eq!(
        decode_order_id(u256(NONLEV_ID)),
        DecodedOrderId {
            quantity_lots: NONLEV_QLOTS,
            quantity: NONLEV_QUANTITY,
            floor_shares: NONLEV_FLOOR,
            opened_at_ms: NONLEV_OPENED,
            lower_boundary_index: NONLEV_LOWER,
            higher_boundary_index: NONLEV_HIGHER,
            sequence: NONLEV_SEQ,
        }
    );
}

#[test]
fn lot_size_matches_move_constant() {
    // packages/predict/sources/helper/constants.move: position_lot_size!() = 10_000
    assert_eq!(POSITION_LOT_SIZE, 10_000);
}

// === Event fixtures ===

fn minted_event() -> OrderMinted {
    OrderMinted {
        expiry_market_id: ObjectID::from_hex_literal(MARKET_ID).unwrap(),
        predict_manager_id: ObjectID::from_hex_literal(MANAGER_ID).unwrap(),
        order_id: u256(NONLEV_ID),
        position_root_id: u256(NONLEV_ID),
        owner: OWNER.parse().unwrap(),
        lower_tick: 3,
        higher_tick: 7,
        leverage: 1_000_000_000,
        entry_probability: 450_000_000,
        quantity: NONLEV_QUANTITY,
        net_premium: 54_000_000,
        trading_fee: 100_000,
        builder_fee: 20_000,
        penalty_fee: 0,
        builder_code_id: None,
    }
}

fn live_redeemed_event(replacement: Option<&str>) -> LiveOrderRedeemed {
    LiveOrderRedeemed {
        expiry_market_id: ObjectID::from_hex_literal(MARKET_ID).unwrap(),
        predict_manager_id: ObjectID::from_hex_literal(MANAGER_ID).unwrap(),
        order_id: u256(NONLEV_ID),
        position_root_id: u256(NONLEV_ID),
        owner: OWNER.parse().unwrap(),
        quantity_closed: 50_000,
        remaining_quantity: NONLEV_QUANTITY - 50_000,
        replacement_order_id: replacement.map(u256),
        redeem_amount: 20_000_000,
        trading_fee: 50_000,
        builder_fee: 0,
        penalty_fee: 0,
        builder_code_id: None,
    }
}

fn order_liquidated_event() -> OrderLiquidated {
    OrderLiquidated {
        expiry_market_id: ObjectID::from_hex_literal(MARKET_ID).unwrap(),
        order_id: u256(NONLEV_ID),
        quantity: NONLEV_QUANTITY,
        gross_value: 30_000_000,
        floor_amount: 28_000_000,
        liquidation_ltv: 900_000_000,
    }
}

fn liquidated_redeemed_event() -> LiquidatedOrderRedeemed {
    LiquidatedOrderRedeemed {
        expiry_market_id: ObjectID::from_hex_literal(MARKET_ID).unwrap(),
        predict_manager_id: ObjectID::from_hex_literal(MANAGER_ID).unwrap(),
        order_id: u256(NONLEV_ID),
        position_root_id: u256(NONLEV_ID),
        owner: OWNER.parse().unwrap(),
        quantity_closed: NONLEV_QUANTITY,
    }
}

// === map() ===

#[test]
fn map_minted_fills_entry_facts_and_decoded_terms() {
    let row = map_minted(&minted_event(), &meta(10, 2, 3));

    assert_eq!(row.order_id, NONLEV_ID);
    assert_eq!(row.expiry_market_id, MARKET_ID);
    assert_eq!(row.predict_manager_id.as_deref(), Some(MANAGER_ID));
    assert_eq!(row.position_root_id.as_deref(), Some(NONLEV_ID));
    assert_eq!(row.owner.as_deref(), Some(OWNER));
    assert_eq!(row.status, status::OPEN);
    assert_eq!(row.replacement_order_id, None);
    assert_eq!(row.opened_at_ms, NONLEV_OPENED as i64);
    assert_eq!(row.lower_boundary_index, NONLEV_LOWER as i64);
    assert_eq!(row.higher_boundary_index, NONLEV_HIGHER as i64);
    assert_eq!(row.floor_shares, BigDecimal::from(NONLEV_FLOOR));
    assert_eq!(row.quantity, BigDecimal::from(NONLEV_QUANTITY));
    assert_eq!(row.sequence, NONLEV_SEQ as i64);
    assert_eq!(row.leverage, Some(1_000_000_000));
    assert_eq!(row.entry_probability, Some(450_000_000));
    assert_eq!(row.net_premium, Some(BigDecimal::from(54_000_000u64)));
    assert_eq!(row.updated_at_ms, 1_000_010);
    assert_eq!((row.checkpoint, row.tx_index, row.event_index), (10, 2, 3));
}

#[test]
fn map_live_redeemed_partial_close_synthesizes_replacement_row() {
    let rows = map_live_redeemed(&live_redeemed_event(Some(LEVERAGED_ID)), &meta(20, 0, 1));
    assert_eq!(rows.len(), 2);

    let closed = &rows[0];
    assert_eq!(closed.order_id, NONLEV_ID);
    assert_eq!(closed.status, status::REPLACED);
    assert_eq!(closed.replacement_order_id.as_deref(), Some(LEVERAGED_ID));
    // Entry facts are never carried by redeem events.
    assert_eq!(closed.leverage, None);
    assert_eq!(closed.net_premium, None);

    let replacement = &rows[1];
    assert_eq!(replacement.order_id, LEVERAGED_ID);
    assert_eq!(replacement.status, status::OPEN);
    assert_eq!(replacement.replacement_order_id, None);
    assert_eq!(replacement.predict_manager_id.as_deref(), Some(MANAGER_ID));
    assert_eq!(replacement.position_root_id.as_deref(), Some(NONLEV_ID));
    assert_eq!(replacement.owner.as_deref(), Some(OWNER));
    // Contract terms come from the replacement's own packed id.
    assert_eq!(replacement.quantity, BigDecimal::from(LEV_QUANTITY));
    assert_eq!(replacement.floor_shares, BigDecimal::from(LEV_FLOOR));
    assert_eq!(replacement.opened_at_ms, LEV_OPENED as i64);
    assert_eq!(replacement.sequence, LEV_SEQ as i64);
    // Entry facts stay NULL on replacement rows (join position_root_id).
    assert_eq!(replacement.net_premium, None);
    assert_eq!(replacement.leverage, None);
    assert_eq!(
        (
            replacement.checkpoint,
            replacement.tx_index,
            replacement.event_index
        ),
        (20, 0, 1)
    );
}

#[test]
fn map_live_redeemed_full_close_yields_single_closed_row() {
    let rows = map_live_redeemed(&live_redeemed_event(None), &meta(20, 0, 1));
    assert_eq!(rows.len(), 1);
    assert_eq!(rows[0].status, status::CLOSED);
    assert_eq!(rows[0].replacement_order_id, None);
}

#[test]
fn map_order_liquidated_has_no_identity() {
    let row = map_order_liquidated(&order_liquidated_event(), &meta(30, 1, 0));
    assert_eq!(row.status, status::LIQUIDATED);
    assert_eq!(row.predict_manager_id, None);
    assert_eq!(row.position_root_id, None);
    assert_eq!(row.owner, None);
    assert_eq!(row.expiry_market_id, MARKET_ID);
    assert_eq!(row.quantity, BigDecimal::from(NONLEV_QUANTITY));
}

#[test]
fn map_settled_and_liquidated_redeemed_statuses() {
    let settled = map_settled_redeemed(
        &predict_indexer::models::SettledOrderRedeemed {
            expiry_market_id: ObjectID::from_hex_literal(MARKET_ID).unwrap(),
            predict_manager_id: ObjectID::from_hex_literal(MANAGER_ID).unwrap(),
            order_id: u256(NONLEV_ID),
            position_root_id: u256(NONLEV_ID),
            owner: OWNER.parse().unwrap(),
            quantity_closed: NONLEV_QUANTITY,
            settlement_price: 99_000_000_000_000,
            payout_amount: 120_000_000,
        },
        &meta(40, 0, 0),
    );
    assert_eq!(settled.status, status::SETTLED_REDEEMED);

    let liq_redeemed = map_liquidated_redeemed(&liquidated_redeemed_event(), &meta(41, 0, 0));
    assert_eq!(liq_redeemed.status, status::LIQUIDATED_REDEEMED);
    assert_eq!(liq_redeemed.owner.as_deref(), Some(OWNER));
}

// === fold ===

#[test]
fn fold_mint_and_partial_close_in_one_batch() {
    let mut values = vec![map_minted(&minted_event(), &meta(10, 2, 3))];
    values.extend(map_live_redeemed(
        &live_redeemed_event(Some(LEVERAGED_ID)),
        &meta(10, 2, 5),
    ));

    let mut folded = fold_rows(&values);
    folded.sort_by(|a, b| a.order_id.cmp(&b.order_id));
    assert_eq!(folded.len(), 2);

    // NONLEV_ID < LEVERAGED_ID as decimal strings of equal length.
    let replacement = &folded[1];
    assert_eq!(replacement.order_id, LEVERAGED_ID);
    assert_eq!(replacement.status, status::OPEN);

    // The old order keeps its mint entry facts and takes the close's status.
    let root = &folded[0];
    assert_eq!(root.order_id, NONLEV_ID);
    assert_eq!(root.status, status::REPLACED);
    assert_eq!(root.replacement_order_id.as_deref(), Some(LEVERAGED_ID));
    assert_eq!(root.net_premium, Some(BigDecimal::from(54_000_000u64)));
    assert_eq!(root.leverage, Some(1_000_000_000));
    assert_eq!(
        (root.checkpoint, root.tx_index, root.event_index),
        (10, 2, 5)
    );
}

#[test]
fn fold_is_order_independent_for_out_of_order_batches() {
    // OrderLiquidated (checkpoint 30) appears in the batch BEFORE the mint
    // (checkpoint 10): the fold must keep the liquidated status (later triple)
    // while still filling the mint's write-once entry facts.
    let values = vec![
        map_order_liquidated(&order_liquidated_event(), &meta(30, 1, 0)),
        map_minted(&minted_event(), &meta(10, 2, 3)),
    ];

    let folded = fold_rows(&values);
    assert_eq!(folded.len(), 1);
    let row = &folded[0];
    assert_eq!(row.status, status::LIQUIDATED);
    assert_eq!(row.predict_manager_id.as_deref(), Some(MANAGER_ID));
    assert_eq!(row.owner.as_deref(), Some(OWNER));
    assert_eq!(row.net_premium, Some(BigDecimal::from(54_000_000u64)));
    assert_eq!((row.checkpoint, row.tx_index, row.event_index), (30, 1, 0));
}

#[test]
fn fold_lifecycle_ends_liquidated_redeemed() {
    let values = vec![
        map_minted(&minted_event(), &meta(10, 2, 3)),
        map_order_liquidated(&order_liquidated_event(), &meta(30, 1, 0)),
        map_liquidated_redeemed(&liquidated_redeemed_event(), &meta(35, 0, 0)),
    ];

    let folded = fold_rows(&values);
    assert_eq!(folded.len(), 1);
    assert_eq!(folded[0].status, status::LIQUIDATED_REDEEMED);
    assert_eq!(folded[0].updated_at_ms, 1_000_035);
}

#[test]
fn fold_keys_by_market_and_order_id() {
    // Packed order ids are expiry-local (sequence/opened_at_ms), so the same
    // id in two markets must fold to two rows, never merge.
    const OTHER_MARKET_ID: &str =
        "0x4444444444444444444444444444444444444444444444444444444444444444";
    let mut other_market_mint = minted_event();
    other_market_mint.expiry_market_id = ObjectID::from_hex_literal(OTHER_MARKET_ID).unwrap();

    let values = vec![
        map_minted(&minted_event(), &meta(10, 2, 3)),
        map_minted(&other_market_mint, &meta(10, 2, 7)),
    ];

    let mut folded = fold_rows(&values);
    folded.sort_by(|a, b| a.expiry_market_id.cmp(&b.expiry_market_id));
    assert_eq!(folded.len(), 2);
    assert_eq!(folded[0].expiry_market_id, MARKET_ID);
    assert_eq!(folded[1].expiry_market_id, OTHER_MARKET_ID);
    assert_eq!(folded[0].order_id, NONLEV_ID);
    assert_eq!(folded[1].order_id, NONLEV_ID);
}

#[test]
fn fold_replay_of_identical_batch_is_idempotent() {
    // Reprocessing feeds the same events again: folding values ++ values must
    // equal folding values once (the SQL upsert's `>=` guard mirrors this).
    let mut values = vec![map_minted(&minted_event(), &meta(10, 2, 3))];
    values.extend(map_live_redeemed(
        &live_redeemed_event(Some(LEVERAGED_ID)),
        &meta(10, 2, 5),
    ));

    let once = fold_rows(&values);
    let mut replayed = values.clone();
    replayed.extend(values.clone());
    let twice = fold_rows(&replayed);

    let sort = |mut v: Vec<predict_schema::models::OrderState>| {
        v.sort_by(|a, b| a.order_id.cmp(&b.order_id));
        v
    };
    assert_eq!(sort(once), sort(twice));
}

// === lp_request_state fold/merge ===
//
// The async-LP maintained table is keyed by (pool_vault_id, is_supply,
// request_index); the request carries identity + amount, the fill carries the
// realized dusdc/shares, and both queues use a per-(vault,is_supply) index
// counter so the same index can appear in both queues. These pin the in-memory
// fold that mirrors the SQL upsert (COALESCE write-once, LEAST opened_at_ms,
// LWW status/triple).

use predict_indexer::handlers::lp_request_state_handler::{
    fold_rows as lp_fold_rows, map_supply_filled, map_supply_requested, map_withdraw_requested,
    status as lp_status,
};
use predict_indexer::models::{SupplyFilled, SupplyRequested, WithdrawRequested};
use predict_schema::models::LpRequestState;

const REQUEST_INDEX: u64 = 4;

fn supply_requested_event() -> SupplyRequested {
    SupplyRequested {
        pool_vault_id: ObjectID::from_hex_literal(MARKET_ID).unwrap(),
        predict_manager_id: ObjectID::from_hex_literal(MANAGER_ID).unwrap(),
        recipient: OWNER.parse().unwrap(),
        index: REQUEST_INDEX,
        amount: 100_000_000,
    }
}

fn supply_filled_event() -> SupplyFilled {
    SupplyFilled {
        pool_vault_id: ObjectID::from_hex_literal(MARKET_ID).unwrap(),
        predict_manager_id: ObjectID::from_hex_literal(MANAGER_ID).unwrap(),
        recipient: OWNER.parse().unwrap(),
        index: REQUEST_INDEX,
        dusdc_amount: 100_000_000,
        shares_minted: 99_000_000,
    }
}

#[test]
fn lp_map_supply_requested_carries_identity_and_amount() {
    // pool_vault_id reuses MARKET_ID's 0x… literal so the ObjectID round-trips.
    let row = map_supply_requested(&supply_requested_event(), &meta(10, 2, 3));
    assert_eq!(row.pool_vault_id, MARKET_ID);
    assert!(row.is_supply);
    assert_eq!(row.request_index, REQUEST_INDEX as i64);
    assert_eq!(row.predict_manager_id.as_deref(), Some(MANAGER_ID));
    assert_eq!(row.recipient.as_deref(), Some(OWNER));
    assert_eq!(row.requested_amount, Some(BigDecimal::from(100_000_000u64)));
    assert_eq!(row.status, lp_status::OPEN);
    assert_eq!(row.filled_dusdc, None);
    assert_eq!(row.filled_shares, None);
    assert_eq!(row.opened_at_ms, 1_000_010);
    assert_eq!(row.updated_at_ms, 1_000_010);
    assert_eq!((row.checkpoint, row.tx_index, row.event_index), (10, 2, 3));
}

#[test]
fn lp_fold_request_then_fill_keeps_amount_and_fills_status() {
    // Request (older) then fill (newer): write-once amount/identity survive, the
    // fill's status + realized dusdc/shares win, opened_at_ms stays the request.
    let values = vec![
        map_supply_requested(&supply_requested_event(), &meta(10, 2, 3)),
        map_supply_filled(&supply_filled_event(), &meta(20, 0, 1)),
    ];
    let folded = lp_fold_rows(&values);
    assert_eq!(folded.len(), 1);
    let row = &folded[0];
    assert_eq!(row.status, lp_status::FILLED);
    assert_eq!(row.requested_amount, Some(BigDecimal::from(100_000_000u64)));
    assert_eq!(row.filled_dusdc, Some(BigDecimal::from(100_000_000u64)));
    assert_eq!(row.filled_shares, Some(BigDecimal::from(99_000_000u64)));
    assert_eq!(row.opened_at_ms, 1_000_010);
    assert_eq!(row.updated_at_ms, 1_000_020);
    assert_eq!((row.checkpoint, row.tx_index, row.event_index), (20, 0, 1));
}

#[test]
fn lp_fold_out_of_order_fill_before_request_backfills_identity() {
    // Reprocess / out-of-order: the FILL (later triple) appears before the
    // REQUEST (earlier triple). The fill carries manager/recipient so identity
    // is backfilled, the requested amount comes from the request, status stays
    // filled (the later triple), and opened_at_ms = LEAST = the request's ts.
    let values = vec![
        map_supply_filled(&supply_filled_event(), &meta(20, 0, 1)),
        map_supply_requested(&supply_requested_event(), &meta(10, 2, 3)),
    ];
    let folded = lp_fold_rows(&values);
    assert_eq!(folded.len(), 1);
    let row = &folded[0];
    assert_eq!(row.predict_manager_id.as_deref(), Some(MANAGER_ID));
    assert_eq!(row.recipient.as_deref(), Some(OWNER));
    assert_eq!(row.requested_amount, Some(BigDecimal::from(100_000_000u64)));
    assert_eq!(row.status, lp_status::FILLED);
    assert_eq!(row.opened_at_ms, 1_000_010);
    assert_eq!((row.checkpoint, row.tx_index, row.event_index), (20, 0, 1));
}

#[test]
fn lp_fold_keys_by_vault_is_supply_and_index() {
    // The same index in the supply queue and the withdraw queue are distinct
    // handles (is_supply is part of the key), so they fold to two rows.
    let mut withdraw = supply_requested_event();
    withdraw.index = REQUEST_INDEX;
    let withdraw = WithdrawRequested {
        pool_vault_id: withdraw.pool_vault_id,
        predict_manager_id: withdraw.predict_manager_id,
        recipient: withdraw.recipient,
        index: withdraw.index,
        amount: withdraw.amount,
    };

    let values = vec![
        map_supply_requested(&supply_requested_event(), &meta(10, 2, 3)),
        map_withdraw_requested(&withdraw, &meta(10, 2, 4)),
    ];
    let mut folded = lp_fold_rows(&values);
    folded.sort_by_key(|r| r.is_supply);
    assert_eq!(folded.len(), 2);
    assert!(!folded[0].is_supply);
    assert!(folded[1].is_supply);
    assert_eq!(folded[0].request_index, REQUEST_INDEX as i64);
    assert_eq!(folded[1].request_index, REQUEST_INDEX as i64);
}

#[test]
fn lp_fold_replay_of_identical_batch_is_idempotent() {
    let values = vec![
        map_supply_requested(&supply_requested_event(), &meta(10, 2, 3)),
        map_supply_filled(&supply_filled_event(), &meta(20, 0, 1)),
    ];
    let once = lp_fold_rows(&values);
    let mut replayed = values.clone();
    replayed.extend(values.clone());
    let twice = lp_fold_rows(&replayed);

    let sort = |mut v: Vec<LpRequestState>| {
        v.sort_by(|a, b| (a.is_supply, a.request_index).cmp(&(b.is_supply, b.request_index)));
        v
    };
    assert_eq!(sort(once), sort(twice));
}

// === commit() against Postgres (TempDb) ===
//
// The fold/merge tests above pin the Rust half of the pipeline; these execute
// the actual multi-row UPSERT SQL (20 positional binds per row, COALESCE
// write-once columns, `>=`-guarded LWW CASE columns) against a real Postgres
// so a positional-bind swap or an inverted comparison cannot pass CI.
//
// Expected rows are hand-built literals derived from the documented upsert
// semantics (module doc of `order_state_handler`), never read back through
// the code under test.

use predict_indexer::handlers::order_state_handler::OrderStateHandler;
use predict_schema::models::OrderState;
use predict_schema::schema::order_state;
use sui_indexer_alt_framework::postgres::handler::Handler;
use sui_pg_db::temp::TempDb;
use sui_pg_db::{Db, DbArgs};

/// Fresh migrated database. The `TempDb` must stay in scope for the whole
/// test, otherwise the postgres process is torn down.
async fn temp_store() -> (TempDb, Db) {
    let temp_db = TempDb::new().expect("postgres binaries (initdb/postgres) must be on PATH");
    let db = Db::for_write(temp_db.database().url().clone(), DbArgs::default())
        .await
        .unwrap();
    db.run_migrations(Some(&predict_schema::MIGRATIONS))
        .await
        .unwrap();
    (temp_db, db)
}

/// A fully-populated `order_state` row with every optional column NULL and
/// fixed decoded-terms filler; tests override the fields they exercise.
fn db_row(
    market: &str,
    order_id: &str,
    st: &str,
    (checkpoint, tx_index, event_index): (i64, i64, i64),
    updated_at_ms: i64,
) -> OrderState {
    OrderState {
        expiry_market_id: market.to_string(),
        order_id: order_id.to_string(),
        predict_manager_id: None,
        position_root_id: None,
        owner: None,
        status: st.to_string(),
        replacement_order_id: None,
        opened_at_ms: NONLEV_OPENED as i64,
        lower_boundary_index: NONLEV_LOWER as i64,
        higher_boundary_index: NONLEV_HIGHER as i64,
        floor_shares: BigDecimal::from(NONLEV_FLOOR),
        quantity: BigDecimal::from(NONLEV_QUANTITY),
        sequence: NONLEV_SEQ as i64,
        leverage: None,
        entry_probability: None,
        net_premium: None,
        updated_at_ms,
        checkpoint,
        tx_index,
        event_index,
    }
}

/// Every `order_state` row, ordered by `(expiry_market_id, order_id)` so
/// assertions are deterministic.
async fn load_all(db: &Db) -> Vec<OrderState> {
    use diesel::{ExpressionMethods, QueryDsl, SelectableHelper};
    use diesel_async::RunQueryDsl;

    let mut conn = db.connect().await.unwrap();
    order_state::table
        .order_by((
            order_state::expiry_market_id.asc(),
            order_state::order_id.asc(),
        ))
        .select(OrderState::as_select())
        .load(&mut conn)
        .await
        .unwrap()
}

async fn commit(db: &Db, values: &[OrderState]) -> usize {
    let mut conn = db.connect().await.unwrap();
    OrderStateHandler::commit(values, &mut conn).await.unwrap()
}

#[tokio::test]
async fn upsert_reprocess_of_identical_batch_is_unchanged() {
    let (_temp_db, db) = temp_store().await;

    // One batch holding a mint (entry facts) and a later close for order-1
    // plus an unrelated open order-2 — the shape an at-least-once redelivery
    // replays verbatim.
    let mut mint = db_row(MARKET_ID, "order-1", status::OPEN, (10, 2, 3), 1_000_010);
    mint.owner = Some(OWNER.to_string());
    mint.net_premium = Some(BigDecimal::from(54_000_000u64));
    let close = db_row(MARKET_ID, "order-1", status::CLOSED, (12, 0, 1), 1_000_012);
    let other = db_row(MARKET_ID, "order-2", status::OPEN, (11, 1, 0), 1_000_011);
    let batch = vec![mint, close, other];

    // order-1 keeps the mint's write-once facts and takes the close's
    // status/triple; order-2 lands as-is.
    let mut expected_order1 = db_row(MARKET_ID, "order-1", status::CLOSED, (12, 0, 1), 1_000_012);
    expected_order1.owner = Some(OWNER.to_string());
    expected_order1.net_premium = Some(BigDecimal::from(54_000_000u64));
    let expected = vec![
        expected_order1,
        db_row(MARKET_ID, "order-2", status::OPEN, (11, 1, 0), 1_000_011),
    ];

    commit(&db, &batch).await;
    assert_eq!(load_all(&db).await, expected);

    // At-least-once redelivery: the identical batch again must change nothing.
    commit(&db, &batch).await;
    assert_eq!(load_all(&db).await, expected);
}

#[tokio::test]
async fn upsert_keeps_newest_triple_and_backfills_write_once_columns() {
    let (_temp_db, db) = temp_store().await;

    // Current state written at triple (20, 1, 1).
    let mut current = db_row(MARKET_ID, "order-1", status::OPEN, (20, 1, 1), 2_000_020);
    current.owner = Some(OWNER.to_string());
    commit(&db, &[current]).await;

    // A stale event with an OLDER triple (10, 0, 0) must not regress the
    // mutable columns (status/updated_at_ms/triple), but its write-once
    // payload (replacement_order_id, NULL so far) is still kept via COALESCE.
    let mut stale = db_row(MARKET_ID, "order-1", status::CLOSED, (10, 0, 0), 1_000_010);
    stale.replacement_order_id = Some("order-9".to_string());
    commit(&db, &[stale]).await;

    let mut expected = db_row(MARKET_ID, "order-1", status::OPEN, (20, 1, 1), 2_000_020);
    expected.owner = Some(OWNER.to_string());
    expected.replacement_order_id = Some("order-9".to_string());
    assert_eq!(load_all(&db).await, vec![expected.clone()]);

    // A NEWER triple (30, 0, 0) wins the mutable columns; existing write-once
    // columns are kept (COALESCE prefers the stored non-null value).
    let newer = db_row(
        MARKET_ID,
        "order-1",
        status::LIQUIDATED,
        (30, 0, 0),
        3_000_030,
    );
    commit(&db, &[newer]).await;

    expected.status = status::LIQUIDATED.to_string();
    expected.updated_at_ms = 3_000_030;
    (expected.checkpoint, expected.tx_index, expected.event_index) = (30, 0, 0);
    assert_eq!(load_all(&db).await, vec![expected]);
}

#[tokio::test]
async fn upsert_multi_row_batch_lands_every_conflict_key() {
    const OTHER_MARKET_ID: &str =
        "0x4444444444444444444444444444444444444444444444444444444444444444";
    let (_temp_db, db) = temp_store().await;

    // Three distinct conflict keys in ONE statement (one multi-row VALUES
    // list), including the same order id in two markets — the conflict key is
    // (expiry_market_id, order_id), so these are distinct rows.
    let batch = vec![
        db_row(MARKET_ID, "order-a", status::OPEN, (10, 0, 0), 1_000_010),
        db_row(
            MARKET_ID,
            "order-b",
            status::LIQUIDATED,
            (10, 0, 1),
            1_000_010,
        ),
        db_row(
            OTHER_MARKET_ID,
            "order-a",
            status::OPEN,
            (10, 0, 2),
            1_000_010,
        ),
    ];

    let affected = commit(&db, &batch).await;
    assert_eq!(affected, 3);

    // load_all orders by (expiry_market_id, order_id): 0x1111... < 0x4444...
    let expected = vec![
        db_row(MARKET_ID, "order-a", status::OPEN, (10, 0, 0), 1_000_010),
        db_row(
            MARKET_ID,
            "order-b",
            status::LIQUIDATED,
            (10, 0, 1),
            1_000_010,
        ),
        db_row(
            OTHER_MARKET_ID,
            "order-a",
            status::OPEN,
            (10, 0, 2),
            1_000_010,
        ),
    ];
    assert_eq!(load_all(&db).await, expected);
}
