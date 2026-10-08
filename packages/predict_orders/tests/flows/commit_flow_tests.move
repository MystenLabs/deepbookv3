// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Flow coverage for `commit`, driven through `commit_for_testing` because a
/// real Pyth Lazer `Update` has no Move test constructor (`lazer_price` tests
/// its decode, including the missing-feed and missing-property aborts): which
/// update prices which cohort (exact τ, other channels, the one backup tick
/// after the gap wait, including across a policy channel switch), the
/// all-or-nothing commit of a cohort and its pre-check of the price's
/// generation and envelope times, prices that leave a cohort waiting, overdue
/// cohorts, the subsidy reservation escrowed in each record, and the gates
/// Predict's `commit` applies.
///
/// Every scenario places exact-quantity mints at the fixture clock 120_000 under
/// the fixture policy (delay 1_000, channel `fixed_rate@200ms`, stall 5_000), so
/// the first cohort's τ is floor((120_000 + 1_000) / 200) * 200 = 121_000 and its
/// deadline is 121_000 + 5_000 = 126_000. A second placement at 120_200 lands on
/// τ = floor(121_200 / 200) * 200 = 121_200 with deadline 126_200.
#[test_only]
module deepbook_predict_orders::commit_flow_tests;

use deepbook_predict::{protocol_config, test_constants};
use deepbook_predict_orders::{
    order_queue,
    queue_event_views as events,
    queue_fixture::{Self as fixture, QueueTest}
};
use std::unit_test::assert_eq;

const QUANTITY: u64 = 4_000_000;
const MAX_COST: u64 = 3_000_000;
const TAU: u64 = 121_000;
const SECOND_PLACEMENT_MS: u64 = 120_200;
const SECOND_TAU: u64 = 121_200;
const DEADLINE: u64 = 126_000;
const GAP_WAIT_MS: u64 = 2_000;
/// Channel tick lengths, which are also the only nonzero price buffers each
/// channel allows.
const TICK_200MS: u64 = 200;
const TICK_50MS: u64 = 50;
const US_PER_MS: u64 = 1_000;
const CHANNEL_50MS: u8 = 2;
/// The fixture's default subsidy rate (20%) applies to an exact-quantity order's
/// subsidy bound: its t₀ pre-subsidy trading fee, 0.005 * 4m = 20_000 (the far
/// expiry keeps the fee ramp at 1), well inside what the 3m budget could pay.
/// mul_down(20_000, 0.2) = 4_000.
const RESERVED_SUBSIDY: u64 = 4_000;
/// 10 USDC of incentives.
const INCENTIVES: u64 = 10_000_000;
const ORDER_FEE: u64 = 20_000;

// === Matching ===

#[test]
fun commit_exact_tau_update_commits_the_whole_cohort() {
    let mut q = fixture::new();
    let first = place_mint(&mut q);
    let second = place_mint(&mut q);

    q.commit_at(TAU, live_price());

    vector[first, second].do!(|record_id| {
        let order = q.record(record_id);
        assert_eq!(order.status(), order_queue::status_committed());
        assert_eq!(order.price().spot(), live_price());
        assert_eq!(order.price().tick_ms(), TAU);
        assert_eq!(order.price().generation_us(), TAU * US_PER_MS);
    });
    let (_, next_id, last_tau_ms, last_committed_tau_ms) = q.queue().queue_heads();
    assert_eq!(next_id, 2);
    assert_eq!(last_tau_ms, TAU);
    assert_eq!(last_committed_tau_ms, TAU);
    let (cohorts, oldest_uncommitted, _) = q.queue().waiting_cohorts();
    assert_eq!(cohorts, 1);
    assert!(oldest_uncommitted.is_none());
    q.assert_invariants();
    q.finish();
}

