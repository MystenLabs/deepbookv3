// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Pure-unit fixtures for `order_queue`: policies with chosen timing, and mint
/// and sell records placed the way enqueue places them (`plan_timing`, then the
/// escrow deposit, then `append`). No market, oracle, or account objects.
#[test_only]
module deepbook_predict::order_queue_test_helpers;

use deepbook_predict::{
    delayed_execution_config::{Self, DelayedExecutionPolicy},
    order_queue::{Self, OrderBook, QueuedOrder},
    pricing::{Self, VolSnapshot},
    strike_exposure::{Self, StrikeExposure},
    strike_exposure_config,
    test_constants
};
use fixed_math::i64;
use sui::balance;

/// Base Sui clock for the unit tests; a multiple of both channel ticks.
const BASE_MS: u64 = 1_000_000_000;
/// Market expiry, far enough out that no deadline is capped by it.
const EXPIRY_MS: u64 = 1_100_000_000;
const NO_TRADE_WINDOW_MS: u64 = 0;
/// Channel ids, spelled out so the tests read the spec values.
const CHANNEL_50MS: u8 = 2;
const CHANNEL_200MS: u8 = 3;
/// Policy defaults the timing setter does not vary here.
const STUCK_THRESHOLD_MS: u64 = 1_500;
const GAP_WAIT_MS: u64 = 2_000;
const PYTH_PRICE_BUFFER_MS: u64 = 0;
const SVI_MAX_AGE_MS: u64 = 60_000;
/// Mint range used by most tests.
const LOWER_TICK: u64 = 100;
const HIGHER_TICK: u64 = 200;

public fun base_ms(): u64 { BASE_MS }

public fun expiry_ms(): u64 { EXPIRY_MS }

public fun channel_50ms(): u8 { CHANNEL_50MS }

public fun channel_200ms(): u8 { CHANNEL_200MS }

public fun lower_tick(): u64 { LOWER_TICK }

public fun higher_tick(): u64 { HIGHER_TICK }

public fun account(index: u64): ID {
    object::id_from_address(sui::address::from_u256((0xA0 + index) as u256))
}

public fun receive_address(): address { @0xBEEF }

/// The compiled defaults: delay 1_000, stall 5_000, channel 3 (200 ms).
public fun default_policy(): DelayedExecutionPolicy {
    delayed_execution_config::new()
}

/// Defaults with the delay, stall timeout, and channel replaced.
public fun policy(delay_ms: u64, stall_timeout_ms: u64, channel: u8): DelayedExecutionPolicy {
    let mut policy = delayed_execution_config::new();
    policy.set_timing(
        delay_ms,
        stall_timeout_ms,
        STUCK_THRESHOLD_MS,
        GAP_WAIT_MS,
        PYTH_PRICE_BUFFER_MS,
        channel,
        SVI_MAX_AGE_MS,
    );
    policy
}

/// An all-zero snapshot; nothing in `order_queue` reads it.
public fun zero_vol(): VolSnapshot {
    pricing::new_vol_snapshot_for_testing(
        0,
        0,
        0,
        i64::zero(),
        0,
        i64::zero(),
        i64::zero(),
        0,
        0,
        0,
        0,
    )
}

/// A strike exposure with no nodes, for the refund routine's `exposure` part.
public fun new_exposure(ctx: &mut TxContext): StrikeExposure {
    strike_exposure::new(
        object::id_from_address(@0xE),
        strike_exposure_config::new(),
        test_constants::default_tick_size(),
        test_constants::default_tick_size(),
        0,
        1_000_000_000,
        ctx,
    )
}

/// Place an exact-quantity mint over `(lower_tick, higher_tick]` at `now_ms`:
/// plan its timing against `EXPIRY_MS`, deposit `budget + order_fee` into
/// escrow, and append it. Returns the record ID.
public fun place_mint(
    book: &mut OrderBook,
    policy: &DelayedExecutionPolicy,
    now_ms: u64,
    account_id: ID,
    lower_tick: u64,
    higher_tick: u64,
    budget: u64,
    order_fee: u64,
    cash_need: u64,
): u64 {
    let order = mint_order(
        book,
        policy,
        now_ms,
        account_id,
        lower_tick,
        higher_tick,
        budget,
        order_fee,
        cash_need,
    );
    book.deposit_escrow(balance::create_for_testing(budget + order_fee));
    book.append(order)
}

/// Place an early sell of `close_quantity` of position `order_id` at `now_ms`,
/// depositing its order fee. Returns the record ID.
public fun place_sell(
    book: &mut OrderBook,
    policy: &DelayedExecutionPolicy,
    now_ms: u64,
    account_id: ID,
    close_quantity: u64,
    order_fee: u64,
    cash_need: u64,
    order_id: u256,
    root_id: u256,
    opened_at_ms: u64,
): u64 {
    let timing = book.plan_timing(policy, EXPIRY_MS, NO_TRADE_WINDOW_MS, now_ms);
    let order = order_queue::new_order(
        order_queue::kind_redeem_open(),
        order_queue::new_request(0, 0, close_quantity, 0, 0, 0, 0, 0, 0),
        parties(account_id),
        timing,
        zero_vol(),
        order_queue::new_escrow(0, order_fee, 0, cash_need),
        order_queue::new_held_position(order_id, root_id, opened_at_ms),
    );
    book.deposit_escrow(balance::create_for_testing(order_fee));
    book.append(order)
}

/// Build (without appending) the exact-quantity mint `place_mint` appends.
public fun mint_order(
    book: &OrderBook,
    policy: &DelayedExecutionPolicy,
    now_ms: u64,
    account_id: ID,
    lower_tick: u64,
    higher_tick: u64,
    budget: u64,
    order_fee: u64,
    cash_need: u64,
): QueuedOrder {
    let timing = book.plan_timing(policy, EXPIRY_MS, NO_TRADE_WINDOW_MS, now_ms);
    order_queue::new_order(
        order_queue::kind_exact_quantity(),
        order_queue::new_request(lower_tick, higher_tick, budget, 0, 0, budget, 0, 0, 0),
        parties(account_id),
        timing,
        zero_vol(),
        order_queue::new_escrow(budget, order_fee, 0, cash_need),
        order_queue::empty_position(),
    )
}

fun parties(account_id: ID): order_queue::OrderParties {
    order_queue::new_parties(
        account_id,
        @0xA11CE,
        receive_address(),
        option::none(),
        option::none(),
        option::none(),
    )
}
