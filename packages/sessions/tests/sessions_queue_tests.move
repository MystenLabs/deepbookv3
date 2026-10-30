// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Session wrappers over the order-flow companion's queue: the four enqueue
/// wrappers and their `_with_builder` versions, the session auth, builder
/// approval, and version gates in front of them, and the retired immediate
/// wrappers.
///
/// The auth and version tests abort in Sessions before the companion runs. The
/// flow tests drive the real queue (enqueue, commit, resolve, sell) and pin
/// what Sessions owns: each wrapper forwards its arguments into the named
/// request fields, and the record belongs to the Account, never to the session
/// key.
#[test_only]
module deepbook_sessions::sessions_queue_tests;

use account::{account::{Self, AccountWrapper}, account_registry::AccountRegistry};
use deepbook_predict::{
    builder_code::BuilderCode,
    expiry_market,
    flow_test_helpers::{Self as predict_helpers, Fixture, MarketBundle},
    order_events,
    protocol_config::ProtocolConfig,
    registry::Registry,
    test_constants
};
use deepbook_predict_orders::{
    desk::{Self, OrderDesk, QueueRegistry},
    order_flow::OrderFlow,
    order_queue::{Self, OrderView},
    queue::{Self, MarketQueue},
    queue_event_views as events,
    queue_fixture
};
use deepbook_sessions::{
    session_config::{Self as session_config, SessionsConfig},
    sessions::{Self as sessions, SessionsApp}
};
use std::{bcs, unit_test::{assert_eq, destroy}};
use sui::{
    accumulator::AccumulatorRoot,
    bcs as sui_bcs,
    deny_list,
    event,
    test_scenario::{most_recent_id_shared, return_shared}
};
use usdc::usdc::USDC;

const SESSION: address = @0x5E5510;
/// A second session key on the owner's Account.
const OTHER_SESSION: address = @0x5E5511;
const BOB: address = @0xB0B;
const KEEPER: address = @0x4EE9;

const SESSION_DURATION_MS: u64 = 60_000;
// The fixture clock starts at 120_000, so the grant expires at 120_000 + 60_000.
const SESSION_EXPIRES_AT_MS: u64 = 180_000;
// Mainnet Sessions runs version 3, so its live watermark is 3 until this
// upgrade's bump.
const MAINNET_WATERMARK: u64 = 3;
// One past this package's version 4: a watermark that retires it.
const RETIRING_WATERMARK: u64 = 5;

// Spec default order fee, 0.02 USDC.
const ORDER_FEE: u64 = 20_000;

// Exact-quantity mint: 100 contracts with a 90 USDC all-in cap and a 0.9
// probability cap. Every forwarded value is distinct so a swapped argument
// shows up in the stored request.
const MINT_QUANTITY: u64 = 100_000_000;
const QUANTITY_MAX_COST: u64 = 90_000_000;
const QUANTITY_MAX_PROBABILITY: u64 = 900_000_000;
// Budget = min(max_cost, quantity, available - fee) = min(90_000_000,
// 100_000_000, 999_980_000).
const QUANTITY_BUDGET: u64 = 90_000_000;

// Exact-amount mint: 40 USDC premium, at least two lots, 80 USDC all-in cap.
const AMOUNT_MAX_PREMIUM: u64 = 40_000_000;
const AMOUNT_MIN_QUANTITY: u64 = 20_000;
const AMOUNT_MAX_COST: u64 = 80_000_000;
// Budget = min(max_cost, available - fee) = min(80_000_000, 909_960_000).
const AMOUNT_BUDGET: u64 = 80_000_000;

// Exact-cost mint: 70 USDC all-in, at least three lots.
const COST_MAX_COST: u64 = 70_000_000;
const COST_MIN_QUANTITY: u64 = 30_000;
// Budget = min(max_cost, available - fee) = min(70_000_000, 819_940_000).
const COST_BUDGET: u64 = 70_000_000;

// 1_000_000_000 deposit - (90_000_000 + 20_000) - (80_000_000 + 20_000)
// - (70_000_000 + 20_000).
const BALANCE_AFTER_MINTS: u64 = 759_940_000;
// Two sells escrow only their order fees: 2 * 20_000.
const TWO_SELL_FEES: u64 = 40_000;
// Sells lock no budget.
const SELL_BUDGET: u64 = 0;

// Sell floors, distinct per field and per sell.
const QUANTITY_SELL_MIN_PROBABILITY: u64 = 1;
const QUANTITY_SELL_MIN_PROCEEDS: u64 = 2;
const COST_SELL_MIN_PROBABILITY: u64 = 3;
const COST_SELL_MIN_PROCEEDS: u64 = 4;

// The keeper lands τ's update 100 ms after τ, well inside the 5_000 ms stall
// timeout.
const PRICE_LANDING_MS: u64 = 100;
const RESOLVE_BATCH: u64 = 10;
const THREE_ORDERS: u64 = 3;

const MISSING_RECORD_ID: u64 = 0;
/// No position this test suite holds; the retired redeem aborts before it looks.
const UNUSED_ORDER_ID: u256 = 1;
const ZERO_FLOOR: u64 = 0;
const EUnexpectedSuccess: u64 = 999;

// Builder approvals: a session approved for code A at a 0.0005 per-contract
// maximum. The 100m mint pays 100m * 0.0005 = 50_000 at that fee.
const APPROVED_MAX_FEE: u64 = 500_000;
const FEE_ABOVE_APPROVED: u64 = 500_001;
const REPLACED_MAX_FEE: u64 = 300_000;
const BUILDER_FEE_ON_MINT: u64 = 50_000;
const CODE_A_INDEX: u64 = 0;
const CODE_B_INDEX: u64 = 1;
const ONE_ORDER: u64 = 1;
/// A zero builder fee: what an app that charges nothing approves and names, and
/// what a trade naming no builder records and pays.
const ZERO_BUILDER_FEE: u64 = 0;
// Fees under APPROVED_MAX_FEE, one per remaining builder wrapper and distinct,
// so a fee forwarded from the wrong argument shows up in its record.
const AMOUNT_BUILDER_FEE: u64 = 200_000;
const COST_BUILDER_FEE: u64 = 100_000;
const SELL_BUILDER_FEE: u64 = 400_000;
/// An approval at the whole $1 payout per contract, 1e9 in FLOAT_SCALING: the
/// highest cap Predict's admin can set, so it sits above the cap in force.
const WHOLE_PAYOUT_MAX_FEE: u64 = 1_000_000_000;
/// Predict's default builder fee cap, 5c per contract
/// (`config_constants::default_builder_fee_cap`). The fixture never changes it.
const DEFAULT_BUILDER_FEE_CAP: u64 = 50_000_000;
/// 10c per contract: twice the cap, inside the $1 approval.
const FEE_ABOVE_CAP: u64 = 100_000_000;
/// The 100m mint pays the cap, not the 10c it named: floor(100_000_000 *
/// 50_000_000 / 1e9) = 5_000_000, 5c on each of 100 contracts.
const BUILDER_FEE_AT_CAP: u64 = 5_000_000;
const NO_EVENTS: u64 = 0;
const ONE_EVENT: u64 = 1;

/// Mirrors `sessions::SessionBuilderCleared` for a byte-for-byte event check.
public struct ExpectedSessionBuilderCleared has copy, drop {
    account_id: ID,
    session: address,
}

public struct QueueSessionFixture {
    predict: Fixture,
    market_id: ID,
    owner: address,
    sessions_config_id: ID,
    desk_id: ID,
    queue_id: ID,
}

/// Every shared object one session transaction needs, taken together.
public struct SessionTx {
    market: MarketBundle,
    account_registry: AccountRegistry,
    wrapper: AccountWrapper,
    sessions_config: SessionsConfig,
    root: AccumulatorRoot,
    desk: OrderDesk,
    queue: MarketQueue,
}

// === Session auth ===

#[test, expected_failure(abort_code = sessions::ESessionNotAuthorized)]
fun unapproved_session_cannot_enqueue_exact_quantity() {
    let mut fixture = setup();
    let owner = fixture.owner;
    let mut tx = begin_tx(&mut fixture, SESSION, owner);
    session_enqueue_exact_quantity(
        &mut fixture,
        &mut tx,
        MINT_QUANTITY,
        QUANTITY_MAX_COST,
        QUANTITY_MAX_PROBABILITY,
    );
    abort EUnexpectedSuccess
}

#[test, expected_failure(abort_code = sessions::ESessionNotAuthorized)]
fun unapproved_session_cannot_enqueue_exact_amount() {
    let mut fixture = setup();
    let owner = fixture.owner;
    let mut tx = begin_tx(&mut fixture, SESSION, owner);
    session_enqueue_exact_amount(
        &mut fixture,
        &mut tx,
        AMOUNT_MAX_PREMIUM,
        AMOUNT_MIN_QUANTITY,
        AMOUNT_MAX_COST,
    );
    abort EUnexpectedSuccess
}

#[test, expected_failure(abort_code = sessions::ESessionNotAuthorized)]
fun unapproved_session_cannot_enqueue_exact_cost() {
    let mut fixture = setup();
    let owner = fixture.owner;
    let mut tx = begin_tx(&mut fixture, SESSION, owner);
    session_enqueue_exact_cost(&mut fixture, &mut tx, COST_MAX_COST, COST_MIN_QUANTITY);
    abort EUnexpectedSuccess
}

#[test, expected_failure(abort_code = sessions::ESessionNotAuthorized)]
fun unapproved_session_cannot_enqueue_redeem_open() {
    let mut fixture = setup();
    let owner = fixture.owner;
    let mut tx = begin_tx(&mut fixture, SESSION, owner);
    session_enqueue_redeem_open(
        &mut fixture,
        &mut tx,
        MISSING_RECORD_ID,
        MINT_QUANTITY,
        ZERO_FLOOR,
        ZERO_FLOOR,
    );
    abort EUnexpectedSuccess
}

