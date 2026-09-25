// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Active flow coverage for sponsor-funded Predict fee incentives: sponsorship
/// into the pool reserve, allocation to live markets, the admin-set subsidy rate
/// read live on every mint, and the admin withdrawal from the pool reserve.
///
/// Every mint here is the fixture's ATM up-range at a far expiry, a single finite
/// leg whose fee binds at the fixture's 0.005 minimum fee, so the trading fee is
/// exactly `quantity / 200` and every subsidy below is hand arithmetic on that.
#[test_only]
module deepbook_predict::fee_incentive_flow_tests;

use deepbook_predict::{
    constants,
    expiry_market::MintQuote,
    flow_test_helpers as helpers,
    plp::{Self, PoolVault},
    protocol_config::{Self, ProtocolConfig},
    test_constants,
    vault_events
};
use std::{bcs, unit_test::{assert_eq, destroy}};
use sui::{event, test_scenario::return_shared};
use usdc::usdc::USDC;

/// Sponsor amount deliberately above the minimum sponsorship and below the
/// per-market live target, so one rebalance allocates it all.
const SPONSOR_AMOUNT: u64 = 20_000_000;
const PARTIAL_WITHDRAWAL: u64 = 5_000_000;
const ZERO_WITHDRAWAL: u64 = 0;
/// 20e6 sponsored - 5e6 withdrawn.
const RESERVE_AFTER_PARTIAL_WITHDRAWAL: u64 = 15_000_000;

/// A market holds at most fee_incentive_live_target_rate (2%) of its cadence's
/// max_expiry_allocation (250,000 USDC) at a time: 0.02 * 250e9 = 5e9.
const LIVE_TARGET: u64 = 5_000_000_000;
/// Sponsored on top of a full live target, so it stays in the pool reserve.
const RESERVE_ABOVE_LIVE_TARGET: u64 = 30_000_000;

/// Allocation-rate fixture, as shares of the same 250,000 USDC allocation cap.
/// 5%: 0.05 * 250e9 = 12.5e9.
const RAISED_LIVE_TARGET_RATE: u64 = 50_000_000;
const RAISED_LIVE_TARGET: u64 = 12_500_000_000;
/// 1%: 0.01 * 250e9 = 2.5e9.
const ONE_PERCENT_RATE: u64 = 10_000_000;
const ONE_PERCENT_OF_ALLOCATION: u64 = 2_500_000_000;
/// The shipped 2% live target and 10% lifetime cap, restored after a test lowers them.
const DEFAULT_LIVE_TARGET_RATE: u64 = 20_000_000;
const DEFAULT_LIFETIME_CAP_RATE: u64 = 100_000_000;
const ZERO_LIVE_TARGET_RATE: u64 = 0;
/// More than any allocation below, so the reserve never limits it.
const LARGE_SPONSORSHIP: u64 = 20_000_000_000;

/// The minimum sponsorship, 10 USDC. Fully allocated by one rebalance.
const ALLOCATED_BALANCE: u64 = 10_000_000;

/// Fee on the `mint_quantity()` (1e9) ATM mint: 0.005 * 1e9.
const MIN_TRADING_FEE: u64 = 5_000_000;
/// Four times `mint_quantity()`, and its fee: 0.005 * 4e9.
const QUADRUPLE_QUANTITY: u64 = 4_000_000_000;
const QUADRUPLE_QUANTITY_TRADING_FEE: u64 = 20_000_000;

/// Subsidy rates, in FLOAT_SCALING.
const ZERO_RATE: u64 = 0;
const RAISED_RATE: u64 = 400_000_000;
/// The ceiling, 50%.
const MAX_RATE: u64 = 500_000_000;

