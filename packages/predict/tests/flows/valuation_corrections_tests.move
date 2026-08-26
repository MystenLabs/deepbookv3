// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Coverage for trading during an in-flight flush: the snapshot capture that
/// keeps the mark exact under mid-window trades, the LP-queue eligibility
/// cutoff, the per-market settlement gate, lazy stamp reconciliation across
/// aborts, and the absence of any mid-window trade budget.
///
/// The exactness tests are metamorphic: the same books produce a control mark
/// from an undisturbed flush, then a second flush runs with trades injected
/// between its snapshot and its valuation and must produce the IDENTICAL mark —
/// the trades are provably invisible to the captured figure. Each carries a
/// guard flush afterwards (the same trades now pre-snapshot) asserting the mark
/// MOVES, so the equality is the capture at work, not an insensitive mark. The
/// control comes from a code path that never mutates a captured book, so the
/// oracle is independent in the sense of unit-test rule 1.
#[test_only]
module deepbook_predict::valuation_corrections_tests;

use deepbook_predict::{
    constants,
    expiry_market,
    flow_test_helpers as helpers,
    protocol_config::{Self, ProtocolConfig},
    test_constants
};
use std::unit_test::assert_eq;
use sui::test_scenario::return_shared;

/// Baseline position minted before any flush: UP at the anchored strike.
const BASELINE_QUANTITY: u64 = 2_000_000_000;
/// Position traded mid-window; even and lot-aligned like the baseline.
const MID_WINDOW_QUANTITY: u64 = 4_000_000_000;
/// Half-close size for the partial-close case.
const PARTIAL_CLOSE_QUANTITY: u64 = 1_000_000_000;
/// A Pyth move small enough to keep mint admission in its entry band but large
/// enough that a live re-read would mark differently than the frozen pricer.
const MOVED_LIVE_PRICE: u64 = 102_000_000_000;
/// Large enough that its required-backing jump drops the market below its cash
/// target, forcing the top-up branch of a following rebalance.
const TOP_UP_FORCING_QUANTITY: u64 = 14_000_000_000;
/// Minimum supply-request escrow accepted by the queue (10 DUSDC).
const SUPPLY_AMOUNT: u64 = 10_000_000;
/// No fill floor: the request takes whatever the mark quotes.
const NO_MIN_OUT: u64 = 0;

// === Exactness: mid-window trades are cancelled out of the mark ===

#[test]
fun a_mint_between_snapshot_and_valuation_leaves_the_mark_unchanged() {
    let (mut fx, expiry_id, trader) = helpers::setup_everything();
    fx.bootstrap_lock(SUPPLY_AMOUNT);
    fx.scenario_mut().next_tx(test_constants::alice());
    let mut market = fx.take_market_bundle(expiry_id);
    let mut account = fx.take_account_bundle(&trader);
    let _baseline = fx.mint_bundle(
        &mut market,
        &mut account,
        helpers::strike_tick(),
        helpers::pos_inf_tick(),
        BASELINE_QUANTITY,
    );

    let control_mark = run_undisturbed_flush(&mut fx, &mut market);

    // Same books: a flush with a mint landing between its snapshot and its
    // valuation must reproduce the control mark exactly.
    fx.scenario_mut().next_tx(test_constants::alice());
    fx.start_flush_bundle(&mut market);
    let _mid_window = fx.mint_bundle(
        &mut market,
        &mut account,
        helpers::strike_tick(),
        helpers::pos_inf_tick(),
        MID_WINDOW_QUANTITY,
    );
    fx.value_expiry_bundle(&mut market);
    let corrected_mark = fx.finish_flush_bundle(&mut market, option::none(), option::none());
    assert_eq!(corrected_mark, control_mark);

    // Guard: with the mint now pre-snapshot, the mark moves (the pool keeps the
    // trade's fees), so the equality above cannot be mark-insensitivity.
    let disturbed_mark = run_undisturbed_flush(&mut fx, &mut market);
    assert!(disturbed_mark > control_mark);

    helpers::return_account_bundle(account);
    helpers::return_market_bundle(market);
    fx.finish();
}

