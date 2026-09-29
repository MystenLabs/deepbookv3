// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Vault-level flow coverage for the async LP layer: the genesis `lock_capital` mint,
/// the bootstrap precondition on the flush, the request-attempt count that
/// `finish_flush` reads from `ProtocolConfig`, and the no-shares USDC addition that
/// raises the mark without touching the share base.
///
/// The fixture shares an empty `sui::accumulator::AccumulatorRoot` through
/// `accumulator_support` (the framework exposes `create_for_testing`, callable as
/// `@0x0`), so the attempt-count tests drive the production `plp::request_supply`
/// against a real `AccountBundle` and cover the account-custody pull and the queue
/// write on the same path as the flush's refund-or-carry decision. Not covered here: the
/// vault-level `cancel_*` entrypoints, and `request_withdraw` — a unit-test root carries
/// no settlement funds (`packages/account/ACCUMULATOR_TESTING_STATUS.md`), so a flush
/// fill's PLP never reaches account custody to be withdrawn. Flush valuation is
/// covered in `pool_valuation_flow_tests`, while the drain economics (proportional
/// shares, FIFO-until-dry, per-queue budgets, frozen mark) and the cancel refund +
/// recipient check are covered root-free against a standalone `LpBook` in
/// `lp_book_tests`.
#[test_only]
module deepbook_predict::lp_flow_tests;

use deepbook_predict::{
    constants::{
        Self,
        min_bootstrap_liquidity as min_bootstrap,
        min_supply_request as min_supply,
        min_usdc_contribution as min_contribution,
    },
    flow_test_helpers as helpers,
    plp::{Self, PoolVault},
    protocol_config::{Self, ProtocolConfig},
    test_constants,
    vault_events
};
use std::unit_test::assert_eq;
use sui::{event, test_scenario::return_shared};

/// 5% in FLOAT_SCALING — the `max_plp_fee_rate` ceiling.
const MAX_PLP_FEE_RATE: u64 = 50_000_000;
/// 20 bps in FLOAT_SCALING — the shipped `default_plp_withdraw_fee_rate`.
const DEFAULT_WITHDRAW_FEE_RATE: u64 = 2_000_000;
/// A `min_supply!()` deposit filling at a 1.0 mark against the genesis lock, charged
/// the 5% ceiling: fee = 500_000, so 9_500_000 is minted on top of the 10_000_000 lock.
const SUPPLY_AFTER_MAX_FEE: u64 = 19_500_000;

/// Account funding for the LP staging the request; well above `min_supply_request`.
const LP_DEPOSIT: u64 = 1_000_000_000;
/// No fill limit, so only pool capacity can stop the request.
const NO_MIN_OUT: u64 = 0;
/// A no-shares contribution comfortably above `min_usdc_contribution` and below the
/// price ceiling, distinct from every other figure here so an assertion cannot pass on
/// the wrong quantity.
const CONTRIBUTION: u64 = 25_000_000;
/// The largest contribution the genesis-lock pool accepts: 10 USDC of idle over 10 PLP
/// of supply, and a contribution may price the pool at most 10 USDC/PLP, so pool cash
/// may reach 100 USDC.
const CONTRIBUTION_AT_CEILING: u64 = 90_000_000;
/// A deposit the ceiling mark does not divide: at 10 USDC/PLP it buys 1.0000001 PLP,
/// which floors to 1 PLP, so the pool keeps the micro-USDC of dust.
const UNEVEN_DEPOSIT: u64 = 10_000_001;
/// A deposit five times the pool it enters, so a supply fee charged on it moves the
/// mark most of the way to the per-flush maximum of `1/(1 - rate)`.
const LARGE_DEPOSIT: u64 = 500_000_000;
/// 50 USDC of UP contracts: backed by the 100 USDC a ceiling-parked genesis pool has
/// deployed into its one market, and charged the flow fixture's 0.5% minimum trading
/// fee, 0.25 USDC, which the mark counts and the contribution guard cannot see.
const FEE_PROBE_QUANTITY: u64 = 50_000_000;

// === Genesis lock + bootstrapped gates ===

#[test]
fun lock_capital_mints_locked_liquidity_and_funds_idle() {
    let mut fx = helpers::setup_market_default();
    fx.bootstrap_lock(min_supply!());

    fx.scenario_mut().next_tx(test_constants::admin());
    let vault = fx.scenario_mut().take_shared_by_id<PoolVault>(fx.vault_id());
    // The lock mints `amount` permanent PLP (held by the book, delivered to no one) and
    // joins the USDC into idle, so total_supply == idle == amount at a 1.0 mark.
    assert_eq!(vault.plp_total_supply(), min_supply!());
    assert_eq!(vault.idle_balance(), min_supply!());
    assert_eq!(vault.supply_requests_pending(), 0);

    return_shared(vault);
    fx.finish();
}

#[test, expected_failure(abort_code = plp::EAlreadyBootstrapped)]
fun lock_capital_twice_aborts() {
    let mut fx = helpers::setup_market_default();
    fx.bootstrap_lock(min_supply!());
    fx.bootstrap_lock(min_supply!()); // total_supply is already > 0
    abort 999
}

#[test, expected_failure(abort_code = plp::EBelowMinBootstrapLiquidity)]
fun lock_capital_below_floor_aborts() {
    let mut fx = helpers::setup_market_default();
    fx.bootstrap_lock(min_bootstrap!() - 1); // below the genesis floor
    abort 999
}