/// 0.2 (the shipped rate) * MIN_TRADING_FEE.
const DEFAULT_RATE_SUBSIDY: u64 = 1_000_000;
/// 0.4 * MIN_TRADING_FEE.
const RAISED_RATE_SUBSIDY: u64 = 2_000_000;
/// 10e6 allocated - 1e6 at the default rate - 2e6 at the raised rate.
const BALANCE_AFTER_DEFAULT_THEN_RAISED: u64 = 7_000_000;
/// 0.5 * MIN_TRADING_FEE.
const MAX_RATE_SUBSIDY: u64 = 2_500_000;
/// 10e6 allocated - 2.5e6 at the ceiling.
const BALANCE_AFTER_ONE_MAX_SUBSIDY: u64 = 7_500_000;

/// Genesis liquidity for the no-market flush: the mark is idle alone.
const BOOTSTRAP_LIQUIDITY: u64 = 100_000_000;
const ONE_EVENT: u64 = 1;

/// BCS mirror of `vault_events::FeeIncentivesWithdrawn`, so the wire schema is
/// asserted without adding production getters solely for tests.
public struct ExpectedFeeIncentivesWithdrawn has copy, drop {
    pool_vault_id: ID,
    amount: u64,
    reserve_after: u64,
}

// === Sponsorship and allocation ===

#[test]
fun sponsor_fee_incentives_increases_reserve_without_idle_nav() {
    let mut fx = helpers::setup_market_default();
    let expiry_id = fx.create_expiry(test_constants::default_expiry_ms());
    fx.scenario_mut().next_tx(test_constants::admin());
    let mut market = fx.take_market_bundle(expiry_id);

    fx.sponsor_fee_incentives_bundle(&mut market, SPONSOR_AMOUNT);

    assert_eq!(helpers::vault(&market).fee_incentive_reserve(), SPONSOR_AMOUNT);
    assert_eq!(helpers::vault(&market).idle_balance(), 0);
    assert_eq!(helpers::vault(&market).plp_total_supply(), 0);
    helpers::return_market_bundle(market);
    fx.finish();
}

#[test, expected_failure(abort_code = plp::EBelowMinFeeIncentiveSponsorship)]
fun sponsor_fee_incentives_below_minimum_aborts() {
    let mut fx = helpers::setup_market_default();
    let expiry_id = fx.create_expiry(test_constants::default_expiry_ms());
    fx.scenario_mut().next_tx(test_constants::admin());
    let mut market = fx.take_market_bundle(expiry_id);

    fx.sponsor_fee_incentives_bundle(&mut market, constants::min_fee_incentive_sponsorship!() - 1);

    abort 999
}

#[test]
fun live_rebalance_allocates_fee_incentives_without_cash_top_up() {
    let mut fx = helpers::setup_market_default();
    let expiry_id = fx.create_expiry(test_constants::default_expiry_ms());
    fx.scenario_mut().next_tx(test_constants::admin());
    let mut market = fx.take_market_bundle(expiry_id);
    fx.sponsor_fee_incentives_bundle(&mut market, SPONSOR_AMOUNT);

    fx.rebalance_expiry_cash_bundle(&mut market);

    assert_eq!(helpers::vault(&market).fee_incentive_reserve(), 0);
    assert_eq!(helpers::vault(&market).idle_balance(), 0);
    assert_eq!(helpers::market(&market).fee_incentive_balance(), SPONSOR_AMOUNT);
    assert_eq!(helpers::market(&market).cash_balance(), 0);
    helpers::return_market_bundle(market);
    fx.finish();
}

// === Admin-set subsidy rate ===

