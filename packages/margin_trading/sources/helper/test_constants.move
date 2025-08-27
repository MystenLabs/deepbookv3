// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module margin_trading::test_constants;

// Test constants
const SUPPLY_CAP: u64 = 1_000_000_000_000;
const MAX_UTILIZATION_RATE: u64 = 800_000_000; // 80%
const PROTOCOL_SPREAD: u64 = 100_000_000; // 10%
const BASE_RATE: u64 = 50_000_000; // 5%
const BASE_SLOPE: u64 = 100_000_000; // 10%
const OPTIMAL_UTILIZATION: u64 = 800_000_000; // 80%
const EXCESS_SLOPE: u64 = 2_000_000_000; // 200%

public fun supply_cap(): u64 {
    SUPPLY_CAP
}

public fun max_utilization_rate(): u64 {
    MAX_UTILIZATION_RATE
}

public fun protocol_spread(): u64 {
    PROTOCOL_SPREAD
}

public fun base_rate(): u64 {
    BASE_RATE
}

public fun base_slope(): u64 {
    BASE_SLOPE
}

public fun optimal_utilization(): u64 {
    OPTIMAL_UTILIZATION
}

public fun excess_slope(): u64 {
    EXCESS_SLOPE
}