#[test, expected_failure(abort_code = plp::ENotBootstrapped)]
fun flush_before_bootstrap_aborts() {
    let mut fx = helpers::setup_market_default();
    flush(&mut fx); // start_pool_valuation requires total_supply > 0
    abort 999
}

// === Attempt count is read from config by the flush ===

/// `finish_flush` must take the attempt count from `ProtocolConfig`, not from a
/// compiled constant. Staged through the production `request_supply` + flush path
/// because the drain-level tests pass the value in by hand and so structurally cannot
/// see a disconnected knob. Runs on a pool with no live markets, so the mark is simply
/// idle over supply and the request can only leave the queue by missing its limit.
#[test]
fun flush_refunds_limit_miss_at_the_default_attempt_count() {
    let (mut fx, mut account) = setup_pool_with_lp();
    queue_unfillable_supply(&mut fx, &mut account);
    assert_pending_and_supply(&mut fx, 1, min_supply!());

    flush(&mut fx);

    // Refunded on its first miss: queue empty, and the genesis lock is all that exists.
    assert_pending_and_supply(&mut fx, 0, min_supply!());

    helpers::return_account_bundle(account);
    fx.finish();
}

/// The same request against a raised attempt count survives its first two flushes,
/// which is only possible if the flush actually reads the configured value.
#[test]
fun flush_carries_limit_miss_when_admin_raises_the_attempt_count() {
    let (mut fx, mut account) = setup_pool_with_lp();
    set_attempts(&mut fx, 3);
    queue_unfillable_supply(&mut fx, &mut account);

    flush(&mut fx);
    // Still queued after one miss, because the admin allowed three attempts.
    assert_pending_and_supply(&mut fx, 1, min_supply!());

    flush(&mut fx);
    assert_pending_and_supply(&mut fx, 1, min_supply!());

    // The third miss exhausts the allowance and refunds it.
    flush(&mut fx);
    assert_pending_and_supply(&mut fx, 0, min_supply!());

    helpers::return_account_bundle(account);
    fx.finish();
}

// === Pool-value cap is read from config by the flush ===

/// The cap must reach the drain from `ProtocolConfig`, not a constant. The genesis
/// lock puts pool value at 10 USDC; a 20 USDC cap leaves 10 of headroom, which the
/// first deposit exactly fills, so the next identical deposit finds no room and waits.
#[test]
fun flush_holds_a_supply_that_would_breach_the_configured_pool_cap() {
    let (mut fx, mut account) = setup_pool_with_lp();
    // Isolate the cap. Redundant against today's zero default, kept so a future
    // non-zero supply default cannot silently shift every figure below.
    set_supply_fee(&mut fx, 0);
    set_max_pool_value(&mut fx, 20_000_000);
    // Consume the whole 10 USDC of headroom first.
    queue_supply(&mut fx, &mut account, NO_MIN_OUT);
    flush(&mut fx);
    assert_pending_and_supply(&mut fx, 0, 2 * min_supply!());
    queue_supply(&mut fx, &mut account, NO_MIN_OUT);

    flush(&mut fx);

    // Held for capacity: the second deposit minted nothing and is still queued.
    assert_pending_and_supply(&mut fx, 1, 2 * min_supply!());

    helpers::return_account_bundle(account);
    fx.finish();
}

#[test]
fun a_committed_supply_budget_is_honored_when_a_stranger_finishes() {
    let (mut fx, mut account) = setup_pool_with_lp();
    set_supply_fee(&mut fx, 0);
    // Two supply requests wait in the queue before the flush.
    queue_supply(&mut fx, &mut account, NO_MIN_OUT);
    queue_supply(&mut fx, &mut account, NO_MIN_OUT);

    // The operator commits a supply budget of ONE at the snapshot — the only place a
    // budget can be set now. This is the whole reason finish could be made
    // permissionless: a griefer can no longer pass a zero budget at finish to retire
    // the mark with nothing filled, because finish takes no budget at all.
    fx.scenario_mut().next_tx(test_constants::admin());
    let mut config = fx.scenario_mut().take_shared<ProtocolConfig>();
    let mut vault = fx.scenario_mut().take_shared_by_id<PoolVault>(fx.vault_id());
    let stage = fx.start_flush_with_budgets(
        &mut config,
        &mut vault,
        option::some(1),
        option::none(),
    );
    helpers::seal_snapshot(stage, &mut vault, &mut config);
    return_shared(config);
    return_shared(vault);

    // A stranger finishes. The budget committed at start still bounds the drain to one
    // request: the first deposit mints, the second stays queued — the stranger cannot
    // widen or zero it.
    fx.scenario_mut().next_tx(test_constants::alice());
    let mut config = fx.scenario_mut().take_shared<ProtocolConfig>();
    let mut vault = fx.scenario_mut().take_shared_by_id<PoolVault>(fx.vault_id());
    let _ = fx.finish_flush(&mut vault, &mut config);
    return_shared(config);
    return_shared(vault);

    assert_pending_and_supply(&mut fx, 1, 2 * min_supply!());

    helpers::return_account_bundle(account);
    fx.finish();
}

