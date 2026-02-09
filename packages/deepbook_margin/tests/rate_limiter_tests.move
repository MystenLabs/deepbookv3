#[test_only]
module deepbook_margin::rate_limiter_tests;

use deepbook_margin::{
    margin_pool::{Self, MarginPool},
    margin_registry::MarginRegistry,
    rate_limiter,
    test_constants::{USDC, admin, user1},
    test_helpers::{Self, return_shared_2, destroy_3, destroy_4}
};
use std::unit_test::destroy;
use sui::{clock, coin, test_scenario};

const HOUR_MS: u64 = 3_600_000;
const CAPACITY: u64 = 100_000_000_000;
const RATE: u64 = 100_000_000;

// === Unit Tests ===

#[test]
fun constructor_works() {
    let ctx = &mut tx_context::dummy();
    let clock = clock::create_for_testing(ctx);
    let limiter = rate_limiter::new(CAPACITY, RATE, true, &clock);

    assert!(limiter.available() == CAPACITY);
    assert!(limiter.capacity() == CAPACITY);
    assert!(limiter.refill_rate_per_ms() == RATE);
    assert!(limiter.is_enabled() == true);
    assert!(limiter.last_updated_ms() == 0);

    clock.destroy_for_testing();
    destroy(limiter);
}

#[test]
fun constructor_disabled() {
    let ctx = &mut tx_context::dummy();
    let clock = clock::create_for_testing(ctx);
    let limiter = rate_limiter::new(CAPACITY, RATE, false, &clock);

    assert!(limiter.is_enabled() == false);
    assert!(limiter.available() == CAPACITY);

    clock.destroy_for_testing();
    destroy(limiter);
}

#[test]
fun get_available_withdrawal_returns_capacity_initially() {
    let ctx = &mut tx_context::dummy();
    let clock = clock::create_for_testing(ctx);
    let limiter = rate_limiter::new(CAPACITY, RATE, true, &clock);

    let available = limiter.get_available_withdrawal(&clock);
    assert!(available == CAPACITY);

    clock.destroy_for_testing();
    destroy(limiter);
}

#[test]
fun refill_works() {
    let ctx = &mut tx_context::dummy();
    let mut clock = clock::create_for_testing(ctx);
    clock::set_for_testing(&mut clock, 1000);
    let mut limiter = rate_limiter::new(CAPACITY, RATE, true, &clock);

    let success = limiter.check_and_record_withdrawal(CAPACITY, &clock);
    assert!(success == true);
    assert!(limiter.available() == 0);

    clock::set_for_testing(&mut clock, 1500);
    let available = limiter.get_available_withdrawal(&clock);
    assert!(available == 500 * RATE);

    clock::set_for_testing(&mut clock, 2000);
    let available_full = limiter.get_available_withdrawal(&clock);
    assert!(available_full == CAPACITY);

    clock.destroy_for_testing();
    destroy(limiter);
}

#[test]
fun refill_caps_at_capacity() {
    let ctx = &mut tx_context::dummy();
    let mut clock = clock::create_for_testing(ctx);
    clock::set_for_testing(&mut clock, 1000);
    let mut limiter = rate_limiter::new(CAPACITY, RATE, true, &clock);

    let success = limiter.check_and_record_withdrawal(CAPACITY / 2, &clock);
    assert!(success == true);
    assert!(limiter.available() == CAPACITY / 2);

    clock::set_for_testing(&mut clock, 1_000_000_000);
    let available = limiter.get_available_withdrawal(&clock);
    assert!(available == CAPACITY);

    clock.destroy_for_testing();
    destroy(limiter);
}

#[test]
fun consume_works() {
    let ctx = &mut tx_context::dummy();
    let mut clock = clock::create_for_testing(ctx);
    clock::set_for_testing(&mut clock, 1000);
    let mut limiter = rate_limiter::new(CAPACITY, RATE, true, &clock);

    let consume_amount = CAPACITY / 4;
    let success = limiter.check_and_record_withdrawal(consume_amount, &clock);
    assert!(success == true);
    assert!(limiter.available() == CAPACITY - consume_amount);

    clock.destroy_for_testing();
    destroy(limiter);
}

