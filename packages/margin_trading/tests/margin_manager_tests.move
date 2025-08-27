// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module margin_trading::margin_manager_tests;

use deepbook::{
    constants,
    pool::{Self, Pool},
    registry::{Self, Registry}
};
use margin_trading::margin_registry::MarginApp;
use margin_trading::{
    margin_manager,
    margin_pool,
    margin_registry::{Self, MarginRegistry, MarginAdminCap, MaintainerCap},
    protocol_config,
    oracle
};
use sui::{
    clock::{Self, Clock},
    test_scenario::{Self as test, Scenario, return_shared},
    test_utils::destroy
};
use pyth::{
    i64,
    price,
    price_identifier,
    price_feed,
    price_info::{Self, PriceInfoObject},
};
use token::deep::DEEP;
use sui::coin::mint_for_testing;

public struct USDC has drop {}
public struct USDT has drop {}
public struct BTC has drop {}
public struct USD has drop {}

const ADMIN: address = @0x0;
const USER1: address = @0x1;
const USER2: address = @0x2;

/// Pyth price feed IDs for testing
const USDC_PRICE_FEED_ID: vector<u8> = b"USDC0000000000000000000000000000";
const USDT_PRICE_FEED_ID: vector<u8> = b"USDT0000000000000000000000000000";
const BTC_PRICE_FEED_ID: vector<u8> = b"BTC00000000000000000000000000000";

/// Pool and margin constants
const SUPPLY_CAP: u64 = 1_000_000_000_000_000; // 1B tokens with 9 decimals
const MAX_UTILIZATION_RATE: u64 = 800_000_000; // 80% with 9 decimals
const PROTOCOL_SPREAD: u64 = 100_000_000; // 10% with 9 decimals

fun setup_margin_registry(): (Scenario, Clock, MarginRegistry, MarginAdminCap, MaintainerCap) {
    let mut scenario = test::begin(ADMIN);
    let mut clock = clock::create_for_testing(scenario.ctx());
    clock.set_for_testing(1000);

    let (mut registry, admin_cap) = margin_registry::new_for_testing(scenario.ctx());
    let maintainer_cap = margin_registry::mint_maintainer_cap(
        &mut registry,
        &admin_cap,
        &clock,
        scenario.ctx(),
    );

    (scenario, clock, registry, admin_cap, maintainer_cap)
}

fun create_margin_pool<Asset>(
    registry: &mut MarginRegistry,
    maintainer_cap: &MaintainerCap,
    clock: &Clock,
    ctx: &mut TxContext,
): ID {
    let margin_pool_config = protocol_config::new_margin_pool_config(
        SUPPLY_CAP,
        MAX_UTILIZATION_RATE,
        PROTOCOL_SPREAD,
    );
    let interest_config = protocol_config::new_interest_config(
        50_000_000, // base_rate: 5% with 9 decimals
        100_000_000, // base_slope: 10% with 9 decimals
        800_000_000, // optimal_utilization: 80% with 9 decimals
        2_000_000_000, // excess_slope: 200% with 9 decimals
    );
    let protocol_config = protocol_config::new_protocol_config(margin_pool_config, interest_config);
    
    margin_pool::create_margin_pool<Asset>(
        registry,
        protocol_config,
        maintainer_cap,
        clock,
        ctx,
    )
}

fun cleanup_margin_test(
    registry: MarginRegistry,
    admin_cap: MarginAdminCap,
    maintainer_cap: MaintainerCap,
    clock: Clock,
    scenario: Scenario,
) {
    destroy(registry);
    destroy(admin_cap);
    destroy(maintainer_cap);
    destroy(clock);
    scenario.end();
}