/// The control: the identical deposit fills when the pool is uncapped, so the test
/// above is measuring the cap rather than some other refund path.
#[test]
fun flush_fills_the_same_supply_when_the_pool_is_uncapped() {
    let (mut fx, mut account) = setup_pool_with_lp();
    set_supply_fee(&mut fx, 0);
    queue_supply(&mut fx, &mut account, NO_MIN_OUT);

    flush(&mut fx);

    // 10 USDC minted 1:1 against the 10 USDC genesis lock at a 1.0 mark.
    assert_pending_and_supply(&mut fx, 0, 2 * min_supply!());

    helpers::return_account_bundle(account);
    fx.finish();
}

// === Fee rates are read from config by the flush ===

/// Entry is free as shipped. This is the whole point of splitting the rate: a
/// deposit dilutes the pool's risk per dollar rather than concentrating it, so the
/// default supply leg charges nothing and a deposit mints its full 1:1 share.
#[test]
fun flush_does_not_charge_the_supply_leg_at_the_shipped_default() {
    let (mut fx, mut account) = setup_pool_with_lp();
    queue_supply(&mut fx, &mut account, NO_MIN_OUT);

    flush(&mut fx);

    assert_pending_and_supply(&mut fx, 0, 2 * min_supply!());

    helpers::return_account_bundle(account);
    fx.finish();
}

/// The supply rate must reach the drain from `ProtocolConfig`, not a compiled
/// constant. The drain-level tests in `lp_book_tests` hand the rates to
/// `new_flush_mark` by hand and so structurally cannot see a disconnected knob:
/// a `finish_flush` that ignored config and froze zero passes all of them.
#[test]
fun flush_charges_a_configured_supply_fee() {
    let (mut fx, mut account) = setup_pool_with_lp();
    set_supply_fee(&mut fx, MAX_PLP_FEE_RATE);
    queue_supply(&mut fx, &mut account, NO_MIN_OUT);

    flush(&mut fx);

    assert_pending_and_supply(&mut fx, 0, SUPPLY_AFTER_MAX_FEE);

    helpers::return_account_bundle(account);
    fx.finish();
}

/// The withdraw leg cannot be driven behaviourally here — a unit-test accumulator
/// root carries no settlement funds, so a fill's PLP never reaches account custody
/// to be withdrawn (see the module doc). This asserts the frozen pair the flush
/// actually took instead, which covers the withdraw rate's wiring and, because the
/// two rates are set to different values, would also catch them being swapped.
#[test]
fun flush_freezes_both_configured_fee_rates() {
    let mut fx = helpers::setup_market_default();
    fx.bootstrap_lock(min_supply!());

    // Shipped defaults first: entry free, exit charged.
    flush(&mut fx);
    let events = event::events_by_type<vault_events::FlushExecuted>();
    assert_eq!(events.length(), 1);
    let (supply_rate, withdraw_rate) = vault_events::flush_executed_fee_rates(&events[0]);
    assert_eq!(supply_rate, 0);
    assert_eq!(withdraw_rate, DEFAULT_WITHDRAW_FEE_RATE);

    // Then two distinct non-default values, so a swap cannot pass.
    set_supply_fee(&mut fx, MAX_PLP_FEE_RATE);
    set_withdraw_fee(&mut fx, 0);

    // `events_by_type` is scoped to the current transaction, so this is the second
    // flush's own event, not an accumulation.
    flush(&mut fx);
    let events = event::events_by_type<vault_events::FlushExecuted>();
    assert_eq!(events.length(), 1);
    let (supply_rate, withdraw_rate) = vault_events::flush_executed_fee_rates(&events[0]);
    assert_eq!(supply_rate, MAX_PLP_FEE_RATE);
    assert_eq!(withdraw_rate, 0);

    fx.finish();
}

// === No-shares USDC contributions ===

/// The whole contract of the entrypoint: the USDC lands in idle and the share base
/// does not move, so the value sits under an unchanged `total_supply`. Also pins where
/// it does NOT land — the fee-incentive reserve is a separate pool excluded from NAV,
/// and the profit basis is reserved for cash the pool sent to and got back from
/// expiries, so an outright gift is neither a debit nor a credit.
#[test]
fun add_usdc_to_plp_lands_in_idle_and_mints_nothing() {
    let mut fx = helpers::setup_market_default();
    fx.bootstrap_lock(min_supply!());

    contribute(&mut fx, CONTRIBUTION);

    fx.scenario_mut().next_tx(test_constants::alice());
    let vault = fx.scenario_mut().take_shared_by_id<PoolVault>(fx.vault_id());
    // 10 USDC genesis lock + 25 USDC contributed.
    assert_eq!(vault.idle_balance(), 35_000_000);
    assert_eq!(vault.plp_total_supply(), min_supply!());
    assert_eq!(vault.fee_incentive_reserve(), 0);
    assert_eq!(vault.protocol_reserve_balance(), 0);
    assert_eq!(vault.profit_basis_debits(), 0);
    assert_eq!(vault.profit_basis_credits(), 0);
    return_shared(vault);

    fx.finish();
}

