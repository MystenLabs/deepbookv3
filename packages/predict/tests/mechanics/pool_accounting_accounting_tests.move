// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Exact idle, funding, terminal-loss, and protocol-profit ledger accounting.
#[test_only]
module deepbook_predict::scope_mechanics__intent_accounting__pool_accounting_tests;

use deepbook_predict::pool_accounting;
use dusdc::dusdc::DUSDC;
use std::unit_test::{assert_eq, destroy};
use sui::balance;

const EXPIRY_A: address = @0xA;
const EXPIRY_B: address = @0xB;
const EXPIRY_A_MS: u64 = 1_000;
const EXPIRY_B_MS: u64 = 2_000;
const MAX_EXPIRY_ALLOCATION: u64 = 1_000;
const INITIAL_EXPIRY_CASH: u64 = 100;
const INITIAL_IDLE: u64 = 1_000;
const SENT_TO_EXPIRY: u64 = 700;
const FIRST_RETURN: u64 = 250;
const IDLE_AFTER_SEND: u64 = 300;
const IDLE_AFTER_RETURN: u64 = 550;
const FUNDING_AFTER_RETURN: u64 = 450;
const AVAILABLE_AFTER_RETURN: u64 = 550;
const FEE_INCENTIVE_CAP: u64 = 100;
const FIRST_FEE_INCENTIVE: u64 = 40;
const SECOND_FEE_INCENTIVE_REQUEST: u64 = 80;
const SECOND_FEE_INCENTIVE_ALLOCATION: u64 = 60;
const ZERO_AMOUNT: u64 = 0;
const TWO_COUNT: u64 = 2;
const TERMINAL_FIRST_RETURN: u64 = 600;
const TERMINAL_FIRST_GAIN: u64 = 300;
const TERMINAL_SECOND_GAIN: u64 = 200;
const TERMINAL_LOSS: u64 = 400;
const REMAINING_LOSS: u64 = 100;
const MATERIALIZED_PROFIT: u64 = 100;
const FINAL_DEBITS: u64 = 1_100;
const PURE_PROFIT: u64 = 500;
const CROSS_EXPIRY_PROFIT: u64 = 500;
const CROSS_EXPIRY_MATERIALIZED: u64 = 100;
const PROTOCOL_CUT: u64 = 100;
const FIRST_PROTOCOL_IDLE: u64 = 40;
const FIRST_PROTOCOL_CARRY: u64 = 60;
const SECOND_PROTOCOL_IDLE: u64 = 50;
const SECOND_PROTOCOL_CARRY: u64 = 10;
const FINAL_PROTOCOL_IDLE: u64 = 10;
const TWO_EXPIRY_IDLE: u64 = 2_000;
const TWO_TERMINAL_LOSSES: u64 = 800;
const PROFIT_AFTER_TWO_LOSSES: u64 = 900;
const PROFITABLE_START_RETURN: u64 = 900;
const PROFITABLE_START_GAIN: u64 = 200;

fun registered_ledger(ctx: &mut TxContext): (pool_accounting::Ledger, ID) {
    let mut ledger = pool_accounting::new(ctx);
    let expiry_id = object::id_from_address(EXPIRY_A);
    ledger.register_expiry(
        expiry_id,
        EXPIRY_A_MS,
        MAX_EXPIRY_ALLOCATION,
        INITIAL_EXPIRY_CASH,
    );
    (ledger, expiry_id)
}

#[test]
fun send_and_receive_conserve_idle_and_track_profit_basis() {
    let ctx = &mut tx_context::dummy();
    let (mut ledger, expiry_id) = registered_ledger(ctx);
    ledger.receive_idle(balance::create_for_testing<DUSDC>(INITIAL_IDLE));

    let sent = ledger.send_expiry_cash(expiry_id, SENT_TO_EXPIRY);
    assert_eq!(sent.value(), SENT_TO_EXPIRY);
    assert_eq!(ledger.idle_balance(), IDLE_AFTER_SEND);
    assert_eq!(ledger.profit_basis_debits(), SENT_TO_EXPIRY);
    assert_eq!(ledger.profit_basis_credits(), ZERO_AMOUNT);

    assert_eq!(
        ledger.receive_expiry_cash(balance::create_for_testing<DUSDC>(FIRST_RETURN), expiry_id),
        FIRST_RETURN,
    );
    assert_eq!(ledger.idle_balance(), IDLE_AFTER_RETURN);
    assert_eq!(ledger.profit_basis_credits(), FIRST_RETURN);
    assert_eq!(SENT_TO_EXPIRY - FIRST_RETURN, FUNDING_AFTER_RETURN);
    assert_eq!(ledger.available_expiry_funding(expiry_id), AVAILABLE_AFTER_RETURN);
    destroy(sent);
    destroy(ledger);
}

