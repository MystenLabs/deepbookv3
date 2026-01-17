// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module deepbook_margin::margin_pool_tests;

use deepbook::{constants, math};
use deepbook_margin::{
    margin_constants,
    margin_pool::{Self, MarginPool},
    margin_registry::{Self, MarginRegistry, MarginAdminCap, MaintainerCap, MarginPoolCap},
    protocol_config,
    protocol_fees,
    test_constants::{Self, USDC, USDT},
    test_helpers::{Self, mint_coin, advance_time}
};
use std::unit_test::{assert_eq, destroy};
use sui::{clock::Clock, coin::Coin, test_scenario::{Self as test, Scenario, return_shared}};

fun setup_test(): (Scenario, Clock, MarginAdminCap, MaintainerCap, ID) {
    let (mut scenario, admin_cap) = test_helpers::setup_test();

    scenario.next_tx(test_constants::admin());
    let mut registry = scenario.take_shared<MarginRegistry>();
    let clock = scenario.take_shared<Clock>();
    let maintainer_cap = margin_registry::mint_maintainer_cap(
        &mut registry,
        &admin_cap,
        &clock,
        scenario.ctx(),
    );
    test::return_shared(registry);

    let protocol_config = test_helpers::default_protocol_config();
    let pool_id = test_helpers::create_margin_pool<USDC>(
        &mut scenario,
        &maintainer_cap,
        protocol_config,
        &clock,
    );
    scenario.next_tx(test_constants::admin());

    (scenario, clock, admin_cap, maintainer_cap, pool_id)
}

fun cleanup_test(
    registry: MarginRegistry,
    admin_cap: MarginAdminCap,
    maintainer_cap: MaintainerCap,
    clock: Clock,
    scenario: Scenario,
) {
    return_shared(registry);
    destroy(admin_cap);
    destroy(maintainer_cap);
    destroy(clock);
    scenario.end();
}

fun setup_usdt_pool_with_cap(
    scenario: &mut Scenario,
    maintainer_cap: &MaintainerCap,
    clock: &Clock,
): MarginPoolCap {
    scenario.next_tx(test_constants::admin());
    let mut registry = scenario.take_shared<MarginRegistry>();
    let config2 = test_helpers::default_protocol_config();
    let _pool_id2 = margin_pool::create_margin_pool<USDT>(
        &mut registry,
        config2,
        maintainer_cap,
        clock,
        scenario.ctx(),
    );
    test::return_shared(registry);

    scenario.next_tx(test_constants::admin());
    scenario.take_from_sender<MarginPoolCap>()
}

public fun test_borrow<Asset>(
    pool: &mut MarginPool<Asset>,
    amount: u64,
    clock: &Clock,
    ctx: &mut TxContext,
): Coin<Asset> {
    let (coin, _) = pool.borrow(amount, clock, ctx);

    coin
}

#[test]
fun test_supply_and_withdraw_basic() {
    let (mut scenario, clock, admin_cap, maintainer_cap, pool_id) = setup_test();

    scenario.next_tx(test_constants::admin());
    let mut pool = scenario.take_shared_by_id<MarginPool<USDC>>(pool_id);
    let registry = scenario.take_shared<MarginRegistry>();

    scenario.next_tx(test_constants::user1());
    let supplier_cap = test_helpers::supply_to_pool(
        &mut pool,
        &registry,
        100 * test_constants::usdc_multiplier(),
        &clock,
        scenario.ctx(),
    );

    let withdrawn = pool.withdraw<USDC>(
        &registry,
        &supplier_cap,
        option::some(50 * test_constants::usdc_multiplier()),
        &clock,
        scenario.ctx(),
    ); // 50 tokens
    assert!(withdrawn.value() == 50 * test_constants::usdc_multiplier());

    destroy(withdrawn);
    destroy(supplier_cap);
    test::return_shared(pool);
    cleanup_test(registry, admin_cap, maintainer_cap, clock, scenario);
}

#[test, expected_failure(abort_code = margin_pool::ESupplyCapExceeded)]
fun test_supply_cap_enforcement() {
    let (mut scenario, clock, admin_cap, maintainer_cap, pool_id) = setup_test();

    scenario.next_tx(test_constants::admin());
    let mut pool = scenario.take_shared_by_id<MarginPool<USDC>>(pool_id);
    let registry = scenario.take_shared<MarginRegistry>();
    scenario.next_tx(test_constants::user1());
    let supplier_cap = test_helpers::supply_to_pool(
        &mut pool,
        &registry,
        test_constants::supply_cap() + 1,
        &clock,
        scenario.ctx(),
    );

    // This should fail due to supply cap
    destroy(supplier_cap);
    test::return_shared(pool);
    cleanup_test(registry, admin_cap, maintainer_cap, clock, scenario);
}

#[test]
fun test_multiple_users_supply_withdraw() {
    let (mut scenario, clock, admin_cap, maintainer_cap, pool_id) = setup_test();
    let mut pool = scenario.take_shared_by_id<MarginPool<USDC>>(pool_id);
    let registry = scenario.take_shared<MarginRegistry>();

    // User1 supplies
    scenario.next_tx(test_constants::user1());
    let supplier_cap1 = test_helpers::supply_to_pool(
        &mut pool,
        &registry,
        50 * test_constants::usdc_multiplier(),
        &clock,
        scenario.ctx(),
    );

    // User2 supplies
    scenario.next_tx(test_constants::user2());
    let supplier_cap2 = test_helpers::supply_to_pool(
        &mut pool,
        &registry,
        30 * test_constants::usdc_multiplier(),
        &clock,
        scenario.ctx(),
    );

    scenario.next_tx(test_constants::user1());
    let withdrawn1 = pool.withdraw<USDC>(
        &registry,
        &supplier_cap1,
        option::some(25 * test_constants::usdc_multiplier()),
        &clock,
        scenario.ctx(),
    );
    assert!(withdrawn1.value() == 25 * test_constants::usdc_multiplier());

    scenario.next_tx(test_constants::user2());
    let withdrawn2 = pool.withdraw<USDC>(
        &registry,
        &supplier_cap2,
        option::some(15 * test_constants::usdc_multiplier()),
        &clock,
        scenario.ctx(),
    );
    assert!(withdrawn2.value() == 15 * test_constants::usdc_multiplier());

    destroy(withdrawn1);
    destroy(withdrawn2);
    destroy(supplier_cap1);
    destroy(supplier_cap2);
    test::return_shared(pool);
    cleanup_test(registry, admin_cap, maintainer_cap, clock, scenario);
}

#[test]
fun test_withdraw_all() {
    let (mut scenario, clock, admin_cap, maintainer_cap, pool_id) = setup_test();
    let mut pool = scenario.take_shared_by_id<MarginPool<USDC>>(pool_id);
    let registry = scenario.take_shared<MarginRegistry>();

    scenario.next_tx(test_constants::user1());
    let supply_amount = 100 * test_constants::usdc_multiplier();
    let supplier_cap = test_helpers::supply_to_pool(
        &mut pool,
        &registry,
        supply_amount,
        &clock,
        scenario.ctx(),
    );

    let withdrawn = pool.withdraw<USDC>(
        &registry,
        &supplier_cap,
        option::none(),
        &clock,
        scenario.ctx(),
    );
    assert!(withdrawn.value() == supply_amount);

    destroy(withdrawn);
    destroy(supplier_cap);
    test::return_shared(pool);
    cleanup_test(registry, admin_cap, maintainer_cap, clock, scenario);
}

#[test]
fun test_create_margin_pool_with_config() {
    let (scenario, clock, admin_cap, maintainer_cap, pool_id) = setup_test();
    let pool = scenario.take_shared_by_id<MarginPool<USDC>>(pool_id);
    let registry = scenario.take_shared<MarginRegistry>();

    test::return_shared(pool);
    cleanup_test(registry, admin_cap, maintainer_cap, clock, scenario);
}

#[test]
fun test_interest_accrual_over_time() {
    let (mut scenario, mut clock, admin_cap, maintainer_cap, pool_id) = setup_test();

    let mut pool = scenario.take_shared_by_id<MarginPool<USDC>>(pool_id);
    let registry = scenario.take_shared<MarginRegistry>();
    scenario.next_tx(test_constants::user1());
    let supply_amount = 100 * test_constants::usdc_multiplier();
    let supplier_cap = test_helpers::supply_to_pool(
        &mut pool,
        &registry,
        supply_amount,
        &clock,
        scenario.ctx(),
    );

    clock.set_for_testing(margin_constants::year_ms());

    let withdrawn = pool.withdraw<USDC>(
        &registry,
        &supplier_cap,
        option::none(),
        &clock,
        scenario.ctx(),
    );
    assert!(withdrawn.value() >= supply_amount);

    destroy(withdrawn);
    destroy(supplier_cap);
    test::return_shared(pool);
    cleanup_test(registry, admin_cap, maintainer_cap, clock, scenario);
}