#[test, expected_failure(abort_code = sessions::ESessionNotAuthorized)]
fun session_at_exact_expiration_cannot_enqueue() {
    let mut fixture = setup();
    authorize_session(&mut fixture, SESSION_DURATION_MS);
    fixture.predict.set_clock_for_testing(SESSION_EXPIRES_AT_MS);
    let owner = fixture.owner;
    let mut tx = begin_tx(&mut fixture, SESSION, owner);
    session_enqueue_exact_cost(&mut fixture, &mut tx, COST_MAX_COST, COST_MIN_QUANTITY);
    abort EUnexpectedSuccess
}

#[test, expected_failure(abort_code = sessions::ESessionNotAuthorized)]
fun session_at_exact_expiration_cannot_sell() {
    let mut fixture = setup();
    authorize_session(&mut fixture, SESSION_DURATION_MS);
    fixture.predict.set_clock_for_testing(SESSION_EXPIRES_AT_MS);
    let owner = fixture.owner;
    let mut tx = begin_tx(&mut fixture, SESSION, owner);
    session_enqueue_redeem_open(
        &mut fixture,
        &mut tx,
        MISSING_RECORD_ID,
        MINT_QUANTITY,
        ZERO_FLOOR,
        ZERO_FLOOR,
    );
    abort EUnexpectedSuccess
}

#[test, expected_failure(abort_code = sessions::ESessionNotAuthorized)]
fun session_approved_on_one_account_cannot_enqueue_for_another() {
    let mut fixture = setup();
    authorize_session(&mut fixture, SESSION_DURATION_MS);
    // Bob's funded account never granted SESSION.
    fixture.predict.create_funded_manager_as(BOB, test_constants::mint_deposit());
    let mut tx = begin_tx(&mut fixture, SESSION, BOB);
    session_enqueue_exact_cost(&mut fixture, &mut tx, COST_MAX_COST, COST_MIN_QUANTITY);
    abort EUnexpectedSuccess
}

#[test, expected_failure(abort_code = sessions::ESessionNotAuthorized)]
fun another_signer_cannot_sell_through_an_approved_session() {
    let mut fixture = setup();
    authorize_session(&mut fixture, SESSION_DURATION_MS);
    let owner = fixture.owner;
    let mut tx = begin_tx(&mut fixture, BOB, owner);
    session_enqueue_redeem_open(
        &mut fixture,
        &mut tx,
        MISSING_RECORD_ID,
        MINT_QUANTITY,
        ZERO_FLOOR,
        ZERO_FLOOR,
    );
    abort EUnexpectedSuccess
}

// === Version gating ===

#[test, expected_failure(abort_code = session_config::EPackageVersionDisabled)]
fun retired_package_version_cannot_enqueue() {
    let mut fixture = setup();
    authorize_session(&mut fixture, SESSION_DURATION_MS);
    let owner = fixture.owner;
    let mut tx = begin_tx(&mut fixture, SESSION, owner);
    session_config::set_version_watermark_for_testing(&mut tx.sessions_config, RETIRING_WATERMARK);
    session_enqueue_exact_cost(&mut fixture, &mut tx, COST_MAX_COST, COST_MIN_QUANTITY);
    abort EUnexpectedSuccess
}

#[test, expected_failure(abort_code = session_config::EPackageVersionDisabled)]
fun retired_package_version_cannot_sell() {
    let mut fixture = setup();
    authorize_session(&mut fixture, SESSION_DURATION_MS);
    let owner = fixture.owner;
    let mut tx = begin_tx(&mut fixture, SESSION, owner);
    session_config::set_version_watermark_for_testing(&mut tx.sessions_config, RETIRING_WATERMARK);
    session_enqueue_redeem_open(
        &mut fixture,
        &mut tx,
        MISSING_RECORD_ID,
        MINT_QUANTITY,
        ZERO_FLOOR,
        ZERO_FLOOR,
    );
    abort EUnexpectedSuccess
}

/// The approval is in place before the watermark retires this version, so the
/// version gate alone refuses the builder trade.
#[test, expected_failure(abort_code = session_config::EPackageVersionDisabled)]
fun retired_package_version_cannot_enqueue_with_a_builder() {
    let mut fixture = setup();
    authorize_session(&mut fixture, SESSION_DURATION_MS);
    let code_a = create_code(&mut fixture, CODE_A_INDEX);
    approve_builder(&mut fixture, code_a, APPROVED_MAX_FEE);
    let owner = fixture.owner;
    let mut tx = begin_tx(&mut fixture, SESSION, owner);
    session_config::set_version_watermark_for_testing(&mut tx.sessions_config, RETIRING_WATERMARK);
    session_enqueue_exact_quantity_with_builder(&mut fixture, &mut tx, code_a, APPROVED_MAX_FEE);
    abort EUnexpectedSuccess
}

#[test]
fun session_enqueues_while_the_mainnet_watermark_still_names_version_three() {
    // Between this upgrade and its bump the shared config still holds Mainnet's
    // watermark 3, and the version 4 wrappers must already serve.
    let mut fixture = setup();
    authorize_session(&mut fixture, SESSION_DURATION_MS);
    let owner = fixture.owner;
    let mut tx = begin_tx(&mut fixture, SESSION, owner);
    session_config::set_version_watermark_for_testing(&mut tx.sessions_config, MAINNET_WATERMARK);
    let record_id = session_enqueue_exact_cost(
        &mut fixture,
        &mut tx,
        COST_MAX_COST,
        COST_MIN_QUANTITY,
    );
    let order = record(&tx, record_id);
    assert_eq!(order.kind(), order_queue::kind_exact_cost());
    assert_eq!(order.request().max_cost(), COST_MAX_COST);
    assert_account_parties(&tx, &order, owner);
    assert_eq!(tx.sessions_config.version_watermark(), MAINNET_WATERMARK);
    end_tx(tx);
    finish(fixture);
}

// === Retired immediate wrappers ===

#[test, expected_failure(abort_code = expiry_market::EDelayedExecutionRequired)]
fun session_mint_exact_quantity_is_retired() {
    let mut fixture = setup();
    authorize_session(&mut fixture, SESSION_DURATION_MS);
    let owner = fixture.owner;
    let mut tx = begin_tx(&mut fixture, SESSION, owner);
    destroy(session_mint_exact_quantity(&mut fixture, &mut tx));
    abort EUnexpectedSuccess
}

#[test, expected_failure(abort_code = expiry_market::EDelayedExecutionRequired)]
fun session_mint_exact_amount_is_retired() {
    let mut fixture = setup();
    authorize_session(&mut fixture, SESSION_DURATION_MS);
    let owner = fixture.owner;
    let mut tx = begin_tx(&mut fixture, SESSION, owner);
    destroy(session_mint_exact_amount(&mut fixture, &mut tx));
    abort EUnexpectedSuccess
}

#[test, expected_failure(abort_code = expiry_market::EDelayedExecutionRequired)]
fun session_mint_exact_cost_is_retired() {
    let mut fixture = setup();
    authorize_session(&mut fixture, SESSION_DURATION_MS);
    let owner = fixture.owner;
    let mut tx = begin_tx(&mut fixture, SESSION, owner);
    destroy(session_mint_exact_cost(&mut fixture, &mut tx));
    abort EUnexpectedSuccess
}

#[test, expected_failure(abort_code = expiry_market::EDelayedExecutionRequired)]
fun session_redeem_live_is_retired() {
    let mut fixture = setup();
    authorize_session(&mut fixture, SESSION_DURATION_MS);
    let owner = fixture.owner;
    let mut tx = begin_tx(&mut fixture, SESSION, owner);
    destroy(session_redeem_live(&mut fixture, &mut tx, UNUSED_ORDER_ID));
    abort EUnexpectedSuccess
}

// === Queue flow ===

#[test]
fun session_places_every_order_kind_and_sells() {
    let mut fixture = setup();
    authorize_session(&mut fixture, SESSION_DURATION_MS);
    let (quantity_id, amount_id, cost_id, tau_ms) = place_three_mints(&mut fixture);
    fill_cohort(&mut fixture, tau_ms, vector[quantity_id, amount_id, cost_id]);
    sell_two_open_records(&mut fixture, quantity_id, amount_id, cost_id);
    finish(fixture);
}

// The flow test runs in phases so no one function passes the 255-local
// bytecode limit that the `assert_eq!` expansions would otherwise hit.

/// t₀: the session queues one mint of each kind in one transaction. Returns
/// the three record IDs and their shared τ.
fun place_three_mints(fixture: &mut QueueSessionFixture): (u64, u64, u64, u64) {
    let owner = fixture.owner;
    let mut tx = begin_tx(fixture, SESSION, owner);
    let quantity_id = session_enqueue_exact_quantity(
        fixture,
        &mut tx,
        MINT_QUANTITY,
        QUANTITY_MAX_COST,
        QUANTITY_MAX_PROBABILITY,
    );
    let amount_id = session_enqueue_exact_amount(
        fixture,
        &mut tx,
        AMOUNT_MAX_PREMIUM,
        AMOUNT_MIN_QUANTITY,
        AMOUNT_MAX_COST,
    );
    let cost_id = session_enqueue_exact_cost(fixture, &mut tx, COST_MAX_COST, COST_MIN_QUANTITY);
    assert_quantity_mint_record(&tx, quantity_id, owner);
    assert_amount_mint_record(&tx, amount_id, owner);
    assert_cost_mint_record(&tx, cost_id, owner);
    // The Account paid every budget and order fee into the records' escrow.
    assert_eq!(account_balance(fixture, &tx), BALANCE_AFTER_MINTS);
    assert_cash_need_matches(&tx);
    // One t₀ gives one τ, so a single update prices all three orders.
    let tau_ms = record(&tx, quantity_id).timing().tau_ms();
    end_tx(tx);
    (quantity_id, amount_id, cost_id, tau_ms)
}