#[test]
fun a_close_between_snapshot_and_valuation_leaves_the_mark_unchanged() {
    let (mut fx, expiry_id, trader) = helpers::setup_everything();
    fx.bootstrap_lock(SUPPLY_AMOUNT);
    fx.scenario_mut().next_tx(test_constants::alice());
    let mut market = fx.take_market_bundle(expiry_id);
    let mut account = fx.take_account_bundle(&trader);
    let baseline = fx.mint_bundle(
        &mut market,
        &mut account,
        helpers::strike_tick(),
        helpers::pos_inf_tick(),
        BASELINE_QUANTITY,
    );

    let control_mark = run_undisturbed_flush(&mut fx, &mut market);

    // A partial close of a PRE-snapshot position lands mid-window: net-remove
    // deltas over live boundaries. The mint/redeem same-timestamp guard needs a
    // fresh oracle instant, and the snapshot must postdate that write, so the
    // clock advances before the flush starts.
    fx.advance_live_oracle_bundle(&mut market, test_constants::default_live_price());
    fx.scenario_mut().next_tx(test_constants::alice());
    fx.start_flush_bundle(&mut market);
    let _replacement = fx.redeem_live_bundle(
        &mut market,
        &mut account,
        baseline,
        PARTIAL_CLOSE_QUANTITY,
    );
    fx.value_expiry_bundle(&mut market);
    let corrected_mark = fx.finish_flush_bundle(&mut market, option::none(), option::none());
    assert_eq!(corrected_mark, control_mark);

    // Guard: the close now pre-snapshot moves the mark (the pool keeps the close
    // fee).
    let disturbed_mark = run_undisturbed_flush(&mut fx, &mut market);
    assert!(disturbed_mark > control_mark);

    helpers::return_account_bundle(account);
    helpers::return_market_bundle(market);
    fx.finish();
}

#[test]
fun a_full_close_deleting_boundaries_mid_window_leaves_the_mark_unchanged() {
    let (mut fx, expiry_id, trader) = helpers::setup_everything();
    fx.bootstrap_lock(SUPPLY_AMOUNT);
    fx.scenario_mut().next_tx(test_constants::alice());
    let mut market = fx.take_market_bundle(expiry_id);
    let mut account = fx.take_account_bundle(&trader);
    let baseline = fx.mint_bundle(
        &mut market,
        &mut account,
        helpers::strike_tick(),
        helpers::pos_inf_tick(),
        BASELINE_QUANTITY,
    );

    let control_mark = run_undisturbed_flush(&mut fx, &mut market);

    // Fully closing the only position empties its boundary nodes, so the frozen
    // walk must price the retained husks alone.
    fx.advance_live_oracle_bundle(&mut market, test_constants::default_live_price());
    fx.scenario_mut().next_tx(test_constants::alice());
    fx.start_flush_bundle(&mut market);
    let replacement = fx.redeem_live_bundle(
        &mut market,
        &mut account,
        baseline,
        BASELINE_QUANTITY,
    );
    assert!(replacement.is_none());
    fx.value_expiry_bundle(&mut market);
    let corrected_mark = fx.finish_flush_bundle(&mut market, option::none(), option::none());
    assert_eq!(corrected_mark, control_mark);

    helpers::return_account_bundle(account);
    helpers::return_market_bundle(market);
    fx.finish();
}

#[test]
fun a_mint_closed_again_mid_window_leaves_the_mark_unchanged() {
    let (mut fx, expiry_id, trader) = helpers::setup_everything();
    fx.bootstrap_lock(SUPPLY_AMOUNT);
    fx.scenario_mut().next_tx(test_constants::alice());
    let mut market = fx.take_market_bundle(expiry_id);
    let mut account = fx.take_account_bundle(&trader);
    let _baseline = fx.mint_bundle(
        &mut market,
        &mut account,
        helpers::strike_tick(),
        helpers::pos_inf_tick(),
        BASELINE_QUANTITY,
    );

    let control_mark = run_undisturbed_flush(&mut fx, &mut market);

    // Mint a NEW boundary pair mid-window, then fully close it mid-window: the
    // transient boundaries carry zero shadows (created after the snapshot) and
    // the cash legs never touch the stamp's captured values.
    fx.scenario_mut().next_tx(test_constants::alice());
    fx.start_flush_bundle(&mut market);
    let mid_window = fx.mint_bundle(
        &mut market,
        &mut account,
        constants::neg_inf!(),
        helpers::strike_tick(),
        MID_WINDOW_QUANTITY,
    );
    fx.advance_live_oracle_bundle(&mut market, test_constants::default_live_price());
    fx.scenario_mut().next_tx(test_constants::alice());
    let replacement = fx.redeem_live_bundle(
        &mut market,
        &mut account,
        mid_window,
        MID_WINDOW_QUANTITY,
    );
    assert!(replacement.is_none());
    fx.value_expiry_bundle(&mut market);
    let corrected_mark = fx.finish_flush_bundle(&mut market, option::none(), option::none());
    assert_eq!(corrected_mark, control_mark);

    helpers::return_account_bundle(account);
    helpers::return_market_bundle(market);
    fx.finish();
}

