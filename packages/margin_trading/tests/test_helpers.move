// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module margin_trading::test_helpers;

use deepbook::{constants, pool::{Self, Pool}, registry::{Self, Registry}};
use margin_trading::{
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
    test_constants::{Self, USDC, BTC}
};
use pyth::{i64, price, price_feed, price_identifier, price_info::{Self, PriceInfoObject}};
use sui::{
    clock::{Self, Clock},
    coin::{Self, Coin},
    test_scenario::{Self as test, Scenario, begin, return_shared},
    test_utils::destroy
};
use token::deep::DEEP;

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
    clock.set_for_testing(1000);

    scenario.next_tx(test_constants::admin());
    let mut registry = scenario.take_shared<MarginRegistry>();
    let maintainer_cap = registry.mint_maintainer_cap(&admin_cap, &clock, scenario.ctx());
    let pyth_config = create_test_pyth_config();
    registry.add_config(&admin_cap, pyth_config);
    return_shared(registry);

    (scenario, clock, admin_cap, maintainer_cap)
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

public fun default_protocol_config(): ProtocolConfig {
    let margin_pool_config = protocol_config::new_margin_pool_config(
        test_constants::supply_cap(),
        test_constants::max_utilization_rate(),
        test_constants::protocol_spread(),
    );
    let interest_config = protocol_config::new_interest_config(
        test_constants::base_rate(), // base_rate: 5% with 9 decimals
        test_constants::base_slope(), // base_slope: 10% with 9 decimals
        test_constants::optimal_utilization(), // optimal_utilization: 80% with 9 decimals
        test_constants::excess_slope(), // excess_slope: 200% with 9 decimals
    );

    protocol_config::new_protocol_config(margin_pool_config, interest_config)
}

public fun mint_coin<T>(amount: u64, ctx: &mut TxContext): Coin<T> {
    coin::mint_for_testing<T>(amount, ctx)
}

/// Create a DeepBook pool for testing
public fun create_pool_for_testing<BaseAsset, QuoteAsset>(scenario: &mut Scenario): ID {
    let registry_id = registry::test_registry(scenario.ctx());

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
    pool_id
}

/// Enable margin trading on a DeepBook pool
public fun enable_margin_trading_on_pool<BaseAsset, QuoteAsset>(
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
        100000000,
        50000,
        8,
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
        100000000,
        50000,
        8,
        clock.timestamp_ms() / 1000,
    )
}

/// Build a BTC price info object at a given price
public fun build_btc_price_info_object(
    scenario: &mut Scenario,
    price_usd: u64,
    clock: &Clock,
): PriceInfoObject {
    // BTC price with 8 decimal places (e.g., 60000_00000000 = $60,000)
    build_pyth_price_info_object(
        scenario,
        test_constants::btc_price_feed_id(),
        price_usd * 100000000,
        1000000,
        8,
        clock.timestamp_ms() / 1000,
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

    oracle::new_pyth_config(
        coin_data_vec,
        60, // max age 60 seconds
    )
}

/// Helper function to set up a complete BTC/USD margin trading environment
/// Returns: (scenario, clock, admin_cap, maintainer_cap, btc_pool_id, usdc_pool_id, deepbook_pool_id)
public fun setup_btc_usd_margin_trading(): (
    Scenario,
    Clock,
    MarginAdminCap,
    MaintainerCap,
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
    let cap1 = scenario.take_from_sender<MarginPoolCap>();
    let cap2 = scenario.take_from_sender<MarginPoolCap>();

    let (btc_pool_cap, usdc_pool_cap) = if (cap1.margin_pool_id() == btc_pool_id) {
        (cap1, cap2)
    } else {
        (cap2, cap1)
    };

    let pool_id = create_pool_for_testing<BTC, USDC>(&mut scenario);
    scenario.next_tx(test_constants::admin());
    let mut registry = scenario.take_shared<MarginRegistry>();
    enable_margin_trading_on_pool<BTC, USDC>(
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

    btc_pool.supply(
        &registry,
        mint_coin<BTC>(10 * test_constants::btc_multiplier(), scenario.ctx()),
        &clock,
        scenario.ctx(),
    );
    usdc_pool.supply(
        &registry,
        mint_coin<USDC>(1_000_000 * test_constants::usdc_multiplier(), scenario.ctx()),
        &clock,
        scenario.ctx(),
    );

    btc_pool.enable_deepbook_pool_for_loan(&registry, pool_id, &btc_pool_cap, &clock);
    usdc_pool.enable_deepbook_pool_for_loan(&registry, pool_id, &usdc_pool_cap, &clock);

    test::return_shared(btc_pool);
    test::return_shared(usdc_pool);
    test::return_shared(registry);
    scenario.return_to_sender(btc_pool_cap);
    scenario.return_to_sender(usdc_pool_cap);

    (scenario, clock, admin_cap, maintainer_cap, btc_pool_id, usdc_pool_id, pool_id)
}
