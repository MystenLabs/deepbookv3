// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module deepbook_predict::vault_tests;

use deepbook_predict::{constants, vault};
use std::unit_test::{assert_eq, destroy};
use sui::coin;

public struct USDC has drop {}

/// 1 USDC = 1_000_000 (6 decimals)
macro fun usdc($amount: u64): u64 {
    $amount * 1_000_000
}

/// 1 contract = 1_000_000 quote units = $1 at settlement
macro fun contracts($n: u64): u64 {
    $n * 1_000_000
}

#[test]
fun new_vault_empty() {
    let ctx = &mut tx_context::dummy();
    let vault = vault::new<USDC>(ctx);

    assert_eq!(vault.balance(), 0);
    assert_eq!(vault.total_up_short(), 0);
    assert_eq!(vault.total_down_short(), 0);
    assert_eq!(vault.max_liability(), 0);

    let (up, down) = vault.oracle_exposure(object::id_from_address(@0x1));
    assert_eq!(up, 0);
    assert_eq!(down, 0);

    destroy(vault);
}

#[test]
fun deposit_increases_balance() {
    let ctx = &mut tx_context::dummy();
    let mut vault = vault::new<USDC>(ctx);

    vault.deposit(coin::mint_for_testing<USDC>(usdc!(1_000), ctx));
    assert_eq!(vault.balance(), usdc!(1_000));

    vault.deposit(coin::mint_for_testing<USDC>(usdc!(500), ctx));
    assert_eq!(vault.balance(), usdc!(1_500));

    destroy(vault);
}

#[test]
fun withdraw_decreases_balance() {
    let ctx = &mut tx_context::dummy();
    let mut vault = vault::new<USDC>(ctx);

    vault.deposit(coin::mint_for_testing<USDC>(usdc!(1_000), ctx));
    let withdrawn = vault.withdraw(usdc!(400));
    assert_eq!(vault.balance(), usdc!(600));

    destroy(withdrawn);
    destroy(vault);
}

#[test]
fun mint_up_updates_exposure() {
    let ctx = &mut tx_context::dummy();
    let mut vault = vault::new<USDC>(ctx);
    let oracle_1 = object::id_from_address(@0x1);

    // Seed vault with $10,000
    vault.deposit(coin::mint_for_testing<USDC>(usdc!(10_000), ctx));

    // Mint 100 UP contracts ($100 notional) with $60 payment
    let qty = contracts!(100);
    let payment = usdc!(60);
    vault.execute_mint(oracle_1, true, qty, coin::mint_for_testing<USDC>(payment, ctx));

    assert_eq!(vault.balance(), usdc!(10_000) + payment);
    assert_eq!(vault.total_up_short(), qty);
    assert_eq!(vault.total_down_short(), 0);

    let (up, down) = vault.oracle_exposure(oracle_1);
    assert_eq!(up, qty);
    assert_eq!(down, 0);

    destroy(vault);
}

#[test]
fun mint_down_updates_exposure() {
    let ctx = &mut tx_context::dummy();
    let mut vault = vault::new<USDC>(ctx);
    let oracle_1 = object::id_from_address(@0x1);

    vault.deposit(coin::mint_for_testing<USDC>(usdc!(10_000), ctx));

    let qty = contracts!(100);
    let payment = usdc!(60);
    vault.execute_mint(oracle_1, false, qty, coin::mint_for_testing<USDC>(payment, ctx));

    assert_eq!(vault.balance(), usdc!(10_000) + payment);
    assert_eq!(vault.total_up_short(), 0);
    assert_eq!(vault.total_down_short(), qty);

    let (up, down) = vault.oracle_exposure(oracle_1);
    assert_eq!(up, 0);
    assert_eq!(down, qty);

    destroy(vault);
}

