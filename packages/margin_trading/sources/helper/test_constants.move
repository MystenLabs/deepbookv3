// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module margin_trading::test_constants;

// === Test Addresses ===
const USER1: address = @0xA;
const USER2: address = @0xB;
const ADMIN: address = @0x0;

// === Test Coin Types ===
public struct USDC has drop {}
public struct USDT has drop {}
public struct BTC has drop {}

const USDC_MULTIPLIER: u64 = 1000000;
const USDT_MULTIPLIER: u64 = 1000000;
const BTC_MULTIPLIER: u64 = 100000000;

// === Margin Pool Constants ===
const SUPPLY_CAP: u64 = 1_000_000_000_000_000; // 1B tokens with 9 decimals
const MAX_UTILIZATION_RATE: u64 = 800_000_000; // 80%
const PROTOCOL_SPREAD: u64 = 100_000_000; // 10%

// === Interest Rate Constants ===
const BASE_RATE: u64 = 50_000_000; // 5%
const BASE_SLOPE: u64 = 100_000_000; // 10%
const OPTIMAL_UTILIZATION: u64 = 800_000_000; // 80%
const EXCESS_SLOPE: u64 = 2_000_000_000; // 200%

// === Pool Configuration Constants ===
const MIN_WITHDRAW_RISK_RATIO: u64 = 2_000_000_000; // 200%
const MIN_BORROW_RISK_RATIO: u64 = 1_500_000_000; // 150%
const LIQUIDATION_RISK_RATIO: u64 = 1_200_000_000; // 120%
const TARGET_LIQUIDATION_RISK_RATIO: u64 = 1_300_000_000; // 130%
const USER_LIQUIDATION_REWARD: u64 = 50_000_000; // 5%
const POOL_LIQUIDATION_REWARD: u64 = 10_000_000; // 1%

// === Pyth Price Feed IDs for Testing ===
const USDC_PRICE_FEED_ID: vector<u8> = b"USDC0000000000000000000000000000";
const USDT_PRICE_FEED_ID: vector<u8> = b"USDT0000000000000000000000000000";
const BTC_PRICE_FEED_ID: vector<u8> = b"BTC00000000000000000000000000000";

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

public fun user1(): address {
    USER1
}

public fun user2(): address {
    USER2
}

public fun admin(): address {
    ADMIN
}

// === Pool Configuration Getters ===
public fun min_withdraw_risk_ratio(): u64 {
    MIN_WITHDRAW_RISK_RATIO
}

public fun min_borrow_risk_ratio(): u64 {
    MIN_BORROW_RISK_RATIO
}

public fun liquidation_risk_ratio(): u64 {
    LIQUIDATION_RISK_RATIO
}

public fun target_liquidation_risk_ratio(): u64 {
    TARGET_LIQUIDATION_RISK_RATIO
}

public fun user_liquidation_reward(): u64 {
    USER_LIQUIDATION_REWARD
}

public fun pool_liquidation_reward(): u64 {
    POOL_LIQUIDATION_REWARD
}

// === Pyth Price Feed ID Getters ===
public fun usdc_price_feed_id(): vector<u8> {
    USDC_PRICE_FEED_ID
}

public fun usdt_price_feed_id(): vector<u8> {
    USDT_PRICE_FEED_ID
}

public fun btc_price_feed_id(): vector<u8> {
    BTC_PRICE_FEED_ID
}

public fun usdc_multiplier(): u64 {
    USDC_MULTIPLIER
}

public fun usdt_multiplier(): u64 {
    USDT_MULTIPLIER
}

public fun btc_multiplier(): u64 {
    BTC_MULTIPLIER
}