/// Helper function to set up a complete BTC/USD margin trading environment
/// Returns: (scenario, clock, registry, admin_cap, maintainer_cap, btc_pool_id, usd_pool_id, deepbook_pool_id)
fun setup_btc_usd_margin_trading(): (
    Scenario, Clock, MarginRegistry, MarginAdminCap, MaintainerCap, ID, ID, ID
) {
    let (mut scenario, mut clock, mut registry, admin_cap, maintainer_cap) = setup_margin_registry();
    
    clock.set_for_testing(1000000);
    
    // Add PythConfig to the registry
    let pyth_config = create_test_pyth_config();
    margin_registry::add_config(&mut registry, &admin_cap, pyth_config);
    
    // Create margin pools
    scenario.next_tx(ADMIN);
    let btc_pool_id = create_margin_pool<BTC>(&mut registry, &maintainer_cap, &clock, scenario.ctx());
    let usd_pool_id = create_margin_pool<USDC>(&mut registry, &maintainer_cap, &clock, scenario.ctx());
    
    // Get MarginPoolCaps
    scenario.next_tx(ADMIN);
    let cap1 = scenario.take_from_sender<margin_registry::MarginPoolCap>();
    let cap2 = scenario.take_from_sender<margin_registry::MarginPoolCap>();
    
    let (btc_pool_cap, usd_pool_cap) = if (margin_registry::margin_pool_id(&cap1) == btc_pool_id) {
        (cap1, cap2)
    } else {
        (cap2, cap1)
    };
    
    // Create and enable DeepBook pool
    let pool_id = create_pool_for_testing<BTC, USDC>(&mut scenario);
    enable_margin_trading_on_pool<BTC, USDC>(
        pool_id, &mut registry, &admin_cap, &clock, &mut scenario
    );
    
    // Supply liquidity
    scenario.next_tx(ADMIN);
    let mut btc_pool = scenario.take_shared_by_id<margin_pool::MarginPool<BTC>>(btc_pool_id);
    let mut usd_pool = scenario.take_shared_by_id<margin_pool::MarginPool<USDC>>(usd_pool_id);
    
    margin_pool::supply<BTC>(&mut btc_pool, &registry, mint_for_testing<BTC>(10_00000000, scenario.ctx()), &clock, scenario.ctx());
    margin_pool::supply<USDC>(&mut usd_pool, &registry, mint_for_testing<USDC>(1_000_000_000000, scenario.ctx()), &clock, scenario.ctx());
    
    margin_pool::enable_deepbook_pool_for_loan<BTC>(&mut btc_pool, &registry, pool_id, &btc_pool_cap, &clock);
    margin_pool::enable_deepbook_pool_for_loan<USDC>(&mut usd_pool, &registry, pool_id, &usd_pool_cap, &clock);
    
    test::return_shared(btc_pool);
    test::return_shared(usd_pool);
    scenario.return_to_sender(btc_pool_cap);
    scenario.return_to_sender(usd_pool_cap);
    
    (scenario, clock, registry, admin_cap, maintainer_cap, btc_pool_id, usd_pool_id, pool_id)
}

fun create_pool_for_testing<BaseAsset, QuoteAsset>(
    scenario: &mut Scenario,
): ID {
    let registry_id = registry::test_registry(scenario.ctx());
    
    scenario.next_tx(@0x0);
    let mut registry = scenario.take_shared_by_id<Registry>(registry_id);
    
    let pool_id = pool::create_permissionless_pool<BaseAsset, QuoteAsset>(
        &mut registry,
        constants::tick_size(), 
        constants::lot_size(), 
        constants::min_size(), 
        mint_for_testing<DEEP>(constants::pool_creation_fee(), scenario.ctx()), // creation fee
        scenario.ctx(),
    );
    
    return_shared(registry);
    pool_id
}