#[test]
fun mint_multiple_oracles_independent() {
    let ctx = &mut tx_context::dummy();
    let mut vault = vault::new<USDC>(ctx);
    let oracle_1 = object::id_from_address(@0x1);
    let oracle_2 = object::id_from_address(@0x2);

    vault.deposit(coin::mint_for_testing<USDC>(usdc!(10_000), ctx));

    let qty_up = contracts!(100);
    let qty_down = contracts!(200);
    vault.execute_mint(oracle_1, true, qty_up, coin::mint_for_testing<USDC>(usdc!(50), ctx));
    vault.execute_mint(oracle_2, false, qty_down, coin::mint_for_testing<USDC>(usdc!(80), ctx));

    assert_eq!(vault.total_up_short(), qty_up);
    assert_eq!(vault.total_down_short(), qty_down);

    let (up, down) = vault.oracle_exposure(oracle_1);
    assert_eq!(up, qty_up);
    assert_eq!(down, 0);

    let (up, down) = vault.oracle_exposure(oracle_2);
    assert_eq!(up, 0);
    assert_eq!(down, qty_down);

    destroy(vault);
}

#[test]
fun redeem_updates_exposure() {
    let ctx = &mut tx_context::dummy();
    let mut vault = vault::new<USDC>(ctx);
    let oracle_1 = object::id_from_address(@0x1);

    vault.deposit(coin::mint_for_testing<USDC>(usdc!(10_000), ctx));

    let mint_qty = contracts!(100);
    vault.execute_mint(oracle_1, true, mint_qty, coin::mint_for_testing<USDC>(usdc!(60), ctx));

    let redeem_qty = contracts!(40);
    let payout_amount = usdc!(30);
    let payout = vault.execute_redeem(oracle_1, true, redeem_qty, payout_amount);

    assert_eq!(vault.total_up_short(), mint_qty - redeem_qty);
    let (up, down) = vault.oracle_exposure(oracle_1);
    assert_eq!(up, mint_qty - redeem_qty);
    assert_eq!(down, 0);
    assert_eq!(payout.value(), payout_amount);

    destroy(payout);
    destroy(vault);
}

#[test, expected_failure(abort_code = vault::EInsufficientBalance)]
fun redeem_insufficient_balance_aborts() {
    let ctx = &mut tx_context::dummy();
    let mut vault = vault::new<USDC>(ctx);
    let oracle_1 = object::id_from_address(@0x1);

    vault.deposit(coin::mint_for_testing<USDC>(usdc!(50), ctx));
    vault.execute_mint(
        oracle_1,
        true,
        contracts!(100),
        coin::mint_for_testing<USDC>(usdc!(50), ctx),
    );

    // balance = $100, payout = $101 → should abort
    let _payout = vault.execute_redeem(oracle_1, true, contracts!(50), usdc!(101));

    abort // unreachable, differs from EInsufficientBalance
}

#[test, expected_failure]
fun withdraw_insufficient_balance_aborts() {
    let ctx = &mut tx_context::dummy();
    let mut vault = vault::new<USDC>(ctx);

    vault.deposit(coin::mint_for_testing<USDC>(usdc!(100), ctx));
    let _withdrawn = vault.withdraw(usdc!(101));

    abort
}

#[test, expected_failure]
fun redeem_more_than_minted_aborts() {
    let ctx = &mut tx_context::dummy();
    let mut vault = vault::new<USDC>(ctx);
    let oracle_1 = object::id_from_address(@0x1);

    vault.deposit(coin::mint_for_testing<USDC>(usdc!(10_000), ctx));
    vault.execute_mint(
        oracle_1,
        true,
        contracts!(50),
        coin::mint_for_testing<USDC>(usdc!(30), ctx),
    );

    // Redeem 100 contracts but only 50 were minted → arithmetic underflow
    let _payout = vault.execute_redeem(oracle_1, true, contracts!(100), usdc!(30));

    abort
}

