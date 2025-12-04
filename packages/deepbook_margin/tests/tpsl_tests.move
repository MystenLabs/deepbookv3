// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module deepbook_margin::tpsl_tests;

use deepbook::constants;
use deepbook::pool::Pool;
use deepbook::registry::Registry;
use deepbook_margin::margin_manager::{Self, MarginManager};
use deepbook_margin::margin_pool;
use deepbook_margin::margin_registry::{MarginRegistry, MarginAdminCap, MaintainerCap};
use deepbook_margin::test_constants::{Self, SUI, USDC};
use deepbook_margin::test_helpers::{
    setup_margin_registry,
    create_margin_pool,
    default_protocol_config,
    get_margin_pool_caps,
    create_pool_for_testing,
    enable_deepbook_margin_on_pool,
    cleanup_margin_test,
    mint_coin,
    build_pyth_price_info_object,
    destroy_2,
    return_shared_2
};
use deepbook_margin::tpsl;
use std::unit_test::destroy;
use sui::test_scenario::{Self, return_shared};

// Helper to create a SUI/USDC margin trading environment
// SUI has 9 decimals, USDC has 6 decimals
// Price of $1 = 10^12 (since math::mul(10^12, 10^6 USDC quantity) = 10^9 which is 1 SUI)
fun setup_sui_usdc_deepbook_margin(): (
    test_scenario::Scenario,
    sui::clock::Clock,
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
    let sui_pool_id = create_margin_pool<SUI>(
        &mut scenario,
        &maintainer_cap,
        default_protocol_config(),
        &clock,
    );

    scenario.next_tx(test_constants::admin());
    let (usdc_pool_cap, sui_pool_cap) = get_margin_pool_caps(&mut scenario, usdc_pool_id);

    let (pool_id, registry_id) = create_pool_for_testing<SUI, USDC>(&mut scenario);
    scenario.next_tx(test_constants::admin());
    let mut registry = scenario.take_shared<MarginRegistry>();
    enable_deepbook_margin_on_pool<SUI, USDC>(
        pool_id,
        &mut registry,
        &admin_cap,
        &clock,
        &mut scenario,
    );
    return_shared(registry);

    scenario.next_tx(test_constants::admin());
    let mut sui_pool = scenario.take_shared_by_id<margin_pool::MarginPool<SUI>>(sui_pool_id);
    let mut usdc_pool = scenario.take_shared_by_id<margin_pool::MarginPool<USDC>>(usdc_pool_id);
    let registry = scenario.take_shared<MarginRegistry>();
    let supplier_cap = margin_pool::mint_supplier_cap(&registry, &clock, scenario.ctx());

    usdc_pool.supply(
        &registry,
        &supplier_cap,
        mint_coin<USDC>(1_000_000 * test_constants::usdc_multiplier(), scenario.ctx()),
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

    sui_pool.enable_deepbook_pool_for_loan(&registry, pool_id, &sui_pool_cap, &clock);
    usdc_pool.enable_deepbook_pool_for_loan(&registry, pool_id, &usdc_pool_cap, &clock);

    test_scenario::return_shared(usdc_pool);
    test_scenario::return_shared(sui_pool);
    test_scenario::return_shared(registry);
    scenario.return_to_sender(sui_pool_cap);
    scenario.return_to_sender(usdc_pool_cap);
    destroy(supplier_cap);

    (scenario, clock, admin_cap, maintainer_cap, usdc_pool_id, sui_pool_id, pool_id, registry_id)
}

// Helper to build price info objects with specific prices
// For SUI: price_usd is in cents (e.g., 100 = $1.00, 95 = $0.95, 200 = $2.00)
fun build_sui_price_info_object_with_price(
    scenario: &mut test_scenario::Scenario,
    price_cents: u64,
    clock: &sui::clock::Clock,
): pyth::price_info::PriceInfoObject {
    build_pyth_price_info_object(
        scenario,
        test_constants::sui_price_feed_id(),
        price_cents * test_constants::pyth_multiplier() / 100, // Convert cents to Pyth format
        50000,
        test_constants::pyth_decimals(),
        clock.timestamp_ms() / 1000,
    )
}

// Helper to build USDC price info object (always $1.00)
fun build_usdc_price_info_object(
    scenario: &mut test_scenario::Scenario,
    clock: &sui::clock::Clock,
): pyth::price_info::PriceInfoObject {
    build_pyth_price_info_object(
        scenario,
        test_constants::usdc_price_feed_id(),
        1 * test_constants::pyth_multiplier(), // $1.00
        50000,
        test_constants::pyth_decimals(),
        clock.timestamp_ms() / 1000,
    )
}

#[test]
fun test_tpsl_trigger_below_executed() {
    // This test demonstrates a stop-loss scenario where ALICE sets up a conditional order
    // to sell SUI when its price drops below a trigger price.
    //
    // Setup:
    // - ALICE deposits 10,000 SUI as collateral when SUI = $2.00
    // - ALICE creates a stop-loss order: if SUI price drops below $1.50, sell 100 SUI at $0.80
    // - BOB triggers the order execution when SUI price drops to $0.95
    //
    // Price calculations (SUI has 9 decimals, USDC has 6 decimals):
    // - Oracle price = (SUI_USD_price / USDC_USD_price) * float_scaling * 10^(9-6)
    // - $2.00 SUI = 2.0 * 10^9 * 10^3 = 2_000_000_000_000
    // - $1.50 trigger = 1.5 * 10^9 * 10^3 = 1_500_000_000_000
    // - $0.95 SUI = 0.95 * 10^9 * 10^3 = 950_000_000_000

    let (
        mut scenario,
        clock,
        admin_cap,
        maintainer_cap,
        _usdc_pool_id,
        _sui_pool_id,
        _pool_id,
        registry_id,
    ) = setup_sui_usdc_deepbook_margin();

    // USER1 = ALICE creates a margin manager
    scenario.next_tx(test_constants::user1());
    let mut margin_registry = scenario.take_shared<MarginRegistry>();
    let pool = scenario.take_shared<Pool<SUI, USDC>>();
    let deepbook_registry = scenario.take_shared_by_id<Registry>(registry_id);
    margin_manager::new<SUI, USDC>(
        &pool,
        &deepbook_registry,
        &mut margin_registry,
        &clock,
        scenario.ctx(),
    );
    return_shared(deepbook_registry);
    return_shared(pool);

    scenario.next_tx(test_constants::user1());
    let mut mm = scenario.take_shared<MarginManager<SUI, USDC>>();
    let pool = scenario.take_shared<Pool<SUI, USDC>>();

    // Initial prices: SUI = $2.00, USDC = $1.00
    // Oracle price calculation:
    // Price = (base_USD / quote_USD) * float_scaling * 10^(base_decimals - quote_decimals)
    // = (2.00 / 1.00) * 10^9 * 10^3 = 2 * 10^12 = 2_000_000_000_000
    let sui_price_high = build_sui_price_info_object_with_price(&mut scenario, 200, &clock); // $2.00
    let usdc_price = build_usdc_price_info_object(&mut scenario, &clock); // $1.00

    // Deposit collateral (SUI)
    mm.deposit<SUI, USDC, SUI>(
        &margin_registry,
        &sui_price_high,
        &usdc_price,
        mint_coin<SUI>(10000 * test_constants::sui_multiplier(), scenario.ctx()),
        &clock,
        scenario.ctx(),
    );

    // Add conditional order: trigger_is_below = true, trigger_price = $1.50
    // This means: trigger when SUI price drops below $1.50
    // When triggered, SELL SUI (is_bid = false) to protect against further losses
    // Trigger price = (1.50 / 1.00) * 10^9 * 10^3 = 1.5 * 10^12 = 1_500_000_000_000
    let condition = tpsl::new_condition(
        true, // trigger_is_below
        1_500_000_000_000, // trigger price: $1.50
    );
    let pending_order = tpsl::new_pending_limit_order(
        1, // client_order_id
        constants::no_restriction(),
        constants::self_matching_allowed(),
        800_000_000_000, // price: $0.80 (sell when price drops)
        100 * test_constants::sui_multiplier(), // quantity: 100 SUI
        false, // is_bid = false (SELL SUI for USDC)
        false, // pay_with_deep
        constants::max_u64(), // expire_timestamp
    );

    mm.add_conditional_order<SUI, USDC>(
        &pool,
        &sui_price_high,
        &usdc_price,
        &margin_registry,
        1, // conditional_order_identifier
        condition,
        pending_order,
        &clock,
        scenario.ctx(),
    );

    // Verify conditional order was added
    assert!(margin_manager::conditional_order_ids(&mm).length() == 1);

    destroy_2!(sui_price_high, usdc_price);
    return_shared(pool);
    return_shared(margin_registry);

    // USER2 = BOB executes conditional orders with oracle price that triggers the condition
    // Update price to trigger: SUI drops to $0.95 < $1.50 trigger
    // Oracle price = (0.95 / 1.00) * 10^9 * 10^3 = 0.95 * 10^12 = 950_000_000_000
    scenario.next_tx(test_constants::user2());
    let sui_price_low = build_sui_price_info_object_with_price(&mut scenario, 95, &clock); // $0.95
    let usdc_price = build_usdc_price_info_object(&mut scenario, &clock);

    let mut pool = scenario.take_shared<Pool<SUI, USDC>>();
    let margin_registry = scenario.take_shared<MarginRegistry>();

    // Execute conditional orders - should trigger and place order
    let order_infos = mm.execute_conditional_orders<SUI, USDC>(
        &mut pool,
        &sui_price_low,
        &usdc_price,
        &margin_registry,
        10, // max_orders_to_execute
        &clock,
        scenario.ctx(),
    );

    // Verify order was executed
    assert!(order_infos.length() == 1, 0);
    destroy(order_infos[0]);

    // Verify conditional order was removed after execution
    assert!(margin_manager::conditional_order_ids(&mm).length() == 0, 1);

    destroy_2!(sui_price_low, usdc_price);
    return_shared_2!(mm, pool);

    let deepbook_registry = scenario.take_shared_by_id<Registry>(registry_id);
    return_shared(deepbook_registry);
    cleanup_margin_test(margin_registry, admin_cap, maintainer_cap, clock, scenario);
}