#[test]
fun commit_reports_the_cohort_in_cohort_committed() {
    let mut q = fixture::new();
    let first = place_mint(&mut q);
    let second = place_mint(&mut q);

    q.commit_at(TAU, live_price());

    let commits = events::commits();
    assert_eq!(commits.length(), 1);
    let commit = commits[0];
    assert_eq!(commit.commit_market_id(), q.expiry_id());
    assert_eq!(commit.commit_tau_ms(), TAU);
    assert_eq!(commit.commit_tick_ms(), TAU);
    assert_eq!(commit.commit_first_record_id(), first);
    assert_eq!(commit.commit_last_record_id(), second);
    assert_eq!(commit.commit_spot(), live_price());
    assert_eq!(commit.commit_generation_us(), TAU * US_PER_MS);
    assert_eq!(commit.commit_pyth_source_id(), test_constants::pyth_feed_id());
    assert_eq!(commit.commit_pyth_channel(), fixture::channel_200ms());
    assert_eq!(commit.commit_sender(), test_constants::alice());
    assert_eq!(commit.commit_onchain_timestamp_ms(), TAU);
    q.finish();
}

/// Anyone may commit: the event names a third-party sender.
#[test]
fun a_third_party_commits_and_is_named_in_the_event() {
    let mut q = fixture::new();
    place_mint(&mut q);
    let mut q = q.next_tx(test_constants::bob());

    q.commit_at(TAU, live_price());

    assert_eq!(events::commits()[0].commit_sender(), test_constants::bob());
    q.finish();
}

#[test]
fun commit_skips_updates_that_match_no_cohort() {
    let mut q = fixture::new();
    let record_id = place_mint(&mut q);
    // Past the gap wait, so only the zero price buffer keeps the later tick out.
    q.set_clock(TAU + GAP_WAIT_MS);

    q.commit(vector[
        // One tick past τ: no exact match, and no backup at buffer 0.
        fixture::price_update(TAU + TICK_200MS, live_price()),
        // Stamped τ, but on the 50 ms channel the cohort was not placed on.
        fixture::update_on(CHANNEL_50MS, TAU, live_price()),
        // One µs past τ: never τ, even though it rounds to τ in ms.
        fixture::update_with(
            fixture::channel_200ms(),
            TAU * US_PER_MS + 1,
            TAU * US_PER_MS + 1,
            live_price(),
        ),
    ]);

    assert_eq!(q.record(record_id).status(), order_queue::status_pending());
    assert_eq!(last_committed_tau_ms(&q), 0);
    let (cohorts, oldest_uncommitted, oldest_above_committed) = q.queue().waiting_cohorts();
    assert_eq!(cohorts, 1);
    assert_eq!(oldest_uncommitted, option::some(TAU));
    assert_eq!(oldest_above_committed, option::some(TAU));
    assert!(events::commits().is_empty());
    q.finish();
}

#[test]
fun commit_backup_tick_waits_for_the_gap() {
    let mut q = fixture::new();
    q.set_channel(fixture::channel_200ms(), TICK_200MS);
    let record_id = place_mint(&mut q);
    let updates = vector[fixture::price_update(TAU + TICK_200MS, live_price())];

    // One ms before τ + gap_wait: the backup tick is not yet accepted.
    q.set_clock(TAU + GAP_WAIT_MS - 1);
    q.commit(updates);
    assert_eq!(q.record(record_id).status(), order_queue::status_pending());
    assert!(events::commits().is_empty());

    q.set_clock(TAU + GAP_WAIT_MS);
    q.commit(updates);
    let order = q.record(record_id);
    assert_eq!(order.status(), order_queue::status_committed());
    assert_eq!(order.price().tick_ms(), TAU + TICK_200MS);
    assert_eq!(order.price().generation_us(), (TAU + TICK_200MS) * US_PER_MS);
    // The cohort's τ, not the backup tick, is what `last_committed_tau_ms` tracks.
    assert_eq!(last_committed_tau_ms(&q), TAU);
    let commits = events::commits();
    assert_eq!(commits.length(), 1);
    assert_eq!(commits[0].commit_tau_ms(), TAU);
    assert_eq!(commits[0].commit_tick_ms(), TAU + TICK_200MS);
    q.finish();
}

