// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module deepbook_predict::supply_manager_tests;

use deepbook_predict::supply_manager;
use std::unit_test::{assert_eq, destroy};

const ALICE: address = @0xA;
const BOB: address = @0xB;
const CAROL: address = @0xC;

// === Getter Tests ===

#[test]
fun total_shares_after_construction_is_zero() {
    let ctx = &mut tx_context::dummy();
    let sm = supply_manager::new(ctx);
    assert_eq!(sm.total_shares(), 0);
    destroy(sm);
}

#[test]
fun user_shares_unknown_user_is_zero() {
    let ctx = &mut tx_context::dummy();
    let sm = supply_manager::new(ctx);
    assert_eq!(sm.user_shares(ALICE), 0);
    destroy(sm);
}

#[test]
fun user_supply_amount_zero_total_shares_is_zero() {
    let ctx = &mut tx_context::dummy();
    let sm = supply_manager::new(ctx);
    assert_eq!(sm.user_supply_amount(0, ALICE), 0);
    destroy(sm);
}

// === supply() Tests ===

#[test]
fun first_deposit_one_to_one() {
    let ctx = &mut tx_context::dummy();
    let mut sm = supply_manager::new(ctx);

    let shares = sm.supply(1_000_000, 0, ALICE);
    // First deposit: shares = amount
    assert_eq!(shares, 1_000_000);
    assert_eq!(sm.total_shares(), 1_000_000);
    assert_eq!(sm.user_shares(ALICE), 1_000_000);

    destroy(sm);
}

#[test]
fun second_deposit_same_user_accumulates() {
    let ctx = &mut tx_context::dummy();
    let mut sm = supply_manager::new(ctx);

    sm.supply(1_000_000, 0, ALICE);
    // vault_value = 1_000_000 after first deposit
    // shares = mul(500_000, div(1_000_000, 1_000_000))
    //        = mul(500_000, 1_000_000_000)
    //        = 500_000 * 1_000_000_000 / 1_000_000_000 = 500_000
    let shares2 = sm.supply(500_000, 1_000_000, ALICE);
    assert_eq!(shares2, 500_000);
    assert_eq!(sm.total_shares(), 1_500_000);
    assert_eq!(sm.user_shares(ALICE), 1_500_000);

    destroy(sm);
}

#[test]
fun second_deposit_different_user() {
    let ctx = &mut tx_context::dummy();
    let mut sm = supply_manager::new(ctx);

    sm.supply(1_000_000, 0, ALICE);
    // vault_value = 1_000_000
    // shares = mul(500_000, div(1_000_000, 1_000_000))
    //        = mul(500_000, 1_000_000_000) = 500_000
    let shares2 = sm.supply(500_000, 1_000_000, BOB);
    assert_eq!(shares2, 500_000);
    assert_eq!(sm.total_shares(), 1_500_000);
    assert_eq!(sm.user_shares(ALICE), 1_000_000);
    assert_eq!(sm.user_shares(BOB), 500_000);

    destroy(sm);
}

#[test]
fun deposit_when_vault_gained_value() {
    let ctx = &mut tx_context::dummy();
    let mut sm = supply_manager::new(ctx);

    // Alice deposits 1_000_000 (gets 1_000_000 shares)
    sm.supply(1_000_000, 0, ALICE);

    // Vault gained: vault_value = 2_000_000
    // Bob deposits 1_000_000
    // shares = mul(1_000_000, div(1_000_000, 2_000_000))
    //        = mul(1_000_000, 500_000_000)
    //        = 1_000_000 * 500_000_000 / 1_000_000_000 = 500_000
    let shares = sm.supply(1_000_000, 2_000_000, BOB);
    assert_eq!(shares, 500_000);
    assert_eq!(sm.total_shares(), 1_500_000);
    assert_eq!(sm.user_shares(BOB), 500_000);

    destroy(sm);
}

