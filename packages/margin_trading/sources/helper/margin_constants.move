// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

module margin_trading::margin_constants;

const MARGIN_VERSION: u64 = 1;
const MAX_RISK_RATIO: u64 = 1_000 * 1_000_000_000; // Risk ratio above 1000 will be considered as 1000
const DEFAULT_USER_LIQUIDATION_REWARD: u64 = 10_000_000; // 1%
const DEFAULT_POOL_LIQUIDATION_REWARD: u64 = 40_000_000; // 4%
const MIN_LEVERAGE: u64 = 1_000_000_000; // 1x
const MAX_LEVERAGE: u64 = 20_000_000_000; // 20x
const YEAR_MS: u64 = 365 * 24 * 60 * 60 * 1000;

public fun margin_version(): u64 {
    MARGIN_VERSION
}

public fun max_risk_ratio(): u64 {
    MAX_RISK_RATIO
}

public fun default_user_liquidation_reward(): u64 {
    DEFAULT_USER_LIQUIDATION_REWARD
}

public fun default_pool_liquidation_reward(): u64 {
    DEFAULT_POOL_LIQUIDATION_REWARD
}

public fun min_leverage(): u64 {
    MIN_LEVERAGE
}

public fun max_leverage(): u64 {
    MAX_LEVERAGE
}

public fun year_ms(): u64 {
    YEAR_MS
}