#[test]
fun an_oracle_move_plus_a_trade_mid_window_leave_the_mark_unchanged() {
    let (mut fx, expiry_id, trader) = helpers::setup_everything();
    fx.bootstrap_lock(SUPPLY_AMOUNT);
    fx.scenario_mut().next_tx(test_constants::alice());
    let mut market = fx.take_market_bundle(expiry_id);
    let mut account = fx.take_account_bundle(&trader);
    let baseline = fx.mint_bundle(
        &mut market,
        &mut account,
        helpers::strike_tick(),
        helpers::pos_inf_tick(),
        BASELINE_QUANTITY,
    );

    let control_mark = run_undisturbed_flush(&mut fx, &mut market);

    // The full mid-window storm: the oracle moves AND a trade prices against the
    // moved oracle, both after the snapshot. The close executes at the live
    // pricer (the fixture surface saturates mint admission off-ATM, so the
    // mid-window trade is a close, which admits at any probability), the flush
    // marks at the frozen one, and the captured snapshot still lands the
    // control mark exactly.
    fx.scenario_mut().next_tx(test_constants::alice());
    fx.start_flush_bundle(&mut market);
    fx.advance_live_oracle_bundle(&mut market, MOVED_LIVE_PRICE);
    fx.scenario_mut().next_tx(test_constants::alice());
    let _replacement = fx.redeem_live_bundle(
        &mut market,
        &mut account,
        baseline,
        PARTIAL_CLOSE_QUANTITY,
    );
    fx.value_expiry_bundle(&mut market);
    let corrected_mark = fx.finish_flush_bundle(&mut market, option::none(), option::none());
    assert_eq!(corrected_mark, control_mark);

    helpers::return_account_bundle(account);
    helpers::return_market_bundle(market);
    fx.finish();
}

#[test]
fun a_trade_after_a_markets_valuation_is_invisible_to_the_flush() {
    let (mut fx, expiry_id, trader) = helpers::setup_everything();
    fx.bootstrap_lock(SUPPLY_AMOUNT);
    fx.scenario_mut().next_tx(test_constants::alice());
    let mut market = fx.take_market_bundle(expiry_id);
    let mut account = fx.take_account_bundle(&trader);
    let _baseline = fx.mint_bundle(
        &mut market,
        &mut account,
        helpers::strike_tick(),
        helpers::pos_inf_tick(),
        BASELINE_QUANTITY,
    );

    let control_mark = run_undisturbed_flush(&mut fx, &mut market);

    // The market is valued, its stamp cleared, and only then does the trade land:
    // nothing records it and the already-folded figure stands.
    fx.scenario_mut().next_tx(test_constants::alice());
    fx.start_flush_bundle(&mut market);
    fx.value_expiry_bundle(&mut market);
    let _post_valuation = fx.mint_bundle(
        &mut market,
        &mut account,
        helpers::strike_tick(),
        helpers::pos_inf_tick(),
        MID_WINDOW_QUANTITY,
    );
    let corrected_mark = fx.finish_flush_bundle(&mut market, option::none(), option::none());
    assert_eq!(corrected_mark, control_mark);

    helpers::return_account_bundle(account);
    helpers::return_market_bundle(market);
    fx.finish();
}

// === LP queue: eligibility cutoff and the cancel gate ===

