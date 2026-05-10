// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Shared oracle timestamp helpers.
///
/// Oracle source data tracks both the original source timestamp and the
/// on-chain update timestamp. Freshness is checked against the older of those
/// two values so neither delayed relays nor future-dated source pushes can make
/// stale data look fresh.
module deepbook_predict::oracle_time;

// === Public-Package Functions ===

public(package) fun source_timestamp_us_to_ms(source_timestamp_us: u64): u64 {
    source_timestamp_us / 1000
}

public(package) fun source_timestamp_us_after_ms(
    source_timestamp_us: u64,
    timestamp_ms: u64,
): bool {
    (source_timestamp_us as u128) > (timestamp_ms as u128) * 1000
}

public(package) fun is_fresh(
    now_ms: u64,
    source_timestamp_ms: u64,
    update_timestamp_ms: u64,
    freshness_ms: u64,
): bool {
    timestamp_is_fresh(
        now_ms,
        effective_timestamp_ms(source_timestamp_ms, update_timestamp_ms),
        freshness_ms,
    )
}

public(package) fun effective_timestamp_ms(
    source_timestamp_ms: u64,
    update_timestamp_ms: u64,
): u64 {
    if (source_timestamp_ms < update_timestamp_ms) {
        source_timestamp_ms
    } else {
        update_timestamp_ms
    }
}

// === Private Functions ===

fun timestamp_is_fresh(now_ms: u64, timestamp_ms: u64, freshness_ms: u64): bool {
    if (timestamp_ms == 0) return false;
    if (timestamp_ms > now_ms) return false;
    now_ms - timestamp_ms <= freshness_ms
}