#[test, expected_failure(abort_code = margin_pool::ENotEnoughAssetInPool)]
fun test_not_enough_asset_in_pool() {
    let (mut scenario, clock, admin_cap, maintainer_cap, pool_id) = setup_test();
    let mut pool = scenario.take_shared_by_id<MarginPool<USDC>>(pool_id);
    let registry = scenario.take_shared<MarginRegistry>();

    scenario.next_tx(test_constants::user1());
    let supplier_cap = test_helpers::supply_to_pool(
        &mut pool,
        &registry,
        100 * test_constants::usdc_multiplier(),
        &clock,
        scenario.ctx(),
    );

    scenario.next_tx(test_constants::user2());
    let borrowed_coin = test_borrow(
        &mut pool,
        80 * test_constants::usdc_multiplier(),
        &clock,
        scenario.ctx(),
    ); // 80 tokens
    destroy(borrowed_coin);

    // Should fail due to outstanding loan
    scenario.next_tx(test_constants::user1());
    let withdrawn = pool.withdraw<USDC>(
        &registry,
        &supplier_cap,
        option::none(),
        &clock,
        scenario.ctx(),
    );

    destroy(withdrawn);
    destroy(supplier_cap);
    test::return_shared(pool);
    cleanup_test(registry, admin_cap, maintainer_cap, clock, scenario);
}

#[test, expected_failure(abort_code = margin_pool::EMaxPoolBorrowPercentageExceeded)]
fun test_max_pool_borrow_percentage_exceeded() {
    let (mut scenario, clock, admin_cap, maintainer_cap, pool_id) = setup_test();
    let mut pool = scenario.take_shared_by_id<MarginPool<USDC>>(pool_id);
    let registry = scenario.take_shared<MarginRegistry>();

    scenario.next_tx(test_constants::user1());
    let supplier_cap = test_helpers::supply_to_pool(
        &mut pool,
        &registry,
        100 * test_constants::usdc_multiplier(),
        &clock,
        scenario.ctx(),
    );

    // Above max utilization rate
    scenario.next_tx(test_constants::user2());
    let borrowed_coin = test_borrow(
        &mut pool,
        85 * test_constants::usdc_multiplier(),
        &clock,
        scenario.ctx(),
    ); // 85 tokens > 80%

    destroy(borrowed_coin);
    destroy(supplier_cap);
    test::return_shared(pool);
    cleanup_test(registry, admin_cap, maintainer_cap, clock, scenario);
}

#[test, expected_failure(abort_code = margin_pool::EBorrowAmountTooLow)]
fun test_invalid_loan_quantity() {
    let (mut scenario, clock, admin_cap, maintainer_cap, pool_id) = setup_test();
    let mut pool = scenario.take_shared_by_id<MarginPool<USDC>>(pool_id);
    let registry = scenario.take_shared<MarginRegistry>();

    scenario.next_tx(test_constants::user1());
    let supplier_cap = test_helpers::supply_to_pool(
        &mut pool,
        &registry,
        100_000_000_000,
        &clock,
        scenario.ctx(),
    );

    scenario.next_tx(test_constants::user2());
    let borrowed_coin = test_borrow(&mut pool, 0, &clock, scenario.ctx());

    destroy(borrowed_coin);
    destroy(supplier_cap);
    test::return_shared(pool);
    cleanup_test(registry, admin_cap, maintainer_cap, clock, scenario);
}

#[test, expected_failure(abort_code = margin_pool::EDeepbookPoolAlreadyAllowed)]
fun test_deepbook_pool_already_allowed() {
    let (scenario, clock, admin_cap, maintainer_cap, pool_id) = setup_test();
    let mut pool = scenario.take_shared_by_id<MarginPool<USDC>>(pool_id);
    let registry = scenario.take_shared<MarginRegistry>();

    let margin_pool_cap = scenario.take_from_sender<MarginPoolCap>();

    let deepbook_pool_id = object::id_from_address(@0x123);

    pool.enable_deepbook_pool_for_loan(&registry, deepbook_pool_id, &margin_pool_cap, &clock);
    pool.enable_deepbook_pool_for_loan(&registry, deepbook_pool_id, &margin_pool_cap, &clock);

    scenario.return_to_sender(margin_pool_cap);
    test::return_shared(pool);
    cleanup_test(registry, admin_cap, maintainer_cap, clock, scenario);
}

#[test, expected_failure(abort_code = margin_pool::EInvalidMarginPoolCap)]
fun test_invalid_margin_pool_cap() {
    let (mut scenario, clock, admin_cap, maintainer_cap, pool_id) = setup_test();

    let wrong_margin_pool_cap = setup_usdt_pool_with_cap(&mut scenario, &maintainer_cap, &clock);
    let mut pool = scenario.take_shared_by_id<MarginPool<USDC>>(pool_id);
    let registry = scenario.take_shared<MarginRegistry>();
    let deepbook_pool_id = object::id_from_address(@0x123);

    // Try to use wrong cap with the first pool (should fail)
    pool.enable_deepbook_pool_for_loan(&registry, deepbook_pool_id, &wrong_margin_pool_cap, &clock);

    scenario.return_to_sender(wrong_margin_pool_cap);
    test::return_shared(pool);
    cleanup_test(registry, admin_cap, maintainer_cap, clock, scenario);
}

#[test, expected_failure(abort_code = margin_pool::EInvalidMarginPoolCap)]
fun test_disable_with_invalid_margin_pool_cap() {
    let (mut scenario, clock, admin_cap, maintainer_cap, pool_id) = setup_test();

    let correct_cap = scenario.take_from_sender<MarginPoolCap>();
    let wrong_cap = setup_usdt_pool_with_cap(&mut scenario, &maintainer_cap, &clock);

    let mut pool = scenario.take_shared_by_id<MarginPool<USDC>>(pool_id);
    let registry = scenario.take_shared<MarginRegistry>();
    let deepbook_pool_id = object::id_from_address(@0x123);

    pool.enable_deepbook_pool_for_loan(&registry, deepbook_pool_id, &correct_cap, &clock);

    pool.disable_deepbook_pool_for_loan(&registry, deepbook_pool_id, &wrong_cap, &clock);

    scenario.return_to_sender(correct_cap);
    scenario.return_to_sender(wrong_cap);
    test::return_shared(pool);
    cleanup_test(registry, admin_cap, maintainer_cap, clock, scenario);
}

#[test]
fun test_disable_deepbook_pool_for_loan() {
    let (scenario, clock, admin_cap, maintainer_cap, pool_id) = setup_test();
    let mut pool = scenario.take_shared_by_id<MarginPool<USDC>>(pool_id);
    let registry = scenario.take_shared<MarginRegistry>();
    let margin_pool_cap = scenario.take_from_sender<MarginPoolCap>();
    let deepbook_pool_id = object::id_from_address(@0x123);

    pool.enable_deepbook_pool_for_loan(&registry, deepbook_pool_id, &margin_pool_cap, &clock);
    assert!(pool.deepbook_pool_allowed(deepbook_pool_id));

    pool.disable_deepbook_pool_for_loan(&registry, deepbook_pool_id, &margin_pool_cap, &clock);
    assert!(!pool.deepbook_pool_allowed(deepbook_pool_id));

    scenario.return_to_sender(margin_pool_cap);
    test::return_shared(pool);
    cleanup_test(registry, admin_cap, maintainer_cap, clock, scenario);
}

#[test, expected_failure(abort_code = margin_pool::EDeepbookPoolNotAllowed)]
fun test_disable_deepbook_pool_not_allowed() {
    let (scenario, clock, admin_cap, maintainer_cap, pool_id) = setup_test();
    let mut pool = scenario.take_shared_by_id<MarginPool<USDC>>(pool_id);
    let registry = scenario.take_shared<MarginRegistry>();
    let margin_pool_cap = scenario.take_from_sender<MarginPoolCap>();
    let deepbook_pool_id = object::id_from_address(@0x123);

    // disable without enabling first
    pool.disable_deepbook_pool_for_loan(&registry, deepbook_pool_id, &margin_pool_cap, &clock);

    scenario.return_to_sender(margin_pool_cap);
    test::return_shared(pool);
    cleanup_test(registry, admin_cap, maintainer_cap, clock, scenario);
}