/// The added value reaches existing holders, and only them. A 10 USDC contribution on top
/// of the 10 USDC genesis lock doubles the mark to 2 USDC per PLP with no new shares,
/// so the next 10 USDC deposit buys 5 PLP where it would have bought 10. The protocol
/// reserve takes 10% of expiry profit by default and none of this, because the profit
/// basis never saw it.
#[test]
fun add_usdc_to_plp_raises_the_mark_for_existing_holders() {
    let (mut fx, mut account) = setup_pool_with_lp();
    // Isolate the mark: a non-zero supply fee would shave the fill as well.
    set_supply_fee(&mut fx, 0);
    contribute(&mut fx, min_supply!());
    queue_supply(&mut fx, &mut account, NO_MIN_OUT);

    let pool_nav = flush_with_budgets(&mut fx, option::none(), option::none());

    // 20 USDC of idle priced against the 10 PLP the lock minted: no cut was withheld.
    assert_eq!(pool_nav, 20_000_000);
    // floor(10 USDC x 10 PLP / 20 USDC) = 5 PLP minted on top of the 10 PLP lock.
    assert_pending_and_supply(&mut fx, 0, 15_000_000);

    fx.scenario_mut().next_tx(test_constants::admin());
    let vault = fx.scenario_mut().take_shared_by_id<PoolVault>(fx.vault_id());
    // 10 locked + 10 contributed + the 10 the fill joined.
    assert_eq!(vault.idle_balance(), 30_000_000);
    assert_eq!(vault.protocol_reserve_balance(), 0);
    return_shared(vault);

    helpers::return_account_bundle(account);
    fx.finish();
}

/// The control for the test above: without the contribution the identical deposit mints
/// 1:1, so that test is measuring the contribution rather than some other fill path.
#[test]
fun the_same_deposit_mints_at_parity_without_a_contribution() {
    let (mut fx, mut account) = setup_pool_with_lp();
    set_supply_fee(&mut fx, 0);
    queue_supply(&mut fx, &mut account, NO_MIN_OUT);

    let pool_nav = flush_with_budgets(&mut fx, option::none(), option::none());

    assert_eq!(pool_nav, min_supply!());
    assert_pending_and_supply(&mut fx, 0, 2 * min_supply!());

    helpers::return_account_bundle(account);
    fx.finish();
}

/// A supply queued before the contribution is priced at the raised mark, not the mark that
/// stood when it was queued. The request carries a price floor, so an LP who needs the
/// pre-addition price says so with `min_plp_out` — here 10 PLP for 10 USDC, which the
/// doubled mark cannot meet, and the request is refunded instead of filled at 5.
#[test]
fun a_contribution_between_queueing_and_the_flush_can_miss_a_supply_limit() {
    let (mut fx, mut account) = setup_pool_with_lp();
    set_supply_fee(&mut fx, 0);
    queue_supply(&mut fx, &mut account, min_supply!());
    contribute(&mut fx, min_supply!());

    flush(&mut fx);

    // Refunded on its first miss: only the genesis lock exists, and the contribution stays.
    assert_pending_and_supply(&mut fx, 0, min_supply!());

    fx.scenario_mut().next_tx(test_constants::admin());
    let vault = fx.scenario_mut().take_shared_by_id<PoolVault>(fx.vault_id());
    assert_eq!(vault.idle_balance(), 20_000_000);
    return_shared(vault);

    helpers::return_account_bundle(account);
    fx.finish();
}

/// The entrypoint is permissionless, so the event is the only record of who funded a
/// contribution. Alice contributes here while the admin holds every cap; crediting the wrong
/// address would misattribute the whole incentive stream and no balance can see it.
#[test]
fun add_usdc_to_plp_credits_the_sender_in_its_event() {
    let mut fx = helpers::setup_market_default();
    fx.bootstrap_lock(min_supply!());

    contribute(&mut fx, CONTRIBUTION);

    let events = event::events_by_type<vault_events::UsdcAddedToPlp>();
    assert_eq!(events.length(), 1);
    let (contributor, amount) = vault_events::usdc_added_to_plp_fields(&events[0]);
    assert_eq!(contributor, test_constants::alice());
    assert_eq!(amount, CONTRIBUTION);

    fx.finish();
}

/// Contributions accumulate rather than replacing one another, and each is measured
/// against the pool cash the previous one left behind.
#[test]
fun contributions_accumulate_in_idle() {
    let mut fx = helpers::setup_market_default();
    fx.bootstrap_lock(min_supply!());

    contribute(&mut fx, CONTRIBUTION);
    contribute(&mut fx, CONTRIBUTION);

    fx.scenario_mut().next_tx(test_constants::alice());
    let vault = fx.scenario_mut().take_shared_by_id<PoolVault>(fx.vault_id());
    // 10 USDC lock + 25 + 25.
    assert_eq!(vault.idle_balance(), 60_000_000);
    assert_eq!(vault.plp_total_supply(), min_supply!());
    return_shared(vault);

    fx.finish();
}

/// A contribution raises pool value, so it eats the headroom `max_lp_pool_value`
/// leaves for supply fills. With a 30 USDC cap, the 10 USDC lock plus a 10 USDC
/// contribution leaves exactly 10 USDC of room: the first queued deposit fills it and
/// the second finds none. Pins the interaction rather than leaving it to be discovered
/// as an unexplained held request.
#[test]
fun a_contribution_consumes_supply_headroom_under_the_pool_cap() {
    let (mut fx, mut account) = setup_pool_with_lp();
    set_supply_fee(&mut fx, 0);
    set_max_pool_value(&mut fx, 30_000_000);
    contribute(&mut fx, min_supply!());
    queue_supply(&mut fx, &mut account, NO_MIN_OUT);
    queue_supply(&mut fx, &mut account, NO_MIN_OUT);

    flush(&mut fx);

    // At the 2 USDC/PLP mark the first 10 USDC deposit mints 5 PLP and takes pool
    // value to the 30 USDC cap; the second is held with no room left.
    assert_pending_and_supply(&mut fx, 1, 15_000_000);

    helpers::return_account_bundle(account);
    fx.finish();
}