#[test]
fun a_request_submitted_after_the_snapshot_waits_for_the_next_flush() {
    let (mut fx, expiry_id, trader) = helpers::setup_everything();
    fx.bootstrap_lock(SUPPLY_AMOUNT);
    fx.scenario_mut().next_tx(test_constants::alice());
    let mut market = fx.take_market_bundle(expiry_id);
    let mut account = fx.take_account_bundle(&trader);

    // Queued before the snapshot: eligible for this flush's mark.
    let _eligible = fx.request_supply_bundle(&mut market, &mut account, SUPPLY_AMOUNT, NO_MIN_OUT);
    fx.scenario_mut().next_tx(test_constants::alice());
    fx.start_flush_bundle(&mut market);
    // Queued after the snapshot: quarantined to the next mark even though the
    // budgets below are unbounded.
    let _too_young = fx.request_supply_bundle(&mut market, &mut account, SUPPLY_AMOUNT, NO_MIN_OUT);
    fx.value_expiry_bundle(&mut market);
    fx.finish_flush_bundle(&mut market, option::none(), option::none());
    assert_eq!(helpers::vault(&market).supply_requests_pending(), 1);

    // The next flush reaches it.
    fx.scenario_mut().next_tx(test_constants::alice());
    fx.start_flush_bundle(&mut market);
    fx.value_expiry_bundle(&mut market);
    fx.finish_flush_bundle(&mut market, option::none(), option::none());
    assert_eq!(helpers::vault(&market).supply_requests_pending(), 0);

    helpers::return_account_bundle(account);
    helpers::return_market_bundle(market);
    fx.finish();
}

#[test, expected_failure(abort_code = protocol_config::EValuationInProgress)]
fun cancelling_a_request_during_a_flush_aborts() {
    let (mut fx, expiry_id, trader) = helpers::setup_everything();
    fx.bootstrap_lock(SUPPLY_AMOUNT);
    fx.scenario_mut().next_tx(test_constants::alice());
    let mut market = fx.take_market_bundle(expiry_id);
    let mut account = fx.take_account_bundle(&trader);

    // The frozen mark is on-chain readable once the snapshot lands, so an
    // ungated cancel of an eligible request would be a free look at a stale
    // price. The gate closes it.
    let index = fx.request_supply_bundle(&mut market, &mut account, SUPPLY_AMOUNT, NO_MIN_OUT);
    fx.scenario_mut().next_tx(test_constants::alice());
    fx.start_flush_bundle(&mut market);
    fx.cancel_supply_request_bundle(&mut market, &mut account, index);
    abort 999
}

// === Maintenance during the window: the mark is timing-invariant ===

#[test]
fun a_mid_window_surplus_sweep_leaves_the_mark_unchanged() {
    let (mut fx, expiry_id, trader) = helpers::setup_everything();
    fx.bootstrap_lock(SUPPLY_AMOUNT);
    fx.scenario_mut().next_tx(test_constants::alice());
    let mut market = fx.take_market_bundle(expiry_id);
    let mut account = fx.take_account_bundle(&trader);
    let _baseline = fx.mint_bundle(
        &mut market,
        &mut account,
        helpers::strike_tick(),
        helpers::pos_inf_tick(),
        BASELINE_QUANTITY,
    );

    let control_mark = run_undisturbed_flush(&mut fx, &mut market);

    // The seeded cash sits far above the market's band, so a mid-window
    // rebalance fires a large surplus sweep on the still-pending market. It is
    // recorded on the stamp and reversed at the finish, so the mark is exactly
    // the control's.
    fx.scenario_mut().next_tx(test_constants::alice());
    fx.start_flush_bundle(&mut market);
    let idle_before = helpers::vault(&market).idle_balance();
    fx.rebalance_expiry_cash_bundle(&mut market);
    // Guard: the sweep genuinely moved cash, so the equality below is the
    // compensation at work, not a no-op rebalance.
    assert!(helpers::vault(&market).idle_balance() > idle_before);
    fx.value_expiry_bundle(&mut market);
    let corrected_mark = fx.finish_flush_bundle(&mut market, option::none(), option::none());
    assert_eq!(corrected_mark, control_mark);

    helpers::return_account_bundle(account);
    helpers::return_market_bundle(market);
    fx.finish();
}