#[test]
fun fee_incentive_allocations_saturate_at_the_lifetime_cap() {
    let ctx = &mut tx_context::dummy();
    let (mut ledger, expiry_id) = registered_ledger(ctx);

    let (first, first_total) = ledger.record_fee_incentives_allocated_up_to(
        expiry_id,
        FEE_INCENTIVE_CAP,
        FIRST_FEE_INCENTIVE,
    );
    assert_eq!(first, FIRST_FEE_INCENTIVE);
    assert_eq!(first_total, FIRST_FEE_INCENTIVE);
    let (second, second_total) = ledger.record_fee_incentives_allocated_up_to(
        expiry_id,
        FEE_INCENTIVE_CAP,
        SECOND_FEE_INCENTIVE_REQUEST,
    );
    assert_eq!(second, SECOND_FEE_INCENTIVE_ALLOCATION);
    assert_eq!(second_total, FEE_INCENTIVE_CAP);
    let (third, third_total) = ledger.record_fee_incentives_allocated_up_to(
        expiry_id,
        FEE_INCENTIVE_CAP,
        FIRST_FEE_INCENTIVE,
    );
    assert_eq!(third, ZERO_AMOUNT);
    assert_eq!(third_total, FEE_INCENTIVE_CAP);
    destroy(ledger);
}

#[test]
fun terminal_loss_carries_until_later_gains_refill_it() {
    let ctx = &mut tx_context::dummy();
    let (mut ledger, expiry_id) = registered_ledger(ctx);
    ledger.receive_idle(balance::create_for_testing<DUSDC>(INITIAL_IDLE));
    destroy(ledger.send_expiry_cash(expiry_id, MAX_EXPIRY_ALLOCATION));
    ledger.receive_expiry_cash(
        balance::create_for_testing<DUSDC>(TERMINAL_FIRST_RETURN),
        expiry_id,
    );

    assert_eq!(MAX_EXPIRY_ALLOCATION - TERMINAL_FIRST_RETURN, TERMINAL_LOSS);
    assert_eq!(ledger.materialize_expiry_profit(expiry_id), ZERO_AMOUNT);
    assert_eq!(ledger.profit_basis_debits(), MAX_EXPIRY_ALLOCATION);
    ledger.receive_expiry_cash(
        balance::create_for_testing<DUSDC>(TERMINAL_FIRST_GAIN),
        expiry_id,
    );
    assert_eq!(TERMINAL_LOSS - TERMINAL_FIRST_GAIN, REMAINING_LOSS);
    assert_eq!(ledger.materialize_expiry_profit(expiry_id), ZERO_AMOUNT);
    ledger.receive_expiry_cash(
        balance::create_for_testing<DUSDC>(TERMINAL_SECOND_GAIN),
        expiry_id,
    );
    assert_eq!(TERMINAL_SECOND_GAIN - REMAINING_LOSS, MATERIALIZED_PROFIT);
    assert_eq!(ledger.materialize_expiry_profit(expiry_id), MATERIALIZED_PROFIT);
    assert_eq!(ledger.profit_basis_debits(), FINAL_DEBITS);
    destroy(ledger);
}

#[test]
fun two_terminal_losses_accumulate_before_later_profit() {
    let ctx = &mut tx_context::dummy();
    let (mut ledger, expiry_a) = registered_ledger(ctx);
    let expiry_b = object::id_from_address(EXPIRY_B);
    ledger.register_expiry(
        expiry_b,
        EXPIRY_B_MS,
        MAX_EXPIRY_ALLOCATION,
        INITIAL_EXPIRY_CASH,
    );
    ledger.receive_idle(balance::create_for_testing<DUSDC>(TWO_EXPIRY_IDLE));
    destroy(ledger.send_expiry_cash(expiry_a, MAX_EXPIRY_ALLOCATION));
    destroy(ledger.send_expiry_cash(expiry_b, MAX_EXPIRY_ALLOCATION));
    ledger.receive_expiry_cash(
        balance::create_for_testing<DUSDC>(TERMINAL_FIRST_RETURN),
        expiry_a,
    );
    ledger.receive_expiry_cash(
        balance::create_for_testing<DUSDC>(TERMINAL_FIRST_RETURN),
        expiry_b,
    );

    assert_eq!(ledger.materialize_expiry_profit(expiry_a), ZERO_AMOUNT);
    assert_eq!(ledger.materialize_expiry_profit(expiry_b), ZERO_AMOUNT);
    assert_eq!(TWO_TERMINAL_LOSSES, TWO_COUNT * TERMINAL_LOSS);
    ledger.receive_expiry_cash(
        balance::create_for_testing<DUSDC>(PROFIT_AFTER_TWO_LOSSES),
        expiry_b,
    );
    assert_eq!(ledger.materialize_expiry_profit(expiry_b), MATERIALIZED_PROFIT);
    assert_eq!(ledger.profit_basis_debits(), TWO_EXPIRY_IDLE + MATERIALIZED_PROFIT);
    destroy(ledger);
}