#[test]
fun consume_exact_capacity() {
    let ctx = &mut tx_context::dummy();
    let mut clock = clock::create_for_testing(ctx);
    clock::set_for_testing(&mut clock, 1000);
    let mut limiter = rate_limiter::new(CAPACITY, RATE, true, &clock);

    let success = limiter.check_and_record_withdrawal(CAPACITY, &clock);
    assert!(success == true);
    assert!(limiter.available() == 0);

    clock.destroy_for_testing();
    destroy(limiter);
}

#[test]
fun consume_fails_when_exceeds_available() {
    let ctx = &mut tx_context::dummy();
    let mut clock = clock::create_for_testing(ctx);
    clock::set_for_testing(&mut clock, 1000);
    let mut limiter = rate_limiter::new(CAPACITY, RATE, true, &clock);

    let success = limiter.check_and_record_withdrawal(CAPACITY + 1, &clock);
    assert!(success == false);
    assert!(limiter.available() == CAPACITY);

    clock.destroy_for_testing();
    destroy(limiter);
}

#[test]
fun consume_fails_when_exceeds_capacity() {
    let ctx = &mut tx_context::dummy();
    let mut clock = clock::create_for_testing(ctx);
    clock::set_for_testing(&mut clock, 1000);
    let mut limiter = rate_limiter::new(CAPACITY, RATE, true, &clock);

    let success = limiter.check_and_record_withdrawal(CAPACITY * 2, &clock);
    assert!(success == false);

    clock.destroy_for_testing();
    destroy(limiter);
}

#[test]
fun multiple_consumptions_with_refill() {
    let ctx = &mut tx_context::dummy();
    let mut clock = clock::create_for_testing(ctx);
    clock::set_for_testing(&mut clock, 1000);
    let mut limiter = rate_limiter::new(CAPACITY, RATE, true, &clock);

    let success1 = limiter.check_and_record_withdrawal(CAPACITY / 2, &clock);
    assert!(success1 == true);
    assert!(limiter.available() == CAPACITY / 2);

    clock::set_for_testing(&mut clock, 1250);

    let success2 = limiter.check_and_record_withdrawal(CAPACITY / 4, &clock);
    assert!(success2 == true);

    let expected = CAPACITY / 2 + (250 * RATE) - CAPACITY / 4;
    assert!(limiter.available() == expected);

    clock.destroy_for_testing();
    destroy(limiter);
}

#[test]
fun consume_then_wait_then_consume_again() {
    let ctx = &mut tx_context::dummy();
    let mut clock = clock::create_for_testing(ctx);
    clock::set_for_testing(&mut clock, 1000);
    let mut limiter = rate_limiter::new(CAPACITY, RATE, true, &clock);

    let success1 = limiter.check_and_record_withdrawal(CAPACITY, &clock);
    assert!(success1 == true);
    assert!(limiter.available() == 0);

    let success2 = limiter.check_and_record_withdrawal(1, &clock);
    assert!(success2 == false);

    clock::set_for_testing(&mut clock, 2000);

    let success3 = limiter.check_and_record_withdrawal(CAPACITY, &clock);
    assert!(success3 == true);

    clock.destroy_for_testing();
    destroy(limiter);
}

#[test]
fun disabled_allows_any_amount() {
    let ctx = &mut tx_context::dummy();
    let mut clock = clock::create_for_testing(ctx);
    clock::set_for_testing(&mut clock, 1000);
    let mut limiter = rate_limiter::new(CAPACITY, RATE, false, &clock);

    let success = limiter.check_and_record_withdrawal(CAPACITY * 10, &clock);
    assert!(success == true);

    assert!(limiter.get_available_withdrawal(&clock) == std::u64::max_value!());

    clock.destroy_for_testing();
    destroy(limiter);
}

