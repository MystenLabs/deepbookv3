// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// A2/A3 trading-loss rebate conservation: a staked trader's order settles
/// worthless exactly ON its lower boundary (the half-open `(lower, higher]`
/// range excludes lower), then `claim_trading_loss_rebate` resolves the
/// reserve. Pins the exact three-way fee split — for fee F = 5e6 at the 50%
/// default rebate rate and a stake at the benefit-curve kink (ratio exactly
/// 0.5): 1_250_000 rebated to the trader, 1_250_000 residual returned to pool
/// idle, 2_500_000 unreserved fee half retained in expiry cash — with the
/// rebate reserve resolving to exactly 0, zero protocol-reserve recognition
/// (received is still under the funding watermark), and the closed-system
/// DUSDC conservation identity holding to the unit.
#[test_only]
module deepbook_predict::rebate_claim_accounting_tests;

use deepbook_predict::{config_constants, constants, flow_test_helpers as helpers, test_constants};
use std::unit_test::{assert_eq, destroy};
use sui::coin;
use token::deep::DEEP;

/// 1x ATM mint: p = Φ(0) = 0.5 exactly, premium = floor(0.5 * 1e9); fee floors
/// at min_fee (fixture base_fee = 1; the default max-multiplier 1.0 keeps the
/// short-expiry fee ramp inert).
const MINT_PRINCIPAL: u64 = 500_000_000;
const MINT_MIN_FEE: u64 = 5_000_000;
/// mint_deposit − principal − fee.
const POST_MINT_BALANCE: u64 = 495_000_000;
/// Reserved at mint = floor(F * 0.5 default rebate rate); this is also the
/// full amount resolved at claim (the other half of F was never escrowed and
/// stays in expiry cash).
const RESOLVED_RESERVE: u64 = 2_500_000;
/// Rebate paid = floor(resolved * benefit_ratio). The stake sits exactly at
/// the benefit-curve kink ("half of max benefits"), so the ratio is exactly
/// 0.5: floor(2.5e6 * 0.5) = 1_250_000. The residual (resolved − rebate)
/// returns to pool idle — also 1_250_000.
const REBATE_PAID: u64 = 1_250_000;