fun enable_margin_trading_on_pool<BaseAsset, QuoteAsset>(
    pool_id: ID,
    margin_registry: &mut MarginRegistry,
    admin_cap: &MarginAdminCap,
    clock: &Clock,
    scenario: &mut Scenario,
) {
    scenario.next_tx(@0x0);
    let mut pool = scenario.take_shared_by_id<Pool<BaseAsset, QuoteAsset>>(pool_id);
    
    // authorize MarginApp on the pool - deepbook admin feature 
    let deepbook_admin_cap = registry::get_admin_cap_for_testing(scenario.ctx());
    pool.authorize_app<MarginApp, BaseAsset, QuoteAsset>(&deepbook_admin_cap);
    destroy(deepbook_admin_cap);
    
    let pool_config = create_test_pool_config<BaseAsset, QuoteAsset>(margin_registry);
    margin_registry::register_deepbook_pool<BaseAsset, QuoteAsset>(
        margin_registry,
        admin_cap,
        &pool,
        pool_config,
        clock,
    );
    
    margin_registry::enable_deepbook_pool<BaseAsset, QuoteAsset>(
        margin_registry,
        admin_cap,
        &mut pool,
        clock,
    );
    return_shared(pool);
}

/// Create a test pool configuration
fun create_test_pool_config<BaseAsset, QuoteAsset>(
    margin_registry: &MarginRegistry, 
): margin_registry::PoolConfig {
    margin_registry::new_pool_config<BaseAsset, QuoteAsset>(
        margin_registry,
        2_000_000_000, // min_withdraw_risk_ratio: 200%
        1_500_000_000, // min_borrow_risk_ratio: 150%  
        1_200_000_000, // liquidation_risk_ratio: 120% (must be >= 100% and < min_borrow_risk_ratio)
        1_300_000_000, // target_liquidation_risk_ratio: 130%
        50_000_000, // user_liquidation_reward: 5%
        10_000_000, // pool_liquidation_reward: 1%
    )
}

#[test]
fun test_margin_manager_creation() {
    let (mut scenario, clock, mut registry, admin_cap, maintainer_cap) = setup_margin_registry();
    
    // Test creating multiple margin pools
    scenario.next_tx(USER1);
    let _btc_pool_id = create_margin_pool<BTC>(&mut registry, &maintainer_cap, &clock, scenario.ctx());
    let _usdt_pool_id = create_margin_pool<USDT>(&mut registry, &maintainer_cap, &clock, scenario.ctx());
    let _usdc_pool_id = create_margin_pool<USDC>(&mut registry, &maintainer_cap, &clock, scenario.ctx());
    
    // Create DeepBook pool and enable margin trading on it
    let pool_id = create_pool_for_testing<USDC, USDT>(&mut scenario);
    enable_margin_trading_on_pool<USDC, USDT>(
        pool_id,
        &mut registry,
        &admin_cap,
        &clock,
        &mut scenario,
    );
    
    scenario.next_tx(ADMIN);  
    let pool = scenario.take_shared<Pool<USDC, USDT>>();
    margin_manager::new<USDC, USDT>(&pool, &registry, scenario.ctx());
    return_shared(pool);
    cleanup_margin_test(registry, admin_cap, maintainer_cap, clock, scenario);
}

// === Pyth Oracle Utilities ===

/// Build a Pyth price info object for testing
/// Parameters:
/// - id: Price identifier as bytes (e.g., b"USDC0000000000000000000000000000")
/// - price_value: Price value (e.g., 99995001 for $0.99995001 with exponent -8)
/// - conf_value: Confidence interval
/// - exp_value: Exponent for price (e.g., 8 means multiply by 10^-8)
/// - timestamp: Unix timestamp in seconds
#[test_only]
public fun build_pyth_price_info_object(
    scenario: &mut Scenario,
    id: vector<u8>,
    price_value: u64,
    conf_value: u64,
    exp_value: u64,
    timestamp: u64,
): PriceInfoObject {
    let price_id = price_identifier::from_byte_vec(id);
    let price = price::new(
        i64::new(price_value, false), // positive price
        conf_value,
        i64::new(exp_value, true), // negative exponent
        timestamp
    );
    let price_feed = price_feed::new(price_id, price, price);
    let price_info = price_info::new_price_info(
        timestamp - 2, // attestation_time
        timestamp - 1, // arrival_time
        price_feed
    );
    price_info::new_price_info_object_for_test(price_info, scenario.ctx())
}

