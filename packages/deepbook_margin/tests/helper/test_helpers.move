// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module deepbook_margin::test_helpers;

use deepbook::{constants, math, pool::{Self, Pool}, registry::{Self, Registry}};
use deepbook_margin::{
    margin_manager::MarginApp,
    margin_pool::{Self, MarginPool},
    margin_registry::{
        Self,
        MarginRegistry,
        MarginAdminCap,
        MaintainerCap,
        PoolConfig,
        MarginPoolCap
    },
    oracle::{Self, PythConfig},
    protocol_config::{Self, ProtocolConfig},
    test_constants::{Self, USDC, USDT, BTC, SUI}
};
use pyth::{i64, price, price_feed, price_identifier, price_info::{Self, PriceInfoObject}};
use std::unit_test::destroy;
use sui::{
    clock::{Self, Clock},
    coin::{Self, Coin},
    test_scenario::{Self as test, Scenario, begin, return_shared}
};
use token::deep::DEEP;

// === Cleanup helper functions ===

public macro fun destroy_all<$T>($vec: vector<$T>) {
    let mut v = $vec;
    v.do!(|item| destroy(item));
    v.destroy_empty();
}

public macro fun destroy_2<$T1, $T2>($obj1: $T1, $obj2: $T2) {
    destroy($obj1);
    destroy($obj2);
}

public macro fun destroy_3<$T1, $T2, $T3>($obj1: $T1, $obj2: $T2, $obj3: $T3) {
    destroy($obj1);
    destroy($obj2);
    destroy($obj3);
}

public macro fun destroy_4<$T1, $T2, $T3, $T4>($obj1: $T1, $obj2: $T2, $obj3: $T3, $obj4: $T4) {
    destroy($obj1);
    destroy($obj2);
    destroy($obj3);
    destroy($obj4);
}

public macro fun return_shared_2<$T1, $T2>($obj1: $T1, $obj2: $T2) {
    return_shared($obj1);
    return_shared($obj2);
}

public macro fun return_shared_3<$T1, $T2, $T3>($obj1: $T1, $obj2: $T2, $obj3: $T3) {
    return_shared($obj1);
    return_shared($obj2);
    return_shared($obj3);
}

public macro fun return_shared_4<$T1, $T2, $T3, $T4>(
    $obj1: $T1,
    $obj2: $T2,
    $obj3: $T3,
    $obj4: $T4,
) {
    return_shared($obj1);
    return_shared($obj2);
    return_shared($obj3);
    return_shared($obj4);
}

public macro fun return_to_sender_2<$T1, $T2>($scenario: &Scenario, $obj1: $T1, $obj2: $T2) {
    let s = $scenario;
    s.return_to_sender($obj1);
    s.return_to_sender($obj2);
}

public fun setup_test(): (Scenario, MarginAdminCap) {
    let mut test = begin(test_constants::admin());
    let clock = clock::create_for_testing(test.ctx());

    let admin_cap = margin_registry::new_for_testing(test.ctx());

    clock.share_for_testing();

    (test, admin_cap)
}

public fun setup_margin_registry(): (Scenario, Clock, MarginAdminCap, MaintainerCap) {
    let (mut scenario, admin_cap) = setup_test();
    let mut clock = clock::create_for_testing(scenario.ctx());
    clock.set_for_testing(1000000);

    scenario.next_tx(test_constants::admin());
    let mut registry = scenario.take_shared<MarginRegistry>();
    let maintainer_cap = registry.mint_maintainer_cap(&admin_cap, &clock, scenario.ctx());
    let pyth_config = create_test_pyth_config();
    registry.add_config(&admin_cap, pyth_config);
    return_shared(registry);

    (scenario, clock, admin_cap, maintainer_cap)
}

/// Authorize MarginApp to create balance managers with custom owners
public fun authorize_margin_app(scenario: &mut Scenario, registry_id: ID) {
    scenario.next_tx(test_constants::admin());
    let deepbook_admin_cap = registry::get_admin_cap_for_testing(scenario.ctx());
    let mut registry = scenario.take_shared_by_id<Registry>(registry_id);
    registry.authorize_app<MarginApp>(&deepbook_admin_cap);
    return_shared(registry);
    destroy(deepbook_admin_cap);
}