#[test]
fun rebate_claim_splits_reserve_exactly_and_conserves() {
    let (mut fx, expiry_id, oracle_id, mut manager) = helpers::setup_live_market(
        test_constants::short_expiry_ms(),
        test_constants::default_live_price(),
    );
    fx.scenario_mut().next_tx(test_constants::alice());
    let (pyth, mut vault, mut market, oracle, config) = fx.take_market(
        expiry_id,
        oracle_id,
    );

    // --- Baseline.
    let cash_floor = constants::expiry_cash_floor!();
    let initial_supply = test_constants::default_initial_supply();
    helpers::check_market_cash(&market, helpers::expected_market_cash(cash_floor, 0, 0));
    helpers::check_pool(
        &vault,
        helpers::expected_pool_state(initial_supply - cash_floor, initial_supply, 0),
    );
    helpers::check_manager(
        &manager,
        expiry_id,
        helpers::expected_manager_state(test_constants::mint_deposit(), 0, 0, 0, 0),
    );

    // --- Mint the 1x ATM order on (min_strike, +inf].
    let order_id = fx.mint(
        &config,
        &mut manager,
        &mut market,
        &oracle,
        &pyth,
        helpers::min_strike(),
        constants::pos_inf!(),
        test_constants::mint_quantity(),
        test_constants::leverage_one_x(),
    );
    let cash_after_mint = cash_floor + MINT_PRINCIPAL + MINT_MIN_FEE;
    helpers::check_market_cash(
        &market,
        helpers::expected_market_cash(
            cash_after_mint,
            test_constants::mint_quantity(),
            RESOLVED_RESERVE,
        ),
    );
    helpers::check_manager(
        &manager,
        expiry_id,
        helpers::expected_manager_state(POST_MINT_BALANCE, MINT_MIN_FEE, 1, 0, 0),
    );

    // --- Stake exactly the benefit-curve kink AFTER the mint (so the mint fee
    // carried no staking discount). The stake records as inactive this epoch;
    // staking moves only DEEP — every DUSDC sheet is untouched.
    let kink_stake = config_constants::default_lower_benefit_power!();
    let deep = coin::mint_for_testing<DEEP>(kink_stake, fx.scenario_mut().ctx());
    vault.stake_deep(&mut manager, deep, fx.scenario_mut().ctx());
    helpers::check_manager(
        &manager,
        expiry_id,
        helpers::expected_manager_state(POST_MINT_BALANCE, MINT_MIN_FEE, 1, 0, kink_stake),
    );
    assert_eq!(vault.staked_deep(), kink_stake);
    helpers::check_market_cash(
        &market,
        helpers::expected_market_cash(
            cash_after_mint,
            test_constants::mint_quantity(),
            RESOLVED_RESERVE,
        ),
    );
    helpers::check_pool(
        &vault,
        helpers::expected_pool_state(initial_supply - cash_floor, initial_supply, 0),
    );

    // --- Advance one epoch (so the claim's update_stake can roll the stake
    // active), then settle exactly ON the lower boundary: (lower, higher]
    // excludes lower, so the order is worthless.
    helpers::return_market(pyth, vault, market, oracle, config);
    fx.scenario_mut().next_epoch(test_constants::alice());
    let (mut pyth, mut vault, mut market, mut oracle, config) = fx.take_market(
        expiry_id,
        oracle_id,
    );
    fx.settle_oracle(&config, &mut oracle, &mut pyth, helpers::min_strike());
    fx.redeem_settled(
        &config,
        &mut manager,
        &mut market,
        &oracle,
        &pyth,
        order_id,
        test_constants::mint_quantity(),
    );
    // Zero payout, no settled-redeem fee, position cleared; the fee basis and
    // its reserve survive untouched until the claim. (Stake fields are
    // deliberately not asserted here — whether a settled redeem rolls the
    // epoch stake is unspecified.)
    assert_eq!(manager.balance(), POST_MINT_BALANCE);
    assert_eq!(manager.trading_fees_paid(expiry_id), MINT_MIN_FEE);
    assert_eq!(manager.expiry_position_count(expiry_id), 0);
    assert!(!manager.has_position(expiry_id, order_id));
    helpers::check_market_cash(
        &market,
        helpers::expected_market_cash(cash_after_mint, 0, RESOLVED_RESERVE),
    );

    // --- Claim: the net-loss trader's full reserve resolves; the rebate is
    // benefit-scaled (exactly half at the kink) and the residual returns to
    // pool idle. No protocol profit is recognized — the pool funded 50_000e6
    // and has received back only the 1.25e6 residual, far under the watermark.
    let balance_before_claim = manager.balance();
    fx.claim_trading_loss_rebate(&config, &mut vault, &mut market, &oracle, &mut manager);
    assert_eq!(manager.balance() - balance_before_claim, REBATE_PAID);
    // fees_paid reads 0 after the claim: resolving removes the per-expiry
    // summary row and the getter falls back to 0.
    helpers::check_manager(
        &manager,
        expiry_id,
        helpers::expected_manager_state(POST_MINT_BALANCE + REBATE_PAID, 0, 0, kink_stake, 0),
    );
    helpers::check_market_cash(
        &market,
        helpers::expected_market_cash(cash_after_mint - RESOLVED_RESERVE, 0, 0),
    );
    helpers::check_pool(
        &vault,
        helpers::expected_pool_state(
            initial_supply - cash_floor + (RESOLVED_RESERVE - REBATE_PAID),
            initial_supply,
            0,
        ),
    );

    // Closed-system DUSDC conservation: every unit of the fee is accounted —
    // rebate to trader + residual to idle + unreserved half still in expiry
    // cash. Total == initial pool supply + manager deposit.
    assert_eq!(
        manager.balance() + market.cash_balance() + vault.idle_balance(),
        initial_supply + test_constants::mint_deposit(),
    );

    helpers::return_market(pyth, vault, market, oracle, config);
    destroy(manager);
    fx.finish();
}