#[test]
fun test_update_interest_params() {
    let (scenario, clock, admin_cap, maintainer_cap, pool_id) = setup_test();
    let mut pool = scenario.take_shared_by_id<MarginPool<USDC>>(pool_id);
    let registry = scenario.take_shared<MarginRegistry>();
    let margin_pool_cap = scenario.take_from_sender<MarginPoolCap>();

    let new_interest_config = protocol_config::new_interest_config(
        100_000_000, // base_rate: 10%
        200_000_000, // base_slope: 20%
        700_000_000, // optimal_utilization: 70%
        3_000_000_000, // excess_slope: 300%
    );

    pool.update_interest_params(&registry, new_interest_config, &margin_pool_cap, &clock);

    scenario.return_to_sender(margin_pool_cap);
    test::return_shared(pool);
    cleanup_test(registry, admin_cap, maintainer_cap, clock, scenario);
}

#[test, expected_failure(abort_code = margin_pool::EInvalidMarginPoolCap)]
fun test_update_interest_params_with_invalid_cap() {
    let (mut scenario, clock, admin_cap, maintainer_cap, pool_id) = setup_test();
    let correct_cap = scenario.take_from_sender<MarginPoolCap>();
    let wrong_cap = setup_usdt_pool_with_cap(&mut scenario, &maintainer_cap, &clock);

    scenario.next_tx(test_constants::admin());
    let mut pool = scenario.take_shared_by_id<MarginPool<USDC>>(pool_id);
    let registry = scenario.take_shared<MarginRegistry>();

    // Create new interest config
    let new_interest_config = protocol_config::new_interest_config(
        100_000_000,
        200_000_000,
        700_000_000,
        3_000_000_000,
    );

    pool.update_interest_params(&registry, new_interest_config, &wrong_cap, &clock);

    scenario.return_to_sender(correct_cap);
    scenario.return_to_sender(wrong_cap);
    test::return_shared(pool);
    cleanup_test(registry, admin_cap, maintainer_cap, clock, scenario);
}

#[test]
fun test_update_margin_pool_config() {
    let (scenario, clock, admin_cap, maintainer_cap, pool_id) = setup_test();
    let mut pool = scenario.take_shared_by_id<MarginPool<USDC>>(pool_id);
    let registry = scenario.take_shared<MarginRegistry>();
    let margin_pool_cap = scenario.take_from_sender<MarginPoolCap>();

    let new_margin_pool_config = protocol_config::new_margin_pool_config(
        2_000_000_000_000_000, // supply_cap: 2M tokens
        900_000_000, // max_utilization_rate: 90%
        5_000_000, // protocol_spread: 0.5%
        100_000_000, // min_borrow: 0.1 token
    );

    pool.update_margin_pool_config(&registry, new_margin_pool_config, &margin_pool_cap, &clock);

    scenario.return_to_sender(margin_pool_cap);
    test::return_shared(pool);
    cleanup_test(registry, admin_cap, maintainer_cap, clock, scenario);
}

#[test, expected_failure(abort_code = margin_pool::EInvalidMarginPoolCap)]
fun test_update_margin_pool_config_with_invalid_cap() {
    let (mut scenario, clock, admin_cap, maintainer_cap, pool_id) = setup_test();

    // Get the first pool's cap
    let correct_cap = scenario.take_from_sender<MarginPoolCap>();
    let wrong_cap = setup_usdt_pool_with_cap(&mut scenario, &maintainer_cap, &clock);

    scenario.next_tx(test_constants::admin());
    let mut pool = scenario.take_shared_by_id<MarginPool<USDC>>(pool_id);
    let registry = scenario.take_shared<MarginRegistry>();

    // Create new margin pool config
    let new_margin_pool_config = protocol_config::new_margin_pool_config(
        2_000_000_000_000_000,
        900_000_000,
        5_000_000,
        100_000_000,
    );

    // Try to update with wrong cap
    pool.update_margin_pool_config(&registry, new_margin_pool_config, &wrong_cap, &clock);

    scenario.return_to_sender(correct_cap);
    scenario.return_to_sender(wrong_cap);
    test::return_shared(pool);
    cleanup_test(registry, admin_cap, maintainer_cap, clock, scenario);
}

#[test]
fun test_repay_liquidation_with_reward() {
    let (mut scenario, clock, admin_cap, maintainer_cap, pool_id) = setup_test();
    let mut pool = scenario.take_shared_by_id<MarginPool<USDC>>(pool_id);
    let registry = scenario.take_shared<MarginRegistry>();

    // User1 supplies
    scenario.next_tx(test_constants::user1());
    let supplier_cap = test_helpers::supply_to_pool(
        &mut pool,
        &registry,
        100 * test_constants::usdc_multiplier(),
        &clock,
        scenario.ctx(),
    );

    // User2 borrows
    scenario.next_tx(test_constants::user2());
    let (borrowed_coin, shares) = pool.borrow(
        50 * test_constants::usdc_multiplier(),
        &clock,
        scenario.ctx(),
    );
    destroy(borrowed_coin);

    // Liquidation with extra amount (reward scenario)
    let repay_amount = pool.borrow_shares_to_amount(shares, &clock);
    let extra_amount = 5 * test_constants::usdc_multiplier();
    let liquidation_coin = mint_coin<USDC>(repay_amount + extra_amount, scenario.ctx());
    let (amount, reward, default) = pool.repay_liquidation(shares, liquidation_coin, &clock);

    assert!(amount == repay_amount);
    assert!(reward == extra_amount);
    assert!(default == 0);

    destroy(supplier_cap);
    test::return_shared(pool);
    cleanup_test(registry, admin_cap, maintainer_cap, clock, scenario);
}

#[test]
fun test_repay_liquidation_with_default() {
    let (mut scenario, clock, admin_cap, maintainer_cap, pool_id) = setup_test();
    let mut pool = scenario.take_shared_by_id<MarginPool<USDC>>(pool_id);
    let registry = scenario.take_shared<MarginRegistry>();

    // User1 supplies
    scenario.next_tx(test_constants::user1());
    let supplier_cap = test_helpers::supply_to_pool(
        &mut pool,
        &registry,
        100 * test_constants::usdc_multiplier(),
        &clock,
        scenario.ctx(),
    );

    // User2 borrows
    scenario.next_tx(test_constants::user2());
    let (borrowed_coin, shares) = pool.borrow(
        50 * test_constants::usdc_multiplier(),
        &clock,
        scenario.ctx(),
    );
    destroy(borrowed_coin);

    // Liquidation with insufficient amount (default scenario)
    let repay_amount = pool.borrow_shares_to_amount(shares, &clock);
    let insufficient_amount = repay_amount - 10 * test_constants::usdc_multiplier();
    let liquidation_coin = mint_coin<USDC>(insufficient_amount, scenario.ctx());
    let (amount, reward, default) = pool.repay_liquidation(shares, liquidation_coin, &clock);

    assert!(amount == repay_amount);
    assert!(reward == 0);
    assert!(default == 10 * test_constants::usdc_multiplier());

    destroy(supplier_cap);
    test::return_shared(pool);
    cleanup_test(registry, admin_cap, maintainer_cap, clock, scenario);
}

#[test]
fun test_multiple_deepbook_pools() {
    let (scenario, clock, admin_cap, maintainer_cap, pool_id) = setup_test();
    let mut pool = scenario.take_shared_by_id<MarginPool<USDC>>(pool_id);
    let registry = scenario.take_shared<MarginRegistry>();
    let margin_pool_cap = scenario.take_from_sender<MarginPoolCap>();

    let deepbook_pool_id1 = object::id_from_address(@0x123);
    let deepbook_pool_id2 = object::id_from_address(@0x456);
    let deepbook_pool_id3 = object::id_from_address(@0x789);

    // Enable multiple pools
    pool.enable_deepbook_pool_for_loan(&registry, deepbook_pool_id1, &margin_pool_cap, &clock);
    pool.enable_deepbook_pool_for_loan(&registry, deepbook_pool_id2, &margin_pool_cap, &clock);
    pool.enable_deepbook_pool_for_loan(&registry, deepbook_pool_id3, &margin_pool_cap, &clock);

    assert!(pool.deepbook_pool_allowed(deepbook_pool_id1));
    assert!(pool.deepbook_pool_allowed(deepbook_pool_id2));
    assert!(pool.deepbook_pool_allowed(deepbook_pool_id3));

    // Disable one pool
    pool.disable_deepbook_pool_for_loan(&registry, deepbook_pool_id2, &margin_pool_cap, &clock);

    assert!(pool.deepbook_pool_allowed(deepbook_pool_id1));
    assert!(!pool.deepbook_pool_allowed(deepbook_pool_id2));
    assert!(pool.deepbook_pool_allowed(deepbook_pool_id3));

    scenario.return_to_sender(margin_pool_cap);
    test::return_shared(pool);
    cleanup_test(registry, admin_cap, maintainer_cap, clock, scenario);
}

