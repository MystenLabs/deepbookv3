// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module deepbook_margin::margin_manager_borrow_share_tests;

use deepbook::{pool::Pool, registry::Registry};
use deepbook_margin::{
    margin_manager::{Self, MarginManager},
    margin_pool::MarginPool,
    margin_registry::MarginRegistry,
    test_constants::{Self, USDC, BTC, btc_multiplier},
    test_helpers::{
        setup_btc_usd_deepbook_margin,
        cleanup_margin_test,
        mint_coin,
        build_demo_usdc_price_info_object,
        build_btc_price_info_object,
        destroy_2,
        return_shared_2,
        return_shared_3,
        supply_to_pool
    }
};
use std::unit_test::destroy;
use sui::test_scenario::return_shared;

#[test]
fun test_multiple_borrows_accumulate_shares_base() {
    let (
        mut scenario,
        clock,
        admin_cap,
        maintainer_cap,
        btc_pool_id,
        usdc_pool_id,
        _pool_id,
        registry_id,
    ) = setup_btc_usd_deepbook_margin();

    // Supply liquidity to BTC pool
    scenario.next_tx(test_constants::admin());
    let mut btc_pool = scenario.take_shared_by_id<MarginPool<BTC>>(btc_pool_id);
    let registry = scenario.take_shared<MarginRegistry>();
    let supplier_cap = supply_to_pool(
        &mut btc_pool,
        &registry,
        100 * btc_multiplier(),
        &clock,
        scenario.ctx(),
    );
    return_shared_2!(btc_pool, registry);
    destroy(supplier_cap);

    // Create margin manager and deposit collateral
    scenario.next_tx(test_constants::user1());
    let pool = scenario.take_shared<Pool<BTC, USDC>>();
    let mut registry = scenario.take_shared<MarginRegistry>();
    let deepbook_registry = scenario.take_shared_by_id<Registry>(registry_id);
    margin_manager::new<BTC, USDC>(
        &pool,
        &deepbook_registry,
        &mut registry,
        &clock,
        scenario.ctx(),
    );
    return_shared(deepbook_registry);
    return_shared_2!(pool, registry);

    scenario.next_tx(test_constants::user1());
    let mut mm = scenario.take_shared<MarginManager<BTC, USDC>>();
    let registry = scenario.take_shared<MarginRegistry>();
    let btc_price = build_btc_price_info_object(&mut scenario, 50000, &clock);
    let usdc_price = build_demo_usdc_price_info_object(&mut scenario, &clock);
    // Deposit significant USDC as collateral
    let deposit_coin = mint_coin<USDC>(
        5_000_000 * test_constants::usdc_multiplier(),
        scenario.ctx(),
    );
    mm.deposit<BTC, USDC, USDC>(
        &registry,
        &btc_price,
        &usdc_price,
        deposit_coin,
        &clock,
        scenario.ctx(),
    );
    destroy_2!(btc_price, usdc_price);
    return_shared_2!(mm, registry);

    // First borrow: 10 BTC when ratio is 1
    scenario.next_tx(test_constants::user1());
    let mut mm = scenario.take_shared<MarginManager<BTC, USDC>>();
    let registry = scenario.take_shared<MarginRegistry>();
    let mut btc_pool = scenario.take_shared_by_id<MarginPool<BTC>>(btc_pool_id);
    let usdc_pool = scenario.take_shared_by_id<MarginPool<USDC>>(usdc_pool_id);
    let pool = scenario.take_shared<Pool<BTC, USDC>>();
    let btc_price = build_btc_price_info_object(&mut scenario, 50000, &clock);
    let usdc_price = build_demo_usdc_price_info_object(&mut scenario, &clock);

    mm.borrow_base<BTC, USDC>(
        &registry,
        &mut btc_pool,
        &btc_price,
        &usdc_price,
        &pool,
        10 * btc_multiplier(),
        &clock,
        scenario.ctx(),
    );

    let borrowed_base_shares_after_first = mm.borrowed_base_shares();
    // At ratio 1, borrowing 10 should give us 10 shares
    assert!(borrowed_base_shares_after_first == 10 * btc_multiplier());

    // Second borrow: 15 BTC more
    mm.borrow_base<BTC, USDC>(
        &registry,
        &mut btc_pool,
        &btc_price,
        &usdc_price,
        &pool,
        15 * btc_multiplier(),
        &clock,
        scenario.ctx(),
    );

    let borrowed_base_shares_after_second = mm.borrowed_base_shares();
    // Total shares should be 10 + 15 = 25
    assert!(borrowed_base_shares_after_second == 25 * btc_multiplier());
    assert!(mm.borrowed_quote_shares() == 0);

    return_shared_3!(btc_pool, usdc_pool, pool);
    return_shared(mm);
    destroy_2!(btc_price, usdc_price);
    cleanup_margin_test(registry, admin_cap, maintainer_cap, clock, scenario);
}

