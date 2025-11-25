#[test_only]
module deepbook_margin::rate_limiter_unit_tests;

use deepbook_margin::rate_limiter;
use sui::{clock, test_utils::destroy};

const CAPACITY: u64 = 100_000_000_000; // 100B tokens
const RATE: u64 = 100_000_000; // 100M tokens per ms (100B per second)


#[test]
fun test_constructor_success() {
    let limiter = rate_limiter::new(CAPACITY, RATE, true);

    assert!(limiter.available() == CAPACITY);
    assert!(limiter.capacity() == CAPACITY);
    assert!(limiter.refill_rate_per_ms() == RATE);
    assert!(limiter.is_enabled() == true);
    // last_updated starts at 0
    assert!(limiter.last_updated_ms() == 0);

    destroy(limiter);
}

#[test]
fun test_constructor_disabled() {
    let limiter = rate_limiter::new(CAPACITY, RATE, false);

    assert!(limiter.is_enabled() == false);
    assert!(limiter.available() == CAPACITY);

    destroy(limiter);
}

#[test]
fun test_get_token_bucket_success() {
    let limiter = rate_limiter::new(CAPACITY, RATE, true);
    let ctx = &mut tx_context::dummy();
    let clock = clock::create_for_testing(ctx);

    // Available should match capacity initially
    let available = limiter.get_available_withdrawal(&clock);
    assert!(available == CAPACITY);

    clock.destroy_for_testing();
    destroy(limiter);
}

#[test]
fun test_refill_success() {
    let mut limiter = rate_limiter::new(CAPACITY, RATE, true);
    let ctx = &mut tx_context::dummy();
    let mut clock = clock::create_for_testing(ctx);

    // Consume all tokens
    clock::set_for_testing(&mut clock, 1000);
    let success = limiter.check_and_record_withdrawal(CAPACITY, &clock);
    assert!(success == true);
    assert!(limiter.available() == 0);

    // Wait 500ms - should refill 500 * RATE = 50B tokens
    clock::set_for_testing(&mut clock, 1500);
    let available = limiter.get_available_withdrawal(&clock);
    assert!(available == 500 * RATE);

    // Wait until full refill (1000ms total from empty)
    clock::set_for_testing(&mut clock, 2000);
    let available_full = limiter.get_available_withdrawal(&clock);
    assert!(available_full == CAPACITY);

    clock.destroy_for_testing();
    destroy(limiter);
}

#[test]
fun test_refill_caps_at_capacity() {
    let mut limiter = rate_limiter::new(CAPACITY, RATE, true);
    let ctx = &mut tx_context::dummy();
    let mut clock = clock::create_for_testing(ctx);

    // Consume half
    clock::set_for_testing(&mut clock, 1000);
    let success = limiter.check_and_record_withdrawal(CAPACITY / 2, &clock);
    assert!(success == true);
    assert!(limiter.available() == CAPACITY / 2);

    // Wait very long time - should cap at CAPACITY, not overflow
    clock::set_for_testing(&mut clock, 1_000_000_000); // ~11.5 days
    let available = limiter.get_available_withdrawal(&clock);
    assert!(available == CAPACITY);

    clock.destroy_for_testing();
    destroy(limiter);
}

#[test]
fun test_consume_success() {
    let mut limiter = rate_limiter::new(CAPACITY, RATE, true);
    let ctx = &mut tx_context::dummy();
    let mut clock = clock::create_for_testing(ctx);
    clock::set_for_testing(&mut clock, 1000);

    // Consume some tokens
    let consume_amount = CAPACITY / 4;
    let success = limiter.check_and_record_withdrawal(consume_amount, &clock);
    assert!(success == true);
    assert!(limiter.available() == CAPACITY - consume_amount);

    clock.destroy_for_testing();
    destroy(limiter);
}

#[test]
fun test_consume_exact_capacity() {
    let mut limiter = rate_limiter::new(CAPACITY, RATE, true);
    let ctx = &mut tx_context::dummy();
    let mut clock = clock::create_for_testing(ctx);
    clock::set_for_testing(&mut clock, 1000);

    // Consume exactly capacity
    let success = limiter.check_and_record_withdrawal(CAPACITY, &clock);
    assert!(success == true);
    assert!(limiter.available() == 0);

    clock.destroy_for_testing();
    destroy(limiter);
}