#[test]
fun update_config_increases_capacity() {
    let ctx = &mut tx_context::dummy();
    let clock = clock::create_for_testing(ctx);
    let mut limiter = rate_limiter::new(CAPACITY, RATE, true, &clock);

    let new_capacity = CAPACITY * 2;
    limiter.update_config(new_capacity, RATE, true, &clock);

    assert!(limiter.capacity() == new_capacity);
    assert!(limiter.available() == CAPACITY);

    clock.destroy_for_testing();
    destroy(limiter);
}

#[test]
fun update_config_decreases_capacity_caps_available() {
    let ctx = &mut tx_context::dummy();
    let clock = clock::create_for_testing(ctx);
    let mut limiter = rate_limiter::new(CAPACITY, RATE, true, &clock);

    let new_capacity = CAPACITY / 2;
    limiter.update_config(new_capacity, RATE, true, &clock);

    assert!(limiter.capacity() == new_capacity);
    assert!(limiter.available() == new_capacity);

    clock.destroy_for_testing();
    destroy(limiter);
}

#[test]
fun update_config_changes_rate() {
    let ctx = &mut tx_context::dummy();
    let mut clock = clock::create_for_testing(ctx);
    clock::set_for_testing(&mut clock, 1000);
    let mut limiter = rate_limiter::new(CAPACITY, RATE, true, &clock);

    limiter.check_and_record_withdrawal(CAPACITY, &clock);
    assert!(limiter.available() == 0);

    let new_rate = RATE * 2;
    limiter.update_config(CAPACITY, new_rate, true, &clock);

    clock::set_for_testing(&mut clock, 1500);
    let available = limiter.get_available_withdrawal(&clock);
    assert!(available == CAPACITY);

    clock.destroy_for_testing();
    destroy(limiter);
}

#[test]
fun update_config_enables() {
    let ctx = &mut tx_context::dummy();
    let clock = clock::create_for_testing(ctx);
    let mut limiter = rate_limiter::new(CAPACITY, RATE, false, &clock);
    assert!(limiter.is_enabled() == false);

    limiter.update_config(CAPACITY, RATE, true, &clock);
    assert!(limiter.is_enabled() == true);

    clock.destroy_for_testing();
    destroy(limiter);
}

#[test]
fun update_config_disables() {
    let ctx = &mut tx_context::dummy();
    let clock = clock::create_for_testing(ctx);
    let mut limiter = rate_limiter::new(CAPACITY, RATE, true, &clock);
    assert!(limiter.is_enabled() == true);

    limiter.update_config(CAPACITY, RATE, false, &clock);
    assert!(limiter.is_enabled() == false);

    clock.destroy_for_testing();
    destroy(limiter);
}

#[test]
fun zero_consumption_succeeds() {
    let ctx = &mut tx_context::dummy();
    let mut clock = clock::create_for_testing(ctx);
    clock::set_for_testing(&mut clock, 1000);
    let mut limiter = rate_limiter::new(CAPACITY, RATE, true, &clock);

    let success = limiter.check_and_record_withdrawal(0, &clock);
    assert!(success == true);
    assert!(limiter.available() == CAPACITY);

    clock.destroy_for_testing();
    destroy(limiter);
}

#[test]
fun timestamp_at_zero_works() {
    let ctx = &mut tx_context::dummy();
    let clock = clock::create_for_testing(ctx);
    let limiter = rate_limiter::new(CAPACITY, RATE, true, &clock);

    let available = limiter.get_available_withdrawal(&clock);
    assert!(available == CAPACITY);

    clock.destroy_for_testing();
    destroy(limiter);
}