#[test, expected_failure]
fun redeem_unknown_oracle_aborts() {
    let ctx = &mut tx_context::dummy();
    let mut vault = vault::new<USDC>(ctx);
    let oracle_1 = object::id_from_address(@0x1);
    let oracle_unknown = object::id_from_address(@0x99);

    vault.deposit(coin::mint_for_testing<USDC>(usdc!(10_000), ctx));
    vault.execute_mint(
        oracle_1,
        true,
        contracts!(100),
        coin::mint_for_testing<USDC>(usdc!(60), ctx),
    );

    // Redeem against an oracle that was never minted to → table key not found
    let _payout = vault.execute_redeem(oracle_unknown, true, contracts!(100), usdc!(60));

    abort
}

#[test]
fun assert_total_exposure_ok() {
    let ctx = &mut tx_context::dummy();
    let mut vault = vault::new<USDC>(ctx);
    let oracle_1 = object::id_from_address(@0x1);
    let oracle_2 = object::id_from_address(@0x2);

    // Deposit $10,000
    vault.deposit(coin::mint_for_testing<USDC>(usdc!(10_000), ctx));

    // Mint 4000 UP + 4000 DOWN contracts → liability = $8,000
    vault.execute_mint(oracle_1, true, contracts!(4_000), coin::mint_for_testing<USDC>(0, ctx));
    vault.execute_mint(oracle_2, false, contracts!(4_000), coin::mint_for_testing<USDC>(0, ctx));

    // liability = $8,000, balance = $10,000, 100% limit → 8000 <= 10000
    vault.assert_total_exposure(constants::float_scaling!());

    destroy(vault);
}

#[test, expected_failure(abort_code = vault::EExceedsMaxTotalExposure)]
fun assert_total_exposure_exceeded() {
    let ctx = &mut tx_context::dummy();
    let mut vault = vault::new<USDC>(ctx);
    let oracle_1 = object::id_from_address(@0x1);
    let oracle_2 = object::id_from_address(@0x2);

    // Deposit $10,000
    vault.deposit(coin::mint_for_testing<USDC>(usdc!(10_000), ctx));

    // Mint 6000 UP + 6000 DOWN contracts → liability = $12,000
    vault.execute_mint(oracle_1, true, contracts!(6_000), coin::mint_for_testing<USDC>(0, ctx));
    vault.execute_mint(oracle_2, false, contracts!(6_000), coin::mint_for_testing<USDC>(0, ctx));

    // liability = $12,000, balance = $10,000, 100% limit → 12000 > 10000
    vault.assert_total_exposure(constants::float_scaling!());

    abort // unreachable, differs from EExceedsMaxTotalExposure
}

#[test]
fun full_cycle_mint_redeem_all() {
    let ctx = &mut tx_context::dummy();
    let mut vault = vault::new<USDC>(ctx);
    let oracle_1 = object::id_from_address(@0x1);

    vault.deposit(coin::mint_for_testing<USDC>(usdc!(10_000), ctx));

    let qty = contracts!(100);
    let cost = usdc!(60);
    vault.execute_mint(oracle_1, true, qty, coin::mint_for_testing<USDC>(cost, ctx));

    let payout = vault.execute_redeem(oracle_1, true, qty, cost);

    assert_eq!(vault.total_up_short(), 0);
    assert_eq!(vault.total_down_short(), 0);
    assert_eq!(vault.max_liability(), 0);

    let (up, down) = vault.oracle_exposure(oracle_1);
    assert_eq!(up, 0);
    assert_eq!(down, 0);

    destroy(payout);
    destroy(vault);
}

// === Edge Cases ===

#[test]
fun mint_zero_quantity_is_noop() {
    let ctx = &mut tx_context::dummy();
    let mut vault = vault::new<USDC>(ctx);
    let oracle = object::id_from_address(@0x1);

    vault.deposit(coin::mint_for_testing<USDC>(usdc!(1_000), ctx));
    vault.execute_mint(oracle, true, 0, coin::mint_for_testing<USDC>(usdc!(10), ctx));

    // Payment accepted but no exposure added
    assert_eq!(vault.balance(), usdc!(1_010));
    assert_eq!(vault.total_up_short(), 0);
    assert_eq!(vault.max_liability(), 0);

    destroy(vault);
}