#[test]
fun test_multiple_borrows_accumulate_shares_quote() {
    let (
        mut scenario,
        clock,
        admin_cap,
        maintainer_cap,
        btc_pool_id,
        usdc_pool_id,
        _pool_id,
        registry_id,
    ) = setup_btc_usd_deepbook_margin();

    // Supply liquidity to USDC pool
    scenario.next_tx(test_constants::admin());
    let mut usdc_pool = scenario.take_shared_by_id<MarginPool<USDC>>(usdc_pool_id);
    let registry = scenario.take_shared<MarginRegistry>();
    let supplier_cap = supply_to_pool(
        &mut usdc_pool,
        &registry,
        1_000_000 * test_constants::usdc_multiplier(),
        &clock,
        scenario.ctx(),
    );
    return_shared_2!(usdc_pool, registry);
    destroy(supplier_cap);

    // Create margin manager and deposit collateral
    scenario.next_tx(test_constants::user1());
    let pool = scenario.take_shared<Pool<BTC, USDC>>();
    let mut registry = scenario.take_shared<MarginRegistry>();
    let deepbook_registry = scenario.take_shared_by_id<Registry>(registry_id);
    margin_manager::new<BTC, USDC>(
        &pool,
        &deepbook_registry,
        &mut registry,
        &clock,
        scenario.ctx(),
    );
    return_shared(deepbook_registry);
    return_shared_2!(pool, registry);

    scenario.next_tx(test_constants::user1());
    let mut mm = scenario.take_shared<MarginManager<BTC, USDC>>();
    let registry = scenario.take_shared<MarginRegistry>();
    let btc_price = build_btc_price_info_object(&mut scenario, 50000, &clock);
    let usdc_price = build_demo_usdc_price_info_object(&mut scenario, &clock);
    // Deposit significant BTC as collateral
    let deposit_coin = mint_coin<BTC>(10 * btc_multiplier(), scenario.ctx());
    mm.deposit<BTC, USDC, BTC>(
        &registry,
        &btc_price,
        &usdc_price,
        deposit_coin,
        &clock,
        scenario.ctx(),
    );
    destroy_2!(btc_price, usdc_price);
    return_shared_2!(mm, registry);

    // First borrow: 10 USDC when ratio is 1
    scenario.next_tx(test_constants::user1());
    let mut mm = scenario.take_shared<MarginManager<BTC, USDC>>();
    let registry = scenario.take_shared<MarginRegistry>();
    let btc_pool = scenario.take_shared_by_id<MarginPool<BTC>>(btc_pool_id);
    let mut usdc_pool = scenario.take_shared_by_id<MarginPool<USDC>>(usdc_pool_id);
    let pool = scenario.take_shared<Pool<BTC, USDC>>();
    let btc_price = build_btc_price_info_object(&mut scenario, 50000, &clock);
    let usdc_price = build_demo_usdc_price_info_object(&mut scenario, &clock);

    mm.borrow_quote<BTC, USDC>(
        &registry,
        &mut usdc_pool,
        &btc_price,
        &usdc_price,
        &pool,
        10 * test_constants::usdc_multiplier(),
        &clock,
        scenario.ctx(),
    );

    let borrowed_quote_shares_after_first = mm.borrowed_quote_shares();
    // At ratio 1, borrowing 10 should give us 10 shares
    assert!(borrowed_quote_shares_after_first == 10 * test_constants::usdc_multiplier());

    // Second borrow: 15 USDC more
    mm.borrow_quote<BTC, USDC>(
        &registry,
        &mut usdc_pool,
        &btc_price,
        &usdc_price,
        &pool,
        15 * test_constants::usdc_multiplier(),
        &clock,
        scenario.ctx(),
    );

    let borrowed_quote_shares_after_second = mm.borrowed_quote_shares();
    // Total shares should be 10 + 15 = 25
    assert!(borrowed_quote_shares_after_second == 25 * test_constants::usdc_multiplier());
    assert!(mm.borrowed_base_shares() == 0);

    return_shared_3!(btc_pool, usdc_pool, pool);
    return_shared(mm);
    destroy_2!(btc_price, usdc_price);
    cleanup_margin_test(registry, admin_cap, maintainer_cap, clock, scenario);
}