#[test]
fun deposit_when_vault_lost_value() {
    let ctx = &mut tx_context::dummy();
    let mut sm = supply_manager::new(ctx);

    // Alice deposits 1_000_000 (gets 1_000_000 shares)
    sm.supply(1_000_000, 0, ALICE);

    // Vault lost value: vault_value = 500_000
    // Bob deposits 1_000_000
    // shares = mul(1_000_000, div(1_000_000, 500_000))
    //        = mul(1_000_000, 2_000_000_000)
    //        = 1_000_000 * 2_000_000_000 / 1_000_000_000 = 2_000_000
    let shares = sm.supply(1_000_000, 500_000, BOB);
    assert_eq!(shares, 2_000_000);
    assert_eq!(sm.total_shares(), 3_000_000);
    assert_eq!(sm.user_shares(BOB), 2_000_000);

    destroy(sm);
}

#[test, expected_failure(abort_code = supply_manager::EZeroAmount)]
fun supply_zero_amount_aborts() {
    let ctx = &mut tx_context::dummy();
    let mut sm = supply_manager::new(ctx);
    sm.supply(0, 0, ALICE);

    abort
}

#[test, expected_failure(abort_code = supply_manager::EZeroVaultValue)]
fun supply_zero_vault_value_with_existing_shares_aborts() {
    let ctx = &mut tx_context::dummy();
    let mut sm = supply_manager::new(ctx);
    sm.supply(1_000_000, 0, ALICE);
    // total_shares > 0 but vault_value = 0
    sm.supply(500_000, 0, BOB);

    abort
}

// === withdraw() Tests ===

#[test]
fun withdraw_partial() {
    let ctx = &mut tx_context::dummy();
    let mut sm = supply_manager::new(ctx);

    sm.supply(1_000_000, 0, ALICE);
    // vault_value = 1_000_000, withdraw 500_000
    // shares_burned = mul(500_000, div(1_000_000, 1_000_000))
    //               = mul(500_000, 1_000_000_000) = 500_000
    let burned = sm.withdraw(500_000, 1_000_000, ALICE);
    assert_eq!(burned, 500_000);
    assert_eq!(sm.total_shares(), 500_000);
    assert_eq!(sm.user_shares(ALICE), 500_000);

    destroy(sm);
}

#[test]
fun withdraw_exact_deposited_no_pnl() {
    let ctx = &mut tx_context::dummy();
    let mut sm = supply_manager::new(ctx);

    sm.supply(1_000_000, 0, ALICE);
    // Withdraw entire deposit at same vault_value
    // shares_burned = mul(1_000_000, div(1_000_000, 1_000_000))
    //               = mul(1_000_000, 1_000_000_000) = 1_000_000
    let burned = sm.withdraw(1_000_000, 1_000_000, ALICE);
    assert_eq!(burned, 1_000_000);
    assert_eq!(sm.total_shares(), 0);
    assert_eq!(sm.user_shares(ALICE), 0);

    destroy(sm);
}

#[test]
fun withdraw_when_vault_gained() {
    let ctx = &mut tx_context::dummy();
    let mut sm = supply_manager::new(ctx);

    sm.supply(1_000_000, 0, ALICE);
    // vault_value doubled to 2_000_000
    // Withdraw 1_000_000 of value
    // shares_burned = mul(1_000_000, div(1_000_000, 2_000_000))
    //               = mul(1_000_000, 500_000_000) = 500_000
    let burned = sm.withdraw(1_000_000, 2_000_000, ALICE);
    assert_eq!(burned, 500_000);
    assert_eq!(sm.total_shares(), 500_000);
    assert_eq!(sm.user_shares(ALICE), 500_000);

    destroy(sm);
}

