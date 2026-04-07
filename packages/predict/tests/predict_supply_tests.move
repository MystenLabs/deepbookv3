// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Tests for vault supply/withdraw and PLP token behavior.
#[test_only]
module deepbook_predict::predict_supply_tests;

use deepbook_predict::{plp::PLP, predict::{Self, Predict}, treasury_config, vault};
use std::unit_test::{assert_eq, destroy};
use sui::{coin, sui::SUI, test_scenario};

const ALICE: address = @0xA;
const BOB: address = @0xB;

public struct ALTUSD has drop {}

fun setup(ctx: &mut TxContext): Predict {
    predict::create_test_predict<SUI>(ctx)
}

/// Supply SUI and return LP coin. Helper to reduce boilerplate.
fun do_supply(predict: &mut Predict, amount: u64, ctx: &mut TxContext): coin::Coin<PLP> {
    let coin = coin::mint_for_testing<SUI>(amount, ctx);
    predict.supply(coin, ctx)
}

/// Supply ALTUSD and return LP coin. Helper to reduce boilerplate.
fun do_supply_alt(
    predict: &mut Predict,
    amount: u64,
    ctx: &mut TxContext,
): coin::Coin<PLP> {
    let coin = coin::mint_for_testing<ALTUSD>(amount, ctx);
    predict.supply(coin, ctx)
}

// ============================================================
// supply() Tests
// ============================================================

#[test]
fun first_deposit_one_to_one() {
    let ctx = &mut tx_context::dummy();
    let mut predict = setup(ctx);

    let lp = do_supply(&mut predict, 1_000_000, ctx);
    assert_eq!(lp.value(), 1_000_000);
    assert_eq!(predict.vault_balance(), 1_000_000);

    destroy(lp);
    destroy(predict);
}

#[test]
fun second_deposit_proportional() {
    let ctx = &mut tx_context::dummy();
    let mut predict = setup(ctx);

    let lp1 = do_supply(&mut predict, 1_000_000, ctx);
    // vault_value = 1_000_000, total_shares = 1_000_000
    // shares = 500_000 * 1_000_000 / 1_000_000 = 500_000
    let lp2 = do_supply(&mut predict, 500_000, ctx);
    assert_eq!(lp2.value(), 500_000);

    destroy(lp1);
    destroy(lp2);
    destroy(predict);
}

#[test]
fun deposit_when_vault_gained_value() {
    let ctx = &mut tx_context::dummy();
    let mut predict = setup(ctx);

    let lp1 = do_supply(&mut predict, 1_000_000, ctx);
    // Simulate vault gain by injecting extra balance
    let extra = coin::mint_for_testing<SUI>(1_000_000, ctx);
    predict.vault_mut().accept_payment(extra.into_balance());
    // vault_value = 2_000_000, total_shares = 1_000_000
    // shares = 1_000_000 * 1_000_000 / 2_000_000 = 500_000
    let lp2 = do_supply(&mut predict, 1_000_000, ctx);
    assert_eq!(lp2.value(), 500_000);

    destroy(lp1);
    destroy(lp2);
    destroy(predict);
}

#[test, expected_failure(abort_code = predict::EZeroAmount)]
fun supply_zero_amount_aborts() {
    let ctx = &mut tx_context::dummy();
    let mut predict = setup(ctx);
    let _lp = do_supply(&mut predict, 0, ctx);

    abort 999
}

#[test, expected_failure(abort_code = predict::EZeroSharesMinted)]
fun supply_rejects_zero_share_mint() {
    let ctx = &mut tx_context::dummy();
    let mut predict = setup(ctx);

    let _lp1 = do_supply(&mut predict, 1_000_000, ctx);
    // Simulate massive vault gain
    let extra = coin::mint_for_testing<SUI>(999_000_000, ctx);
    predict.vault_mut().accept_payment(extra.into_balance());
    // 1 unit into a 1B vault: 1 * 1_000_000 / 1_000_000_000 = 0 shares
    let _lp2 = do_supply(&mut predict, 1, ctx);

    abort 999
}

#[test, expected_failure(abort_code = predict::EZeroSharesMinted)]
fun inflation_attack_blocked() {
    let ctx = &mut tx_context::dummy();
    let mut predict = setup(ctx);

    let _lp1 = do_supply(&mut predict, 1, ctx);
    // Simulate donation to inflate vault to 1_000_001
    let extra = coin::mint_for_testing<SUI>(1_000_000, ctx);
    predict.vault_mut().accept_payment(extra.into_balance());
    // 1_000_000 * 1 / 1_000_001 = 0 shares
    let _lp2 = do_supply(&mut predict, 1_000_000, ctx);

    abort 999
}

