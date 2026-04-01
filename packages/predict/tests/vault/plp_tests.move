// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Tests for LP token (PLP) behavior — scenarios that exist because
/// vault shares are actual Coin objects (transferable, splittable, mergeable).
#[test_only]
module deepbook_predict::plp_tests;

use deepbook_predict::{plp::PLP, supply_manager};
use std::unit_test::{assert_eq, destroy};
use sui::coin;

fun setup(ctx: &mut TxContext): supply_manager::SupplyManager {
    let treasury_cap = coin::create_treasury_cap_for_testing<PLP>(ctx);
    supply_manager::new(treasury_cap)
}

#[test]
/// Two supply calls produce two coins. Merge them and withdraw the merged coin.
fun coin_merge_then_withdraw() {
    let ctx = &mut tx_context::dummy();
    let mut sm = setup(ctx);

    let mut lp1 = sm.supply(1_000_000, 0, ctx);
    // vault_value = 1_000_000
    let lp2 = sm.supply(500_000, 1_000_000, ctx);
    assert_eq!(lp1.value(), 1_000_000);
    assert_eq!(lp2.value(), 500_000);
    assert_eq!(sm.total_shares(), 1_500_000);

    // Merge into one coin
    lp1.join(lp2);
    assert_eq!(lp1.value(), 1_500_000);

    // Withdraw merged coin — sole LP gets full vault_value
    // vault_value = 1_500_000
    let amount = sm.withdraw(lp1, 1_500_000);
    assert_eq!(amount, 1_500_000);
    assert_eq!(sm.total_shares(), 0);

    destroy(sm);
}

#[test]
/// Split one LP coin multiple times and withdraw each piece separately.
fun multiple_partial_withdrawals_via_split() {
    let ctx = &mut tx_context::dummy();
    let mut sm = setup(ctx);

    let mut lp = sm.supply(1_000_000, 0, ctx);
    // vault_value stays at 1_000_000

    // Split off 300_000 and withdraw
    let w1 = lp.split(300_000, ctx);
    let amount1 = sm.withdraw(w1, 1_000_000);
    // amount = 300_000 * 1_000_000 / 1_000_000 = 300_000
    assert_eq!(amount1, 300_000);
    assert_eq!(sm.total_shares(), 700_000);

    // Split off another 200_000 and withdraw (vault_value = 700_000)
    let w2 = lp.split(200_000, ctx);
    let amount2 = sm.withdraw(w2, 700_000);
    // amount = 200_000 * 700_000 / 700_000 = 200_000
    assert_eq!(amount2, 200_000);
    assert_eq!(sm.total_shares(), 500_000);

    // Withdraw remaining 500_000 — sole LP
    let amount3 = sm.withdraw(lp, 500_000);
    assert_eq!(amount3, 500_000);
    assert_eq!(sm.total_shares(), 0);

    destroy(sm);
}

#[test]
/// Boundary test: supply exactly 1 unit, get 1 share, withdraw 1 share.
fun single_unit_supply_and_withdraw() {
    let ctx = &mut tx_context::dummy();
    let mut sm = setup(ctx);

    let lp = sm.supply(1, 0, ctx);
    assert_eq!(lp.value(), 1);
    assert_eq!(sm.total_shares(), 1);

    // sole LP → amount = vault_value = 1
    let amount = sm.withdraw(lp, 1);
    assert_eq!(amount, 1);
    assert_eq!(sm.total_shares(), 0);

    destroy(sm);
}

#[test]
/// Deposit into a gained vault, withdraw all, receive less than deposited
/// due to truncation. Confirms vault favors existing LPs.
fun rounding_asymmetry_supply_vs_withdraw() {
    let ctx = &mut tx_context::dummy();
    let mut sm = setup(ctx);

    let lp1 = sm.supply(1_000_000, 0, ctx);

    // Vault at 3_000_000 (gained 2x). New deposit of 1_000_000.
    // shares = 1_000_000 * 1_000_000 / 3_000_000 = 333_333 (truncated)
    let lp2 = sm.supply(1_000_000, 3_000_000, ctx);
    assert_eq!(lp2.value(), 333_333);

    // Withdraw lp2 at vault_value = 4_000_000
    // total_shares = 1_333_333, lp2 = 333_333
    // amount = 333_333 * 4_000_000 / 1_333_333 = 999_999 (truncated)
    // Lost 1 unit due to rounding — vault keeps the dust
    let amount = sm.withdraw(lp2, 4_000_000);
    assert_eq!(amount, 999_999);

    destroy(lp1);
    destroy(sm);
}