/// A keeper commits τ's Lazer update and fills every order in `record_ids`.
fun fill_cohort(fixture: &mut QueueSessionFixture, tau_ms: u64, record_ids: vector<u64>) {
    fixture.predict.set_clock_for_testing(tau_ms + PRICE_LANDING_MS);
    let owner = fixture.owner;
    let mut tx = begin_tx(fixture, KEEPER, owner);
    let tx_fields = &mut tx;
    let (market, config, _, _, _) = tx_fields.market.market_parts_mut();
    let (clock, ctx) = fixture.predict.clock_and_ctx();
    tx_fields
        .queue
        .commit_for_testing(
            market,
            &tx_fields.desk,
            config,
            vector[queue_fixture::price_update(tau_ms, test_constants::default_live_price())],
            clock,
            ctx,
        );
    // No USDC address is denied here, so an empty deny list stands in for
    // Sui's shared one.
    let deny_list = deny_list::new_for_testing(ctx);
    let finished = tx_fields
        .queue
        .resolve(market, &tx_fields.desk, config, RESOLVE_BATCH, &deny_list, clock, ctx);
    destroy(deny_list);
    assert_eq!(finished, THREE_ORDERS);
    record_ids.do_ref!(|record_id| {
        assert_eq!(record(&tx, *record_id).status(), order_queue::status_open());
    });
    end_tx(tx);
}

/// The session sells the exact-quantity and exact-cost records whole from their
/// Open records and leaves the exact-amount record Open.
fun sell_two_open_records(
    fixture: &mut QueueSessionFixture,
    quantity_id: u64,
    amount_id: u64,
    cost_id: u64,
) {
    let owner = fixture.owner;
    let mut tx = begin_tx(fixture, SESSION, owner);
    // The fills landed past the setup seed's Block Scholes freshness window, so
    // reseed the feeds at the current clock for the sells' volatility snapshots.
    let now_ms = fixture.predict.clock().timestamp_ms();
    fixture
        .predict
        .advance_live_oracle_bundle_to(
            &mut tx.market,
            test_constants::default_live_price(),
            now_ms,
        );
    let quantity_position = record(&tx, quantity_id).position().order_id();
    let cost_order = record(&tx, cost_id);
    let cost_position = cost_order.position().order_id();
    let cost_quantity = cost_order.result().result_quantity();
    let balance_before_sells = account_balance(fixture, &tx);
    let quantity_sell_id = session_enqueue_redeem_open(
        fixture,
        &mut tx,
        quantity_id,
        MINT_QUANTITY,
        QUANTITY_SELL_MIN_PROBABILITY,
        QUANTITY_SELL_MIN_PROCEEDS,
    );
    let cost_sell_id = session_enqueue_redeem_open(
        fixture,
        &mut tx,
        cost_id,
        cost_quantity,
        COST_SELL_MIN_PROBABILITY,
        COST_SELL_MIN_PROCEEDS,
    );
    assert_eq!(balance_before_sells - account_balance(fixture, &tx), TWO_SELL_FEES);
    assert_sell_record(
        &tx,
        quantity_sell_id,
        MINT_QUANTITY,
        QUANTITY_SELL_MIN_PROBABILITY,
        QUANTITY_SELL_MIN_PROCEEDS,
        quantity_position,
        owner,
    );
    assert_sell_record(
        &tx,
        cost_sell_id,
        cost_quantity,
        COST_SELL_MIN_PROBABILITY,
        COST_SELL_MIN_PROCEEDS,
        cost_position,
        owner,
    );
    assert_eq!(record(&tx, quantity_id).status(), order_queue::status_closed());
    assert_eq!(record(&tx, cost_id).status(), order_queue::status_closed());
    assert_eq!(record(&tx, amount_id).status(), order_queue::status_open());
    assert_cash_need_matches(&tx);
    end_tx(tx);
}

// === Builder approvals ===

#[test]
fun approving_a_builder_records_it_and_reapproving_replaces_it() {
    let mut fixture = setup();
    authorize_session(&mut fixture, SESSION_DURATION_MS);
    let code_a = create_code(&mut fixture, CODE_A_INDEX);
    let code_b = create_code(&mut fixture, CODE_B_INDEX);
    approve_builder(&mut fixture, code_a, APPROVED_MAX_FEE);
    let approval = session_builder(&mut fixture).destroy_some();
    assert_eq!(approval.approved_code_id(), code_a);
    assert_eq!(approval.approved_max_fee_per_contract(), APPROVED_MAX_FEE);

    approve_builder(&mut fixture, code_b, REPLACED_MAX_FEE);
    let approval = session_builder(&mut fixture).destroy_some();
    assert_eq!(approval.approved_code_id(), code_b);
    assert_eq!(approval.approved_max_fee_per_contract(), REPLACED_MAX_FEE);
    finish(fixture);
}

#[test]
fun revoking_clears_the_builder_and_reauthorizing_keeps_it() {
    let mut fixture = setup();
    authorize_session(&mut fixture, SESSION_DURATION_MS);
    let code_a = create_code(&mut fixture, CODE_A_INDEX);
    approve_builder(&mut fixture, code_a, APPROVED_MAX_FEE);

    // Re-authorizing an existing grant clears nothing, so it emits no
    // `SessionBuilderCleared`.
    authorize_session(&mut fixture, SESSION_DURATION_MS);
    assert_eq!(event::events_by_type<sessions::SessionAuthorized>().length(), ONE_EVENT);
    assert_none_cleared();
    assert!(session_builder(&mut fixture).is_some());

    let account_id = account_id(&mut fixture);
    revoke_session(&mut fixture);
    assert_one_cleared(account_id);
    assert!(session_builder(&mut fixture).is_none());
    finish(fixture);
}

/// The pre-upgrade `revoke_session` stays callable and leaves the builder
/// approval behind. A new grant for that address clears it, so the session
/// needs a fresh approval.
#[test]
fun a_new_grant_clears_an_approval_the_old_revoke_left_behind() {
    let mut fixture = setup();
    authorize_session(&mut fixture, SESSION_DURATION_MS);
    let code_a = create_code(&mut fixture, CODE_A_INDEX);
    approve_builder(&mut fixture, code_a, APPROVED_MAX_FEE);

    revoke_session_leaving_approval(&mut fixture);
    assert!(session_builder(&mut fixture).is_some());

    let account_id = account_id(&mut fixture);
    authorize_session(&mut fixture, SESSION_DURATION_MS);
    assert_one_cleared(account_id);
    assert!(session_builder(&mut fixture).is_none());
    finish(fixture);
}

/// Builder approvals wait until the watermark retires the older Sessions
/// versions, whose `revoke_session` and `authorize_session` would together
/// keep a stale approval.
#[test, expected_failure(abort_code = sessions::EBuilderApprovalsNotEnabled)]
fun approving_a_builder_before_the_watermark_retires_older_sessions_aborts() {
    let mut fixture = setup();
    authorize_session(&mut fixture, SESSION_DURATION_MS);
    let code_a = create_code(&mut fixture, CODE_A_INDEX);
    let owner = fixture.owner;
    let mut tx = begin_tx(&mut fixture, owner, owner);
    let tx_fields = &mut tx;
    session_config::set_version_watermark_for_testing(
        &mut tx_fields.sessions_config,
        MAINNET_WATERMARK,
    );
    let (_, ctx) = fixture.predict.clock_and_ctx();
    sessions::approve_session_builder(
        &mut tx_fields.wrapper,
        &tx_fields.sessions_config,
        SESSION,
        code_a,
        APPROVED_MAX_FEE,
        ctx,
    );
    abort EUnexpectedSuccess
}

#[test, expected_failure(abort_code = sessions::ESessionNotAuthorized)]
fun approving_a_builder_for_an_unauthorized_session_aborts() {
    let mut fixture = setup();
    let code_a = create_code(&mut fixture, CODE_A_INDEX);
    approve_builder(&mut fixture, code_a, APPROVED_MAX_FEE);
    abort EUnexpectedSuccess
}

#[test, expected_failure(abort_code = account::EInvalidOwner)]
fun only_the_owner_can_approve_a_builder() {
    let mut fixture = setup();
    authorize_session(&mut fixture, SESSION_DURATION_MS);
    let code_a = create_code(&mut fixture, CODE_A_INDEX);
    let owner = fixture.owner;
    let mut tx = begin_tx(&mut fixture, SESSION, owner);
    let tx_fields = &mut tx;
    let (_, ctx) = fixture.predict.clock_and_ctx();
    sessions::approve_session_builder(
        &mut tx_fields.wrapper,
        &tx_fields.sessions_config,
        SESSION,
        code_a,
        APPROVED_MAX_FEE,
        ctx,
    );
    abort EUnexpectedSuccess
}

#[test]
fun an_approved_session_mint_records_its_fee_and_the_fill_pays_it() {
    let mut fixture = setup();
    authorize_session(&mut fixture, SESSION_DURATION_MS);
    let code_a = create_code(&mut fixture, CODE_A_INDEX);
    approve_builder(&mut fixture, code_a, APPROVED_MAX_FEE);

    let owner = fixture.owner;
    let mut tx = begin_tx(&mut fixture, SESSION, owner);
    let record_id = session_enqueue_exact_quantity_with_builder(
        &mut fixture,
        &mut tx,
        code_a,
        APPROVED_MAX_FEE,
    );
    assert_eq!(tx.queue.builder_fee_per_contract(record_id), APPROVED_MAX_FEE);
    let tau_ms = record(&tx, record_id).timing().tau_ms();
    end_tx(tx);

    fill_one(&mut fixture, tau_ms);
    let fill = events::fills()[0];
    assert_eq!(fill.record_id(), record_id);
    assert_eq!(fill.builder_fee(), BUILDER_FEE_ON_MINT);
    finish(fixture);
}

#[test, expected_failure(abort_code = sessions::EBuilderNotApproved)]
fun a_session_mint_with_a_builder_but_no_approval_aborts() {
    let mut fixture = setup();
    authorize_session(&mut fixture, SESSION_DURATION_MS);
    let code_a = create_code(&mut fixture, CODE_A_INDEX);
    let owner = fixture.owner;
    let mut tx = begin_tx(&mut fixture, SESSION, owner);
    session_enqueue_exact_quantity_with_builder(&mut fixture, &mut tx, code_a, APPROVED_MAX_FEE);
    abort EUnexpectedSuccess
}

#[test, expected_failure(abort_code = sessions::EBuilderNotApproved)]
fun a_session_mint_with_another_code_aborts() {
    let mut fixture = setup();
    authorize_session(&mut fixture, SESSION_DURATION_MS);
    let code_a = create_code(&mut fixture, CODE_A_INDEX);
    let code_b = create_code(&mut fixture, CODE_B_INDEX);
    approve_builder(&mut fixture, code_a, APPROVED_MAX_FEE);
    let owner = fixture.owner;
    let mut tx = begin_tx(&mut fixture, SESSION, owner);
    session_enqueue_exact_quantity_with_builder(&mut fixture, &mut tx, code_b, APPROVED_MAX_FEE);
    abort EUnexpectedSuccess
}