#[test]
fun supply_accepts_minimum_for_one_share() {
    let ctx = &mut tx_context::dummy();
    let mut predict = setup(ctx);

    let lp1 = do_supply(&mut predict, 1_000_000, ctx);
    // Simulate vault gain to 3_000_000
    let extra = coin::mint_for_testing<SUI>(2_000_000, ctx);
    predict.vault_mut().accept_payment(extra.into_balance());
    // 4 * 1_000_000 / 3_000_000 = 1 share (truncated)
    let lp2 = do_supply(&mut predict, 4, ctx);
    assert_eq!(lp2.value(), 1);

    destroy(lp1);
    destroy(lp2);
    destroy(predict);
}

#[test]
fun supply_accepts_second_whitelisted_quote_asset() {
    let ctx = &mut tx_context::dummy();
    let mut predict = setup(ctx);
    predict.add_quote_asset<ALTUSD>();

    let lp_sui = do_supply(&mut predict, 1_000_000, ctx);
    let lp_alt = do_supply_alt(&mut predict, 500_000, ctx);

    assert_eq!(lp_alt.value(), 500_000);
    assert_eq!(predict.vault_balance(), 1_500_000);
    assert_eq!(vault::asset_balance<SUI>(predict.vault_mut()), 1_000_000);
    assert_eq!(vault::asset_balance<ALTUSD>(predict.vault_mut()), 500_000);

    destroy(lp_sui);
    destroy(lp_alt);
    destroy(predict);
}

#[test]
fun supply_values_vault_across_both_quote_assets() {
    let ctx = &mut tx_context::dummy();
    let mut predict = setup(ctx);
    predict.add_quote_asset<ALTUSD>();

    let lp_sui = do_supply(&mut predict, 1_000_000, ctx);
    let lp_alt = do_supply_alt(&mut predict, 500_000, ctx);

    // Simulate additional vault value arriving in the secondary quote asset.
    let extra_alt = coin::mint_for_testing<ALTUSD>(1_500_000, ctx);
    predict.vault_mut().accept_payment(extra_alt.into_balance());

    // vault_value = 3_000_000, total_shares = 1_500_000
    // shares = 600_000 * 1_500_000 / 3_000_000 = 300_000
    let lp3 = do_supply(&mut predict, 600_000, ctx);
    assert_eq!(lp3.value(), 300_000);
    assert_eq!(predict.vault_balance(), 3_600_000);
    assert_eq!(vault::asset_balance<SUI>(predict.vault_mut()), 1_600_000);
    assert_eq!(vault::asset_balance<ALTUSD>(predict.vault_mut()), 2_000_000);

    destroy(lp_sui);
    destroy(lp_alt);
    destroy(lp3);
    destroy(predict);
}

#[test, expected_failure(abort_code = treasury_config::EQuoteAssetNotAccepted)]
fun supply_rejects_unapproved_quote_asset() {
    let ctx = &mut tx_context::dummy();
    let mut predict = setup(ctx);
    let coin = coin::mint_for_testing<ALTUSD>(1_000_000, ctx);

    let _lp = predict.supply(coin, ctx);

    abort
}

// ============================================================
// withdraw() Tests
// ============================================================

#[test]
fun withdraw_partial() {
    let ctx = &mut tx_context::dummy();
    let mut predict = setup(ctx);

    let mut lp = do_supply(&mut predict, 1_000_000, ctx);
    let withdraw_lp = lp.split(500_000, ctx);
    let usdc = predict.withdraw<SUI>(withdraw_lp, ctx);
    assert_eq!(usdc.value(), 500_000);
    assert_eq!(predict.vault_balance(), 500_000);

    destroy(lp);
    destroy(usdc);
    destroy(predict);
}

#[test]
fun withdraw_all_shares() {
    let ctx = &mut tx_context::dummy();
    let mut predict = setup(ctx);

    let lp = do_supply(&mut predict, 1_000_000, ctx);
    // sole LP → amount = vault_value
    let usdc = predict.withdraw<SUI>(lp, ctx);
    assert_eq!(usdc.value(), 1_000_000);
    assert_eq!(predict.vault_balance(), 0);

    destroy(usdc);
    destroy(predict);
}

