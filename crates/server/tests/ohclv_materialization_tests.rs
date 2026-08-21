use diesel::sql_types::{BigInt, Double, Integer};
use diesel::QueryableByName;
use diesel_async::RunQueryDsl;
use sui_pg_db::temp::TempDb;
use sui_pg_db::{Db, DbArgs};
use url::Url;

const POOL_ID: &str = "pool-1";
// 2023-11-05 00:00:00 UTC crosses the America/Detroit daylight-saving transition.
const DAY_START_MS: i64 = 1_699_142_400_000;
const MINUTE_MS: i64 = 60_000;
const DAY_MS: i64 = 86_400_000;

#[derive(Debug, PartialEq, QueryableByName)]
struct CandleAggregate {
    #[diesel(sql_type = Double)]
    open: f64,
    #[diesel(sql_type = Double)]
    high: f64,
    #[diesel(sql_type = Double)]
    low: f64,
    #[diesel(sql_type = Double)]
    close: f64,
    #[diesel(sql_type = Double)]
    base_volume: f64,
    #[diesel(sql_type = Double)]
    quote_volume: f64,
    #[diesel(sql_type = Integer)]
    trade_count: i32,
    #[diesel(sql_type = BigInt)]
    first_trade_timestamp: i64,
    #[diesel(sql_type = BigInt)]
    last_trade_timestamp: i64,
}

async fn setup() -> (TempDb, Db) {
    let temp_db = TempDb::new().expect("postgres binaries must be on PATH");
    let url: Url = temp_db.database().url().clone();
    let db = Db::for_write(url, DbArgs::default()).await.unwrap();
    db.run_migrations(Some(&deepbook_schema::MIGRATIONS))
        .await
        .unwrap();

    let mut conn = db.connect().await.unwrap();
    diesel::sql_query(
        "INSERT INTO pools (
            pool_id, pool_name,
            base_asset_id, base_asset_decimals, base_asset_symbol, base_asset_name,
            quote_asset_id, quote_asset_decimals, quote_asset_symbol, quote_asset_name,
            min_size, lot_size, tick_size
        ) VALUES (
            'pool-1', 'BASE_USDC',
            'base-coin', 9, 'BASE', 'Base Coin',
            'quote-coin', 9, 'USDC', 'USD Coin',
            1, 1, 1
        )",
    )
    .execute(&mut conn)
    .await
    .unwrap();
    drop(conn);

    (temp_db, db)
}

async fn insert_fill(db: &Db, tag: &str, timestamp_ms: i64, price: i64, volume: i64) {
    let mut conn = db.connect().await.unwrap();
    diesel::sql_query(format!(
        "INSERT INTO order_fills (
            event_digest, digest, sender, checkpoint, checkpoint_timestamp_ms, package,
            pool_id, maker_order_id, taker_order_id,
            maker_client_order_id, taker_client_order_id,
            price, taker_fee, taker_fee_is_deep, maker_fee, maker_fee_is_deep,
            taker_is_bid, base_quantity, quote_quantity,
            maker_balance_manager_id, taker_balance_manager_id, onchain_timestamp
        ) VALUES (
            'fill-{tag}', 'tx-{tag}', 'sender', 1, {timestamp_ms}, 'package',
            '{POOL_ID}', 'maker-order-{tag}', 'taker-order-{tag}',
            1, 2,
            {price}, 0, false, 0, false,
            false, {base_quantity}, {quote_quantity},
            'maker-manager', 'taker-manager', {timestamp_ms}
        )",
        price = price * 1_000_000_000,
        base_quantity = volume * 1_000_000_000,
        quote_quantity = price * volume * 1_000_000_000,
    ))
    .execute(&mut conn)
    .await
    .unwrap();
}

async fn call_materializer(db: &Db, procedure: &str, start_ms: i64, end_ms: i64) {
    let mut conn = db.connect().await.unwrap();
    diesel::sql_query("SET TIME ZONE 'America/Detroit'")
        .execute(&mut conn)
        .await
        .unwrap();
    diesel::sql_query(format!("CALL {procedure}({start_ms}, {end_ms})"))
        .execute(&mut conn)
        .await
        .unwrap();
}

