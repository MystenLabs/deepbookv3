use deepbook_server::live_ohclv::{Candle, LiveFill, LiveOhclvCache};

const MINUTE_MS: i64 = 60_000;

fn minute(minute_of_day: i64) -> i64 {
    minute_of_day * MINUTE_MS
}

fn candle(
    timestamp_ms: i64,
    open: f64,
    high: f64,
    low: f64,
    close: f64,
    base_volume: f64,
) -> Candle {
    Candle {
        timestamp_ms,
        open,
        high,
        low,
        close,
        base_volume,
        first_trade_timestamp_ms: None,
        last_trade_timestamp_ms: None,
    }
}

fn stored_candle(
    timestamp_ms: i64,
    open: f64,
    high: f64,
    low: f64,
    close: f64,
    base_volume: f64,
    last_trade_timestamp_ms: i64,
) -> Candle {
    Candle {
        timestamp_ms,
        open,
        high,
        low,
        close,
        base_volume,
        first_trade_timestamp_ms: Some(timestamp_ms),
        last_trade_timestamp_ms: Some(last_trade_timestamp_ms),
    }
}

fn fill(
    event_digest: &str,
    pool_id: &str,
    timestamp_ms: i64,
    price: f64,
    base_volume: f64,
) -> LiveFill {
    LiveFill {
        event_digest: event_digest.to_string(),
        pool_id: pool_id.to_string(),
        checkpoint_timestamp_ms: timestamp_ms,
        price,
        base_volume,
    }
}

#[test]
fn overlay_five_minute_bucket_with_unmaterialized_fills() {
    let cache = LiveOhclvCache::new(100);
    let bucket_1230 = minute(12 * 60 + 30);
    let bucket_1232 = minute(12 * 60 + 32);
    let pool_id = "pool-1";

    cache.insert_fills(vec![
        // Already covered by the materialized candle's last trade timestamp.
        fill(
            "already-materialized",
            pool_id,
            bucket_1232 + 1_000,
            120.0,
            99.0,
        ),
        fill("live-a", pool_id, bucket_1232 + 2_000, 110.0, 3.0),
        fill("live-b", pool_id, bucket_1232 + 4_000, 108.0, 2.0),
    ]);

    let stored = vec![stored_candle(
        bucket_1230,
        100.0,
        105.0,
        95.0,
        102.0,
        10.0,
        bucket_1232 + 1_000,
    )];
    let overlaid =
        cache.overlay_candles("5m", pool_id, bucket_1230, bucket_1232 + 5_000, 10, stored);

    assert_eq!(overlaid.len(), 1);
    assert_eq!(
        overlaid[0],
        stored_candle(
            bucket_1230,
            100.0,
            110.0,
            95.0,
            108.0,
            15.0,
            bucket_1232 + 1_000
        )
    );
}

#[test]
fn overlay_creates_current_minute_when_stored_bucket_is_missing() {
    let cache = LiveOhclvCache::new(100);
    let bucket_1232 = minute(12 * 60 + 32);
    let pool_id = "pool-1";

    cache.insert_fills(vec![
        fill("live-a", pool_id, bucket_1232 + 2_000, 110.0, 3.0),
        fill("live-b", pool_id, bucket_1232 + 4_000, 108.0, 2.0),
    ]);

    let overlaid = cache.overlay_candles(
        "1m",
        pool_id,
        bucket_1232,
        bucket_1232 + 5_000,
        10,
        Vec::new(),
    );

    assert_eq!(
        overlaid,
        vec![candle(bucket_1232, 110.0, 110.0, 108.0, 108.0, 5.0)]
    );
}

#[test]
fn overlay_filters_by_request_end_time() {
    let cache = LiveOhclvCache::new(100);
    let bucket_1232 = minute(12 * 60 + 32);
    let pool_id = "pool-1";

    cache.insert_fills(vec![
        fill("included", pool_id, bucket_1232 + 2_000, 110.0, 3.0),
        fill("excluded", pool_id, bucket_1232 + 6_000, 120.0, 7.0),
    ]);

    let overlaid = cache.overlay_candles(
        "1m",
        pool_id,
        bucket_1232,
        bucket_1232 + 5_000,
        10,
        Vec::new(),
    );

    assert_eq!(
        overlaid,
        vec![candle(bucket_1232, 110.0, 110.0, 110.0, 110.0, 3.0)]
    );
}