#[test]
fun test_consume_fails_exceeds_available() {
    let mut limiter = rate_limiter::new(CAPACITY, RATE, true);
    let ctx = &mut tx_context::dummy();
    let mut clock = clock::create_for_testing(ctx);
    clock::set_for_testing(&mut clock, 1000);

    // Try to consume more than available
    let success = limiter.check_and_record_withdrawal(CAPACITY + 1, &clock);
    assert!(success == false);
    // Tokens should remain unchanged on failure
    assert!(limiter.available() == CAPACITY);

    clock.destroy_for_testing();
    destroy(limiter);
}

#[test]
fun test_consume_fails_exceeds_capacity() {
    let mut limiter = rate_limiter::new(CAPACITY, RATE, true);
    let ctx = &mut tx_context::dummy();
    let mut clock = clock::create_for_testing(ctx);
    clock::set_for_testing(&mut clock, 1000);

    // Even with full bucket, cannot consume more than capacity
    let success = limiter.check_and_record_withdrawal(CAPACITY * 2, &clock);
    assert!(success == false);

    clock.destroy_for_testing();
    destroy(limiter);
}

// === Multiple Consumption Tests ===

#[test]
fun test_multiple_consumptions_with_refill() {
    let mut limiter = rate_limiter::new(CAPACITY, RATE, true);
    let ctx = &mut tx_context::dummy();
    let mut clock = clock::create_for_testing(ctx);
    clock::set_for_testing(&mut clock, 1000);

    // First consumption - use half
    let success1 = limiter.check_and_record_withdrawal(CAPACITY / 2, &clock);
    assert!(success1 == true);
    assert!(limiter.available() == CAPACITY / 2);

    // Wait 250ms - should refill 25B (250 * 100M)
    clock::set_for_testing(&mut clock, 1250);

    // Second consumption - use another quarter
    let success2 = limiter.check_and_record_withdrawal(CAPACITY / 4, &clock);
    assert!(success2 == true);

    // Available should be: 50B + 25B - 25B = 50B
    // But we need to account for the refill happening during check_and_record_withdrawal
    let expected = CAPACITY / 2 + (250 * RATE) - CAPACITY / 4;
    assert!(limiter.available() == expected);

    clock.destroy_for_testing();
    destroy(limiter);
}

#[test]
fun test_consume_then_wait_then_consume_again() {
    let mut limiter = rate_limiter::new(CAPACITY, RATE, true);
    let ctx = &mut tx_context::dummy();
    let mut clock = clock::create_for_testing(ctx);
    clock::set_for_testing(&mut clock, 1000);

    // Drain the bucket
    let success1 = limiter.check_and_record_withdrawal(CAPACITY, &clock);
    assert!(success1 == true);
    assert!(limiter.available() == 0);

    // Immediate second attempt should fail
    let success2 = limiter.check_and_record_withdrawal(1, &clock);
    assert!(success2 == false);

    // Wait for full refill (1000ms at RATE = 100M/ms means 1000ms to refill 100B)
    clock::set_for_testing(&mut clock, 2000);

    // Now should be able to consume again
    let success3 = limiter.check_and_record_withdrawal(CAPACITY, &clock);
    assert!(success3 == true);

    clock.destroy_for_testing();
    destroy(limiter);
}

// === Disabled Rate Limiter Tests ===

#[test]
fun test_disabled_allows_any_amount() {
    let mut limiter = rate_limiter::new(CAPACITY, RATE, false);
    let ctx = &mut tx_context::dummy();
    let mut clock = clock::create_for_testing(ctx);
    clock::set_for_testing(&mut clock, 1000);

    // Should allow consumption even exceeding capacity when disabled
    let success = limiter.check_and_record_withdrawal(CAPACITY * 10, &clock);
    assert!(success == true);

    // Available returns capacity when disabled
    assert!(limiter.get_available_withdrawal(&clock) == CAPACITY);

    clock.destroy_for_testing();
    destroy(limiter);
}

#[test]
fun test_update_config_increases_capacity() {
    let mut limiter = rate_limiter::new(CAPACITY, RATE, true);

    let new_capacity = CAPACITY * 2;
    limiter.update_config(new_capacity, RATE, true);

    assert!(limiter.capacity() == new_capacity);
    // Available stays the same (doesn't auto-increase)
    assert!(limiter.available() == CAPACITY);

    destroy(limiter);
}

