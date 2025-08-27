// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module margin_trading::test_constants;

// Test constants
const SUPPLY_CAP: u64 = 1_000_000_000_000; // 1M tokens with 9 decimals
const MAX_UTILIZATION_RATE: u64 = 800_000_000; // 80% with 9 decimals
const PROTOCOL_SPREAD: u64 = 100_000_000; // 10% with 9 decimals

public fun supply_cap(): u64 {
    SUPPLY_CAP
}

public fun max_utilization_rate(): u64 {
    MAX_UTILIZATION_RATE
}

public fun protocol_spread(): u64 {
    PROTOCOL_SPREAD
}