#[test, expected_failure(abort_code = sessions::EBuilderFeeAboveApproved)]
fun a_session_mint_above_the_approved_fee_aborts() {
    let mut fixture = setup();
    authorize_session(&mut fixture, SESSION_DURATION_MS);
    let code_a = create_code(&mut fixture, CODE_A_INDEX);
    approve_builder(&mut fixture, code_a, APPROVED_MAX_FEE);
    let owner = fixture.owner;
    let mut tx = begin_tx(&mut fixture, SESSION, owner);
    session_enqueue_exact_quantity_with_builder(
        &mut fixture,
        &mut tx,
        code_a,
        FEE_ABOVE_APPROVED,
    );
    abort EUnexpectedSuccess
}

#[test, expected_failure(abort_code = sessions::EBuilderNotApproved)]
fun a_revoked_and_reauthorized_session_needs_a_new_approval() {
    let mut fixture = setup();
    authorize_session(&mut fixture, SESSION_DURATION_MS);
    let code_a = create_code(&mut fixture, CODE_A_INDEX);
    approve_builder(&mut fixture, code_a, APPROVED_MAX_FEE);
    revoke_session(&mut fixture);
    authorize_session(&mut fixture, SESSION_DURATION_MS);
    let owner = fixture.owner;
    let mut tx = begin_tx(&mut fixture, SESSION, owner);
    session_enqueue_exact_quantity_with_builder(&mut fixture, &mut tx, code_a, APPROVED_MAX_FEE);
    abort EUnexpectedSuccess
}

#[test, expected_failure(abort_code = sessions::EBuilderNotApproved)]
fun a_session_amount_mint_with_a_builder_but_no_approval_aborts() {
    let mut fixture = setup();
    authorize_session(&mut fixture, SESSION_DURATION_MS);
    let code_a = create_code(&mut fixture, CODE_A_INDEX);
    let owner = fixture.owner;
    let mut tx = begin_tx(&mut fixture, SESSION, owner);
    session_enqueue_exact_amount_with_builder(&mut fixture, &mut tx, code_a, APPROVED_MAX_FEE);
    abort EUnexpectedSuccess
}

#[test, expected_failure(abort_code = sessions::EBuilderNotApproved)]
fun a_session_cost_mint_with_a_builder_but_no_approval_aborts() {
    let mut fixture = setup();
    authorize_session(&mut fixture, SESSION_DURATION_MS);
    let code_a = create_code(&mut fixture, CODE_A_INDEX);
    let owner = fixture.owner;
    let mut tx = begin_tx(&mut fixture, SESSION, owner);
    session_enqueue_exact_cost_with_builder(&mut fixture, &mut tx, code_a, APPROVED_MAX_FEE);
    abort EUnexpectedSuccess
}

#[test, expected_failure(abort_code = sessions::EBuilderNotApproved)]
fun a_session_sell_with_a_builder_but_no_approval_aborts() {
    let mut fixture = setup();
    authorize_session(&mut fixture, SESSION_DURATION_MS);
    let code_a = create_code(&mut fixture, CODE_A_INDEX);
    let owner = fixture.owner;
    let mut tx = begin_tx(&mut fixture, SESSION, owner);
    session_enqueue_redeem_open_with_builder(
        &mut fixture,
        &mut tx,
        code_a,
        APPROVED_MAX_FEE,
        MISSING_RECORD_ID,
        MINT_QUANTITY,
        ZERO_FLOOR,
        ZERO_FLOOR,
    );
    abort EUnexpectedSuccess
}

// --- What an approval does and does not change ---

/// The approval names what a builder trade may charge but forces no fee: the
/// plain wrapper names no builder, so the record and the fill carry none.
#[test]
fun an_approved_session_trading_without_a_builder_pays_no_builder_fee() {
    let mut fixture = setup();
    authorize_session(&mut fixture, SESSION_DURATION_MS);
    let code_a = create_code(&mut fixture, CODE_A_INDEX);
    approve_builder(&mut fixture, code_a, APPROVED_MAX_FEE);

    let owner = fixture.owner;
    let mut tx = begin_tx(&mut fixture, SESSION, owner);
    let record_id = session_enqueue_exact_quantity(
        &mut fixture,
        &mut tx,
        MINT_QUANTITY,
        QUANTITY_MAX_COST,
        QUANTITY_MAX_PROBABILITY,
    );
    assert_eq!(tx.queue.builder_fee_per_contract(record_id), ZERO_BUILDER_FEE);
    let tau_ms = record(&tx, record_id).timing().tau_ms();
    end_tx(tx);

    fill_one(&mut fixture, tau_ms);
    let fill = events::fills()[0];
    assert_eq!(fill.record_id(), record_id);
    assert_eq!(fill.builder_fee(), ZERO_BUILDER_FEE);
    let (minted_fee, minted_code) = minted_builder();
    assert_eq!(minted_fee, ZERO_BUILDER_FEE);
    assert!(minted_code.is_none());
    finish(fixture);
}

/// Sessions compares the named fee, uncapped, against the approval, and Predict
/// then caps it. A 10c fee inside a $1 approval passes Sessions, and the receipt
/// and the fill carry the 5c cap.
#[test]
fun a_session_fee_above_the_cap_is_recorded_and_charged_at_the_cap() {
    let mut fixture = setup();
    authorize_session(&mut fixture, SESSION_DURATION_MS);
    let code_a = create_code(&mut fixture, CODE_A_INDEX);
    approve_builder(&mut fixture, code_a, WHOLE_PAYOUT_MAX_FEE);

    let owner = fixture.owner;
    let mut tx = begin_tx(&mut fixture, SESSION, owner);
    assert_eq!(predict_helpers::config(&tx.market).builder_fee_cap(), DEFAULT_BUILDER_FEE_CAP);
    let record_id = session_enqueue_exact_quantity_with_builder(
        &mut fixture,
        &mut tx,
        code_a,
        FEE_ABOVE_CAP,
    );
    assert_eq!(tx.queue.builder_fee_per_contract(record_id), DEFAULT_BUILDER_FEE_CAP);
    let tau_ms = record(&tx, record_id).timing().tau_ms();
    end_tx(tx);

    fill_one(&mut fixture, tau_ms);
    let fill = events::fills()[0];
    assert_eq!(fill.record_id(), record_id);
    assert_eq!(fill.builder_fee(), BUILDER_FEE_AT_CAP);
    let (minted_fee, minted_code) = minted_builder();
    assert_eq!(minted_fee, BUILDER_FEE_AT_CAP);
    assert_eq!(minted_code, option::some(code_a));
    finish(fixture);
}

/// An app that charges nothing approves its code at a zero maximum. A zero fee
/// is at that maximum, so the trade passes, pays nothing, and still names the
/// code on its fill.
#[test]
fun a_zero_fee_approval_still_names_its_code_on_the_fill() {
    let mut fixture = setup();
    authorize_session(&mut fixture, SESSION_DURATION_MS);
    let code_a = create_code(&mut fixture, CODE_A_INDEX);
    approve_builder(&mut fixture, code_a, ZERO_BUILDER_FEE);

    let owner = fixture.owner;
    let mut tx = begin_tx(&mut fixture, SESSION, owner);
    let record_id = session_enqueue_exact_quantity_with_builder(
        &mut fixture,
        &mut tx,
        code_a,
        ZERO_BUILDER_FEE,
    );
    assert_eq!(tx.queue.builder_fee_per_contract(record_id), ZERO_BUILDER_FEE);
    let tau_ms = record(&tx, record_id).timing().tau_ms();
    end_tx(tx);

    fill_one(&mut fixture, tau_ms);
    let fill = events::fills()[0];
    assert_eq!(fill.record_id(), record_id);
    assert_eq!(fill.builder_fee(), ZERO_BUILDER_FEE);
    let (minted_fee, minted_code) = minted_builder();
    assert_eq!(minted_fee, ZERO_BUILDER_FEE);
    assert_eq!(minted_code, option::some(code_a));
    finish(fixture);
}

/// The amount and cost builder wrappers forward the named fee into each record,
/// beside the request fields, and the records belong to the Account. Both
/// budgets are their `max_cost`, as in the plain flow.
#[test]
fun approved_session_amount_and_cost_mints_record_their_builder_fees() {
    let mut fixture = setup();
    authorize_session(&mut fixture, SESSION_DURATION_MS);
    let code_a = create_code(&mut fixture, CODE_A_INDEX);
    approve_builder(&mut fixture, code_a, APPROVED_MAX_FEE);

    let owner = fixture.owner;
    let mut tx = begin_tx(&mut fixture, SESSION, owner);
    let amount_id = session_enqueue_exact_amount_with_builder(
        &mut fixture,
        &mut tx,
        code_a,
        AMOUNT_BUILDER_FEE,
    );
    assert_eq!(tx.queue.builder_fee_per_contract(amount_id), AMOUNT_BUILDER_FEE);
    assert_amount_mint_record(&tx, amount_id, owner);
    end_tx(tx);

    // The code was returned to the scenario, so the next mint takes it in a new
    // transaction.
    let mut tx = begin_tx(&mut fixture, SESSION, owner);
    let cost_id = session_enqueue_exact_cost_with_builder(
        &mut fixture,
        &mut tx,
        code_a,
        COST_BUILDER_FEE,
    );
    assert_eq!(tx.queue.builder_fee_per_contract(cost_id), COST_BUILDER_FEE);
    assert_cost_mint_record(&tx, cost_id, owner);
    end_tx(tx);
    finish(fixture);
}