#[test]
fun withdraw_when_vault_lost() {
    let ctx = &mut tx_context::dummy();
    let mut sm = supply_manager::new(ctx);

    sm.supply(2_000_000, 0, ALICE);
    // vault_value halved to 1_000_000
    // Withdraw 500_000 of value
    // shares_burned = mul(500_000, div(2_000_000, 1_000_000))
    //               = mul(500_000, 2_000_000_000) = 1_000_000
    let burned = sm.withdraw(500_000, 1_000_000, ALICE);
    assert_eq!(burned, 1_000_000);
    assert_eq!(sm.total_shares(), 1_000_000);
    assert_eq!(sm.user_shares(ALICE), 1_000_000);

    destroy(sm);
}

#[test, expected_failure(abort_code = supply_manager::EZeroAmount)]
fun withdraw_zero_amount_aborts() {
    let ctx = &mut tx_context::dummy();
    let mut sm = supply_manager::new(ctx);
    sm.supply(1_000_000, 0, ALICE);
    sm.withdraw(0, 1_000_000, ALICE);

    abort
}

#[test, expected_failure(abort_code = supply_manager::EZeroVaultValue)]
fun withdraw_zero_vault_value_aborts() {
    let ctx = &mut tx_context::dummy();
    let mut sm = supply_manager::new(ctx);
    sm.supply(1_000_000, 0, ALICE);
    sm.withdraw(500_000, 0, ALICE);

    abort
}

#[test, expected_failure(abort_code = supply_manager::EInsufficientShares)]
fun withdraw_insufficient_shares_aborts() {
    let ctx = &mut tx_context::dummy();
    let mut sm = supply_manager::new(ctx);
    sm.supply(1_000_000, 0, ALICE);
    // Try to withdraw more value than Alice has shares for
    // shares_burned = mul(2_000_000, div(1_000_000, 1_000_000))
    //               = mul(2_000_000, 1_000_000_000) = 2_000_000 > 1_000_000
    sm.withdraw(2_000_000, 1_000_000, ALICE);

    abort
}

// === withdraw_all() Tests ===

#[test]
fun withdraw_all_single_user_gets_full_vault() {
    let ctx = &mut tx_context::dummy();
    let mut sm = supply_manager::new(ctx);

    sm.supply(1_000_000, 0, ALICE);
    // Alice is sole user, total_shares == user_shares → amount = vault_value
    let (amount, shares) = sm.withdraw_all(1_500_000, ALICE);
    assert_eq!(amount, 1_500_000);
    assert_eq!(shares, 1_000_000);
    assert_eq!(sm.total_shares(), 0);
    assert_eq!(sm.user_shares(ALICE), 0);

    destroy(sm);
}

#[test]
fun withdraw_all_user_with_partial_shares() {
    let ctx = &mut tx_context::dummy();
    let mut sm = supply_manager::new(ctx);

    sm.supply(1_000_000, 0, ALICE);
    // vault_value = 1_000_000, Bob deposits 1_000_000
    // Bob shares = mul(1_000_000, div(1_000_000, 1_000_000)) = 1_000_000
    sm.supply(1_000_000, 1_000_000, BOB);
    // total_shares = 2_000_000, Alice has 1_000_000, Bob has 1_000_000

    // vault_value grew to 3_000_000. Alice withdraws all.
    // Alice shares (1_000_000) != total_shares (2_000_000)
    // amount = mul(1_000_000, div(3_000_000, 2_000_000))
    //        = mul(1_000_000, 1_500_000_000)
    //        = 1_000_000 * 1_500_000_000 / 1_000_000_000 = 1_500_000
    let (amount, shares) = sm.withdraw_all(3_000_000, ALICE);
    assert_eq!(amount, 1_500_000);
    assert_eq!(shares, 1_000_000);
    assert_eq!(sm.total_shares(), 1_000_000);
    assert_eq!(sm.user_shares(ALICE), 0);
    assert_eq!(sm.user_shares(BOB), 1_000_000);

    destroy(sm);
}

#[test, expected_failure(abort_code = supply_manager::EZeroAmount)]
fun withdraw_all_zero_shares_aborts() {
    let ctx = &mut tx_context::dummy();
    let mut sm = supply_manager::new(ctx);
    sm.withdraw_all(1_000_000, ALICE);

    abort
}