/// The rate is read at mint time, so a change reaches a market that already has
/// positions: the first mint is subsidized at the shipped 20%, the second at the
/// newly set 40%, on the same market in the same transaction.
#[test]
fun configured_rate_reprices_the_subsidy_on_a_market_already_trading() {
    let (mut fx, expiry_id, trader) = sponsored_market();
    let mut market = fx.take_market_bundle(expiry_id);
    let mut account = fx.take_account_bundle(&trader);

    let at_default = quote_atm(&mut fx, &market, test_constants::mint_quantity());
    assert_eq!(at_default.trading_fee(), MIN_TRADING_FEE);
    assert_eq!(at_default.fee_incentive_subsidy(), DEFAULT_RATE_SUBSIDY);
    mint_atm(&mut fx, &mut market, &mut account, &at_default);

    fx.set_fee_incentive_subsidy_rate_bundle(&mut market, RAISED_RATE);
    let balance_before = fx.account_balance_bundle<USDC>(&account);
    let cash_before = helpers::market(&market).cash_balance();

    let at_raised = quote_atm(&mut fx, &market, test_constants::mint_quantity());
    assert_eq!(at_raised.trading_fee(), MIN_TRADING_FEE);
    assert_eq!(at_raised.fee_incentive_subsidy(), RAISED_RATE_SUBSIDY);
    assert_eq!(
        at_raised.all_in_cost(),
        at_raised.premium() + MIN_TRADING_FEE - RAISED_RATE_SUBSIDY,
    );
    mint_atm(&mut fx, &mut market, &mut account, &at_raised);

    // The trader pays the unsubsidized part; the market still collects the whole
    // fee, the rest drawn from its incentive balance.
    assert_eq!(fx.account_balance_bundle<USDC>(&account), balance_before - at_raised.all_in_cost());
    assert_eq!(
        helpers::market(&market).cash_balance(),
        cash_before + at_raised.premium() + MIN_TRADING_FEE,
    );
    assert_eq!(helpers::market(&market).fee_incentive_balance(), BALANCE_AFTER_DEFAULT_THEN_RAISED);
    helpers::assert_market_backed_bundle(&market);

    helpers::return_account_bundle(account);
    helpers::return_market_bundle(market);
    fx.finish();
}

/// A zero rate pauses spending without moving the incentives: the trader pays the
/// full fee and the market's allocated balance stays where it was.
#[test]
fun zero_rate_stops_spending_without_moving_incentives() {
    let (mut fx, expiry_id, trader) = sponsored_market();
    let mut market = fx.take_market_bundle(expiry_id);
    let mut account = fx.take_account_bundle(&trader);
    fx.set_fee_incentive_subsidy_rate_bundle(&mut market, ZERO_RATE);
    let balance_before = fx.account_balance_bundle<USDC>(&account);

    let quote = quote_atm(&mut fx, &market, test_constants::mint_quantity());
    assert_eq!(quote.trading_fee(), MIN_TRADING_FEE);
    assert_eq!(quote.fee_incentive_subsidy(), 0);
    assert_eq!(quote.all_in_cost(), quote.premium() + MIN_TRADING_FEE);
    mint_atm(&mut fx, &mut market, &mut account, &quote);

    assert_eq!(fx.account_balance_bundle<USDC>(&account), balance_before - quote.all_in_cost());
    assert_eq!(helpers::market(&market).fee_incentive_balance(), ALLOCATED_BALANCE);
    assert_eq!(helpers::vault(&market).fee_incentive_reserve(), 0);
    helpers::assert_market_backed_bundle(&market);

    helpers::return_account_bundle(account);
    helpers::return_market_bundle(market);
    fx.finish();
}

