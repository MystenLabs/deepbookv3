// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

module deepbook_margin::margin_constants;

const MARGIN_VERSION: u64 = 2;
const MAX_RISK_RATIO: u64 = 1_000 * 1_000_000_000; // Risk ratio above 1000 will be considered as 1000
const DEFAULT_USER_LIQUIDATION_REWARD: u64 = 10_000_000; // 1%
const DEFAULT_POOL_LIQUIDATION_REWARD: u64 = 40_000_000; // 4%
const MIN_LEVERAGE: u64 = 1_000_000_000; // 1x
const MAX_LEVERAGE: u64 = 20_000_000_000; // 20x
const YEAR_MS: u64 = 365 * 24 * 60 * 60 * 1000;
const DAY_MS: u64 = 24 * 60 * 60 * 1000;
const MIN_MIN_BORROW: u64 = 1000;
const MAX_MARGIN_MANAGERS: u64 = 100;
const DEFAULT_REFERRAL: address = @0x0;
const MAX_PROTOCOL_SPREAD: u64 = 200_000_000; // 20%
const MIN_LIQUIDATION_REPAY: u64 = 1000;
const MAX_CONF_BPS: u64 = 10_000; // 100% - maximum allowed confidence interval
const MAX_EWMA_DIFFERENCE_BPS: u64 = 10_000; // 100% - maximum allowed EWMA price difference
const MAX_CONDITIONAL_ORDERS: u64 = 10;

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

public fun min_min_borrow(): u64 {
    MIN_MIN_BORROW
}

public fun max_margin_managers(): u64 {
    MAX_MARGIN_MANAGERS
}

public fun default_referral(): ID {
    DEFAULT_REFERRAL.to_id()
}

public fun max_protocol_spread(): u64 {
    MAX_PROTOCOL_SPREAD
}

public fun min_liquidation_repay(): u64 {
    MIN_LIQUIDATION_REPAY
}

public fun max_conf_bps(): u64 {
    MAX_CONF_BPS
}

public fun max_ewma_difference_bps(): u64 {
    MAX_EWMA_DIFFERENCE_BPS
}

public fun max_conditional_orders(): u64 {
    MAX_CONDITIONAL_ORDERS
}

public fun day_ms(): u64 {
    DAY_MS
}