#[test]
fun test_user_shares_isolated_from_other_users_base() {
    let (
        mut scenario,
        clock,
        admin_cap,
        maintainer_cap,
        btc_pool_id,
        usdc_pool_id,
        _pool_id,
        registry_id,
    ) = setup_btc_usd_deepbook_margin();

    // Supply liquidity to BTC pool
    scenario.next_tx(test_constants::admin());
    let mut btc_pool = scenario.take_shared_by_id<MarginPool<BTC>>(btc_pool_id);
    let registry = scenario.take_shared<MarginRegistry>();
    let supplier_cap = supply_to_pool(
        &mut btc_pool,
        &registry,
        100 * btc_multiplier(),
        &clock,
        scenario.ctx(),
    );
    return_shared_2!(btc_pool, registry);
    destroy(supplier_cap);

    // User1 creates margin manager and borrows first
    scenario.next_tx(test_constants::user1());
    let pool = scenario.take_shared<Pool<BTC, USDC>>();
    let mut registry = scenario.take_shared<MarginRegistry>();
    let deepbook_registry = scenario.take_shared_by_id<Registry>(registry_id);
    margin_manager::new<BTC, USDC>(
        &pool,
        &deepbook_registry,
        &mut registry,
        &clock,
        scenario.ctx(),
    );
    return_shared(deepbook_registry);
    return_shared_2!(pool, registry);

    scenario.next_tx(test_constants::user1());
    let mut mm1 = scenario.take_shared<MarginManager<BTC, USDC>>();
    let registry = scenario.take_shared<MarginRegistry>();
    let btc_price = build_btc_price_info_object(&mut scenario, 50000, &clock);
    let usdc_price = build_demo_usdc_price_info_object(&mut scenario, &clock);
    let deposit_coin = mint_coin<USDC>(
        5_000_000 * test_constants::usdc_multiplier(),
        scenario.ctx(),
    );
    mm1.deposit<BTC, USDC, USDC>(
        &registry,
        &btc_price,
        &usdc_price,
        deposit_coin,
        &clock,
        scenario.ctx(),
    );
    destroy_2!(btc_price, usdc_price);
    return_shared_2!(mm1, registry);

    // User1 borrows 20 BTC
    scenario.next_tx(test_constants::user1());
    let mut mm1 = scenario.take_shared<MarginManager<BTC, USDC>>();
    let registry = scenario.take_shared<MarginRegistry>();
    let mut btc_pool = scenario.take_shared_by_id<MarginPool<BTC>>(btc_pool_id);
    let usdc_pool = scenario.take_shared_by_id<MarginPool<USDC>>(usdc_pool_id);
    let pool = scenario.take_shared<Pool<BTC, USDC>>();
    let btc_price = build_btc_price_info_object(&mut scenario, 50000, &clock);
    let usdc_price = build_demo_usdc_price_info_object(&mut scenario, &clock);

    mm1.borrow_base<BTC, USDC>(
        &registry,
        &mut btc_pool,
        &btc_price,
        &usdc_price,
        &pool,
        20 * btc_multiplier(),
        &clock,
        scenario.ctx(),
    );

    // User1 should have 20 shares
    assert!(mm1.borrowed_base_shares() == 20 * btc_multiplier());

    // The pool now has total borrow shares of 20
    assert!(btc_pool.borrow_shares() == 20 * btc_multiplier());

    return_shared_3!(btc_pool, usdc_pool, pool);
    return_shared_2!(mm1, registry);
    destroy_2!(btc_price, usdc_price);

    // User2 creates their own margin manager
    scenario.next_tx(test_constants::user2());
    let pool = scenario.take_shared<Pool<BTC, USDC>>();
    let mut registry = scenario.take_shared<MarginRegistry>();
    let deepbook_registry = scenario.take_shared_by_id<Registry>(registry_id);
    margin_manager::new<BTC, USDC>(
        &pool,
        &deepbook_registry,
        &mut registry,
        &clock,
        scenario.ctx(),
    );
    return_shared(deepbook_registry);
    return_shared_2!(pool, registry);

    scenario.next_tx(test_constants::user2());
    let mut mm2 = scenario.take_shared<MarginManager<BTC, USDC>>();
    let registry = scenario.take_shared<MarginRegistry>();
    let btc_price = build_btc_price_info_object(&mut scenario, 50000, &clock);
    let usdc_price = build_demo_usdc_price_info_object(&mut scenario, &clock);
    let deposit_coin = mint_coin<USDC>(
        5_000_000 * test_constants::usdc_multiplier(),
        scenario.ctx(),
    );
    mm2.deposit<BTC, USDC, USDC>(
        &registry,
        &btc_price,
        &usdc_price,
        deposit_coin,
        &clock,
        scenario.ctx(),
    );
    destroy_2!(btc_price, usdc_price);
    return_shared_2!(mm2, registry);

    // User2 borrows 10 BTC when ratio is still 1
    scenario.next_tx(test_constants::user2());
    let mut mm2 = scenario.take_shared<MarginManager<BTC, USDC>>();
    let registry = scenario.take_shared<MarginRegistry>();
    let mut btc_pool = scenario.take_shared_by_id<MarginPool<BTC>>(btc_pool_id);
    let usdc_pool = scenario.take_shared_by_id<MarginPool<USDC>>(usdc_pool_id);
    let pool = scenario.take_shared<Pool<BTC, USDC>>();
    let btc_price = build_btc_price_info_object(&mut scenario, 50000, &clock);
    let usdc_price = build_demo_usdc_price_info_object(&mut scenario, &clock);

    mm2.borrow_base<BTC, USDC>(
        &registry,
        &mut btc_pool,
        &btc_price,
        &usdc_price,
        &pool,
        10 * btc_multiplier(),
        &clock,
        scenario.ctx(),
    );

    // User2 should have exactly 10 shares, NOT 30 (which would be the pool total)
    assert!(mm2.borrowed_base_shares() == 10 * btc_multiplier());
    assert!(mm2.borrowed_quote_shares() == 0);

    // The pool should now have total borrow shares of 30 (20 + 10)
    assert!(btc_pool.borrow_shares() == 30 * btc_multiplier());

    return_shared_3!(btc_pool, usdc_pool, pool);
    return_shared(mm2);
    destroy_2!(btc_price, usdc_price);

    // The key verifications are:
    // 1. mm2 has exactly 10 shares (not 30 which would be the bug)
    // 2. The pool has 30 total shares (20 from mm1 + 10 from mm2)

    cleanup_margin_test(registry, admin_cap, maintainer_cap, clock, scenario);
}