#[test]
fun a_mid_window_top_up_leaves_the_mark_unchanged() {
    let (mut fx, expiry_id, trader) = helpers::setup_everything();
    fx.bootstrap_lock(SUPPLY_AMOUNT);
    fx.scenario_mut().next_tx(test_constants::alice());
    let mut market = fx.take_market_bundle(expiry_id);
    let mut account = fx.take_account_bundle(&trader);
    let _baseline = fx.mint_bundle(
        &mut market,
        &mut account,
        helpers::strike_tick(),
        helpers::pos_inf_tick(),
        BASELINE_QUANTITY,
    );
    // Sweep the seeded surplus to the band OUTSIDE any window, so the top-up
    // branch is reachable below.
    fx.rebalance_expiry_cash_bundle(&mut market);

    let control_mark = run_undisturbed_flush(&mut fx, &mut market);

    // Mid-window: a large mint jumps the required backing past the market's
    // cash target, and the following rebalance tops the market up from idle —
    // trade deltas and maintenance both recorded on the pending market's stamp,
    // the top-up also reversed out of the pool total and profit basis.
    fx.scenario_mut().next_tx(test_constants::alice());
    fx.start_flush_bundle(&mut market);
    let _mid_window = fx.mint_bundle(
        &mut market,
        &mut account,
        helpers::strike_tick(),
        helpers::pos_inf_tick(),
        TOP_UP_FORCING_QUANTITY,
    );
    let idle_before = helpers::vault(&market).idle_balance();
    fx.rebalance_expiry_cash_bundle(&mut market);
    // Guard: the top-up genuinely pulled idle into the market.
    assert!(helpers::vault(&market).idle_balance() < idle_before);
    fx.value_expiry_bundle(&mut market);
    let corrected_mark = fx.finish_flush_bundle(&mut market, option::none(), option::none());
    assert_eq!(corrected_mark, control_mark);

    helpers::return_account_bundle(account);
    helpers::return_market_bundle(market);
    fx.finish();
}

#[test]
fun maintenance_after_a_markets_valuation_leaves_the_mark_unchanged() {
    let (mut fx, expiry_id, trader) = helpers::setup_everything();
    fx.bootstrap_lock(SUPPLY_AMOUNT);
    fx.scenario_mut().next_tx(test_constants::alice());
    let mut market = fx.take_market_bundle(expiry_id);
    let mut account = fx.take_account_bundle(&trader);
    let _baseline = fx.mint_bundle(
        &mut market,
        &mut account,
        helpers::strike_tick(),
        helpers::pos_inf_tick(),
        BASELINE_QUANTITY,
    );

    let control_mark = run_undisturbed_flush(&mut fx, &mut market);

    // The market is valued (stamp cleared), then a trade and a surplus sweep
    // land before the finish: nothing records on a stamp any more, and only the
    // flush-level accumulators keep the swept surplus out of an already-measured
    // pool total.
    fx.scenario_mut().next_tx(test_constants::alice());
    fx.start_flush_bundle(&mut market);
    fx.value_expiry_bundle(&mut market);
    let _post_valuation = fx.mint_bundle(
        &mut market,
        &mut account,
        helpers::strike_tick(),
        helpers::pos_inf_tick(),
        MID_WINDOW_QUANTITY,
    );
    let idle_before = helpers::vault(&market).idle_balance();
    fx.rebalance_expiry_cash_bundle(&mut market);
    // Guard: the sweep genuinely moved cash after the valuation.
    assert!(helpers::vault(&market).idle_balance() > idle_before);
    let corrected_mark = fx.finish_flush_bundle(&mut market, option::none(), option::none());
    assert_eq!(corrected_mark, control_mark);

    helpers::return_account_bundle(account);
    helpers::return_market_bundle(market);
    fx.finish();
}

// === Settlement: the per-market gate ===

#[test, expected_failure(abort_code = expiry_market::EMarketPendingValuation)]
fun settling_a_market_pending_valuation_aborts() {
    let (mut fx, expiry_id, _trader) = helpers::setup_everything();
    fx.bootstrap_lock(SUPPLY_AMOUNT);
    fx.scenario_mut().next_tx(test_constants::alice());
    let mut market = fx.take_market_bundle(expiry_id);

    // Snapshotted live, then the expiry passes mid-window: settlement must wait
    // for this market's valuation (the frozen sweep-vs-value branch is
    // load-bearing).
    fx.scenario_mut().next_tx(test_constants::alice());
    fx.start_flush_bundle(&mut market);
    fx.set_clock_for_testing(helpers::market(&market).expiry() + 1);
    fx.try_settle_bundle(&mut market);
    abort 999
}