#[test]
fun commit_accepts_only_the_next_channel_tick_as_backup() {
    let mut q = fixture::new();
    q.set_channel(fixture::channel_200ms(), TICK_200MS);
    let record_id = place_mint(&mut q);
    q.set_clock(TAU + GAP_WAIT_MS);

    // Off the channel grid, and two ticks past τ: neither is a backup.
    q.commit(vector[
        fixture::price_update(TAU + TICK_200MS / 2, live_price()),
        fixture::price_update(TAU + 2 * TICK_200MS, live_price()),
    ]);
    assert_eq!(q.record(record_id).status(), order_queue::status_pending());
    assert!(events::commits().is_empty());

    // The next tick commits wherever it sits in the list.
    q.commit(vector[
        fixture::price_update(TAU + 2 * TICK_200MS, live_price()),
        fixture::price_update(TAU + TICK_200MS, live_price()),
    ]);
    assert_eq!(q.record(record_id).price().tick_ms(), TAU + TICK_200MS);
    q.finish();
}

#[test]
fun commit_exact_tau_update_beats_an_earlier_listed_backup() {
    let mut q = fixture::new();
    q.set_channel(fixture::channel_200ms(), TICK_200MS);
    let record_id = place_mint(&mut q);
    q.set_clock(TAU + GAP_WAIT_MS);

    q.commit(vector[
        fixture::price_update(TAU + TICK_200MS, live_price()),
        fixture::price_update(TAU, live_price()),
    ]);

    assert_eq!(q.record(record_id).price().tick_ms(), TAU);
    q.finish();
}

#[test]
fun commit_backup_follows_a_50ms_cohort_after_the_policy_moves_to_200ms() {
    let mut q = fixture::new();
    q.set_channel(CHANNEL_50MS, TICK_50MS);
    // floor((120_000 + 1_000) / 50) * 50 = 121_000 on the 50 ms channel.
    let record_id = place_mint(&mut q);
    q.set_channel(fixture::channel_200ms(), TICK_200MS);
    q.set_clock(TAU + GAP_WAIT_MS);

    // The 200 ms buffer does not widen the waiting cohort's window: later 50 ms
    // ticks and a 200 ms tick are all refused.
    q.commit(vector[
        fixture::update_on(CHANNEL_50MS, TAU + 2 * TICK_50MS, live_price()),
        fixture::update_on(CHANNEL_50MS, TAU + 3 * TICK_50MS, live_price()),
        fixture::update_on(CHANNEL_50MS, TAU + TICK_200MS, live_price()),
        fixture::update_on(fixture::channel_200ms(), TAU + TICK_200MS, live_price()),
    ]);
    assert_eq!(q.record(record_id).status(), order_queue::status_pending());
    assert!(events::commits().is_empty());

    q.commit(vector[fixture::update_on(CHANNEL_50MS, TAU + TICK_50MS, live_price())]);
    let order = q.record(record_id);
    assert_eq!(order.status(), order_queue::status_committed());
    assert_eq!(order.price().tick_ms(), TAU + TICK_50MS);
    q.finish();
}

#[test]
fun commit_backup_follows_a_200ms_cohort_after_the_policy_moves_to_50ms() {
    let mut q = fixture::new();
    // Placed under the default 200 ms channel with no buffer.
    let record_id = place_mint(&mut q);
    q.set_channel(CHANNEL_50MS, TICK_50MS);
    q.set_clock(TAU + GAP_WAIT_MS);

    // Neither a 50 ms-later tick on the cohort's channel nor one on the new
    // policy channel is its backup.
    q.commit(vector[
        fixture::update_on(fixture::channel_200ms(), TAU + TICK_50MS, live_price()),
        fixture::update_on(CHANNEL_50MS, TAU + TICK_50MS, live_price()),
    ]);
    assert_eq!(q.record(record_id).status(), order_queue::status_pending());

    // Its own next 200 ms tick commits it, beyond the 50 ms buffer: the buffer
    // only switches the backup on.
    q.commit(vector[fixture::update_on(fixture::channel_200ms(), TAU + TICK_200MS, live_price())]);
    assert_eq!(q.record(record_id).price().tick_ms(), TAU + TICK_200MS);
    q.finish();
}