#[test]
fun test_update_config_decreases_capacity_caps_available() {
    let mut limiter = rate_limiter::new(CAPACITY, RATE, true);

    let new_capacity = CAPACITY / 2;
    limiter.update_config(new_capacity, RATE, true);

    assert!(limiter.capacity() == new_capacity);
    // Available should be capped to new capacity
    assert!(limiter.available() == new_capacity);

    destroy(limiter);
}

#[test]
fun test_update_config_changes_rate() {
    let mut limiter = rate_limiter::new(CAPACITY, RATE, true);
    let ctx = &mut tx_context::dummy();
    let mut clock = clock::create_for_testing(ctx);
    clock::set_for_testing(&mut clock, 1000);

    // Consume all
    limiter.check_and_record_withdrawal(CAPACITY, &clock);
    assert!(limiter.available() == 0);

    // Double the rate
    let new_rate = RATE * 2;
    limiter.update_config(CAPACITY, new_rate, true);

    // Wait 500ms - should refill at new rate: 500 * 200M = 100B (full)
    clock::set_for_testing(&mut clock, 1500);
    let available = limiter.get_available_withdrawal(&clock);
    assert!(available == CAPACITY);

    clock.destroy_for_testing();
    destroy(limiter);
}

#[test]
fun test_update_config_enables() {
    let mut limiter = rate_limiter::new(CAPACITY, RATE, false);
    assert!(limiter.is_enabled() == false);

    limiter.update_config(CAPACITY, RATE, true);
    assert!(limiter.is_enabled() == true);

    destroy(limiter);
}

#[test]
fun test_update_config_disables() {
    let mut limiter = rate_limiter::new(CAPACITY, RATE, true);
    assert!(limiter.is_enabled() == true);

    limiter.update_config(CAPACITY, RATE, false);
    assert!(limiter.is_enabled() == false);

    destroy(limiter);
}

// === Edge Case Tests ===

#[test]
fun test_zero_consumption() {
    let mut limiter = rate_limiter::new(CAPACITY, RATE, true);
    let ctx = &mut tx_context::dummy();
    let mut clock = clock::create_for_testing(ctx);
    clock::set_for_testing(&mut clock, 1000);

    // Zero consumption should succeed and not change state
    let success = limiter.check_and_record_withdrawal(0, &clock);
    assert!(success == true);
    assert!(limiter.available() == CAPACITY);

    clock.destroy_for_testing();
    destroy(limiter);
}

#[test]
fun test_timestamp_at_zero() {
    let limiter = rate_limiter::new(CAPACITY, RATE, true);
    let ctx = &mut tx_context::dummy();
    let clock = clock::create_for_testing(ctx);

    // Clock at 0 should still work
    let available = limiter.get_available_withdrawal(&clock);
    assert!(available == CAPACITY);

    clock.destroy_for_testing();
    destroy(limiter);
}

#[test]
fun test_partial_refill_precision() {
    // Use smaller numbers to test precision
    let capacity: u64 = 1_000_000;
    let rate: u64 = 100; // 100 per ms

    let mut limiter = rate_limiter::new(capacity, rate, true);
    let ctx = &mut tx_context::dummy();
    let mut clock = clock::create_for_testing(ctx);
    clock::set_for_testing(&mut clock, 1000);

    // Consume all
    limiter.check_and_record_withdrawal(capacity, &clock);

    // Wait 1ms - should have exactly 100 tokens
    clock::set_for_testing(&mut clock, 1001);
    let available = limiter.get_available_withdrawal(&clock);
    assert!(available == 100);

    // Wait 10ms total - should have exactly 1000 tokens
    clock::set_for_testing(&mut clock, 1010);
    let available2 = limiter.get_available_withdrawal(&clock);
    assert!(available2 == 1000);

    clock.destroy_for_testing();
    destroy(limiter);
}

#[test]
fun test_large_values_no_overflow() {
    // Test with very large values to ensure no overflow
    let capacity: u64 = 18_446_744_073_709_551_615; // u64 max
    let rate: u64 = 1_000_000_000_000; // 1T per ms

    let mut limiter = rate_limiter::new(capacity, rate, true);
    let ctx = &mut tx_context::dummy();
    let mut clock = clock::create_for_testing(ctx);
    clock::set_for_testing(&mut clock, 1000);

    // Should be able to consume max
    let success = limiter.check_and_record_withdrawal(capacity, &clock);
    assert!(success == true);

    // After long wait, should cap at capacity (no overflow)
    clock::set_for_testing(&mut clock, 1_000_000_000);
    let available = limiter.get_available_withdrawal(&clock);
    assert!(available == capacity);

    clock.destroy_for_testing();
    destroy(limiter);
}