#[test]
fun partial_refill_precision() {
    let capacity: u64 = 1_000_000;
    let rate: u64 = 100;

    let ctx = &mut tx_context::dummy();
    let mut clock = clock::create_for_testing(ctx);
    clock::set_for_testing(&mut clock, 1000);
    let mut limiter = rate_limiter::new(capacity, rate, true, &clock);

    limiter.check_and_record_withdrawal(capacity, &clock);

    clock::set_for_testing(&mut clock, 1001);
    let available = limiter.get_available_withdrawal(&clock);
    assert!(available == 100);

    clock::set_for_testing(&mut clock, 1010);
    let available2 = limiter.get_available_withdrawal(&clock);
    assert!(available2 == 1000);

    clock.destroy_for_testing();
    destroy(limiter);
}

#[test]
fun large_values_no_overflow() {
    let capacity: u64 = 18_446_744_073_709_551_615;
    let rate: u64 = 1_000_000_000_000;

    let ctx = &mut tx_context::dummy();
    let mut clock = clock::create_for_testing(ctx);
    clock::set_for_testing(&mut clock, 1000);
    let mut limiter = rate_limiter::new(capacity, rate, true, &clock);

    let success = limiter.check_and_record_withdrawal(capacity, &clock);
    assert!(success == true);

    clock::set_for_testing(&mut clock, 1_000_000_000);
    let available = limiter.get_available_withdrawal(&clock);
    assert!(available == capacity);

    clock.destroy_for_testing();
    destroy(limiter);
}

#[test]
fun same_timestamp_no_double_refill() {
    let ctx = &mut tx_context::dummy();
    let mut clock = clock::create_for_testing(ctx);
    clock::set_for_testing(&mut clock, 1000);
    let mut limiter = rate_limiter::new(CAPACITY, RATE, true, &clock);

    limiter.check_and_record_withdrawal(CAPACITY / 2, &clock);
    let after_first = limiter.available();

    limiter.check_and_record_withdrawal(CAPACITY / 4, &clock);
    let after_second = limiter.available();

    assert!(after_second == after_first - CAPACITY / 4);

    clock.destroy_for_testing();
    destroy(limiter);
}

#[test]
fun last_updated_changes_on_consumption() {
    let ctx = &mut tx_context::dummy();
    let mut clock = clock::create_for_testing(ctx);
    let mut limiter = rate_limiter::new(CAPACITY, RATE, true, &clock);

    assert!(limiter.last_updated_ms() == 0);

    clock::set_for_testing(&mut clock, 5000);
    limiter.check_and_record_withdrawal(1000, &clock);

    assert!(limiter.last_updated_ms() == 5000);

    clock.destroy_for_testing();
    destroy(limiter);
}

#[test]
fun wait_time_for_refill() {
    let ctx = &mut tx_context::dummy();
    let mut clock = clock::create_for_testing(ctx);
    clock::set_for_testing(&mut clock, 1000);
    let mut limiter = rate_limiter::new(CAPACITY, RATE, true, &clock);

    limiter.check_and_record_withdrawal(CAPACITY, &clock);
    assert!(limiter.available() == 0);

    clock::set_for_testing(&mut clock, 1100);
    assert!(limiter.get_available_withdrawal(&clock) == 10_000_000_000);

    clock::set_for_testing(&mut clock, 1500);
    assert!(limiter.get_available_withdrawal(&clock) == 50_000_000_000);

    clock::set_for_testing(&mut clock, 2000);
    assert!(limiter.get_available_withdrawal(&clock) == CAPACITY);

    clock.destroy_for_testing();
    destroy(limiter);
}

#[test]
fun consume_after_partial_refill() {
    let ctx = &mut tx_context::dummy();
    let mut clock = clock::create_for_testing(ctx);
    clock::set_for_testing(&mut clock, 1000);
    let mut limiter = rate_limiter::new(CAPACITY, RATE, true, &clock);

    limiter.check_and_record_withdrawal(CAPACITY, &clock);

    clock::set_for_testing(&mut clock, 1200);

    let success1 = limiter.check_and_record_withdrawal(30_000_000_000, &clock);
    assert!(success1 == false);

    let success2 = limiter.check_and_record_withdrawal(20_000_000_000, &clock);
    assert!(success2 == true);
    assert!(limiter.available() == 0);

    clock.destroy_for_testing();
    destroy(limiter);
}