#[test]
fun commit_one_update_prices_two_cohorts() {
    let mut q = fixture::new();
    q.set_channel(fixture::channel_200ms(), TICK_200MS);
    let first = place_mint(&mut q);
    q.set_clock(SECOND_PLACEMENT_MS);
    let second = place_mint(&mut q);
    // Past the first cohort's gap wait, before either deadline.
    q.set_clock(TAU + GAP_WAIT_MS);

    // Stamped the second cohort's τ, which is also the first cohort's next
    // 200 ms tick, so it is the first cohort's backup.
    q.commit(vector[fixture::price_update(SECOND_TAU, live_price())]);

    assert_eq!(q.record(first).price().tick_ms(), SECOND_TAU);
    assert_eq!(q.record(second).price().tick_ms(), SECOND_TAU);
    assert_eq!(last_committed_tau_ms(&q), SECOND_TAU);
    let commits = events::commits();
    assert_eq!(commits.length(), 2);
    assert_eq!(commits[0].commit_tau_ms(), TAU);
    assert_eq!(commits[1].commit_tau_ms(), SECOND_TAU);
    q.finish();
}

#[test]
fun commit_prices_cohorts_in_any_order_and_keeps_the_committed_tau_monotone() {
    let mut q = fixture::new();
    let first = place_mint(&mut q);
    q.set_clock(SECOND_PLACEMENT_MS);
    let second = place_mint(&mut q);

    // The later cohort commits first and never waits on the earlier one.
    q.commit_at(SECOND_TAU, live_price());
    assert_eq!(q.record(first).status(), order_queue::status_pending());
    assert_eq!(q.record(second).status(), order_queue::status_committed());
    assert_eq!(last_committed_tau_ms(&q), SECOND_TAU);

    q.commit(vector[fixture::price_update(TAU, live_price())]);
    assert_eq!(q.record(first).status(), order_queue::status_committed());
    assert_eq!(last_committed_tau_ms(&q), SECOND_TAU);
    q.finish();
}

#[test]
fun commit_twice_is_a_no_op() {
    let mut q = fixture::new();
    let record_id = place_mint(&mut q);
    q.commit_at(TAU, live_price());
    // A different price for the same τ cannot overwrite the committed one.
    q.commit(vector[fixture::price_update(TAU, live_price() + test_constants::float())]);

    assert_eq!(q.record(record_id).price().spot(), live_price());
    assert_eq!(events::commits().length(), 1);
    q.assert_invariants();
    q.finish();
}

// === Cohorts that stay waiting ===

#[test]
fun commit_never_commits_a_cohort_at_or_past_its_deadline() {
    let mut q = fixture::new();
    let first = place_mint(&mut q);
    q.set_clock(SECOND_PLACEMENT_MS);
    let second = place_mint(&mut q);
    // Exactly the first cohort's deadline, one tick before the second's.
    q.set_clock(DEADLINE);

    q.commit(vector[
        fixture::price_update(TAU, live_price()),
        fixture::price_update(SECOND_TAU, live_price()),
    ]);

    let overdue = q.record(first);
    assert_eq!(overdue.status(), order_queue::status_pending());
    assert_eq!(overdue.price().tick_ms(), 0);
    assert_eq!(q.record(second).status(), order_queue::status_committed());
    // Only the second cohort raised it; nothing marks the first RefundDue.
    assert_eq!(last_committed_tau_ms(&q), SECOND_TAU);
    assert_eq!(events::commits().length(), 1);
    q.finish();
}

/// An empty price, a price generated before τ, and an update whose envelope is
/// after the Sui clock each leave the whole cohort waiting, so Predict's
/// `commit` is never reached with a price it would refuse. The cohort still
/// commits on a usable update before its deadline.
#[test]
fun commit_leaves_the_cohort_waiting_on_an_unusable_early_or_future_price() {
    let mut q = fixture::new();
    let record_id = place_mint(&mut q);
    // Stamped τ, but the Sui clock is still one ms short of it.
    q.set_clock(TAU - 1);
    q.commit(vector[fixture::price_update(TAU, live_price())]);
    assert_eq!(q.record(record_id).status(), order_queue::status_pending());
    q.set_clock(TAU);
    let unusable = vector[
        // The feed carries no price at τ.
        fixture::empty_update(fixture::channel_200ms(), TAU),
        // Generated one µs before τ.
        fixture::update_with(
            fixture::channel_200ms(),
            TAU * US_PER_MS,
            TAU * US_PER_MS - 1,
            live_price(),
        ),
    ];
    unusable.do!(|update| {
        q.commit(vector[update]);
        assert_eq!(q.record(record_id).status(), order_queue::status_pending());
        assert_eq!(last_committed_tau_ms(&q), 0);
    });
    assert!(events::commits().is_empty());

    q.commit_at(TAU, live_price());
    assert_eq!(q.record(record_id).status(), order_queue::status_committed());
    assert_eq!(events::commits().length(), 1);
    q.finish();
}