#[test]
fun redeem_zero_payout_closes_exposure_for_free() {
    let ctx = &mut tx_context::dummy();
    let mut vault = vault::new<USDC>(ctx);
    let oracle = object::id_from_address(@0x1);

    vault.deposit(coin::mint_for_testing<USDC>(usdc!(1_000), ctx));
    vault.execute_mint(oracle, true, contracts!(50), coin::mint_for_testing<USDC>(usdc!(30), ctx));

    // Redeem all 50 contracts for $0 payout — vault keeps everything
    let payout = vault.execute_redeem(oracle, true, contracts!(50), 0);
    assert_eq!(payout.value(), 0);
    assert_eq!(vault.total_up_short(), 0);
    assert_eq!(vault.balance(), usdc!(1_030));

    destroy(payout);
    destroy(vault);
}

#[test, expected_failure]
fun redeem_wrong_side_underflows() {
    let ctx = &mut tx_context::dummy();
    let mut vault = vault::new<USDC>(ctx);
    let oracle = object::id_from_address(@0x1);

    vault.deposit(coin::mint_for_testing<USDC>(usdc!(10_000), ctx));
    vault.execute_mint(oracle, true, contracts!(100), coin::mint_for_testing<USDC>(usdc!(60), ctx));

    // Minted UP but try to redeem DOWN → total_down_short underflow
    let _payout = vault.execute_redeem(oracle, false, contracts!(50), usdc!(30));

    abort
}

#[test]
fun multiple_mints_same_oracle_accumulate() {
    let ctx = &mut tx_context::dummy();
    let mut vault = vault::new<USDC>(ctx);
    let oracle = object::id_from_address(@0x1);

    vault.deposit(coin::mint_for_testing<USDC>(usdc!(10_000), ctx));

    // 3 sequential UP mints on same oracle
    vault.execute_mint(oracle, true, contracts!(100), coin::mint_for_testing<USDC>(usdc!(50), ctx));
    vault.execute_mint(oracle, true, contracts!(200), coin::mint_for_testing<USDC>(usdc!(90), ctx));
    vault.execute_mint(
        oracle,
        true,
        contracts!(300),
        coin::mint_for_testing<USDC>(usdc!(130), ctx),
    );

    assert_eq!(vault.total_up_short(), contracts!(600));
    let (up, down) = vault.oracle_exposure(oracle);
    assert_eq!(up, contracts!(600));
    assert_eq!(down, 0);

    destroy(vault);
}

#[test]
fun same_oracle_up_and_down() {
    let ctx = &mut tx_context::dummy();
    let mut vault = vault::new<USDC>(ctx);
    let oracle = object::id_from_address(@0x1);

    vault.deposit(coin::mint_for_testing<USDC>(usdc!(10_000), ctx));

    vault.execute_mint(oracle, true, contracts!(100), coin::mint_for_testing<USDC>(usdc!(60), ctx));
    vault.execute_mint(oracle, false, contracts!(70), coin::mint_for_testing<USDC>(usdc!(40), ctx));

    assert_eq!(vault.total_up_short(), contracts!(100));
    assert_eq!(vault.total_down_short(), contracts!(70));
    assert_eq!(vault.max_liability(), contracts!(170));

    let (up, down) = vault.oracle_exposure(oracle);
    assert_eq!(up, contracts!(100));
    assert_eq!(down, contracts!(70));

    destroy(vault);
}

#[test]
fun exposure_check_at_exact_boundary() {
    let ctx = &mut tx_context::dummy();
    let mut vault = vault::new<USDC>(ctx);
    let oracle = object::id_from_address(@0x1);

    // Deposit $100, mint $100 of contracts (liability == balance at 100%)
    vault.deposit(coin::mint_for_testing<USDC>(usdc!(100), ctx));
    vault.execute_mint(oracle, true, usdc!(100), coin::mint_for_testing<USDC>(0, ctx));

    // liability = 100, balance = 100, 100% limit → 100 <= mul(100, 1e9) = 100
    vault.assert_total_exposure(constants::float_scaling!());

    destroy(vault);
}