public fun create_margin_pool<Asset>(
    test: &mut Scenario,
    maintainer_cap: &MaintainerCap,
    protocol_config: ProtocolConfig,
    clock: &Clock,
): ID {
    test.next_tx(test_constants::admin());

    let mut registry = test.take_shared<MarginRegistry>();

    let pool_id = margin_pool::create_margin_pool<Asset>(
        &mut registry,
        protocol_config,
        maintainer_cap,
        clock,
        test.ctx(),
    );
    return_shared(registry);

    pool_id
}

/// Helper function to retrieve two MarginPoolCaps and return them in the correct order
public fun get_margin_pool_caps(
    scenario: &mut Scenario,
    base_pool_id: ID,
): (MarginPoolCap, MarginPoolCap) {
    scenario.next_tx(test_constants::admin());
    let cap1 = scenario.take_from_sender<MarginPoolCap>();
    let cap2 = scenario.take_from_sender<MarginPoolCap>();

    if (cap1.margin_pool_id() == base_pool_id) {
        (cap1, cap2)
    } else {
        (cap2, cap1)
    }
}

/// Helper function to retrieve a single MarginPoolCap for a specific pool
public fun get_margin_pool_cap(scenario: &mut Scenario, pool_id: ID): MarginPoolCap {
    scenario.next_tx(test_constants::admin());
    let cap = scenario.take_from_sender<MarginPoolCap>();
    assert!(cap.margin_pool_id() == pool_id);
    cap
}

public fun default_protocol_config(): ProtocolConfig {
    let margin_pool_config = protocol_config::new_margin_pool_config(
        test_constants::supply_cap(),
        test_constants::max_utilization_rate(),
        test_constants::protocol_spread(),
        test_constants::min_borrow(),
    );
    let interest_config = protocol_config::new_interest_config(
        test_constants::base_rate(), // base_rate: 5% with 9 decimals
        test_constants::base_slope(), // base_slope: 10% with 9 decimals
        test_constants::optimal_utilization(), // optimal_utilization: 80% with 9 decimals
        test_constants::excess_slope(), // excess_slope: 200% with 9 decimals
    );

    protocol_config::new_protocol_config(margin_pool_config, interest_config)
}

public fun create_pool_with_rate_limit<Asset>(
    registry: &mut MarginRegistry,
    maintainer_cap: &MaintainerCap,
    supply_cap: u64,
    rate_limit_capacity: u64,
    rate_limit_refill_rate_per_ms: u64,
    rate_limit_enabled: bool,
    clock: &Clock,
    scenario: &mut Scenario,
): ID {
    scenario.next_tx(test_constants::admin());

    let margin_pool_config = protocol_config::new_margin_pool_config_with_rate_limit(
        supply_cap,
        test_constants::max_utilization_rate(),
        test_constants::protocol_spread(),
        test_constants::min_borrow(),
        rate_limit_capacity,
        rate_limit_refill_rate_per_ms,
        rate_limit_enabled,
    );
    let interest_config = protocol_config::new_interest_config(
        test_constants::base_rate(),
        test_constants::base_slope(),
        test_constants::optimal_utilization(),
        test_constants::excess_slope(),
    );
    let config = protocol_config::new_protocol_config(margin_pool_config, interest_config);

    let pool_id = margin_pool::create_margin_pool<Asset>(
        registry,
        config,
        maintainer_cap,
        clock,
        scenario.ctx(),
    );

    pool_id
}

public fun mint_coin<T>(amount: u64, ctx: &mut TxContext): Coin<T> {
    coin::mint_for_testing<T>(amount, ctx)
}

/// Helper function to supply to a margin pool with a SupplierCap
/// Returns the SupplierCap which must be used for withdrawals and eventually destroyed
public fun supply_to_pool<Asset>(
    pool: &mut MarginPool<Asset>,
    registry: &MarginRegistry,
    amount: u64,
    clock: &Clock,
    ctx: &mut TxContext,
): margin_pool::SupplierCap {
    let supplier_cap = margin_pool::mint_supplier_cap(registry, clock, ctx);
    let supply_coin = mint_coin<Asset>(amount, ctx);
    pool.supply<Asset>(registry, &supplier_cap, supply_coin, option::none(), clock);
    supplier_cap
}