#[test]
fun profitable_terminal_start_uses_sent_cash_as_its_watermark() {
    let ctx = &mut tx_context::dummy();
    let (mut ledger, expiry_id) = registered_ledger(ctx);
    ledger.receive_idle(balance::create_for_testing<DUSDC>(INITIAL_IDLE));
    destroy(ledger.send_expiry_cash(expiry_id, SENT_TO_EXPIRY));
    ledger.receive_expiry_cash(
        balance::create_for_testing<DUSDC>(PROFITABLE_START_RETURN),
        expiry_id,
    );

    assert_eq!(PROFITABLE_START_RETURN - SENT_TO_EXPIRY, PROFITABLE_START_GAIN);
    assert_eq!(ledger.materialize_expiry_profit(expiry_id), PROFITABLE_START_GAIN);
    assert_eq!(ledger.profit_basis_debits(), PROFITABLE_START_RETURN);
    assert_eq!(ledger.materialize_expiry_profit(expiry_id), ZERO_AMOUNT);
    destroy(ledger);
}

#[test]
fun terminal_profit_without_funding_materializes_once() {
    let ctx = &mut tx_context::dummy();
    let (mut ledger, expiry_id) = registered_ledger(ctx);
    ledger.receive_expiry_cash(balance::create_for_testing<DUSDC>(PURE_PROFIT), expiry_id);

    assert_eq!(ledger.materialize_expiry_profit(expiry_id), PURE_PROFIT);
    assert_eq!(ledger.profit_basis_debits(), PURE_PROFIT);
    assert_eq!(ledger.materialize_expiry_profit(expiry_id), ZERO_AMOUNT);
    assert_eq!(ledger.profit_basis_debits(), PURE_PROFIT);
    assert_eq!(ledger.available_expiry_funding(expiry_id), MAX_EXPIRY_ALLOCATION);
    destroy(ledger);
}

#[test]
fun later_expiry_profit_refills_prior_expiry_loss_before_materializing() {
    let ctx = &mut tx_context::dummy();
    let (mut ledger, expiry_a) = registered_ledger(ctx);
    let expiry_b = object::id_from_address(EXPIRY_B);
    ledger.register_expiry(
        expiry_b,
        EXPIRY_B_MS,
        MAX_EXPIRY_ALLOCATION,
        INITIAL_EXPIRY_CASH,
    );
    ledger.receive_idle(balance::create_for_testing<DUSDC>(INITIAL_IDLE));
    destroy(ledger.send_expiry_cash(expiry_a, MAX_EXPIRY_ALLOCATION));
    ledger.receive_expiry_cash(
        balance::create_for_testing<DUSDC>(TERMINAL_FIRST_RETURN),
        expiry_a,
    );
    assert_eq!(ledger.materialize_expiry_profit(expiry_a), ZERO_AMOUNT);

    ledger.receive_expiry_cash(
        balance::create_for_testing<DUSDC>(CROSS_EXPIRY_PROFIT),
        expiry_b,
    );
    assert_eq!(CROSS_EXPIRY_PROFIT - TERMINAL_LOSS, CROSS_EXPIRY_MATERIALIZED);
    assert_eq!(ledger.materialize_expiry_profit(expiry_b), CROSS_EXPIRY_MATERIALIZED);
    assert_eq!(ledger.profit_basis_debits(), MAX_EXPIRY_ALLOCATION + CROSS_EXPIRY_MATERIALIZED);
    destroy(ledger);
}

#[test]
fun protocol_profit_realization_carries_only_the_idle_shortfall() {
    let ctx = &mut tx_context::dummy();
    let mut ledger = pool_accounting::new(ctx);
    ledger.receive_idle(balance::create_for_testing<DUSDC>(FIRST_PROTOCOL_IDLE));

    let first = ledger.realize_protocol_profit(PROTOCOL_CUT);
    assert_eq!(first.value(), FIRST_PROTOCOL_IDLE);
    assert_eq!(ledger.idle_balance(), ZERO_AMOUNT);
    assert_eq!(ledger.pending_protocol_profit(), FIRST_PROTOCOL_CARRY);

    ledger.receive_idle(balance::create_for_testing<DUSDC>(SECOND_PROTOCOL_IDLE));
    let second = ledger.realize_pending_protocol_profit();
    assert_eq!(second.value(), SECOND_PROTOCOL_IDLE);
    assert_eq!(ledger.pending_protocol_profit(), SECOND_PROTOCOL_CARRY);

    ledger.receive_idle(balance::create_for_testing<DUSDC>(FINAL_PROTOCOL_IDLE));
    let final = ledger.realize_pending_protocol_profit();
    assert_eq!(final.value(), FINAL_PROTOCOL_IDLE);
    assert_eq!(ledger.pending_protocol_profit(), ZERO_AMOUNT);
    assert_eq!(ledger.idle_balance(), ZERO_AMOUNT);
    destroy(first);
    destroy(second);
    destroy(final);
    destroy(ledger);
}