#[test, expected_failure(abort_code = margin_pool::ENotEnoughAssetInPool)]
fun test_borrow_exceeds_vault_balance() {
    let (mut scenario, clock, admin_cap, maintainer_cap, pool_id) = setup_test();
    let mut pool = scenario.take_shared_by_id<MarginPool<USDC>>(pool_id);
    let registry = scenario.take_shared<MarginRegistry>();

    // User1 supplies 100 USDC
    scenario.next_tx(test_constants::user1());
    let supply_amount = 100 * test_constants::usdc_multiplier();
    let supplier_cap = test_helpers::supply_to_pool(
        &mut pool,
        &registry,
        supply_amount,
        &clock,
        scenario.ctx(),
    );

    // User2 borrows 70 USDC
    scenario.next_tx(test_constants::user2());
    let first_borrow = 70 * test_constants::usdc_multiplier();
    let (borrowed_coin1, _) = pool.borrow(first_borrow, &clock, scenario.ctx());
    destroy(borrowed_coin1);

    // User3 tries to borrow $1 more than what's left in the vault
    scenario.next_tx(test_constants::liquidator());
    let second_borrow = 31 * test_constants::usdc_multiplier();
    let (borrowed_coin2, _) = pool.borrow(second_borrow, &clock, scenario.ctx());

    destroy(borrowed_coin2);
    destroy(supplier_cap);
    test::return_shared(pool);
    cleanup_test(registry, admin_cap, maintainer_cap, clock, scenario);
}

#[test, expected_failure(abort_code = margin_pool::ENotEnoughAssetInPool)]
fun test_withdraw_exceeds_available_liquidity() {
    let (mut scenario, clock, admin_cap, maintainer_cap, pool_id) = setup_test();
    let mut pool = scenario.take_shared_by_id<MarginPool<USDC>>(pool_id);
    let registry = scenario.take_shared<MarginRegistry>();

    // User1 and User2 both supply
    scenario.next_tx(test_constants::user1());
    let supply1 = 60 * test_constants::usdc_multiplier();
    let supplier_cap1 = test_helpers::supply_to_pool(
        &mut pool,
        &registry,
        supply1,
        &clock,
        scenario.ctx(),
    );

    scenario.next_tx(test_constants::user2());
    let supply2 = 40 * test_constants::usdc_multiplier();
    let supplier_cap2 = test_helpers::supply_to_pool(
        &mut pool,
        &registry,
        supply2,
        &clock,
        scenario.ctx(),
    );

    // Someone borrows, reducing available liquidity
    scenario.next_tx(test_constants::liquidator());
    let borrow_amount = 75 * test_constants::usdc_multiplier();
    let (borrowed_coin, _) = pool.borrow(borrow_amount, &clock, scenario.ctx());
    destroy(borrowed_coin);

    // Now only 25 USDC left in vault
    // User1 tries to withdraw their full 60 USDC, but only 25 is available
    scenario.next_tx(test_constants::user1());
    let withdrawn = pool.withdraw<USDC>(
        &registry,
        &supplier_cap1,
        option::none(), // withdraw all
        &clock,
        scenario.ctx(),
    );

    destroy(withdrawn);
    destroy(supplier_cap1);
    destroy(supplier_cap2);
    test::return_shared(pool);
    cleanup_test(registry, admin_cap, maintainer_cap, clock, scenario);
}

#[test]
fun test_liquidation_exact_amount() {
    let (mut scenario, clock, admin_cap, maintainer_cap, pool_id) = setup_test();
    scenario.next_tx(test_constants::admin());
    let mut pool = scenario.take_shared_by_id<MarginPool<USDC>>(pool_id);
    let registry = scenario.take_shared<MarginRegistry>();

    scenario.next_tx(test_constants::user1());
    let supplier_cap = test_helpers::supply_to_pool(
        &mut pool,
        &registry,
        1000 * test_constants::usdc_multiplier(),
        &clock,
        scenario.ctx(),
    );

    scenario.next_tx(test_constants::user2());
    let (borrowed_coin, shares) = pool.borrow(
        500 * test_constants::usdc_multiplier(),
        &clock,
        scenario.ctx(),
    );
    destroy(borrowed_coin);

    let exact_amount = pool.borrow_shares_to_amount(shares, &clock);
    let liquidation_coin = mint_coin<USDC>(exact_amount, scenario.ctx());
    let (amount, reward, default) = pool.repay_liquidation(shares, liquidation_coin, &clock);

    assert!(amount == exact_amount);
    assert!(reward == 0);
    assert!(default == 0);

    destroy(supplier_cap);
    test::return_shared(pool);
    cleanup_test(registry, admin_cap, maintainer_cap, clock, scenario);
}

#[test]
fun test_liquidation_zero_shares() {
    let (mut scenario, clock, admin_cap, maintainer_cap, pool_id) = setup_test();
    scenario.next_tx(test_constants::admin());
    let mut pool = scenario.take_shared_by_id<MarginPool<USDC>>(pool_id);
    let registry = scenario.take_shared<MarginRegistry>();

    scenario.next_tx(test_constants::user1());
    let supplier_cap = test_helpers::supply_to_pool(
        &mut pool,
        &registry,
        1000 * test_constants::usdc_multiplier(),
        &clock,
        scenario.ctx(),
    );

    let liquidation_coin = mint_coin<USDC>(100 * test_constants::usdc_multiplier(), scenario.ctx());
    let (amount, reward, default) = pool.repay_liquidation(0, liquidation_coin, &clock);

    assert!(amount == 0);
    assert!(reward == 100 * test_constants::usdc_multiplier()); // all reward
    assert!(default == 0);

    destroy(supplier_cap);
    test::return_shared(pool);
    cleanup_test(registry, admin_cap, maintainer_cap, clock, scenario);
}

#[test]
fun test_supply_withdrawal_with_interest() {
    let (mut scenario, mut clock, admin_cap, maintainer_cap, pool_id) = setup_test();
    scenario.next_tx(test_constants::admin());
    let mut pool = scenario.take_shared_by_id<MarginPool<USDC>>(pool_id);
    let registry = scenario.take_shared<MarginRegistry>();

    // Two users supply
    scenario.next_tx(test_constants::user1());
    let supply1 = 1000 * test_constants::usdc_multiplier();
    let supplier_cap1 = test_helpers::supply_to_pool(
        &mut pool,
        &registry,
        supply1,
        &clock,
        scenario.ctx(),
    );

    scenario.next_tx(test_constants::user2());
    let supply2 = 500 * test_constants::usdc_multiplier();
    let supplier_cap2 = test_helpers::supply_to_pool(
        &mut pool,
        &registry,
        supply2,
        &clock,
        scenario.ctx(),
    );

    scenario.next_tx(test_constants::liquidator());
    let (borrowed_coin, _) = pool.borrow(
        750 * test_constants::usdc_multiplier(),
        &clock,
        scenario.ctx(),
    );
    destroy(borrowed_coin);

    advance_time(&mut clock, margin_constants::year_ms());

    // User1 withdraws 20% of initial deposit
    scenario.next_tx(test_constants::user1());
    let withdrawn1 = pool.withdraw(
        &registry,
        &supplier_cap1,
        option::some(200 * test_constants::usdc_multiplier()),
        &clock,
        scenario.ctx(),
    );

    assert_eq!(withdrawn1.value(), 200 * test_constants::usdc_multiplier());
    destroy(withdrawn1);

    // User2 tries to withdraw all
    scenario.next_tx(test_constants::user2());
    let withdrawn2 = pool.withdraw(
        &registry,
        &supplier_cap2,
        option::none(),
        &clock,
        scenario.ctx(),
    );

    assert!(withdrawn2.value() > supply2);
    destroy(withdrawn2);
    destroy(supplier_cap1);
    destroy(supplier_cap2);

    test::return_shared(pool);
    cleanup_test(registry, admin_cap, maintainer_cap, clock, scenario);
}