/// At the 50% ceiling the trader still pays half of every fee while the balance
/// covers the other half, the balance caps the subsidy once it no longer does, and
/// an exhausted balance subsidizes nothing.
#[test]
fun max_rate_leaves_the_trader_half_the_fee_until_the_balance_runs_out() {
    let (mut fx, expiry_id, trader) = sponsored_market();
    let mut market = fx.take_market_bundle(expiry_id);
    let mut account = fx.take_account_bundle(&trader);
    fx.set_fee_incentive_subsidy_rate_bundle(&mut market, MAX_RATE);

    // The 10e6 balance covers half of the 5e6 fee.
    let halved = quote_atm(&mut fx, &market, test_constants::mint_quantity());
    assert_eq!(halved.fee_incentive_subsidy(), MAX_RATE_SUBSIDY);
    assert_eq!(halved.all_in_cost(), halved.premium() + MIN_TRADING_FEE - MAX_RATE_SUBSIDY);
    mint_atm(&mut fx, &mut market, &mut account, &halved);
    assert_eq!(helpers::market(&market).fee_incentive_balance(), BALANCE_AFTER_ONE_MAX_SUBSIDY);

    // Half of a 20e6 fee is 10e6; the remaining 7.5e6 caps it.
    let capped = quote_atm(&mut fx, &market, QUADRUPLE_QUANTITY);
    assert_eq!(capped.trading_fee(), QUADRUPLE_QUANTITY_TRADING_FEE);
    assert_eq!(capped.fee_incentive_subsidy(), BALANCE_AFTER_ONE_MAX_SUBSIDY);
    assert_eq!(
        capped.all_in_cost(),
        capped.premium() + QUADRUPLE_QUANTITY_TRADING_FEE - BALANCE_AFTER_ONE_MAX_SUBSIDY,
    );
    mint_atm(&mut fx, &mut market, &mut account, &capped);
    assert_eq!(helpers::market(&market).fee_incentive_balance(), 0);

    let unsubsidized = quote_atm(&mut fx, &market, test_constants::mint_quantity());
    assert_eq!(unsubsidized.fee_incentive_subsidy(), 0);
    assert_eq!(unsubsidized.all_in_cost(), unsubsidized.premium() + MIN_TRADING_FEE);
    mint_atm(&mut fx, &mut market, &mut account, &unsubsidized);

    assert_eq!(
        fx.account_balance_bundle<USDC>(&account),
        test_constants::default_manager_deposit()
            - halved.all_in_cost()
            - capped.all_in_cost()
            - unsubsidized.all_in_cost(),
    );
    helpers::assert_market_backed_bundle(&market);

    helpers::return_account_bundle(account);
    helpers::return_market_bundle(market);
    fx.finish();
}

// === Admin withdrawal ===

#[test]
fun admin_withdraws_part_of_the_reserve_and_reports_the_reserve_after() {
    let mut fx = helpers::setup_market_default();
    let expiry_id = fx.create_expiry(test_constants::default_expiry_ms());
    fx.scenario_mut().next_tx(test_constants::admin());
    let mut market = fx.take_market_bundle(expiry_id);
    fx.sponsor_fee_incentives_bundle(&mut market, SPONSOR_AMOUNT);

    let withdrawn = fx.withdraw_fee_incentives_bundle(&mut market, PARTIAL_WITHDRAWAL);

    assert_eq!(withdrawn.value(), PARTIAL_WITHDRAWAL);
    assert_eq!(helpers::vault(&market).fee_incentive_reserve(), RESERVE_AFTER_PARTIAL_WITHDRAWAL);
    // The reserve is not pool capital, so withdrawing it leaves idle untouched.
    assert_eq!(helpers::vault(&market).idle_balance(), 0);
    let events = event::events_by_type<vault_events::FeeIncentivesWithdrawn>();
    assert_eq!(events.length(), ONE_EVENT);
    let expected = ExpectedFeeIncentivesWithdrawn {
        pool_vault_id: fx.vault_id(),
        amount: PARTIAL_WITHDRAWAL,
        reserve_after: RESERVE_AFTER_PARTIAL_WITHDRAWAL,
    };
    assert_eq!(bcs::to_bytes(&events[0]), bcs::to_bytes(&expected));

    destroy(withdrawn);
    helpers::return_market_bundle(market);
    fx.finish();
}

/// Withdrawing exactly the reserve empties it, so the next rebalance has nothing
/// to allocate.
#[test]
fun admin_withdraws_the_whole_reserve_so_rebalance_allocates_nothing() {
    let mut fx = helpers::setup_market_default();
    let expiry_id = fx.create_expiry(test_constants::default_expiry_ms());
    fx.scenario_mut().next_tx(test_constants::admin());
    let mut market = fx.take_market_bundle(expiry_id);
    fx.sponsor_fee_incentives_bundle(&mut market, SPONSOR_AMOUNT);

    let withdrawn = fx.withdraw_fee_incentives_bundle(&mut market, SPONSOR_AMOUNT);
    assert_eq!(withdrawn.value(), SPONSOR_AMOUNT);
    assert_eq!(helpers::vault(&market).fee_incentive_reserve(), 0);

    fx.rebalance_expiry_cash_bundle(&mut market);
    assert_eq!(helpers::market(&market).fee_incentive_balance(), 0);

    destroy(withdrawn);
    helpers::return_market_bundle(market);
    fx.finish();
}