// === Timestamp Handling Tests ===

#[test]
fun test_same_timestamp_no_double_refill() {
    let mut limiter = rate_limiter::new(CAPACITY, RATE, true);
    let ctx = &mut tx_context::dummy();
    let mut clock = clock::create_for_testing(ctx);
    clock::set_for_testing(&mut clock, 1000);

    // Consume half
    limiter.check_and_record_withdrawal(CAPACITY / 2, &clock);
    let after_first = limiter.available();

    // Same timestamp - another consumption
    limiter.check_and_record_withdrawal(CAPACITY / 4, &clock);
    let after_second = limiter.available();

    // Should have deducted without any refill
    assert!(after_second == after_first - CAPACITY / 4);

    clock.destroy_for_testing();
    destroy(limiter);
}

#[test]
fun test_last_updated_changes_on_consumption() {
    let mut limiter = rate_limiter::new(CAPACITY, RATE, true);
    let ctx = &mut tx_context::dummy();
    let mut clock = clock::create_for_testing(ctx);

    assert!(limiter.last_updated_ms() == 0);

    clock::set_for_testing(&mut clock, 5000);
    limiter.check_and_record_withdrawal(1000, &clock);

    assert!(limiter.last_updated_ms() == 5000);

    clock.destroy_for_testing();
    destroy(limiter);
}

#[test]
fun test_wait_time_for_refill() {
    let mut limiter = rate_limiter::new(CAPACITY, RATE, true);
    let ctx = &mut tx_context::dummy();
    let mut clock = clock::create_for_testing(ctx);
    clock::set_for_testing(&mut clock, 1000);

    // Drain completely
    limiter.check_and_record_withdrawal(CAPACITY, &clock);
    assert!(limiter.available() == 0);

    // Check available at various time points
    // At 1100ms (100ms later): 100 * 100M = 10B
    clock::set_for_testing(&mut clock, 1100);
    assert!(limiter.get_available_withdrawal(&clock) == 10_000_000_000);

    // At 1500ms (500ms later): 500 * 100M = 50B
    clock::set_for_testing(&mut clock, 1500);
    assert!(limiter.get_available_withdrawal(&clock) == 50_000_000_000);

    // At 2000ms (1000ms later): full capacity 100B
    clock::set_for_testing(&mut clock, 2000);
    assert!(limiter.get_available_withdrawal(&clock) == CAPACITY);

    clock.destroy_for_testing();
    destroy(limiter);
}

// === Consumption After Partial Refill ===

#[test]
fun test_consume_after_partial_refill() {
    let mut limiter = rate_limiter::new(CAPACITY, RATE, true);
    let ctx = &mut tx_context::dummy();
    let mut clock = clock::create_for_testing(ctx);
    clock::set_for_testing(&mut clock, 1000);

    // Drain
    limiter.check_and_record_withdrawal(CAPACITY, &clock);

    // Wait 200ms - refill 20B
    clock::set_for_testing(&mut clock, 1200);

    // Try to consume 30B - should fail (only 20B available)
    let success1 = limiter.check_and_record_withdrawal(30_000_000_000, &clock);
    assert!(success1 == false);

    // Consume 20B - should succeed
    let success2 = limiter.check_and_record_withdrawal(20_000_000_000, &clock);
    assert!(success2 == true);
    assert!(limiter.available() == 0);

    clock.destroy_for_testing();
    destroy(limiter);
}

// === Burst Then Steady State ===

#[test]
fun test_burst_then_steady_consumption() {
    let mut limiter = rate_limiter::new(CAPACITY, RATE, true);
    let ctx = &mut tx_context::dummy();
    let mut clock = clock::create_for_testing(ctx);
    clock::set_for_testing(&mut clock, 1000);

    // Burst: consume full capacity
    let success1 = limiter.check_and_record_withdrawal(CAPACITY, &clock);
    assert!(success1 == true);

    // Steady state: consume at refill rate
    // Every 1ms, RATE tokens refill. If we consume RATE every ms, we stay at 0.
    let mut i = 0;
    while (i < 10) {
        clock::increment_for_testing(&mut clock, 1);
        let success = limiter.check_and_record_withdrawal(RATE, &clock);
        assert!(success == true);
        i = i + 1;
    };

    // Should still be at 0 (consuming exactly the refill rate)
    assert!(limiter.available() == 0);

    clock.destroy_for_testing();
    destroy(limiter);
}