/// Build a demo USDC price info object at $1.00
#[test_only]
public fun build_demo_usdc_price_info_object(scenario: &mut Scenario, timestamp: u64): PriceInfoObject {
    // USDC at ~$1.00 (0.99995001)
    build_pyth_price_info_object(scenario, USDC_PRICE_FEED_ID, 99995001, 98352, 8, timestamp)
}

/// Build a demo USDT price info object at $1.00
#[test_only]
public fun build_demo_usdt_price_info_object(scenario: &mut Scenario, timestamp: u64): PriceInfoObject {
    // USDT at exactly $1.00
    build_pyth_price_info_object(scenario, USDT_PRICE_FEED_ID, 100000000, 50000, 8, timestamp)
}

/// Build a BTC price info object at a given price
#[test_only]
public fun build_btc_price_info_object(scenario: &mut Scenario, price: u64, timestamp: u64): PriceInfoObject {
    // BTC price with 8 decimal places (e.g., 60000_00000000 = $60,000)
    build_pyth_price_info_object(scenario, BTC_PRICE_FEED_ID, price, 1000000, 8, timestamp)
}

/// Create a test PythConfig for all test coins
#[test_only]
fun create_test_pyth_config(): oracle::PythConfig {
    // For testing, create a simple configuration with minimal setup
    let mut coin_data_vec = vector[];
    
    // Add USDC configuration (6 decimals)
    let usdc_data = oracle::test_coin_type_data<USDC>(
        6, // decimals
        USDC_PRICE_FEED_ID
    );
    coin_data_vec.push_back(usdc_data);
    
    // Add USDT configuration (6 decimals)
    let usdt_data = oracle::test_coin_type_data<USDT>(
        6, // decimals
        USDT_PRICE_FEED_ID
    );
    coin_data_vec.push_back(usdt_data);
    
    // Add BTC configuration (8 decimals)
    let btc_data = oracle::test_coin_type_data<BTC>(
        8, // decimals
        BTC_PRICE_FEED_ID
    );
    coin_data_vec.push_back(btc_data);

    oracle::new_pyth_config(
        coin_data_vec,
        60 // max age 60 seconds
    )
}