#[test]
fun burst_then_steady_consumption() {
    let ctx = &mut tx_context::dummy();
    let mut clock = clock::create_for_testing(ctx);
    clock::set_for_testing(&mut clock, 1000);
    let mut limiter = rate_limiter::new(CAPACITY, RATE, true, &clock);

    let success1 = limiter.check_and_record_withdrawal(CAPACITY, &clock);
    assert!(success1 == true);

    let mut i = 0u64;
    while (i < 10) {
        clock::increment_for_testing(&mut clock, 1);
        let success = limiter.check_and_record_withdrawal(RATE, &clock);
        assert!(success == true);
        i = i + 1;
    };

    assert!(limiter.available() == 0);

    clock.destroy_for_testing();
    destroy(limiter);
}

// === Integration Tests ===

#[test]
fun pool_basic_rate_limiting() {
    let (mut scenario, clock, admin_cap, maintainer_cap) = test_helpers::setup_margin_registry();

    scenario.next_tx(admin());
    let mut registry = scenario.take_shared<MarginRegistry>();
    let _pool_id = test_helpers::create_pool_with_rate_limit<USDC>(
        &mut registry,
        &maintainer_cap,
        1_000_000,
        10_000,
        10,
        true,
        &clock,
        &mut scenario,
    );
    test_scenario::return_shared(registry);

    scenario.next_tx(user1());
    let mut pool = scenario.take_shared<MarginPool<USDC>>();
    let registry = scenario.take_shared<MarginRegistry>();
    let supplier_cap = margin_pool::mint_supplier_cap(&registry, &clock, scenario.ctx());

    let supply_coin = coin::mint_for_testing<USDC>(20_000, scenario.ctx());
    pool.supply(&registry, &supplier_cap, supply_coin, option::none(), &clock);

    let withdrawn1 = pool.withdraw(
        &registry,
        &supplier_cap,
        option::some(10_000),
        &clock,
        scenario.ctx(),
    );
    assert!(withdrawn1.value() == 10_000);

    let available = pool.get_available_withdrawal(&clock);
    assert!(available == 0);

    destroy_3!(withdrawn1, supplier_cap, maintainer_cap);
    destroy(admin_cap);
    return_shared_2!(pool, registry);
    clock.destroy_for_testing();
    scenario.end();
}

#[test]
fun pool_capacity_refills_over_time() {
    let (
        mut scenario,
        mut clock,
        admin_cap,
        maintainer_cap,
    ) = test_helpers::setup_margin_registry();

    scenario.next_tx(admin());
    let mut registry = scenario.take_shared<MarginRegistry>();
    let _pool_id = test_helpers::create_pool_with_rate_limit<USDC>(
        &mut registry,
        &maintainer_cap,
        1_000_000,
        10_000,
        10,
        true,
        &clock,
        &mut scenario,
    );
    test_scenario::return_shared(registry);

    scenario.next_tx(user1());
    let mut pool = scenario.take_shared<MarginPool<USDC>>();
    let registry = scenario.take_shared<MarginRegistry>();
    let supplier_cap = margin_pool::mint_supplier_cap(&registry, &clock, scenario.ctx());

    let supply_coin = coin::mint_for_testing<USDC>(30_000, scenario.ctx());
    pool.supply(&registry, &supplier_cap, supply_coin, option::none(), &clock);

    let withdrawn1 = pool.withdraw(
        &registry,
        &supplier_cap,
        option::some(10_000),
        &clock,
        scenario.ctx(),
    );
    assert!(withdrawn1.value() == 10_000);

    assert!(pool.get_available_withdrawal(&clock) == 0);

    clock::increment_for_testing(&mut clock, 500);

    let available = pool.get_available_withdrawal(&clock);
    assert!(available == 5_000);

    let withdrawn2 = pool.withdraw(
        &registry,
        &supplier_cap,
        option::some(5_000),
        &clock,
        scenario.ctx(),
    );
    assert!(withdrawn2.value() == 5_000);

    clock::increment_for_testing(&mut clock, 1_000);
    let available_after = pool.get_available_withdrawal(&clock);
    assert!(available_after == 10_000);

    destroy_4!(withdrawn1, withdrawn2, supplier_cap, maintainer_cap);
    destroy(admin_cap);
    return_shared_2!(pool, registry);
    clock.destroy_for_testing();
    scenario.end();
}