/// The sell builder wrapper forwards the named fee into the sell's record, beside
/// the close quantity and floors. The position came from a plain mint, so the
/// fee is the sell's own.
#[test]
fun an_approved_session_sell_records_its_builder_fee() {
    let mut fixture = setup();
    authorize_session(&mut fixture, SESSION_DURATION_MS);
    let code_a = create_code(&mut fixture, CODE_A_INDEX);
    approve_builder(&mut fixture, code_a, APPROVED_MAX_FEE);

    let owner = fixture.owner;
    let mut tx = begin_tx(&mut fixture, SESSION, owner);
    let mint_id = session_enqueue_exact_quantity(
        &mut fixture,
        &mut tx,
        MINT_QUANTITY,
        QUANTITY_MAX_COST,
        QUANTITY_MAX_PROBABILITY,
    );
    let tau_ms = record(&tx, mint_id).timing().tau_ms();
    end_tx(tx);
    fill_one(&mut fixture, tau_ms);

    let mut tx = begin_tx(&mut fixture, SESSION, owner);
    // The fill landed past the setup seed's Block Scholes freshness window, so
    // reseed the feeds at the current clock for the sell's volatility snapshot.
    let now_ms = fixture.predict.clock().timestamp_ms();
    fixture
        .predict
        .advance_live_oracle_bundle_to(
            &mut tx.market,
            test_constants::default_live_price(),
            now_ms,
        );
    let position = record(&tx, mint_id).position().order_id();
    let sell_id = session_enqueue_redeem_open_with_builder(
        &mut fixture,
        &mut tx,
        code_a,
        SELL_BUILDER_FEE,
        mint_id,
        MINT_QUANTITY,
        QUANTITY_SELL_MIN_PROBABILITY,
        QUANTITY_SELL_MIN_PROCEEDS,
    );
    assert_eq!(tx.queue.builder_fee_per_contract(sell_id), SELL_BUILDER_FEE);
    assert_sell_record(
        &tx,
        sell_id,
        MINT_QUANTITY,
        QUANTITY_SELL_MIN_PROBABILITY,
        QUANTITY_SELL_MIN_PROCEEDS,
        position,
        owner,
    );
    end_tx(tx);
    finish(fixture);
}

// --- Re-approval ---

#[test, expected_failure(abort_code = sessions::EBuilderNotApproved)]
fun after_reapproval_the_old_code_is_refused() {
    let mut fixture = setup();
    authorize_session(&mut fixture, SESSION_DURATION_MS);
    let code_a = create_code(&mut fixture, CODE_A_INDEX);
    let code_b = create_code(&mut fixture, CODE_B_INDEX);
    approve_builder(&mut fixture, code_a, APPROVED_MAX_FEE);
    approve_builder(&mut fixture, code_b, REPLACED_MAX_FEE);
    let owner = fixture.owner;
    let mut tx = begin_tx(&mut fixture, SESSION, owner);
    session_enqueue_exact_quantity_with_builder(&mut fixture, &mut tx, code_a, REPLACED_MAX_FEE);
    abort EUnexpectedSuccess
}

#[test]
fun after_reapproval_the_new_code_trades_at_its_new_max() {
    let mut fixture = setup();
    authorize_session(&mut fixture, SESSION_DURATION_MS);
    let code_a = create_code(&mut fixture, CODE_A_INDEX);
    let code_b = create_code(&mut fixture, CODE_B_INDEX);
    approve_builder(&mut fixture, code_a, APPROVED_MAX_FEE);
    approve_builder(&mut fixture, code_b, REPLACED_MAX_FEE);
    let owner = fixture.owner;
    let mut tx = begin_tx(&mut fixture, SESSION, owner);
    let record_id = session_enqueue_exact_quantity_with_builder(
        &mut fixture,
        &mut tx,
        code_b,
        REPLACED_MAX_FEE,
    );
    assert_eq!(tx.queue.builder_fee_per_contract(record_id), REPLACED_MAX_FEE);
    end_tx(tx);
    finish(fixture);
}

/// Re-approval replaces the maximum with the code: the first approval's higher
/// maximum no longer passes.
#[test, expected_failure(abort_code = sessions::EBuilderFeeAboveApproved)]
fun reapproval_replaces_the_approved_max_fee() {
    let mut fixture = setup();
    authorize_session(&mut fixture, SESSION_DURATION_MS);
    let code_a = create_code(&mut fixture, CODE_A_INDEX);
    let code_b = create_code(&mut fixture, CODE_B_INDEX);
    approve_builder(&mut fixture, code_a, APPROVED_MAX_FEE);
    approve_builder(&mut fixture, code_b, REPLACED_MAX_FEE);
    let owner = fixture.owner;
    let mut tx = begin_tx(&mut fixture, SESSION, owner);
    session_enqueue_exact_quantity_with_builder(&mut fixture, &mut tx, code_b, APPROVED_MAX_FEE);
    abort EUnexpectedSuccess
}

// --- Expiry and revocation ---

/// The session checks run before the builder checks, so an expired session's
/// approval does not let it trade.
#[test, expected_failure(abort_code = sessions::ESessionNotAuthorized)]
fun an_expired_session_cannot_trade_on_its_approval() {
    let mut fixture = setup();
    authorize_session(&mut fixture, SESSION_DURATION_MS);
    let code_a = create_code(&mut fixture, CODE_A_INDEX);
    approve_builder(&mut fixture, code_a, APPROVED_MAX_FEE);
    fixture.predict.set_clock_for_testing(SESSION_EXPIRES_AT_MS);
    let owner = fixture.owner;
    let mut tx = begin_tx(&mut fixture, SESSION, owner);
    session_enqueue_exact_quantity_with_builder(&mut fixture, &mut tx, code_a, APPROVED_MAX_FEE);
    abort EUnexpectedSuccess
}

/// Expiry ends a session's trading but removes nothing: the approval stays
/// readable, and re-authorizing the same address is an existing grant, which
/// keeps it.
#[test]
fun an_expired_session_keeps_its_approval_through_reauthorization() {
    let mut fixture = setup();
    authorize_session(&mut fixture, SESSION_DURATION_MS);
    let code_a = create_code(&mut fixture, CODE_A_INDEX);
    approve_builder(&mut fixture, code_a, APPROVED_MAX_FEE);
    fixture.predict.set_clock_for_testing(SESSION_EXPIRES_AT_MS);
    let approval = session_builder(&mut fixture).destroy_some();
    assert_eq!(approval.approved_code_id(), code_a);
    assert_eq!(approval.approved_max_fee_per_contract(), APPROVED_MAX_FEE);

    authorize_session(&mut fixture, SESSION_DURATION_MS);
    assert_eq!(event::events_by_type<sessions::SessionAuthorized>().length(), ONE_EVENT);
    assert_none_cleared();
    let approval = session_builder(&mut fixture).destroy_some();
    assert_eq!(approval.approved_code_id(), code_a);
    assert_eq!(approval.approved_max_fee_per_contract(), APPROVED_MAX_FEE);
    finish(fixture);
}

// Revoking also removes the approval, so a builder check run first would abort
// `EBuilderNotApproved`. Each builder wrapper runs the session checks first.

#[test, expected_failure(abort_code = sessions::ESessionNotAuthorized)]
fun a_revoked_session_cannot_enqueue_exact_quantity_with_a_builder() {
    let mut fixture = setup();
    authorize_session(&mut fixture, SESSION_DURATION_MS);
    let code_a = create_code(&mut fixture, CODE_A_INDEX);
    approve_builder(&mut fixture, code_a, APPROVED_MAX_FEE);
    revoke_session(&mut fixture);
    let owner = fixture.owner;
    let mut tx = begin_tx(&mut fixture, SESSION, owner);
    session_enqueue_exact_quantity_with_builder(&mut fixture, &mut tx, code_a, APPROVED_MAX_FEE);
    abort EUnexpectedSuccess
}

#[test, expected_failure(abort_code = sessions::ESessionNotAuthorized)]
fun a_revoked_session_cannot_enqueue_exact_amount_with_a_builder() {
    let mut fixture = setup();
    authorize_session(&mut fixture, SESSION_DURATION_MS);
    let code_a = create_code(&mut fixture, CODE_A_INDEX);
    approve_builder(&mut fixture, code_a, APPROVED_MAX_FEE);
    revoke_session(&mut fixture);
    let owner = fixture.owner;
    let mut tx = begin_tx(&mut fixture, SESSION, owner);
    session_enqueue_exact_amount_with_builder(&mut fixture, &mut tx, code_a, APPROVED_MAX_FEE);
    abort EUnexpectedSuccess
}

#[test, expected_failure(abort_code = sessions::ESessionNotAuthorized)]
fun a_revoked_session_cannot_enqueue_exact_cost_with_a_builder() {
    let mut fixture = setup();
    authorize_session(&mut fixture, SESSION_DURATION_MS);
    let code_a = create_code(&mut fixture, CODE_A_INDEX);
    approve_builder(&mut fixture, code_a, APPROVED_MAX_FEE);
    revoke_session(&mut fixture);
    let owner = fixture.owner;
    let mut tx = begin_tx(&mut fixture, SESSION, owner);
    session_enqueue_exact_cost_with_builder(&mut fixture, &mut tx, code_a, APPROVED_MAX_FEE);
    abort EUnexpectedSuccess
}

#[test, expected_failure(abort_code = sessions::ESessionNotAuthorized)]
fun a_revoked_session_cannot_sell_with_a_builder() {
    let mut fixture = setup();
    authorize_session(&mut fixture, SESSION_DURATION_MS);
    let code_a = create_code(&mut fixture, CODE_A_INDEX);
    approve_builder(&mut fixture, code_a, APPROVED_MAX_FEE);
    revoke_session(&mut fixture);
    let owner = fixture.owner;
    let mut tx = begin_tx(&mut fixture, SESSION, owner);
    session_enqueue_redeem_open_with_builder(
        &mut fixture,
        &mut tx,
        code_a,
        APPROVED_MAX_FEE,
        MISSING_RECORD_ID,
        MINT_QUANTITY,
        ZERO_FLOOR,
        ZERO_FLOOR,
    );
    abort EUnexpectedSuccess
}