#[test]
fun test_margin_trading_with_oracle() {
    let (mut scenario, mut clock, mut registry, admin_cap, maintainer_cap) = setup_margin_registry();
    
    clock.set_for_testing(1000000);
    
    // Add PythConfig to the registry - CRITICAL STEP!
    let pyth_config = create_test_pyth_config();
    margin_registry::add_config(&mut registry, &admin_cap, pyth_config);
    
    scenario.next_tx(ADMIN);
    let usdc_pool_id = create_margin_pool<USDC>(&mut registry, &maintainer_cap, &clock, scenario.ctx());
    let usdt_pool_id = create_margin_pool<USDT>(&mut registry, &maintainer_cap, &clock, scenario.ctx());
    
    scenario.next_tx(ADMIN);
    let cap1 = scenario.take_from_sender<margin_registry::MarginPoolCap>();
    let cap2 = scenario.take_from_sender<margin_registry::MarginPoolCap>();
    
    let (usdc_pool_cap, usdt_pool_cap) = if (margin_registry::margin_pool_id(&cap1) == usdc_pool_id) {
        (cap1, cap2)
    } else {
        (cap2, cap1)
    };
    
    let pool_id = create_pool_for_testing<USDC, USDT>(&mut scenario);
    enable_margin_trading_on_pool<USDC, USDT>(
        pool_id,
        &mut registry,
        &admin_cap,
        &clock,
        &mut scenario,
    );
    
    scenario.next_tx(ADMIN);
    let mut usdc_pool = scenario.take_shared_by_id<margin_pool::MarginPool<USDC>>(usdc_pool_id);
    let mut usdt_pool = scenario.take_shared_by_id<margin_pool::MarginPool<USDT>>(usdt_pool_id);
    
    let usdc_supply = mint_for_testing<USDC>(1_000_000_000_000, scenario.ctx()); // 1M USDC with 6 decimals
    let usdt_supply = mint_for_testing<USDT>(1_000_000_000_000, scenario.ctx()); // 1M USDT with 6 decimals
    
    margin_pool::supply<USDC>(&mut usdc_pool, &registry, usdc_supply, &clock, scenario.ctx());
    margin_pool::supply<USDT>(&mut usdt_pool, &registry, usdt_supply, &clock, scenario.ctx());
    
    margin_pool::enable_deepbook_pool_for_loan<USDC>(
        &mut usdc_pool,
        &registry,
        pool_id,
        &usdc_pool_cap,
        &clock
    );
    
    margin_pool::enable_deepbook_pool_for_loan<USDT>(
        &mut usdt_pool,
        &registry,
        pool_id,
        &usdt_pool_cap,
        &clock
    );
    
    test::return_shared(usdc_pool);
    test::return_shared(usdt_pool);
    
    scenario.return_to_sender(usdc_pool_cap);
    scenario.return_to_sender(usdt_pool_cap);
    
    scenario.next_tx(USER1);
    let mut pool = scenario.take_shared<Pool<USDC, USDT>>();
    margin_manager::new<USDC, USDT>(&pool, &registry, scenario.ctx());
    return_shared(pool);
    
    scenario.next_tx(ADMIN);
    let usdc_price = build_demo_usdc_price_info_object(&mut scenario, clock.timestamp_ms() / 1000);
    let usdt_price = build_demo_usdt_price_info_object(&mut scenario, clock.timestamp_ms() / 1000);
    
    // Now test borrowing with oracle prices
    scenario.next_tx(USER1);
    let mut margin_managers = scenario.take_shared<margin_manager::MarginManager<USDC, USDT>>();
    let mut usdt_pool = scenario.take_shared_by_id<margin_pool::MarginPool<USDT>>(usdt_pool_id);
    let pool = scenario.take_shared<Pool<USDC, USDT>>();
    
    // User1 deposits 10k USDC as collateral
    let deposit_coin = mint_for_testing<USDC>(10_000_000_000, scenario.ctx()); // 10k USDC with 6 decimals
    margin_manager::deposit<USDC, USDT, USDC>(&mut margin_managers, &registry, deposit_coin, scenario.ctx());
    
    // Borrow 5k USDT against the collateral (50% borrow ratio)
    let request = margin_manager::borrow_quote<USDC, USDT>(
        &mut margin_managers,
        &registry,
        &mut usdt_pool,
        5_000_000_000, // 5k USDT with 6 decimals
        &clock,
        scenario.ctx()
    );
    
    // Prove the request is valid using oracle prices
    margin_manager::prove_and_destroy_request<USDC, USDT, USDT>(
        &margin_managers,
        &registry,
        &mut usdt_pool,
        &pool,
        &usdc_price,
        &usdt_price,
        &clock,
        request
    );
    
    test::return_shared(margin_managers);
    test::return_shared(usdt_pool);
    test::return_shared(pool);
    
    destroy(usdc_price);
    destroy(usdt_price);
    
    cleanup_margin_test(registry, admin_cap, maintainer_cap, clock, scenario);
}