#[test]
/// Two LPs, vault becomes worthless, one redeems. Amount = 0 but tokens burned.
fun withdraw_non_sole_lp_zero_vault_value() {
    let ctx = &mut tx_context::dummy();
    let mut sm = setup(ctx);

    let lp1 = sm.supply(1_000_000, 0, ctx);
    let lp2 = sm.supply(1_000_000, 1_000_000, ctx);
    // total_shares = 2_000_000

    // vault_value = 0, not sole LP
    // amount = 1_000_000 * 0 / 2_000_000 = 0
    let amount = sm.withdraw(lp1, 0);
    assert_eq!(amount, 0);
    assert_eq!(sm.total_shares(), 1_000_000);

    destroy(lp2);
    destroy(sm);
}

#[test]
/// More complex scenario: vault value changes between operations while
/// LP tokens are split, merged, and redeemed by different parties.
fun vault_value_changes_with_splits_and_merges() {
    let ctx = &mut tx_context::dummy();
    let mut sm = setup(ctx);

    // --- Round 1: Alice supplies 2_000_000 USDC (vault_value=0) ---
    // First deposit → 1:1 shares
    let mut lp_alice = sm.supply(2_000_000, 0, ctx);
    assert_eq!(lp_alice.value(), 2_000_000);
    assert_eq!(sm.total_shares(), 2_000_000);

    // --- Vault gains from trading fees: vault_value rises to 3_000_000 ---

    // --- Round 2: Bob supplies 1_500_000 USDC (vault_value=3_000_000) ---
    // shares = 1_500_000 * 2_000_000 / 3_000_000 = 1_000_000
    let lp_bob = sm.supply(1_500_000, 3_000_000, ctx);
    assert_eq!(lp_bob.value(), 1_000_000);
    assert_eq!(sm.total_shares(), 3_000_000);
    // vault_value is now 4_500_000 (3M + 1.5M deposit)

    // --- Alice splits her LP: keeps 1_200_000, splits off 800_000 ---
    let lp_alice_split = lp_alice.split(800_000, ctx);
    assert_eq!(lp_alice.value(), 1_200_000);
    assert_eq!(lp_alice_split.value(), 800_000);

    // --- Vault takes a loss: vault_value drops to 3_000_000 ---

    // --- Alice redeems her split portion (800_000 shares) ---
    // Not sole LP: amount = 800_000 * 3_000_000 / 3_000_000 = 800_000
    let amount1 = sm.withdraw(lp_alice_split, 3_000_000);
    assert_eq!(amount1, 800_000);
    assert_eq!(sm.total_shares(), 2_200_000);
    // vault_value after withdrawal = 3_000_000 - 800_000 = 2_200_000

    // --- Carol supplies 440_000 USDC (vault_value=2_200_000) ---
    // shares = 440_000 * 2_200_000 / 2_200_000 = 440_000
    let lp_carol = sm.supply(440_000, 2_200_000, ctx);
    assert_eq!(lp_carol.value(), 440_000);
    assert_eq!(sm.total_shares(), 2_640_000);
    // vault_value = 2_200_000 + 440_000 = 2_640_000

    // --- Bob transfers tokens to Carol (simulated: merge Bob + Carol coins) ---
    let mut lp_merged = lp_bob;
    lp_merged.join(lp_carol);
    assert_eq!(lp_merged.value(), 1_440_000);

    // --- Vault recovers: vault_value rises to 5_280_000 (2x) ---

    // --- Carol (holding merged coins) redeems 720_000 shares ---
    let lp_partial = lp_merged.split(720_000, ctx);
    // Not sole LP: amount = 720_000 * 5_280_000 / 2_640_000 = 1_440_000
    let amount2 = sm.withdraw(lp_partial, 5_280_000);
    assert_eq!(amount2, 1_440_000);
    assert_eq!(sm.total_shares(), 1_920_000);
    // vault_value = 5_280_000 - 1_440_000 = 3_840_000

    // --- Alice redeems remaining 1_200_000 shares ---
    // Not sole LP: amount = 1_200_000 * 3_840_000 / 1_920_000 = 2_400_000
    let amount3 = sm.withdraw(lp_alice, 3_840_000);
    assert_eq!(amount3, 2_400_000);
    assert_eq!(sm.total_shares(), 720_000);
    // vault_value = 3_840_000 - 2_400_000 = 1_440_000

    // --- Carol redeems last 720_000 shares — sole LP ---
    let amount4 = sm.withdraw(lp_merged, 1_440_000);
    assert_eq!(amount4, 1_440_000);
    assert_eq!(sm.total_shares(), 0);

    destroy(sm);
}
