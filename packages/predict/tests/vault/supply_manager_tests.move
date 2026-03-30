// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module deepbook_predict::supply_manager_tests;

use deepbook_predict::{plp::PLP, supply_manager};
use std::unit_test::{assert_eq, destroy};
use sui::coin;

fun setup(ctx: &mut TxContext): supply_manager::SupplyManager {
    let treasury_cap = coin::create_treasury_cap_for_testing<PLP>(ctx);
    supply_manager::new(treasury_cap)
}

// === Getter Tests ===

#[test]
fun total_shares_after_construction_is_zero() {
    let ctx = &mut tx_context::dummy();
    let sm = setup(ctx);
    assert_eq!(sm.total_shares(), 0);
    destroy(sm);
}

// === shares_to_amount() Tests ===

#[test]
fun shares_to_amount_zero_total_shares_is_zero() {
    let ctx = &mut tx_context::dummy();
    let sm = setup(ctx);
    assert_eq!(sm.shares_to_amount(0, 1_000_000), 0);
    destroy(sm);
}

#[test]
fun shares_to_amount_exact_calculation() {
    let ctx = &mut tx_context::dummy();
    let mut sm = setup(ctx);

    let lp1 = sm.supply(1_000_000, 0, ctx);
    let lp2 = sm.supply(1_000_000, 1_000_000, ctx);
    // total_shares = 2_000_000, each coin has 1_000_000
    // vault_value = 3_000_000
    // amount = 1_000_000 * 3_000_000 / 2_000_000 = 1_500_000
    assert_eq!(sm.shares_to_amount(lp1.value(), 3_000_000), 1_500_000);
    assert_eq!(sm.shares_to_amount(lp2.value(), 3_000_000), 1_500_000);

    destroy(lp1);
    destroy(lp2);
    destroy(sm);
}

// === supply() Tests ===

#[test]
fun first_deposit_one_to_one() {
    let ctx = &mut tx_context::dummy();
    let mut sm = setup(ctx);

    let lp = sm.supply(1_000_000, 0, ctx);
    // First deposit: shares = amount
    assert_eq!(lp.value(), 1_000_000);
    assert_eq!(sm.total_shares(), 1_000_000);

    destroy(lp);
    destroy(sm);
}

#[test]
fun second_deposit_proportional() {
    let ctx = &mut tx_context::dummy();
    let mut sm = setup(ctx);

    let lp1 = sm.supply(1_000_000, 0, ctx);
    // vault_value = 1_000_000 after first deposit
    // shares = 500_000 * 1_000_000 / 1_000_000 = 500_000
    let lp2 = sm.supply(500_000, 1_000_000, ctx);
    assert_eq!(lp2.value(), 500_000);
    assert_eq!(sm.total_shares(), 1_500_000);

    destroy(lp1);
    destroy(lp2);
    destroy(sm);
}

#[test]
fun deposit_when_vault_gained_value() {
    let ctx = &mut tx_context::dummy();
    let mut sm = setup(ctx);

    let lp1 = sm.supply(1_000_000, 0, ctx);

    // Vault gained: vault_value = 2_000_000
    // shares = 1_000_000 * 1_000_000 / 2_000_000 = 500_000
    let lp2 = sm.supply(1_000_000, 2_000_000, ctx);
    assert_eq!(lp2.value(), 500_000);
    assert_eq!(sm.total_shares(), 1_500_000);

    destroy(lp1);
    destroy(lp2);
    destroy(sm);
}

#[test]
fun deposit_when_vault_lost_value() {
    let ctx = &mut tx_context::dummy();
    let mut sm = setup(ctx);

    let lp1 = sm.supply(1_000_000, 0, ctx);

    // Vault lost value: vault_value = 500_000
    // shares = 1_000_000 * 1_000_000 / 500_000 = 2_000_000
    let lp2 = sm.supply(1_000_000, 500_000, ctx);
    assert_eq!(lp2.value(), 2_000_000);
    assert_eq!(sm.total_shares(), 3_000_000);

    destroy(lp1);
    destroy(lp2);
    destroy(sm);
}