/// A zero withdrawal is accepted as a no-op: an empty coin, the reserve untouched,
/// and an event reporting the unchanged reserve.
#[test]
fun zero_withdrawal_returns_an_empty_coin_and_leaves_the_reserve() {
    let mut fx = helpers::setup_market_default();
    let expiry_id = fx.create_expiry(test_constants::default_expiry_ms());
    fx.scenario_mut().next_tx(test_constants::admin());
    let mut market = fx.take_market_bundle(expiry_id);
    fx.sponsor_fee_incentives_bundle(&mut market, SPONSOR_AMOUNT);

    let withdrawn = fx.withdraw_fee_incentives_bundle(&mut market, ZERO_WITHDRAWAL);

    assert_eq!(withdrawn.value(), ZERO_WITHDRAWAL);
    assert_eq!(helpers::vault(&market).fee_incentive_reserve(), SPONSOR_AMOUNT);
    let events = event::events_by_type<vault_events::FeeIncentivesWithdrawn>();
    assert_eq!(events.length(), ONE_EVENT);
    let expected = ExpectedFeeIncentivesWithdrawn {
        pool_vault_id: fx.vault_id(),
        amount: ZERO_WITHDRAWAL,
        reserve_after: SPONSOR_AMOUNT,
    };
    assert_eq!(bcs::to_bytes(&events[0]), bcs::to_bytes(&expected));

    destroy(withdrawn);
    helpers::return_market_bundle(market);
    fx.finish();
}

#[test, expected_failure(abort_code = plp::EInsufficientFeeIncentiveReserve)]
fun withdraw_above_the_reserve_aborts() {
    let mut fx = helpers::setup_market_default();
    let expiry_id = fx.create_expiry(test_constants::default_expiry_ms());
    fx.scenario_mut().next_tx(test_constants::admin());
    let mut market = fx.take_market_bundle(expiry_id);
    fx.sponsor_fee_incentives_bundle(&mut market, SPONSOR_AMOUNT);

    let _withdrawn = fx.withdraw_fee_incentives_bundle(&mut market, SPONSOR_AMOUNT + 1);

    abort 999
}

/// The withdrawal reaches the pool reserve only: incentives already allocated to a
/// live market stay in that market, and the reserve above the live target is all
/// that can be taken.
#[test]
fun withdraw_leaves_market_allocated_incentives_in_place() {
    let mut fx = helpers::setup_market_default();
    let expiry_id = fx.create_expiry(test_constants::default_expiry_ms());
    fx.scenario_mut().next_tx(test_constants::admin());
    let mut market = fx.take_market_bundle(expiry_id);
    fx.sponsor_fee_incentives_bundle(&mut market, LIVE_TARGET + RESERVE_ABOVE_LIVE_TARGET);
    fx.rebalance_expiry_cash_bundle(&mut market);
    assert_eq!(helpers::market(&market).fee_incentive_balance(), LIVE_TARGET);
    assert_eq!(helpers::vault(&market).fee_incentive_reserve(), RESERVE_ABOVE_LIVE_TARGET);

    let withdrawn = fx.withdraw_fee_incentives_bundle(&mut market, RESERVE_ABOVE_LIVE_TARGET);

    assert_eq!(withdrawn.value(), RESERVE_ABOVE_LIVE_TARGET);
    assert_eq!(helpers::vault(&market).fee_incentive_reserve(), 0);
    assert_eq!(helpers::market(&market).fee_incentive_balance(), LIVE_TARGET);

    destroy(withdrawn);
    helpers::return_market_bundle(market);
    fx.finish();
}

