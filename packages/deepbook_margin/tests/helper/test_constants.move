// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module deepbook_margin::test_constants;

// === Test Addresses ===
const USER1: address = @0xA;
const USER2: address = @0xB;
const ADMIN: address = @0x0;
const LIQUIDATOR: address = @0xC;
const TEST_MARGIN_POOL_ID: address = @0x1234;

// === Test Coin Types ===
public struct USDC has drop {}
public struct USDT has drop {}
public struct BTC has drop {}
public struct SUI has drop {}
public struct INVALID_ASSET has drop {}

const USDC_MULTIPLIER: u64 = 1000000;
const USDT_MULTIPLIER: u64 = 1000000;
const DEEP_MULTIPLIER: u64 = 1000000;
const BTC_MULTIPLIER: u64 = 100000000;
const SUI_MULTIPLIER: u64 = 1000000000; // 9 decimals
const PYTH_DECIMALS: u64 = 8;

// === Margin Pool Constants ===
const SUPPLY_CAP: u64 = 1_000_000_000_000_000; // 1B tokens with 9 decimals
const MAX_UTILIZATION_RATE: u64 = 800_000_000; // 80%
const PROTOCOL_SPREAD: u64 = 100_000_000; // 10%
const MIN_BORROW: u64 = 1000;

// === Interest Rate Constants ===
const BASE_RATE: u64 = 50_000_000; // 5%
const BASE_SLOPE: u64 = 100_000_000; // 10%
const OPTIMAL_UTILIZATION: u64 = 800_000_000; // 80%
const EXCESS_SLOPE: u64 = 2_000_000_000; // 200%

// === Pool Configuration Constants ===
const MIN_WITHDRAW_RISK_RATIO: u64 = 2_000_000_000; // 200%
const MIN_BORROW_RISK_RATIO: u64 = 1_250_000_000; // 125%
const LIQUIDATION_RISK_RATIO: u64 = 1_100_000_000; // 110%
const TARGET_LIQUIDATION_RISK_RATIO: u64 = 1_250_000_000; // 125%
const USER_LIQUIDATION_REWARD: u64 = 20_000_000; // 2%
const POOL_LIQUIDATION_REWARD: u64 = 30_000_000; // 3%

// === Pyth Price Feed IDs for Testing ===
const USDC_PRICE_FEED_ID: vector<u8> = b"USDC0000000000000000000000000000";
const USDT_PRICE_FEED_ID: vector<u8> = b"USDT0000000000000000000000000000";
const BTC_PRICE_FEED_ID: vector<u8> = b"BTC00000000000000000000000000000";
const SUI_PRICE_FEED_ID: vector<u8> = b"SUI00000000000000000000000000000";

public fun supply_cap(): u64 {
    SUPPLY_CAP
}

public fun max_utilization_rate(): u64 {
    MAX_UTILIZATION_RATE
}

public fun protocol_spread(): u64 {
    PROTOCOL_SPREAD
}

public fun protocol_spread_inverse(): u64 {
    1_000_000_000 - PROTOCOL_SPREAD
}

public fun min_borrow(): u64 {
    MIN_BORROW
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

public fun liquidator(): address {
    LIQUIDATOR
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

public fun sui_price_feed_id(): vector<u8> {
    SUI_PRICE_FEED_ID
}

public fun usdc_multiplier(): u64 {
    USDC_MULTIPLIER
}

public fun usdt_multiplier(): u64 {
    USDT_MULTIPLIER
}

public fun deep_multiplier(): u64 {
    DEEP_MULTIPLIER
}

public fun btc_multiplier(): u64 {
    BTC_MULTIPLIER
}

public fun sui_multiplier(): u64 {
    SUI_MULTIPLIER
}

public fun pyth_multiplier(): u64 {
    10u64.pow(PYTH_DECIMALS as u8)
}

public fun pyth_decimals(): u64 {
    PYTH_DECIMALS
}

public fun test_margin_pool_id(): ID {
    TEST_MARGIN_POOL_ID.to_id()
}
