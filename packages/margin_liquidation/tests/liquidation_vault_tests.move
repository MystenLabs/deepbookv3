// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module margin_liquidation::liquidation_vault_tests;

use margin_liquidation::liquidation_vault::{Self, LiquidationVault, LiquidationAdminCap};
use std::unit_test::destroy;
use sui::{coin, sui::SUI};

public struct QUOTE has drop {}

fun setup(ctx: &mut TxContext): (LiquidationVault, LiquidationAdminCap) {
    let vault = liquidation_vault::create_liquidation_vault_for_testing(ctx);
    let cap = liquidation_vault::create_admin_cap_for_testing(ctx);
    (vault, cap)
}

// === Deposit / Withdraw ===

#[test]
fun deposit_and_check_balance() {
    let ctx = &mut tx_context::dummy();
    let (mut vault, cap) = setup(ctx);

    assert!(vault.balance<SUI>() == 0);

    let coin = coin::mint_for_testing<SUI>(1000, ctx);
    vault.deposit(&cap, coin);
    assert!(vault.balance<SUI>() == 1000);

    destroy(vault);
    destroy(cap);
}

#[test]
fun deposit_multiple_accumulates() {
    let ctx = &mut tx_context::dummy();
    let (mut vault, cap) = setup(ctx);

    vault.deposit(&cap, coin::mint_for_testing<SUI>(500, ctx));
    vault.deposit(&cap, coin::mint_for_testing<SUI>(300, ctx));
    assert!(vault.balance<SUI>() == 800);

    destroy(vault);
    destroy(cap);
}

#[test]
fun deposit_multiple_asset_types() {
    let ctx = &mut tx_context::dummy();
    let (mut vault, cap) = setup(ctx);

    vault.deposit(&cap, coin::mint_for_testing<SUI>(1000, ctx));
    vault.deposit(&cap, coin::mint_for_testing<QUOTE>(2000, ctx));

    assert!(vault.balance<SUI>() == 1000);
    assert!(vault.balance<QUOTE>() == 2000);

    destroy(vault);
    destroy(cap);
}

#[test]
fun withdraw_reduces_balance() {
    let ctx = &mut tx_context::dummy();
    let (mut vault, cap) = setup(ctx);

    vault.deposit(&cap, coin::mint_for_testing<SUI>(1000, ctx));
    let withdrawn = vault.withdraw<SUI>(&cap, 400, ctx);
    assert!(withdrawn.value() == 400);
    assert!(vault.balance<SUI>() == 600);

    destroy(withdrawn);
    destroy(vault);
    destroy(cap);
}

#[test]
fun withdraw_full_balance() {
    let ctx = &mut tx_context::dummy();
    let (mut vault, cap) = setup(ctx);

    vault.deposit(&cap, coin::mint_for_testing<SUI>(1000, ctx));
    let withdrawn = vault.withdraw<SUI>(&cap, 1000, ctx);
    assert!(withdrawn.value() == 1000);
    assert!(vault.balance<SUI>() == 0);

    destroy(withdrawn);
    destroy(vault);
    destroy(cap);
}

#[test, expected_failure(abort_code = liquidation_vault::ENotEnoughBalanceInVault)]
fun withdraw_exceeds_balance_fail() {
    let ctx = &mut tx_context::dummy();
    let (mut vault, cap) = setup(ctx);

    vault.deposit(&cap, coin::mint_for_testing<SUI>(100, ctx));
    let _withdrawn = vault.withdraw<SUI>(&cap, 200, ctx);

    abort // unreachable
}

#[test, expected_failure(abort_code = liquidation_vault::ENotEnoughBalanceInVault)]
fun withdraw_empty_vault_fail() {
    let ctx = &mut tx_context::dummy();
    let (mut vault, cap) = setup(ctx);

    let _withdrawn = vault.withdraw<SUI>(&cap, 1, ctx);

    abort // unreachable
}

// === Authorize / Deauthorize Trader ===

#[test]
fun authorize_trader_works() {
    let ctx = &mut tx_context::dummy();
    let (mut vault, cap) = setup(ctx);

    vault.authorize_trader(&cap, @0xA);
    vault.authorize_trader(&cap, @0xB);

    destroy(vault);
    destroy(cap);
}

#[test]
fun deauthorize_trader_works() {
    let ctx = &mut tx_context::dummy();
    let (mut vault, cap) = setup(ctx);

    vault.authorize_trader(&cap, @0xA);
    vault.authorize_trader(&cap, @0xB);
    vault.deauthorize_trader(&cap, @0xA);

    destroy(vault);
    destroy(cap);
}

#[test, expected_failure]
fun authorize_duplicate_trader_fail() {
    let ctx = &mut tx_context::dummy();
    let (mut vault, cap) = setup(ctx);

    vault.authorize_trader(&cap, @0xA);
    vault.authorize_trader(&cap, @0xA);

    abort // unreachable
}

#[test, expected_failure]
fun deauthorize_nonexistent_trader_fail() {
    let ctx = &mut tx_context::dummy();
    let (mut vault, cap) = setup(ctx);

    vault.authorize_trader(&cap, @0xA);
    vault.deauthorize_trader(&cap, @0xB);

    abort // unreachable
}

#[test, expected_failure]
fun deauthorize_without_any_traders_fail() {
    let ctx = &mut tx_context::dummy();
    let (mut vault, cap) = setup(ctx);

    vault.deauthorize_trader(&cap, @0xA);

    abort // unreachable
}

// === assert_trader via swap functions ===

#[test, expected_failure(abort_code = liquidation_vault::ETraderNotAuthorized)]
fun swap_base_unauthorized_trader_fail() {
    let ctx = &mut tx_context::dummy();
    let (mut vault, cap) = setup(ctx);

    vault.authorize_trader(&cap, @0xCAFE);

    // ctx.sender() is @0x0 (dummy), not @0xCAFE
    vault.assert_trader_for_testing(ctx);

    abort // unreachable
}

#[test]
fun swap_base_authorized_trader_passes() {
    let ctx = &mut tx_context::dummy();
    let (mut vault, cap) = setup(ctx);

    // dummy ctx sender is @0x0
    vault.authorize_trader(&cap, @0x0);
    vault.assert_trader_for_testing(ctx);

    destroy(vault);
    destroy(cap);
}

#[test, expected_failure(abort_code = liquidation_vault::ETraderNotAuthorized)]
fun deauthorized_trader_cannot_trade_fail() {
    let ctx = &mut tx_context::dummy();
    let (mut vault, cap) = setup(ctx);

    vault.authorize_trader(&cap, @0x0);
    vault.deauthorize_trader(&cap, @0x0);

    vault.assert_trader_for_testing(ctx);

    abort // unreachable
}

// === Balance of uninitialized type ===

#[test]
fun balance_uninitialized_returns_zero() {
    let ctx = &mut tx_context::dummy();
    let (vault, cap) = setup(ctx);

    assert!(vault.balance<SUI>() == 0);
    assert!(vault.balance<QUOTE>() == 0);

    destroy(vault);
    destroy(cap);
}