#[test]
fun test_partial_liquidation_half_shares() {
    let (mut scenario, mut clock, admin_cap, maintainer_cap, pool_id) = setup_test();
    scenario.next_tx(test_constants::admin());
    let mut pool = scenario.take_shared_by_id<MarginPool<USDC>>(pool_id);
    let registry = scenario.take_shared<MarginRegistry>();

    scenario.next_tx(test_constants::user1());
    let supplier_cap = test_helpers::supply_to_pool(
        &mut pool,
        &registry,
        10000 * test_constants::usdc_multiplier(),
        &clock,
        scenario.ctx(),
    );

    scenario.next_tx(test_constants::user2());
    let borrow_amount = 1000 * test_constants::usdc_multiplier();
    let (borrowed_coin, total_shares) = pool.borrow(borrow_amount, &clock, scenario.ctx());
    destroy(borrowed_coin);

    advance_time(&mut clock, margin_constants::year_ms());

    let half_shares = total_shares / 2;
    let half_amount = pool.borrow_shares_to_amount(half_shares, &clock);
    let liquidation_coin = mint_coin<USDC>(half_amount + 10000, scenario.ctx());
    let (amount, reward, default) = pool.repay_liquidation(half_shares, liquidation_coin, &clock);

    assert!(amount == half_amount);
    assert!(reward == 10000);
    assert!(default == 0);

    let remaining_shares = total_shares - half_shares;
    let remaining_amount = pool.borrow_shares_to_amount(remaining_shares, &clock);
    // remaining amount should include accrued interest
    assert!(remaining_amount > borrow_amount / 2);

    destroy(supplier_cap);
    test::return_shared(pool);
    cleanup_test(registry, admin_cap, maintainer_cap, clock, scenario);
}

#[test]
fun test_partial_liquidation_with_default() {
    let (mut scenario, mut clock, admin_cap, maintainer_cap, pool_id) = setup_test();
    scenario.next_tx(test_constants::admin());
    let mut pool = scenario.take_shared_by_id<MarginPool<USDC>>(pool_id);
    let registry = scenario.take_shared<MarginRegistry>();

    scenario.next_tx(test_constants::user1());
    let supplier_cap = test_helpers::supply_to_pool(
        &mut pool,
        &registry,
        10000 * test_constants::usdc_multiplier(),
        &clock,
        scenario.ctx(),
    );

    scenario.next_tx(test_constants::user2());
    let borrow_amount = 2000 * test_constants::usdc_multiplier();
    let (borrowed_coin, total_shares) = pool.borrow(borrow_amount, &clock, scenario.ctx());
    destroy(borrowed_coin);

    advance_time(&mut clock, margin_constants::year_ms() / 6);

    // Partial liquidation of 30% shares with insufficient payment
    let partial_shares = total_shares / 2;
    let required_amount = pool.borrow_shares_to_amount(partial_shares, &clock);
    let insufficient_amount = (required_amount * 90) / 100;
    let liquidation_coin = mint_coin<USDC>(insufficient_amount, scenario.ctx());
    let (amount, reward, default) = pool.repay_liquidation(
        partial_shares,
        liquidation_coin,
        &clock,
    );

    assert!(amount == required_amount);
    assert!(reward == 0);
    assert!(default == required_amount - insufficient_amount);

    let remaining_shares = total_shares - partial_shares;
    let remaining_amount = pool.borrow_shares_to_amount(remaining_shares, &clock);
    assert!(remaining_amount > 0);

    destroy(supplier_cap);
    test::return_shared(pool);
    cleanup_test(registry, admin_cap, maintainer_cap, clock, scenario);
}

#[test]
fun test_full_liquidation_with_interest() {
    let (mut scenario, mut clock, admin_cap, maintainer_cap, pool_id) = setup_test();
    scenario.next_tx(test_constants::admin());
    let mut pool = scenario.take_shared_by_id<MarginPool<USDC>>(pool_id);
    let registry = scenario.take_shared<MarginRegistry>();

    scenario.next_tx(test_constants::user1());
    let supply_amount = 10000 * test_constants::usdc_multiplier();
    let supplier_cap = test_helpers::supply_to_pool(
        &mut pool,
        &registry,
        supply_amount,
        &clock,
        scenario.ctx(),
    );

    scenario.next_tx(test_constants::user2());
    let borrow_amount = 3000 * test_constants::usdc_multiplier();
    let (borrowed_coin, borrow_shares) = pool.borrow(borrow_amount, &clock, scenario.ctx());
    destroy(borrowed_coin);

    let initial_debt = pool.borrow_shares_to_amount(borrow_shares, &clock);
    assert!(initial_debt == borrow_amount);

    advance_time(&mut clock, margin_constants::year_ms());

    // Check debt has grown substantially due to interest
    let debt_after_interest = pool.borrow_shares_to_amount(borrow_shares, &clock);
    assert!(debt_after_interest > initial_debt);

    scenario.next_tx(test_constants::liquidator());
    let liquidation_coin = mint_coin<USDC>(debt_after_interest + 1000, scenario.ctx());
    let (_, reward, default) = pool.repay_liquidation(
        borrow_shares,
        liquidation_coin,
        &clock,
    );
    assert!(reward > 0);
    assert!(default == 0);

    // User should be able to withdraw supply plus interest earned
    scenario.next_tx(test_constants::user1());
    let withdrawn = pool.withdraw(&registry, &supplier_cap, option::none(), &clock, scenario.ctx());
    let interest_earned = withdrawn.value() - supply_amount;
    assert!(withdrawn.value() > supply_amount);
    assert!(interest_earned > 0);

    destroy(withdrawn);
    destroy(supplier_cap);
    test::return_shared(pool);
    cleanup_test(registry, admin_cap, maintainer_cap, clock, scenario);
}

#[test]
fun test_user_supply_shares_tracks_individual_users() {
    let (mut scenario, clock, admin_cap, maintainer_cap, pool_id) = setup_test();

    // User1 supplies 20 USDC
    scenario.next_tx(test_constants::user1());
    let mut pool = scenario.take_shared_by_id<MarginPool<USDC>>(pool_id);
    let registry = scenario.take_shared<MarginRegistry>();
    let supplier_cap_1 = margin_pool::mint_supplier_cap(&registry, &clock, scenario.ctx());
    let supplier_cap_1_id = object::id(&supplier_cap_1);
    let supply_coin_1 = mint_coin<USDC>(20 * test_constants::usdc_multiplier(), scenario.ctx());

    let user1_shares = pool.supply(
        &registry,
        &supplier_cap_1,
        supply_coin_1,
        option::none(),
        &clock,
    );

    // Verify user1 shares via the new function
    assert!(pool.user_supply_shares(supplier_cap_1_id) == user1_shares);
    assert!(pool.user_supply_shares(supplier_cap_1_id) == 20 * test_constants::usdc_multiplier());

    // Pool should have 20 total supply shares
    assert!(pool.supply_shares() == 20 * test_constants::usdc_multiplier());

    test::return_shared(pool);
    return_shared(registry);
    destroy(supplier_cap_1);

    // User2 supplies 10 USDC
    scenario.next_tx(test_constants::user2());
    let mut pool = scenario.take_shared_by_id<MarginPool<USDC>>(pool_id);
    let registry = scenario.take_shared<MarginRegistry>();
    let supplier_cap_2 = margin_pool::mint_supplier_cap(&registry, &clock, scenario.ctx());
    let supplier_cap_2_id = object::id(&supplier_cap_2);
    let supply_coin_2 = mint_coin<USDC>(10 * test_constants::usdc_multiplier(), scenario.ctx());

    let user2_shares = pool.supply(
        &registry,
        &supplier_cap_2,
        supply_coin_2,
        option::none(),
        &clock,
    );

    // Verify user2 has exactly 10 shares (not 30)
    assert!(pool.user_supply_shares(supplier_cap_2_id) == user2_shares);
    assert!(pool.user_supply_shares(supplier_cap_2_id) == 10 * test_constants::usdc_multiplier());

    // Pool should now have 30 total supply shares (20 + 10)
    assert!(pool.supply_shares() == 30 * test_constants::usdc_multiplier());

    test::return_shared(pool);
    destroy(supplier_cap_2);

    cleanup_test(registry, admin_cap, maintainer_cap, clock, scenario);
}