/// Create a DeepBook pool for testing. Returns (pool_id, registry_id).
public fun create_pool_for_testing<BaseAsset, QuoteAsset>(scenario: &mut Scenario): (ID, ID) {
    let registry_id = registry::test_registry(scenario.ctx());

    // Authorize MarginApp to create BalanceManagers with custom owners
    authorize_margin_app(scenario, registry_id);

    scenario.next_tx(test_constants::admin());
    let mut registry = scenario.take_shared_by_id<Registry>(registry_id);

    let pool_id = pool::create_permissionless_pool<BaseAsset, QuoteAsset>(
        &mut registry,
        constants::tick_size(),
        constants::lot_size(),
        constants::min_size(),
        mint_coin<DEEP>(constants::pool_creation_fee(), scenario.ctx()),
        scenario.ctx(),
    );

    return_shared(registry);
    (pool_id, registry_id)
}

/// Enable margin trading on a DeepBook pool
public fun enable_deepbook_margin_on_pool<BaseAsset, QuoteAsset>(
    pool_id: ID,
    margin_registry: &mut MarginRegistry,
    admin_cap: &MarginAdminCap,
    clock: &Clock,
    scenario: &mut Scenario,
) {
    scenario.next_tx(test_constants::admin());
    let mut pool = scenario.take_shared_by_id<Pool<BaseAsset, QuoteAsset>>(pool_id);

    let pool_config = create_test_pool_config<BaseAsset, QuoteAsset>(margin_registry);
    margin_registry.register_deepbook_pool<BaseAsset, QuoteAsset>(
        admin_cap,
        &pool,
        pool_config,
        clock,
    );

    margin_registry.enable_deepbook_pool<BaseAsset, QuoteAsset>(
        admin_cap,
        &mut pool,
        clock,
    );
    return_shared(pool);
}

/// Create a test pool configuration
public fun create_test_pool_config<BaseAsset, QuoteAsset>(
    margin_registry: &MarginRegistry,
): PoolConfig {
    margin_registry::new_pool_config<BaseAsset, QuoteAsset>(
        margin_registry,
        test_constants::min_withdraw_risk_ratio(),
        test_constants::min_borrow_risk_ratio(),
        test_constants::liquidation_risk_ratio(),
        test_constants::target_liquidation_risk_ratio(),
        test_constants::user_liquidation_reward(),
        test_constants::pool_liquidation_reward(),
    )
}

/// Cleanup test resources
public fun cleanup_margin_test(
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

// === Pyth Oracle Test Utilities ===

/// Build a Pyth price info object for testing
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
        timestamp,
    );
    let price_feed = price_feed::new(price_id, price, price);
    let price_info = price_info::new_price_info(
        timestamp - 2, // attestation_time
        timestamp - 1, // arrival_time
        price_feed,
    );
    price_info::new_price_info_object_for_test(price_info, scenario.ctx())
}

/// Build a demo USDC price info object at $1.00
public fun build_demo_usdc_price_info_object(
    scenario: &mut Scenario,
    clock: &Clock,
): PriceInfoObject {
    // USDC at exactly $1.00
    build_pyth_price_info_object(
        scenario,
        test_constants::usdc_price_feed_id(),
        1 * test_constants::pyth_multiplier(),
        50000,
        test_constants::pyth_decimals(),
        clock.timestamp_ms() / 1000,
    )
}

/// Build a demo USDC price info object at $1.00
public fun build_demo_usdc_price_info_object_with_price(
    scenario: &mut Scenario,
    price: u64,
    clock: &Clock,
): PriceInfoObject {
    build_pyth_price_info_object(
        scenario,
        test_constants::usdc_price_feed_id(),
        price,
        50000,
        test_constants::pyth_decimals(),
        clock.timestamp_ms() / 1000,
    )
}