#[test]
fun withdraw_when_vault_gained() {
    let ctx = &mut tx_context::dummy();
    let mut predict = setup(ctx);

    let mut lp = do_supply(&mut predict, 1_000_000, ctx);
    // Vault doubles
    let extra = coin::mint_for_testing<SUI>(1_000_000, ctx);
    predict.vault_mut().accept_payment(extra.into_balance());
    // Withdraw 500_000 shares: amount = 500_000 * 2_000_000 / 1_000_000 = 1_000_000
    let withdraw_lp = lp.split(500_000, ctx);
    let usdc = predict.withdraw<SUI>(withdraw_lp, ctx);
    assert_eq!(usdc.value(), 1_000_000);

    destroy(lp);
    destroy(usdc);
    destroy(predict);
}

#[test, expected_failure(abort_code = predict::EZeroAmount)]
fun withdraw_zero_shares_aborts() {
    let ctx = &mut tx_context::dummy();
    let mut predict = setup(ctx);

    let _lp = do_supply(&mut predict, 1_000_000, ctx);
    let zero_coin = coin::zero<PLP>(ctx);
    let _usdc = predict.withdraw<SUI>(zero_coin, ctx);

    abort 999
}

#[test]
fun withdraw_sole_lp_gets_full_vault_value() {
    let ctx = &mut tx_context::dummy();
    let mut predict = setup(ctx);

    let lp = do_supply(&mut predict, 1_000_000, ctx);
    // Vault grew
    let extra = coin::mint_for_testing<SUI>(500_000, ctx);
    predict.vault_mut().accept_payment(extra.into_balance());
    // sole LP → amount = full vault_value = 1_500_000
    let usdc = predict.withdraw<SUI>(lp, ctx);
    assert_eq!(usdc.value(), 1_500_000);

    destroy(usdc);
    destroy(predict);
}

#[test]
fun withdraw_secondary_quote_uses_matching_concrete_balance() {
    let ctx = &mut tx_context::dummy();
    let mut predict = setup(ctx);
    predict.add_quote_asset<ALTUSD>();

    let lp_sui = do_supply(&mut predict, 1_000_000, ctx);
    let lp_alt = do_supply_alt(&mut predict, 500_000, ctx);
    let alt = predict.withdraw<ALTUSD>(lp_alt, ctx);

    assert_eq!(alt.value(), 500_000);
    assert_eq!(predict.vault_balance(), 1_000_000);
    assert_eq!(vault::asset_balance<SUI>(predict.vault_mut()), 1_000_000);
    assert_eq!(vault::asset_balance<ALTUSD>(predict.vault_mut()), 0);

    destroy(lp_sui);
    destroy(alt);
    destroy(predict);
}

#[test, expected_failure(abort_code = vault::EAssetNotInVault)]
fun withdraw_whitelisted_asset_without_concrete_balance_aborts() {
    let ctx = &mut tx_context::dummy();
    let mut predict = setup(ctx);
    predict.add_quote_asset<ALTUSD>();

    // Supply SUI and withdraw ALTUSD but no ALTUSD in vault
    let lp = do_supply(&mut predict, 1_000_000, ctx);
    let _alt = predict.withdraw<ALTUSD>(lp, ctx);

    abort 999
}

// ============================================================
// Rounding Tests
// ============================================================

#[test]
fun supply_rounding_truncation() {
    let ctx = &mut tx_context::dummy();
    let mut predict = setup(ctx);

    let lp1 = do_supply(&mut predict, 1_000_000, ctx);
    // Vault gained to 3_000_000
    let extra = coin::mint_for_testing<SUI>(2_000_000, ctx);
    predict.vault_mut().accept_payment(extra.into_balance());
    // shares = 1_000_001 * 1_000_000 / 3_000_000 = 333_333 (truncated)
    let lp2 = do_supply(&mut predict, 1_000_001, ctx);
    assert_eq!(lp2.value(), 333_333);

    destroy(lp1);
    destroy(lp2);
    destroy(predict);
}