#[test, expected_failure(abort_code = supply_manager::EZeroAmount)]
fun supply_zero_amount_aborts() {
    let ctx = &mut tx_context::dummy();
    let mut sm = setup(ctx);
    let _lp = sm.supply(0, 0, ctx);

    abort
}

#[test, expected_failure(abort_code = supply_manager::EZeroVaultValue)]
fun supply_zero_vault_value_with_existing_shares_aborts() {
    let ctx = &mut tx_context::dummy();
    let mut sm = setup(ctx);
    let _lp1 = sm.supply(1_000_000, 0, ctx);
    // total_shares > 0 but vault_value = 0
    let _lp2 = sm.supply(500_000, 0, ctx);

    abort
}

// === withdraw() Tests ===

#[test]
fun withdraw_partial() {
    let ctx = &mut tx_context::dummy();
    let mut sm = setup(ctx);

    let mut lp = sm.supply(1_000_000, 0, ctx);
    // vault_value = 1_000_000, withdraw 500_000 shares
    // amount = 500_000 * 1_000_000 / 1_000_000 = 500_000
    let withdraw_lp = lp.split(500_000, ctx);
    let amount = sm.withdraw(withdraw_lp, 1_000_000);
    assert_eq!(amount, 500_000);
    assert_eq!(sm.total_shares(), 500_000);

    destroy(lp);
    destroy(sm);
}

#[test]
fun withdraw_all_shares() {
    let ctx = &mut tx_context::dummy();
    let mut sm = setup(ctx);

    let lp = sm.supply(1_000_000, 0, ctx);
    // sole LP → amount = vault_value = 1_000_000
    let amount = sm.withdraw(lp, 1_000_000);
    assert_eq!(amount, 1_000_000);
    assert_eq!(sm.total_shares(), 0);

    destroy(sm);
}

#[test]
fun withdraw_when_vault_gained() {
    let ctx = &mut tx_context::dummy();
    let mut sm = setup(ctx);

    let mut lp = sm.supply(1_000_000, 0, ctx);
    // vault_value doubled to 2_000_000
    // Withdraw 500_000 shares
    // amount = 500_000 * 2_000_000 / 1_000_000 = 1_000_000
    let withdraw_lp = lp.split(500_000, ctx);
    let amount = sm.withdraw(withdraw_lp, 2_000_000);
    assert_eq!(amount, 1_000_000);
    assert_eq!(sm.total_shares(), 500_000);

    destroy(lp);
    destroy(sm);
}

#[test]
fun withdraw_when_vault_lost() {
    let ctx = &mut tx_context::dummy();
    let mut sm = setup(ctx);

    let mut lp = sm.supply(2_000_000, 0, ctx);
    // vault_value halved to 1_000_000
    // Withdraw 1_000_000 shares
    // amount = 1_000_000 * 1_000_000 / 2_000_000 = 500_000
    let withdraw_lp = lp.split(1_000_000, ctx);
    let amount = sm.withdraw(withdraw_lp, 1_000_000);
    assert_eq!(amount, 500_000);
    assert_eq!(sm.total_shares(), 1_000_000);

    destroy(lp);
    destroy(sm);
}

#[test, expected_failure(abort_code = supply_manager::EZeroAmount)]
fun withdraw_zero_shares_aborts() {
    let ctx = &mut tx_context::dummy();
    let mut sm = setup(ctx);
    let _lp = sm.supply(1_000_000, 0, ctx);
    let zero_coin = coin::zero<PLP>(ctx);
    sm.withdraw(zero_coin, 1_000_000);

    abort
}

// === Sole-LP special case ===

#[test]
fun withdraw_sole_lp_gets_full_vault_value() {
    let ctx = &mut tx_context::dummy();
    let mut sm = setup(ctx);

    let lp = sm.supply(1_000_000, 0, ctx);
    // sole LP, vault grew to 1_500_000
    // sole LP → amount = vault_value = 1_500_000
    let amount = sm.withdraw(lp, 1_500_000);
    assert_eq!(amount, 1_500_000);
    assert_eq!(sm.total_shares(), 0);

    destroy(sm);
}