/// Build a demo USDT price info object at $1.00
public fun build_demo_usdt_price_info_object(
    scenario: &mut Scenario,
    clock: &Clock,
): PriceInfoObject {
    // USDT at exactly $1.00
    build_pyth_price_info_object(
        scenario,
        test_constants::usdt_price_feed_id(),
        1 * test_constants::pyth_multiplier(),
        50000,
        test_constants::pyth_decimals(),
        clock.timestamp_ms() / 1000,
    )
}

/// Build a BTC price info object at a given price
public fun build_btc_price_info_object(
    scenario: &mut Scenario,
    price_usd: u64,
    clock: &Clock,
): PriceInfoObject {
    build_pyth_price_info_object(
        scenario,
        test_constants::btc_price_feed_id(),
        price_usd * test_constants::pyth_multiplier(),
        1000000,
        test_constants::pyth_decimals(),
        clock.timestamp_ms() / 1000,
    )
}

/// Build a SUI price info object at a given price
public fun build_sui_price_info_object(
    scenario: &mut Scenario,
    price_usd: u64,
    clock: &Clock,
): PriceInfoObject {
    build_pyth_price_info_object(
        scenario,
        test_constants::sui_price_feed_id(),
        price_usd * test_constants::pyth_multiplier(),
        100000,
        test_constants::pyth_decimals(),
        clock.timestamp_ms() / 1000,
    )
}

/// Build a stale BTC price info object (timestamp is stale_seconds before clock time)
public fun build_stale_btc_price_info_object(
    scenario: &mut Scenario,
    price_usd: u64,
    clock: &Clock,
    stale_seconds: u64,
): PriceInfoObject {
    let current_timestamp = clock.timestamp_ms() / 1000;
    let stale_timestamp = if (current_timestamp > stale_seconds) {
        current_timestamp - stale_seconds
    } else {
        0
    };
    build_pyth_price_info_object(
        scenario,
        test_constants::btc_price_feed_id(),
        price_usd * test_constants::pyth_multiplier(),
        1000000,
        test_constants::pyth_decimals(),
        stale_timestamp,
    )
}

/// Build a stale USDC price info object (timestamp is stale_seconds before clock time)
public fun build_stale_usdc_price_info_object(
    scenario: &mut Scenario,
    clock: &Clock,
    stale_seconds: u64,
): PriceInfoObject {
    let current_timestamp = clock.timestamp_ms() / 1000;
    let stale_timestamp = if (current_timestamp > stale_seconds) {
        current_timestamp - stale_seconds
    } else {
        0
    };
    build_pyth_price_info_object(
        scenario,
        test_constants::usdc_price_feed_id(),
        1 * test_constants::pyth_multiplier(),
        50000,
        test_constants::pyth_decimals(),
        stale_timestamp,
    )
}

/// Create a test PythConfig for all test coins
public fun create_test_pyth_config(): PythConfig {
    let mut coin_data_vec = vector[];

    // Add USDC configuration (6 decimals)
    let usdc_data = oracle::test_coin_type_data<test_constants::USDC>(
        6, // decimals
        test_constants::usdc_price_feed_id(),
    );
    coin_data_vec.push_back(usdc_data);

    // Add USDT configuration (6 decimals)
    let usdt_data = oracle::test_coin_type_data<test_constants::USDT>(
        6, // decimals
        test_constants::usdt_price_feed_id(),
    );
    coin_data_vec.push_back(usdt_data);

    // Add BTC configuration (8 decimals)
    let btc_data = oracle::test_coin_type_data<test_constants::BTC>(
        8, // decimals
        test_constants::btc_price_feed_id(),
    );
    coin_data_vec.push_back(btc_data);

    // Add SUI configuration (9 decimals)
    let sui_data = oracle::test_coin_type_data<test_constants::SUI>(
        9, // decimals
        test_constants::sui_price_feed_id(),
    );
    coin_data_vec.push_back(sui_data);

    oracle::new_pyth_config(
        coin_data_vec,
        60, // max age 60 seconds
    )
}