// === The contribution price ceiling ===

/// Upper boundary, accepted side, and why the ceiling sits inside the band. 90 USDC on
/// top of the 10 USDC lock puts pool cash at exactly 100 USDC against 10 PLP, the
/// 10 USDC/PLP contribution ceiling. Fills after that only push the price up: an uneven
/// deposit leaves its rounding dust in the pool. Had contributions been allowed to the
/// band's own 100 USDC/PLP, that dust alone would have carried the next mark out of the
/// band and refunded every later request. Here the next flush still prices and fills.
/// The contribution is sized from the ceiling constant, so restoring the ceiling to the
/// band fails this test.
#[test]
fun a_contribution_to_the_price_ceiling_is_accepted_and_the_pool_still_fills() {
    let (mut fx, mut account) = setup_pool_with_lp();
    set_supply_fee(&mut fx, 0);
    contribute_to_ceiling(&mut fx);
    queue_supply_amount(&mut fx, &mut account, UNEVEN_DEPOSIT);

    let pool_nav = flush_with_budgets(&mut fx, option::none(), option::none());

    assert_eq!(pool_nav, 100_000_000);
    // floor(10.000001 USDC x 10 PLP / 100 USDC) = floor(1.0000001 PLP) = 1 PLP.
    assert_pending_and_supply(&mut fx, 0, 11_000_000);

    queue_supply(&mut fx, &mut account, NO_MIN_OUT);
    let pool_nav = flush_with_budgets(&mut fx, option::none(), option::none());

    // 100 + 10.000001 USDC over 11 PLP, about 10.0000001 USDC/PLP: still inside the band.
    assert_eq!(pool_nav, 110_000_001);
    // 10 USDC x 11 PLP / 110.000001 USDC = 0.99999999 PLP, floored to 0.999999 PLP.
    assert_pending_and_supply(&mut fx, 0, 11_999_999);

    helpers::return_account_bundle(account);
    fx.finish();
}

/// A retained supply fee is the largest upward push one supply fill can give the
/// price. At the 5% maximum, a deposit five times the pool that a contribution just
/// filled to its ceiling moves the mark from 10 to about 10.43 USDC/PLP, nowhere near
/// the band, and the next deposit still fills. The contribution is sized from the
/// ceiling constant, so restoring the ceiling to the band fails this test.
#[test]
fun a_contribution_to_the_price_ceiling_survives_the_maximum_supply_fee() {
    let (mut fx, mut account) = setup_pool_with_lp();
    set_supply_fee(&mut fx, MAX_PLP_FEE_RATE);
    contribute_to_ceiling(&mut fx);
    queue_supply_amount(&mut fx, &mut account, LARGE_DEPOSIT);

    let pool_nav = flush_with_budgets(&mut fx, option::none(), option::none());

    assert_eq!(pool_nav, 100_000_000);
    // Fee 5% x 500 = 25 USDC stays in the pool. Shares on the 475 USDC net:
    // 475 USDC x 10 PLP / 100 USDC = 47.5 PLP, so supply is 57.5 PLP.
    assert_pending_and_supply(&mut fx, 0, 57_500_000);

    queue_supply(&mut fx, &mut account, NO_MIN_OUT);
    let pool_nav = flush_with_budgets(&mut fx, option::none(), option::none());

    // 100 + 500 USDC over 57.5 PLP, about 10.43 USDC/PLP.
    assert_eq!(pool_nav, 600_000_000);
    // Fee 5% x 10 = 0.5 USDC. 9.5 USDC x 57.5 PLP / 600 USDC = 0.91041666 PLP,
    // floored to 0.910416 PLP.
    assert_pending_and_supply(&mut fx, 0, 58_410_416);

    helpers::return_account_bundle(account);
    fx.finish();
}

/// Upper boundary, rejected side — one micro-USDC past the ceiling. Without this guard
/// a contribution could fill the pool past the band: the mark prices out of it, so
/// `drain` refunds every supply and withdraw head, `total_supply` can never grow, and
/// nothing brings the price back down. Anyone could reach that state on the
/// genesis-lock share base for about 1,000 USDC, which is why the guard is here and not
/// left to RP-2 at the fill site.
#[test, expected_failure(abort_code = plp::EContributionExceedsPriceCeiling)]
fun a_contribution_past_the_price_ceiling_aborts() {
    let mut fx = helpers::setup_market_default();
    fx.bootstrap_lock(min_supply!());
    contribute(&mut fx, CONTRIBUTION_AT_CEILING + 1);
    abort 999
}

/// The ceiling tracks the share base rather than a fixed amount: once real LPs have
/// minted, the same contribution that was refused above is comfortably inside it.
#[test]
fun the_ceiling_rises_with_the_share_base() {
    let (mut fx, mut account) = setup_pool_with_lp();
    set_supply_fee(&mut fx, 0);
    // A 10 USDC fill doubles supply to 20 PLP, lifting the ceiling to 200 USDC of cash.
    queue_supply(&mut fx, &mut account, NO_MIN_OUT);
    flush(&mut fx);
    assert_pending_and_supply(&mut fx, 0, 2 * min_supply!());

    contribute(&mut fx, CONTRIBUTION_AT_CEILING + 1);

    fx.scenario_mut().next_tx(test_constants::alice());
    let vault = fx.scenario_mut().take_shared_by_id<PoolVault>(fx.vault_id());
    assert_eq!(vault.idle_balance(), 20_000_000 + CONTRIBUTION_AT_CEILING + 1);
    return_shared(vault);

    helpers::return_account_bundle(account);
    fx.finish();
}