// === user_supply_amount() Tests ===

#[test]
fun user_supply_amount_exact_calculation() {
    let ctx = &mut tx_context::dummy();
    let mut sm = supply_manager::new(ctx);

    sm.supply(1_000_000, 0, ALICE);
    sm.supply(1_000_000, 1_000_000, BOB);
    // total_shares = 2_000_000, each has 1_000_000
    // vault_value = 3_000_000
    // amount = mul(1_000_000, div(3_000_000, 2_000_000))
    //        = mul(1_000_000, 1_500_000_000) = 1_500_000
    assert_eq!(sm.user_supply_amount(3_000_000, ALICE), 1_500_000);
    assert_eq!(sm.user_supply_amount(3_000_000, BOB), 1_500_000);

    destroy(sm);
}

// === Rounding / Truncation Tests ===

#[test]
fun supply_rounding_truncation() {
    let ctx = &mut tx_context::dummy();
    let mut sm = supply_manager::new(ctx);

    sm.supply(1_000_000, 0, ALICE);

    // vault_value = 3_000_000, total_shares = 1_000_000, Bob deposits 1_000_001
    // div(1_000_000, 3_000_000) = 333_333_333
    // mul(1_000_001, 333_333_333) = 333_333_666_333_333 / 1_000_000_000 = 333_333 (truncated)
    let shares = sm.supply(1_000_001, 3_000_000, BOB);
    assert_eq!(shares, 333_333);

    destroy(sm);
}

#[test]
fun withdraw_rounding_truncation() {
    let ctx = &mut tx_context::dummy();
    let mut sm = supply_manager::new(ctx);

    sm.supply(3_000_000, 0, ALICE);
    // total_shares = 3_000_000, vault_value = 3_000_000
    // Withdraw 1_000_001
    // div(3_000_000, 3_000_000) = 1_000_000_000
    // mul(1_000_001, 1_000_000_000) = 1_000_001 * 1_000_000_000 / 1_000_000_000 = 1_000_001
    let burned = sm.withdraw(1_000_001, 3_000_000, ALICE);
    assert_eq!(burned, 1_000_001);

    // Now total_shares = 1_999_999, vault_value changed, say 2_000_000
    // Withdraw 1_000_001 from remaining
    // mul_div_round_up(1_000_001, 1_999_999, 2_000_000)
    //   = ceil(1_000_001 * 1_999_999 / 2_000_000) = ceil(1_000_000.4999995) = 1_000_001
    let burned2 = sm.withdraw(1_000_001, 2_000_000, ALICE);
    assert_eq!(burned2, 1_000_001);

    destroy(sm);
}

// === Interleaved Multi-User Tests ===