#[test]
fun pool_capacity_caps_at_max() {
    let (
        mut scenario,
        mut clock,
        admin_cap,
        maintainer_cap,
    ) = test_helpers::setup_margin_registry();

    scenario.next_tx(admin());
    let mut registry = scenario.take_shared<MarginRegistry>();
    let _pool_id = test_helpers::create_pool_with_rate_limit<USDC>(
        &mut registry,
        &maintainer_cap,
        1_000_000,
        10_000,
        10,
        true,
        &clock,
        &mut scenario,
    );
    test_scenario::return_shared(registry);

    scenario.next_tx(user1());
    let mut pool = scenario.take_shared<MarginPool<USDC>>();
    let registry = scenario.take_shared<MarginRegistry>();
    let supplier_cap = margin_pool::mint_supplier_cap(&registry, &clock, scenario.ctx());

    let supply_coin = coin::mint_for_testing<USDC>(20_000, scenario.ctx());
    pool.supply(&registry, &supplier_cap, supply_coin, option::none(), &clock);

    clock::increment_for_testing(&mut clock, 10 * HOUR_MS);

    let available = pool.get_available_withdrawal(&clock);
    assert!(available == 10_000);

    let withdrawn = pool.withdraw(
        &registry,
        &supplier_cap,
        option::some(10_000),
        &clock,
        scenario.ctx(),
    );
    assert!(withdrawn.value() == 10_000);

    destroy_3!(withdrawn, supplier_cap, maintainer_cap);
    destroy(admin_cap);
    return_shared_2!(pool, registry);
    clock.destroy_for_testing();
    scenario.end();
}

#[test, expected_failure(abort_code = deepbook_margin::margin_pool::ERateLimitExceeded)]
fun pool_withdrawal_exceeds_limit_fails() {
    let (mut scenario, clock, _admin_cap, maintainer_cap) = test_helpers::setup_margin_registry();

    scenario.next_tx(admin());
    let mut registry = scenario.take_shared<MarginRegistry>();
    let _pool_id = test_helpers::create_pool_with_rate_limit<USDC>(
        &mut registry,
        &maintainer_cap,
        1_000_000,
        10_000,
        10,
        true,
        &clock,
        &mut scenario,
    );
    test_scenario::return_shared(registry);

    scenario.next_tx(user1());
    let mut pool = scenario.take_shared<MarginPool<USDC>>();
    let registry = scenario.take_shared<MarginRegistry>();
    let supplier_cap = margin_pool::mint_supplier_cap(&registry, &clock, scenario.ctx());

    let supply_coin = coin::mint_for_testing<USDC>(20_000, scenario.ctx());
    pool.supply(&registry, &supplier_cap, supply_coin, option::none(), &clock);

    let _withdrawn = pool.withdraw(
        &registry,
        &supplier_cap,
        option::some(15_000),
        &clock,
        scenario.ctx(),
    );

    abort
}