#[test, expected_failure(abort_code = vault::EExceedsMaxTotalExposure)]
fun exposure_check_one_unit_over() {
    let ctx = &mut tx_context::dummy();
    let mut vault = vault::new<USDC>(ctx);
    let oracle = object::id_from_address(@0x1);

    vault.deposit(coin::mint_for_testing<USDC>(usdc!(100), ctx));
    // liability = 100_000_001 > balance * 100% = 100_000_000
    vault.execute_mint(oracle, true, usdc!(100) + 1, coin::mint_for_testing<USDC>(0, ctx));

    vault.assert_total_exposure(constants::float_scaling!());

    abort
}

#[test]
fun exposure_check_half_limit() {
    let ctx = &mut tx_context::dummy();
    let mut vault = vault::new<USDC>(ctx);
    let oracle = object::id_from_address(@0x1);

    // $1000 balance, $400 liability, 50% limit
    vault.deposit(coin::mint_for_testing<USDC>(usdc!(1_000), ctx));
    vault.execute_mint(oracle, true, usdc!(400), coin::mint_for_testing<USDC>(0, ctx));

    let half = constants::float_scaling!() / 2; // 50%
    // liability 400 <= mul(1000, 0.5) = 500
    vault.assert_total_exposure(half);

    destroy(vault);
}

#[test, expected_failure(abort_code = vault::EExceedsMaxTotalExposure)]
fun exposure_check_half_limit_exceeded() {
    let ctx = &mut tx_context::dummy();
    let mut vault = vault::new<USDC>(ctx);
    let oracle = object::id_from_address(@0x1);

    // $1000 balance, $600 liability, 50% limit
    vault.deposit(coin::mint_for_testing<USDC>(usdc!(1_000), ctx));
    vault.execute_mint(oracle, true, usdc!(600), coin::mint_for_testing<USDC>(0, ctx));

    let half = constants::float_scaling!() / 2;
    // liability 600 > mul(1000, 0.5) = 500
    vault.assert_total_exposure(half);

    abort
}

#[test]
fun exposure_check_zero_balance_zero_liability() {
    let ctx = &mut tx_context::dummy();
    let vault = vault::new<USDC>(ctx);

    // Empty vault: liability 0 <= mul(0, pct) = 0
    vault.assert_total_exposure(constants::float_scaling!());

    destroy(vault);
}

#[test, expected_failure(abort_code = vault::EExceedsMaxTotalExposure)]
fun exposure_check_zero_pct_with_any_liability() {
    let ctx = &mut tx_context::dummy();
    let mut vault = vault::new<USDC>(ctx);
    let oracle = object::id_from_address(@0x1);

    vault.deposit(coin::mint_for_testing<USDC>(usdc!(10_000), ctx));
    vault.execute_mint(oracle, true, 1, coin::mint_for_testing<USDC>(0, ctx));

    // 0% limit: even 1 unit of liability fails
    vault.assert_total_exposure(0);

    abort
}

#[test]
fun withdraw_exact_full_balance() {
    let ctx = &mut tx_context::dummy();
    let mut vault = vault::new<USDC>(ctx);

    vault.deposit(coin::mint_for_testing<USDC>(usdc!(500), ctx));
    let withdrawn = vault.withdraw(usdc!(500));

    assert_eq!(vault.balance(), 0);
    assert_eq!(withdrawn.value(), usdc!(500));

    destroy(withdrawn);
    destroy(vault);
}

#[test]
fun deposit_zero_coin() {
    let ctx = &mut tx_context::dummy();
    let mut vault = vault::new<USDC>(ctx);

    vault.deposit(coin::mint_for_testing<USDC>(0, ctx));
    assert_eq!(vault.balance(), 0);

    destroy(vault);
}

#[test]
fun withdraw_zero() {
    let ctx = &mut tx_context::dummy();
    let mut vault = vault::new<USDC>(ctx);

    vault.deposit(coin::mint_for_testing<USDC>(usdc!(100), ctx));
    let withdrawn = vault.withdraw(0);

    assert_eq!(vault.balance(), usdc!(100));
    assert_eq!(withdrawn.value(), 0);

    destroy(withdrawn);
    destroy(vault);
}