/// The pre-upgrade revoke removes the session but leaves its approval, which
/// still names the code. Only the session check refuses the trade.
#[test, expected_failure(abort_code = sessions::ESessionNotAuthorized)]
fun a_session_the_old_revoke_removed_cannot_trade_on_its_leftover_approval() {
    let mut fixture = setup();
    authorize_session(&mut fixture, SESSION_DURATION_MS);
    let code_a = create_code(&mut fixture, CODE_A_INDEX);
    approve_builder(&mut fixture, code_a, APPROVED_MAX_FEE);
    revoke_session_leaving_approval(&mut fixture);
    assert!(session_builder(&mut fixture).is_some());
    let owner = fixture.owner;
    let mut tx = begin_tx(&mut fixture, SESSION, owner);
    session_enqueue_exact_quantity_with_builder(&mut fixture, &mut tx, code_a, APPROVED_MAX_FEE);
    abort EUnexpectedSuccess
}

/// The owner can clear an approval the pre-upgrade revoke left behind by revoking
/// again: the approval goes, with its `SessionBuilderCleared`, although no session
/// remains to emit `SessionRevoked`.
#[test]
fun revoking_again_clears_an_approval_the_old_revoke_left_behind() {
    let mut fixture = setup();
    authorize_session(&mut fixture, SESSION_DURATION_MS);
    let code_a = create_code(&mut fixture, CODE_A_INDEX);
    approve_builder(&mut fixture, code_a, APPROVED_MAX_FEE);
    revoke_session_leaving_approval(&mut fixture);
    assert!(session_builder(&mut fixture).is_some());

    let account_id = account_id(&mut fixture);
    revoke_session(&mut fixture);
    assert_one_cleared(account_id);
    assert_eq!(event::events_by_type<sessions::SessionRevoked>().length(), NO_EVENTS);
    assert!(session_builder(&mut fixture).is_none());
    finish(fixture);
}

/// Revoking a session that holds no approval emits no `SessionBuilderCleared`,
/// and another session's approval on the same Account stays in place.
#[test]
fun revoking_an_unapproved_session_clears_nothing() {
    let mut fixture = setup();
    authorize_session(&mut fixture, SESSION_DURATION_MS);
    let owner = fixture.owner;
    authorize_session_for(&mut fixture, owner, OTHER_SESSION, SESSION_DURATION_MS);
    let code_a = create_code(&mut fixture, CODE_A_INDEX);
    approve_builder(&mut fixture, code_a, APPROVED_MAX_FEE);

    revoke_session_for(&mut fixture, OTHER_SESSION);
    assert_eq!(event::events_by_type<sessions::SessionRevoked>().length(), ONE_EVENT);
    assert_none_cleared();
    let approval = session_builder(&mut fixture).destroy_some();
    assert_eq!(approval.approved_code_id(), code_a);
    assert_eq!(approval.approved_max_fee_per_contract(), APPROVED_MAX_FEE);
    finish(fixture);
}

// --- Scope ---

/// Approvals are per session: a second session on the same Account has none, so
/// it cannot name the code the first session may.
#[test, expected_failure(abort_code = sessions::EBuilderNotApproved)]
fun another_session_on_the_account_cannot_use_its_approval() {
    let mut fixture = setup();
    authorize_session(&mut fixture, SESSION_DURATION_MS);
    let owner = fixture.owner;
    authorize_session_for(&mut fixture, owner, OTHER_SESSION, SESSION_DURATION_MS);
    let code_a = create_code(&mut fixture, CODE_A_INDEX);
    approve_builder(&mut fixture, code_a, APPROVED_MAX_FEE);
    let mut tx = begin_tx(&mut fixture, OTHER_SESSION, owner);
    session_enqueue_exact_quantity_with_builder(&mut fixture, &mut tx, code_a, APPROVED_MAX_FEE);
    abort EUnexpectedSuccess
}

/// Approvals belong to the Account that made them: Bob grants the same session
/// key on his own Account without one, so it cannot name the code there.
#[test, expected_failure(abort_code = sessions::EBuilderNotApproved)]
fun an_approval_on_one_account_does_not_reach_another() {
    let mut fixture = setup();
    authorize_session(&mut fixture, SESSION_DURATION_MS);
    let code_a = create_code(&mut fixture, CODE_A_INDEX);
    approve_builder(&mut fixture, code_a, APPROVED_MAX_FEE);
    fixture.predict.create_funded_manager_as(BOB, test_constants::mint_deposit());
    authorize_session_for(&mut fixture, BOB, SESSION, SESSION_DURATION_MS);
    let mut tx = begin_tx(&mut fixture, SESSION, BOB);
    session_enqueue_exact_quantity_with_builder(&mut fixture, &mut tx, code_a, APPROVED_MAX_FEE);
    abort EUnexpectedSuccess
}

// === Fixture ===

/// A live market past the Predict cutover with the companion's witness
/// allowlisted, a desk at the launch policy, the market's queue, a funded owner
/// account, Sessions authorized as an Account app, and a fresh `SessionsConfig`
/// at this package's version.
fun setup(): QueueSessionFixture {
    let (mut predict, market_id, trader) = predict_helpers::setup_live_market(
        test_constants::default_expiry_ms(),
        test_constants::default_live_price(),
    );
    predict.cutover();
    predict.authorize_account_app<SessionsApp>();
    let (sessions_config_id, sessions_admin_cap) = session_config::init_for_testing(predict
        .scenario_mut()
        .ctx());
    destroy(sessions_admin_cap);
    predict.scenario_mut().next_tx(test_constants::admin());
    let mut market = predict.take_market_bundle(market_id);
    {
        let (admin_cap, clock, ctx) = predict.admin_parts();
        predict_helpers::config_mut(&mut market).set_order_flow<OrderFlow>(admin_cap, true, clock);
        desk::init_for_testing(ctx);
    };
    predict_helpers::return_market_bundle(market);
    predict.scenario_mut().next_tx(test_constants::admin());
    let desk_id = most_recent_id_shared<OrderDesk>().destroy_some();
    let registry_id = most_recent_id_shared<QueueRegistry>().destroy_some();
    let desk = predict.scenario_mut().take_shared_by_id<OrderDesk>(desk_id);
    let mut registry = predict.scenario_mut().take_shared_by_id<QueueRegistry>(registry_id);
    let market = predict.take_market_bundle(market_id);
    let queue_id = {
        let (_, ctx) = predict.clock_and_ctx();
        queue::create_and_share(&mut registry, &desk, predict_helpers::market(&market), ctx)
    };
    predict_helpers::return_market_bundle(market);
    return_shared(desk);
    return_shared(registry);
    predict.scenario_mut().next_tx(test_constants::admin());
    QueueSessionFixture {
        predict,
        market_id,
        owner: predict_helpers::owner(&trader),
        sessions_config_id,
        desk_id,
        queue_id,
    }
}

/// The owner grants `SESSION` for `duration_ms` from the fixture clock.
fun authorize_session(fixture: &mut QueueSessionFixture, duration_ms: u64) {
    let owner = fixture.owner;
    authorize_session_for(fixture, owner, SESSION, duration_ms);
}

/// `account_owner` grants `session` on their Account for `duration_ms` from the
/// fixture clock.
fun authorize_session_for(
    fixture: &mut QueueSessionFixture,
    account_owner: address,
    session: address,
    duration_ms: u64,
) {
    let mut tx = begin_tx(fixture, account_owner, account_owner);
    // Field borrows go through one reference: borrowing the local `tx` itself
    // while `&mut tx.wrapper` is alive fails the bytecode borrow check.
    let tx_fields = &mut tx;
    let (clock, ctx) = fixture.predict.clock_and_ctx();
    sessions::authorize_session(
        &mut tx_fields.wrapper,
        &tx_fields.sessions_config,
        session,
        duration_ms,
        clock,
        ctx,
    );
    end_tx(tx);
}

/// The owner creates and shares builder code `code_index`. Returns its ID.
fun create_code(fixture: &mut QueueSessionFixture, code_index: u64): ID {
    let owner = fixture.owner;
    let scenario = fixture.predict.scenario_mut();
    scenario.next_tx(owner);
    let mut registry = scenario.take_shared<Registry>();
    let config = scenario.take_shared<ProtocolConfig>();
    let code_id = registry.create_and_share_builder_code(&config, code_index, scenario.ctx());
    return_shared(registry);
    return_shared(config);
    code_id
}

/// The owner approves `code_id` at `max_fee` for `SESSION`.
fun approve_builder(fixture: &mut QueueSessionFixture, code_id: ID, max_fee: u64) {
    let owner = fixture.owner;
    let mut tx = begin_tx(fixture, owner, owner);
    let tx_fields = &mut tx;
    let (_, ctx) = fixture.predict.clock_and_ctx();
    sessions::approve_session_builder(
        &mut tx_fields.wrapper,
        &tx_fields.sessions_config,
        SESSION,
        code_id,
        max_fee,
        ctx,
    );
    end_tx(tx);
}

/// The owner revokes `SESSION`.
fun revoke_session(fixture: &mut QueueSessionFixture) {
    revoke_session_for(fixture, SESSION);
}

/// The owner revokes `session`.
fun revoke_session_for(fixture: &mut QueueSessionFixture, session: address) {
    let owner = fixture.owner;
    let mut tx = begin_tx(fixture, owner, owner);
    let tx_fields = &mut tx;
    let (_, ctx) = fixture.predict.clock_and_ctx();
    sessions::revoke_session(&mut tx_fields.wrapper, session, ctx);
    end_tx(tx);
}

/// The owner revokes `SESSION` through the pre-upgrade `revoke_session`, which
/// leaves its builder approval behind.
fun revoke_session_leaving_approval(fixture: &mut QueueSessionFixture) {
    let owner = fixture.owner;
    let mut tx = begin_tx(fixture, owner, owner);
    let tx_fields = &mut tx;
    let (_, ctx) = fixture.predict.clock_and_ctx();
    sessions::revoke_session_without_builder_for_testing(&mut tx_fields.wrapper, SESSION, ctx);
    end_tx(tx);
}

/// `SESSION`'s approved builder, read in its own transaction.
fun session_builder(fixture: &mut QueueSessionFixture): Option<sessions::SessionBuilder> {
    let owner = fixture.owner;
    let tx = begin_tx(fixture, owner, owner);
    let approval = sessions::session_builder(&tx.wrapper, SESSION);
    end_tx(tx);
    approval
}

/// The owner's canonical Account ID, read in its own transaction.
fun account_id(fixture: &mut QueueSessionFixture): ID {
    let owner = fixture.owner;
    let tx = begin_tx(fixture, owner, owner);
    let account_id = tx.wrapper.load_account().account_id();
    end_tx(tx);
    account_id
}

