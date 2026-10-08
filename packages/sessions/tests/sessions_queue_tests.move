// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Session wrappers over Predict's delayed-execution queue: the four enqueue
/// wrappers, the session auth and version gates in front of them, and the
/// retired immediate wrappers after the cutover.
///
/// Every market here runs past the Predict cutover; only the retired live
/// redeem test mints before crossing it. The auth and version tests abort in
/// Sessions before Predict runs. The flow tests drive the real queue
/// (enqueue, commit, resolve, sell) and pin what Sessions owns: each wrapper
/// forwards its arguments into the named request fields, and the record belongs
/// to the Account, never to the session key.
#[test_only]
module deepbook_sessions::sessions_queue_tests;

use account::{account::AccountWrapper, account_registry::AccountRegistry};
use deepbook_predict::{
    expiry_market::{Self as expiry_market, ExpiryMarket},
    flow_test_helpers::{Self as predict_helpers, Fixture, MarketBundle},
    order_queue::{Self, QueuedOrder},
    queue_test_helpers,
    test_constants
};
use deepbook_sessions::{
    session_config::{Self as session_config, SessionsConfig},
    sessions::{Self as sessions, SessionsApp}
};
use std::unit_test::{assert_eq, destroy};
use sui::{accumulator::AccumulatorRoot, test_scenario::return_shared};
use usdc::usdc::USDC;

const SESSION: address = @0x5E5510;
const BOB: address = @0xB0B;
const KEEPER: address = @0x4EE9;

const SESSION_DURATION_MS: u64 = 60_000;
// The fixture clock starts at 120_000, so the grant expires at 120_000 + 60_000.
const SESSION_EXPIRES_AT_MS: u64 = 180_000;
// Mainnet Sessions runs version 2, so its live watermark is 2 until this
// upgrade's bump.
const MAINNET_WATERMARK: u64 = 2;
// One past this package's version 3: a watermark that retires it.
const RETIRING_WATERMARK: u64 = 4;

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

// Pyth Lazer `fixed_rate@200ms`, the policy's default channel.
const PYTH_CHANNEL_200MS: u8 = 3;
// 100.00000000 at exponent -8 normalizes to the fixture's 100 * 1e9 live spot.
const LAZER_SPOT_MAGNITUDE: u64 = 10_000_000_000;
const LAZER_SPOT_NEG_EXPONENT: u16 = 8;
const US_PER_MS: u64 = 1_000;
// The keeper lands τ's update 100 ms after τ, well inside the 5_000 ms stall
// timeout.
const PRICE_LANDING_MS: u64 = 100;
const RESOLVE_BATCH: u64 = 10;
const THREE_ORDERS: u64 = 3;

// One millisecond after the fixture's 120_000 mint time.
const LIVE_REDEEM_MS: u64 = 120_001;
const MISSING_RECORD_ID: u64 = 0;
const ZERO_FLOOR: u64 = 0;
const EUnexpectedSuccess: u64 = 999;

public struct QueueSessionFixture {
    predict: Fixture,
    market_id: ID,
    owner: address,
    sessions_config_id: ID,
}