/// One unusable price for any Pending order leaves every order of the cohort
/// waiting: a cohort commits whole or not at all.
#[test]
fun one_unusable_order_price_holds_back_the_whole_cohort() {
    let mut q = fixture::new();
    let first = place_mint(&mut q);
    let second = place_mint(&mut q);
    q.set_clock(TAU);

    q.commit(vector[fixture::empty_update(fixture::channel_200ms(), TAU)]);

    assert_eq!(q.record(first).status(), order_queue::status_pending());
    assert_eq!(q.record(second).status(), order_queue::status_pending());
    let (waiting_cash_need, _) = q.ledger();
    assert_eq!(waiting_cash_need, q.cash_need_sum());
    q.finish();
}

/// A record refunded inside a waiting cohort is skipped; the rest commit.
#[test]
fun commit_skips_a_record_refunded_inside_the_cohort() {
    let mut q = fixture::new();
    let refunded = place_mint(&mut q);
    let waiting = place_mint(&mut q);
    q.admin_refund(vector[refunded]);

    q.commit_at(TAU, live_price());

    assert_eq!(q.record(refunded).status(), order_queue::status_refunded());
    assert_eq!(q.record(waiting).status(), order_queue::status_committed());
    let commits = events::commits();
    assert_eq!(commits.length(), 1);
    q.assert_invariants();
    q.finish();
}

// === Subsidy ===

/// Predict reserves each mint's subsidy at commit; the reservation joins that
/// record's own escrow.
#[test]
fun commit_reserves_each_mint_subsidy_into_its_record() {
    let mut q = fixture::new();
    q.fund_incentives(INCENTIVES);
    let incentives = q.market().fee_incentive_balance();
    assert!(incentives >= 2 * RESERVED_SUBSIDY);
    let first = place_mint(&mut q);
    let second = place_mint(&mut q);

    q.commit_at(TAU, live_price());

    vector[first, second].do!(|record_id| {
        let record = q.record(record_id);
        assert_eq!(record.escrow().subsidy_reserved(), RESERVED_SUBSIDY);
        assert_eq!(record.funds(), MAX_COST + ORDER_FEE + RESERVED_SUBSIDY);
    });
    assert_eq!(q.market().fee_incentive_balance(), incentives - 2 * RESERVED_SUBSIDY);
    q.assert_invariants();
    q.finish();
}

// === Gates ===

#[test, expected_failure(abort_code = protocol_config::EProtocolFrozen)]
fun commit_while_frozen_aborts() {
    let mut q = fixture::new();
    place_mint(&mut q);
    q.set_frozen(true);
    q.commit_at(TAU, live_price());
    abort 999
}

/// With the witness removed, Predict refuses the commit.
#[test, expected_failure(abort_code = protocol_config::EOrderFlowNotAllowed)]
fun commit_with_the_witness_removed_aborts() {
    let mut q = fixture::new();
    place_mint(&mut q);
    q.set_witness(false);
    q.commit_at(TAU, live_price());
    abort 999
}

/// On a settled market nothing matches and nothing aborts.
#[test]
fun commit_on_a_settled_market_changes_nothing() {
    let mut q = fixture::new_at(test_constants::short_expiry_ms());
    let record_id = place_mint(&mut q);
    q.settle_market(live_price());

    q.commit(vector[fixture::price_update(TAU, live_price())]);

    assert_eq!(q.record(record_id).status(), order_queue::status_pending());
    assert!(events::commits().is_empty());
    q.finish();
}

// === Helpers ===

fun live_price(): u64 { fixture::live_price() }

fun place_mint(q: &mut QueueTest): u64 {
    q.enqueue_atm(QUANTITY, MAX_COST)
}

fun last_committed_tau_ms(q: &QueueTest): u64 {
    let (_, _, _, last_committed_tau_ms) = q.queue().queue_heads();
    last_committed_tau_ms
}