/// Accepted side of the deployed-cash boundary. With the genesis 10 USDC moved into a
/// market and idle at 0, a contribution that brings pool cash to exactly the 100 USDC
/// ceiling is accepted, and the flush prices the market's cash at par and fills. The
/// next two tests show the market's cash is counted.
#[test]
fun a_contribution_to_the_ceiling_with_deployed_cash_is_accepted_and_fills() {
    let (mut fx, mut account) = setup_pool_with_lp();
    set_supply_fee(&mut fx, 0);
    let expiry_id = fund_market_from_idle(&mut fx);
    assert_idle(&mut fx, 0);
    contribute(&mut fx, CONTRIBUTION_AT_CEILING);
    queue_supply(&mut fx, &mut account, NO_MIN_OUT);

    let pool_nav = flush_with_market(&mut fx, expiry_id);

    // 90 USDC idle + 10 USDC in the order-free market. Credits (0) plus active value
    // (10) less debits (10 sent) is 0, so the protocol excludes nothing.
    assert_eq!(pool_nav, 100_000_000);
    // 10 USDC x 10 PLP / 100 USDC = 1 PLP on top of the 10 PLP lock.
    assert_pending_and_supply(&mut fx, 0, 11_000_000);

    helpers::return_account_bundle(account);
    fx.finish();
}

/// Rejected side of the boundary above. An idle-only test admits this: idle is 0, so
/// it sees 90.000001 USDC against a 100 USDC ceiling. Counting the 10 USDC in the
/// market makes pool cash 100.000001 USDC, one micro-USDC past the ceiling.
#[test, expected_failure(abort_code = plp::EContributionExceedsPriceCeiling)]
fun a_contribution_past_the_ceiling_through_deployed_cash_aborts() {
    let mut fx = helpers::setup_market_default();
    fx.bootstrap_lock(min_supply!());
    fund_market_from_idle(&mut fx);
    contribute(&mut fx, CONTRIBUTION_AT_CEILING + 1);
    abort 999
}

/// `rebalance_expiry_cash` is permissionless, so a contributor can fill the ceiling,
/// park the idle in a market, and try again against the emptied idle. Parking moves
/// cash between two figures the guard sums, so the ceiling is still full and the
/// minimum contribution is refused. That holds for a market that has not returned more
/// than it was sent, as here; `pool_accounting_tests` pins the bounded exception.
#[test, expected_failure(abort_code = plp::EContributionExceedsPriceCeiling)]
fun parking_idle_in_a_market_does_not_reopen_the_ceiling() {
    let mut fx = helpers::setup_market_default();
    fx.bootstrap_lock(min_supply!());
    contribute(&mut fx, CONTRIBUTION_AT_CEILING);
    // The default 10,000 USDC cash target takes all 100 USDC of idle.
    fund_market_from_idle(&mut fx);
    assert_idle(&mut fx, 0);
    contribute(&mut fx, min_contribution!());
    abort 999
}

/// Income the guard cannot see does not carry a ceiling-parked pool out of the band,
/// because the ceiling is a tenth of it. Pool cash sits at exactly 100 USDC over 10
/// PLP, all of it deployed into one live market, and one 50-contract ATM mint leaves
/// its 0.25 USDC fee in market cash: the premium equals the marked liability, so only
/// the fee reaches NAV, and the protocol's 10% share of that gain is excluded. The mark
/// is 100.225 USDC over 10 PLP, about 10.02 USDC/PLP, and the next deposit fills. The
/// contribution is sized from the ceiling constant rather than the fixed
/// `CONTRIBUTION_AT_CEILING`, so moving the ceiling back to the band fails this test:
/// the same trade then prices the pool at 1,000.225 USDC over 10 PLP, above the band,
/// and the deposit is refunded.
#[test]
fun fee_income_at_the_contribution_ceiling_stays_inside_the_band() {
    let (mut fx, mut account) = setup_pool_with_lp();
    set_supply_fee(&mut fx, 0);
    contribute_to_ceiling(&mut fx);
    let expiry_id = fund_market_from_idle(&mut fx);
    assert_idle(&mut fx, 0);

    fx.scenario_mut().next_tx(test_constants::alice());
    let mut market = fx.take_market_bundle(expiry_id);
    fx.prepare_live_oracle_bundle(&mut market, test_constants::default_live_price());
    fx.mint_bundle(
        &mut market,
        &mut account,
        helpers::strike_tick(),
        constants::pos_inf_tick!(),
        FEE_PROBE_QUANTITY,
    );
    helpers::return_market_bundle(market);
    queue_supply(&mut fx, &mut account, NO_MIN_OUT);

    let pool_nav = flush_with_market(&mut fx, expiry_id);

    // 100 USDC of pool cash + 0.25 USDC fee, less 10% of that 0.25 USDC gain.
    assert_eq!(pool_nav, 100_225_000);
    // floor(10 USDC x 10 PLP / 100.225 USDC) = floor(0.99775505 PLP) = 0.997755 PLP.
    assert_pending_and_supply(&mut fx, 0, 10_997_755);
    // The fill's 10 USDC is the only idle; everything else is still in the market.
    assert_idle(&mut fx, min_supply!());

    helpers::return_account_bundle(account);
    fx.finish();
}

