// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

module margin_trading::margin_constants;

use deepbook::constants;

#[allow(unused_const)]
const CURRENT_VERSION: u64 = 1; // TODO: add version checks
const MAX_RISK_RATIO: u64 = 1_000; // Risk ratio above 1000 will be considered as 1000
const DEFAULT_USER_LIQUIDATION_REWARD: u64 = 10_000_000; // 1%
const DEFAULT_POOL_LIQUIDATION_REWARD: u64 = 40_000_000; // 4%

public fun max_risk_ratio(): u64 {
    MAX_RISK_RATIO * constants::float_scaling()
}

public fun default_user_liquidation_reward(): u64 {
    DEFAULT_USER_LIQUIDATION_REWARD
}

public fun default_pool_liquidation_reward(): u64 {
    DEFAULT_POOL_LIQUIDATION_REWARD
}