async fn corrupt_candle(db: &Db, table: &str, bucket_predicate: &str) {
    let mut conn = db.connect().await.unwrap();
    diesel::sql_query(format!(
        "UPDATE {table}
         SET open = 99, high = 99, low = 1, close = 99,
             base_volume = 99, quote_volume = 99, trade_count = 99,
             first_trade_timestamp = 1, last_trade_timestamp = 2
         WHERE pool_id = '{POOL_ID}' AND {bucket_predicate}"
    ))
    .execute(&mut conn)
    .await
    .unwrap();
}

async fn store_newer_candle(
    db: &Db,
    table: &str,
    bucket_predicate: &str,
    first_ms: i64,
    last_ms: i64,
) {
    let mut conn = db.connect().await.unwrap();
    diesel::sql_query(format!(
        "UPDATE {table}
         SET open = 10, high = 20, low = 10, close = 20,
             base_volume = 12, quote_volume = 196, trade_count = 3,
             first_trade_timestamp = {first_ms}, last_trade_timestamp = {last_ms}
         WHERE pool_id = '{POOL_ID}' AND {bucket_predicate}"
    ))
    .execute(&mut conn)
    .await
    .unwrap();
}

async fn load_candle(db: &Db, table: &str, bucket_predicate: &str) -> CandleAggregate {
    let mut conn = db.connect().await.unwrap();
    diesel::sql_query(format!(
        "SELECT
            open::DOUBLE PRECISION AS open,
            high::DOUBLE PRECISION AS high,
            low::DOUBLE PRECISION AS low,
            close::DOUBLE PRECISION AS close,
            base_volume::DOUBLE PRECISION AS base_volume,
            quote_volume::DOUBLE PRECISION AS quote_volume,
            trade_count,
            first_trade_timestamp,
            last_trade_timestamp
         FROM {table}
         WHERE pool_id = '{POOL_ID}' AND {bucket_predicate}"
    ))
    .get_result(&mut conn)
    .await
    .unwrap()
}

async fn load_total_trade_count(db: &Db, table: &str) -> i64 {
    #[derive(QueryableByName)]
    struct Count {
        #[diesel(sql_type = BigInt)]
        count: i64,
    }

    let mut conn = db.connect().await.unwrap();
    diesel::sql_query(format!(
        "SELECT SUM(trade_count)::BIGINT AS count FROM {table} WHERE pool_id = '{POOL_ID}'"
    ))
    .get_result::<Count>(&mut conn)
    .await
    .unwrap()
    .count
}

async fn load_candle_count(db: &Db, table: &str) -> i64 {
    #[derive(QueryableByName)]
    struct Count {
        #[diesel(sql_type = BigInt)]
        count: i64,
    }

    let mut conn = db.connect().await.unwrap();
    diesel::sql_query(format!(
        "SELECT COUNT(*) AS count FROM {table} WHERE pool_id = '{POOL_ID}'"
    ))
    .get_result::<Count>(&mut conn)
    .await
    .unwrap()
    .count
}

fn expected(first_ms: i64, last_ms: i64) -> CandleAggregate {
    CandleAggregate {
        open: 10.0,
        high: 12.0,
        low: 10.0,
        close: 12.0,
        base_volume: 5.0,
        quote_volume: 56.0,
        trade_count: 2,
        first_trade_timestamp: first_ms,
        last_trade_timestamp: last_ms,
    }
}

fn expected_newer(first_ms: i64, last_ms: i64) -> CandleAggregate {
    CandleAggregate {
        open: 10.0,
        high: 20.0,
        low: 10.0,
        close: 20.0,
        base_volume: 12.0,
        quote_volume: 196.0,
        trade_count: 3,
        first_trade_timestamp: first_ms,
        last_trade_timestamp: last_ms,
    }
}

#[tokio::test]
async fn partial_minute_refresh_recomputes_the_complete_bucket() {
    let (_temp_db, db) = setup().await;
    let first_ms = DAY_START_MS + 5_000;
    let last_ms = DAY_START_MS + 50_000;
    let next_minute_ms = DAY_START_MS + MINUTE_MS;
    insert_fill(&db, "minute-first", first_ms, 10, 2).await;
    insert_fill(&db, "minute-last", last_ms, 12, 3).await;
    insert_fill(&db, "minute-boundary", next_minute_ms, 20, 7).await;

    call_materializer(&db, "update_ohclv_1m", DAY_START_MS, next_minute_ms - 1).await;
    let bucket_predicate = format!(
        "bucket_time = date_trunc('minute', to_timestamp({DAY_START_MS}::DOUBLE PRECISION / 1000) AT TIME ZONE 'UTC')"
    );
    corrupt_candle(&db, "ohclv_1m", &bucket_predicate).await;
    call_materializer(&db, "update_ohclv_1m", last_ms, last_ms).await;
    call_materializer(&db, "update_ohclv_1m", last_ms, last_ms).await;

    let first_bucket = load_candle(&db, "ohclv_1m", &bucket_predicate).await;
    assert_eq!(first_bucket, expected(first_ms, last_ms));
    assert_eq!(load_candle_count(&db, "ohclv_1m").await, 1);

    call_materializer(&db, "update_ohclv_1m", next_minute_ms, next_minute_ms).await;
    assert_eq!(load_total_trade_count(&db, "ohclv_1m").await, 3);
}