#[test]
fun withdraw_sole_lp_zero_vault_value() {
    let ctx = &mut tx_context::dummy();
    let mut sm = setup(ctx);

    let lp = sm.supply(1_000_000, 0, ctx);
    // sole LP → amount = vault_value = 0
    let amount = sm.withdraw(lp, 0);
    assert_eq!(amount, 0);
    assert_eq!(sm.total_shares(), 0);

    destroy(sm);
}

#[test]
fun withdraw_non_sole_lp_proportional() {
    let ctx = &mut tx_context::dummy();
    let mut sm = setup(ctx);

    let lp1 = sm.supply(1_000_000, 0, ctx);
    let lp2 = sm.supply(1_000_000, 1_000_000, ctx);
    // total_shares = 2_000_000

    // vault_value grew to 3_000_000. Withdraw lp1 (1_000_000 shares).
    // Not sole LP: amount = 1_000_000 * 3_000_000 / 2_000_000 = 1_500_000
    let amount = sm.withdraw(lp1, 3_000_000);
    assert_eq!(amount, 1_500_000);
    assert_eq!(sm.total_shares(), 1_000_000);

    destroy(lp2);
    destroy(sm);
}

// === Total supply tracking ===

#[test]
fun total_supply_increases_on_supply() {
    let ctx = &mut tx_context::dummy();
    let mut sm = setup(ctx);

    assert_eq!(sm.total_shares(), 0);

    let lp1 = sm.supply(1_000_000, 0, ctx);
    assert_eq!(sm.total_shares(), 1_000_000);

    let lp2 = sm.supply(500_000, 1_000_000, ctx);
    assert_eq!(sm.total_shares(), 1_500_000);

    destroy(lp1);
    destroy(lp2);
    destroy(sm);
}

#[test]
fun total_supply_decreases_on_withdraw() {
    let ctx = &mut tx_context::dummy();
    let mut sm = setup(ctx);

    let mut lp = sm.supply(1_000_000, 0, ctx);
    assert_eq!(sm.total_shares(), 1_000_000);

    let w1 = lp.split(400_000, ctx);
    sm.withdraw(w1, 1_000_000);
    assert_eq!(sm.total_shares(), 600_000);

    sm.withdraw(lp, 600_000);
    assert_eq!(sm.total_shares(), 0);

    destroy(sm);
}

// === Rounding / Truncation Tests ===

#[test]
fun supply_rounding_truncation() {
    let ctx = &mut tx_context::dummy();
    let mut sm = setup(ctx);

    let lp1 = sm.supply(1_000_000, 0, ctx);

    // vault_value = 3_000_000, total_shares = 1_000_000
    // shares = 1_000_001 * 1_000_000 / 3_000_000 = 333_333 (truncated)
    let lp2 = sm.supply(1_000_001, 3_000_000, ctx);
    assert_eq!(lp2.value(), 333_333);

    destroy(lp1);
    destroy(lp2);
    destroy(sm);
}

#[test]
fun withdraw_rounding_truncation() {
    let ctx = &mut tx_context::dummy();
    let mut sm = setup(ctx);

    let mut lp = sm.supply(3_000_000, 0, ctx);
    // total_shares = 3_000_000, vault_value = 3_000_000
    // Withdraw 1_000_001 shares
    // amount = 1_000_001 * 3_000_000 / 3_000_000 = 1_000_001
    let w1 = lp.split(1_000_001, ctx);
    let amount = sm.withdraw(w1, 3_000_000);
    assert_eq!(amount, 1_000_001);

    // Now total_shares = 1_999_999, vault_value changed to 2_000_000
    // Withdraw 1_000_001 shares
    // amount = 1_000_001 * 2_000_000 / 1_999_999 = 1_000_001 (truncated)
    let w2 = lp.split(1_000_001, ctx);
    let amount2 = sm.withdraw(w2, 2_000_000);
    assert_eq!(amount2, 1_000_001);

    destroy(lp);
    destroy(sm);
}

// === Interleaved Multi-User Tests ===