#[test]
fun a_market_expiring_mid_flush_values_at_the_frozen_mark_then_settles() {
    let (mut fx, expiry_id, trader) = helpers::setup_everything();
    fx.bootstrap_lock(SUPPLY_AMOUNT);
    fx.scenario_mut().next_tx(test_constants::alice());
    let mut market = fx.take_market_bundle(expiry_id);
    let mut account = fx.take_account_bundle(&trader);
    let _baseline = fx.mint_bundle(
        &mut market,
        &mut account,
        helpers::strike_tick(),
        helpers::pos_inf_tick(),
        BASELINE_QUANTITY,
    );

    let control_mark = run_undisturbed_flush(&mut fx, &mut market);

    // The expiry passes between the snapshot and the valuation: the market is
    // valued at its frozen pre-expiry mark (identical books, identical mark),
    // becomes settleable the moment its stamp clears, and its settled sweep is
    // DEFERRED for the rest of the window — a market already folded at its live
    // NAV must not also have its cash swept into idle before the finish.
    fx.scenario_mut().next_tx(test_constants::alice());
    fx.start_flush_bundle(&mut market);
    fx.set_clock_for_testing(helpers::market(&market).expiry() + 1);
    fx.value_expiry_bundle(&mut market);
    assert!(!helpers::market(&market).is_pending_valuation(helpers::config(&market)));
    fx.insert_exact_settlement_spot_bundle(&mut market, test_constants::default_live_price());
    assert!(fx.try_settle_bundle(&mut market));
    let idle_before = helpers::vault(&market).idle_balance();
    fx.rebalance_expiry_cash_bundle(&mut market);
    // Guard: the settled sweep genuinely deferred — idle untouched mid-window.
    assert_eq!(helpers::vault(&market).idle_balance(), idle_before);
    let corrected_mark = fx.finish_flush_bundle(&mut market, option::none(), option::none());
    assert_eq!(corrected_mark, control_mark);

    helpers::return_account_bundle(account);
    helpers::return_market_bundle(market);
    fx.finish();
}

#[test]
fun a_settled_redeem_mid_window_leaves_the_mark_unchanged() {
    let (mut fx, expiry_id, trader) = helpers::setup_everything();
    fx.bootstrap_lock(SUPPLY_AMOUNT);
    fx.scenario_mut().next_tx(test_constants::alice());
    let mut market = fx.take_market_bundle(expiry_id);
    let mut account = fx.take_account_bundle(&trader);
    let baseline = fx.mint_bundle(
        &mut market,
        &mut account,
        helpers::strike_tick(),
        helpers::pos_inf_tick(),
        BASELINE_QUANTITY,
    );

    let control_mark = run_undisturbed_flush(&mut fx, &mut market);

    // The market is valued, expires, settles, and the winner REDEEMS — all
    // inside the window. The redeem moves market cash after the figure was
    // folded, so it is invisible to the mark, and the settled sweep stays
    // deferred throughout.
    fx.scenario_mut().next_tx(test_constants::alice());
    fx.start_flush_bundle(&mut market);
    fx.set_clock_for_testing(helpers::market(&market).expiry() + 1);
    fx.value_expiry_bundle(&mut market);
    fx.insert_exact_settlement_spot_bundle(&mut market, test_constants::default_live_price());
    assert!(fx.try_settle_bundle(&mut market));
    fx.redeem_settled_bundle(&mut market, &mut account, baseline);
    let idle_before = helpers::vault(&market).idle_balance();
    fx.rebalance_expiry_cash_bundle(&mut market);
    assert_eq!(helpers::vault(&market).idle_balance(), idle_before);
    let corrected_mark = fx.finish_flush_bundle(&mut market, option::none(), option::none());
    assert_eq!(corrected_mark, control_mark);

    helpers::return_account_bundle(account);
    helpers::return_market_bundle(market);
    fx.finish();
}

#[test]
fun emergency_controls_stay_available_mid_flush() {
    let (mut fx, expiry_id, trader) = helpers::setup_everything();
    fx.bootstrap_lock(SUPPLY_AMOUNT);
    fx.scenario_mut().next_tx(test_constants::alice());
    let mut market = fx.take_market_bundle(expiry_id);
    let mut account = fx.take_account_bundle(&trader);
    let _baseline = fx.mint_bundle(
        &mut market,
        &mut account,
        helpers::strike_tick(),
        helpers::pos_inf_tick(),
        BASELINE_QUANTITY,
    );

    let control_mark = run_undisturbed_flush(&mut fx, &mut market);

    // The pause and the freeze both engage AND clear while a flush is in
    // flight — neither setter carries a valuation gate — and the flush then
    // completes at the control mark.
    fx.scenario_mut().next_tx(test_constants::alice());
    fx.start_flush_bundle(&mut market);
    fx.set_trading_paused_bundle(&mut market, true);
    fx.set_trading_paused_bundle(&mut market, false);
    fx.set_frozen_bundle(&mut market, true);
    fx.set_frozen_bundle(&mut market, false);
    fx.value_expiry_bundle(&mut market);
    let corrected_mark = fx.finish_flush_bundle(&mut market, option::none(), option::none());
    assert_eq!(corrected_mark, control_mark);

    helpers::return_account_bundle(account);
    helpers::return_market_bundle(market);
    fx.finish();
}