public fun setup_usdc_usdt_deepbook_margin(): (
    Scenario,
    Clock,
    MarginAdminCap,
    MaintainerCap,
    ID,
    ID,
    ID,
    ID,
) {
    let (mut scenario, mut clock, admin_cap, maintainer_cap) = setup_margin_registry();

    clock.set_for_testing(1000000);
    let usdc_pool_id = create_margin_pool<USDC>(
        &mut scenario,
        &maintainer_cap,
        default_protocol_config(),
        &clock,
    );
    let usdt_pool_id = create_margin_pool<USDT>(
        &mut scenario,
        &maintainer_cap,
        default_protocol_config(),
        &clock,
    );

    scenario.next_tx(test_constants::admin());
    let (usdc_pool_cap, usdt_pool_cap) = get_margin_pool_caps(&mut scenario, usdc_pool_id);

    let (pool_id, registry_id) = create_pool_for_testing<USDT, USDC>(&mut scenario);
    scenario.next_tx(test_constants::admin());
    let mut registry = scenario.take_shared<MarginRegistry>();
    enable_deepbook_margin_on_pool<USDT, USDC>(
        pool_id,
        &mut registry,
        &admin_cap,
        &clock,
        &mut scenario,
    );
    return_shared(registry);

    scenario.next_tx(test_constants::admin());
    let mut usdt_pool = scenario.take_shared_by_id<MarginPool<USDT>>(usdt_pool_id);
    let mut usdc_pool = scenario.take_shared_by_id<MarginPool<USDC>>(usdc_pool_id);
    let registry = scenario.take_shared<MarginRegistry>();
    let supplier_cap = margin_pool::mint_supplier_cap(&registry, &clock, scenario.ctx());

    usdc_pool.supply(
        &registry,
        &supplier_cap,
        mint_coin<USDC>(1_000_000 * test_constants::usdc_multiplier(), scenario.ctx()),
        option::none(),
        &clock,
    );
    usdt_pool.supply(
        &registry,
        &supplier_cap,
        mint_coin<USDT>(1_000_000 * test_constants::usdt_multiplier(), scenario.ctx()),
        option::none(),
        &clock,
    );

    usdt_pool.enable_deepbook_pool_for_loan(&registry, pool_id, &usdt_pool_cap, &clock);
    usdc_pool.enable_deepbook_pool_for_loan(&registry, pool_id, &usdc_pool_cap, &clock);

    test::return_shared(usdc_pool);
    test::return_shared(usdt_pool);
    test::return_shared(registry);
    scenario.return_to_sender(usdt_pool_cap);
    scenario.return_to_sender(usdc_pool_cap);
    destroy(supplier_cap);

    (scenario, clock, admin_cap, maintainer_cap, usdc_pool_id, usdt_pool_id, pool_id, registry_id)
}

/// Helper function to set up a complete BTC/USD margin trading environment
/// Returns: (scenario, clock, admin_cap, maintainer_cap, btc_pool_id, usdc_pool_id, deepbook_pool_id, registry_id)
public fun setup_btc_usd_deepbook_margin(): (
    Scenario,
    Clock,
    MarginAdminCap,
    MaintainerCap,
    ID,
    ID,
    ID,
    ID,
) {
    let (mut scenario, mut clock, admin_cap, maintainer_cap) = setup_margin_registry();

    clock.set_for_testing(1000000);
    let btc_pool_id = create_margin_pool<BTC>(
        &mut scenario,
        &maintainer_cap,
        default_protocol_config(),
        &clock,
    );
    let usdc_pool_id = create_margin_pool<USDC>(
        &mut scenario,
        &maintainer_cap,
        default_protocol_config(),
        &clock,
    );

    scenario.next_tx(test_constants::admin());
    let (btc_pool_cap, usdc_pool_cap) = get_margin_pool_caps(&mut scenario, btc_pool_id);

    let (pool_id, registry_id) = create_pool_for_testing<BTC, USDC>(&mut scenario);
    scenario.next_tx(test_constants::admin());
    let mut registry = scenario.take_shared<MarginRegistry>();
    enable_deepbook_margin_on_pool<BTC, USDC>(
        pool_id,
        &mut registry,
        &admin_cap,
        &clock,
        &mut scenario,
    );
    return_shared(registry);

    scenario.next_tx(test_constants::admin());
    let mut btc_pool = scenario.take_shared_by_id<MarginPool<BTC>>(btc_pool_id);
    let mut usdc_pool = scenario.take_shared_by_id<MarginPool<USDC>>(usdc_pool_id);
    let registry = scenario.take_shared<MarginRegistry>();
    let supplier_cap = margin_pool::mint_supplier_cap(&registry, &clock, scenario.ctx());

    btc_pool.supply(
        &registry,
        &supplier_cap,
        mint_coin<BTC>(10 * test_constants::btc_multiplier(), scenario.ctx()),
        option::none(),
        &clock,
    );
    usdc_pool.supply(
        &registry,
        &supplier_cap,
        mint_coin<USDC>(1_000_000 * test_constants::usdc_multiplier(), scenario.ctx()),
        option::none(),
        &clock,
    );

    btc_pool.enable_deepbook_pool_for_loan(&registry, pool_id, &btc_pool_cap, &clock);
    usdc_pool.enable_deepbook_pool_for_loan(&registry, pool_id, &usdc_pool_cap, &clock);

    test::return_shared(btc_pool);
    test::return_shared(usdc_pool);
    test::return_shared(registry);
    scenario.return_to_sender(btc_pool_cap);
    scenario.return_to_sender(usdc_pool_cap);
    destroy(supplier_cap);

    (scenario, clock, admin_cap, maintainer_cap, btc_pool_id, usdc_pool_id, pool_id, registry_id)
}