#[test]
fn overlay_does_not_create_bucket_before_requested_start() {
    let cache = LiveOhclvCache::new(100);
    let bucket_1232 = minute(12 * 60 + 32);
    let pool_id = "pool-1";

    cache.insert_fills(vec![fill(
        "mid-bucket",
        pool_id,
        bucket_1232 + 20_000,
        110.0,
        3.0,
    )]);

    // The DB query filters by bucket_time >= start_time. The fill timestamp is
    // inside the requested range, but its 1m bucket starts before start_time.
    let overlaid = cache.overlay_candles(
        "1m",
        pool_id,
        bucket_1232 + 10_000,
        bucket_1232 + 50_000,
        10,
        Vec::new(),
    );

    assert_eq!(overlaid, Vec::<Candle>::new());
}

#[test]
fn overlay_uses_stored_latest_trade_timestamp_as_cutoff() {
    let cache = LiveOhclvCache::new(100);
    let bucket_1230 = minute(12 * 60 + 30);
    let bucket_1231 = minute(12 * 60 + 31);
    let pool_id = "pool-1";

    cache.insert_fills(vec![fill(
        "out-of-order-minute",
        pool_id,
        bucket_1230 + 20_000,
        110.0,
        3.0,
    )]);

    let overlaid = cache.overlay_candles(
        "5m",
        pool_id,
        bucket_1230,
        bucket_1230 + 5 * MINUTE_MS - 1,
        10,
        vec![stored_candle(
            bucket_1230,
            100.0,
            105.0,
            95.0,
            102.0,
            10.0,
            bucket_1231 + 30_000,
        )],
    );

    assert_eq!(
        overlaid,
        vec![stored_candle(
            bucket_1230,
            100.0,
            105.0,
            95.0,
            102.0,
            10.0,
            bucket_1231 + 30_000,
        )]
    );
}

#[test]
fn overlay_skips_daily_and_weekly_intervals() {
    let cache = LiveOhclvCache::new(100);
    let bucket_1232 = minute(12 * 60 + 32);
    let pool_id = "pool-1";
    let stored = vec![candle(0, 100.0, 105.0, 95.0, 102.0, 10.0)];

    cache.insert_fills(vec![fill(
        "live-a",
        pool_id,
        bucket_1232 + 2_000,
        110.0,
        3.0,
    )]);

    assert_eq!(
        cache.overlay_candles("1d", pool_id, 0, bucket_1232 + 5_000, 10, stored.clone()),
        stored
    );
    assert_eq!(
        cache.overlay_candles("1w", pool_id, 0, bucket_1232 + 5_000, 10, stored.clone()),
        stored
    );
}

#[test]
fn overlay_skips_fills_covered_by_served_candle_watermark() {
    let cache = LiveOhclvCache::new(100);
    let bucket_1232 = minute(12 * 60 + 32);
    let pool_id = "pool-1";

    cache.insert_fills(vec![fill(
        "cached-but-materialized",
        pool_id,
        bucket_1232 + 2_000,
        110.0,
        3.0,
    )]);

    let overlaid = cache.overlay_candles(
        "1m",
        pool_id,
        bucket_1232,
        bucket_1232 + 5_000,
        10,
        vec![stored_candle(
            bucket_1232,
            100.0,
            105.0,
            95.0,
            102.0,
            10.0,
            bucket_1232 + 2_000,
        )],
    );

    assert_eq!(
        overlaid,
        vec![stored_candle(
            bucket_1232,
            100.0,
            105.0,
            95.0,
            102.0,
            10.0,
            bucket_1232 + 2_000,
        )]
    );
}

#[test]
fn cache_respects_max_fills_by_dropping_oldest() {
    let cache = LiveOhclvCache::new(2);
    let bucket_1232 = minute(12 * 60 + 32);
    let pool_id = "pool-1";

    cache.insert_fills(vec![
        fill("oldest", pool_id, bucket_1232 + 1_000, 100.0, 1.0),
        fill("middle", pool_id, bucket_1232 + 2_000, 110.0, 2.0),
        fill("newest", pool_id, bucket_1232 + 3_000, 120.0, 3.0),
    ]);

    let overlaid = cache.overlay_candles(
        "1m",
        pool_id,
        bucket_1232,
        bucket_1232 + 5_000,
        10,
        Vec::new(),
    );

    assert_eq!(
        overlaid,
        vec![candle(bucket_1232, 110.0, 120.0, 110.0, 120.0, 5.0)]
    );
}