#[test]
fun an_aborted_flushs_husks_never_reach_a_later_mark() {
    let (mut fx, expiry_id, trader) = helpers::setup_everything();
    fx.bootstrap_lock(SUPPLY_AMOUNT);
    fx.scenario_mut().next_tx(test_constants::alice());
    let mut market = fx.take_market_bundle(expiry_id);
    let mut account = fx.take_account_bundle(&trader);
    let baseline = fx.mint_bundle(
        &mut market,
        &mut account,
        helpers::strike_tick(),
        helpers::pos_inf_tick(),
        BASELINE_QUANTITY,
    );

    let with_position_mark = run_undisturbed_flush(&mut fx, &mut market);

    // Flush A freezes the position, the position fully closes mid-window
    // (its boundaries become husks holding A's shadows), and A aborts. The
    // husks' stale shadows must never serve a later mark: flushes B and C
    // both price the emptied book, agree with each other, and disagree with
    // the with-position control.
    fx.advance_live_oracle_bundle(&mut market, test_constants::default_live_price());
    fx.scenario_mut().next_tx(test_constants::alice());
    fx.start_flush_bundle(&mut market);
    let _closed = fx.redeem_live_bundle(&mut market, &mut account, baseline, BASELINE_QUANTITY);
    fx.scenario_mut().next_tx(test_constants::alice());
    fx.abort_valuation_privileged_bundle(&mut market);

    let mark_b = run_undisturbed_flush(&mut fx, &mut market);
    let mark_c = run_undisturbed_flush(&mut fx, &mut market);
    assert_eq!(mark_b, mark_c);
    assert!(mark_b != with_position_mark);

    helpers::return_account_bundle(account);
    helpers::return_market_bundle(market);
    fx.finish();
}

// === Lazy reconciliation across aborts ===

#[test]
fun an_aborted_flushs_snapshot_never_leaks_into_the_next_flush() {
    let (mut fx, expiry_id, trader) = helpers::setup_everything();
    fx.bootstrap_lock(SUPPLY_AMOUNT);
    fx.scenario_mut().next_tx(test_constants::alice());
    let mut market = fx.take_market_bundle(expiry_id);
    let mut account = fx.take_account_bundle(&trader);
    let _baseline = fx.mint_bundle(
        &mut market,
        &mut account,
        helpers::strike_tick(),
        helpers::pos_inf_tick(),
        BASELINE_QUANTITY,
    );

    // Flush A records a mid-window mint, then is discarded.
    fx.scenario_mut().next_tx(test_constants::alice());
    fx.start_flush_bundle(&mut market);
    let _mid_window = fx.mint_bundle(
        &mut market,
        &mut account,
        helpers::strike_tick(),
        helpers::pos_inf_tick(),
        MID_WINDOW_QUANTITY,
    );
    fx.scenario_mut().next_tx(test_constants::alice());
    fx.abort_valuation_privileged_bundle(&mut market);
    assert!(!helpers::valuation_in_progress_bundle(&market));

    // Both later flushes see the mint as ordinary pre-snapshot state. If flush
    // B could read A's stale snapshot it would exclude the mint and disagree
    // with flush C.
    let mark_b = run_undisturbed_flush(&mut fx, &mut market);
    let mark_c = run_undisturbed_flush(&mut fx, &mut market);
    assert_eq!(mark_b, mark_c);

    helpers::return_account_bundle(account);
    helpers::return_market_bundle(market);
    fx.finish();
}