/// Every shared object one session transaction needs, taken together.
public struct SessionTx {
    market: MarketBundle,
    account_registry: AccountRegistry,
    wrapper: AccountWrapper,
    sessions_config: SessionsConfig,
    root: AccumulatorRoot,
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

#[test]
fun session_enqueues_while_the_mainnet_watermark_still_names_version_two() {
    // Between this upgrade and its bump the shared config still holds Mainnet's
    // watermark 2, and the version 3 wrappers must already serve.
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
fun session_mint_exact_quantity_aborts_after_cutover() {
    let mut fixture = setup();
    authorize_session(&mut fixture, SESSION_DURATION_MS);
    let owner = fixture.owner;
    let mut tx = begin_tx(&mut fixture, SESSION, owner);
    destroy(session_mint_exact_quantity(&mut fixture, &mut tx));
    abort EUnexpectedSuccess
}

#[test, expected_failure(abort_code = expiry_market::EDelayedExecutionRequired)]
fun session_mint_exact_amount_aborts_after_cutover() {
    let mut fixture = setup();
    authorize_session(&mut fixture, SESSION_DURATION_MS);
    let owner = fixture.owner;
    let mut tx = begin_tx(&mut fixture, SESSION, owner);
    destroy(session_mint_exact_amount(&mut fixture, &mut tx));
    abort EUnexpectedSuccess
}

#[test, expected_failure(abort_code = expiry_market::EDelayedExecutionRequired)]
fun session_mint_exact_cost_aborts_after_cutover() {
    let mut fixture = setup();
    authorize_session(&mut fixture, SESSION_DURATION_MS);
    let owner = fixture.owner;
    let mut tx = begin_tx(&mut fixture, SESSION, owner);
    destroy(session_mint_exact_cost(&mut fixture, &mut tx));
    abort EUnexpectedSuccess
}

#[test, expected_failure(abort_code = expiry_market::EDelayedExecutionRequired)]
fun session_redeem_live_aborts_after_cutover() {
    // A position the session minted through the immediate path before the
    // cutover can no longer be sold through it afterwards. A real position keeps
    // every other redeem check passing, so only the cutover gate can abort.
    let mut fixture = setup_before_cutover();
    authorize_session(&mut fixture, SESSION_DURATION_MS);
    let owner = fixture.owner;
    let mut tx = begin_tx(&mut fixture, SESSION, owner);
    let order_id = session_mint_exact_quantity(&mut fixture, &mut tx);
    end_tx(tx);
    fixture.predict.cutover();
    // A later timestamp keeps the same-timestamp mint and redeem guard out of
    // the way.
    fixture.predict.set_clock_for_testing(LIVE_REDEEM_MS);
    let mut tx = begin_tx(&mut fixture, SESSION, owner);
    destroy(session_redeem_live(&mut fixture, &mut tx, order_id));
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
    // The Account paid every budget and order fee into escrow.
    assert_eq!(account_balance(fixture, &tx), BALANCE_AFTER_MINTS);
    queue_test_helpers::assert_queue_invariants(predict_helpers::market(&tx.market));
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
    queue_test_helpers::commit_decoded(
        &mut fixture.predict,
        &mut tx.market,
        vector[
            queue_test_helpers::lazer_tick(
                tau_ms,
                PYTH_CHANNEL_200MS,
                test_constants::pyth_feed_id(),
                LAZER_SPOT_MAGNITUDE,
                LAZER_SPOT_NEG_EXPONENT,
                tau_ms * US_PER_MS,
            ),
        ],
    );
    let finished = queue_test_helpers::resolve(&mut fixture.predict, &mut tx.market, RESOLVE_BATCH);
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
    queue_test_helpers::assert_queue_invariants(predict_helpers::market(&tx.market));
    end_tx(tx);
}

// === Fixture ===

/// A live market past the Predict cutover with the default delayed-execution
/// policy, a funded owner account, Sessions authorized as an Account app, and
/// a fresh `SessionsConfig` at this package's version.
fun setup(): QueueSessionFixture {
    let mut fixture = setup_before_cutover();
    fixture.predict.cutover();
    fixture
}

/// `setup` stopped before the Predict cutover, where the immediate mint and
/// redeem paths still run. `queue_test_helpers::setup_queue_market` is this
/// plus the cutover.
fun setup_before_cutover(): QueueSessionFixture {
    let (mut predict, market_id, trader) = predict_helpers::setup_live_market(
        test_constants::default_expiry_ms(),
        test_constants::default_live_price(),
    );
    predict.init_delayed_execution();
    predict.authorize_account_app<SessionsApp>();
    let (sessions_config_id, sessions_admin_cap) = session_config::init_for_testing(predict
        .scenario_mut()
        .ctx());
    destroy(sessions_admin_cap);
    predict.scenario_mut().next_tx(test_constants::admin());
    QueueSessionFixture {
        predict,
        market_id,
        owner: predict_helpers::owner(&trader),
        sessions_config_id,
    }
}

/// The owner grants `SESSION` for `duration_ms` from the fixture clock.
fun authorize_session(fixture: &mut QueueSessionFixture, duration_ms: u64) {
    let owner = fixture.owner;
    let mut tx = begin_tx(fixture, owner, owner);
    // Field borrows go through one reference: borrowing the local `tx` itself
    // while `&mut tx.wrapper` is alive fails the bytecode borrow check.
    let tx_fields = &mut tx;
    let (clock, ctx) = fixture.predict.clock_and_ctx();
    sessions::authorize_session(
        &mut tx_fields.wrapper,
        &tx_fields.sessions_config,
        SESSION,
        duration_ms,
        clock,
        ctx,
    );
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
    fixture.predict.scenario_mut().next_tx(sender);
    let market = fixture.predict.take_market_bundle(market_id);
    let scenario = fixture.predict.scenario_mut();
    let account_registry = scenario.take_shared<AccountRegistry>();
    let wrapper_id = account_registry.derived_wrapper_address(account_owner).to_id();
    let wrapper = scenario.take_shared_by_id<AccountWrapper>(wrapper_id);
    let sessions_config = scenario.take_shared_by_id<SessionsConfig>(sessions_config_id);
    let root = scenario.take_shared<AccumulatorRoot>();
    SessionTx { market, account_registry, wrapper, sessions_config, root }
}

fun end_tx(tx: SessionTx) {
    let SessionTx { market, account_registry, wrapper, sessions_config, root } = tx;
    predict_helpers::return_market_bundle(market);
    return_shared(account_registry);
    return_shared(wrapper);
    return_shared(sessions_config);
    return_shared(root);
}

fun finish(fixture: QueueSessionFixture) {
    let QueueSessionFixture { predict, market_id: _, owner: _, sessions_config_id: _ } = fixture;
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
        market,
        &tx.account_registry,
        &mut tx.wrapper,
        &tx.sessions_config,
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
        market,
        &tx.account_registry,
        &mut tx.wrapper,
        &tx.sessions_config,
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
        market,
        &tx.account_registry,
        &mut tx.wrapper,
        &tx.sessions_config,
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
        market,
        &tx.account_registry,
        &mut tx.wrapper,
        &tx.sessions_config,
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

fun record(tx: &SessionTx, record_id: u64): QueuedOrder {
    let market: &ExpiryMarket = predict_helpers::market(&tx.market);
    let order = market.queued_order(record_id);
    assert!(order.is_some());
    order.destroy_some()
}

fun account_balance(fixture: &QueueSessionFixture, tx: &SessionTx): u64 {
    tx.wrapper.load_account().balance<USDC>(&tx.root, fixture.predict.clock())
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
    assert_account_parties(tx, &order, owner);
}

/// A session-placed record belongs to the Account and its owner, and refunds
/// and proceeds go to the Account wrapper, never to the session key.
fun assert_account_parties(tx: &SessionTx, order: &QueuedOrder, owner: address) {
    let parties = order.parties();
    assert_eq!(parties.account_id(), tx.wrapper.load_account().account_id());
    assert_eq!(parties.owner(), owner);
    assert_eq!(parties.receive_address(), tx.account_registry.derived_wrapper_address(owner));
}
