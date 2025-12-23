// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module deepbook_margin::tpsl_tests;

use deepbook::{constants, pool::Pool, registry::Registry};
use deepbook_margin::{
    margin_manager::{Self, MarginManager},
    margin_pool,
    margin_registry::{MarginRegistry, MarginAdminCap, MaintainerCap},
    test_constants::{Self, SUI, USDC},
    test_helpers::{
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
    },
    tpsl
};
use std::unit_test::destroy;
use sui::test_scenario::{Self, return_shared};

// Helper to create a SUI/USDC margin trading environment
// SUI has 9 decimals, USDC has 6 decimals
// Price of $1 = 10^6 (since SUI has 9 decimals and USDC has 6 decimals, price = USD * 10^9 / 10^3)
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

// Helper to set up orderbook liquidity
fun setup_orderbook_liquidity<BaseAsset, QuoteAsset>(
    scenario: &mut test_scenario::Scenario,
    pool_id: ID,
    clock: &sui::clock::Clock,
) {
    use deepbook::balance_manager;
    use token::deep::DEEP;

    scenario.next_tx(test_constants::user2());
    let mut pool = scenario.take_shared_by_id<Pool<BaseAsset, QuoteAsset>>(pool_id);
    let mut balance_manager = balance_manager::new(scenario.ctx());

    // Deposit plenty of assets for liquidity provision
    balance_manager.deposit(
        mint_coin<BaseAsset>(1000 * test_constants::sui_multiplier(), scenario.ctx()),
        scenario.ctx(),
    );
    balance_manager.deposit(
        mint_coin<QuoteAsset>(
            1_000_000_000 * test_constants::usdc_multiplier(),
            scenario.ctx(),
        ), // 1B USDC
        scenario.ctx(),
    );
    balance_manager.deposit(
        mint_coin<DEEP>(10000 * test_constants::deep_multiplier(), scenario.ctx()),
        scenario.ctx(),
    );

    let trade_proof = balance_manager.generate_proof_as_owner(scenario.ctx());

    // Place ask orders (sell SUI) at different prices
    // Price in oracle terms: (USD_price / USDC_price) * 10^9 / 10^3
    pool.place_limit_order<BaseAsset, QuoteAsset>(
        &mut balance_manager,
        &trade_proof,
        1,
        constants::no_restriction(),
        constants::self_matching_allowed(),
        2_500_000, // $2.50
        100 * test_constants::sui_multiplier(),
        false, // is_bid = false (ask)
        false,
        constants::max_u64(),
        clock,
        scenario.ctx(),
    );

    pool.place_limit_order<BaseAsset, QuoteAsset>(
        &mut balance_manager,
        &trade_proof,
        2,
        constants::no_restriction(),
        constants::self_matching_allowed(),
        3_000_000, // $3.00
        100 * test_constants::sui_multiplier(),
        false, // is_bid = false (ask)
        false,
        constants::max_u64(),
        clock,
        scenario.ctx(),
    );

    // Place bid orders (buy SUI) at different prices
    pool.place_limit_order<BaseAsset, QuoteAsset>(
        &mut balance_manager,
        &trade_proof,
        3,
        constants::no_restriction(),
        constants::self_matching_allowed(),
        1_500_000, // $1.50
        100 * test_constants::sui_multiplier(),
        true, // is_bid = true
        false,
        constants::max_u64(),
        clock,
        scenario.ctx(),
    );

    pool.place_limit_order<BaseAsset, QuoteAsset>(
        &mut balance_manager,
        &trade_proof,
        4,
        constants::no_restriction(),
        constants::self_matching_allowed(),
        1_000_000, // $1.00
        100 * test_constants::sui_multiplier(),
        true, // is_bid = true
        false,
        constants::max_u64(),
        clock,
        scenario.ctx(),
    );

    let _balance_manager_id = balance_manager.id();
    transfer::public_share_object(balance_manager);
    return_shared(pool);
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
    // - $2.00 SUI = 2.0 * 10^9 / 10^3 = 2_000_000
    // - $1.50 trigger = 1.5 * 10^9 / 10^3 = 1_500_000
    // - $0.95 SUI = 0.95 * 10^9 / 10^3 = 950_000

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
    // = (2.00 / 1.00) * 10^9 / 10^3 = 2 * 10^6 = 2_000_000
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
    // Trigger price = (1.50 / 1.00) * 10^9 / 10^3 = 1.5 * 10^6 = 1_500_000
    let condition = tpsl::new_condition(
        true, // trigger_is_below
        1_500_000, // trigger price: $1.50
    );
    let pending_order = tpsl::new_pending_limit_order(
        1, // client_order_id
        constants::no_restriction(),
        constants::self_matching_allowed(),
        800_000, // price: $0.80 (sell when price drops)
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
    assert!(mm.conditional_order_ids().length() == 1);

    destroy_2!(sui_price_high, usdc_price);
    return_shared(pool);
    return_shared(margin_registry);

    // USER2 = BOB executes conditional orders with oracle price that triggers the condition
    // Update price to trigger: SUI drops to $0.95 < $1.50 trigger
    // Oracle price = (0.95 / 1.00) * 10^9 / 10^3 = 0.95 * 10^6 = 950_000
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

    // Verify order was executed with accurate data
    assert!(order_infos.length() == 1);
    let order_info = &order_infos[0];

    // Validate order details
    assert!(order_info.client_order_id() == 1); // client_order_id from pending_order
    assert!(order_info.price() == 800_000); // price: $0.80
    assert!(order_info.original_quantity() == 100 * test_constants::sui_multiplier()); // 100 SUI
    assert!(order_info.is_bid() == false); // Sell order
    assert!(order_info.balance_manager_id() == object::id(mm.balance_manager()));

    destroy(order_infos[0]);

    // Verify conditional order was removed after execution
    assert!(mm.conditional_order_ids().length() == 0);

    destroy_2!(sui_price_low, usdc_price);
    return_shared_2!(mm, pool);

    let deepbook_registry = scenario.take_shared_by_id<Registry>(registry_id);
    return_shared(deepbook_registry);
    cleanup_margin_test(margin_registry, admin_cap, maintainer_cap, clock, scenario);
}

#[test]
fun test_tpsl_trigger_above_executed() {
    // This test demonstrates a take-profit scenario where ALICE sets up a conditional order
    // to sell SUI when its price rises above a trigger price.
    //
    // Setup:
    // - ALICE deposits 10,000 SUI as collateral when SUI = $1.50
    // - ALICE creates a take-profit order: if SUI price rises above $2.00, sell 100 SUI at $2.50
    // - BOB triggers the order execution when SUI price rises to $2.10
    //
    // Price calculations (SUI has 9 decimals, USDC has 6 decimals):
    // - Oracle price = (SUI_USD_price / USDC_USD_price) * float_scaling * 10^(9-6)
    // - $1.50 SUI = 1.5 * 10^9 / 10^3 = 1_500_000
    // - $2.00 trigger = 2.0 * 10^9 / 10^3 = 2_000_000
    // - $2.10 SUI = 2.1 * 10^9 / 10^3 = 2_100_000

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

    // Initial prices: SUI = $1.50, USDC = $1.00
    // Oracle price calculation:
    // Price = (base_USD / quote_USD) * float_scaling * 10^(base_decimals - quote_decimals)
    // = (1.50 / 1.00) * 10^9 / 10^3 = 1.5 * 10^6 = 1_500_000
    let sui_price_low = build_sui_price_info_object_with_price(&mut scenario, 150, &clock); // $1.50
    let usdc_price = build_usdc_price_info_object(&mut scenario, &clock); // $1.00

    // Deposit collateral (SUI)
    mm.deposit<SUI, USDC, SUI>(
        &margin_registry,
        &sui_price_low,
        &usdc_price,
        mint_coin<SUI>(10000 * test_constants::sui_multiplier(), scenario.ctx()),
        &clock,
        scenario.ctx(),
    );

    // Add conditional order: trigger_is_below = false, trigger_price = $2.00
    // This means: trigger when SUI price rises above $2.00
    // When triggered, SELL SUI (is_bid = false) to take profits
    // Trigger price = (2.00 / 1.00) * 10^9 / 10^3 = 2.0 * 10^6 = 2_000_000
    let condition = tpsl::new_condition(
        false, // trigger_is_below = false (trigger_above)
        2_000_000, // trigger price: $2.00
    );
    let pending_order = tpsl::new_pending_limit_order(
        1, // client_order_id
        constants::no_restriction(),
        constants::self_matching_allowed(),
        2_500_000, // price: $2.50 (sell at higher price)
        100 * test_constants::sui_multiplier(), // quantity: 100 SUI
        false, // is_bid = false (SELL SUI for USDC)
        false, // pay_with_deep
        constants::max_u64(), // expire_timestamp
    );

    mm.add_conditional_order<SUI, USDC>(
        &pool,
        &sui_price_low,
        &usdc_price,
        &margin_registry,
        1, // conditional_order_identifier
        condition,
        pending_order,
        &clock,
        scenario.ctx(),
    );

    // Verify conditional order was added
    assert!(mm.conditional_order_ids().length() == 1);

    destroy_2!(sui_price_low, usdc_price);
    return_shared(pool);
    return_shared(margin_registry);

    // USER2 = BOB executes conditional orders with oracle price that triggers the condition
    // Update price to trigger: SUI rises to $2.10 > $2.00 trigger
    // Oracle price = (2.10 / 1.00) * 10^9 / 10^3 = 2.1 * 10^6 = 2_100_000
    scenario.next_tx(test_constants::user2());
    let sui_price_high = build_sui_price_info_object_with_price(&mut scenario, 210, &clock); // $2.10
    let usdc_price = build_usdc_price_info_object(&mut scenario, &clock);

    let mut pool = scenario.take_shared<Pool<SUI, USDC>>();
    let margin_registry = scenario.take_shared<MarginRegistry>();

    // Execute conditional orders - should trigger and place order
    let order_infos = mm.execute_conditional_orders<SUI, USDC>(
        &mut pool,
        &sui_price_high,
        &usdc_price,
        &margin_registry,
        10, // max_orders_to_execute
        &clock,
        scenario.ctx(),
    );

    // Verify order was executed with accurate data
    assert!(order_infos.length() == 1);
    let order_info = &order_infos[0];

    // Validate order details
    assert!(order_info.client_order_id() == 1); // client_order_id from pending_order
    assert!(order_info.price() == 2_500_000); // price: $2.50
    assert!(order_info.original_quantity() == 100 * test_constants::sui_multiplier()); // 100 SUI
    assert!(order_info.is_bid() == false); // Sell order
    assert!(order_info.balance_manager_id() == object::id(mm.balance_manager()));

    destroy(order_infos[0]);

    // Verify conditional order was removed after execution
    assert!(mm.conditional_order_ids().length() == 0);

    destroy_2!(sui_price_high, usdc_price);
    return_shared_2!(mm, pool);

    let deepbook_registry = scenario.take_shared_by_id<Registry>(registry_id);
    return_shared(deepbook_registry);
    cleanup_margin_test(margin_registry, admin_cap, maintainer_cap, clock, scenario);
}

#[test]
fun test_tpsl_orders_sorted_correctly() {
    // This test verifies that conditional orders are correctly sorted:
    // - trigger_below orders: sorted high to low by trigger_price
    // - trigger_above orders: sorted low to high by trigger_price
    //
    // ALICE adds 8 conditional orders at different trigger prices and verifies the sorting.

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
    let sui_price = build_sui_price_info_object_with_price(&mut scenario, 200, &clock); // $2.00
    let usdc_price = build_usdc_price_info_object(&mut scenario, &clock); // $1.00

    // Deposit collateral (SUI)
    mm.deposit<SUI, USDC, SUI>(
        &margin_registry,
        &sui_price,
        &usdc_price,
        mint_coin<SUI>(10000 * test_constants::sui_multiplier(), scenario.ctx()),
        &clock,
        scenario.ctx(),
    );

    // Add 4 trigger_below orders at different prices (intentionally out of order)
    // Expected sorted order (high to low): 1.8, 1.5, 1.2, 0.9
    let trigger_prices_below = vector[
        1_500_000, // $1.50 - ID 1
        900_000, // $0.90 - ID 2
        1_800_000, // $1.80 - ID 3
        1_200_000, // $1.20 - ID 4
    ];

    let mut i = 0;
    while (i < trigger_prices_below.length()) {
        let condition = tpsl::new_condition(
            true, // trigger_is_below
            trigger_prices_below[i],
        );
        let pending_order = tpsl::new_pending_limit_order(
            i + 1, // client_order_id
            constants::no_restriction(),
            constants::self_matching_allowed(),
            800_000, // price: $0.80
            100 * test_constants::sui_multiplier(),
            false, // is_bid = false (SELL)
            false,
            constants::max_u64(),
        );

        mm.add_conditional_order<SUI, USDC>(
            &pool,
            &sui_price,
            &usdc_price,
            &margin_registry,
            i + 1, // conditional_order_id
            condition,
            pending_order,
            &clock,
            scenario.ctx(),
        );
        i = i + 1;
    };

    // Add 4 trigger_above orders at different prices (intentionally out of order)
    // Expected sorted order (low to high): 2.2, 2.5, 2.8, 3.1
    let trigger_prices_above = vector[
        2_500_000, // $2.50 - ID 5
        3_100_000, // $3.10 - ID 6
        2_200_000, // $2.20 - ID 7
        2_800_000, // $2.80 - ID 8
    ];

    i = 0;
    while (i < trigger_prices_above.length()) {
        let condition = tpsl::new_condition(
            false, // trigger_is_below = false (trigger_above)
            trigger_prices_above[i],
        );
        let pending_order = tpsl::new_pending_limit_order(
            i + 5, // client_order_id (5, 6, 7, 8)
            constants::no_restriction(),
            constants::self_matching_allowed(),
            3_500_000, // price: $3.50
            100 * test_constants::sui_multiplier(),
            false, // is_bid = false (SELL)
            false,
            constants::max_u64(),
        );

        mm.add_conditional_order<SUI, USDC>(
            &pool,
            &sui_price,
            &usdc_price,
            &margin_registry,
            i + 5, // conditional_order_id (5, 6, 7, 8)
            condition,
            pending_order,
            &clock,
            scenario.ctx(),
        );
        i = i + 1;
    };

    // Verify all 8 orders were added
    let order_ids = mm.conditional_order_ids();
    assert!(order_ids.length() == 8);

    // Verify trigger_below orders are sorted high to low
    // Expected order: ID 3 ($1.80), ID 1 ($1.50), ID 4 ($1.20), ID 2 ($0.90)
    let order_1 = mm.conditional_order(order_ids[0]);
    let order_2 = mm.conditional_order(order_ids[1]);
    let order_3 = mm.conditional_order(order_ids[2]);
    let order_4 = mm.conditional_order(order_ids[3]);

    assert!(order_1.condition().trigger_below_price() == true);
    assert!(order_2.condition().trigger_below_price() == true);
    assert!(order_3.condition().trigger_below_price() == true);
    assert!(order_4.condition().trigger_below_price() == true);

    assert!(order_1.condition().trigger_price() == 1_800_000); // $1.80 (highest)
    assert!(order_2.condition().trigger_price() == 1_500_000); // $1.50
    assert!(order_3.condition().trigger_price() == 1_200_000); // $1.20
    assert!(order_4.condition().trigger_price() == 900_000); // $0.90 (lowest)

    // Verify decreasing order (high to low)
    assert!(order_1.condition().trigger_price() > order_2.condition().trigger_price());
    assert!(order_2.condition().trigger_price() > order_3.condition().trigger_price());
    assert!(order_3.condition().trigger_price() > order_4.condition().trigger_price());

    // Verify trigger_above orders are sorted low to high
    // Expected order: ID 7 ($2.20), ID 5 ($2.50), ID 8 ($2.80), ID 6 ($3.10)
    let order_5 = mm.conditional_order(order_ids[4]);
    let order_6 = mm.conditional_order(order_ids[5]);
    let order_7 = mm.conditional_order(order_ids[6]);
    let order_8 = mm.conditional_order(order_ids[7]);

    assert!(order_5.condition().trigger_below_price() == false);
    assert!(order_6.condition().trigger_below_price() == false);
    assert!(order_7.condition().trigger_below_price() == false);
    assert!(order_8.condition().trigger_below_price() == false);

    assert!(order_5.condition().trigger_price() == 2_200_000); // $2.20 (lowest)
    assert!(order_6.condition().trigger_price() == 2_500_000); // $2.50
    assert!(order_7.condition().trigger_price() == 2_800_000); // $2.80
    assert!(order_8.condition().trigger_price() == 3_100_000); // $3.10 (highest)

    // Verify increasing order (low to high)
    assert!(order_5.condition().trigger_price() < order_6.condition().trigger_price());
    assert!(order_6.condition().trigger_price() < order_7.condition().trigger_price());
    assert!(order_7.condition().trigger_price() < order_8.condition().trigger_price());

    destroy_2!(sui_price, usdc_price);
    return_shared_2!(mm, pool);

    scenario.next_tx(test_constants::user1());
    let deepbook_registry = scenario.take_shared_by_id<Registry>(registry_id);
    return_shared(deepbook_registry);
    cleanup_margin_test(margin_registry, admin_cap, maintainer_cap, clock, scenario);
}

#[test]
fun test_tpsl_orders_with_same_trigger_price_maintain_fifo_order() {
    // This test verifies that the sort is stable: orders with the same trigger price
    // maintain their insertion order (FIFO - first in, first out).
    // The insertion_sort_by! macro requires >= and <= comparisons for stability.

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

    let sui_price = build_sui_price_info_object_with_price(&mut scenario, 200, &clock); // $2.00
    let usdc_price = build_usdc_price_info_object(&mut scenario, &clock); // $1.00

    mm.deposit<SUI, USDC, SUI>(
        &margin_registry,
        &sui_price,
        &usdc_price,
        mint_coin<SUI>(10000 * test_constants::sui_multiplier(), scenario.ctx()),
        &clock,
        scenario.ctx(),
    );

    // Add two trigger_below orders with the SAME trigger price
    // Order ID 1 added first, Order ID 2 added second
    let same_trigger_below_price = 1_500_000; // $1.50

    let condition_1 = tpsl::new_condition(true, same_trigger_below_price);
    let pending_order_1 = tpsl::new_pending_limit_order(
        1,
        constants::no_restriction(),
        constants::self_matching_allowed(),
        800_000,
        100 * test_constants::sui_multiplier(),
        false,
        false,
        constants::max_u64(),
    );
    mm.add_conditional_order<SUI, USDC>(
        &pool,
        &sui_price,
        &usdc_price,
        &margin_registry,
        1, // conditional_order_id
        condition_1,
        pending_order_1,
        &clock,
        scenario.ctx(),
    );

    let condition_2 = tpsl::new_condition(true, same_trigger_below_price);
    let pending_order_2 = tpsl::new_pending_limit_order(
        2,
        constants::no_restriction(),
        constants::self_matching_allowed(),
        800_000_000_000,
        100 * test_constants::sui_multiplier(),
        false,
        false,
        constants::max_u64(),
    );
    mm.add_conditional_order<SUI, USDC>(
        &pool,
        &sui_price,
        &usdc_price,
        &margin_registry,
        2, // conditional_order_id
        condition_2,
        pending_order_2,
        &clock,
        scenario.ctx(),
    );

    // Add two trigger_above orders with the SAME trigger price
    // Order ID 3 added first, Order ID 4 added second
    let same_trigger_above_price = 2_500_000_000_000; // $2.50

    let condition_3 = tpsl::new_condition(false, same_trigger_above_price);
    let pending_order_3 = tpsl::new_pending_limit_order(
        3,
        constants::no_restriction(),
        constants::self_matching_allowed(),
        3_000_000_000_000,
        100 * test_constants::sui_multiplier(),
        false,
        false,
        constants::max_u64(),
    );
    mm.add_conditional_order<SUI, USDC>(
        &pool,
        &sui_price,
        &usdc_price,
        &margin_registry,
        3, // conditional_order_id
        condition_3,
        pending_order_3,
        &clock,
        scenario.ctx(),
    );

    let condition_4 = tpsl::new_condition(false, same_trigger_above_price);
    let pending_order_4 = tpsl::new_pending_limit_order(
        4,
        constants::no_restriction(),
        constants::self_matching_allowed(),
        3_000_000_000_000,
        100 * test_constants::sui_multiplier(),
        false,
        false,
        constants::max_u64(),
    );
    mm.add_conditional_order<SUI, USDC>(
        &pool,
        &sui_price,
        &usdc_price,
        &margin_registry,
        4, // conditional_order_id
        condition_4,
        pending_order_4,
        &clock,
        scenario.ctx(),
    );

    // Verify all 4 orders were added
    let order_ids = mm.conditional_order_ids();
    assert!(order_ids.length() == 4);

    // Verify trigger_below orders maintain FIFO order (order 1 before order 2)
    let below_order_1 = mm.conditional_order(order_ids[0]);
    let below_order_2 = mm.conditional_order(order_ids[1]);

    assert!(below_order_1.condition().trigger_below_price() == true);
    assert!(below_order_2.condition().trigger_below_price() == true);
    assert!(below_order_1.condition().trigger_price() == same_trigger_below_price);
    assert!(below_order_2.condition().trigger_price() == same_trigger_below_price);
    // Order 1 (added first) should appear before Order 2 (added second)
    assert!(below_order_1.conditional_order_id() == 1);
    assert!(below_order_2.conditional_order_id() == 2);

    // Verify trigger_above orders maintain FIFO order (order 3 before order 4)
    let above_order_1 = mm.conditional_order(order_ids[2]);
    let above_order_2 = mm.conditional_order(order_ids[3]);

    assert!(above_order_1.condition().trigger_below_price() == false);
    assert!(above_order_2.condition().trigger_below_price() == false);
    assert!(above_order_1.condition().trigger_price() == same_trigger_above_price);
    assert!(above_order_2.condition().trigger_price() == same_trigger_above_price);
    // Order 3 (added first) should appear before Order 4 (added second)
    assert!(above_order_1.conditional_order_id() == 3);
    assert!(above_order_2.conditional_order_id() == 4);

    destroy_2!(sui_price, usdc_price);
    return_shared_2!(mm, pool);

    scenario.next_tx(test_constants::user1());
    let deepbook_registry = scenario.take_shared_by_id<Registry>(registry_id);
    return_shared(deepbook_registry);
    cleanup_margin_test(margin_registry, admin_cap, maintainer_cap, clock, scenario);
}

#[test]
fun test_tpsl_trigger_price_getters() {
    // This test verifies the lowest_trigger_above_price and highest_trigger_below_price functions:
    // - Returns default values when no orders exist
    // - Returns correct values from the first element of each sorted vector

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

    // Verify default values when no orders exist
    assert!(mm.lowest_trigger_above_price() == constants::max_u64());
    assert!(mm.highest_trigger_below_price() == 0);

    // Initial prices: SUI = $2.00, USDC = $1.00
    let sui_price = build_sui_price_info_object_with_price(&mut scenario, 200, &clock); // $2.00
    let usdc_price = build_usdc_price_info_object(&mut scenario, &clock); // $1.00

    // Deposit collateral (SUI)
    mm.deposit<SUI, USDC, SUI>(
        &margin_registry,
        &sui_price,
        &usdc_price,
        mint_coin<SUI>(10000 * test_constants::sui_multiplier(), scenario.ctx()),
        &clock,
        scenario.ctx(),
    );

    // Add 4 trigger_below orders at different prices (intentionally out of order)
    // After insertion, they will be sorted high to low: $1.80, $1.50, $1.20, $0.90
    // highest_trigger_below_price should return the first element: $1.80
    let trigger_prices_below = vector[
        1_500_000, // $1.50
        900_000, // $0.90
        1_800_000, // $1.80 (this will be first after sorting)
        1_200_000, // $1.20
    ];

    let mut i = 0;
    while (i < trigger_prices_below.length()) {
        let condition = tpsl::new_condition(
            true, // trigger_is_below
            trigger_prices_below[i],
        );
        let pending_order = tpsl::new_pending_limit_order(
            i + 1, // client_order_id
            constants::no_restriction(),
            constants::self_matching_allowed(),
            800_000, // price: $0.80
            100 * test_constants::sui_multiplier(),
            false, // is_bid = false (SELL)
            false,
            constants::max_u64(),
        );

        mm.add_conditional_order<SUI, USDC>(
            &pool,
            &sui_price,
            &usdc_price,
            &margin_registry,
            i + 1, // conditional_order_id
            condition,
            pending_order,
            &clock,
            scenario.ctx(),
        );
        i = i + 1;
    };

    // Verify highest_trigger_below_price returns the highest price (first element)
    assert!(mm.highest_trigger_below_price() == 1_800_000); // $1.80
    // lowest_trigger_above_price should still be default (no trigger_above orders yet)
    assert!(mm.lowest_trigger_above_price() == constants::max_u64());

    // Add 4 trigger_above orders at different prices (intentionally out of order)
    // After insertion, they will be sorted low to high: $2.20, $2.50, $2.80, $3.10
    // lowest_trigger_above_price should return the first element: $2.20
    let trigger_prices_above = vector[
        2_500_000, // $2.50
        3_100_000, // $3.10
        2_200_000, // $2.20 (this will be first after sorting)
        2_800_000, // $2.80
    ];

    i = 0;
    while (i < trigger_prices_above.length()) {
        let condition = tpsl::new_condition(
            false, // trigger_is_below = false (trigger_above)
            trigger_prices_above[i],
        );
        let pending_order = tpsl::new_pending_limit_order(
            i + 5, // client_order_id (5, 6, 7, 8)
            constants::no_restriction(),
            constants::self_matching_allowed(),
            3_500_000, // price: $3.50
            100 * test_constants::sui_multiplier(),
            false, // is_bid = false (SELL)
            false,
            constants::max_u64(),
        );

        mm.add_conditional_order<SUI, USDC>(
            &pool,
            &sui_price,
            &usdc_price,
            &margin_registry,
            i + 5, // conditional_order_id (5, 6, 7, 8)
            condition,
            pending_order,
            &clock,
            scenario.ctx(),
        );
        i = i + 1;
    };

    // Verify both getters return the correct first elements
    assert!(mm.highest_trigger_below_price() == 1_800_000); // $1.80 (highest in trigger_below)
    assert!(mm.lowest_trigger_above_price() == 2_200_000); // $2.20 (lowest in trigger_above)

    // Verify all orders are present
    assert!(mm.conditional_order_ids().length() == 8);

    destroy_2!(sui_price, usdc_price);
    return_shared_2!(mm, pool);

    scenario.next_tx(test_constants::user1());
    let deepbook_registry = scenario.take_shared_by_id<Registry>(registry_id);
    return_shared(deepbook_registry);
    cleanup_margin_test(margin_registry, admin_cap, maintainer_cap, clock, scenario);
}

#[test]
fun test_tpsl_trigger_below_market_order_executed() {
    // This test demonstrates a stop-loss with MARKET ORDER where ALICE sets up a conditional order
    // to sell SUI at market price when price drops below a trigger.
    //
    // Setup:
    // - Orderbook has bid liquidity at $1.50 (100 SUI) and $1.00 (100 SUI)
    // - Orderbook has ask liquidity at $2.50 (100 SUI) and $3.00 (100 SUI)
    // - ALICE deposits 10,000 SUI when SUI = $2.00
    // - ALICE creates stop-loss: if price drops below $1.50, sell 150 SUI at market
    // - BOB triggers when price drops to $0.95
    //
    // Expected: Market sell (is_bid=false) fills against bids
    // - 100 SUI at $1.50 = 150 USDC received
    // - 50 SUI at $1.00 = 50 USDC received
    // - Total: 150 SUI sold for 200 USDC

    let (
        mut scenario,
        clock,
        admin_cap,
        maintainer_cap,
        _usdc_pool_id,
        _sui_pool_id,
        pool_id,
        registry_id,
    ) = setup_sui_usdc_deepbook_margin();

    // Set up orderbook liquidity
    setup_orderbook_liquidity<SUI, USDC>(&mut scenario, pool_id, &clock);

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
    // When triggered, execute MARKET order to sell 150 SUI (< 200 bid liquidity available)
    let condition = tpsl::new_condition(
        true, // trigger_is_below
        1_500_000, // trigger price: $1.50
    );
    let pending_order = tpsl::new_pending_market_order(
        1, // client_order_id
        constants::self_matching_allowed(),
        150 * test_constants::sui_multiplier(), // quantity: 150 SUI (< 200 bid liquidity)
        false, // is_bid = false (SELL at market, fills against bids)
        false, // pay_with_deep
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
    assert!(mm.conditional_order_ids().length() == 1);

    destroy_2!(sui_price_high, usdc_price);
    return_shared(pool);
    return_shared(margin_registry);

    // USER2 = BOB executes conditional orders when price drops
    scenario.next_tx(test_constants::user2());
    let sui_price_low = build_sui_price_info_object_with_price(&mut scenario, 95, &clock); // $0.95
    let usdc_price = build_usdc_price_info_object(&mut scenario, &clock);

    let mut pool = scenario.take_shared<Pool<SUI, USDC>>();
    let margin_registry = scenario.take_shared<MarginRegistry>();

    // Execute conditional orders - should trigger and place market order
    let order_infos = mm.execute_conditional_orders<SUI, USDC>(
        &mut pool,
        &sui_price_low,
        &usdc_price,
        &margin_registry,
        10, // max_orders_to_execute
        &clock,
        scenario.ctx(),
    );

    // Verify order was executed with accurate data
    assert!(order_infos.length() == 1);
    let order_info = &order_infos[0];

    // Validate order details
    assert!(order_info.client_order_id() == 1);
    assert!(order_info.original_quantity() == 150 * test_constants::sui_multiplier()); // 150 SUI
    assert!(order_info.is_bid() == false); // Sell order
    assert!(order_info.balance_manager_id() == object::id(mm.balance_manager()));

    // Validate fills - market sell fills against bid orders
    let fills = order_info.fills();
    assert!(fills.length() == 2); // Two fills: 100 at $1.50, 50 at $1.00

    // First fill: 100 SUI at $1.50
    assert!(fills[0].base_quantity() == 100 * test_constants::sui_multiplier());
    assert!(fills[0].quote_quantity() == 150_000_000); // 100 * 1.5 in pool units

    // Second fill: 50 SUI at $1.00
    assert!(fills[1].base_quantity() == 50 * test_constants::sui_multiplier());
    assert!(fills[1].quote_quantity() == 50_000_000); // 50 * 1.0 in pool units

    // Total executed quantity should be 150 SUI
    assert!(order_info.executed_quantity() == 150 * test_constants::sui_multiplier());

    // Total quote in pool units
    assert!(order_info.cumulative_quote_quantity() == 200_000_000);

    destroy(order_infos[0]);

    // Verify conditional order was removed after execution
    assert!(mm.conditional_order_ids().length() == 0);

    destroy_2!(sui_price_low, usdc_price);
    return_shared_2!(mm, pool);

    let deepbook_registry = scenario.take_shared_by_id<Registry>(registry_id);
    return_shared(deepbook_registry);
    cleanup_margin_test(margin_registry, admin_cap, maintainer_cap, clock, scenario);
}

#[test]
fun test_tpsl_trigger_above_market_order_executed() {
    // This test demonstrates a take-profit with MARKET ORDER where ALICE sets up a conditional order
    // to sell SUI at market price when price rises above a trigger.
    //
    // Setup:
    // - Orderbook has bid liquidity at $1.50 (100 SUI) and $1.00 (100 SUI)
    // - Orderbook has ask liquidity at $2.50 (100 SUI) and $3.00 (100 SUI)
    // - ALICE deposits 10,000 SUI when SUI = $1.50
    // - ALICE creates take-profit: if price rises above $2.00, sell 150 SUI at market
    // - BOB triggers when price rises to $2.10
    //
    // Expected: Market sell (is_bid=false) fills against bids
    // - 100 SUI at $1.50 = 150 USDC received
    // - 50 SUI at $1.00 = 50 USDC received
    // - Total: 150 SUI sold for 200 USDC

    let (
        mut scenario,
        clock,
        admin_cap,
        maintainer_cap,
        _usdc_pool_id,
        _sui_pool_id,
        pool_id,
        registry_id,
    ) = setup_sui_usdc_deepbook_margin();

    // Set up orderbook liquidity
    setup_orderbook_liquidity<SUI, USDC>(&mut scenario, pool_id, &clock);

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

    // Initial prices: SUI = $1.50, USDC = $1.00
    let sui_price_low = build_sui_price_info_object_with_price(&mut scenario, 150, &clock); // $1.50
    let usdc_price = build_usdc_price_info_object(&mut scenario, &clock); // $1.00

    // Deposit collateral (SUI)
    mm.deposit<SUI, USDC, SUI>(
        &margin_registry,
        &sui_price_low,
        &usdc_price,
        mint_coin<SUI>(10000 * test_constants::sui_multiplier(), scenario.ctx()),
        &clock,
        scenario.ctx(),
    );

    // Add conditional order: trigger_is_below = false, trigger_price = $2.00
    // When triggered, execute MARKET order to sell 150 SUI (< 200 total available)
    let condition = tpsl::new_condition(
        false, // trigger_is_below = false (trigger_above)
        2_000_000, // trigger price: $2.00
    );
    let pending_order = tpsl::new_pending_market_order(
        1, // client_order_id
        constants::self_matching_allowed(),
        150 * test_constants::sui_multiplier(), // quantity: 150 SUI (< 200 available)
        false, // is_bid = false (SELL at market, crosses to fill against asks)
        false, // pay_with_deep
    );

    mm.add_conditional_order<SUI, USDC>(
        &pool,
        &sui_price_low,
        &usdc_price,
        &margin_registry,
        1, // conditional_order_identifier
        condition,
        pending_order,
        &clock,
        scenario.ctx(),
    );

    // Verify conditional order was added
    assert!(mm.conditional_order_ids().length() == 1);

    destroy_2!(sui_price_low, usdc_price);
    return_shared(pool);
    return_shared(margin_registry);

    // USER2 = BOB executes conditional orders when price rises
    scenario.next_tx(test_constants::user2());
    let sui_price_high = build_sui_price_info_object_with_price(&mut scenario, 210, &clock); // $2.10
    let usdc_price = build_usdc_price_info_object(&mut scenario, &clock);

    let mut pool = scenario.take_shared<Pool<SUI, USDC>>();
    let margin_registry = scenario.take_shared<MarginRegistry>();

    // Execute conditional orders - should trigger and place market order
    let order_infos = mm.execute_conditional_orders<SUI, USDC>(
        &mut pool,
        &sui_price_high,
        &usdc_price,
        &margin_registry,
        10, // max_orders_to_execute
        &clock,
        scenario.ctx(),
    );

    // Verify order was executed with accurate data
    assert!(order_infos.length() == 1);
    let order_info = &order_infos[0];

    // Validate order details
    assert!(order_info.client_order_id() == 1);
    assert!(order_info.original_quantity() == 150 * test_constants::sui_multiplier()); // 150 SUI
    assert!(order_info.is_bid() == false); // Sell order
    assert!(order_info.balance_manager_id() == object::id(mm.balance_manager()));

    // Validate fills - market sell fills against bid orders (same as trigger_below)
    let fills = order_info.fills();
    assert!(fills.length() == 2); // Two fills: 100 at $1.50, 50 at $1.00

    // First fill: 100 SUI at $1.50
    assert!(fills[0].base_quantity() == 100 * test_constants::sui_multiplier());
    assert!(fills[0].quote_quantity() == 150_000_000); // 100 * 1.5 in pool units

    // Second fill: 50 SUI at $1.00
    assert!(fills[1].base_quantity() == 50 * test_constants::sui_multiplier());
    assert!(fills[1].quote_quantity() == 50_000_000); // 50 * 1.0 in pool units

    // Total executed quantity should be 150 SUI
    assert!(order_info.executed_quantity() == 150 * test_constants::sui_multiplier());

    // Total quote in pool units (150 + 50 = 200 in pool units)
    assert!(order_info.cumulative_quote_quantity() == 200_000_000);

    destroy(order_infos[0]);

    // Verify conditional order was removed after execution
    assert!(mm.conditional_order_ids().length() == 0);

    destroy_2!(sui_price_high, usdc_price);
    return_shared_2!(mm, pool);

    let deepbook_registry = scenario.take_shared_by_id<Registry>(registry_id);
    return_shared(deepbook_registry);
    cleanup_margin_test(margin_registry, admin_cap, maintainer_cap, clock, scenario);
}

#[test]
fun test_tpsl_cancel_conditional_order() {
    // This test verifies canceling specific conditional orders
    // - ALICE adds 8 conditional orders (4 trigger_below, 4 trigger_above)
    // - ALICE cancels 2 orders (1 from each vector)
    // - Verifies remaining 6 orders are still correctly sorted

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

    let sui_price = build_sui_price_info_object_with_price(&mut scenario, 200, &clock); // $2.00
    let usdc_price = build_usdc_price_info_object(&mut scenario, &clock); // $1.00

    // Deposit collateral
    mm.deposit<SUI, USDC, SUI>(
        &margin_registry,
        &sui_price,
        &usdc_price,
        mint_coin<SUI>(10000 * test_constants::sui_multiplier(), scenario.ctx()),
        &clock,
        scenario.ctx(),
    );

    // Add 4 trigger_below orders
    let trigger_prices_below = vector[
        1_500_000, // $1.50 - ID 1
        900_000, // $0.90 - ID 2
        1_800_000, // $1.80 - ID 3
        1_200_000, // $1.20 - ID 4
    ];

    let mut i = 0;
    while (i < trigger_prices_below.length()) {
        let condition = tpsl::new_condition(true, trigger_prices_below[i]);
        let pending_order = tpsl::new_pending_limit_order(
            i + 1,
            constants::no_restriction(),
            constants::self_matching_allowed(),
            800_000,
            100 * test_constants::sui_multiplier(),
            false,
            false,
            constants::max_u64(),
        );

        mm.add_conditional_order<SUI, USDC>(
            &pool,
            &sui_price,
            &usdc_price,
            &margin_registry,
            i + 1,
            condition,
            pending_order,
            &clock,
            scenario.ctx(),
        );
        i = i + 1;
    };

    // Add 4 trigger_above orders
    let trigger_prices_above = vector[
        2_500_000, // $2.50 - ID 5
        3_100_000, // $3.10 - ID 6
        2_200_000, // $2.20 - ID 7
        2_800_000, // $2.80 - ID 8
    ];

    i = 0;
    while (i < trigger_prices_above.length()) {
        let condition = tpsl::new_condition(false, trigger_prices_above[i]);
        let pending_order = tpsl::new_pending_limit_order(
            i + 5,
            constants::no_restriction(),
            constants::self_matching_allowed(),
            3_500_000,
            100 * test_constants::sui_multiplier(),
            false,
            false,
            constants::max_u64(),
        );

        mm.add_conditional_order<SUI, USDC>(
            &pool,
            &sui_price,
            &usdc_price,
            &margin_registry,
            i + 5,
            condition,
            pending_order,
            &clock,
            scenario.ctx(),
        );
        i = i + 1;
    };

    // Verify all 8 orders were added
    assert!(mm.conditional_order_ids().length() == 8);

    // Cancel 2 orders: ID 3 from trigger_below ($1.80) and ID 5 from trigger_above ($2.50)
    mm.cancel_conditional_order<SUI, USDC>(3, &clock, scenario.ctx());
    mm.cancel_conditional_order<SUI, USDC>(5, &clock, scenario.ctx());

    // Verify 6 orders remain
    let order_ids = mm.conditional_order_ids();
    assert!(order_ids.length() == 6);

    // Verify trigger_below orders are still sorted correctly (high to low)
    // After canceling ID 3 ($1.80), should be: ID 1 ($1.50), ID 4 ($1.20), ID 2 ($0.90)
    let order_1 = mm.conditional_order(order_ids[0]);
    let order_2 = mm.conditional_order(order_ids[1]);
    let order_3 = mm.conditional_order(order_ids[2]);

    assert!(order_1.condition().trigger_below_price() == true);
    assert!(order_1.condition().trigger_price() == 1_500_000); // $1.50 (highest remaining)
    assert!(order_2.condition().trigger_price() == 1_200_000); // $1.20
    assert!(order_3.condition().trigger_price() == 900_000); // $0.90 (lowest)

    // Verify trigger_above orders are still sorted correctly (low to high)
    // After canceling ID 5 ($2.50), should be: ID 7 ($2.20), ID 8 ($2.80), ID 6 ($3.10)
    let order_4 = mm.conditional_order(order_ids[3]);
    let order_5 = mm.conditional_order(order_ids[4]);
    let order_6 = mm.conditional_order(order_ids[5]);

    assert!(order_4.condition().trigger_below_price() == false);
    assert!(order_4.condition().trigger_price() == 2_200_000); // $2.20 (lowest remaining)
    assert!(order_5.condition().trigger_price() == 2_800_000); // $2.80
    assert!(order_6.condition().trigger_price() == 3_100_000); // $3.10 (highest)

    destroy_2!(sui_price, usdc_price);
    return_shared_2!(mm, pool);

    scenario.next_tx(test_constants::user1());
    let deepbook_registry = scenario.take_shared_by_id<Registry>(registry_id);
    return_shared(deepbook_registry);
    cleanup_margin_test(margin_registry, admin_cap, maintainer_cap, clock, scenario);
}

#[test]
fun test_tpsl_cancel_all_conditional_orders() {
    // This test verifies canceling all conditional orders at once
    // - ALICE adds 8 conditional orders (4 trigger_below, 4 trigger_above)
    // - ALICE calls cancel_all_conditional_orders
    // - Verifies no orders remain

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

    let sui_price = build_sui_price_info_object_with_price(&mut scenario, 200, &clock); // $2.00
    let usdc_price = build_usdc_price_info_object(&mut scenario, &clock); // $1.00

    // Deposit collateral
    mm.deposit<SUI, USDC, SUI>(
        &margin_registry,
        &sui_price,
        &usdc_price,
        mint_coin<SUI>(10000 * test_constants::sui_multiplier(), scenario.ctx()),
        &clock,
        scenario.ctx(),
    );

    // Add 4 trigger_below orders
    let trigger_prices_below = vector[1_500_000, 900_000, 1_800_000, 1_200_000];

    let mut i = 0;
    while (i < trigger_prices_below.length()) {
        let condition = tpsl::new_condition(true, trigger_prices_below[i]);
        let pending_order = tpsl::new_pending_limit_order(
            i + 1,
            constants::no_restriction(),
            constants::self_matching_allowed(),
            800_000,
            100 * test_constants::sui_multiplier(),
            false,
            false,
            constants::max_u64(),
        );

        mm.add_conditional_order<SUI, USDC>(
            &pool,
            &sui_price,
            &usdc_price,
            &margin_registry,
            i + 1,
            condition,
            pending_order,
            &clock,
            scenario.ctx(),
        );
        i = i + 1;
    };

    // Add 4 trigger_above orders
    let trigger_prices_above = vector[2_500_000, 3_100_000, 2_200_000, 2_800_000];

    i = 0;
    while (i < trigger_prices_above.length()) {
        let condition = tpsl::new_condition(false, trigger_prices_above[i]);
        let pending_order = tpsl::new_pending_limit_order(
            i + 5,
            constants::no_restriction(),
            constants::self_matching_allowed(),
            3_500_000,
            100 * test_constants::sui_multiplier(),
            false,
            false,
            constants::max_u64(),
        );

        mm.add_conditional_order<SUI, USDC>(
            &pool,
            &sui_price,
            &usdc_price,
            &margin_registry,
            i + 5,
            condition,
            pending_order,
            &clock,
            scenario.ctx(),
        );
        i = i + 1;
    };

    // Verify all 8 orders were added
    assert!(mm.conditional_order_ids().length() == 8);

    // Cancel all conditional orders
    mm.cancel_all_conditional_orders<SUI, USDC>(&clock, scenario.ctx());

    // Verify no orders remain
    assert!(mm.conditional_order_ids().length() == 0);

    // Verify trigger price getters return default values
    assert!(mm.lowest_trigger_above_price() == constants::max_u64());
    assert!(mm.highest_trigger_below_price() == 0);

    destroy_2!(sui_price, usdc_price);
    return_shared_2!(mm, pool);

    scenario.next_tx(test_constants::user1());
    let deepbook_registry = scenario.take_shared_by_id<Registry>(registry_id);
    return_shared(deepbook_registry);
    cleanup_margin_test(margin_registry, admin_cap, maintainer_cap, clock, scenario);
}

// === Error Code Tests ===

#[test]
#[expected_failure(abort_code = deepbook_margin::tpsl::EInvalidCondition)]
fun test_error_invalid_condition() {
    // Test EInvalidCondition: trigger_below price must be < current price
    // Current price is $2.00, but trigger is set to $2.50 (above current price)

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

    let sui_price = build_sui_price_info_object_with_price(&mut scenario, 200, &clock); // $2.00
    let usdc_price = build_usdc_price_info_object(&mut scenario, &clock);

    mm.deposit<SUI, USDC, SUI>(
        &margin_registry,
        &sui_price,
        &usdc_price,
        mint_coin<SUI>(10000 * test_constants::sui_multiplier(), scenario.ctx()),
        &clock,
        scenario.ctx(),
    );

    // Invalid: trigger_below with trigger price $2.50 > current price $2.00
    let condition = tpsl::new_condition(true, 2_500_000); // $2.50
    let pending_order = tpsl::new_pending_limit_order(
        1,
        constants::no_restriction(),
        constants::self_matching_allowed(),
        800_000,
        100 * test_constants::sui_multiplier(),
        false,
        false,
        constants::max_u64(),
    );

    mm.add_conditional_order<SUI, USDC>(
        &pool,
        &sui_price,
        &usdc_price,
        &margin_registry,
        1,
        condition,
        pending_order,
        &clock,
        scenario.ctx(),
    );

    destroy_2!(sui_price, usdc_price);
    return_shared_2!(mm, pool);

    cleanup_margin_test(margin_registry, admin_cap, maintainer_cap, clock, scenario);
}

#[test]
#[expected_failure(abort_code = deepbook_margin::tpsl::EInvalidCondition)]
fun test_error_invalid_condition_trigger_above() {
    // Test EInvalidCondition: trigger_above price must be > current price
    // Current price is $2.00, but trigger is set to $1.50 (below current price)

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

    let sui_price = build_sui_price_info_object_with_price(&mut scenario, 200, &clock); // $2.00
    let usdc_price = build_usdc_price_info_object(&mut scenario, &clock);

    mm.deposit<SUI, USDC, SUI>(
        &margin_registry,
        &sui_price,
        &usdc_price,
        mint_coin<SUI>(10000 * test_constants::sui_multiplier(), scenario.ctx()),
        &clock,
        scenario.ctx(),
    );

    // Invalid: trigger_above (false) with trigger price $1.50 < current price $2.00
    let condition = tpsl::new_condition(false, 1_500_000); // $1.50
    let pending_order = tpsl::new_pending_limit_order(
        1,
        constants::no_restriction(),
        constants::self_matching_allowed(),
        2_500_000,
        100 * test_constants::sui_multiplier(),
        false,
        false,
        constants::max_u64(),
    );

    mm.add_conditional_order<SUI, USDC>(
        &pool,
        &sui_price,
        &usdc_price,
        &margin_registry,
        1,
        condition,
        pending_order,
        &clock,
        scenario.ctx(),
    );

    destroy_2!(sui_price, usdc_price);
    return_shared_2!(mm, pool);

    cleanup_margin_test(margin_registry, admin_cap, maintainer_cap, clock, scenario);
}

#[test]
#[expected_failure(abort_code = deepbook_margin::tpsl::EConditionalOrderNotFound)]
fun test_error_conditional_order_not_found() {
    // Test EConditionalOrderNotFound: trying to cancel a non-existent order

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

    // Try to cancel non-existent order ID 999
    mm.cancel_conditional_order<SUI, USDC>(999, &clock, scenario.ctx());

    return_shared(mm);
    cleanup_margin_test(margin_registry, admin_cap, maintainer_cap, clock, scenario);
}

#[test]
#[expected_failure(abort_code = deepbook_margin::tpsl::EMaxConditionalOrdersReached)]
fun test_error_max_conditional_orders_reached() {
    // Test EMaxConditionalOrdersReached: trying to add more than 10 orders (max is 10)

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

    let sui_price = build_sui_price_info_object_with_price(&mut scenario, 200, &clock);
    let usdc_price = build_usdc_price_info_object(&mut scenario, &clock);

    mm.deposit<SUI, USDC, SUI>(
        &margin_registry,
        &sui_price,
        &usdc_price,
        mint_coin<SUI>(10000 * test_constants::sui_multiplier(), scenario.ctx()),
        &clock,
        scenario.ctx(),
    );

    // Add 11 orders (max is 10)
    let mut i = 0;
    while (i < 11) {
        let condition = tpsl::new_condition(true, 1_500_000);
        let pending_order = tpsl::new_pending_limit_order(
            i + 1,
            constants::no_restriction(),
            constants::self_matching_allowed(),
            800_000,
            100 * test_constants::sui_multiplier(),
            false,
            false,
            constants::max_u64(),
        );

        mm.add_conditional_order<SUI, USDC>(
            &pool,
            &sui_price,
            &usdc_price,
            &margin_registry,
            i + 1,
            condition,
            pending_order,
            &clock,
            scenario.ctx(),
        );
        i = i + 1;
    };

    destroy_2!(sui_price, usdc_price);
    return_shared_2!(mm, pool);

    cleanup_margin_test(margin_registry, admin_cap, maintainer_cap, clock, scenario);
}

#[test]
#[expected_failure(abort_code = deepbook_margin::tpsl::EInvalidTPSLOrderType)]
fun test_error_invalid_tpsl_order_type() {
    // Test EInvalidTPSLOrderType: only no_restriction and immediate_or_cancel are allowed
    // fill_or_kill is not allowed

    let _condition = tpsl::new_condition(true, 1_500_000);
    let _pending_order = tpsl::new_pending_limit_order(
        1,
        constants::fill_or_kill(), // This should fail
        constants::self_matching_allowed(),
        800_000,
        100 * test_constants::sui_multiplier(),
        false,
        false,
        constants::max_u64(),
    );
}

#[test]
#[expected_failure(abort_code = deepbook_margin::tpsl::EDuplicateConditionalOrderIdentifier)]
fun test_error_duplicate_conditional_order_identifier() {
    // Test EDuplicateConditionalOrderIdentifier: trying to add order with existing ID

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

    let sui_price = build_sui_price_info_object_with_price(&mut scenario, 200, &clock);
    let usdc_price = build_usdc_price_info_object(&mut scenario, &clock);

    mm.deposit<SUI, USDC, SUI>(
        &margin_registry,
        &sui_price,
        &usdc_price,
        mint_coin<SUI>(10000 * test_constants::sui_multiplier(), scenario.ctx()),
        &clock,
        scenario.ctx(),
    );

    // Add first order with ID 1
    let condition = tpsl::new_condition(true, 1_500_000);
    let pending_order = tpsl::new_pending_limit_order(
        1,
        constants::no_restriction(),
        constants::self_matching_allowed(),
        800_000,
        100 * test_constants::sui_multiplier(),
        false,
        false,
        constants::max_u64(),
    );

    mm.add_conditional_order<SUI, USDC>(
        &pool,
        &sui_price,
        &usdc_price,
        &margin_registry,
        1,
        condition,
        pending_order,
        &clock,
        scenario.ctx(),
    );

    // Try to add another order with same ID 1
    let condition2 = tpsl::new_condition(true, 1_000_000);
    let pending_order2 = tpsl::new_pending_limit_order(
        2,
        constants::no_restriction(),
        constants::self_matching_allowed(),
        700_000_000_000,
        100 * test_constants::sui_multiplier(),
        false,
        false,
        constants::max_u64(),
    );

    mm.add_conditional_order<SUI, USDC>(
        &pool,
        &sui_price,
        &usdc_price,
        &margin_registry,
        1, // Duplicate ID
        condition2,
        pending_order2,
        &clock,
        scenario.ctx(),
    );

    destroy_2!(sui_price, usdc_price);
    return_shared_2!(mm, pool);

    cleanup_margin_test(margin_registry, admin_cap, maintainer_cap, clock, scenario);
}

#[test]
#[expected_failure(abort_code = deepbook_margin::tpsl::EInvalidOrderParams)]
fun test_error_invalid_order_params_quantity_too_small() {
    // Test EInvalidOrderParams: quantity below min_size

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

    let sui_price = build_sui_price_info_object_with_price(&mut scenario, 200, &clock);
    let usdc_price = build_usdc_price_info_object(&mut scenario, &clock);

    mm.deposit<SUI, USDC, SUI>(
        &margin_registry,
        &sui_price,
        &usdc_price,
        mint_coin<SUI>(10000 * test_constants::sui_multiplier(), scenario.ctx()),
        &clock,
        scenario.ctx(),
    );

    // Invalid: quantity = 0 (below min_size)
    let condition = tpsl::new_condition(true, 1_500_000);
    let pending_order = tpsl::new_pending_limit_order(
        1,
        constants::no_restriction(),
        constants::self_matching_allowed(),
        800_000,
        0, // Invalid quantity
        false,
        false,
        constants::max_u64(),
    );

    mm.add_conditional_order<SUI, USDC>(
        &pool,
        &sui_price,
        &usdc_price,
        &margin_registry,
        1,
        condition,
        pending_order,
        &clock,
        scenario.ctx(),
    );

    destroy_2!(sui_price, usdc_price);
    return_shared_2!(mm, pool);

    cleanup_margin_test(margin_registry, admin_cap, maintainer_cap, clock, scenario);
}

#[test]
#[expected_failure(abort_code = deepbook_margin::tpsl::EInvalidOrderParams)]
fun test_error_invalid_order_params_quantity_not_lot_size_multiple() {
    // Test EInvalidOrderParams: quantity not a multiple of lot_size

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

    let sui_price = build_sui_price_info_object_with_price(&mut scenario, 200, &clock);
    let usdc_price = build_usdc_price_info_object(&mut scenario, &clock);

    mm.deposit<SUI, USDC, SUI>(
        &margin_registry,
        &sui_price,
        &usdc_price,
        mint_coin<SUI>(10000 * test_constants::sui_multiplier(), scenario.ctx()),
        &clock,
        scenario.ctx(),
    );

    // Invalid: quantity = 1.5 * lot_size + 1 (not a multiple of lot_size)
    // lot_size is typically 1 * base_multiplier (1 SUI = 1_000_000_000)
    let condition = tpsl::new_condition(true, 1_500_000);
    let pending_order = tpsl::new_pending_limit_order(
        1,
        constants::no_restriction(),
        constants::self_matching_allowed(),
        800_000,
        test_constants::sui_multiplier() + 1, // 1 SUI + 1 nano (not a lot_size multiple)
        false,
        false,
        constants::max_u64(),
    );

    mm.add_conditional_order<SUI, USDC>(
        &pool,
        &sui_price,
        &usdc_price,
        &margin_registry,
        1,
        condition,
        pending_order,
        &clock,
        scenario.ctx(),
    );

    destroy_2!(sui_price, usdc_price);
    return_shared_2!(mm, pool);

    cleanup_margin_test(margin_registry, admin_cap, maintainer_cap, clock, scenario);
}

#[test]
#[expected_failure(abort_code = deepbook_margin::tpsl::EInvalidOrderParams)]
fun test_error_invalid_order_params_price_not_tick_size_multiple() {
    // Test EInvalidOrderParams: price not a multiple of tick_size for limit orders

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

    let sui_price = build_sui_price_info_object_with_price(&mut scenario, 200, &clock);
    let usdc_price = build_usdc_price_info_object(&mut scenario, &clock);

    mm.deposit<SUI, USDC, SUI>(
        &margin_registry,
        &sui_price,
        &usdc_price,
        mint_coin<SUI>(10000 * test_constants::sui_multiplier(), scenario.ctx()),
        &clock,
        scenario.ctx(),
    );

    // Invalid: price = 12345 (not a multiple of tick_size)
    let condition = tpsl::new_condition(true, 1_500_000);
    let pending_order = tpsl::new_pending_limit_order(
        1,
        constants::no_restriction(),
        constants::self_matching_allowed(),
        12345, // Invalid price (not tick_size multiple)
        100 * test_constants::sui_multiplier(),
        false,
        false,
        constants::max_u64(),
    );

    mm.add_conditional_order<SUI, USDC>(
        &pool,
        &sui_price,
        &usdc_price,
        &margin_registry,
        1,
        condition,
        pending_order,
        &clock,
        scenario.ctx(),
    );

    destroy_2!(sui_price, usdc_price);
    return_shared_2!(mm, pool);

    cleanup_margin_test(margin_registry, admin_cap, maintainer_cap, clock, scenario);
}

#[test]
#[expected_failure(abort_code = deepbook_margin::tpsl::EInvalidOrderParams)]
fun test_error_invalid_order_params_price_below_min() {
    // Test EInvalidOrderParams: price < min_price for limit orders

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

    let sui_price = build_sui_price_info_object_with_price(&mut scenario, 200, &clock);
    let usdc_price = build_usdc_price_info_object(&mut scenario, &clock);

    mm.deposit<SUI, USDC, SUI>(
        &margin_registry,
        &sui_price,
        &usdc_price,
        mint_coin<SUI>(10000 * test_constants::sui_multiplier(), scenario.ctx()),
        &clock,
        scenario.ctx(),
    );

    // Invalid: price = 0 (< min_price)
    let condition = tpsl::new_condition(true, 1_500_000);
    let pending_order = tpsl::new_pending_limit_order(
        1,
        constants::no_restriction(),
        constants::self_matching_allowed(),
        0, // Invalid: price = 0
        100 * test_constants::sui_multiplier(),
        false,
        false,
        constants::max_u64(),
    );

    mm.add_conditional_order<SUI, USDC>(
        &pool,
        &sui_price,
        &usdc_price,
        &margin_registry,
        1,
        condition,
        pending_order,
        &clock,
        scenario.ctx(),
    );

    destroy_2!(sui_price, usdc_price);
    return_shared_2!(mm, pool);

    cleanup_margin_test(margin_registry, admin_cap, maintainer_cap, clock, scenario);
}

#[test]
#[expected_failure(abort_code = deepbook_margin::tpsl::EInvalidOrderParams)]
fun test_error_invalid_order_params_expired_timestamp() {
    // Test EInvalidOrderParams: expire_timestamp in the past

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

    let sui_price = build_sui_price_info_object_with_price(&mut scenario, 200, &clock);
    let usdc_price = build_usdc_price_info_object(&mut scenario, &clock);

    mm.deposit<SUI, USDC, SUI>(
        &margin_registry,
        &sui_price,
        &usdc_price,
        mint_coin<SUI>(10000 * test_constants::sui_multiplier(), scenario.ctx()),
        &clock,
        scenario.ctx(),
    );

    // Invalid: expire_timestamp = 100 (< current clock time which is 1000000)
    let condition = tpsl::new_condition(true, 1_500_000);
    let pending_order = tpsl::new_pending_limit_order(
        1,
        constants::no_restriction(),
        constants::self_matching_allowed(),
        800_000,
        100 * test_constants::sui_multiplier(),
        false,
        false,
        100, // Already expired
    );

    mm.add_conditional_order<SUI, USDC>(
        &pool,
        &sui_price,
        &usdc_price,
        &margin_registry,
        1,
        condition,
        pending_order,
        &clock,
        scenario.ctx(),
    );

    destroy_2!(sui_price, usdc_price);
    return_shared_2!(mm, pool);

    cleanup_margin_test(margin_registry, admin_cap, maintainer_cap, clock, scenario);
}

#[test]
#[expected_failure(abort_code = deepbook_margin::tpsl::EInvalidOrderParams)]
fun test_error_invalid_order_params_market_order_quantity_too_small() {
    // Test EInvalidOrderParams: market order quantity below min_size

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

    let sui_price = build_sui_price_info_object_with_price(&mut scenario, 200, &clock);
    let usdc_price = build_usdc_price_info_object(&mut scenario, &clock);

    mm.deposit<SUI, USDC, SUI>(
        &margin_registry,
        &sui_price,
        &usdc_price,
        mint_coin<SUI>(10000 * test_constants::sui_multiplier(), scenario.ctx()),
        &clock,
        scenario.ctx(),
    );

    // Invalid: market order quantity = 0 (below min_size)
    let condition = tpsl::new_condition(true, 1_500_000);
    let pending_order = tpsl::new_pending_market_order(
        1,
        constants::self_matching_allowed(),
        0, // Invalid quantity
        false,
        false,
    );

    mm.add_conditional_order<SUI, USDC>(
        &pool,
        &sui_price,
        &usdc_price,
        &margin_registry,
        1,
        condition,
        pending_order,
        &clock,
        scenario.ctx(),
    );

    destroy_2!(sui_price, usdc_price);
    return_shared_2!(mm, pool);

    cleanup_margin_test(margin_registry, admin_cap, maintainer_cap, clock, scenario);
}

#[test]
fun test_tpsl_insufficient_funds_second_order() {
    // Test insufficient funds scenario:
    // - ALICE adds 2 trigger_below orders at different trigger prices
    // - Both orders get triggered simultaneously
    // - Only enough collateral to execute the first order (sorted high to low)
    // - Second order fails due to insufficient funds and is removed

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
    let sui_price_high = build_sui_price_info_object_with_price(&mut scenario, 200, &clock); // $2.00
    let usdc_price = build_usdc_price_info_object(&mut scenario, &clock); // $1.00

    // Deposit limited collateral: only 150 SUI
    mm.deposit<SUI, USDC, SUI>(
        &margin_registry,
        &sui_price_high,
        &usdc_price,
        mint_coin<SUI>(150 * test_constants::sui_multiplier(), scenario.ctx()),
        &clock,
        scenario.ctx(),
    );

    // Add first order: trigger_below at $1.80, sell 100 SUI (this will succeed)
    let condition1 = tpsl::new_condition(
        true, // trigger_is_below
        1_800_000, // $1.80
    );
    let pending_order1 = tpsl::new_pending_limit_order(
        1,
        constants::no_restriction(),
        constants::self_matching_allowed(),
        800_000,
        100 * test_constants::sui_multiplier(), // 100 SUI
        false,
        false,
        constants::max_u64(),
    );

    mm.add_conditional_order<SUI, USDC>(
        &pool,
        &sui_price_high,
        &usdc_price,
        &margin_registry,
        1,
        condition1,
        pending_order1,
        &clock,
        scenario.ctx(),
    );

    // Add second order: trigger_below at $1.50, sell 100 SUI (this will fail due to insufficient funds)
    let condition2 = tpsl::new_condition(
        true, // trigger_is_below
        1_500_000, // $1.50
    );
    let pending_order2 = tpsl::new_pending_limit_order(
        2,
        constants::no_restriction(),
        constants::self_matching_allowed(),
        700_000_000_000,
        100 * test_constants::sui_multiplier(), // 100 SUI
        false,
        false,
        constants::max_u64(),
    );

    mm.add_conditional_order<SUI, USDC>(
        &pool,
        &sui_price_high,
        &usdc_price,
        &margin_registry,
        2,
        condition2,
        pending_order2,
        &clock,
        scenario.ctx(),
    );

    // Verify both orders were added
    assert!(mm.conditional_order_ids().length() == 2);

    destroy_2!(sui_price_high, usdc_price);
    return_shared(pool);
    return_shared(margin_registry);

    // USER2 = BOB executes conditional orders when price drops below both triggers
    scenario.next_tx(test_constants::user2());
    let sui_price_low = build_sui_price_info_object_with_price(&mut scenario, 95, &clock); // $0.95 (below both $1.80 and $1.50)
    let usdc_price = build_usdc_price_info_object(&mut scenario, &clock);

    let mut pool = scenario.take_shared<Pool<SUI, USDC>>();
    let margin_registry = scenario.take_shared<MarginRegistry>();

    // Execute conditional orders - both are triggered, but only first succeeds
    let order_infos = mm.execute_conditional_orders<SUI, USDC>(
        &mut pool,
        &sui_price_low,
        &usdc_price,
        &margin_registry,
        10, // max_orders_to_execute
        &clock,
        scenario.ctx(),
    );

    // Only the first order should have been executed successfully
    assert!(order_infos.length() == 1);

    let order_info = &order_infos[0];
    assert!(order_info.client_order_id() == 1); // First order
    assert!(order_info.original_quantity() == 100 * test_constants::sui_multiplier());

    destroy(order_infos[0]);

    // Both conditional orders should be removed (first executed, second insufficient funds)
    assert!(mm.conditional_order_ids().length() == 0);

    destroy_2!(sui_price_low, usdc_price);
    return_shared_2!(mm, pool);

    let deepbook_registry = scenario.take_shared_by_id<Registry>(registry_id);
    return_shared(deepbook_registry);
    cleanup_margin_test(margin_registry, admin_cap, maintainer_cap, clock, scenario);
}

#[test]
fun test_tpsl_expired_order_during_execution() {
    // Test expired order scenario:
    // - ALICE adds a trigger_below order with expiration timestamp
    // - Time passes and the order expires
    // - Price triggers the condition
    // - Order should be removed due to expiration, not executed

    let (
        mut scenario,
        mut clock,
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
    let sui_price_high = build_sui_price_info_object_with_price(&mut scenario, 200, &clock); // $2.00
    let usdc_price = build_usdc_price_info_object(&mut scenario, &clock); // $1.00

    // Deposit collateral
    mm.deposit<SUI, USDC, SUI>(
        &margin_registry,
        &sui_price_high,
        &usdc_price,
        mint_coin<SUI>(10000 * test_constants::sui_multiplier(), scenario.ctx()),
        &clock,
        scenario.ctx(),
    );

    // Add order with short expiration (current time + 100ms)
    let expire_timestamp = clock.timestamp_ms() + 100;
    let condition = tpsl::new_condition(
        true, // trigger_is_below
        1_500_000, // $1.50
    );
    let pending_order = tpsl::new_pending_limit_order(
        1,
        constants::no_restriction(),
        constants::self_matching_allowed(),
        800_000,
        100 * test_constants::sui_multiplier(),
        false,
        false,
        expire_timestamp,
    );

    mm.add_conditional_order<SUI, USDC>(
        &pool,
        &sui_price_high,
        &usdc_price,
        &margin_registry,
        1,
        condition,
        pending_order,
        &clock,
        scenario.ctx(),
    );

    // Verify order was added
    assert!(mm.conditional_order_ids().length() == 1);

    destroy_2!(sui_price_high, usdc_price);
    return_shared(pool);
    return_shared(margin_registry);

    // Advance time past expiration (current time + 200ms)
    clock.increment_for_testing(200);

    // USER2 = BOB tries to execute when price drops (after expiration)
    scenario.next_tx(test_constants::user2());
    let sui_price_low = build_sui_price_info_object_with_price(&mut scenario, 95, &clock); // $0.95
    let usdc_price = build_usdc_price_info_object(&mut scenario, &clock);

    let mut pool = scenario.take_shared<Pool<SUI, USDC>>();
    let margin_registry = scenario.take_shared<MarginRegistry>();

    // Execute conditional orders - order is triggered but expired
    let order_infos = mm.execute_conditional_orders<SUI, USDC>(
        &mut pool,
        &sui_price_low,
        &usdc_price,
        &margin_registry,
        10,
        &clock,
        scenario.ctx(),
    );

    // No orders should have been executed (order was expired)
    assert!(order_infos.length() == 0);

    // Conditional order should be removed due to expiration
    assert!(mm.conditional_order_ids().length() == 0);

    destroy_2!(sui_price_low, usdc_price);
    return_shared_2!(mm, pool);

    let deepbook_registry = scenario.take_shared_by_id<Registry>(registry_id);
    return_shared(deepbook_registry);
    cleanup_margin_test(margin_registry, admin_cap, maintainer_cap, clock, scenario);
}

#[test]
fun test_tpsl_early_exit_optimization() {
    // Test early exit optimization:
    // - ALICE adds 5 trigger_below orders at different prices
    // - Price only crosses 2 of them (highest 2)
    // - Only 2 orders should execute, 3 should remain
    // - Tests that the early exit optimization works (breaks when condition not met)

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
    let sui_price_high = build_sui_price_info_object_with_price(&mut scenario, 200, &clock); // $2.00
    let usdc_price = build_usdc_price_info_object(&mut scenario, &clock);

    // Deposit collateral
    mm.deposit<SUI, USDC, SUI>(
        &margin_registry,
        &sui_price_high,
        &usdc_price,
        mint_coin<SUI>(10000 * test_constants::sui_multiplier(), scenario.ctx()),
        &clock,
        scenario.ctx(),
    );

    // Add 5 trigger_below orders at different prices (will be sorted high to low)
    let trigger_prices = vector[
        1_800_000, // $1.80 - ID 1 - Will trigger
        1_600_000, // $1.60 - ID 2 - Will trigger
        1_400_000, // $1.40 - ID 3 - Won't trigger (price = $1.50)
        1_200_000, // $1.20 - ID 4 - Won't trigger
        1_000_000, // $1.00 - ID 5 - Won't trigger
    ];

    let mut i = 0;
    while (i < trigger_prices.length()) {
        let condition = tpsl::new_condition(true, trigger_prices[i]);
        let pending_order = tpsl::new_pending_limit_order(
            i + 1,
            constants::no_restriction(),
            constants::self_matching_allowed(),
            800_000,
            10 * test_constants::sui_multiplier(), // Small amounts to ensure all can execute
            false,
            false,
            constants::max_u64(),
        );

        mm.add_conditional_order<SUI, USDC>(
            &pool,
            &sui_price_high,
            &usdc_price,
            &margin_registry,
            i + 1,
            condition,
            pending_order,
            &clock,
            scenario.ctx(),
        );
        i = i + 1;
    };

    // Verify all 5 orders were added
    assert!(mm.conditional_order_ids().length() == 5);

    destroy_2!(sui_price_high, usdc_price);
    return_shared(pool);
    return_shared(margin_registry);

    // USER2 = BOB executes when price drops to $1.50 (only crosses $1.80 and $1.60)
    scenario.next_tx(test_constants::user2());
    let sui_price_mid = build_sui_price_info_object_with_price(&mut scenario, 150, &clock); // $1.50
    let usdc_price = build_usdc_price_info_object(&mut scenario, &clock);

    let mut pool = scenario.take_shared<Pool<SUI, USDC>>();
    let margin_registry = scenario.take_shared<MarginRegistry>();

    // Execute conditional orders
    let order_infos = mm.execute_conditional_orders<SUI, USDC>(
        &mut pool,
        &sui_price_mid,
        &usdc_price,
        &margin_registry,
        10,
        &clock,
        scenario.ctx(),
    );

    // Only 2 orders should have been executed (ID 1 and ID 2)
    assert!(order_infos.length() == 2);
    assert!(order_infos[0].client_order_id() == 1); // $1.80
    assert!(order_infos[1].client_order_id() == 2); // $1.60

    destroy(order_infos[0]);
    destroy(order_infos[1]);

    // 3 orders should remain (ID 3, 4, 5)
    let remaining_ids = mm.conditional_order_ids();
    assert!(remaining_ids.length() == 3);

    // Verify remaining orders are the correct ones (sorted high to low)
    let order_3 = mm.conditional_order(remaining_ids[0]);
    let order_4 = mm.conditional_order(remaining_ids[1]);
    let order_5 = mm.conditional_order(remaining_ids[2]);

    assert!(order_3.condition().trigger_price() == 1_400_000); // $1.40
    assert!(order_4.condition().trigger_price() == 1_200_000); // $1.20
    assert!(order_5.condition().trigger_price() == 1_000_000); // $1.00

    destroy_2!(sui_price_mid, usdc_price);
    return_shared_2!(mm, pool);

    let deepbook_registry = scenario.take_shared_by_id<Registry>(registry_id);
    return_shared(deepbook_registry);
    cleanup_margin_test(margin_registry, admin_cap, maintainer_cap, clock, scenario);
}

#[test]
fun test_tpsl_max_orders_to_execute_limit() {
    // Test max_orders_to_execute limit with multiple execution calls:
    // - ALICE adds 5 trigger_below orders
    // - All 5 are triggered by price movement
    // - First execution: max_orders_to_execute = 2 (executes 2, 3 remain)
    // - Second execution: max_orders_to_execute = 2 (executes 2 more, 1 remains)
    // - Tests batched execution across multiple calls

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
    let sui_price_high = build_sui_price_info_object_with_price(&mut scenario, 200, &clock); // $2.00
    let usdc_price = build_usdc_price_info_object(&mut scenario, &clock);

    // Deposit collateral
    mm.deposit<SUI, USDC, SUI>(
        &margin_registry,
        &sui_price_high,
        &usdc_price,
        mint_coin<SUI>(10000 * test_constants::sui_multiplier(), scenario.ctx()),
        &clock,
        scenario.ctx(),
    );

    // Add 5 trigger_below orders at different prices (all will trigger when price drops to $0.50)
    let trigger_prices = vector[
        1_800_000, // $1.80 - ID 1
        1_600_000, // $1.60 - ID 2
        1_400_000, // $1.40 - ID 3
        1_200_000, // $1.20 - ID 4
        1_000_000, // $1.00 - ID 5
    ];

    let mut i = 0;
    while (i < trigger_prices.length()) {
        let condition = tpsl::new_condition(true, trigger_prices[i]);
        let pending_order = tpsl::new_pending_limit_order(
            i + 1,
            constants::no_restriction(),
            constants::self_matching_allowed(),
            400_000_000_000, // $0.40
            10 * test_constants::sui_multiplier(),
            false,
            false,
            constants::max_u64(),
        );

        mm.add_conditional_order<SUI, USDC>(
            &pool,
            &sui_price_high,
            &usdc_price,
            &margin_registry,
            i + 1,
            condition,
            pending_order,
            &clock,
            scenario.ctx(),
        );
        i = i + 1;
    };

    // Verify all 5 orders were added
    assert!(mm.conditional_order_ids().length() == 5);

    destroy_2!(sui_price_high, usdc_price);
    return_shared(pool);
    return_shared(margin_registry);

    // USER2 = BOB executes when price drops to $0.50 (triggers all 5 orders)
    // First execution call with max = 2
    scenario.next_tx(test_constants::user2());
    let sui_price_low = build_sui_price_info_object_with_price(&mut scenario, 50, &clock); // $0.50
    let usdc_price = build_usdc_price_info_object(&mut scenario, &clock);

    let mut pool = scenario.take_shared<Pool<SUI, USDC>>();
    let margin_registry = scenario.take_shared<MarginRegistry>();

    // First execution: max_orders_to_execute = 2
    let order_infos_1 = mm.execute_conditional_orders<SUI, USDC>(
        &mut pool,
        &sui_price_low,
        &usdc_price,
        &margin_registry,
        2, // Execute only 2 orders
        &clock,
        scenario.ctx(),
    );

    // First batch: 2 orders executed (ID 1, 2)
    assert!(order_infos_1.length() == 2);
    assert!(order_infos_1[0].client_order_id() == 1);
    assert!(order_infos_1[1].client_order_id() == 2);

    destroy(order_infos_1[0]);
    destroy(order_infos_1[1]);

    // 3 orders should remain (ID 3, 4, 5)
    assert!(mm.conditional_order_ids().length() == 3);

    destroy_2!(sui_price_low, usdc_price);
    return_shared(pool);
    return_shared(margin_registry);

    // Second execution call with max = 2
    scenario.next_tx(test_constants::user2());
    let sui_price_low2 = build_sui_price_info_object_with_price(&mut scenario, 50, &clock); // $0.50
    let usdc_price2 = build_usdc_price_info_object(&mut scenario, &clock);

    let mut pool = scenario.take_shared<Pool<SUI, USDC>>();
    let margin_registry = scenario.take_shared<MarginRegistry>();

    // Second execution: max_orders_to_execute = 2
    let order_infos_2 = mm.execute_conditional_orders<SUI, USDC>(
        &mut pool,
        &sui_price_low2,
        &usdc_price2,
        &margin_registry,
        2, // Execute 2 more orders
        &clock,
        scenario.ctx(),
    );

    // Second batch: 2 more orders executed (ID 3, 4)
    assert!(order_infos_2.length() == 2);
    assert!(order_infos_2[0].client_order_id() == 3);
    assert!(order_infos_2[1].client_order_id() == 4);

    destroy(order_infos_2[0]);
    destroy(order_infos_2[1]);

    // Only 1 order should remain (ID 5)
    let remaining_ids = mm.conditional_order_ids();
    assert!(remaining_ids.length() == 1);

    // Verify the remaining order
    let order_5 = mm.conditional_order(remaining_ids[0]);
    assert!(order_5.condition().trigger_price() == 1_000_000); // $1.00

    destroy_2!(sui_price_low2, usdc_price2);
    return_shared_2!(mm, pool);

    let deepbook_registry = scenario.take_shared_by_id<Registry>(registry_id);
    return_shared(deepbook_registry);
    cleanup_margin_test(margin_registry, admin_cap, maintainer_cap, clock, scenario);
}