#[tokio::test]
async fn partial_daily_refresh_recomputes_the_complete_bucket() {
    let (_temp_db, db) = setup().await;
    let first_ms = DAY_START_MS + 5 * MINUTE_MS;
    let last_ms = DAY_START_MS + 23 * 60 * MINUTE_MS;
    let next_day_ms = DAY_START_MS + DAY_MS;
    insert_fill(&db, "day-first", first_ms, 10, 2).await;
    insert_fill(&db, "day-last", last_ms, 12, 3).await;
    insert_fill(&db, "day-boundary", next_day_ms, 20, 7).await;

    call_materializer(&db, "update_ohclv_1d", DAY_START_MS, next_day_ms - 1).await;
    let bucket_predicate = format!(
        "bucket_time = (to_timestamp({DAY_START_MS}::DOUBLE PRECISION / 1000) AT TIME ZONE 'UTC')::DATE"
    );
    corrupt_candle(&db, "ohclv_1d", &bucket_predicate).await;
    call_materializer(&db, "update_ohclv_1d", last_ms, last_ms).await;
    call_materializer(&db, "update_ohclv_1d", last_ms, last_ms).await;

    let first_bucket = load_candle(&db, "ohclv_1d", &bucket_predicate).await;
    assert_eq!(first_bucket, expected(first_ms, last_ms));
    assert_eq!(load_candle_count(&db, "ohclv_1d").await, 1);

    call_materializer(&db, "update_ohclv_1d", next_day_ms, next_day_ms).await;
    assert_eq!(load_total_trade_count(&db, "ohclv_1d").await, 3);
}

#[tokio::test]
async fn stale_refresh_does_not_replace_a_newer_materialization() {
    let (_temp_db, db) = setup().await;
    let first_ms = DAY_START_MS + 5_000;
    let snapshot_last_ms = DAY_START_MS + 50_000;
    let stored_last_ms = DAY_START_MS + 55_000;
    insert_fill(&db, "stale-first", first_ms, 10, 2).await;
    insert_fill(&db, "stale-last", snapshot_last_ms, 12, 3).await;

    let minute_predicate = format!(
        "bucket_time = date_trunc('minute', to_timestamp({DAY_START_MS}::DOUBLE PRECISION / 1000) AT TIME ZONE 'UTC')"
    );
    let daily_predicate = format!(
        "bucket_time = (to_timestamp({DAY_START_MS}::DOUBLE PRECISION / 1000) AT TIME ZONE 'UTC')::DATE"
    );
    call_materializer(&db, "update_ohclv_1m", first_ms, snapshot_last_ms).await;
    call_materializer(&db, "update_ohclv_1d", first_ms, snapshot_last_ms).await;

    // Represents a concurrent refresh that observed a later fill than this raw-fill snapshot.
    store_newer_candle(&db, "ohclv_1m", &minute_predicate, first_ms, stored_last_ms).await;
    store_newer_candle(
        &db,
        "ohclv_1d",
        &daily_predicate,
        first_ms,
        snapshot_last_ms,
    )
    .await;

    call_materializer(&db, "update_ohclv_1m", first_ms, snapshot_last_ms).await;
    call_materializer(&db, "update_ohclv_1d", first_ms, snapshot_last_ms).await;

    let expected = expected_newer(first_ms, stored_last_ms);
    assert_eq!(
        load_candle(&db, "ohclv_1m", &minute_predicate).await,
        expected
    );
    assert_eq!(
        load_candle(&db, "ohclv_1d", &daily_predicate).await,
        expected_newer(first_ms, snapshot_last_ms)
    );
}