#[test]
fun test_user_supply_amount_reflects_shares_value() {
    let (mut scenario, clock, admin_cap, maintainer_cap, pool_id) = setup_test();

    // User supplies 100 USDC
    scenario.next_tx(test_constants::user1());
    let mut pool = scenario.take_shared_by_id<MarginPool<USDC>>(pool_id);
    let registry = scenario.take_shared<MarginRegistry>();
    let supplier_cap = margin_pool::mint_supplier_cap(&registry, &clock, scenario.ctx());
    let supplier_cap_id = object::id(&supplier_cap);
    let supply_amount = 100 * test_constants::usdc_multiplier();
    let supply_coin = mint_coin<USDC>(supply_amount, scenario.ctx());

    let shares = pool.supply(&registry, &supplier_cap, supply_coin, option::none(), &clock);

    // At ratio 1, shares should equal amount
    assert!(shares == supply_amount);

    // Verify user_supply_shares returns correct shares
    assert!(pool.user_supply_shares(supplier_cap_id) == shares);

    // Verify user_supply_amount returns correct amount
    let amount = pool.user_supply_amount(supplier_cap_id, &clock);
    assert!(amount == supply_amount);

    // Shares and amount should be equal at ratio 1
    assert!(pool.user_supply_shares(supplier_cap_id) == amount);

    test::return_shared(pool);
    destroy(supplier_cap);
    cleanup_test(registry, admin_cap, maintainer_cap, clock, scenario);
}

#[test]
fun test_user_supply_amount_with_interest_accrual() {
    let (mut scenario, mut clock, admin_cap, maintainer_cap, pool_id) = setup_test();

    // User supplies 1000 USDC
    scenario.next_tx(test_constants::user1());
    let mut pool = scenario.take_shared_by_id<MarginPool<USDC>>(pool_id);
    let registry = scenario.take_shared<MarginRegistry>();
    let supplier_cap = margin_pool::mint_supplier_cap(&registry, &clock, scenario.ctx());
    let supplier_cap_id = object::id(&supplier_cap);
    let supply_amount = 1000 * test_constants::usdc_multiplier();
    let supply_coin = mint_coin<USDC>(supply_amount, scenario.ctx());

    pool.supply(&registry, &supplier_cap, supply_coin, option::none(), &clock);

    let initial_shares = pool.user_supply_shares(supplier_cap_id);
    let initial_amount = pool.user_supply_amount(supplier_cap_id, &clock);

    assert!(initial_shares == supply_amount);
    assert!(initial_amount == supply_amount);

    test::return_shared(pool);
    return_shared(registry);

    // Someone borrows to generate interest
    scenario.next_tx(test_constants::user2());
    let mut pool = scenario.take_shared_by_id<MarginPool<USDC>>(pool_id);
    let registry = scenario.take_shared<MarginRegistry>();
    let (borrowed_coin, _) = pool.borrow(
        500 * test_constants::usdc_multiplier(),
        &clock,
        scenario.ctx(),
    );

    test::return_shared(pool);
    return_shared(registry);
    destroy(borrowed_coin);

    // Advance time to accrue interest
    clock.increment_for_testing(30 * 24 * 60 * 60 * 1000); // 30 days

    // Check that amount increased but shares stayed the same
    scenario.next_tx(test_constants::user1());
    let pool = scenario.take_shared_by_id<MarginPool<USDC>>(pool_id);
    let registry = scenario.take_shared<MarginRegistry>();

    let final_shares = pool.user_supply_shares(supplier_cap_id);
    let final_amount = pool.user_supply_amount(supplier_cap_id, &clock);

    // Shares should remain unchanged
    assert!(final_shares == initial_shares);

    // Amount should have increased due to interest
    assert!(final_amount > initial_amount);

    test::return_shared(pool);
    destroy(supplier_cap);
    cleanup_test(registry, admin_cap, maintainer_cap, clock, scenario);
}

#[test]
fun test_multiple_users_supply_amounts_independent() {
    let (mut scenario, clock, admin_cap, maintainer_cap, pool_id) = setup_test();

    // User1 supplies 50 USDC
    scenario.next_tx(test_constants::user1());
    let mut pool = scenario.take_shared_by_id<MarginPool<USDC>>(pool_id);
    let registry = scenario.take_shared<MarginRegistry>();
    let supplier_cap_1 = margin_pool::mint_supplier_cap(&registry, &clock, scenario.ctx());
    let supplier_cap_1_id = object::id(&supplier_cap_1);
    let user1_supply_amount = 50 * test_constants::usdc_multiplier();
    let supply_coin_1 = mint_coin<USDC>(user1_supply_amount, scenario.ctx());

    pool.supply(&registry, &supplier_cap_1, supply_coin_1, option::none(), &clock);

    let user1_shares = pool.user_supply_shares(supplier_cap_1_id);
    let user1_amount = pool.user_supply_amount(supplier_cap_1_id, &clock);

    assert!(user1_shares == user1_supply_amount);
    assert!(user1_amount == user1_supply_amount);

    test::return_shared(pool);
    return_shared(registry);
    destroy(supplier_cap_1);

    // User2 supplies 30 USDC
    scenario.next_tx(test_constants::user2());
    let mut pool = scenario.take_shared_by_id<MarginPool<USDC>>(pool_id);
    let registry = scenario.take_shared<MarginRegistry>();
    let supplier_cap_2 = margin_pool::mint_supplier_cap(&registry, &clock, scenario.ctx());
    let supplier_cap_2_id = object::id(&supplier_cap_2);
    let user2_supply_amount = 30 * test_constants::usdc_multiplier();
    let supply_coin_2 = mint_coin<USDC>(user2_supply_amount, scenario.ctx());

    pool.supply(&registry, &supplier_cap_2, supply_coin_2, option::none(), &clock);

    let user2_shares = pool.user_supply_shares(supplier_cap_2_id);
    let user2_amount = pool.user_supply_amount(supplier_cap_2_id, &clock);

    // User2's shares should be 30, not 80 (pool total)
    assert!(user2_shares == user2_supply_amount);
    assert!(user2_amount == user2_supply_amount);

    // Pool total should be 50 + 30 = 80
    assert!(pool.total_supply() == user1_supply_amount + user2_supply_amount);
    assert!(pool.supply_shares() == user1_shares + user2_shares);

    test::return_shared(pool);
    destroy(supplier_cap_2);

    cleanup_test(registry, admin_cap, maintainer_cap, clock, scenario);
}

#[test, expected_failure(abort_code = margin_pool::EInvalidMarginPoolCap)]
fun test_withdraw_maintainer_fees_with_wrong_cap() {
    let (mut scenario, clock, admin_cap, maintainer_cap, pool_id) = setup_test();

    // Create a second pool and get its cap (the wrong cap)
    let wrong_cap = setup_usdt_pool_with_cap(&mut scenario, &maintainer_cap, &clock);

    scenario.next_tx(test_constants::admin());
    let mut pool = scenario.take_shared_by_id<MarginPool<USDC>>(pool_id);
    let registry = scenario.take_shared<MarginRegistry>();

    // Supply some funds to generate fees
    scenario.next_tx(test_constants::user1());
    let supplier_cap = test_helpers::supply_to_pool(
        &mut pool,
        &registry,
        100 * test_constants::usdc_multiplier(),
        &clock,
        scenario.ctx(),
    );

    // Try to withdraw maintainer fees with the wrong cap (should fail)
    scenario.next_tx(test_constants::admin());
    let coin = pool.withdraw_maintainer_fees(&registry, &wrong_cap, &clock, scenario.ctx());

    destroy(supplier_cap);
    destroy(coin);
    scenario.return_to_sender(wrong_cap);
    test::return_shared(pool);
    cleanup_test(registry, admin_cap, maintainer_cap, clock, scenario);
}

#[test, expected_failure(abort_code = protocol_fees::ENotOwner)]
fun test_withdraw_referral_fees_not_owner() {
    use deepbook_margin::protocol_fees::SupplyReferral;

    let (mut scenario, mut clock, admin_cap, maintainer_cap, pool_id) = setup_test();

    scenario.next_tx(test_constants::admin());
    let mut pool = scenario.take_shared_by_id<MarginPool<USDC>>(pool_id);
    let registry = scenario.take_shared<MarginRegistry>();

    // User1 creates a supply referral
    scenario.next_tx(test_constants::user1());
    let referral_id = pool.mint_supply_referral(&registry, &clock, scenario.ctx());

    // Supply some funds with the referral to generate fees
    scenario.next_tx(test_constants::user2());
    let supplier_cap = margin_pool::mint_supplier_cap(&registry, &clock, scenario.ctx());
    let supply_coin = mint_coin<USDC>(100 * test_constants::usdc_multiplier(), scenario.ctx());
    pool.supply(&registry, &supplier_cap, supply_coin, option::some(referral_id), &clock);

    // Advance time and add some borrow to generate interest/fees
    advance_time(&mut clock, 30 * 24 * 60 * 60 * 1000); // 30 days

    // User2 (not the owner) tries to withdraw referral fees (should fail)
    scenario.next_tx(test_constants::user2());
    let referral = scenario.take_shared_by_id<SupplyReferral>(referral_id);
    let coin = pool.withdraw_referral_fees(&registry, &referral, scenario.ctx());

    return_shared(referral);
    destroy(supplier_cap);
    destroy(coin);
    test::return_shared(pool);
    cleanup_test(registry, admin_cap, maintainer_cap, clock, scenario);
}