#[test]
fun pool_disabled_rate_limiter() {
    let (mut scenario, clock, admin_cap, maintainer_cap) = test_helpers::setup_margin_registry();

    scenario.next_tx(admin());
    let mut registry = scenario.take_shared<MarginRegistry>();
    let _pool_id = test_helpers::create_pool_with_rate_limit<USDC>(
        &mut registry,
        &maintainer_cap,
        1_000_000,
        10_000,
        10,
        false,
        &clock,
        &mut scenario,
    );
    test_scenario::return_shared(registry);

    scenario.next_tx(user1());
    let mut pool = scenario.take_shared<MarginPool<USDC>>();
    let registry = scenario.take_shared<MarginRegistry>();
    let supplier_cap = margin_pool::mint_supplier_cap(&registry, &clock, scenario.ctx());

    let supply_coin = coin::mint_for_testing<USDC>(100_000, scenario.ctx());
    pool.supply(&registry, &supplier_cap, supply_coin, option::none(), &clock);

    let withdrawn = pool.withdraw(
        &registry,
        &supplier_cap,
        option::some(50_000),
        &clock,
        scenario.ctx(),
    );
    assert!(withdrawn.value() == 50_000);

    destroy_3!(withdrawn, supplier_cap, maintainer_cap);
    destroy(admin_cap);
    return_shared_2!(pool, registry);
    clock.destroy_for_testing();
    scenario.end();
}

#[test]
/// Test that deposit increases rate limit available, so deposit/withdraw cycles don't consume the bucket.
/// This prevents griefing attacks where someone deposits and withdraws to block other users.
fun deposit_refills_rate_limit_bucket() {
    let ctx = &mut tx_context::dummy();
    let mut clock = clock::create_for_testing(ctx);
    clock::set_for_testing(&mut clock, 1000);

    let capacity: u64 = 100_000;
    let rate: u64 = 1; // slow refill rate
    let mut limiter = rate_limiter::new(capacity, rate, true, &clock);

    // First drain the bucket partially so deposits can refill it
    let success = limiter.check_and_record_withdrawal(50_000, &clock);
    assert!(success == true);
    assert!(limiter.available() == 50_000);

    // Now simulate 20 deposit/withdraw cycles of 10_000 each
    let cycle_amount: u64 = 10_000;
    let mut i = 0u64;
    while (i < 20) {
        // Deposit increases available (capped at capacity)
        limiter.record_deposit(cycle_amount, &clock);

        // Withdraw decreases available
        let success = limiter.check_and_record_withdrawal(cycle_amount, &clock);
        assert!(success == true);

        i = i + 1;
    };

    // After 20 cycles, bucket should be at 50k (where we started after initial drain)
    // Each deposit→withdraw cycle nets to zero when bucket is below capacity
    assert!(limiter.available() == 50_000);

    clock.destroy_for_testing();
    destroy(limiter);
}

#[test]
/// Test that pure withdrawals without deposits will eventually hit the rate limit.
fun pure_withdrawals_hit_rate_limit() {
    let ctx = &mut tx_context::dummy();
    let mut clock = clock::create_for_testing(ctx);
    clock::set_for_testing(&mut clock, 1000);

    let capacity: u64 = 100_000;
    let rate: u64 = 1;
    let mut limiter = rate_limiter::new(capacity, rate, true, &clock);

    // First 10 withdrawals of 10_000 should succeed (total 100k = capacity)
    let mut i = 0u64;
    while (i < 10) {
        let success = limiter.check_and_record_withdrawal(10_000, &clock);
        assert!(success == true);
        i = i + 1;
    };

    // 11th withdrawal should fail (bucket exhausted)
    let success = limiter.check_and_record_withdrawal(10_000, &clock);
    assert!(success == false);

    clock.destroy_for_testing();
    destroy(limiter);
}