#[test]
fun rounding_asymmetry_supply_vs_withdraw() {
    let ctx = &mut tx_context::dummy();
    let mut predict = setup(ctx);

    let lp1 = do_supply(&mut predict, 1_000_000, ctx);
    // Vault gained to 3_000_000
    let extra = coin::mint_for_testing<SUI>(2_000_000, ctx);
    predict.vault_mut().accept_payment(extra.into_balance());
    // shares = 1_000_000 * 1_000_000 / 3_000_000 = 333_333
    let lp2 = do_supply(&mut predict, 1_000_000, ctx);
    assert_eq!(lp2.value(), 333_333);
    // vault_value = 4_000_000, total_shares = 1_333_333
    // Withdraw lp2: amount = 333_333 * 4_000_000 / 1_333_333 = 999_999 (truncated)
    let usdc = predict.withdraw<SUI>(lp2, ctx);
    assert_eq!(usdc.value(), 999_999);

    destroy(lp1);
    destroy(usdc);
    destroy(predict);
}

// ============================================================
// PLP Token Scenarios (merge, split, transfer)
// ============================================================

#[test]
fun coin_merge_then_withdraw() {
    let ctx = &mut tx_context::dummy();
    let mut predict = setup(ctx);

    let mut lp1 = do_supply(&mut predict, 1_000_000, ctx);
    let lp2 = do_supply(&mut predict, 500_000, ctx);
    lp1.join(lp2);
    assert_eq!(lp1.value(), 1_500_000);

    // sole LP → full vault_value = 1_500_000
    let usdc = predict.withdraw<SUI>(lp1, ctx);
    assert_eq!(usdc.value(), 1_500_000);

    destroy(usdc);
    destroy(predict);
}

#[test]
fun multiple_partial_withdrawals_via_split() {
    let ctx = &mut tx_context::dummy();
    let mut predict = setup(ctx);

    let mut lp = do_supply(&mut predict, 1_000_000, ctx);

    let w1 = lp.split(300_000, ctx);
    let usdc1 = predict.withdraw<SUI>(w1, ctx);
    assert_eq!(usdc1.value(), 300_000);

    let w2 = lp.split(200_000, ctx);
    let usdc2 = predict.withdraw<SUI>(w2, ctx);
    assert_eq!(usdc2.value(), 200_000);

    // Remaining 500_000 shares — sole LP
    let usdc3 = predict.withdraw<SUI>(lp, ctx);
    assert_eq!(usdc3.value(), 500_000);

    destroy(usdc1);
    destroy(usdc2);
    destroy(usdc3);
    destroy(predict);
}

#[test]
fun lp_transfer_then_withdraw_by_recipient() {
    let mut scenario = test_scenario::begin(ALICE);
    {
        let treasury_cap = coin::create_treasury_cap_for_testing<PLP>(scenario.ctx());
        predict::create<SUI>(treasury_cap, scenario.ctx());
    };

    scenario.next_tx(ALICE);
    {
        let mut predict = scenario.take_shared<Predict>();
        let payment = coin::mint_for_testing<SUI>(1_000_000, scenario.ctx());
        let lp = predict.supply(payment, scenario.ctx());

        test_scenario::return_shared(predict);
        transfer::public_transfer(lp, BOB);
    };

    scenario.next_tx(BOB);
    {
        let mut predict = scenario.take_shared<Predict>();
        let lp = scenario.take_from_sender<coin::Coin<PLP>>();
        let usdc = predict.withdraw<SUI>(lp, scenario.ctx());
        assert_eq!(usdc.value(), 1_000_000);
        assert_eq!(predict.vault_balance(), 0);

        test_scenario::return_shared(predict);
        destroy(usdc);
    };

    scenario.end();
}

#[test]
fun single_unit_supply_and_withdraw() {
    let ctx = &mut tx_context::dummy();
    let mut predict = setup(ctx);

    let lp = do_supply(&mut predict, 1, ctx);
    assert_eq!(lp.value(), 1);

    let usdc = predict.withdraw<SUI>(lp, ctx);
    assert_eq!(usdc.value(), 1);

    destroy(usdc);
    destroy(predict);
}

#[test]
fun supply_withdraw_then_resupply() {
    let ctx = &mut tx_context::dummy();
    let mut predict = setup(ctx);

    let lp1 = do_supply(&mut predict, 1_000_000, ctx);
    let usdc1 = predict.withdraw<SUI>(lp1, ctx);
    assert_eq!(usdc1.value(), 1_000_000);
    assert_eq!(predict.vault_balance(), 0);

    // Re-supply after full exit
    let lp2 = do_supply(&mut predict, 2_000_000, ctx);
    assert_eq!(lp2.value(), 2_000_000);

    destroy(usdc1);
    destroy(lp2);
    destroy(predict);
}

