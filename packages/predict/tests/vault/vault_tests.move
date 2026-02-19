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