/// The last transaction emitted exactly one `SessionBuilderCleared`, for
/// `SESSION` on `account_id`.
fun assert_one_cleared(account_id: ID) {
    let events = event::events_by_type<sessions::SessionBuilderCleared>();
    assert_eq!(events.length(), ONE_EVENT);
    let expected = ExpectedSessionBuilderCleared { account_id, session: SESSION };
    assert_eq!(bcs::to_bytes(&events[0]), bcs::to_bytes(&expected));
}

/// The last transaction emitted no `SessionBuilderCleared`.
fun assert_none_cleared() {
    assert_eq!(event::events_by_type<sessions::SessionBuilderCleared>().length(), NO_EVENTS);
}

/// A keeper commits τ's update and resolves the one waiting order.
fun fill_one(fixture: &mut QueueSessionFixture, tau_ms: u64) {
    fixture.predict.set_clock_for_testing(tau_ms + PRICE_LANDING_MS);
    let owner = fixture.owner;
    let mut tx = begin_tx(fixture, KEEPER, owner);
    let tx_fields = &mut tx;
    let (market, config, _, _, _) = tx_fields.market.market_parts_mut();
    let (clock, ctx) = fixture.predict.clock_and_ctx();
    tx_fields
        .queue
        .commit_for_testing(
            market,
            &tx_fields.desk,
            config,
            vector[queue_fixture::price_update(tau_ms, test_constants::default_live_price())],
            clock,
            ctx,
        );
    let deny_list = deny_list::new_for_testing(ctx);
    let finished = tx_fields
        .queue
        .resolve(market, &tx_fields.desk, config, RESOLVE_BATCH, &deny_list, clock, ctx);
    destroy(deny_list);
    assert_eq!(finished, ONE_ORDER);
    end_tx(tx);
}

/// Start a transaction from `sender` against `account_owner`'s Account.
fun begin_tx(
    fixture: &mut QueueSessionFixture,
    sender: address,
    account_owner: address,
): SessionTx {
    let market_id = fixture.market_id;
    let sessions_config_id = fixture.sessions_config_id;
    let desk_id = fixture.desk_id;
    let queue_id = fixture.queue_id;
    fixture.predict.scenario_mut().next_tx(sender);
    let market = fixture.predict.take_market_bundle(market_id);
    let scenario = fixture.predict.scenario_mut();
    let account_registry = scenario.take_shared<AccountRegistry>();
    let wrapper_id = account_registry.derived_wrapper_address(account_owner).to_id();
    let wrapper = scenario.take_shared_by_id<AccountWrapper>(wrapper_id);
    let sessions_config = scenario.take_shared_by_id<SessionsConfig>(sessions_config_id);
    let root = scenario.take_shared<AccumulatorRoot>();
    let desk = scenario.take_shared_by_id<OrderDesk>(desk_id);
    let queue = scenario.take_shared_by_id<MarketQueue>(queue_id);
    SessionTx { market, account_registry, wrapper, sessions_config, root, desk, queue }
}

fun end_tx(tx: SessionTx) {
    let SessionTx { market, account_registry, wrapper, sessions_config, root, desk, queue } = tx;
    predict_helpers::return_market_bundle(market);
    return_shared(account_registry);
    return_shared(wrapper);
    return_shared(sessions_config);
    return_shared(root);
    return_shared(desk);
    return_shared(queue);
}

fun finish(fixture: QueueSessionFixture) {
    let QueueSessionFixture { predict, .. } = fixture;
    predict.finish();
}

// === Session calls ===

fun session_enqueue_exact_quantity(
    fixture: &mut QueueSessionFixture,
    tx: &mut SessionTx,
    quantity: u64,
    max_cost: u64,
    max_probability: u64,
): u64 {
    let (market, config, oracle_registry, pyth, bs) = tx.market.market_parts_mut();
    let (clock, ctx) = fixture.predict.clock_and_ctx();
    sessions::enqueue_exact_quantity(
        &mut tx.queue,
        market,
        &tx.account_registry,
        &mut tx.wrapper,
        &tx.sessions_config,
        &tx.desk,
        config,
        oracle_registry,
        pyth,
        bs.values(),
        bs.svi(),
        predict_helpers::strike_tick(),
        predict_helpers::pos_inf_tick(),
        quantity,
        max_cost,
        max_probability,
        &tx.root,
        clock,
        ctx,
    )
}

fun session_enqueue_exact_amount(
    fixture: &mut QueueSessionFixture,
    tx: &mut SessionTx,
    max_premium: u64,
    min_quantity: u64,
    max_cost: u64,
): u64 {
    let (market, config, oracle_registry, pyth, bs) = tx.market.market_parts_mut();
    let (clock, ctx) = fixture.predict.clock_and_ctx();
    sessions::enqueue_exact_amount(
        &mut tx.queue,
        market,
        &tx.account_registry,
        &mut tx.wrapper,
        &tx.sessions_config,
        &tx.desk,
        config,
        oracle_registry,
        pyth,
        bs.values(),
        bs.svi(),
        predict_helpers::strike_tick(),
        predict_helpers::pos_inf_tick(),
        max_premium,
        min_quantity,
        max_cost,
        &tx.root,
        clock,
        ctx,
    )
}

fun session_enqueue_exact_cost(
    fixture: &mut QueueSessionFixture,
    tx: &mut SessionTx,
    max_cost: u64,
    min_quantity: u64,
): u64 {
    let (market, config, oracle_registry, pyth, bs) = tx.market.market_parts_mut();
    let (clock, ctx) = fixture.predict.clock_and_ctx();
    sessions::enqueue_exact_cost(
        &mut tx.queue,
        market,
        &tx.account_registry,
        &mut tx.wrapper,
        &tx.sessions_config,
        &tx.desk,
        config,
        oracle_registry,
        pyth,
        bs.values(),
        bs.svi(),
        predict_helpers::strike_tick(),
        predict_helpers::pos_inf_tick(),
        max_cost,
        min_quantity,
        &tx.root,
        clock,
        ctx,
    )
}

fun session_enqueue_exact_quantity_with_builder(
    fixture: &mut QueueSessionFixture,
    tx: &mut SessionTx,
    code_id: ID,
    fee_per_contract: u64,
): u64 {
    let code = fixture.predict.scenario_mut().take_shared_by_id<BuilderCode>(code_id);
    let (market, config, oracle_registry, pyth, bs) = tx.market.market_parts_mut();
    let (clock, ctx) = fixture.predict.clock_and_ctx();
    let record_id = sessions::enqueue_exact_quantity_with_builder(
        &mut tx.queue,
        market,
        &tx.account_registry,
        &mut tx.wrapper,
        &tx.sessions_config,
        &tx.desk,
        config,
        oracle_registry,
        pyth,
        bs.values(),
        bs.svi(),
        &code,
        fee_per_contract,
        predict_helpers::strike_tick(),
        predict_helpers::pos_inf_tick(),
        MINT_QUANTITY,
        QUANTITY_MAX_COST,
        QUANTITY_MAX_PROBABILITY,
        &tx.root,
        clock,
        ctx,
    );
    return_shared(code);
    record_id
}

fun session_enqueue_exact_amount_with_builder(
    fixture: &mut QueueSessionFixture,
    tx: &mut SessionTx,
    code_id: ID,
    fee_per_contract: u64,
): u64 {
    let code = fixture.predict.scenario_mut().take_shared_by_id<BuilderCode>(code_id);
    let (market, config, oracle_registry, pyth, bs) = tx.market.market_parts_mut();
    let (clock, ctx) = fixture.predict.clock_and_ctx();
    let record_id = sessions::enqueue_exact_amount_with_builder(
        &mut tx.queue,
        market,
        &tx.account_registry,
        &mut tx.wrapper,
        &tx.sessions_config,
        &tx.desk,
        config,
        oracle_registry,
        pyth,
        bs.values(),
        bs.svi(),
        &code,
        fee_per_contract,
        predict_helpers::strike_tick(),
        predict_helpers::pos_inf_tick(),
        AMOUNT_MAX_PREMIUM,
        AMOUNT_MIN_QUANTITY,
        AMOUNT_MAX_COST,
        &tx.root,
        clock,
        ctx,
    );
    return_shared(code);
    record_id
}

fun session_enqueue_exact_cost_with_builder(
    fixture: &mut QueueSessionFixture,
    tx: &mut SessionTx,
    code_id: ID,
    fee_per_contract: u64,
): u64 {
    let code = fixture.predict.scenario_mut().take_shared_by_id<BuilderCode>(code_id);
    let (market, config, oracle_registry, pyth, bs) = tx.market.market_parts_mut();
    let (clock, ctx) = fixture.predict.clock_and_ctx();
    let record_id = sessions::enqueue_exact_cost_with_builder(
        &mut tx.queue,
        market,
        &tx.account_registry,
        &mut tx.wrapper,
        &tx.sessions_config,
        &tx.desk,
        config,
        oracle_registry,
        pyth,
        bs.values(),
        bs.svi(),
        &code,
        fee_per_contract,
        predict_helpers::strike_tick(),
        predict_helpers::pos_inf_tick(),
        COST_MAX_COST,
        COST_MIN_QUANTITY,
        &tx.root,
        clock,
        ctx,
    );
    return_shared(code);
    record_id
}

fun session_enqueue_redeem_open_with_builder(
    fixture: &mut QueueSessionFixture,
    tx: &mut SessionTx,
    code_id: ID,
    fee_per_contract: u64,
    record_id: u64,
    close_quantity: u64,
    min_probability: u64,
    min_proceeds: u64,
): u64 {
    let code = fixture.predict.scenario_mut().take_shared_by_id<BuilderCode>(code_id);
    let (market, config, oracle_registry, pyth, bs) = tx.market.market_parts_mut();
    let (clock, ctx) = fixture.predict.clock_and_ctx();
    let sell_id = sessions::enqueue_redeem_open_with_builder(
        &mut tx.queue,
        market,
        &tx.account_registry,
        &mut tx.wrapper,
        &tx.sessions_config,
        &tx.desk,
        config,
        oracle_registry,
        pyth,
        bs.values(),
        bs.svi(),
        &code,
        fee_per_contract,
        record_id,
        close_quantity,
        min_probability,
        min_proceeds,
        &tx.root,
        clock,
        ctx,
    );
    return_shared(code);
    sell_id
}