#[test]
fun test_admin_withdraw_default_referral_fees() {
    let (mut scenario, clock, admin_cap, maintainer_cap, pool_id) = setup_test();

    scenario.next_tx(test_constants::admin());
    let mut pool = scenario.take_shared_by_id<MarginPool<USDC>>(pool_id);
    let registry = scenario.take_shared<MarginRegistry>();

    // User1 supplies WITHOUT a referral (goes to default 0x0)
    scenario.next_tx(test_constants::user1());
    let supplier_cap1 = margin_pool::mint_supplier_cap(&registry, &clock, scenario.ctx());
    let supply_coin1 = mint_coin<USDC>(1000 * test_constants::usdc_multiplier(), scenario.ctx());
    pool.supply(&registry, &supplier_cap1, supply_coin1, option::none(), &clock);

    // User2 also supplies WITHOUT a referral
    scenario.next_tx(test_constants::user2());
    let supplier_cap2 = margin_pool::mint_supplier_cap(&registry, &clock, scenario.ctx());
    let supply_coin2 = mint_coin<USDC>(500 * test_constants::usdc_multiplier(), scenario.ctx());
    pool.supply(&registry, &supplier_cap2, supply_coin2, option::none(), &clock);

    // Check that default referral has shares
    let default_id = margin_constants::default_referral();
    let (current_shares, _unclaimed_fees) = protocol_fees::referral_tracker(
        pool.protocol_fees(),
        default_id,
    );
    assert!(current_shares > 0); // Users supplied without referral, so default has shares

    // Admin can call the function to claim default referral fees (even if 0)
    scenario.next_tx(test_constants::admin());
    let default_referral_coin = pool.admin_withdraw_default_referral_fees(
        &registry,
        &admin_cap,
        scenario.ctx(),
    );

    // Fees will be 0 initially since no borrows/interest yet,
    // but the important thing is admin CAN claim them (not stuck)
    let fees_claimed = default_referral_coin.value();
    assert_eq!(fees_claimed, 0); // No fees accrued yet

    // Verify default referral's unclaimed_fees reset after claim
    let (current_shares_after, unclaimed_fees) = protocol_fees::referral_tracker(
        pool.protocol_fees(),
        default_id,
    );
    assert_eq!(unclaimed_fees, 0);
    assert_eq!(current_shares_after, current_shares);

    // Cleanup
    destroy(supplier_cap1);
    destroy(supplier_cap2);
    destroy(default_referral_coin);
    test::return_shared(pool);
    cleanup_test(registry, admin_cap, maintainer_cap, clock, scenario);
}

#[test]
fun test_withdraw_round_up_shares() {
    let (mut scenario, mut clock, admin_cap, maintainer_cap, pool_id) = setup_test();

    scenario.next_tx(test_constants::admin());
    let mut pool = scenario.take_shared_by_id<MarginPool<USDC>>(pool_id);
    let registry = scenario.take_shared<MarginRegistry>();

    scenario.next_tx(test_constants::user1());
    // Supply 10 tokens
    let supplier_cap = test_helpers::supply_to_pool(
        &mut pool,
        &registry,
        10 * test_constants::usdc_multiplier(),
        &clock,
        scenario.ctx(),
    );

    // Borrow to create interest accrual
    scenario.next_tx(test_constants::user2());
    let borrow_coin = test_borrow(
        &mut pool,
        5 * test_constants::usdc_multiplier(),
        &clock,
        scenario.ctx(),
    );

    // Advance time to accrue interest
    advance_time(&mut clock, 365 * 24 * 60 * 60 * 1000); // 1 year

    // Now shares are worth more than initial amount (ratio > 1)
    scenario.next_tx(test_constants::user1());
    let supplier_cap_id = object::id(&supplier_cap);
    let shares_before = pool.user_supply_shares(supplier_cap_id);
    let amount_before = pool.user_supply_amount(supplier_cap_id, &clock);

    // Verify interest accrued: amount > initial supply
    assert!(amount_before > 10 * test_constants::usdc_multiplier());

    // Try to withdraw 1 token (very small compared to total)
    let withdrawn = pool.withdraw<USDC>(
        &registry,
        &supplier_cap,
        option::some(1),
        &clock,
        scenario.ctx(),
    );

    // Verify we got exactly 1 token
    assert_eq!(withdrawn.value(), 1);

    // Verify exactly 1 share was burned (rounded up from fractional share)
    let shares_after = pool.user_supply_shares(supplier_cap_id);
    assert_eq!(shares_after, shares_before - 1);

    // Cleanup
    destroy(borrow_coin);
    destroy(withdrawn);
    destroy(supplier_cap);
    test::return_shared(pool);
    cleanup_test(registry, admin_cap, maintainer_cap, clock, scenario);
}

#[test]
fun test_total_supply_with_interest_no_borrow() {
    let (mut scenario, clock, admin_cap, maintainer_cap, pool_id) = setup_test();
    let mut pool = scenario.take_shared_by_id<MarginPool<USDC>>(pool_id);
    let registry = scenario.take_shared<MarginRegistry>();

    scenario.next_tx(test_constants::user1());
    let supply_amount = 100 * test_constants::usdc_multiplier();
    let supplier_cap = test_helpers::supply_to_pool(
        &mut pool,
        &registry,
        supply_amount,
        &clock,
        scenario.ctx(),
    );

    // With no borrows, total_supply should equal total_supply_with_interest
    let raw_supply = pool.total_supply();
    let supply_with_interest = pool.total_supply_with_interest(&clock);
    assert_eq!(raw_supply, supply_amount);
    assert_eq!(supply_with_interest, supply_amount);

    destroy(supplier_cap);
    test::return_shared(pool);
    cleanup_test(registry, admin_cap, maintainer_cap, clock, scenario);
}

#[test]
fun test_total_supply_with_interest_after_year() {
    let (mut scenario, mut clock, admin_cap, maintainer_cap, pool_id) = setup_test();
    let mut pool = scenario.take_shared_by_id<MarginPool<USDC>>(pool_id);
    let registry = scenario.take_shared<MarginRegistry>();

    // Supply 100 USDC
    scenario.next_tx(test_constants::user1());
    let supply_amount = 100 * test_constants::usdc_multiplier();
    let supplier_cap = test_helpers::supply_to_pool(
        &mut pool,
        &registry,
        supply_amount,
        &clock,
        scenario.ctx(),
    );

    // Borrow 50 USDC (50% utilization)
    scenario.next_tx(test_constants::user2());
    let borrow_amount = 50 * test_constants::usdc_multiplier();
    let borrowed_coin = test_borrow(
        &mut pool,
        borrow_amount,
        &clock,
        scenario.ctx(),
    );

    // Record initial values
    let initial_supply = pool.total_supply();
    assert_eq!(initial_supply, supply_amount);

    // Advance time by 1 year
    advance_time(&mut clock, margin_constants::year_ms());

    // total_supply should still be the raw supply (not updated yet)
    let raw_supply = pool.total_supply();
    assert_eq!(raw_supply, initial_supply);

    // total_supply_with_interest should include accrued interest
    let supply_with_interest = pool.total_supply_with_interest(&clock);
    let true_interest_rate = pool.true_interest_rate();

    // Verify that supply_with_interest > raw_supply (interest has accrued)
    assert_eq!(
        supply_with_interest,
        math::mul(raw_supply, constants::float_scaling() + true_interest_rate),
    );

    destroy(borrowed_coin);
    destroy(supplier_cap);
    test::return_shared(pool);
    cleanup_test(registry, admin_cap, maintainer_cap, clock, scenario);
}