#[test]
fun a_stale_stamp_is_discarded_by_the_next_trade() {
    let (mut fx, expiry_id, trader) = helpers::setup_everything();
    fx.bootstrap_lock(SUPPLY_AMOUNT);
    fx.scenario_mut().next_tx(test_constants::alice());
    let mut market = fx.take_market_bundle(expiry_id);
    let mut account = fx.take_account_bundle(&trader);

    fx.scenario_mut().next_tx(test_constants::alice());
    fx.start_flush_bundle(&mut market);
    assert!(helpers::market(&market).is_pending_valuation(helpers::config(&market)));
    fx.scenario_mut().next_tx(test_constants::alice());
    fx.abort_valuation_privileged_bundle(&mut market);
    // The stamp is stale the moment the flag drops, and the next trade discards
    // it instead of recording.
    assert!(!helpers::market(&market).is_pending_valuation(helpers::config(&market)));
    let _plain = fx.mint_bundle(
        &mut market,
        &mut account,
        helpers::strike_tick(),
        helpers::pos_inf_tick(),
        BASELINE_QUANTITY,
    );
    assert!(!helpers::market(&market).is_pending_valuation(helpers::config(&market)));

    helpers::return_account_bundle(account);
    helpers::return_market_bundle(market);
    fx.finish();
}

#[test]
fun value_expiry_moves_no_cash_for_a_live_market() {
    let (mut fx, expiry_id, trader) = helpers::setup_everything();
    fx.bootstrap_lock(SUPPLY_AMOUNT);
    fx.scenario_mut().next_tx(test_constants::alice());
    let mut market = fx.take_market_bundle(expiry_id);
    let mut account = fx.take_account_bundle(&trader);
    let _baseline = fx.mint_bundle(
        &mut market,
        &mut account,
        helpers::strike_tick(),
        helpers::pos_inf_tick(),
        BASELINE_QUANTITY,
    );

    // Measurement-only: a live market's valuation reads its captured snapshot
    // and moves nothing. Cash maintenance runs outside the window.
    fx.scenario_mut().next_tx(test_constants::alice());
    fx.start_flush_bundle(&mut market);
    let idle_before = helpers::vault(&market).idle_balance();
    let cash_before = helpers::market(&market).cash_balance();
    fx.value_expiry_bundle(&mut market);
    assert_eq!(helpers::vault(&market).idle_balance(), idle_before);
    assert_eq!(helpers::market(&market).cash_balance(), cash_before);
    fx.finish_flush_bundle(&mut market, option::none(), option::none());

    helpers::return_account_bundle(account);
    helpers::return_market_bundle(market);
    fx.finish();
}

// === Unbudgeted mid-window trading ===

#[test]
fun mid_window_trading_has_no_budget() {
    // Snapshot capture has no per-trade record, so nothing bounds how much a
    // pending market trades: one mint past the retired delta-log floor lands
    // while the market awaits its value leg, and the flush still completes on
    // its frozen figure.
    let (mut fx, expiry_id, trader) = helpers::setup_everything();
    fx.bootstrap_lock(SUPPLY_AMOUNT);
    fx.scenario_mut().next_tx(test_constants::alice());
    let mut market = fx.take_market_bundle(expiry_id);
    let mut account = fx.take_account_bundle(&trader);

    fx.scenario_mut().next_tx(test_constants::alice());
    fx.start_flush_bundle(&mut market);
    // One past the retired delta-log floor (64), where the old mechanism's
    // 65th trade aborted at that setting.
    let past_retired_log_floor = 65;
    let mut minted = 0;
    while (minted < past_retired_log_floor) {
        fx.mint_bundle(
            &mut market,
            &mut account,
            helpers::strike_tick(),
            helpers::pos_inf_tick(),
            constants::position_lot_size!() * 400,
        );
        minted = minted + 1;
    };
    fx.value_expiry_bundle(&mut market);
    // The stamp is cleared: trading also continues before the flush finishes.
    let _reopened = fx.mint_bundle(
        &mut market,
        &mut account,
        helpers::strike_tick(),
        helpers::pos_inf_tick(),
        constants::position_lot_size!() * 400,
    );
    fx.finish_flush_bundle(&mut market, option::none(), option::none());

    helpers::return_account_bundle(account);
    helpers::return_market_bundle(market);
    fx.finish();
}

// === Helpers ===

/// One undisturbed staged flush over the bundle's single market; returns the
/// mark the LP drain was priced at.
fun run_undisturbed_flush(fx: &mut helpers::Fixture, market: &mut helpers::MarketBundle): u64 {
    fx.scenario_mut().next_tx(test_constants::alice());
    fx.start_flush_bundle(market);
    fx.value_expiry_bundle(market);
    fx.finish_flush_bundle(market, option::none(), option::none())
}