#[test]
fun redeem_drains_vault_to_exactly_zero() {
    let ctx = &mut tx_context::dummy();
    let mut vault = vault::new<USDC>(ctx);
    let oracle = object::id_from_address(@0x1);

    vault.deposit(coin::mint_for_testing<USDC>(usdc!(100), ctx));
    vault.execute_mint(oracle, true, contracts!(100), coin::mint_for_testing<USDC>(0, ctx));

    // Payout the entire balance
    let payout = vault.execute_redeem(oracle, true, contracts!(100), usdc!(100));
    assert_eq!(vault.balance(), 0);
    assert_eq!(payout.value(), usdc!(100));

    destroy(payout);
    destroy(vault);
}

#[test, expected_failure(abort_code = vault::EInsufficientBalance)]
fun redeem_one_over_balance_aborts() {
    let ctx = &mut tx_context::dummy();
    let mut vault = vault::new<USDC>(ctx);
    let oracle = object::id_from_address(@0x1);

    vault.deposit(coin::mint_for_testing<USDC>(usdc!(100), ctx));
    vault.execute_mint(oracle, true, contracts!(200), coin::mint_for_testing<USDC>(0, ctx));

    // balance = 100, payout = 100 + 1 — exactly one unit over
    let _payout = vault.execute_redeem(oracle, true, contracts!(100), usdc!(100) + 1);

    abort
}

#[test]
fun partial_redeems_track_exposure_correctly() {
    let ctx = &mut tx_context::dummy();
    let mut vault = vault::new<USDC>(ctx);
    let oracle = object::id_from_address(@0x1);

    vault.deposit(coin::mint_for_testing<USDC>(usdc!(10_000), ctx));
    vault.execute_mint(
        oracle,
        false,
        contracts!(500),
        coin::mint_for_testing<USDC>(usdc!(250), ctx),
    );

    // Redeem in 3 chunks
    let p1 = vault.execute_redeem(oracle, false, contracts!(100), usdc!(40));
    let p2 = vault.execute_redeem(oracle, false, contracts!(150), usdc!(60));
    let p3 = vault.execute_redeem(oracle, false, contracts!(250), usdc!(100));

    assert_eq!(vault.total_down_short(), 0);
    let (up, down) = vault.oracle_exposure(oracle);
    assert_eq!(up, 0);
    assert_eq!(down, 0);

    destroy(p1);
    destroy(p2);
    destroy(p3);
    destroy(vault);
}

#[test]
fun max_liability_is_sum_of_both_sides() {
    let ctx = &mut tx_context::dummy();
    let mut vault = vault::new<USDC>(ctx);
    let oracle_a = object::id_from_address(@0xA);
    let oracle_b = object::id_from_address(@0xB);
    let oracle_c = object::id_from_address(@0xC);

    vault.deposit(coin::mint_for_testing<USDC>(usdc!(100_000), ctx));

    vault.execute_mint(oracle_a, true, contracts!(1_000), coin::mint_for_testing<USDC>(0, ctx));
    vault.execute_mint(oracle_b, false, contracts!(2_000), coin::mint_for_testing<USDC>(0, ctx));
    vault.execute_mint(oracle_c, true, contracts!(3_000), coin::mint_for_testing<USDC>(0, ctx));

    // max_liability = total_up + total_down = 4000 + 2000 = 6000
    assert_eq!(vault.total_up_short(), contracts!(4_000));
    assert_eq!(vault.total_down_short(), contracts!(2_000));
    assert_eq!(vault.max_liability(), contracts!(6_000));

    destroy(vault);
}