fun session_enqueue_redeem_open(
    fixture: &mut QueueSessionFixture,
    tx: &mut SessionTx,
    record_id: u64,
    close_quantity: u64,
    min_probability: u64,
    min_proceeds: u64,
): u64 {
    let (market, config, oracle_registry, pyth, bs) = tx.market.market_parts_mut();
    let (clock, ctx) = fixture.predict.clock_and_ctx();
    sessions::enqueue_redeem_open(
        &mut tx.queue,
        market,
        &tx.account_registry,
        &mut tx.wrapper,
        &tx.sessions_config,
        &tx.desk,
        config,
        oracle_registry,
        pyth,
        bs.values(),
        bs.svi(),
        record_id,
        close_quantity,
        min_probability,
        min_proceeds,
        &tx.root,
        clock,
        ctx,
    )
}

// The retired immediate wrappers, called with the queued mints' terms.

fun session_mint_exact_quantity(fixture: &mut QueueSessionFixture, tx: &mut SessionTx): u256 {
    let pricer = fixture.predict.load_pricer_bundle(&tx.market);
    let (market, config, _, _, _) = tx.market.market_parts_mut();
    let (clock, ctx) = fixture.predict.clock_and_ctx();
    sessions::mint_exact_quantity(
        market,
        &tx.account_registry,
        &mut tx.wrapper,
        &tx.sessions_config,
        config,
        &pricer,
        predict_helpers::strike_tick(),
        predict_helpers::pos_inf_tick(),
        MINT_QUANTITY,
        QUANTITY_MAX_COST,
        QUANTITY_MAX_PROBABILITY,
        &tx.root,
        clock,
        ctx,
    )
}

fun session_mint_exact_amount(fixture: &mut QueueSessionFixture, tx: &mut SessionTx): u256 {
    let pricer = fixture.predict.load_pricer_bundle(&tx.market);
    let (market, config, _, _, _) = tx.market.market_parts_mut();
    let (clock, ctx) = fixture.predict.clock_and_ctx();
    sessions::mint_exact_amount(
        market,
        &tx.account_registry,
        &mut tx.wrapper,
        &tx.sessions_config,
        config,
        &pricer,
        predict_helpers::strike_tick(),
        predict_helpers::pos_inf_tick(),
        AMOUNT_MAX_PREMIUM,
        AMOUNT_MIN_QUANTITY,
        AMOUNT_MAX_COST,
        &tx.root,
        clock,
        ctx,
    )
}

fun session_mint_exact_cost(fixture: &mut QueueSessionFixture, tx: &mut SessionTx): u256 {
    let pricer = fixture.predict.load_pricer_bundle(&tx.market);
    let (market, config, _, _, _) = tx.market.market_parts_mut();
    let (clock, ctx) = fixture.predict.clock_and_ctx();
    sessions::mint_exact_cost(
        market,
        &tx.account_registry,
        &mut tx.wrapper,
        &tx.sessions_config,
        config,
        &pricer,
        predict_helpers::strike_tick(),
        predict_helpers::pos_inf_tick(),
        COST_MAX_COST,
        COST_MIN_QUANTITY,
        &tx.root,
        clock,
        ctx,
    )
}

fun session_redeem_live(
    fixture: &mut QueueSessionFixture,
    tx: &mut SessionTx,
    order_id: u256,
): Option<u256> {
    let pricer = fixture.predict.load_pricer_bundle(&tx.market);
    let (market, config, _, _, _) = tx.market.market_parts_mut();
    let (clock, ctx) = fixture.predict.clock_and_ctx();
    sessions::redeem_live(
        market,
        &tx.account_registry,
        &mut tx.wrapper,
        &tx.sessions_config,
        config,
        &pricer,
        order_id,
        MINT_QUANTITY,
        ZERO_FLOOR,
        ZERO_FLOOR,
        &tx.root,
        clock,
        ctx,
    )
}

// === Reads and assertions ===

fun record(tx: &SessionTx, record_id: u64): OrderView {
    let order = tx.queue.order(record_id);
    assert!(order.is_some());
    order.destroy_some()
}

fun account_balance(fixture: &QueueSessionFixture, tx: &SessionTx): u64 {
    tx.wrapper.load_account().balance<USDC>(&tx.root, fixture.predict.clock())
}

/// The builder fee and code of the one `OrderMinted` the last transaction
/// emitted, read from its BCS in `order_events::OrderMinted` field order: the
/// fee follows two IDs, two order IDs, the owner, and seven amounts, and the
/// code follows three more amounts.
fun minted_builder(): (u64, Option<ID>) {
    let events = event::events_by_type<order_events::OrderMinted>();
    assert_eq!(events.length(), ONE_EVENT);
    let mut bytes = sui_bcs::new(bcs::to_bytes(&events[0]));
    let _ = bytes.peel_address();
    let _ = bytes.peel_address();
    let _ = bytes.peel_u256();
    let _ = bytes.peel_u256();
    let _ = bytes.peel_address();
    7u64.do!(|_| { let _ = bytes.peel_u64(); });
    let builder_fee = bytes.peel_u64();
    3u64.do!(|_| { let _ = bytes.peel_u64(); });
    let code = bytes.peel_option_address().map!(|code| code.to_id());
    (builder_fee, code)
}

/// Predict's waiting cash need is exactly the queue's unfinished records' cash
/// need.
fun assert_cash_need_matches(tx: &SessionTx) {
    let (_, next_id, _, _) = tx.queue.queue_heads();
    let mut sum = 0;
    next_id.do!(|record_id| {
        tx.queue.order(record_id).do!(|order| {
            let status = order.status();
            if (
                status == order_queue::status_pending()
                    || status == order_queue::status_committed()
                    || status == order_queue::status_refund_due()
            ) sum = sum + order.escrow().cash_need();
        });
    });
    let (waiting_cash_need, _, _) = predict_helpers::market(&tx.market).order_flow_state();
    assert_eq!(waiting_cash_need, sum);
}

fun assert_quantity_mint_record(tx: &SessionTx, record_id: u64, owner: address) {
    let order = record(tx, record_id);
    assert_eq!(order.kind(), order_queue::kind_exact_quantity());
    assert_eq!(order.status(), order_queue::status_pending());
    let request = order.request();
    assert_eq!(request.lower_tick(), predict_helpers::strike_tick());
    assert_eq!(request.higher_tick(), predict_helpers::pos_inf_tick());
    assert_eq!(request.quantity(), MINT_QUANTITY);
    assert_eq!(request.max_cost(), QUANTITY_MAX_COST);
    assert_eq!(request.max_probability(), QUANTITY_MAX_PROBABILITY);
    assert_eq!(order.escrow().budget(), QUANTITY_BUDGET);
    assert_eq!(order.escrow().order_fee(), ORDER_FEE);
    assert_eq!(order.funds(), QUANTITY_BUDGET + ORDER_FEE);
    assert_account_parties(tx, &order, owner);
}

fun assert_amount_mint_record(tx: &SessionTx, record_id: u64, owner: address) {
    let order = record(tx, record_id);
    assert_eq!(order.kind(), order_queue::kind_exact_amount());
    assert_eq!(order.status(), order_queue::status_pending());
    let request = order.request();
    assert_eq!(request.lower_tick(), predict_helpers::strike_tick());
    assert_eq!(request.higher_tick(), predict_helpers::pos_inf_tick());
    assert_eq!(request.max_premium(), AMOUNT_MAX_PREMIUM);
    assert_eq!(request.min_quantity(), AMOUNT_MIN_QUANTITY);
    assert_eq!(request.max_cost(), AMOUNT_MAX_COST);
    assert_eq!(order.escrow().budget(), AMOUNT_BUDGET);
    assert_eq!(order.escrow().order_fee(), ORDER_FEE);
    assert_account_parties(tx, &order, owner);
}

fun assert_cost_mint_record(tx: &SessionTx, record_id: u64, owner: address) {
    let order = record(tx, record_id);
    assert_eq!(order.kind(), order_queue::kind_exact_cost());
    assert_eq!(order.status(), order_queue::status_pending());
    let request = order.request();
    assert_eq!(request.lower_tick(), predict_helpers::strike_tick());
    assert_eq!(request.higher_tick(), predict_helpers::pos_inf_tick());
    assert_eq!(request.max_cost(), COST_MAX_COST);
    assert_eq!(request.min_quantity(), COST_MIN_QUANTITY);
    assert_eq!(order.escrow().budget(), COST_BUDGET);
    assert_eq!(order.escrow().order_fee(), ORDER_FEE);
    assert_account_parties(tx, &order, owner);
}

/// A queued sell holds the sold position, escrows only the order fee, and
/// stores the forwarded close quantity and floors.
fun assert_sell_record(
    tx: &SessionTx,
    record_id: u64,
    close_quantity: u64,
    min_probability: u64,
    min_proceeds: u64,
    position_order_id: u256,
    owner: address,
) {
    let order = record(tx, record_id);
    assert_eq!(order.kind(), order_queue::kind_redeem_open());
    assert_eq!(order.status(), order_queue::status_pending());
    let request = order.request();
    assert_eq!(request.quantity(), close_quantity);
    assert_eq!(request.min_probability(), min_probability);
    assert_eq!(request.min_proceeds(), min_proceeds);
    assert_eq!(order.position().order_id(), position_order_id);
    assert_eq!(order.escrow().budget(), SELL_BUDGET);
    assert_eq!(order.escrow().order_fee(), ORDER_FEE);
    assert_eq!(order.funds(), ORDER_FEE);
    assert_account_parties(tx, &order, owner);
}

/// A session-placed record belongs to the owner's Account, and refunds and
/// proceeds go to the Account wrapper, never to the session key.
fun assert_account_parties(tx: &SessionTx, order: &OrderView, owner: address) {
    assert_eq!(order.account_id(), tx.wrapper.load_account().account_id());
    assert_eq!(order.receive_address(), tx.account_registry.derived_wrapper_address(owner));
}