#[test]
fun test_total_supply_with_interest_high_utilization() {
    let (mut scenario, mut clock, admin_cap, maintainer_cap, pool_id) = setup_test();
    let mut pool = scenario.take_shared_by_id<MarginPool<USDC>>(pool_id);
    let registry = scenario.take_shared<MarginRegistry>();

    // Supply 100 USDC
    scenario.next_tx(test_constants::user1());
    let supply_amount = 100 * test_constants::usdc_multiplier();
    let supplier_cap = test_helpers::supply_to_pool(
        &mut pool,
        &registry,
        supply_amount,
        &clock,
        scenario.ctx(),
    );

    // Borrow 79 USDC (79% utilization, close to optimal 80%)
    scenario.next_tx(test_constants::user2());
    let borrow_amount = 79 * test_constants::usdc_multiplier();
    let borrowed_coin = test_borrow(
        &mut pool,
        borrow_amount,
        &clock,
        scenario.ctx(),
    );

    // Record initial values
    let initial_supply = pool.total_supply();

    // Advance time by 1 year
    advance_time(&mut clock, margin_constants::year_ms());

    // Raw supply should not have changed
    let raw_supply_after_year = pool.total_supply();
    assert_eq!(raw_supply_after_year, initial_supply);

    // total_supply_with_interest should include accrued interest
    let supply_with_interest = pool.total_supply_with_interest(&clock);
    let true_interest_rate = pool.true_interest_rate();

    // Verify exact calculation with true interest rate
    assert_eq!(
        supply_with_interest,
        math::mul(raw_supply_after_year, constants::float_scaling() + true_interest_rate),
    );

    destroy(borrowed_coin);
    destroy(supplier_cap);
    test::return_shared(pool);
    cleanup_test(registry, admin_cap, maintainer_cap, clock, scenario);
}

#[test]
fun test_total_supply_with_interest_vs_update() {
    let (mut scenario, mut clock, admin_cap, maintainer_cap, pool_id) = setup_test();
    let mut pool = scenario.take_shared_by_id<MarginPool<USDC>>(pool_id);
    let registry = scenario.take_shared<MarginRegistry>();

    // Supply 100 USDC
    scenario.next_tx(test_constants::user1());
    let supply_amount = 100 * test_constants::usdc_multiplier();
    let supplier_cap = test_helpers::supply_to_pool(
        &mut pool,
        &registry,
        supply_amount,
        &clock,
        scenario.ctx(),
    );

    // Borrow 60 USDC (60% utilization)
    scenario.next_tx(test_constants::user2());
    let borrow_amount = 60 * test_constants::usdc_multiplier();
    let borrowed_coin = test_borrow(
        &mut pool,
        borrow_amount,
        &clock,
        scenario.ctx(),
    );

    // Advance time by 1 year
    advance_time(&mut clock, margin_constants::year_ms());

    // Get supply with interest (without updating state)
    let raw_supply_before = pool.total_supply();
    let supply_with_interest_before_update = pool.total_supply_with_interest(&clock);
    let true_interest_rate = pool.true_interest_rate();

    // Verify exact calculation with true interest rate
    assert_eq!(
        supply_with_interest_before_update,
        math::mul(raw_supply_before, constants::float_scaling() + true_interest_rate),
    );

    // Now actually update the state by withdrawing
    scenario.next_tx(test_constants::user1());
    let withdrawn = pool.withdraw<USDC>(
        &registry,
        &supplier_cap,
        option::some(1), // Withdraw minimal amount to trigger state update
        &clock,
        scenario.ctx(),
    );

    // After update, raw supply should now include the interest (minus withdrawn amount)
    let raw_supply_after = pool.total_supply();
    let withdrawn_amount = withdrawn.value();
    let expected_supply_after = supply_with_interest_before_update - withdrawn_amount;

    // Verify the supply after update matches our prediction
    assert_eq!(raw_supply_after, expected_supply_after);

    destroy(withdrawn);
    destroy(borrowed_coin);
    destroy(supplier_cap);
    test::return_shared(pool);
    cleanup_test(registry, admin_cap, maintainer_cap, clock, scenario);
}

/// Test that withdrawing a tiny amount still burns at least 1 share.
#[test]
fun test_tiny_withdraw_burns_at_least_one_share() {
    let (mut scenario, clock, admin_cap, maintainer_cap, pool_id) = setup_test();

    scenario.next_tx(test_constants::admin());
    let mut pool = scenario.take_shared_by_id<MarginPool<USDC>>(pool_id);
    let registry = scenario.take_shared<MarginRegistry>();

    // User supplies a large amount: 1,000,000 USDC = 10^12 units
    scenario.next_tx(test_constants::user1());
    let large_supply = 1_000_000 * test_constants::usdc_multiplier(); // 10^12 units
    let supplier_cap = test_helpers::supply_to_pool(
        &mut pool,
        &registry,
        large_supply,
        &clock,
        scenario.ctx(),
    );

    let supplier_cap_id = object::id(&supplier_cap);
    let shares_before = pool.user_supply_shares(supplier_cap_id);

    // Verify initial shares equal supply (1:1 ratio at start)
    assert_eq!(shares_before, large_supply);

    // Withdraw just 1 unit - this would have burned 0 shares before the fix
    // because: div(1, 10^12) = (1 * 10^9) / 10^12 = 0 (floor division)
    let withdrawn = pool.withdraw<USDC>(
        &registry,
        &supplier_cap,
        option::some(1),
        &clock,
        scenario.ctx(),
    );

    // Verify we received exactly 1 unit
    assert_eq!(withdrawn.value(), 1);

    let shares_after = pool.user_supply_shares(supplier_cap_id);
    let shares_burned = shares_before - shares_after;

    assert!(shares_burned >= 1);

    destroy(withdrawn);
    destroy(supplier_cap);
    test::return_shared(pool);
    cleanup_test(registry, admin_cap, maintainer_cap, clock, scenario);
}

#[test]
/// Test that update_margin_pool_config accrues interest using old params before applying new config.
fun test_update_margin_pool_config_accrues_interest_with_old_params() {
    let (mut scenario, mut clock, admin_cap, maintainer_cap, pool_id) = setup_test();
    let mut pool = scenario.take_shared_by_id<MarginPool<USDC>>(pool_id);
    let registry = scenario.take_shared<MarginRegistry>();
    let margin_pool_cap = scenario.take_from_sender<MarginPoolCap>();

    // Verify initial protocol_spread is 10%
    let old_protocol_spread = pool.protocol_spread();
    assert_eq!(old_protocol_spread, test_constants::protocol_spread());

    // Supply 100 USDC
    scenario.next_tx(test_constants::user1());
    let supply_amount = 100 * test_constants::usdc_multiplier();
    let supplier_cap = test_helpers::supply_to_pool(
        &mut pool,
        &registry,
        supply_amount,
        &clock,
        scenario.ctx(),
    );

    // Borrow 60 USDC (60% utilization)
    scenario.next_tx(test_constants::user2());
    let borrow_amount = 60 * test_constants::usdc_multiplier();
    let borrowed_coin = test_borrow(&mut pool, borrow_amount, &clock, scenario.ctx());

    // Advance time by 1 year to accrue interest
    advance_time(&mut clock, margin_constants::year_ms());

    // Get expected supply with interest before config update (using old protocol_spread)
    let supply_with_interest_before = pool.total_supply_with_interest(&clock);
    let raw_supply_before = pool.total_supply();
    let protocol_fees_before = pool.protocol_fees().protocol_fees();

    // Supply with interest should be greater than raw supply (interest has accrued)
    assert!(supply_with_interest_before > raw_supply_before);

    // Now update margin_pool_config with new protocol_spread (5% instead of 10%)
    scenario.next_tx(test_constants::admin());
    let new_protocol_spread = 50_000_000; // 5%
    let new_margin_pool_config = protocol_config::new_margin_pool_config(
        test_constants::supply_cap(),
        test_constants::max_utilization_rate(),
        new_protocol_spread,
        test_constants::min_borrow(),
    );

    pool.update_margin_pool_config(&registry, new_margin_pool_config, &margin_pool_cap, &clock);

    // After config update, interest should have been accrued using old protocol_spread
    let raw_supply_after = pool.total_supply();
    let protocol_fees_after = pool.protocol_fees().protocol_fees();

    // Verify state was updated: raw supply should now include accrued interest
    assert_eq!(raw_supply_after, supply_with_interest_before);

    // Verify protocol fees increased (interest was calculated with old protocol_spread)
    assert!(protocol_fees_after > protocol_fees_before);

    // Verify new protocol_spread is in effect
    assert_eq!(pool.protocol_spread(), new_protocol_spread);

    scenario.return_to_sender(margin_pool_cap);
    destroy(borrowed_coin);
    destroy(supplier_cap);
    test::return_shared(pool);
    cleanup_test(registry, admin_cap, maintainer_cap, clock, scenario);
}