#[test]
fun multiple_supply_withdraw_interleaved() {
    let ctx = &mut tx_context::dummy();
    let mut sm = setup(ctx);

    // First deposit: 1_000_000
    let mut lp1 = sm.supply(1_000_000, 0, ctx);
    assert_eq!(lp1.value(), 1_000_000);

    // Second deposit: 2_000_000 (vault_value=1_000_000)
    // shares = 2_000_000 * 1_000_000 / 1_000_000 = 2_000_000
    let lp2 = sm.supply(2_000_000, 1_000_000, ctx);
    assert_eq!(lp2.value(), 2_000_000);
    // total_shares=3_000_000

    // Vault grew to 6_000_000. Withdraw 500_000 shares.
    // amount = 500_000 * 6_000_000 / 3_000_000 = 1_000_000
    let w1 = lp1.split(500_000, ctx);
    let amount = sm.withdraw(w1, 6_000_000);
    assert_eq!(amount, 1_000_000);
    assert_eq!(sm.total_shares(), 2_500_000);

    // New deposit: 1_000_000 (vault_value=5_000_000)
    // shares = 1_000_000 * 2_500_000 / 5_000_000 = 500_000
    let lp3 = sm.supply(1_000_000, 5_000_000, ctx);
    assert_eq!(lp3.value(), 500_000);
    assert_eq!(sm.total_shares(), 3_000_000);

    destroy(lp1);
    destroy(lp2);
    destroy(lp3);
    destroy(sm);
}

#[test]
fun sequential_full_withdrawals() {
    let ctx = &mut tx_context::dummy();
    let mut sm = setup(ctx);

    let lp1 = sm.supply(1_000_000, 0, ctx);
    let lp2 = sm.supply(1_000_000, 1_000_000, ctx);
    // total_shares=2_000_000

    // Vault grew to 4_000_000. Withdraw lp2.
    // Not sole LP: amount = 1_000_000 * 4_000_000 / 2_000_000 = 2_000_000
    let amount1 = sm.withdraw(lp2, 4_000_000);
    assert_eq!(amount1, 2_000_000);
    assert_eq!(sm.total_shares(), 1_000_000);

    // Now sole LP. Withdraw lp1.
    // Sole LP → amount = vault_value = 2_000_000
    let amount2 = sm.withdraw(lp1, 2_000_000);
    assert_eq!(amount2, 2_000_000);
    assert_eq!(sm.total_shares(), 0);

    destroy(sm);
}

// ============================================================
// Zero-share attacks (adversarial rounding tests)
// ============================================================

#[test, expected_failure(abort_code = supply_manager::EZeroSharesMinted)]
// Depositing a tiny amount into a large vault would yield 0 shares.
fun supply_rejects_zero_share_mint() {
    let ctx = &mut tx_context::dummy();
    let mut sm = setup(ctx);

    let _lp1 = sm.supply(1_000_000, 0, ctx);

    // 1 unit into a 1B vault: 1 * 1_000_000 / 1_000_000_000 = 0 shares
    let _lp2 = sm.supply(1, 1_000_000_000, ctx);

    abort
}

#[test, expected_failure(abort_code = supply_manager::EZeroSharesMinted)]
// Classic ERC-4626 inflation attack.
fun inflation_attack_blocked() {
    let ctx = &mut tx_context::dummy();
    let mut sm = setup(ctx);

    let _lp1 = sm.supply(1, 0, ctx);

    // Attacker donates to inflate vault to 1_000_001
    // 1_000_000 * 1 / 1_000_001 = 0 shares
    let _lp2 = sm.supply(1_000_000, 1_000_001, ctx);

    abort
}

#[test]
fun supply_accepts_minimum_for_one_share() {
    let ctx = &mut tx_context::dummy();
    let mut sm = setup(ctx);

    let lp1 = sm.supply(1_000_000, 0, ctx);

    // 4 units: 4 * 1_000_000 / 3_000_000 = 1 share (truncated)
    let lp2 = sm.supply(4, 3_000_000, ctx);
    assert_eq!(lp2.value(), 1);
    assert_eq!(sm.total_shares(), 1_000_001);

    destroy(lp1);
    destroy(lp2);
    destroy(sm);
}