#[test]
fun test_user_shares_isolated_from_other_users_quote() {
    let (
        mut scenario,
        clock,
        admin_cap,
        maintainer_cap,
        btc_pool_id,
        usdc_pool_id,
        _pool_id,
        registry_id,
    ) = setup_btc_usd_deepbook_margin();

    // Supply liquidity to USDC pool
    scenario.next_tx(test_constants::admin());
    let mut usdc_pool = scenario.take_shared_by_id<MarginPool<USDC>>(usdc_pool_id);
    let registry = scenario.take_shared<MarginRegistry>();
    let supplier_cap = supply_to_pool(
        &mut usdc_pool,
        &registry,
        1_000_000 * test_constants::usdc_multiplier(),
        &clock,
        scenario.ctx(),
    );
    return_shared_2!(usdc_pool, registry);
    destroy(supplier_cap);

    // User1 creates margin manager and borrows first
    scenario.next_tx(test_constants::user1());
    let pool = scenario.take_shared<Pool<BTC, USDC>>();
    let mut registry = scenario.take_shared<MarginRegistry>();
    let deepbook_registry = scenario.take_shared_by_id<Registry>(registry_id);
    margin_manager::new<BTC, USDC>(
        &pool,
        &deepbook_registry,
        &mut registry,
        &clock,
        scenario.ctx(),
    );
    return_shared(deepbook_registry);
    return_shared_2!(pool, registry);

    scenario.next_tx(test_constants::user1());
    let mut mm1 = scenario.take_shared<MarginManager<BTC, USDC>>();
    let registry = scenario.take_shared<MarginRegistry>();
    let btc_price = build_btc_price_info_object(&mut scenario, 50000, &clock);
    let usdc_price = build_demo_usdc_price_info_object(&mut scenario, &clock);
    let deposit_coin = mint_coin<BTC>(10 * btc_multiplier(), scenario.ctx());
    mm1.deposit<BTC, USDC, BTC>(
        &registry,
        &btc_price,
        &usdc_price,
        deposit_coin,
        &clock,
        scenario.ctx(),
    );
    destroy_2!(btc_price, usdc_price);
    return_shared_2!(mm1, registry);

    // User1 borrows 20 USDC
    scenario.next_tx(test_constants::user1());
    let mut mm1 = scenario.take_shared<MarginManager<BTC, USDC>>();
    let registry = scenario.take_shared<MarginRegistry>();
    let btc_pool = scenario.take_shared_by_id<MarginPool<BTC>>(btc_pool_id);
    let mut usdc_pool = scenario.take_shared_by_id<MarginPool<USDC>>(usdc_pool_id);
    let pool = scenario.take_shared<Pool<BTC, USDC>>();
    let btc_price = build_btc_price_info_object(&mut scenario, 50000, &clock);
    let usdc_price = build_demo_usdc_price_info_object(&mut scenario, &clock);

    mm1.borrow_quote<BTC, USDC>(
        &registry,
        &mut usdc_pool,
        &btc_price,
        &usdc_price,
        &pool,
        20 * test_constants::usdc_multiplier(),
        &clock,
        scenario.ctx(),
    );

    // User1 should have 20 shares
    assert!(mm1.borrowed_quote_shares() == 20 * test_constants::usdc_multiplier());

    // The pool now has total borrow shares of 20
    assert!(usdc_pool.borrow_shares() == 20 * test_constants::usdc_multiplier());

    return_shared_3!(btc_pool, usdc_pool, pool);
    return_shared_2!(mm1, registry);
    destroy_2!(btc_price, usdc_price);

    // User2 creates their own margin manager
    scenario.next_tx(test_constants::user2());
    let pool = scenario.take_shared<Pool<BTC, USDC>>();
    let mut registry = scenario.take_shared<MarginRegistry>();
    let deepbook_registry = scenario.take_shared_by_id<Registry>(registry_id);
    margin_manager::new<BTC, USDC>(
        &pool,
        &deepbook_registry,
        &mut registry,
        &clock,
        scenario.ctx(),
    );
    return_shared(deepbook_registry);
    return_shared_2!(pool, registry);

    scenario.next_tx(test_constants::user2());
    let mut mm2 = scenario.take_shared<MarginManager<BTC, USDC>>();
    let registry = scenario.take_shared<MarginRegistry>();
    let btc_price = build_btc_price_info_object(&mut scenario, 50000, &clock);
    let usdc_price = build_demo_usdc_price_info_object(&mut scenario, &clock);
    let deposit_coin = mint_coin<BTC>(10 * btc_multiplier(), scenario.ctx());
    mm2.deposit<BTC, USDC, BTC>(
        &registry,
        &btc_price,
        &usdc_price,
        deposit_coin,
        &clock,
        scenario.ctx(),
    );
    destroy_2!(btc_price, usdc_price);
    return_shared_2!(mm2, registry);

    // User2 borrows 10 USDC when ratio is still 1
    scenario.next_tx(test_constants::user2());
    let mut mm2 = scenario.take_shared<MarginManager<BTC, USDC>>();
    let registry = scenario.take_shared<MarginRegistry>();
    let btc_pool = scenario.take_shared_by_id<MarginPool<BTC>>(btc_pool_id);
    let mut usdc_pool = scenario.take_shared_by_id<MarginPool<USDC>>(usdc_pool_id);
    let pool = scenario.take_shared<Pool<BTC, USDC>>();
    let btc_price = build_btc_price_info_object(&mut scenario, 50000, &clock);
    let usdc_price = build_demo_usdc_price_info_object(&mut scenario, &clock);

    mm2.borrow_quote<BTC, USDC>(
        &registry,
        &mut usdc_pool,
        &btc_price,
        &usdc_price,
        &pool,
        10 * test_constants::usdc_multiplier(),
        &clock,
        scenario.ctx(),
    );

    // User2 should have exactly 10 shares, NOT 30 (which would be the pool total)
    assert!(mm2.borrowed_quote_shares() == 10 * test_constants::usdc_multiplier());
    assert!(mm2.borrowed_base_shares() == 0);

    // The pool should now have total borrow shares of 30 (20 + 10)
    assert!(usdc_pool.borrow_shares() == 30 * test_constants::usdc_multiplier());

    return_shared_3!(btc_pool, usdc_pool, pool);
    return_shared(mm2);
    destroy_2!(btc_price, usdc_price);

    // The key verifications are:
    // 1. mm2 has exactly 10 shares (not 30 which would be the bug)
    // 2. The pool has 30 total shares (20 from mm1 + 10 from mm2)

    cleanup_margin_test(registry, admin_cap, maintainer_cap, clock, scenario);
}