// === Admission gates ===

/// Lower boundary, accepted side. Pairs with the below-floor abort so the floor is
/// pinned from both directions and cannot drift by one unit unnoticed.
#[test]
fun a_contribution_at_the_minimum_is_accepted() {
    let mut fx = helpers::setup_market_default();
    fx.bootstrap_lock(min_supply!());

    contribute(&mut fx, min_contribution!());

    fx.scenario_mut().next_tx(test_constants::alice());
    let vault = fx.scenario_mut().take_shared_by_id<PoolVault>(fx.vault_id());
    assert_eq!(vault.idle_balance(), min_supply!() + min_contribution!());
    return_shared(vault);

    fx.finish();
}

#[test, expected_failure(abort_code = plp::ENotBootstrapped)]
fun add_usdc_to_plp_before_bootstrap_aborts() {
    let mut fx = helpers::setup_market_default();
    // No share base to credit: the USDC would only enrich the genesis lock, which is
    // never withdrawable.
    contribute(&mut fx, CONTRIBUTION);
    abort 999
}

#[test, expected_failure(abort_code = plp::EBelowMinUsdcContribution)]
fun add_usdc_to_plp_below_the_floor_aborts() {
    let mut fx = helpers::setup_market_default();
    fx.bootstrap_lock(min_supply!());
    contribute(&mut fx, min_contribution!() - 1);
    abort 999
}

/// Refused inside the still-open snapshot stage too, so the gate covers the flush from
/// its first transaction rather than only after the seal.
#[test, expected_failure(abort_code = protocol_config::EValuationInProgress)]
fun add_usdc_to_plp_is_refused_inside_the_open_snapshot_stage() {
    let mut fx = helpers::setup_market_default();
    fx.bootstrap_lock(min_supply!());

    fx.scenario_mut().next_tx(test_constants::admin());
    let mut config = fx.scenario_mut().take_shared<ProtocolConfig>();
    let mut vault = fx.scenario_mut().take_shared_by_id<PoolVault>(fx.vault_id());
    let stage = fx.start_flush(&mut config, &mut vault);

    fx.add_usdc_to_plp_direct(&mut vault, &config, CONTRIBUTION);
    helpers::seal_snapshot(stage, &mut vault, &mut config);
    abort 999
}

/// Refused for the whole flush, not just the snapshot stage. The seal has already
/// frozen idle here, so an addition landing now would raise the pool without raising
/// the mark this flush pays its queued withdrawals at — the contributor's transaction
/// timing, not their intent, would decide who received the value.
#[test, expected_failure(abort_code = protocol_config::EValuationInProgress)]
fun add_usdc_to_plp_is_refused_after_the_seal() {
    let mut fx = helpers::setup_market_default();
    fx.bootstrap_lock(min_supply!());

    fx.scenario_mut().next_tx(test_constants::admin());
    let mut config = fx.scenario_mut().take_shared<ProtocolConfig>();
    let mut vault = fx.scenario_mut().take_shared_by_id<PoolVault>(fx.vault_id());
    let stage = fx.start_flush(&mut config, &mut vault);
    helpers::seal_snapshot(stage, &mut vault, &mut config);

    fx.add_usdc_to_plp_direct(&mut vault, &config, CONTRIBUTION);
    abort 999
}

// === Helpers ===

/// Contribute USDC to idle with no shares minted, as a non-admin, through the
/// production entrypoint.
fun contribute(fx: &mut helpers::Fixture, amount: u64) {
    fx.scenario_mut().next_tx(test_constants::alice());
    let config = fx.scenario_mut().take_shared<ProtocolConfig>();
    let mut vault = fx.scenario_mut().take_shared_by_id<PoolVault>(fx.vault_id());
    fx.add_usdc_to_plp_direct(&mut vault, &config, amount);
    return_shared(vault);
    return_shared(config);
}

/// Fill the genesis-lock pool to the contribution ceiling: the ceiling times its 10 PLP
/// of pool cash, less the 10 USDC lock already there. Sized from the ceiling constant,
/// so a test that relies on sitting exactly at the ceiling fails if the ceiling moves.
fun contribute_to_ceiling(fx: &mut helpers::Fixture) {
    contribute(fx, constants::contribution_price_ceiling_factor!() * min_supply!() - min_supply!());
}

/// A bootstrapped pool (no live markets) plus a funded LP account.
fun setup_pool_with_lp(): (helpers::Fixture, helpers::AccountBundle) {
    let mut fx = helpers::setup_market_default();
    fx.bootstrap_lock(min_supply!());
    let trader = fx.create_funded_manager(LP_DEPOSIT);
    let account = fx.take_account_bundle(&trader);
    (fx, account)
}

/// Queue a minimum-sized supply asking for an output no mark can quote, through the
/// production entrypoint.
fun queue_unfillable_supply(fx: &mut helpers::Fixture, account: &mut helpers::AccountBundle) {
    queue_supply(fx, account, unattainable_min_out());
}

/// Queue a minimum-sized supply at `min_plp_out` through the production entrypoint.
fun queue_supply(
    fx: &mut helpers::Fixture,
    account: &mut helpers::AccountBundle,
    min_plp_out: u64,
) {
    fx.scenario_mut().next_tx(test_constants::alice());
    let config = fx.scenario_mut().take_shared<ProtocolConfig>();
    let mut vault = fx.scenario_mut().take_shared_by_id<PoolVault>(fx.vault_id());
    fx.request_supply_direct(&mut vault, &config, account, min_supply!(), min_plp_out);
    return_shared(vault);
    return_shared(config);
}