/// Market-allocated incentives are unreachable only until settlement: the
/// settled-market sweep returns them to the reserve, where the admin can take them.
#[test]
fun incentives_returned_at_settlement_become_withdrawable() {
    let (mut fx, expiry_id, _trader) = helpers::setup_live_market(
        test_constants::short_expiry_ms(),
        test_constants::default_live_price(),
    );
    let mut market = fx.take_market_bundle(expiry_id);
    fx.sponsor_fee_incentives_bundle(&mut market, SPONSOR_AMOUNT);
    fx.rebalance_expiry_cash_bundle(&mut market);
    assert_eq!(helpers::market(&market).fee_incentive_balance(), SPONSOR_AMOUNT);
    assert_eq!(helpers::vault(&market).fee_incentive_reserve(), 0);

    fx.set_clock_for_testing(test_constants::short_expiry_ms());
    fx.insert_exact_settlement_spot_bundle(&mut market, test_constants::default_live_price());
    assert!(fx.try_settle_bundle(&mut market));
    fx.rebalance_expiry_cash_bundle(&mut market);
    assert_eq!(helpers::market(&market).fee_incentive_balance(), 0);
    assert_eq!(helpers::vault(&market).fee_incentive_reserve(), SPONSOR_AMOUNT);

    let withdrawn = fx.withdraw_fee_incentives_bundle(&mut market, SPONSOR_AMOUNT);

    assert_eq!(withdrawn.value(), SPONSOR_AMOUNT);
    assert_eq!(helpers::vault(&market).fee_incentive_reserve(), 0);

    destroy(withdrawn);
    helpers::return_market_bundle(market);
    fx.finish();
}

/// Not gated on the valuation flag, in either stage of a flush: half is withdrawn
/// inside the still-open snapshot stage, half after the seal. The reserve is outside
/// NAV, so the flush still marks the pool at its bootstrap idle alone.
#[test]
fun withdraw_during_a_flush_leaves_the_frozen_mark_unchanged() {
    let mut fx = helpers::setup_market_default();
    fx.bootstrap_lock(BOOTSTRAP_LIQUIDITY);
    fx.scenario_mut().next_tx(test_constants::admin());
    let mut config = fx.scenario_mut().take_shared<ProtocolConfig>();
    let mut vault = fx.scenario_mut().take_shared_by_id<PoolVault>(fx.vault_id());
    fx.sponsor_fee_incentives(&mut vault, &config, SPONSOR_AMOUNT);

    let stage = fx.start_flush(&mut config, &mut vault);
    let in_snapshot = fx.withdraw_fee_incentives(&mut vault, &config, SPONSOR_AMOUNT / 2);
    helpers::seal_snapshot(stage, &mut vault, &mut config);
    assert!(config.valuation_in_progress());
    let after_seal = fx.withdraw_fee_incentives(&mut vault, &config, SPONSOR_AMOUNT / 2);

    assert_eq!(in_snapshot.value() + after_seal.value(), SPONSOR_AMOUNT);
    assert_eq!(vault.fee_incentive_reserve(), 0);
    assert_eq!(fx.finish_flush(&mut vault, &mut config), BOOTSTRAP_LIQUIDITY);

    destroy(in_snapshot);
    destroy(after_seal);
    return_shared(vault);
    return_shared(config);
    fx.finish();
}

#[test, expected_failure(abort_code = protocol_config::EProtocolFrozen)]
fun withdraw_while_frozen_aborts() {
    let mut fx = helpers::setup_market_default();
    let expiry_id = fx.create_expiry(test_constants::default_expiry_ms());
    fx.scenario_mut().next_tx(test_constants::admin());
    let mut market = fx.take_market_bundle(expiry_id);
    fx.sponsor_fee_incentives_bundle(&mut market, SPONSOR_AMOUNT);
    fx.set_frozen_bundle(&mut market, true);

    let _withdrawn = fx.withdraw_fee_incentives_bundle(&mut market, SPONSOR_AMOUNT);

    abort 999
}