/// Test demonstrates BTC/USD margin trading with borrowing
#[test]
fun test_btc_usd_margin_trading() {
    let (mut scenario, mut clock, registry, admin_cap, maintainer_cap, _btc_pool_id, usd_pool_id, pool_id) = 
        setup_btc_usd_margin_trading();
    
    // BTC price: $60,000
    let btc_price = build_btc_price_info_object(&mut scenario, 60000_00000000, clock.timestamp_ms() / 1000);
    let usd_price = build_demo_usdc_price_info_object(&mut scenario, clock.timestamp_ms() / 1000);
    
    // USER1 creates margin manager and borrows
    scenario.next_tx(USER1);
    let pool = scenario.take_shared<Pool<BTC, USDC>>();
    margin_manager::new<BTC, USDC>(&pool, &registry, scenario.ctx());
    return_shared(pool);
    
    scenario.next_tx(USER1);
    let mut margin_managers = scenario.take_shared<margin_manager::MarginManager<BTC, USDC>>();
    let mut usd_pool = scenario.take_shared_by_id<margin_pool::MarginPool<USDC>>(usd_pool_id);
    let pool = scenario.take_shared<Pool<BTC, USDC>>();
    
    // Deposit 0.5 BTC as collateral
    let deposit = mint_for_testing<BTC>(50000000, scenario.ctx()); // 0.5 BTC
    margin_manager::deposit<BTC, USDC, BTC>(&mut margin_managers, &registry, deposit, scenario.ctx());
    
    let request = margin_manager::borrow_quote<BTC, USDC>(
        &mut margin_managers,
        &registry,
        &mut usd_pool,
        15_000_000000, // $15,000
        &clock,
        scenario.ctx()
    );
    
    // Prove the borrow is valid
    margin_manager::prove_and_destroy_request<BTC, USDC, USDC>(
        &margin_managers,
        &registry,
        &mut usd_pool,
        &pool,
        &btc_price,
        &usd_price,
        &clock,
        request
    );
    
    test::return_shared(margin_managers);
    test::return_shared(usd_pool);
    test::return_shared(pool);
    
    destroy(btc_price);
    destroy(usd_price);
    
    cleanup_margin_test(registry, admin_cap, maintainer_cap, clock, scenario);
}

/// Test demonstrates depositing USD and borrowing BTC at near-max LTV
#[test]
fun test_usd_deposit_btc_borrow() {
    let (mut scenario, mut clock, registry, admin_cap, maintainer_cap, btc_pool_id, _usd_pool_id, pool_id) = 
        setup_btc_usd_margin_trading();
    
    // Set initial prices
    let btc_price = build_btc_price_info_object(&mut scenario, 50000_00000000, clock.timestamp_ms() / 1000);
    let usd_price = build_demo_usdc_price_info_object(&mut scenario, clock.timestamp_ms() / 1000);
    
    scenario.next_tx(USER1);
    let pool = scenario.take_shared<Pool<BTC, USDC>>();
    margin_manager::new<BTC, USDC>(&pool, &registry, scenario.ctx());
    return_shared(pool);
    
    scenario.next_tx(USER1);
    let mut margin_managers = scenario.take_shared<margin_manager::MarginManager<BTC, USDC>>();
    let mut btc_pool = scenario.take_shared_by_id<margin_pool::MarginPool<BTC>>(btc_pool_id);
    let pool = scenario.take_shared<Pool<BTC, USDC>>();
    
    // Deposit 75000 USD
    margin_manager::deposit<BTC, USDC, USDC>(
        &mut margin_managers, 
        &registry, 
        mint_for_testing<USDC>(75_000_000000, scenario.ctx()),
        scenario.ctx()
    );
    
    // Borrow 0.95 BTC 
    let request = margin_manager::borrow_base<BTC, USDC>(
        &mut margin_managers,
        &registry,
        &mut btc_pool,
        95000000, // 0.95 BTC
        &clock,
        scenario.ctx()
    );
    
    // Prove borrow is valid
    margin_manager::prove_and_destroy_request<BTC, USDC, BTC>(
        &margin_managers, &registry, &mut btc_pool, &pool,
        &btc_price, &usd_price, &clock, request
    );
    
    // 20% BTC price increase to $60,000
    clock.set_for_testing(1000001);
    let btc_increased = build_btc_price_info_object(&mut scenario, 60000_00000000, clock.timestamp_ms() / 1000);
    
    
    test::return_shared(margin_managers);
    test::return_shared(btc_pool);
    test::return_shared(pool);
    
    destroy(btc_price);
    destroy(usd_price);
    destroy(btc_increased);
    
    cleanup_margin_test(registry, admin_cap, maintainer_cap, clock, scenario);
}