/// Queue a supply of `amount` with no fill limit through the production entrypoint.
fun queue_supply_amount(
    fx: &mut helpers::Fixture,
    account: &mut helpers::AccountBundle,
    amount: u64,
) {
    fx.scenario_mut().next_tx(test_constants::alice());
    let config = fx.scenario_mut().take_shared<ProtocolConfig>();
    let mut vault = fx.scenario_mut().take_shared_by_id<PoolVault>(fx.vault_id());
    fx.request_supply_direct(&mut vault, &config, account, amount, NO_MIN_OUT);
    return_shared(vault);
    return_shared(config);
}

fun set_attempts(fx: &mut helpers::Fixture, attempts: u64) {
    fx.scenario_mut().next_tx(test_constants::admin());
    let mut config = fx.scenario_mut().take_shared<ProtocolConfig>();
    fx.set_lp_request_limit_flush_attempts(&mut config, attempts);
    return_shared(config);
}

fun set_supply_fee(fx: &mut helpers::Fixture, rate: u64) {
    fx.scenario_mut().next_tx(test_constants::admin());
    let config_id = fx.config_id();
    let mut config = fx.scenario_mut().take_shared_by_id<ProtocolConfig>(config_id);
    fx.set_plp_supply_fee_rate(&mut config, rate);
    return_shared(config);
}

fun set_withdraw_fee(fx: &mut helpers::Fixture, rate: u64) {
    fx.scenario_mut().next_tx(test_constants::admin());
    let config_id = fx.config_id();
    let mut config = fx.scenario_mut().take_shared_by_id<ProtocolConfig>(config_id);
    fx.set_plp_withdraw_fee_rate(&mut config, rate);
    return_shared(config);
}

fun set_max_pool_value(fx: &mut helpers::Fixture, max_pool_value: u64) {
    fx.scenario_mut().next_tx(test_constants::admin());
    let mut config = fx.scenario_mut().take_shared<ProtocolConfig>();
    fx.set_max_lp_pool_value(&mut config, max_pool_value);
    return_shared(config);
}

fun assert_idle(fx: &mut helpers::Fixture, idle: u64) {
    fx.scenario_mut().next_tx(test_constants::admin());
    let vault = fx.scenario_mut().take_shared_by_id<PoolVault>(fx.vault_id());
    assert_eq!(vault.idle_balance(), idle);
    return_shared(vault);
}

/// Create a live market and fund it from idle through the permissionless
/// `rebalance_expiry_cash`, so pool cash moves out of idle into market cash.
fun fund_market_from_idle(fx: &mut helpers::Fixture): ID {
    let expiry_id = fx.create_expiry(test_constants::default_expiry_ms());
    fx.scenario_mut().next_tx(test_constants::admin());
    let mut market = fx.take_market_bundle(expiry_id);
    fx.prepare_live_oracle_bundle(&mut market, test_constants::default_live_price());
    fx.rebalance_expiry_cash_bundle(&mut market);
    helpers::return_market_bundle(market);
    expiry_id
}

/// Run one full flush over a single live market, returning the pool NAV it priced at.
fun flush_with_market(fx: &mut helpers::Fixture, expiry_id: ID): u64 {
    fx.scenario_mut().next_tx(test_constants::admin());
    let mut market = fx.take_market_bundle(expiry_id);
    fx.start_flush_bundle(&mut market);
    fx.value_expiry_bundle(&mut market);
    let pool_nav = fx.finish_flush_bundle(&mut market);
    helpers::return_market_bundle(market);
    pool_nav
}

fun assert_pending_and_supply(fx: &mut helpers::Fixture, pending: u64, total_supply: u64) {
    fx.scenario_mut().next_tx(test_constants::admin());
    let vault = fx.scenario_mut().take_shared_by_id<PoolVault>(fx.vault_id());
    assert_eq!(vault.supply_requests_pending(), pending);
    assert_eq!(vault.plp_total_supply(), total_supply);
    return_shared(vault);
}

/// No executable mark can quote this, so a request carrying it misses every flush.
fun unattainable_min_out(): u64 { std::u64::max_value!() }

/// Run one flush over the empty market set (pool NAV == idle), draining both queues
/// fully, and discard the result.
fun flush(fx: &mut helpers::Fixture) {
    let _ = flush_with_budgets(fx, option::none(), option::none());
}

/// Run one flush bounding how many supply / withdraw requests each queue may fill,
/// returning the pool NAV it priced the drain at. Started through the sole flush
/// authority, the `PoolValuationCap`.
fun flush_with_budgets(
    fx: &mut helpers::Fixture,
    supply_budget: Option<u64>,
    withdraw_budget: Option<u64>,
): u64 {
    fx.scenario_mut().next_tx(test_constants::admin());
    let mut config = fx.scenario_mut().take_shared<ProtocolConfig>();
    let mut vault = fx.scenario_mut().take_shared_by_id<PoolVault>(fx.vault_id());
    let stage = fx.start_flush_with_budgets(
        &mut config,
        &mut vault,
        supply_budget,
        withdraw_budget,
    );
    helpers::seal_snapshot(stage, &mut vault, &mut config);
    let pool_nav = fx.finish_flush(&mut vault, &mut config);
    return_shared(config);
    return_shared(vault);
    pool_nav
}