// === Admin-set allocation rates ===

/// The live target is read at every rebalance, so raising it tops a market already
/// allocated at the shipped 2% up to the new share.
#[test]
fun raised_live_target_tops_an_existing_market_up_to_the_new_share() {
    let mut fx = helpers::setup_market_default();
    let expiry_id = fx.create_expiry(test_constants::default_expiry_ms());
    fx.scenario_mut().next_tx(test_constants::admin());
    let mut market = fx.take_market_bundle(expiry_id);
    fx.sponsor_fee_incentives_bundle(&mut market, LARGE_SPONSORSHIP);
    fx.rebalance_expiry_cash_bundle(&mut market);
    assert_eq!(helpers::market(&market).fee_incentive_balance(), LIVE_TARGET);
    helpers::return_market_bundle(market);

    fx.set_fee_incentive_live_target_rate(RAISED_LIVE_TARGET_RATE);
    let mut market = fx.take_market_bundle(expiry_id);
    fx.rebalance_expiry_cash_bundle(&mut market);

    assert_eq!(helpers::market(&market).fee_incentive_balance(), RAISED_LIVE_TARGET);
    assert_eq!(
        helpers::vault(&market).fee_incentive_reserve(),
        LARGE_SPONSORSHIP - RAISED_LIVE_TARGET,
    );
    helpers::return_market_bundle(market);
    fx.finish();
}

/// Lowering the live target never takes an allocated balance back: the market keeps
/// what it holds and simply receives nothing more.
#[test]
fun lowered_live_target_leaves_an_allocated_balance_in_place() {
    let mut fx = helpers::setup_market_default();
    let expiry_id = fx.create_expiry(test_constants::default_expiry_ms());
    fx.scenario_mut().next_tx(test_constants::admin());
    let mut market = fx.take_market_bundle(expiry_id);
    fx.sponsor_fee_incentives_bundle(&mut market, LARGE_SPONSORSHIP);
    fx.rebalance_expiry_cash_bundle(&mut market);
    helpers::return_market_bundle(market);

    fx.set_fee_incentive_live_target_rate(ONE_PERCENT_RATE);
    let mut market = fx.take_market_bundle(expiry_id);
    fx.rebalance_expiry_cash_bundle(&mut market);

    assert_eq!(helpers::market(&market).fee_incentive_balance(), LIVE_TARGET);
    assert_eq!(helpers::vault(&market).fee_incentive_reserve(), LARGE_SPONSORSHIP - LIVE_TARGET);
    helpers::return_market_bundle(market);
    fx.finish();
}

/// A zero live target stops allocation without touching the reserve, so the whole
/// sponsorship stays in the pool and withdrawable.
#[test]
fun zero_live_target_stops_allocation_and_keeps_the_reserve_withdrawable() {
    let mut fx = helpers::setup_market_default();
    let expiry_id = fx.create_expiry(test_constants::default_expiry_ms());
    fx.set_fee_incentive_live_target_rate(ZERO_LIVE_TARGET_RATE);
    let mut market = fx.take_market_bundle(expiry_id);
    fx.sponsor_fee_incentives_bundle(&mut market, SPONSOR_AMOUNT);

    fx.rebalance_expiry_cash_bundle(&mut market);

    assert_eq!(helpers::market(&market).fee_incentive_balance(), 0);
    assert_eq!(helpers::vault(&market).fee_incentive_reserve(), SPONSOR_AMOUNT);
    let withdrawn = fx.withdraw_fee_incentives_bundle(&mut market, SPONSOR_AMOUNT);
    assert_eq!(withdrawn.value(), SPONSOR_AMOUNT);

    destroy(withdrawn);
    helpers::return_market_bundle(market);
    fx.finish();
}