/// Helper function to set up a complete BTC/SUI margin trading environment
/// Returns: (scenario, clock, admin_cap, maintainer_cap, btc_pool_id, sui_pool_id, deepbook_pool_id, registry_id)
public fun setup_btc_sui_deepbook_margin(): (
    Scenario,
    Clock,
    MarginAdminCap,
    MaintainerCap,
    ID,
    ID,
    ID,
    ID,
) {
    let (mut scenario, mut clock, admin_cap, maintainer_cap) = setup_margin_registry();

    clock.set_for_testing(1000000);
    let btc_pool_id = create_margin_pool<BTC>(
        &mut scenario,
        &maintainer_cap,
        default_protocol_config(),
        &clock,
    );
    let sui_pool_id = create_margin_pool<SUI>(
        &mut scenario,
        &maintainer_cap,
        default_protocol_config(),
        &clock,
    );

    scenario.next_tx(test_constants::admin());
    let (btc_pool_cap, sui_pool_cap) = get_margin_pool_caps(&mut scenario, btc_pool_id);

    let (pool_id, registry_id) = create_pool_for_testing<BTC, SUI>(&mut scenario);
    scenario.next_tx(test_constants::admin());
    let mut registry = scenario.take_shared<MarginRegistry>();
    enable_deepbook_margin_on_pool<BTC, SUI>(
        pool_id,
        &mut registry,
        &admin_cap,
        &clock,
        &mut scenario,
    );
    return_shared(registry);

    scenario.next_tx(test_constants::admin());
    let mut btc_pool = scenario.take_shared_by_id<MarginPool<BTC>>(btc_pool_id);
    let mut sui_pool = scenario.take_shared_by_id<MarginPool<SUI>>(sui_pool_id);
    let registry = scenario.take_shared<MarginRegistry>();
    let supplier_cap = margin_pool::mint_supplier_cap(&registry, &clock, scenario.ctx());

    btc_pool.supply(
        &registry,
        &supplier_cap,
        mint_coin<BTC>(10 * test_constants::btc_multiplier(), scenario.ctx()),
        option::none(),
        &clock,
    );
    sui_pool.supply(
        &registry,
        &supplier_cap,
        mint_coin<SUI>(1_000_000 * test_constants::sui_multiplier(), scenario.ctx()),
        option::none(),
        &clock,
    );

    btc_pool.enable_deepbook_pool_for_loan(&registry, pool_id, &btc_pool_cap, &clock);
    sui_pool.enable_deepbook_pool_for_loan(&registry, pool_id, &sui_pool_cap, &clock);

    test::return_shared(btc_pool);
    test::return_shared(sui_pool);
    test::return_shared(registry);
    scenario.return_to_sender(btc_pool_cap);
    scenario.return_to_sender(sui_pool_cap);
    destroy(supplier_cap);

    (scenario, clock, admin_cap, maintainer_cap, btc_pool_id, sui_pool_id, pool_id, registry_id)
}