#[test]
/// Integration test: Pool with 400k funds, 500k max cap, 100k rate limit.
/// 20 cycles of deposit 10k / withdraw 10k should not hit rate limit.
/// Key: Each deposit refills bucket, allowing subsequent withdraw to succeed.
fun pool_deposit_withdraw_cycles_no_rate_limit() {
    let (mut scenario, clock, admin_cap, maintainer_cap) = test_helpers::setup_margin_registry();

    scenario.next_tx(admin());
    let mut registry = scenario.take_shared<MarginRegistry>();

    // Create pool with 500k supply cap, 100k rate limit capacity, slow refill
    let _pool_id = test_helpers::create_pool_with_rate_limit<USDC>(
        &mut registry,
        &maintainer_cap,
        500_000, // supply cap
        100_000, // rate limit capacity
        1, // very slow refill rate (1 per ms)
        true, // enabled
        &clock,
        &mut scenario,
    );
    test_scenario::return_shared(registry);

    // Initial supply of 400k to the pool
    scenario.next_tx(user1());
    let mut pool = scenario.take_shared<MarginPool<USDC>>();
    let registry = scenario.take_shared<MarginRegistry>();
    let supplier_cap = margin_pool::mint_supplier_cap(&registry, &clock, scenario.ctx());

    let initial_supply = coin::mint_for_testing<USDC>(400_000, scenario.ctx());
    pool.supply(&registry, &supplier_cap, initial_supply, option::none(), &clock);

    // Verify initial state - bucket at capacity after initial supply
    assert!(pool.total_supply() == 400_000);
    assert!(pool.get_available_withdrawal(&clock) == 100_000);

    // Perform 20 cycles of deposit 10k, withdraw 10k
    // All 20 withdrawals should succeed because each deposit refills what the withdraw takes
    let cycle_amount: u64 = 10_000;
    let mut i = 0u64;
    while (i < 20) {
        // Deposit 10k - refills bucket (capped at capacity)
        let deposit_coin = coin::mint_for_testing<USDC>(cycle_amount, scenario.ctx());
        pool.supply(&registry, &supplier_cap, deposit_coin, option::none(), &clock);

        // Withdraw 10k - should succeed
        let withdrawn = pool.withdraw(
            &registry,
            &supplier_cap,
            option::some(cycle_amount),
            &clock,
            scenario.ctx(),
        );
        assert!(withdrawn.value() == cycle_amount);
        withdrawn.burn_for_testing();

        i = i + 1;
    };

    // After 20 cycles:
    // - Bucket ends at 90k (first deposit was wasted since bucket was at cap, then withdraw took 10k)
    // - Each subsequent cycle: deposit refills to 100k, withdraw takes to 90k
    assert!(pool.get_available_withdrawal(&clock) == 90_000);

    // Vault should still have 400k (net zero change from cycles)
    // Note: We check vault_balance instead of total_supply because share calculations can have rounding
    assert!(pool.vault_balance() == 400_000);

    destroy(supplier_cap);
    destroy(maintainer_cap);
    destroy(admin_cap);
    return_shared_2!(pool, registry);
    clock.destroy_for_testing();
    scenario.end();
}

#[test, expected_failure(abort_code = deepbook_margin::margin_pool::ERateLimitExceeded)]
/// Integration test: Without deposits, pure withdrawals should hit rate limit.
fun pool_pure_withdrawals_hit_rate_limit() {
    let (mut scenario, clock, _admin_cap, maintainer_cap) = test_helpers::setup_margin_registry();

    scenario.next_tx(admin());
    let mut registry = scenario.take_shared<MarginRegistry>();

    // Create pool with 500k supply cap, 100k rate limit capacity
    let _pool_id = test_helpers::create_pool_with_rate_limit<USDC>(
        &mut registry,
        &maintainer_cap,
        500_000, // supply cap
        100_000, // rate limit capacity
        1, // very slow refill
        true, // enabled
        &clock,
        &mut scenario,
    );
    test_scenario::return_shared(registry);

    scenario.next_tx(user1());
    let mut pool = scenario.take_shared<MarginPool<USDC>>();
    let registry = scenario.take_shared<MarginRegistry>();
    let supplier_cap = margin_pool::mint_supplier_cap(&registry, &clock, scenario.ctx());

    // Supply 400k initially
    let initial_supply = coin::mint_for_testing<USDC>(400_000, scenario.ctx());
    pool.supply(&registry, &supplier_cap, initial_supply, option::none(), &clock);

    // Try to withdraw 110k (exceeds 100k rate limit) - should fail
    let _withdrawn = pool.withdraw(
        &registry,
        &supplier_cap,
        option::some(110_000),
        &clock,
        scenario.ctx(),
    );

    abort
}