#[test]
fun multiple_users_supply_withdraw_interleaved() {
    let ctx = &mut tx_context::dummy();
    let mut sm = supply_manager::new(ctx);

    // Alice deposits 1_000_000 (vault_value=0)
    let s1 = sm.supply(1_000_000, 0, ALICE);
    assert_eq!(s1, 1_000_000);
    // total_shares=1_000_000

    // Bob deposits 2_000_000 (vault_value=1_000_000)
    // div(1_000_000, 1_000_000) = 1_000_000_000
    // mul(2_000_000, 1_000_000_000) = 2_000_000
    let s2 = sm.supply(2_000_000, 1_000_000, BOB);
    assert_eq!(s2, 2_000_000);
    // total_shares=3_000_000, Alice=1_000_000, Bob=2_000_000

    // Vault grew to 6_000_000. Alice withdraws 1_000_000 value.
    // div(3_000_000, 6_000_000) = 500_000_000
    // mul(1_000_000, 500_000_000) = 500_000
    let burned = sm.withdraw(1_000_000, 6_000_000, ALICE);
    assert_eq!(burned, 500_000);
    // total_shares=2_500_000, Alice=500_000, Bob=2_000_000

    // Carol deposits 1_000_000 (vault_value=5_000_000)
    // div(2_500_000, 5_000_000) = 500_000_000
    // mul(1_000_000, 500_000_000) = 500_000
    let s3 = sm.supply(1_000_000, 5_000_000, CAROL);
    assert_eq!(s3, 500_000);
    // total_shares=3_000_000, Alice=500_000, Bob=2_000_000, Carol=500_000

    assert_eq!(sm.total_shares(), 3_000_000);
    assert_eq!(sm.user_shares(ALICE), 500_000);
    assert_eq!(sm.user_shares(BOB), 2_000_000);
    assert_eq!(sm.user_shares(CAROL), 500_000);

    // Check user_supply_amount at vault_value=6_000_000
    // Alice: mul(500_000, div(6_000_000, 3_000_000))
    //      = mul(500_000, 2_000_000_000) = 1_000_000
    assert_eq!(sm.user_supply_amount(6_000_000, ALICE), 1_000_000);
    // Bob: mul(2_000_000, div(6_000_000, 3_000_000))
    //    = mul(2_000_000, 2_000_000_000) = 4_000_000
    assert_eq!(sm.user_supply_amount(6_000_000, BOB), 4_000_000);
    // Carol: mul(500_000, div(6_000_000, 3_000_000))
    //      = mul(500_000, 2_000_000_000) = 1_000_000
    assert_eq!(sm.user_supply_amount(6_000_000, CAROL), 1_000_000);

    destroy(sm);
}

#[test]
fun bob_withdraw_all_after_vault_gain() {
    let ctx = &mut tx_context::dummy();
    let mut sm = supply_manager::new(ctx);

    sm.supply(1_000_000, 0, ALICE);
    sm.supply(1_000_000, 1_000_000, BOB);
    // total_shares=2_000_000, Alice=1_000_000, Bob=1_000_000

    // Vault grew to 4_000_000. Bob withdraw_all.
    // Bob shares (1_000_000) != total_shares (2_000_000)
    // amount = mul(1_000_000, div(4_000_000, 2_000_000))
    //        = mul(1_000_000, 2_000_000_000) = 2_000_000
    let (amount, shares) = sm.withdraw_all(4_000_000, BOB);
    assert_eq!(amount, 2_000_000);
    assert_eq!(shares, 1_000_000);
    assert_eq!(sm.total_shares(), 1_000_000);

    // Now Alice is sole user, withdraw_all
    let (amount2, shares2) = sm.withdraw_all(2_000_000, ALICE);
    assert_eq!(amount2, 2_000_000);
    assert_eq!(shares2, 1_000_000);
    assert_eq!(sm.total_shares(), 0);

    destroy(sm);
}

#[test]
fun withdraw_all_with_zero_vault_value_sole_user() {
    let ctx = &mut tx_context::dummy();
    let mut sm = supply_manager::new(ctx);

    sm.supply(1_000_000, 0, ALICE);
    // Sole user, vault lost everything: vault_value = 0
    // total_shares == shares → amount = vault_value = 0
    let (amount, shares) = sm.withdraw_all(0, ALICE);
    assert_eq!(amount, 0);
    assert_eq!(shares, 1_000_000);

    destroy(sm);
}

#[test, expected_failure(abort_code = supply_manager::EZeroVaultValue)]
fun withdraw_all_zero_vault_value_partial_user_aborts() {
    let ctx = &mut tx_context::dummy();
    let mut sm = supply_manager::new(ctx);

    sm.supply(1_000_000, 0, ALICE);
    sm.supply(1_000_000, 1_000_000, BOB);
    // Alice is not sole user, vault_value = 0 → aborts
    sm.withdraw_all(0, ALICE);

    abort
}