/// The lifetime cap is snapshotted when a market is created. A market created under
/// a 1% cap stays capped there after the template is raised back to 10%, while a
/// market created afterwards gets the raised cap.
#[test]
fun lifetime_cap_rate_is_snapshotted_when_the_market_is_created() {
    let mut fx = helpers::setup_market_default();
    // Lower the target first so the cap can follow it down.
    fx.set_fee_incentive_live_target_rate(ONE_PERCENT_RATE);
    fx.set_template_fee_incentive_lifetime_cap_rate(ONE_PERCENT_RATE);
    let capped_id = fx.create_expiry(test_constants::default_expiry_ms());
    fx.scenario_mut().next_tx(test_constants::admin());
    let mut capped = fx.take_market_bundle(capped_id);
    fx.sponsor_fee_incentives_bundle(&mut capped, LARGE_SPONSORSHIP);
    fx.rebalance_expiry_cash_bundle(&mut capped);
    // The 1% target and the 1% cap coincide.
    assert_eq!(helpers::market(&capped).fee_incentive_balance(), ONE_PERCENT_OF_ALLOCATION);
    helpers::return_market_bundle(capped);

    // Raise the cap first, then the target, back to the shipped shares.
    fx.set_template_fee_incentive_lifetime_cap_rate(DEFAULT_LIFETIME_CAP_RATE);
    fx.set_fee_incentive_live_target_rate(DEFAULT_LIVE_TARGET_RATE);
    let later_id = fx.create_expiry(test_constants::default_expiry_ms() + constants::one_day_ms!());

    // The 2% target asks for another 2.5e9, but this market's 1% cap is spent.
    let mut capped = fx.take_market_bundle(capped_id);
    fx.rebalance_expiry_cash_bundle(&mut capped);
    assert_eq!(helpers::market(&capped).fee_incentive_balance(), ONE_PERCENT_OF_ALLOCATION);
    helpers::return_market_bundle(capped);

    fx.scenario_mut().next_tx(test_constants::admin());
    let mut later = fx.take_market_bundle(later_id);
    fx.rebalance_expiry_cash_bundle(&mut later);
    assert_eq!(helpers::market(&later).fee_incentive_balance(), LIVE_TARGET);
    assert_eq!(
        helpers::vault(&later).fee_incentive_reserve(),
        LARGE_SPONSORSHIP - ONE_PERCENT_OF_ALLOCATION - LIVE_TARGET,
    );
    helpers::return_market_bundle(later);
    fx.finish();
}

// === Helpers ===

/// A far-expiry live market whose trader holds the large default deposit, with the
/// minimum sponsorship allocated into the market by one rebalance.
fun sponsored_market(): (helpers::Fixture, ID, helpers::Trader) {
    let (mut fx, expiry_id, trader) = helpers::setup_everything();
    fx.scenario_mut().next_tx(test_constants::alice());
    let mut market = fx.take_market_bundle(expiry_id);
    fx.sponsor_fee_incentives_bundle(&mut market, constants::min_fee_incentive_sponsorship!());
    fx.rebalance_expiry_cash_bundle(&mut market);
    assert_eq!(helpers::market(&market).fee_incentive_balance(), ALLOCATED_BALANCE);
    helpers::return_market_bundle(market);
    fx.scenario_mut().next_tx(test_constants::alice());
    (fx, expiry_id, trader)
}

fun quote_atm(fx: &mut helpers::Fixture, market: &helpers::MarketBundle, quantity: u64): MintQuote {
    fx.quote_mint_bundle(market, helpers::strike_tick(), constants::pos_inf_tick!(), quantity)
}

/// Mint exactly what `quote` priced, capped at its all-in cost so the mint aborts
/// if execution charges more than the quote reported.
fun mint_atm(
    fx: &mut helpers::Fixture,
    market: &mut helpers::MarketBundle,
    account: &mut helpers::AccountBundle,
    quote: &MintQuote,
) {
    fx.mint_exact_quantity_bundle(
        market,
        account,
        helpers::strike_tick(),
        constants::pos_inf_tick!(),
        quote.quantity(),
        quote.all_in_cost(),
        std::u64::max_value!(),
    );
}