public fun advance_time(clock: &mut Clock, ms: u64) {
    let current_time = clock.timestamp_ms();
    clock.set_for_testing(current_time + ms);
}

public fun interest_rate(
    utilization_rate: u64,
    base_rate: u64,
    base_slope: u64,
    optimal_utilization: u64,
    excess_slope: u64,
): u64 {
    if (utilization_rate < optimal_utilization) {
        // Use base slope
        math::mul(utilization_rate, base_slope) + base_rate
    } else {
        // Use base slope and excess slope
        let excess_utilization = utilization_rate - optimal_utilization;
        let excess_rate = math::mul(excess_utilization, excess_slope);

        base_rate + math::mul(optimal_utilization, base_slope) + excess_rate
    }
}

/// Setup a complete margin trading environment with margin manager for pool proxy testing
/// Returns: (scenario, clock, admin_cap, maintainer_cap, base_pool_id, quote_pool_id, deepbook_pool_id, registry_id)
public fun setup_pool_proxy_test_env<BaseAsset, QuoteAsset>(): (
    Scenario,
    Clock,
    MarginAdminCap,
    MaintainerCap,
    ID,
    ID,
    ID,
    ID,
) {
    let (mut scenario, mut clock, admin_cap, maintainer_cap) = setup_margin_registry();

    clock.set_for_testing(1000000);

    // Create margin pools
    let base_pool_id = create_margin_pool<BaseAsset>(
        &mut scenario,
        &maintainer_cap,
        default_protocol_config(),
        &clock,
    );
    let quote_pool_id = create_margin_pool<QuoteAsset>(
        &mut scenario,
        &maintainer_cap,
        default_protocol_config(),
        &clock,
    );

    // Get pool caps
    let (base_pool_cap, quote_pool_cap) = get_margin_pool_caps(&mut scenario, base_pool_id);

    // Create DeepBook pool
    let (pool_id, registry_id) = create_pool_for_testing<BaseAsset, QuoteAsset>(&mut scenario);

    // Enable margin trading
    scenario.next_tx(test_constants::admin());
    let mut registry = scenario.take_shared<MarginRegistry>();
    enable_deepbook_margin_on_pool<BaseAsset, QuoteAsset>(
        pool_id,
        &mut registry,
        &admin_cap,
        &clock,
        &mut scenario,
    );
    return_shared(registry);

    // Setup liquidity for margin pools
    scenario.next_tx(test_constants::admin());
    let mut base_pool = scenario.take_shared_by_id<MarginPool<BaseAsset>>(base_pool_id);
    let mut quote_pool = scenario.take_shared_by_id<MarginPool<QuoteAsset>>(quote_pool_id);
    let registry = scenario.take_shared<MarginRegistry>();
    let supplier_cap = margin_pool::mint_supplier_cap(&registry, &clock, scenario.ctx());

    base_pool.supply(
        &registry,
        &supplier_cap,
        mint_coin<BaseAsset>(1_000_000 * test_constants::usdc_multiplier(), scenario.ctx()),
        option::none(),
        &clock,
    );
    quote_pool.supply(
        &registry,
        &supplier_cap,
        mint_coin<QuoteAsset>(1_000_000 * test_constants::usdt_multiplier(), scenario.ctx()),
        option::none(),
        &clock,
    );

    base_pool.enable_deepbook_pool_for_loan(&registry, pool_id, &base_pool_cap, &clock);
    quote_pool.enable_deepbook_pool_for_loan(&registry, pool_id, &quote_pool_cap, &clock);

    return_shared_2!(base_pool, quote_pool);
    return_shared(registry);
    return_to_sender_2!(&scenario, base_pool_cap, quote_pool_cap);
    destroy(supplier_cap);

    (scenario, clock, admin_cap, maintainer_cap, base_pool_id, quote_pool_id, pool_id, registry_id)
}