#[test]
fun rounding_asymmetry_supply_vs_withdraw() {
    let ctx = &mut tx_context::dummy();
    let mut sm = supply_manager::new(ctx);

    sm.supply(1_000_000, 0, ALICE);

    // Vault at 3_000_000 (gained 2x). Bob deposits 1_000_000.
    // div(1_000_000, 3_000_000) = 333_333_333
    // mul(1_000_000, 333_333_333) = 333_333 (truncated)
    let shares = sm.supply(1_000_000, 3_000_000, BOB);
    assert_eq!(shares, 333_333);

    // Bob withdraws all at vault_value = 4_000_000
    // total_shares = 1_333_333, Bob has 333_333
    // div(4_000_000, 1_333_333) = 4_000_000_000_000_000 / 1_333_333 = 3_000_000_750
    // mul(333_333, 3_000_000_750) = 333_333 * 3_000_000_750 / 1_000_000_000 = 999_999
    // Due to truncation, Bob gets back 999_999 instead of 1_000_000
    let (amount, burned) = sm.withdraw_all(4_000_000, BOB);
    assert_eq!(burned, 333_333);
    assert_eq!(amount, 999_999);

    destroy(sm);
}

// ============================================================
// Zero-share attacks (adversarial rounding tests)
// ============================================================

#[test, expected_failure(abort_code = supply_manager::EZeroSharesMinted)]
// Depositing a tiny amount into a large vault would yield 0 shares.
// The contract must reject this to prevent donation of funds to existing LPs.
fun supply_rejects_zero_share_mint() {
    let ctx = &mut tx_context::dummy();
    let mut sm = supply_manager::new(ctx);

    sm.supply(1_000_000, 0, ALICE);

    // 1 unit into a 1B vault → mul(1, div(1M, 1B)) = mul(1, 1M) = 0 shares
    sm.supply(1, 1_000_000_000, BOB);

    abort
}

#[test, expected_failure(abort_code = supply_manager::EZeroSharesMinted)]
// Classic ERC-4626 inflation attack: first depositor deposits 1 unit,
// donates to inflate share price, next depositor gets 0 shares.
// The contract must reject the second deposit.
fun inflation_attack_blocked() {
    let ctx = &mut tx_context::dummy();
    let mut sm = supply_manager::new(ctx);

    sm.supply(1, 0, ALICE);

    // Attacker donates to inflate vault to 1_000_001
    // Bob deposits 1_000_000 → div(1, 1_000_001) = 999, mul(1M, 999) = 0
    sm.supply(1_000_000, 1_000_001, BOB);

    abort
}

#[test]
// The minimum deposit that yields 1 share must succeed.
fun supply_accepts_minimum_for_one_share() {
    let ctx = &mut tx_context::dummy();
    let mut sm = supply_manager::new(ctx);

    sm.supply(1_000_000, 0, ALICE);

    // 4 units → mul(4, 333_333_333) = 1_333_333_332/1e9 = 1 share
    let shares = sm.supply(4, 3_000_000, BOB);
    assert_eq!(shares, 1);

    destroy(sm);
}

#[test]
// With round-up, even a tiny withdrawal burns at least 1 share.
fun withdraw_tiny_amount_burns_one_share() {
    let ctx = &mut tx_context::dummy();
    let mut sm = supply_manager::new(ctx);

    sm.supply(1_000_000, 0, ALICE);

    // 1 unit from 1B vault: ceil(1 * 1_000_000 / 1_000_000_000) = 1
    let burned = sm.withdraw(1, 1_000_000_000, ALICE);
    assert_eq!(burned, 1);

    destroy(sm);
}

#[test]
// With round-up, 4 units from 3M vault burns 2 shares.
// ceil(4 * 1_000_000 / 3_000_000) = ceil(1.333) = 2
fun withdraw_small_amount_rounds_up() {
    let ctx = &mut tx_context::dummy();
    let mut sm = supply_manager::new(ctx);

    sm.supply(1_000_000, 0, ALICE);

    let burned = sm.withdraw(4, 3_000_000, ALICE);
    assert_eq!(burned, 2);

    destroy(sm);
}