#[test]
fun vault_value_changes_with_splits_and_merges() {
    let ctx = &mut tx_context::dummy();
    let mut predict = setup(ctx);

    // Alice supplies 2_000_000
    let mut lp_alice = do_supply(&mut predict, 2_000_000, ctx);
    assert_eq!(lp_alice.value(), 2_000_000);

    // Vault gains to 3_000_000
    let extra1 = coin::mint_for_testing<SUI>(1_000_000, ctx);
    predict.vault_mut().accept_payment(extra1.into_balance());

    // Bob supplies 1_500_000 at vault_value=3_000_000
    // shares = 1_500_000 * 2_000_000 / 3_000_000 = 1_000_000
    let lp_bob = do_supply(&mut predict, 1_500_000, ctx);
    assert_eq!(lp_bob.value(), 1_000_000);
    // vault_value = 4_500_000, total_shares = 3_000_000

    // Alice splits off 800_000
    let lp_alice_split = lp_alice.split(800_000, ctx);

    // Alice redeems split portion
    // amount = 800_000 * 4_500_000 / 3_000_000 = 1_200_000
    let usdc1 = predict.withdraw<SUI>(lp_alice_split, ctx);
    assert_eq!(usdc1.value(), 1_200_000);
    // vault_value = 3_300_000, total_shares = 2_200_000

    // Carol supplies 440_000 at vault_value=3_300_000
    // shares = 440_000 * 2_200_000 / 3_300_000 = 293_333
    let lp_carol = do_supply(&mut predict, 440_000, ctx);
    assert_eq!(lp_carol.value(), 293_333);
    // vault_value = 3_740_000, total_shares = 2_493_333

    // Bob transfers to Carol (merge coins)
    let mut lp_merged = lp_bob;
    lp_merged.join(lp_carol);
    assert_eq!(lp_merged.value(), 1_293_333);

    // Vault recovers: inject extra to double
    let extra2 = coin::mint_for_testing<SUI>(3_740_000, ctx);
    predict.vault_mut().accept_payment(extra2.into_balance());
    // vault_value = 7_480_000, total_shares = 2_493_333

    // Carol redeems 720_000 shares from merged coin
    let w2 = lp_merged.split(720_000, ctx);
    // amount = 720_000 * 7_480_000 / 2_493_333 = 2_160_000
    let usdc2 = predict.withdraw<SUI>(w2, ctx);
    assert_eq!(usdc2.value(), 2_160_000);
    // vault_value = 5_320_000, total_shares = 1_773_333

    // Alice redeems remaining 1_200_000 shares
    // amount = 1_200_000 * 5_320_000 / 1_773_333 = 3_600_000
    let usdc3 = predict.withdraw<SUI>(lp_alice, ctx);
    assert_eq!(usdc3.value(), 3_600_000);
    // vault_value = 1_720_000, total_shares = 573_333

    // Carol redeems last — sole LP
    let usdc4 = predict.withdraw<SUI>(lp_merged, ctx);
    assert_eq!(usdc4.value(), 1_720_000);

    destroy(usdc1);
    destroy(usdc2);
    destroy(usdc3);
    destroy(usdc4);
    destroy(predict);
}

// ============================================================
// Multi-user interleaved
// ============================================================

#[test]
fun sequential_full_withdrawals() {
    let ctx = &mut tx_context::dummy();
    let mut predict = setup(ctx);

    let lp1 = do_supply(&mut predict, 1_000_000, ctx);
    let lp2 = do_supply(&mut predict, 1_000_000, ctx);
    // total_shares = 2_000_000, vault_value = 2_000_000

    // Vault grows to 4_000_000
    let extra = coin::mint_for_testing<SUI>(2_000_000, ctx);
    predict.vault_mut().accept_payment(extra.into_balance());

    // lp2 (1M shares): amount = 1_000_000 * 4_000_000 / 2_000_000 = 2_000_000
    let usdc1 = predict.withdraw<SUI>(lp2, ctx);
    assert_eq!(usdc1.value(), 2_000_000);

    // lp1 sole LP: amount = vault_value = 2_000_000
    let usdc2 = predict.withdraw<SUI>(lp1, ctx);
    assert_eq!(usdc2.value(), 2_000_000);

    destroy(usdc1);
    destroy(usdc2);
    destroy(predict);
}