#[test, expected_failure]
fun large_mint_overflows_total_short() {
    let ctx = &mut tx_context::dummy();
    let mut vault = vault::new<USDC>(ctx);
    let oracle = object::id_from_address(@0x1);

    vault.deposit(coin::mint_for_testing<USDC>(usdc!(1), ctx));

    let half_max = 9_223_372_036_854_775_808; // 2^63
    vault.execute_mint(oracle, true, half_max, coin::mint_for_testing<USDC>(0, ctx));
    // Second mint overflows total_up_short
    vault.execute_mint(oracle, true, half_max, coin::mint_for_testing<USDC>(0, ctx));

    abort
}

#[test]
fun mint_and_redeem_across_many_oracles() {
    let ctx = &mut tx_context::dummy();
    let mut vault = vault::new<USDC>(ctx);

    vault.deposit(coin::mint_for_testing<USDC>(usdc!(100_000), ctx));

    // Mint across 5 oracles
    let oracle_1 = object::id_from_address(@0x1);
    let oracle_2 = object::id_from_address(@0x2);
    let oracle_3 = object::id_from_address(@0x3);
    let oracle_4 = object::id_from_address(@0x4);
    let oracle_5 = object::id_from_address(@0x5);

    vault.execute_mint(oracle_1, true, contracts!(100), coin::mint_for_testing<USDC>(0, ctx));
    vault.execute_mint(oracle_2, false, contracts!(200), coin::mint_for_testing<USDC>(0, ctx));
    vault.execute_mint(oracle_3, true, contracts!(300), coin::mint_for_testing<USDC>(0, ctx));
    vault.execute_mint(oracle_4, false, contracts!(400), coin::mint_for_testing<USDC>(0, ctx));
    vault.execute_mint(oracle_5, true, contracts!(500), coin::mint_for_testing<USDC>(0, ctx));

    assert_eq!(vault.total_up_short(), contracts!(900));
    assert_eq!(vault.total_down_short(), contracts!(600));

    // Redeem all from oracle_3 and oracle_4
    let p1 = vault.execute_redeem(oracle_3, true, contracts!(300), usdc!(100));
    let p2 = vault.execute_redeem(oracle_4, false, contracts!(400), usdc!(100));

    assert_eq!(vault.total_up_short(), contracts!(600));
    assert_eq!(vault.total_down_short(), contracts!(200));

    // Verify per-oracle isolation: oracle_1 untouched
    let (up, down) = vault.oracle_exposure(oracle_1);
    assert_eq!(up, contracts!(100));
    assert_eq!(down, 0);

    // oracle_3 fully redeemed
    let (up, down) = vault.oracle_exposure(oracle_3);
    assert_eq!(up, 0);
    assert_eq!(down, 0);

    destroy(p1);
    destroy(p2);
    destroy(vault);
}

#[test]
fun exposure_check_with_mint_payments_included() {
    let ctx = &mut tx_context::dummy();
    let mut vault = vault::new<USDC>(ctx);
    let oracle = object::id_from_address(@0x1);

    // No deposit — balance comes entirely from mint payment
    vault.execute_mint(
        oracle,
        true,
        usdc!(800),
        coin::mint_for_testing<USDC>(usdc!(1_000), ctx),
    );

    // 100% limit: 800 <= 1000
    vault.assert_total_exposure(constants::float_scaling!());

    // 80% limit: 800 <= mul(1000, 0.8) = 800 (exact boundary)
    vault.assert_total_exposure(constants::default_max_total_exposure_pct!());

    destroy(vault);
}

#[test, expected_failure(abort_code = vault::EExceedsMaxTotalExposure)]
fun exposure_check_payment_not_enough_for_default_limit() {
    let ctx = &mut tx_context::dummy();
    let mut vault = vault::new<USDC>(ctx);
    let oracle = object::id_from_address(@0x1);

    // balance = $1000 from payment, liability = $801
    vault.execute_mint(
        oracle,
        true,
        usdc!(801),
        coin::mint_for_testing<USDC>(usdc!(1_000), ctx),
    );

    // 80% limit: 801 > mul(1000, 0.8) = 800
    vault.assert_total_exposure(constants::default_max_total_exposure_pct!());

    abort
}
