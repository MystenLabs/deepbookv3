// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module deepbook::pool_tests;

use deepbook::{
    balance_manager::{
        Self,
        BalanceManager,
        TradeCap,
        DeepBookPoolReferral,
        DepositCap,
        WithdrawCap
    },
    balance_manager_tests::{
        USDC,
        USDT,
        SPAM,
        create_acct_and_share_with_funds,
        create_acct_and_share_with_funds_typed,
        create_acct_only_deep_and_share_with_funds,
        create_caps,
        asset_balance
    },
    big_vector::BigVector,
    constants,
    fill::Fill,
    math,
    order::Order,
    order_info::OrderInfo,
    pool::{Self, Pool},
    registry::{Self, Registry},
    utils
};
use std::unit_test::{assert_eq, destroy};
use sui::{
    clock::{Self, Clock},
    coin::{Self, Coin, mint_for_testing},
    sui::SUI,
    test_scenario::{Scenario, begin, end, return_shared}
};
use token::deep::DEEP;

const OWNER: address = @0x1;
const ALICE: address = @0xAAAA;
const BOB: address = @0xBBBB;

/// Create a pool with 1000 limit sell at $2 and 1000 limit buy at $1.
#[test_only]
public fun setup_everything<BaseAsset, QuoteAsset, ReferenceBaseAsset, ReferenceQuoteAsset>(
    test: &mut Scenario,
): ID {
    let registry_id = setup_test(OWNER, test);
    let balance_manager_id_alice = create_acct_and_share_with_funds_typed<
        BaseAsset,
        QuoteAsset,
        ReferenceBaseAsset,
        ReferenceQuoteAsset,
    >(
        ALICE,
        1000000 * constants::float_scaling(),
        test,
    );
    let pool_id = setup_pool_with_default_fees_and_reference_pool<
        BaseAsset,
        QuoteAsset,
        ReferenceBaseAsset,
        ReferenceQuoteAsset,
    >(ALICE, registry_id, balance_manager_id_alice, test);

    let client_order_id = 1;
    let order_type = constants::no_restriction();
    let price = 2 * constants::float_scaling();
    let quantity = 1000 * constants::float_scaling();
    let expire_timestamp = constants::max_u64();
    place_limit_order<BaseAsset, QuoteAsset>(
        ALICE,
        pool_id,
        balance_manager_id_alice,
        client_order_id,
        order_type,
        constants::self_matching_allowed(),
        price,
        quantity,
        false,
        true,
        expire_timestamp,
        test,
    );

    let price = 1 * constants::float_scaling();
    place_limit_order<BaseAsset, QuoteAsset>(
        ALICE,
        pool_id,
        balance_manager_id_alice,
        client_order_id,
        order_type,
        constants::self_matching_allowed(),
        price,
        quantity,
        true,
        true,
        expire_timestamp,
        test,
    );

    pool_id
}

#[test]
fun test_place_order_bid() {
    place_order_ok(true);
}

#[test]
fun test_update_pool_book_params_ok() {
    test_update_pool_book_params(0);
}

#[test, expected_failure(abort_code = ::deepbook::order_info::EOrderInvalidLotSize)]
fun test_update_pool_book_params_trade_e() {
    test_update_pool_book_params(1);
}

#[test, expected_failure(abort_code = ::deepbook::pool::EInvalidLotSize)]
fun test_update_pool_book_params_update_e() {
    test_update_pool_book_params(2);
}

#[test, expected_failure(abort_code = ::deepbook::pool::EInvalidTickSize)]
fun test_update_pool_book_params_tick_e() {
    test_update_pool_book_params(3);
}

#[test, expected_failure(abort_code = ::deepbook::pool::EInvalidLotSize)]
fun test_update_pool_book_params_small_lot_e() {
    test_update_pool_book_params(4);
}

#[test]
fun test_place_order_ask() {
    place_order_ok(false);
}

#[test]
fun test_place_and_cancel_order_bid() {
    place_and_cancel_order_ok(true);
}

#[test]
fun test_place_and_cancel_order_ask() {
    place_and_cancel_order_ok(false);
}

#[test]
fun test_place_then_fill_bid_ask() {
    place_then_fill(
        false,
        true,
        constants::no_restriction(),
        3 * constants::float_scaling(),
        3 * constants::float_scaling(),
        6 * constants::float_scaling(),
        3 * math::mul(constants::taker_fee(), constants::deep_multiplier()),
        constants::filled(),
    );
}

#[test]
fun test_place_then_fill_bid_ask_stable() {
    place_then_fill(
        true,
        true,
        constants::no_restriction(),
        3 * constants::float_scaling(),
        3 * constants::float_scaling(),
        6 * constants::float_scaling(),
        3 *
        math::mul(constants::stable_taker_fee(), constants::deep_multiplier()),
        constants::filled(),
    );
}

#[test]
fun test_place_then_fill_ask_bid() {
    place_then_fill(
        false,
        false,
        constants::no_restriction(),
        3 * constants::float_scaling(),
        3 * constants::float_scaling(),
        6 * constants::float_scaling(),
        3 * math::mul(constants::taker_fee(), constants::deep_multiplier()),
        constants::filled(),
    );
}

#[test]
fun test_place_then_fill_ask_bid_stable() {
    place_then_fill(
        true,
        false,
        constants::no_restriction(),
        3 * constants::float_scaling(),
        3 * constants::float_scaling(),
        6 * constants::float_scaling(),
        3 *
        math::mul(constants::stable_taker_fee(), constants::deep_multiplier()),
        constants::filled(),
    );
}

#[test]
fun test_place_then_ioc_bid_ask() {
    place_then_fill(
        false,
        true,
        constants::immediate_or_cancel(),
        3 * constants::float_scaling(),
        3 * constants::float_scaling(),
        6 * constants::float_scaling(),
        3 * math::mul(constants::taker_fee(), constants::deep_multiplier()),
        constants::filled(),
    );
}

#[test]
fun test_place_then_ioc_bid_ask_stable() {
    place_then_fill(
        true,
        true,
        constants::immediate_or_cancel(),
        3 * constants::float_scaling(),
        3 * constants::float_scaling(),
        6 * constants::float_scaling(),
        3 *
        math::mul(constants::stable_taker_fee(), constants::deep_multiplier()),
        constants::filled(),
    );
}

#[test]
fun test_place_then_ioc_ask_bid() {
    place_then_fill(
        false,
        false,
        constants::immediate_or_cancel(),
        3 * constants::float_scaling(),
        3 * constants::float_scaling(),
        6 * constants::float_scaling(),
        3 * math::mul(constants::taker_fee(), constants::deep_multiplier()),
        constants::filled(),
    );
}

#[test]
fun test_place_then_ioc_ask_bid_stable() {
    place_then_fill(
        true,
        false,
        constants::immediate_or_cancel(),
        3 * constants::float_scaling(),
        3 * constants::float_scaling(),
        6 * constants::float_scaling(),
        3 *
        math::mul(constants::stable_taker_fee(), constants::deep_multiplier()),
        constants::filled(),
    );
}

#[test]
fun test_fills_bid_ok() {
    place_then_fill_correct(
        true,
        constants::no_restriction(),
        3 * constants::float_scaling(),
    );
}

#[test]
fun test_fills_ask_ok() {
    place_then_fill_correct(
        false,
        constants::no_restriction(),
        3 * constants::float_scaling(),
    );
}

#[test, expected_failure(abort_code = ::deepbook::big_vector::ENotFound)]
fun test_place_then_ioc_no_fill_bid_ask_order_removed_e() {
    place_then_no_fill(
        true,
        constants::immediate_or_cancel(),
        0,
        0,
        0,
        constants::canceled(),
    );
}

#[test, expected_failure(abort_code = ::deepbook::big_vector::ENotFound)]
fun test_place_then_ioc_no_fill_ask_bid_order_removed_e() {
    place_then_no_fill(
        false,
        constants::immediate_or_cancel(),
        0,
        0,
        0,
        constants::canceled(),
    );
}

#[test, expected_failure(abort_code = ::deepbook::big_vector::ENotFound)]
fun test_expired_order_removed_bid_ask_e() {
    place_order_expire_timestamp_e(
        true,
        constants::no_restriction(),
        0,
        0,
        0,
        constants::live(),
    );
}

#[test, expected_failure(abort_code = ::deepbook::big_vector::ENotFound)]
fun test_expired_order_removed_ask_bid_e() {
    place_order_expire_timestamp_e(
        false,
        constants::no_restriction(),
        0,
        0,
        0,
        constants::live(),
    );
}

#[test]
fun test_partial_fill_order_bid_ok() {
    partial_fill_order(
        true,
        constants::no_restriction(),
        3 * constants::float_scaling(),
        3 * constants::float_scaling(),
        6 * constants::float_scaling(),
        3 * math::mul(constants::taker_fee(), constants::deep_multiplier()),
        constants::partially_filled(),
    );
}

#[test]
fun test_partial_fill_order_ask_ok() {
    partial_fill_order(
        false,
        constants::no_restriction(),
        3 * constants::float_scaling(),
        3 * constants::float_scaling(),
        6 * constants::float_scaling(),
        3 * math::mul(constants::taker_fee(), constants::deep_multiplier()),
        constants::partially_filled(),
    );
}

#[test]
fun test_fill_partial_maker_bid_ok() {
    partial_fill_maker_order(
        true,
        constants::no_restriction(),
        3 * constants::float_scaling(),
        3 * constants::float_scaling() / 2,
        3 * constants::float_scaling(),
        3 * math::mul(constants::taker_fee(), constants::deep_multiplier()) / 2,
        constants::partially_filled(),
    );
}

#[test]
fun test_fill_partial_maker_ask_ok() {
    partial_fill_maker_order(
        false,
        constants::no_restriction(),
        3 * constants::float_scaling(),
        3 * constants::float_scaling() / 2,
        3 * constants::float_scaling(),
        3 * math::mul(constants::taker_fee(), constants::deep_multiplier()) / 2,
        constants::partially_filled(),
    );
}

#[test]
fun test_partially_filled_maker_bid_ok() {
    partially_filled_order_taken(true);
}

#[test]
fun test_partially_filled_maker_ask_ok() {
    partially_filled_order_taken(false);
}

#[test, expected_failure(abort_code = ::deepbook::order_info::EOrderBelowMinimumSize)]
fun test_invalid_order_quantity_e() {
    place_with_price_quantity(
        2 * constants::float_scaling(),
        0,
    );
}

#[test, expected_failure(abort_code = ::deepbook::order_info::EOrderInvalidLotSize)]
fun test_invalid_lot_size_e() {
    place_with_price_quantity(
        2 * constants::float_scaling(),
        1_000_000_100,
    );
}

#[test, expected_failure(abort_code = ::deepbook::order_info::EOrderInvalidPrice)]
fun test_invalid_tick_size_e() {
    place_with_price_quantity(
        2_000_000_100,
        1 * constants::float_scaling(),
    );
}

#[test, expected_failure(abort_code = ::deepbook::order_info::EOrderInvalidPrice)]
fun test_price_above_max_e() {
    place_with_price_quantity(
        constants::max_u64(),
        1 * constants::float_scaling(),
    );
}

#[test, expected_failure(abort_code = ::deepbook::order_info::EOrderInvalidPrice)]
fun test_price_below_min_e() {
    place_with_price_quantity(
        0,
        1 * constants::float_scaling(),
    );
}

#[test, expected_failure(abort_code = ::deepbook::order_info::ESelfMatchingCancelTaker)]
fun test_self_matching_cancel_taker_bid() {
    test_self_matching_cancel_taker(true);
}

#[test, expected_failure(abort_code = ::deepbook::order_info::ESelfMatchingCancelTaker)]
fun test_self_matching_cancel_taker_ask() {
    test_self_matching_cancel_taker(false);
}

#[test, expected_failure(abort_code = ::deepbook::big_vector::ENotFound)]
fun test_self_matching_cancel_maker_bid() {
    test_self_matching_cancel_maker(true);
}

#[test, expected_failure(abort_code = ::deepbook::big_vector::ENotFound)]
fun test_self_matching_cancel_maker_ask() {
    test_self_matching_cancel_maker(false);
}

#[test]
fun test_swap_exact_amount_bid_ask() {
    test_swap_exact_amount(true, false);
}

#[test]
fun test_swap_exact_amount_ask_bid() {
    test_swap_exact_amount(false, false);
}

#[test]
fun test_swap_exact_amount_bid_ask_with_manager() {
    test_swap_exact_amount(true, true);
}

#[test]
fun test_swap_exact_amount_ask_bid_with_manager() {
    test_swap_exact_amount(false, true);
}

#[test]
fun test_swap_exact_amount_with_input_bid_ask() {
    test_swap_exact_amount_with_input(true);
}

#[test]
fun test_swap_exact_amount_with_input_ask_bid() {
    test_swap_exact_amount_with_input(false);
}

#[test]
fun test_get_quantity_out_input_fee_bid_ask_zero() {
    test_get_quantity_out_zero(true);
}

#[test]
fun test_get_quantity_out_input_fee_ask_bid_zero() {
    test_get_quantity_out_zero(false);
}

#[test, expected_failure(abort_code = ::deepbook::big_vector::ENotFound)]
fun test_cancel_all_orders_bid_e() {
    test_cancel_all_orders(true, true);
}

#[test, expected_failure(abort_code = ::deepbook::big_vector::ENotFound)]
fun test_cancel_all_orders_ask_e() {
    test_cancel_all_orders(false, true);
}

#[test]
fun test_cancel_all_orders_bid_ok() {
    test_cancel_all_orders(true, false);
}

#[test]
fun test_cancel_all_orders_ask_ok() {
    test_cancel_all_orders(false, false);
}

#[test, expected_failure(abort_code = ::deepbook::big_vector::ENotFound)]
fun test_cancel_orders_bid() {
    test_cancel_orders(true);
}

#[test, expected_failure(abort_code = ::deepbook::big_vector::ENotFound)]
fun test_cancel_orders_ask() {
    test_cancel_orders(false);
}

#[test, expected_failure(abort_code = ::deepbook::order_info::EPOSTOrderCrossesOrderbook)]
fun test_post_only_bid_e() {
    test_post_only(true, true);
}

#[test, expected_failure(abort_code = ::deepbook::order_info::EPOSTOrderCrossesOrderbook)]
fun test_post_only_ask_e() {
    test_post_only(false, true);
}

#[test]
fun test_post_only_bid_ok() {
    test_post_only(true, false);
}

#[test]
fun test_post_only_ask_ok() {
    test_post_only(false, false);
}

#[test]
fun test_crossing_multiple_orders_bid_ok() {
    test_crossing_multiple(true, 3)
}

#[test]
fun test_crossing_multiple_orders_ask_ok() {
    test_crossing_multiple(false, 3)
}

#[test, expected_failure(abort_code = ::deepbook::order_info::EFOKOrderCannotBeFullyFilled)]
fun test_fill_or_kill_bid_e() {
    test_fill_or_kill(true, false);
}

#[test, expected_failure(abort_code = ::deepbook::order_info::EFOKOrderCannotBeFullyFilled)]
fun test_fill_or_kill_ask_e() {
    test_fill_or_kill(false, false);
}

#[test]
fun test_fill_or_kill_bid_ok() {
    test_fill_or_kill(true, true);
}

#[test]
fun test_fill_or_kill_ask_ok() {
    test_fill_or_kill(false, true);
}

#[test]
fun test_market_order_bid_then_ask_ok() {
    test_market_order(true);
}

#[test]
fun test_market_order_ask_then_bid_ok() {
    test_market_order(false);
}

#[test]
fun test_mid_price_ok() {
    test_mid_price();
}

#[test]
fun test_swap_exact_not_fully_filled_bid_ok() {
    test_swap_exact_not_fully_filled(true, false, false, false, false);
}

#[test]
fun test_swap_exact_not_fully_filled_bid_with_manager_ok() {
    test_swap_exact_not_fully_filled(true, false, false, false, true);
}

#[test]
fun test_swap_exact_not_fully_filled_ask_ok() {
    test_swap_exact_not_fully_filled(false, false, false, false, false);
}

#[test]
fun test_swap_exact_not_fully_filled_ask_with_manager_ok() {
    test_swap_exact_not_fully_filled(false, false, false, false, true);
}

#[test]
fun test_swap_exact_not_fully_filled_bid_low_qty_ok() {
    test_swap_exact_not_fully_filled(true, true, false, false, false);
}

#[test]
fun test_swap_exact_not_fully_filled_bid_with_manager_low_qty_ok() {
    test_swap_exact_not_fully_filled(true, true, false, false, true);
}

#[test]
fun test_swap_exact_not_fully_filled_ask_low_qty_ok() {
    test_swap_exact_not_fully_filled(false, true, false, false, false);
}

#[test]
fun test_swap_exact_not_fully_filled_ask_with_manager_low_qty_ok() {
    test_swap_exact_not_fully_filled(false, true, false, false, true);
}

#[test, expected_failure(abort_code = ::deepbook::pool::EMinimumQuantityOutNotMet)]
fun test_swap_exact_not_fully_filled_bid_min_e() {
    test_swap_exact_not_fully_filled(true, false, true, false, false);
}

#[test, expected_failure(abort_code = ::deepbook::pool::EMinimumQuantityOutNotMet)]
fun test_swap_exact_not_fully_filled_bid_with_manager_min_e() {
    test_swap_exact_not_fully_filled(true, false, true, false, true);
}

#[test, expected_failure(abort_code = ::deepbook::pool::EMinimumQuantityOutNotMet)]
fun test_swap_exact_not_fully_filled_ask_min_e() {
    test_swap_exact_not_fully_filled(false, false, true, false, false);
}

#[test, expected_failure(abort_code = ::deepbook::pool::EMinimumQuantityOutNotMet)]
fun test_swap_exact_not_fully_filled_ask_with_manager_min_e() {
    test_swap_exact_not_fully_filled(false, false, true, false, true);
}

#[test]
fun test_swap_exact_not_fully_filled_maker_partial_bid_ok() {
    test_swap_exact_not_fully_filled(true, false, false, true, false);
}

#[test]
fun test_swap_exact_not_fully_filled_maker_partial_bid_with_manager_ok() {
    test_swap_exact_not_fully_filled(true, false, false, true, true);
}

#[test]
fun test_swap_exact_not_fully_filled_maker_partial_ask_ok() {
    test_swap_exact_not_fully_filled(false, false, false, true, false);
}

#[test]
fun test_swap_exact_not_fully_filled_maker_partial_ask_with_manager_ok() {
    test_swap_exact_not_fully_filled(false, false, false, true, true);
}

#[test]
fun test_swap_with_manager_zero_base_out_ok() {
    test_swap_with_manager_zero_out(true);
}

#[test]
fun test_swap_with_manager_zero_quote_out_ok() {
    test_swap_with_manager_zero_out(false);
}

#[test]
fun test_unregister_pool_ok() {
    test_unregister_pool(true);
}

#[test, expected_failure(abort_code = ::deepbook::registry::EPoolAlreadyExists)]
fun test_duplicate_pool_e() {
    test_unregister_pool(false);
}

#[test]
fun test_get_pool_id_by_asset_ok() {
    test_get_pool_id_by_asset();
}

#[test]
fun test_modify_order_bid_ok() {
    test_modify_order(
        3 * constants::float_scaling(),
        2 * constants::float_scaling(),
        0,
        true,
        true,
    );
}

#[test]
fun test_modify_order_ask_ok() {
    test_modify_order(
        3 * constants::float_scaling(),
        2 * constants::float_scaling(),
        0,
        false,
        true,
    );
}

#[test, expected_failure(abort_code = ::deepbook::book::ENewQuantityMustBeLessThanOriginal)]
fun test_modify_order_increase_bid_e() {
    test_modify_order(
        2 * constants::float_scaling(),
        3 * constants::float_scaling(),
        0,
        true,
        true,
    );
}

#[test, expected_failure(abort_code = ::deepbook::book::ENewQuantityMustBeLessThanOriginal)]
fun test_modify_order_increase_ask_e() {
    test_modify_order(
        2 * constants::float_scaling(),
        3 * constants::float_scaling(),
        0,
        false,
        true,
    );
}

#[test, expected_failure(abort_code = ::deepbook::order::EInvalidNewQuantity)]
fun test_modify_order_invalid_new_quantity_bid_e() {
    test_modify_order(
        3 * constants::float_scaling(),
        2 * constants::float_scaling(),
        2 * constants::float_scaling(),
        true,
        true,
    );
}

#[test, expected_failure(abort_code = ::deepbook::order::EInvalidNewQuantity)]
fun test_modify_order_invalid_new_quantity_ask_e() {
    test_modify_order(
        3 * constants::float_scaling(),
        2 * constants::float_scaling(),
        2 * constants::float_scaling(),
        false,
        true,
    );
}

#[test]
fun test_modify_order_bid_input_ok() {
    test_modify_order(
        3 * constants::float_scaling(),
        2 * constants::float_scaling(),
        0,
        true,
        false,
    );
}

#[test]
fun test_modify_order_ask_input_ok() {
    test_modify_order(
        3 * constants::float_scaling(),
        2 * constants::float_scaling(),
        0,
        false,
        false,
    );
}

#[test, expected_failure(abort_code = ::deepbook::book::ENewQuantityMustBeLessThanOriginal)]
fun test_modify_order_increase_bid_input_e() {
    test_modify_order(
        2 * constants::float_scaling(),
        3 * constants::float_scaling(),
        0,
        true,
        false,
    );
}

#[test, expected_failure(abort_code = ::deepbook::book::ENewQuantityMustBeLessThanOriginal)]
fun test_modify_order_increase_ask_input_e() {
    test_modify_order(
        2 * constants::float_scaling(),
        3 * constants::float_scaling(),
        0,
        false,
        false,
    );
}

#[test, expected_failure(abort_code = ::deepbook::order::EInvalidNewQuantity)]
fun test_modify_order_invalid_new_quantity_bid_input_e() {
    test_modify_order(
        3 * constants::float_scaling(),
        2 * constants::float_scaling(),
        2 * constants::float_scaling(),
        true,
        false,
    );
}

#[test, expected_failure(abort_code = ::deepbook::order::EInvalidNewQuantity)]
fun test_modify_order_invalid_new_quantity_ask_input_e() {
    test_modify_order(
        3 * constants::float_scaling(),
        2 * constants::float_scaling(),
        2 * constants::float_scaling(),
        false,
        false,
    );
}

#[test]
fun test_queue_priority_bid_ok() {
    test_queue_priority(true);
}

#[test]
fun test_queue_priority_ask_ok() {
    test_queue_priority(false);
}

#[test, expected_failure(abort_code = ::deepbook::order_info::EOrderInvalidPrice)]
fun test_place_order_with_maxu64_as_price_e() {
    test_place_order_edge_price(
        1 * constants::float_scaling(),
        constants::max_u64() - constants::max_u64() % constants::tick_size(),
    )
}

#[test, expected_failure(abort_code = ::deepbook::order_info::EOrderInvalidPrice)]
fun test_place_order_with_zero_as_price_e() {
    test_place_order_edge_price(1 * constants::float_scaling(), 0)
}

#[test]
fun test_place_order_with_maxprice_ok() {
    test_place_order_edge_price(
        1 * constants::float_scaling(),
        constants::max_price() -
        constants::max_price() % constants::tick_size(),
    )
}

#[test]
fun test_place_order_with_minprice_ok() {
    test_place_order_edge_price(
        1 * constants::float_scaling(),
        constants::tick_size(),
    )
}

#[test]
fun test_place_order_with_min_quantity_ok() {
    test_place_order_edge_price(constants::min_size(), constants::tick_size())
}

#[test, expected_failure(abort_code = ::deepbook::order_info::EOrderBelowMinimumSize)]
fun test_place_order_with_lower_min_quantity_e() {
    test_place_order_edge_price(constants::lot_size(), constants::tick_size())
}

#[test]
fun test_order_limit_bid_ok() {
    test_order_limit(true);
}

#[test]
fun test_order_limit_ask_ok() {
    test_order_limit(false);
}

#[test, expected_failure(abort_code = ::deepbook::pool::EIneligibleReferencePool)]
fun test_using_unregistered_as_reference() {
    let mut test = begin(OWNER);
    let registry_id = setup_test(OWNER, &mut test);
    let balance_manager_id_alice = create_acct_and_share_with_funds(
        ALICE,
        1000000 * constants::float_scaling(),
        &mut test,
    );
    setup_pool_with_default_fees_and_reference_pool_unregistered<SUI, USDC, SUI, DEEP>(
        ALICE,
        registry_id,
        balance_manager_id_alice,
        &mut test,
    );
    end(test);
}

#[test, expected_failure(abort_code = ::deepbook::pool::EPoolCannotBeBothWhitelistedAndStable)]
fun test_create_pool_e() {
    test_create_pool(true, true);
}

#[test]
fun test_create_pool_1_ok() {
    test_create_pool(false, true);
}

#[test]
fun test_create_pool_2_ok() {
    test_create_pool(true, false);
}

#[test]
fun test_create_pool_3_ok() {
    test_create_pool(false, false);
}

#[test]
fun test_get_order() {
    let mut test = begin(OWNER);
    let registry_id = setup_test(OWNER, &mut test);
    let balance_manager_id_alice = create_acct_and_share_with_funds(
        ALICE,
        1000000 * constants::float_scaling(),
        &mut test,
    );
    let pool_id = setup_pool_with_default_fees_and_reference_pool<SUI, USDC, SUI, DEEP>(
        ALICE,
        registry_id,
        balance_manager_id_alice,
        &mut test,
    );
    let order_info = place_limit_order<SUI, USDC>(
        ALICE,
        pool_id,
        balance_manager_id_alice,
        1,
        constants::no_restriction(),
        constants::self_matching_allowed(),
        100 * constants::float_scaling(),
        1 * constants::float_scaling(),
        true,
        true,
        constants::max_u64(),
        &mut test,
    );
    let order = get_order(pool_id, order_info.order_id(), &mut test);
    assert!(order.order_id() == order_info.order_id(), 0);
    assert!(order.client_order_id() == 1, 0);
    assert!(order.balance_manager_id() == balance_manager_id_alice, 0);
    assert!(order.quantity() == 1 * constants::float_scaling(), 0);
    assert!(order.filled_quantity() == 0, 0);
    assert!(order.fee_is_deep() == true, 0);
    assert!(order.order_deep_price().deep_per_asset() ==
        constants::deep_multiplier(), 0);
    assert!(order.epoch() == 0, 0);
    assert!(order.status() == constants::live(), 0);
    assert!(order.expire_timestamp() == constants::max_u64(), 0);

    end(test);
}

#[test]
fun test_place_cancel_whitelisted_pool() {
    let mut test = begin(OWNER);
    let registry_id = setup_test(OWNER, &mut test);

    let pool_id = setup_pool_with_default_fees<SUI, DEEP>(
        OWNER,
        registry_id,
        true,
        false,
        &mut test,
    );
    let balance_manager_id_alice = create_acct_and_share_with_funds(
        ALICE,
        1000000 * constants::float_scaling(),
        &mut test,
    );

    let order_info_1 = place_limit_order<SUI, DEEP>(
        ALICE,
        pool_id,
        balance_manager_id_alice,
        1,
        constants::no_restriction(),
        constants::self_matching_allowed(),
        100 * constants::float_scaling(),
        1 * constants::float_scaling(),
        true,
        true,
        constants::max_u64(),
        &mut test,
    );

    cancel_order<SUI, DEEP>(
        ALICE,
        pool_id,
        balance_manager_id_alice,
        order_info_1.order_id(),
        &mut test,
    );

    let order_info_2 = place_limit_order<SUI, DEEP>(
        ALICE,
        pool_id,
        balance_manager_id_alice,
        1,
        constants::no_restriction(),
        constants::self_matching_allowed(),
        100 * constants::float_scaling(),
        1 * constants::float_scaling(),
        true,
        false,
        constants::max_u64(),
        &mut test,
    );

    cancel_order<SUI, DEEP>(
        ALICE,
        pool_id,
        balance_manager_id_alice,
        order_info_2.order_id(),
        &mut test,
    );

    let order_info_3 = place_limit_order<SUI, DEEP>(
        ALICE,
        pool_id,
        balance_manager_id_alice,
        1,
        constants::no_restriction(),
        constants::self_matching_allowed(),
        100 * constants::float_scaling(),
        1 * constants::float_scaling(),
        false,
        true,
        constants::max_u64(),
        &mut test,
    );

    cancel_order<SUI, DEEP>(
        ALICE,
        pool_id,
        balance_manager_id_alice,
        order_info_3.order_id(),
        &mut test,
    );

    let order_info_4 = place_limit_order<SUI, DEEP>(
        ALICE,
        pool_id,
        balance_manager_id_alice,
        1,
        constants::no_restriction(),
        constants::self_matching_allowed(),
        100 * constants::float_scaling(),
        1 * constants::float_scaling(),
        false,
        false,
        constants::max_u64(),
        &mut test,
    );

    cancel_order<SUI, DEEP>(
        ALICE,
        pool_id,
        balance_manager_id_alice,
        order_info_4.order_id(),
        &mut test,
    );

    end(test);
}

#[test]
fun test_get_orders() {
    let mut test = begin(OWNER);
    let registry_id = setup_test(OWNER, &mut test);
    let balance_manager_id_alice = create_acct_and_share_with_funds(
        ALICE,
        1000000 * constants::float_scaling(),
        &mut test,
    );
    let pool_id = setup_pool_with_default_fees_and_reference_pool<SUI, USDC, SUI, DEEP>(
        ALICE,
        registry_id,
        balance_manager_id_alice,
        &mut test,
    );
    let order_info_1 = place_limit_order<SUI, USDC>(
        ALICE,
        pool_id,
        balance_manager_id_alice,
        1,
        constants::no_restriction(),
        constants::self_matching_allowed(),
        100 * constants::float_scaling(),
        1 * constants::float_scaling(),
        true,
        true,
        constants::max_u64(),
        &mut test,
    );
    let order_info_2 = place_limit_order<SUI, USDC>(
        ALICE,
        pool_id,
        balance_manager_id_alice,
        2,
        constants::no_restriction(),
        constants::self_matching_allowed(),
        100 * constants::float_scaling(),
        1 * constants::float_scaling(),
        true,
        true,
        constants::max_u64(),
        &mut test,
    );
    let mut order_ids = vector[];
    order_ids.push_back(order_info_1.order_id());
    order_ids.push_back(order_info_2.order_id());

    let orders = get_orders(pool_id, order_ids, &mut test);
    let mut i = 0;
    while (i < 2) {
        let order = &orders[i];
        assert!(order.client_order_id() == i + 1, 0);
        assert!(order.balance_manager_id() == balance_manager_id_alice, 0);
        assert!(order.quantity() == 1 * constants::float_scaling(), 0);
        assert!(order.filled_quantity() == 0, 0);
        assert!(order.fee_is_deep() == true, 0);
        assert!(
            order.order_deep_price().deep_per_asset() ==
            constants::deep_multiplier(),
            0,
        );
        assert!(order.epoch() == 0, 0);
        assert!(order.status() == constants::live(), 0);
        assert!(order.expire_timestamp() == constants::max_u64(), 0);
        i = i + 1;
    };

    end(test);
}

fun get_order(pool_id: ID, order_id: u128, test: &mut Scenario): Order {
    test.next_tx(OWNER);
    {
        let pool = test.take_shared_by_id<Pool<SUI, USDC>>(pool_id);
        let order = pool.get_order(order_id);
        return_shared(pool);

        order
    }
}

fun get_orders(pool_id: ID, order_ids: vector<u128>, test: &mut Scenario): vector<Order> {
    test.next_tx(OWNER);
    {
        let pool = test.take_shared_by_id<Pool<SUI, USDC>>(pool_id);
        let orders = pool.get_orders(order_ids);
        return_shared(pool);

        orders
    }
}

fun test_create_pool(whitelisted_pool: bool, stable_pool: bool) {
    let mut test = begin(OWNER);
    let registry_id = setup_test(OWNER, &mut test);
    setup_pool_with_default_fees<SUI, DEEP>(
        OWNER,
        registry_id,
        whitelisted_pool,
        stable_pool,
        &mut test,
    );
    end(test);
}

#[test]
fun test_permissionless_pools() {
    let mut test = begin(OWNER);
    let registry_id = setup_test(OWNER, &mut test);

    // Only 1 coin is stable
    add_stablecoin<USDC>(OWNER, registry_id, &mut test);
    let pool_id_1 = setup_default_permissionless_pool<SUI, USDC>(
        OWNER,
        registry_id,
        &mut test,
    );
    check_pool_attributes<SUI, USDC>(pool_id_1, false, false, &mut test);

    let pool_id_2 = setup_default_permissionless_pool<USDT, USDC>(
        OWNER,
        registry_id,
        &mut test,
    );
    check_pool_attributes<USDT, USDC>(pool_id_2, false, false, &mut test);

    // Now both coins are stable
    unregister_pool<USDT, USDC>(pool_id_2, registry_id, &mut test);
    add_stablecoin<USDT>(OWNER, registry_id, &mut test);
    let pool_id_2 = setup_default_permissionless_pool<USDT, USDC>(
        OWNER,
        registry_id,
        &mut test,
    );
    check_pool_attributes<USDT, USDC>(pool_id_2, false, true, &mut test);

    let pool_id_3 = setup_default_permissionless_pool<DEEP, USDC>(
        OWNER,
        registry_id,
        &mut test,
    );
    check_pool_attributes<DEEP, USDC>(pool_id_3, false, false, &mut test);

    end(test);
}

#[test, expected_failure(abort_code = ::deepbook::registry::ECoinAlreadyWhitelisted)]
fun test_adding_duplicate_stablecoin_e() {
    let mut test = begin(OWNER);
    let registry_id = setup_test(OWNER, &mut test);

    add_stablecoin<USDC>(OWNER, registry_id, &mut test);
    add_stablecoin<USDC>(OWNER, registry_id, &mut test);

    end(test);
}

#[test, expected_failure(abort_code = ::deepbook::registry::ECoinNotWhitelisted)]
fun test_removing_not_whitelisted_stablecoin_e() {
    let mut test = begin(OWNER);
    let registry_id = setup_test(OWNER, &mut test);

    add_stablecoin<USDC>(OWNER, registry_id, &mut test);
    remove_stablecoin<USDT>(OWNER, registry_id, &mut test);

    end(test);
}

fun check_pool_attributes<BaseAsset, QuoteAsset>(
    pool_id: ID,
    whitelisted: bool,
    stable: bool,
    test: &mut Scenario,
) {
    test.next_tx(OWNER);
    {
        let pool = test.take_shared_by_id<Pool<BaseAsset, QuoteAsset>>(pool_id);
        assert!(pool.whitelisted() == whitelisted, 0);
        assert!(pool.stable_pool() == stable, 0);
        return_shared(pool);
    }
}

#[test_only]
public(package) fun setup_test(owner: address, test: &mut Scenario): ID {
    test.next_tx(owner);
    share_clock(test);
    share_registry_for_testing(test)
}

#[test_only]
public(package) fun add_deep_price_point<
    BaseAsset,
    QuoteAsset,
    ReferenceBaseAsset,
    ReferenceQuoteAsset,
>(
    sender: address,
    target_pool_id: ID,
    reference_pool_id: ID,
    test: &mut Scenario,
) {
    test.next_tx(sender);
    {
        let mut target_pool = test.take_shared_by_id<Pool<BaseAsset, QuoteAsset>>(target_pool_id);
        let reference_pool = test.take_shared_by_id<Pool<ReferenceBaseAsset, ReferenceQuoteAsset>>(
            reference_pool_id,
        );
        let clock = test.take_shared<Clock>();
        pool::add_deep_price_point<BaseAsset, QuoteAsset, ReferenceBaseAsset, ReferenceQuoteAsset>(
            &mut target_pool,
            &reference_pool,
            &clock,
        );
        return_shared(target_pool);
        return_shared(reference_pool);
        return_shared(clock);
    }
}

#[test_only]
/// Set up a reference pool where Deep per base is 100
public(package) fun setup_reference_pool<BaseAsset, QuoteAsset>(
    sender: address,
    registry_id: ID,
    balance_manager_id: ID,
    deep_multiplier: u64,
    test: &mut Scenario,
): ID {
    let reference_pool_id = setup_pool_with_default_fees<BaseAsset, QuoteAsset>(
        sender,
        registry_id,
        true,
        false,
        test,
    );

    place_limit_order<BaseAsset, QuoteAsset>(
        sender,
        reference_pool_id,
        balance_manager_id,
        1,
        constants::no_restriction(),
        constants::self_matching_allowed(),
        deep_multiplier - 80 * constants::float_scaling(),
        1 * constants::float_scaling(),
        true,
        true,
        constants::max_u64(),
        test,
    );

    place_limit_order<BaseAsset, QuoteAsset>(
        sender,
        reference_pool_id,
        balance_manager_id,
        1,
        constants::no_restriction(),
        constants::self_matching_allowed(),
        deep_multiplier + 80 * constants::float_scaling(),
        1 * constants::float_scaling(),
        false,
        true,
        constants::max_u64(),
        test,
    );

    reference_pool_id
}

#[test_only]
/// Set up a reference pool where Deep per base is 100
public(package) fun setup_reference_pool_deep_as_base<BaseAsset, QuoteAsset>(
    sender: address,
    registry_id: ID,
    balance_manager_id: ID,
    deep_multiplier: u64,
    test: &mut Scenario,
): ID {
    let reference_pool_id = setup_pool_with_default_fees<BaseAsset, QuoteAsset>(
        sender,
        registry_id,
        true,
        false,
        test,
    );

    place_limit_order<BaseAsset, QuoteAsset>(
        sender,
        reference_pool_id,
        balance_manager_id,
        1,
        constants::no_restriction(),
        constants::self_matching_allowed(),
        math::div(constants::float_scaling(), deep_multiplier) - 10_000,
        1 * constants::float_scaling(),
        true,
        true,
        constants::max_u64(),
        test,
    );

    place_limit_order<BaseAsset, QuoteAsset>(
        sender,
        reference_pool_id,
        balance_manager_id,
        1,
        constants::no_restriction(),
        constants::self_matching_allowed(),
        math::div(constants::float_scaling(), deep_multiplier) + 10_000,
        1 * constants::float_scaling(),
        false,
        true,
        constants::max_u64(),
        test,
    );

    reference_pool_id
}

#[test_only]
public(package) fun setup_pool_with_default_fees<BaseAsset, QuoteAsset>(
    sender: address,
    registry_id: ID,
    whitelisted_pool: bool,
    stable_pool: bool,
    test: &mut Scenario,
): ID {
    setup_pool<BaseAsset, QuoteAsset>(
        sender,
        constants::tick_size(), // tick size
        constants::lot_size(), // lot size
        constants::min_size(), // min size
        registry_id,
        whitelisted_pool,
        stable_pool,
        test,
    )
}

#[test_only]
public(package) fun setup_pool_with_stable_fees<BaseAsset, QuoteAsset>(
    sender: address,
    registry_id: ID,
    whitelisted_pool: bool,
    test: &mut Scenario,
): ID {
    let stable_pool = true;
    setup_pool<BaseAsset, QuoteAsset>(
        sender,
        constants::tick_size(), // tick size
        constants::lot_size(), // lot size
        constants::min_size(), // min size
        registry_id,
        whitelisted_pool,
        stable_pool,
        test,
    )
}

#[test_only]
public(package) fun setup_pool_with_default_fees_return_fee<BaseAsset, QuoteAsset>(
    sender: address,
    registry_id: ID,
    whitelisted_pool: bool,
    test: &mut Scenario,
): ID {
    let stable_pool = false;
    let pool_id = setup_pool<BaseAsset, QuoteAsset>(
        sender,
        constants::tick_size(), // tick size
        constants::lot_size(), // lot size
        constants::min_size(), // min size
        registry_id,
        whitelisted_pool,
        stable_pool,
        test,
    );

    pool_id
}

#[test_only]
public(package) fun setup_default_permissionless_pool<BaseAsset, QuoteAsset>(
    sender: address,
    registry_id: ID,
    test: &mut Scenario,
): ID {
    setup_permissionless_pool<BaseAsset, QuoteAsset>(
        sender,
        constants::tick_size(), // tick size
        constants::lot_size(), // lot size
        constants::min_size(), // min size
        registry_id,
        test,
    )
}

#[test_only]
/// Place a limit order
public(package) fun place_limit_order<BaseAsset, QuoteAsset>(
    trader: address,
    pool_id: ID,
    balance_manager_id: ID,
    client_order_id: u64,
    order_type: u8,
    self_matching_option: u8,
    price: u64,
    quantity: u64,
    is_bid: bool,
    pay_with_deep: bool,
    expire_timestamp: u64,
    test: &mut Scenario,
): OrderInfo {
    test.next_tx(trader);
    {
        let mut pool = test.take_shared_by_id<Pool<BaseAsset, QuoteAsset>>(
            pool_id,
        );
        let clock = test.take_shared<Clock>();
        let mut balance_manager = test.take_shared_by_id<BalanceManager>(
            balance_manager_id,
        );
        let trade_proof;

        let is_owner = balance_manager.owner() == trader;
        if (is_owner) {
            trade_proof = balance_manager.generate_proof_as_owner(test.ctx());
        } else {
            let trade_cap = test.take_from_sender<TradeCap>();
            trade_proof =
                balance_manager.generate_proof_as_trader(
                    &trade_cap,
                    test.ctx(),
                );
            test.return_to_sender(trade_cap);
        };

        // Place order in pool
        let order_info = pool.place_limit_order<BaseAsset, QuoteAsset>(
            &mut balance_manager,
            &trade_proof,
            client_order_id,
            order_type,
            self_matching_option,
            price,
            quantity,
            is_bid,
            pay_with_deep,
            expire_timestamp,
            &clock,
            test.ctx(),
        );
        return_shared(pool);
        return_shared(clock);
        return_shared(balance_manager);

        order_info
    }
}

#[test_only]
/// Place an order
public(package) fun place_market_order<BaseAsset, QuoteAsset>(
    trader: address,
    pool_id: ID,
    balance_manager_id: ID,
    client_order_id: u64,
    self_matching_option: u8,
    quantity: u64,
    is_bid: bool,
    pay_with_deep: bool,
    test: &mut Scenario,
): OrderInfo {
    test.next_tx(trader);
    {
        let mut pool = test.take_shared_by_id<Pool<BaseAsset, QuoteAsset>>(
            pool_id,
        );
        let clock = test.take_shared<Clock>();
        let mut balance_manager = test.take_shared_by_id<BalanceManager>(
            balance_manager_id,
        );
        let trade_proof = balance_manager.generate_proof_as_owner(test.ctx());

        // Place order in pool
        let order_info = pool.place_market_order<BaseAsset, QuoteAsset>(
            &mut balance_manager,
            &trade_proof,
            client_order_id,
            self_matching_option,
            quantity,
            is_bid,
            pay_with_deep,
            &clock,
            test.ctx(),
        );
        return_shared(pool);
        return_shared(clock);
        return_shared(balance_manager);

        order_info
    }
}

#[test_only]
/// Cancel an order
public(package) fun cancel_order<BaseAsset, QuoteAsset>(
    sender: address,
    pool_id: ID,
    balance_manager_id: ID,
    order_id: u128,
    test: &mut Scenario,
) {
    test.next_tx(sender);
    {
        let mut pool = test.take_shared_by_id<Pool<BaseAsset, QuoteAsset>>(
            pool_id,
        );
        let clock = test.take_shared<Clock>();
        let mut balance_manager = test.take_shared_by_id<BalanceManager>(
            balance_manager_id,
        );
        let trade_proof = balance_manager.generate_proof_as_owner(test.ctx());

        pool.cancel_order<BaseAsset, QuoteAsset>(
            &mut balance_manager,
            &trade_proof,
            order_id,
            &clock,
            test.ctx(),
        );
        return_shared(pool);
        return_shared(clock);
        return_shared(balance_manager);
    }
}

#[test_only]
/// Set the time in the global clock to 1_000_000 + current_time
public(package) fun set_time(current_time: u64, test: &mut Scenario) {
    test.next_tx(OWNER);
    {
        let mut clock = test.take_shared<Clock>();
        clock.set_for_testing(current_time + 1_000_000);
        return_shared(clock);
    };
}

#[test_only]
public(package) fun modify_order<BaseAsset, QuoteAsset>(
    sender: address,
    pool_id: ID,
    balance_manager_id: ID,
    order_id: u128,
    new_quantity: u64,
    test: &mut Scenario,
) {
    test.next_tx(sender);
    {
        let mut pool = test.take_shared_by_id<Pool<BaseAsset, QuoteAsset>>(
            pool_id,
        );
        let mut balance_manager = test.take_shared_by_id<BalanceManager>(
            balance_manager_id,
        );
        let trade_cap = test.take_from_sender<TradeCap>();
        let trade_proof = balance_manager.generate_proof_as_trader(
            &trade_cap,
            test.ctx(),
        );
        let clock = test.take_shared<Clock>();

        pool.modify_order<BaseAsset, QuoteAsset>(
            &mut balance_manager,
            &trade_proof,
            order_id,
            new_quantity,
            &clock,
            test.ctx(),
        );

        test.return_to_sender(trade_cap);
        return_shared(pool);
        return_shared(balance_manager);
        return_shared(clock);
    }
}

fun test_place_order_edge_price(quantity: u64, price: u64) {
    let mut test = begin(OWNER);
    let registry_id = setup_test(OWNER, &mut test);
    let balance_manager_id_alice = create_acct_and_share_with_funds(
        ALICE,
        1000000 * constants::float_scaling(),
        &mut test,
    );
    let pool_id = setup_pool_with_default_fees_and_reference_pool<SUI, USDC, SUI, DEEP>(
        ALICE,
        registry_id,
        balance_manager_id_alice,
        &mut test,
    );

    let client_order_id = 1;
    let expire_timestamp = constants::max_u64();
    let pay_with_deep = true;

    place_limit_order<SUI, USDC>(
        ALICE,
        pool_id,
        balance_manager_id_alice,
        client_order_id,
        constants::no_restriction(),
        constants::self_matching_allowed(),
        price,
        quantity,
        false,
        pay_with_deep,
        expire_timestamp,
        &mut test,
    );

    end(test);
}

#[test_only]
/// Get the time in the global clock
public(package) fun get_time(test: &mut Scenario): u64 {
    test.next_tx(OWNER);
    {
        let clock = test.take_shared<Clock>();
        let time = clock.timestamp_ms();
        return_shared(clock);

        time
    }
}

#[test_only]
public(package) fun validate_open_orders<BaseAsset, QuoteAsset>(
    sender: address,
    pool_id: ID,
    balance_manager_id: ID,
    expected_open_orders: u64,
    test: &mut Scenario,
) {
    test.next_tx(sender);
    {
        let pool = test.take_shared_by_id<Pool<BaseAsset, QuoteAsset>>(pool_id);
        let balance_manager = test.take_shared_by_id<BalanceManager>(
            balance_manager_id,
        );

        assert!(
            pool.account_open_orders(&balance_manager).length() ==
            expected_open_orders,
            1,
        );

        return_shared(pool);
        return_shared(balance_manager);
    }
}

/// Alice places a worse order
/// Alice places 3 bid/ask orders with at price 1
/// Alice matches the order with an ask/bid order at price 1
/// The first order should be matched because of queue priority
/// Process is repeated with a third order
fun test_queue_priority(is_bid: bool) {
    let mut test = begin(OWNER);
    let registry_id = setup_test(OWNER, &mut test);
    let balance_manager_id_alice = create_acct_and_share_with_funds(
        ALICE,
        1000000 * constants::float_scaling(),
        &mut test,
    );
    let pool_id = setup_pool_with_default_fees_and_reference_pool<SUI, USDC, SUI, DEEP>(
        ALICE,
        registry_id,
        balance_manager_id_alice,
        &mut test,
    );

    let client_order_id = 1;
    let price = 2 * constants::float_scaling();
    let worse_price = if (is_bid) {
        1 * constants::float_scaling()
    } else {
        3 * constants::float_scaling()
    };
    let quantity = 1 * constants::float_scaling();
    let expire_timestamp = constants::max_u64();
    let pay_with_deep = true;

    let order_info_worse = place_limit_order<SUI, USDC>(
        ALICE,
        pool_id,
        balance_manager_id_alice,
        client_order_id,
        constants::no_restriction(),
        constants::self_matching_allowed(),
        worse_price,
        quantity,
        is_bid,
        pay_with_deep,
        expire_timestamp,
        &mut test,
    );

    place_limit_order<SUI, USDC>(
        ALICE,
        pool_id,
        balance_manager_id_alice,
        client_order_id,
        constants::no_restriction(),
        constants::self_matching_allowed(),
        price,
        quantity,
        is_bid,
        pay_with_deep,
        expire_timestamp,
        &mut test,
    );

    let order_info_2 = place_limit_order<SUI, USDC>(
        ALICE,
        pool_id,
        balance_manager_id_alice,
        client_order_id,
        constants::no_restriction(),
        constants::self_matching_allowed(),
        price,
        quantity,
        is_bid,
        pay_with_deep,
        expire_timestamp,
        &mut test,
    );

    let order_info_3 = place_limit_order<SUI, USDC>(
        ALICE,
        pool_id,
        balance_manager_id_alice,
        client_order_id,
        constants::no_restriction(),
        constants::self_matching_allowed(),
        price,
        quantity,
        is_bid,
        pay_with_deep,
        expire_timestamp,
        &mut test,
    );

    // Alice places limit order at price 1 for matching
    place_limit_order<SUI, USDC>(
        ALICE,
        pool_id,
        balance_manager_id_alice,
        client_order_id,
        constants::no_restriction(),
        constants::self_matching_allowed(),
        price,
        quantity,
        !is_bid,
        pay_with_deep,
        expire_timestamp,
        &mut test,
    );

    borrow_and_verify_book_order<SUI, USDC>(
        pool_id,
        order_info_2.order_id(),
        is_bid,
        client_order_id,
        quantity,
        0,
        order_info_2.order_deep_price().deep_per_asset(),
        test.ctx().epoch(),
        constants::live(),
        expire_timestamp,
        &mut test,
    );

    borrow_and_verify_book_order<SUI, USDC>(
        pool_id,
        order_info_3.order_id(),
        is_bid,
        client_order_id,
        quantity,
        0,
        order_info_3.order_deep_price().deep_per_asset(),
        test.ctx().epoch(),
        constants::live(),
        expire_timestamp,
        &mut test,
    );

    borrow_and_verify_book_order<SUI, USDC>(
        pool_id,
        order_info_worse.order_id(),
        is_bid,
        client_order_id,
        quantity,
        0,
        order_info_3.order_deep_price().deep_per_asset(),
        test.ctx().epoch(),
        constants::live(),
        expire_timestamp,
        &mut test,
    );

    // Alice places limit order at price 1 for matching
    place_limit_order<SUI, USDC>(
        ALICE,
        pool_id,
        balance_manager_id_alice,
        client_order_id,
        constants::no_restriction(),
        constants::self_matching_allowed(),
        price,
        quantity,
        !is_bid,
        pay_with_deep,
        expire_timestamp,
        &mut test,
    );

    borrow_and_verify_book_order<SUI, USDC>(
        pool_id,
        order_info_3.order_id(),
        is_bid,
        client_order_id,
        quantity,
        0,
        order_info_3.order_deep_price().deep_per_asset(),
        test.ctx().epoch(),
        constants::live(),
        expire_timestamp,
        &mut test,
    );

    borrow_and_verify_book_order<SUI, USDC>(
        pool_id,
        order_info_worse.order_id(),
        is_bid,
        client_order_id,
        quantity,
        0,
        order_info_worse.order_deep_price().deep_per_asset(),
        test.ctx().epoch(),
        constants::live(),
        expire_timestamp,
        &mut test,
    );

    end(test);
}

fun test_modify_order(
    original_quantity: u64,
    new_quantity: u64,
    filled_quantity: u64,
    is_bid: bool,
    pay_with_deep: bool,
) {
    let mut test = begin(OWNER);
    let registry_id = setup_test(OWNER, &mut test);
    let balance_manager_id_alice = create_acct_and_share_with_funds(
        ALICE,
        1000000 * constants::float_scaling(),
        &mut test,
    );
    let pool_id = setup_pool_with_default_fees_and_reference_pool<SUI, USDC, SUI, DEEP>(
        ALICE,
        registry_id,
        balance_manager_id_alice,
        &mut test,
    );

    let client_order_id = 1;
    let base_price = 2 * constants::float_scaling();
    let expire_timestamp = constants::max_u64();

    let order_info = place_limit_order<SUI, USDC>(
        ALICE,
        pool_id,
        balance_manager_id_alice,
        client_order_id,
        constants::no_restriction(),
        constants::self_matching_allowed(),
        base_price,
        original_quantity,
        is_bid,
        pay_with_deep,
        expire_timestamp,
        &mut test,
    );

    if (filled_quantity > 0) {
        place_limit_order<SUI, USDC>(
            ALICE,
            pool_id,
            balance_manager_id_alice,
            client_order_id,
            constants::no_restriction(),
            constants::self_matching_allowed(),
            base_price,
            filled_quantity,
            !is_bid,
            pay_with_deep,
            expire_timestamp,
            &mut test,
        );
    };

    modify_order<SUI, USDC>(
        ALICE,
        pool_id,
        balance_manager_id_alice,
        order_info.order_id(),
        new_quantity,
        &mut test,
    );

    borrow_and_verify_book_order<SUI, USDC>(
        pool_id,
        order_info.order_id(),
        is_bid,
        client_order_id,
        new_quantity,
        0,
        order_info.order_deep_price().deep_per_asset(),
        test.ctx().epoch(),
        constants::live(),
        expire_timestamp,
        &mut test,
    );

    end(test);
}

fun test_order_limit(is_bid: bool) {
    let mut test = begin(OWNER);
    let registry_id = setup_test(OWNER, &mut test);
    let balance_manager_id_alice = create_acct_and_share_with_funds(
        ALICE,
        1000000 * constants::float_scaling(),
        &mut test,
    );
    let balance_manager_id_bob = create_acct_and_share_with_funds(
        BOB,
        1000000 * constants::float_scaling(),
        &mut test,
    );
    let pool_id = setup_pool_with_default_fees_and_reference_pool<SUI, USDC, SUI, DEEP>(
        ALICE,
        registry_id,
        balance_manager_id_alice,
        &mut test,
    );

    let client_order_id = 1;
    let price = 2 * constants::float_scaling();
    let quantity = 1 * constants::float_scaling();
    let expire_timestamp = constants::max_u64();
    let pay_with_deep = true;
    let mut num_orders = 150;

    while (num_orders > 100) {
        place_limit_order<SUI, USDC>(
            ALICE,
            pool_id,
            balance_manager_id_alice,
            client_order_id,
            constants::no_restriction(),
            constants::self_matching_allowed(),
            price,
            quantity,
            is_bid,
            pay_with_deep,
            expire_timestamp,
            &mut test,
        );

        num_orders = num_orders - 1;
    };

    while (num_orders > 0) {
        place_limit_order<SUI, USDC>(
            BOB,
            pool_id,
            balance_manager_id_bob,
            client_order_id,
            constants::no_restriction(),
            constants::self_matching_allowed(),
            price,
            quantity,
            is_bid,
            pay_with_deep,
            expire_timestamp,
            &mut test,
        );

        num_orders = num_orders - 1u64;
    };

    let match_quantity = 1000 * constants::float_scaling();

    if (is_bid) {
        let (base, quote, deep) = get_quote_quantity_out<SUI, USDC>(
            pool_id,
            match_quantity,
            &mut test,
        );
        assert!(base == 900 * constants::float_scaling(), 0);
        assert!(quote == 200 * constants::float_scaling(), 0);
        assert!(
            deep == math::mul(constants::taker_fee(), math::mul(100 * constants::float_scaling(), constants::deep_multiplier())),
            0,
        );
    } else {
        let (base, quote, deep) = get_base_quantity_out<SUI, USDC>(
            pool_id,
            math::mul(match_quantity, price),
            &mut test,
        );
        assert!(base == 100 * constants::float_scaling(), 0);
        assert!(quote == 1800 * constants::float_scaling(), 0);
        assert!(
            deep == math::mul(constants::taker_fee(), math::mul(100 * constants::float_scaling(), constants::deep_multiplier())),
            0,
        );
    };

    let order_info = place_limit_order<SUI, USDC>(
        ALICE,
        pool_id,
        balance_manager_id_alice,
        client_order_id,
        constants::no_restriction(),
        constants::self_matching_allowed(),
        price,
        match_quantity,
        !is_bid,
        pay_with_deep,
        expire_timestamp,
        &mut test,
    );

    let expected_status = constants::partially_filled();
    let expected_cumulative_quote_quantity = constants::max_fills() * price;
    let paid_fees =
        constants::max_fills() *
        math::mul(constants::taker_fee(), constants::deep_multiplier());

    verify_order_info(
        &order_info,
        client_order_id,
        price,
        match_quantity,
        constants::max_fills() * quantity,
        expected_cumulative_quote_quantity,
        paid_fees,
        true,
        expected_status,
        expire_timestamp,
    );

    if (is_bid) {
        let (base, quote, deep) = get_quote_quantity_out<SUI, USDC>(
            pool_id,
            match_quantity,
            &mut test,
        );
        assert!(base == 950 * constants::float_scaling(), 0);
        assert!(quote == 100 * constants::float_scaling(), 0);
        assert!(
            deep == math::mul(constants::taker_fee(), math::mul(50 * constants::float_scaling(), constants::deep_multiplier())),
            0,
        );
    } else {
        let (base, quote, deep) = get_base_quantity_out<SUI, USDC>(
            pool_id,
            math::mul(match_quantity, price),
            &mut test,
        );
        assert!(base == 50 * constants::float_scaling(), 0);
        assert!(quote == 1900 * constants::float_scaling(), 0);
        assert!(
            deep == math::mul(constants::taker_fee(), math::mul(50 * constants::float_scaling(), constants::deep_multiplier())),
            0,
        );
    };

    // Place second order, should match with the 50 remaining orders.
    let order_info = place_limit_order<SUI, USDC>(
        ALICE,
        pool_id,
        balance_manager_id_alice,
        client_order_id,
        constants::no_restriction(),
        constants::self_matching_allowed(),
        price,
        match_quantity,
        !is_bid,
        pay_with_deep,
        expire_timestamp,
        &mut test,
    );

    let expected_status = constants::partially_filled();
    let expected_cumulative_quote_quantity = 50 * price;
    let expected_executed_quantity = 50 * quantity;
    let paid_fees = 50 * math::mul(constants::taker_fee(), constants::deep_multiplier());

    verify_order_info(
        &order_info,
        client_order_id,
        price,
        match_quantity,
        expected_executed_quantity,
        expected_cumulative_quote_quantity,
        paid_fees,
        true,
        expected_status,
        expire_timestamp,
    );

    end(test);
}

fun test_get_pool_id_by_asset() {
    let mut test = begin(OWNER);
    let registry_id = setup_test(OWNER, &mut test);
    let pool_id_1 = setup_pool_with_default_fees<SUI, USDC>(
        OWNER,
        registry_id,
        false,
        false,
        &mut test,
    );
    let pool_id_2 = setup_pool_with_default_fees<SPAM, USDC>(
        OWNER,
        registry_id,
        false,
        false,
        &mut test,
    );
    let pool_id_1_returned = get_pool_id_by_asset<SUI, USDC>(
        registry_id,
        &mut test,
    );
    let pool_id_2_returned = get_pool_id_by_asset<SPAM, USDC>(
        registry_id,
        &mut test,
    );

    assert!(pool_id_1 == pool_id_1_returned, constants::e_incorrect_pool_id());
    assert!(pool_id_2 == pool_id_2_returned, constants::e_incorrect_pool_id());
    end(test);
}

fun get_pool_id_by_asset<BaseAsset, QuoteAsset>(registry_id: ID, test: &mut Scenario): ID {
    test.next_tx(OWNER);
    {
        let registry = test.take_shared_by_id<Registry>(registry_id);
        let pool_id = pool::get_pool_id_by_asset<BaseAsset, QuoteAsset>(
            &registry,
        );
        return_shared(registry);

        pool_id
    }
}

fun test_unregister_pool(unregister: bool) {
    let mut test = begin(OWNER);
    let registry_id = setup_test(OWNER, &mut test);
    let pool_id = setup_pool_with_default_fees<SUI, USDC>(
        OWNER,
        registry_id,
        false,
        false,
        &mut test,
    );
    if (unregister) {
        unregister_pool<SUI, USDC>(pool_id, registry_id, &mut test);
    };
    setup_pool_with_default_fees<SUI, USDC>(
        OWNER,
        registry_id,
        false,
        false,
        &mut test,
    );

    end(test);
}

public(package) fun unregister_pool<BaseAsset, QuoteAsset>(
    pool_id: ID,
    registry_id: ID,
    test: &mut Scenario,
) {
    test.next_tx(OWNER);
    {
        let admin_cap = registry::get_admin_cap_for_testing(test.ctx());
        let mut pool = test.take_shared_by_id<Pool<BaseAsset, QuoteAsset>>(
            pool_id,
        );
        let mut registry = test.take_shared_by_id<Registry>(registry_id);

        pool::unregister_pool_admin<BaseAsset, QuoteAsset>(
            &mut pool,
            &mut registry,
            &admin_cap,
        );
        return_shared(pool);
        return_shared(registry);
        destroy(admin_cap);
    }
}

public(package) fun setup_pool_with_default_fees_and_reference_pool<
    BaseAsset,
    QuoteAsset,
    ReferenceBaseAsset,
    ReferenceQuoteAsset,
>(
    sender: address,
    registry_id: ID,
    balance_manager_id: ID,
    test: &mut Scenario,
): ID {
    let target_pool_id = setup_pool_with_default_fees<BaseAsset, QuoteAsset>(
        OWNER,
        registry_id,
        false,
        false,
        test,
    );
    let reference_pool_id = setup_reference_pool<ReferenceBaseAsset, ReferenceQuoteAsset>(
        sender,
        registry_id,
        balance_manager_id,
        constants::deep_multiplier(),
        test,
    );
    set_time(0, test);
    add_deep_price_point<BaseAsset, QuoteAsset, ReferenceBaseAsset, ReferenceQuoteAsset>(
        sender,
        target_pool_id,
        reference_pool_id,
        test,
    );

    target_pool_id
}

fun setup_pool_with_default_fees_and_reference_pool_unregistered<
    BaseAsset,
    QuoteAsset,
    ReferenceBaseAsset,
    ReferenceQuoteAsset,
>(
    sender: address,
    registry_id: ID,
    balance_manager_id: ID,
    test: &mut Scenario,
): ID {
    let target_pool_id = setup_pool_with_default_fees<BaseAsset, QuoteAsset>(
        OWNER,
        registry_id,
        false,
        false,
        test,
    );
    let reference_pool_id = setup_reference_pool<ReferenceBaseAsset, ReferenceQuoteAsset>(
        sender,
        registry_id,
        balance_manager_id,
        constants::deep_multiplier(),
        test,
    );
    set_time(0, test);
    unregister_pool<ReferenceBaseAsset, ReferenceQuoteAsset>(
        reference_pool_id,
        registry_id,
        test,
    );
    add_deep_price_point<BaseAsset, QuoteAsset, ReferenceBaseAsset, ReferenceQuoteAsset>(
        sender,
        target_pool_id,
        reference_pool_id,
        test,
    );

    target_pool_id
}

fun setup_pool_with_stable_fees_and_reference_pool<
    BaseAsset,
    QuoteAsset,
    ReferenceBaseAsset,
    ReferenceQuoteAsset,
>(
    sender: address,
    registry_id: ID,
    balance_manager_id: ID,
    test: &mut Scenario,
): ID {
    let target_pool_id = setup_pool_with_stable_fees<BaseAsset, QuoteAsset>(
        OWNER,
        registry_id,
        false,
        test,
    );
    let reference_pool_id = setup_reference_pool<ReferenceBaseAsset, ReferenceQuoteAsset>(
        sender,
        registry_id,
        balance_manager_id,
        constants::deep_multiplier(),
        test,
    );
    set_time(0, test);
    add_deep_price_point<BaseAsset, QuoteAsset, ReferenceBaseAsset, ReferenceQuoteAsset>(
        sender,
        target_pool_id,
        reference_pool_id,
        test,
    );

    target_pool_id
}

/// Alice places a bid order, Bob places a swap_exact_amount order
/// Make sure the assets returned to Bob are correct
/// When swap is not fully filled, assets are returned correctly
/// Make sure expired orders are skipped over
fun test_swap_exact_not_fully_filled(
    is_bid: bool,
    low_quantity: bool,
    minimum_enforced: bool,
    partially_filled_maker: bool,
    with_manager: bool,
) {
    let mut test = begin(OWNER);
    let registry_id = setup_test(OWNER, &mut test);
    let balance_manager_id_alice = create_acct_and_share_with_funds(
        ALICE,
        1000000 * constants::float_scaling(),
        &mut test,
    );
    let pool_id = setup_pool_with_default_fees_and_reference_pool<SUI, USDC, SUI, DEEP>(
        ALICE,
        registry_id,
        balance_manager_id_alice,
        &mut test,
    );

    let alice_client_order_id = 1;
    let alice_price = 3 * constants::float_scaling();
    let alice_quantity = 2 * constants::float_scaling();
    let expired_price = if (is_bid) {
        3 * constants::float_scaling()
    } else {
        1 * constants::float_scaling()
    };
    let expire_timestamp = constants::max_u64();
    let expire_timestamp_e = get_time(&mut test) + 100;
    let pay_with_deep = true;
    let residual = constants::lot_size() - 1;

    place_limit_order<SUI, USDC>(
        ALICE,
        pool_id,
        balance_manager_id_alice,
        alice_client_order_id,
        constants::no_restriction(),
        constants::self_matching_allowed(),
        alice_price,
        alice_quantity,
        is_bid,
        pay_with_deep,
        expire_timestamp,
        &mut test,
    );

    if (partially_filled_maker) {
        place_limit_order<SUI, USDC>(
            ALICE,
            pool_id,
            balance_manager_id_alice,
            alice_client_order_id,
            constants::no_restriction(),
            constants::self_matching_allowed(),
            alice_price,
            alice_quantity / 2,
            !is_bid,
            pay_with_deep,
            expire_timestamp,
            &mut test,
        );
    };

    place_limit_order<SUI, USDC>(
        ALICE,
        pool_id,
        balance_manager_id_alice,
        alice_client_order_id,
        constants::no_restriction(),
        constants::self_matching_allowed(),
        expired_price,
        alice_quantity,
        is_bid,
        pay_with_deep,
        expire_timestamp_e,
        &mut test,
    );

    set_time(200, &mut test);

    let base_in = if (is_bid) {
        if (low_quantity) {
            100
        } else {
            4 * constants::float_scaling() + residual
        }
    } else {
        0
    };
    let quote_in = if (is_bid) {
        0
    } else {
        if (low_quantity) {
            100
        } else {
            8 * constants::float_scaling() + residual
        }
    };
    let deep_in =
        2 * math::mul(constants::deep_multiplier(), constants::taker_fee()) +
        residual;

    let (base, quote, deep_required) = get_quantity_out<SUI, USDC>(
        pool_id,
        base_in,
        quote_in,
        &mut test,
    );

    let (base_2, quote_2, deep_required_2) = if (is_bid) {
        get_quote_quantity_out<SUI, USDC>(
            pool_id,
            base_in,
            &mut test,
        )
    } else {
        get_base_quantity_out<SUI, USDC>(
            pool_id,
            quote_in,
            &mut test,
        )
    };
    let min_out = if (minimum_enforced) {
        10 * constants::float_scaling()
    } else {
        0
    };

    let initial_bob_balances = 1000000 * constants::float_scaling();
    let bob_balance_manager_id = create_acct_and_share_with_funds(
        BOB,
        initial_bob_balances,
        &mut test,
    );
    create_caps(BOB, bob_balance_manager_id, &mut test);
    let bob_sui_balance_before = asset_balance<SUI>(BOB, bob_balance_manager_id, &mut test);
    let bob_usdc_balance_before = asset_balance<USDC>(BOB, bob_balance_manager_id, &mut test);
    let bob_deep_balance_before = asset_balance<DEEP>(BOB, bob_balance_manager_id, &mut test);

    let (base_out, quote_out, deep_out) = if (is_bid) {
        if (with_manager) {
            let deep_out = coin::zero(test.ctx());
            let (base_out, quote_out) = place_exact_base_for_quote_with_manager<SUI, USDC>(
                pool_id,
                BOB,
                bob_balance_manager_id,
                base_in,
                min_out,
                &mut test,
            );

            (base_out, quote_out, deep_out)
        } else {
            place_swap_exact_base_for_quote<SUI, USDC>(
                pool_id,
                BOB,
                base_in,
                deep_in,
                min_out,
                &mut test,
            )
        }
    } else {
        if (with_manager) {
            let deep_out = coin::zero(test.ctx());
            let (base_out, quote_out) = place_exact_quote_for_base_with_manager<SUI, USDC>(
                pool_id,
                BOB,
                bob_balance_manager_id,
                quote_in,
                min_out,
                &mut test,
            );

            (base_out, quote_out, deep_out)
        } else {
            place_swap_exact_quote_for_base<SUI, USDC>(
                pool_id,
                BOB,
                quote_in,
                deep_in,
                min_out,
                &mut test,
            )
        }
    };
    let bob_sui_balance_after = asset_balance<SUI>(BOB, bob_balance_manager_id, &mut test);
    let bob_usdc_balance_after = asset_balance<USDC>(BOB, bob_balance_manager_id, &mut test);
    let bob_deep_balance_after = asset_balance<DEEP>(BOB, bob_balance_manager_id, &mut test);

    if (low_quantity) {
        assert!(base_out.value() == base_in);
        assert!(quote_out.value() == quote_in);
        if (with_manager) {
            assert!(deep_out.value() == 0);
            assert!(bob_sui_balance_before == bob_sui_balance_after);
            assert!(bob_usdc_balance_before == bob_usdc_balance_after);
            assert!(bob_deep_balance_before == bob_deep_balance_after);
        } else {
            assert!(deep_out.value() == deep_in);
        };
    } else if (!partially_filled_maker) {
        if (is_bid) {
            assert!(
                base_out.value() == 2 * constants::float_scaling() + residual,
                constants::e_order_info_mismatch(),
            );
            assert!(
                quote_out.value() == 6 * constants::float_scaling(),
                constants::e_order_info_mismatch(),
            );
        } else {
            assert!(
                base_out.value() == 2 * constants::float_scaling(),
                constants::e_order_info_mismatch(),
            );
            assert!(
                quote_out.value() == 2 * constants::float_scaling() + residual,
                constants::e_order_info_mismatch(),
            );
        };

        if (with_manager) {
            assert!(
                bob_deep_balance_before == bob_deep_balance_after + deep_in - residual,
                constants::e_order_info_mismatch(),
            );
            assert!(
                deep_required == deep_required_2 &&
                deep_required == bob_deep_balance_before - bob_deep_balance_after,
                constants::e_order_info_mismatch(),
            );
        } else {
            assert!(deep_out.value() == residual, constants::e_order_info_mismatch());
            assert!(
                deep_required == deep_required_2 &&
                deep_required == deep_in - deep_out.value(),
                constants::e_order_info_mismatch(),
            );
        };

        assert!(base == base_2 && base == base_out.value(), constants::e_order_info_mismatch());
        assert!(quote == quote_2 && quote == quote_out.value(), constants::e_order_info_mismatch());
    } else {
        if (is_bid) {
            assert!(
                base_out.value() == 3 * constants::float_scaling() + residual,
                constants::e_order_info_mismatch(),
            );
            assert!(
                quote_out.value() == 3 * constants::float_scaling(),
                constants::e_order_info_mismatch(),
            );
        } else {
            assert!(
                base_out.value() == 1 * constants::float_scaling(),
                constants::e_order_info_mismatch(),
            );
            assert!(
                quote_out.value() == 5 * constants::float_scaling() + residual,
                constants::e_order_info_mismatch(),
            );
        };

        if (with_manager) {
            assert!(
                bob_deep_balance_before - bob_deep_balance_after == constants::float_scaling() / 10,
                constants::e_order_info_mismatch(),
            );
            assert!(
                deep_required == deep_required_2 &&
                deep_required == bob_deep_balance_before - bob_deep_balance_after,
                constants::e_order_info_mismatch(),
            )
        } else {
            assert!(
                deep_out.value() == constants::float_scaling() / 10 + residual,
                constants::e_order_info_mismatch(),
            );
            assert!(
                deep_required == deep_required_2 &&
                deep_required == deep_in - deep_out.value(),
                constants::e_order_info_mismatch(),
            );
        };

        assert!(base == base_2 && base == base_out.value(), constants::e_order_info_mismatch());
        assert!(quote == quote_2 && quote == quote_out.value(), constants::e_order_info_mismatch());
    };

    base_out.burn_for_testing();
    quote_out.burn_for_testing();
    deep_out.burn_for_testing();

    end(test);
}

/// Test getting the mid price of the order book
/// Expired orders are skipped
fun test_mid_price() {
    let mut test = begin(OWNER);
    let registry_id = setup_test(OWNER, &mut test);
    let balance_manager_id_alice = create_acct_and_share_with_funds(
        ALICE,
        1000000 * constants::float_scaling(),
        &mut test,
    );
    let pool_id = setup_pool_with_default_fees_and_reference_pool<SUI, USDC, SUI, DEEP>(
        ALICE,
        registry_id,
        balance_manager_id_alice,
        &mut test,
    );

    let client_order_id = 1;
    let price_bid_1 = 1 * constants::float_scaling();
    let price_bid_best = 2 * constants::float_scaling();
    let price_bid_expired = 2_200_000_000;
    let price_ask_1 = 6 * constants::float_scaling();
    let price_ask_best = 5 * constants::float_scaling();
    let price_ask_expired = 3_200_000_000;
    let quantity = 1 * constants::float_scaling();
    let expire_timestamp = constants::max_u64();
    let expire_timestamp_e = get_time(&mut test) + 100;
    let pay_with_deep = true;
    let is_bid = true;

    place_limit_order<SUI, USDC>(
        ALICE,
        pool_id,
        balance_manager_id_alice,
        client_order_id,
        constants::no_restriction(),
        constants::self_matching_allowed(),
        price_bid_1,
        quantity,
        is_bid,
        pay_with_deep,
        expire_timestamp,
        &mut test,
    );

    place_limit_order<SUI, USDC>(
        ALICE,
        pool_id,
        balance_manager_id_alice,
        client_order_id,
        constants::no_restriction(),
        constants::self_matching_allowed(),
        price_bid_best,
        quantity,
        is_bid,
        pay_with_deep,
        expire_timestamp,
        &mut test,
    );

    place_limit_order<SUI, USDC>(
        ALICE,
        pool_id,
        balance_manager_id_alice,
        client_order_id,
        constants::no_restriction(),
        constants::self_matching_allowed(),
        price_bid_expired,
        quantity,
        is_bid,
        pay_with_deep,
        expire_timestamp_e,
        &mut test,
    );

    place_limit_order<SUI, USDC>(
        ALICE,
        pool_id,
        balance_manager_id_alice,
        client_order_id,
        constants::no_restriction(),
        constants::self_matching_allowed(),
        price_ask_1,
        quantity,
        !is_bid,
        pay_with_deep,
        expire_timestamp,
        &mut test,
    );

    place_limit_order<SUI, USDC>(
        ALICE,
        pool_id,
        balance_manager_id_alice,
        client_order_id,
        constants::no_restriction(),
        constants::self_matching_allowed(),
        price_ask_best,
        quantity,
        !is_bid,
        pay_with_deep,
        expire_timestamp,
        &mut test,
    );

    place_limit_order<SUI, USDC>(
        ALICE,
        pool_id,
        balance_manager_id_alice,
        client_order_id,
        constants::no_restriction(),
        constants::self_matching_allowed(),
        price_ask_expired,
        quantity,
        !is_bid,
        pay_with_deep,
        expire_timestamp_e,
        &mut test,
    );

    let expected_mid_price = (price_bid_expired + price_ask_expired) / 2;
    assert!(
        get_mid_price<SUI, USDC>(pool_id, &mut test) == expected_mid_price,
        constants::e_incorrect_mid_price(),
    );

    set_time(200, &mut test);
    let expected_mid_price = (price_bid_best + price_ask_best) / 2;
    assert!(
        get_mid_price<SUI, USDC>(pool_id, &mut test) == expected_mid_price,
        constants::e_incorrect_mid_price(),
    );

    end(test);
}

/// Places 3 orders at price 1, 2, 3 with quantity 1
/// Market order of quantity 1.5 should fill one order completely, one
/// partially, and one not at all
/// Order 3 is fully filled for bid orders then ask market order
/// Order 1 is fully filled for ask orders then bid market order
/// Order 2 is partially filled for both
fun test_market_order(is_bid: bool) {
    let mut test = begin(OWNER);
    let registry_id = setup_test(OWNER, &mut test);
    let balance_manager_id_alice = create_acct_and_share_with_funds(
        ALICE,
        1000000 * constants::float_scaling(),
        &mut test,
    );
    let pool_id = setup_pool_with_default_fees_and_reference_pool<SUI, USDC, SUI, DEEP>(
        ALICE,
        registry_id,
        balance_manager_id_alice,
        &mut test,
    );

    let client_order_id = 1;
    let base_price = constants::float_scaling();
    let quantity = 1 * constants::float_scaling();
    let expire_timestamp = constants::max_u64();
    let pay_with_deep = true;
    let mut i = 0;
    let num_orders = 3;
    let partial_order_client_id = 2;
    let full_order_client_id = if (is_bid) {
        1
    } else {
        3
    };
    let mut partial_order_id = 0;
    let mut full_order_id = 0;

    while (i < num_orders) {
        let order_info = place_limit_order<SUI, USDC>(
            ALICE,
            pool_id,
            balance_manager_id_alice,
            client_order_id + i,
            constants::no_restriction(),
            constants::self_matching_allowed(),
            (client_order_id + i) * base_price,
            quantity,
            is_bid,
            pay_with_deep,
            expire_timestamp,
            &mut test,
        );
        if (order_info.client_order_id() == full_order_client_id) {
            full_order_id = order_info.order_id();
        };
        if (order_info.client_order_id() == partial_order_client_id) {
            partial_order_id = order_info.order_id();
        };
        i = i + 1;
    };

    let client_order_id = num_orders + 1;
    let fee_is_deep = true;
    let quantity_2 = 1_500_000_000;
    let price = if (is_bid) {
        constants::min_price()
    } else {
        constants::max_price()
    };

    let order_info = place_market_order<SUI, USDC>(
        ALICE,
        pool_id,
        balance_manager_id_alice,
        client_order_id,
        constants::self_matching_allowed(),
        quantity_2,
        !is_bid,
        pay_with_deep,
        &mut test,
    );

    let current_time = get_time(&mut test);
    let cumulative_quote_quantity = if (is_bid) {
        4_000_000_000
    } else {
        2_000_000_000
    };

    verify_order_info(
        &order_info,
        client_order_id,
        price,
        quantity_2,
        quantity_2,
        cumulative_quote_quantity,
        math::mul(
            quantity_2,
            math::mul(
                constants::taker_fee(),
                constants::deep_multiplier(),
            ),
        ),
        fee_is_deep,
        constants::filled(),
        current_time,
    );

    borrow_and_verify_book_order<SUI, USDC>(
        pool_id,
        partial_order_id,
        is_bid,
        partial_order_client_id,
        quantity,
        500_000_000,
        constants::deep_multiplier(),
        0,
        constants::partially_filled(),
        constants::max_u64(),
        &mut test,
    );

    borrow_and_verify_book_order<SUI, USDC>(
        pool_id,
        full_order_id,
        is_bid,
        full_order_client_id,
        quantity,
        0,
        constants::deep_multiplier(),
        0,
        constants::live(),
        constants::max_u64(),
        &mut test,
    );

    end(test);
}

/// Test crossing num_orders orders with a single order
/// Should be filled with the num_orders orders, with correct quantities
/// Quantity of 1 for the first num_orders orders, quantity of num_orders for
/// the last order
fun test_crossing_multiple(is_bid: bool, num_orders: u64) {
    let mut test = begin(OWNER);
    let registry_id = setup_test(OWNER, &mut test);
    let balance_manager_id_alice = create_acct_and_share_with_funds(
        ALICE,
        1000000 * constants::float_scaling(),
        &mut test,
    );
    let pool_id = setup_pool_with_default_fees_and_reference_pool<SUI, USDC, SUI, DEEP>(
        ALICE,
        registry_id,
        balance_manager_id_alice,
        &mut test,
    );

    let client_order_id = 1;
    let price = 2 * constants::float_scaling();
    let quantity = 1 * constants::float_scaling();
    let expire_timestamp = constants::max_u64();
    let pay_with_deep = true;

    let mut i = 0;
    while (i < num_orders) {
        place_limit_order<SUI, USDC>(
            ALICE,
            pool_id,
            balance_manager_id_alice,
            client_order_id,
            constants::no_restriction(),
            constants::self_matching_allowed(),
            price,
            quantity,
            is_bid,
            pay_with_deep,
            expire_timestamp,
            &mut test,
        );
        i = i + 1;
    };

    let client_order_id = 3;
    let price = if (is_bid) {
        1 * constants::float_scaling()
    } else {
        3 * constants::float_scaling()
    };

    let order_info = place_limit_order<SUI, USDC>(
        ALICE,
        pool_id,
        balance_manager_id_alice,
        client_order_id,
        constants::no_restriction(),
        constants::self_matching_allowed(),
        price,
        num_orders * quantity,
        !is_bid,
        pay_with_deep,
        expire_timestamp,
        &mut test,
    );

    verify_order_info(
        &order_info,
        client_order_id,
        price,
        num_orders * quantity,
        num_orders * quantity,
        2 * num_orders * quantity,
        num_orders *
        math::mul(constants::taker_fee(), constants::deep_multiplier()),
        true,
        constants::filled(),
        expire_timestamp,
    );

    end(test);
}

/// Test fill or kill order that crosses with an order that's smaller in
/// quantity
/// Should error with EFOKOrderCannotBeFullyFilled if order cannot be fully
/// filled
/// Should fill correctly if order can be fully filled
/// First order has quantity 1, second order has quantity 2 for incorrect fill
/// First two orders have quantity 1, third order is quantity 2 for correct fill
fun test_fill_or_kill(is_bid: bool, order_can_be_filled: bool) {
    let mut test = begin(OWNER);
    let registry_id = setup_test(OWNER, &mut test);
    let balance_manager_id_alice = create_acct_and_share_with_funds(
        ALICE,
        1000000 * constants::float_scaling(),
        &mut test,
    );
    let pool_id = setup_pool_with_default_fees_and_reference_pool<SUI, USDC, SUI, DEEP>(
        ALICE,
        registry_id,
        balance_manager_id_alice,
        &mut test,
    );

    let client_order_id = 1;
    let price = 2 * constants::float_scaling();
    let quantity = 1 * constants::float_scaling();
    let expire_timestamp = constants::max_u64();
    let pay_with_deep = true;
    let quantity_multiplier = 2;
    let mut num_orders = if (order_can_be_filled) {
        quantity_multiplier
    } else {
        1
    };

    while (num_orders > 0) {
        place_limit_order<SUI, USDC>(
            ALICE,
            pool_id,
            balance_manager_id_alice,
            client_order_id,
            constants::no_restriction(),
            constants::self_matching_allowed(),
            price,
            quantity,
            is_bid,
            pay_with_deep,
            expire_timestamp,
            &mut test,
        );
        num_orders = num_orders - 1;
    };

    // Place a second order that crosses with the first i orders
    let client_order_id = 2;
    let price = if (is_bid) {
        1 * constants::float_scaling()
    } else {
        3 * constants::float_scaling()
    };

    let order_info = place_limit_order<SUI, USDC>(
        ALICE,
        pool_id,
        balance_manager_id_alice,
        client_order_id,
        constants::fill_or_kill(),
        constants::self_matching_allowed(),
        price,
        quantity_multiplier * quantity,
        !is_bid,
        pay_with_deep,
        expire_timestamp,
        &mut test,
    );

    verify_order_info(
        &order_info,
        client_order_id,
        price,
        quantity_multiplier * quantity,
        quantity_multiplier * quantity,
        2 * quantity_multiplier * quantity,
        quantity_multiplier *
        math::mul(constants::taker_fee(), constants::deep_multiplier()),
        true,
        constants::filled(),
        expire_timestamp,
    );

    end(test);
}

/// Test post only order that crosses with another order
/// Should error with EPOSTOrderCrossesOrderbook
fun test_post_only(is_bid: bool, crosses_order: bool) {
    let mut test = begin(OWNER);
    let registry_id = setup_test(OWNER, &mut test);
    let balance_manager_id_alice = create_acct_and_share_with_funds(
        ALICE,
        1000000 * constants::float_scaling(),
        &mut test,
    );
    let pool_id = setup_pool_with_default_fees_and_reference_pool<SUI, USDC, SUI, DEEP>(
        ALICE,
        registry_id,
        balance_manager_id_alice,
        &mut test,
    );

    let client_order_id = 1;
    let order_type = constants::post_only();
    let price = 2 * constants::float_scaling();
    let quantity = 1 * constants::float_scaling();
    let expire_timestamp = constants::max_u64();
    let pay_with_deep = true;

    place_limit_order<SUI, USDC>(
        ALICE,
        pool_id,
        balance_manager_id_alice,
        client_order_id,
        order_type,
        constants::self_matching_allowed(),
        price,
        quantity,
        is_bid,
        pay_with_deep,
        expire_timestamp,
        &mut test,
    );

    // Place a second order that crosses with the first order
    let client_order_id = 2;
    let price = if ((is_bid && crosses_order) || (!is_bid && !crosses_order)) {
        1 * constants::float_scaling()
    } else {
        3 * constants::float_scaling()
    };

    place_limit_order<SUI, USDC>(
        ALICE,
        pool_id,
        balance_manager_id_alice,
        client_order_id,
        order_type,
        constants::self_matching_allowed(),
        price,
        quantity,
        !is_bid,
        pay_with_deep,
        expire_timestamp,
        &mut test,
    );

    end(test);
}

#[test, expected_failure(abort_code = ::deepbook::order_info::EInvalidOrderType)]
/// placing an order > MAX_RESTRICTIONS should fail
fun place_order_max_restrictions_e() {
    let mut test = begin(OWNER);
    let registry_id = setup_test(OWNER, &mut test);
    let balance_manager_id_alice = create_acct_and_share_with_funds(
        ALICE,
        1000000 * constants::float_scaling(),
        &mut test,
    );
    let pool_id = setup_pool_with_default_fees_and_reference_pool<SUI, USDC, SUI, DEEP>(
        ALICE,
        registry_id,
        balance_manager_id_alice,
        &mut test,
    );
    let client_order_id = 1;
    let order_type = constants::max_restriction() + 1;
    let price = 2 * constants::float_scaling();
    let quantity = 1 * constants::float_scaling();
    let expire_timestamp = constants::max_u64();
    let pay_with_deep = true;

    place_limit_order<SUI, USDC>(
        ALICE,
        pool_id,
        balance_manager_id_alice,
        client_order_id,
        order_type,
        constants::self_matching_allowed(),
        price,
        quantity,
        true,
        pay_with_deep,
        expire_timestamp,
        &mut test,
    );
    end(test);
}

#[test, expected_failure(abort_code = ::deepbook::big_vector::ENotFound)]
/// Trying to cancel a cancelled order should fail
fun place_and_cancel_order_empty_e() {
    let mut test = begin(OWNER);
    let registry_id = setup_test(OWNER, &mut test);
    let balance_manager_id_alice = create_acct_and_share_with_funds(
        ALICE,
        1000000 * constants::float_scaling(),
        &mut test,
    );
    let pool_id = setup_pool_with_default_fees_and_reference_pool<SUI, USDC, SUI, DEEP>(
        ALICE,
        registry_id,
        balance_manager_id_alice,
        &mut test,
    );

    let client_order_id = 1;
    let order_type = constants::no_restriction();
    let price = 2 * constants::float_scaling();
    let alice_quantity = 1 * constants::float_scaling();
    let expire_timestamp = constants::max_u64();
    let is_bid = true;
    let pay_with_deep = true;

    let placed_order_id = place_limit_order<SUI, USDC>(
        ALICE,
        pool_id,
        balance_manager_id_alice,
        client_order_id,
        order_type,
        constants::self_matching_allowed(),
        price,
        alice_quantity,
        is_bid,
        pay_with_deep,
        expire_timestamp,
        &mut test,
    ).order_id();
    cancel_order<SUI, USDC>(
        ALICE,
        pool_id,
        balance_manager_id_alice,
        placed_order_id,
        &mut test,
    );
    cancel_order<SUI, USDC>(
        ALICE,
        pool_id,
        balance_manager_id_alice,
        placed_order_id,
        &mut test,
    );
    end(test);
}

#[test]
fun mint_referral_ok() {
    let mut test = begin(OWNER);
    let pool_id = setup_everything<SUI, USDC, SUI, DEEP>(&mut test);

    test.next_tx(ALICE);
    {
        let mut pool = test.take_shared_by_id<Pool<SUI, USDC>>(pool_id);
        let mut i = 1;
        while (i <= 20) {
            pool.mint_referral(100_000_000 * i, test.ctx());
            i = i + 1;
        };
        return_shared(pool);
    };

    let referral_id;
    test.next_tx(ALICE);
    {
        let mut pool = test.take_shared_by_id<Pool<SUI, USDC>>(pool_id);
        referral_id = pool.mint_referral(100_000_000, test.ctx());
        return_shared(pool);
    };

    test.next_tx(ALICE);
    {
        let pool = test.take_shared_by_id<Pool<SUI, USDC>>(pool_id);
        let referral = test.take_shared_by_id<DeepBookPoolReferral>(referral_id);
        let (base, quote, deep) = pool.get_pool_referral_balances(&referral);
        assert!(base == 0, 0);
        assert!(quote == 0, 0);
        assert!(deep == 0, 0);
        return_shared(referral);
        return_shared(pool);
    };

    end(test);
}

#[test, expected_failure(abort_code = ::deepbook::pool::EInvalidReferralMultiplier)]
fun mint_referral_max_multiplier_e() {
    let mut test = begin(OWNER);
    let pool_id = setup_everything<SUI, USDC, SUI, DEEP>(&mut test);
    test.next_tx(ALICE);
    {
        let mut pool = test.take_shared_by_id<Pool<SUI, USDC>>(pool_id);
        pool.mint_referral(2_100_000_000, test.ctx());
    };

    abort (0)
}

#[test, expected_failure(abort_code = ::deepbook::pool::EInvalidReferralMultiplier)]
fun mint_referral_not_multiple_of_multiplier_e() {
    let mut test = begin(OWNER);
    let pool_id = setup_everything<SUI, USDC, SUI, DEEP>(&mut test);
    test.next_tx(ALICE);
    {
        let mut pool = test.take_shared_by_id<Pool<SUI, USDC>>(pool_id);
        pool.mint_referral(100_000_001, test.ctx());
    };

    abort (0)
}

#[test, expected_failure(abort_code = ::deepbook::pool::EInvalidReferralMultiplier)]
fun test_update_deepbook_referral_multiplier_e() {
    let mut test = begin(OWNER);
    let pool_id = setup_everything<SUI, USDC, SUI, DEEP>(&mut test);
    let referral_id;
    test.next_tx(ALICE);
    {
        let mut pool = test.take_shared_by_id<Pool<SUI, USDC>>(pool_id);
        referral_id = pool.mint_referral(100_000_000, test.ctx());
        return_shared(pool);
    };

    test.next_tx(ALICE);
    {
        let mut pool = test.take_shared_by_id<Pool<SUI, USDC>>(pool_id);
        let referral = test.take_shared_by_id<DeepBookPoolReferral>(referral_id);
        pool.update_pool_referral_multiplier(&referral, 2_100_000_000, test.ctx());
    };

    abort (0)
}

#[test, expected_failure(abort_code = ::deepbook::balance_manager::EInvalidReferralOwner)]
fun test_update_deepbook_referral_multiplier_wrong_owner() {
    let mut test = begin(OWNER);
    let pool_id = setup_everything<SUI, USDC, SUI, DEEP>(&mut test);
    let referral_id;
    test.next_tx(ALICE);
    {
        let mut pool = test.take_shared_by_id<Pool<SUI, USDC>>(pool_id);
        referral_id = pool.mint_referral(100_000_000, test.ctx());
        return_shared(pool);
    };

    // BOB tries to update ALICE's referral multiplier
    test.next_tx(BOB);
    {
        let mut pool = test.take_shared_by_id<Pool<SUI, USDC>>(pool_id);
        let referral = test.take_shared_by_id<DeepBookPoolReferral>(referral_id);
        pool.update_pool_referral_multiplier(&referral, 200_000_000, test.ctx());
    };

    abort (0)
}

#[test, expected_failure(abort_code = ::deepbook::balance_manager::EInvalidReferralOwner)]
fun test_claim_referral_rewards_wrong_owner() {
    let mut test = begin(OWNER);
    let pool_id = setup_everything<SUI, USDC, SUI, DEEP>(&mut test);
    let referral_id;
    test.next_tx(ALICE);
    {
        let mut pool = test.take_shared_by_id<Pool<SUI, USDC>>(pool_id);
        referral_id = pool.mint_referral(100_000_000, test.ctx());
        return_shared(pool);
    };

    // BOB tries to claim ALICE's referral rewards
    test.next_tx(BOB);
    {
        let mut pool = test.take_shared_by_id<Pool<SUI, USDC>>(pool_id);
        let referral = test.take_shared_by_id<DeepBookPoolReferral>(referral_id);
        let (base, quote, deep) = pool.claim_pool_referral_rewards(&referral, test.ctx());
        destroy(base);
        destroy(quote);
        destroy(deep);
    };

    abort (0)
}

#[test]
fun test_process_order_referral_ok() {
    let mut test = begin(OWNER);
    let pool_id = setup_everything<SUI, USDC, SUI, DEEP>(&mut test);
    let referral_id;
    test.next_tx(ALICE);
    {
        let mut pool = test.take_shared_by_id<Pool<SUI, USDC>>(pool_id);
        referral_id = pool.mint_referral(100_000_000, test.ctx());
        return_shared(pool);
    };

    let balance_manager_id_alice;
    test.next_tx(ALICE);
    {
        balance_manager_id_alice =
            create_acct_and_share_with_funds_typed<SUI, USDC, SUI, DEEP>(
                ALICE,
                1000000 * constants::float_scaling(),
                &mut test,
            );
    };

    test.next_tx(ALICE);
    {
        let mut balance_manager = test.take_shared_by_id<BalanceManager>(balance_manager_id_alice);
        let referral = test.take_shared_by_id<DeepBookPoolReferral>(referral_id);
        let trade_cap = balance_manager.mint_trade_cap(test.ctx());
        balance_manager.set_balance_manager_referral(&referral, &trade_cap);
        return_shared(balance_manager);
        return_shared(referral);
        destroy(trade_cap);
    };

    test.next_tx(ALICE);
    {
        let order_info = place_market_order<SUI, USDC>(
            ALICE,
            pool_id,
            balance_manager_id_alice,
            1,
            constants::self_matching_allowed(),
            1_500_000_000,
            true,
            true,
            &mut test,
        );

        assert_eq!(order_info.paid_fees(), 150_000_000);
    };

    test.next_tx(ALICE);
    {
        let pool = test.take_shared_by_id<Pool<SUI, USDC>>(pool_id);
        let referral = test.take_shared_by_id<DeepBookPoolReferral>(referral_id);
        let (base, quote, deep) = pool.get_pool_referral_balances(&referral);
        assert_eq!(base, 0);
        assert_eq!(quote, 0);
        // 10bps fee, 0.1x multiplier
        assert_eq!(deep, 15_000_000);
        return_shared(referral);
        return_shared(pool);
    };

    // increase multiplier from 0.1x to 2x
    test.next_tx(ALICE);
    {
        let mut pool = test.take_shared_by_id<Pool<SUI, USDC>>(pool_id);
        let referral = test.take_shared_by_id<DeepBookPoolReferral>(referral_id);
        pool.update_pool_referral_multiplier(&referral, 2_000_000_000, test.ctx());
        return_shared(pool);
        return_shared(referral);
    };

    test.next_tx(ALICE);
    {
        let order_info = place_market_order<SUI, USDC>(
            ALICE,
            pool_id,
            balance_manager_id_alice,
            1,
            constants::self_matching_allowed(),
            1_500_000_000,
            true,
            true,
            &mut test,
        );

        assert_eq!(order_info.paid_fees(), 150_000_000);
    };

    test.next_tx(ALICE);
    {
        let pool = test.take_shared_by_id<Pool<SUI, USDC>>(pool_id);
        let referral = test.take_shared_by_id<DeepBookPoolReferral>(referral_id);
        let (base, quote, deep) = pool.get_pool_referral_balances(&referral);
        assert_eq!(base, 0);
        assert_eq!(quote, 0);
        // 10bps fee, 2x multiplier = 300_000_000
        // + 10bps fee, 0.1x multiplier = 15_000_000
        assert_eq!(deep, 315_000_000);
        return_shared(referral);
        return_shared(pool);
    };

    test.next_tx(ALICE);
    {
        let order_info = place_market_order<SUI, USDC>(
            ALICE,
            pool_id,
            balance_manager_id_alice,
            1,
            constants::self_matching_allowed(),
            1_500_000_000,
            true,
            false,
            &mut test,
        );

        // fees paid in USDC = 1.5 filled @ $2 = 3_000_000_000
        // 10bps of that = 3_000_000
        // penalty 1.25x = 3_750_000
        assert_eq!(order_info.paid_fees(), 3_750_000);
    };

    test.next_tx(ALICE);
    {
        let pool = test.take_shared_by_id<Pool<SUI, USDC>>(pool_id);
        let referral = test.take_shared_by_id<DeepBookPoolReferral>(referral_id);
        let (base, quote, deep) = pool.get_pool_referral_balances(&referral);
        assert_eq!(base, 0);
        // fees paid in USDC = 3_750_000 with 2x multiple = 7_500_000
        assert_eq!(quote, 7_500_000);
        assert_eq!(deep, 315_000_000);
        return_shared(referral);
        return_shared(pool);
    };

    test.next_tx(ALICE);
    {
        let order_info = place_market_order<SUI, USDC>(
            ALICE,
            pool_id,
            balance_manager_id_alice,
            1,
            constants::self_matching_allowed(),
            1_500_000_000,
            false,
            false,
            &mut test,
        );

        // fees paid in SUI = 1.5 filled @ $1 = 1_500_000_000
        // 10bps of that = 1_500_000
        // penalty 1.25x = 1_875_000
        assert_eq!(order_info.paid_fees(), 1_875_000);
    };

    test.next_tx(ALICE);
    {
        let pool = test.take_shared_by_id<Pool<SUI, USDC>>(pool_id);
        let referral = test.take_shared_by_id<DeepBookPoolReferral>(referral_id);
        let (base, quote, deep) = pool.get_pool_referral_balances(&referral);
        // fees paid in SUI = 1_875_000 with 2x multiple = 3_750_000
        assert_eq!(base, 3_750_000);
        assert_eq!(quote, 7_500_000);
        assert_eq!(deep, 315_000_000);
        return_shared(referral);
        return_shared(pool);
    };

    end(test);
}

#[test]
fun test_referral_two_pools_comprehensive() {
    let mut test = begin(OWNER);

    // Setup registry
    let registry_id = setup_test(OWNER, &mut test);

    // Alice creates balance manager with funds for both pools
    let balance_manager_id_alice;
    test.next_tx(ALICE);
    {
        balance_manager_id_alice =
            create_acct_and_share_with_funds_typed<SUI, USDC, SUI, DEEP>(
                ALICE,
                1000000 * constants::float_scaling(),
                &mut test,
            );
    };

    // Also deposit USDT into Alice's balance manager for pool 2
    test.next_tx(ALICE);
    {
        let mut balance_manager = test.take_shared_by_id<BalanceManager>(balance_manager_id_alice);
        balance_manager.deposit(
            mint_for_testing<USDT>(1000000 * constants::float_scaling(), test.ctx()),
            test.ctx(),
        );
        return_shared(balance_manager);
    };

    // Create reference pool (SUI/DEEP) with orders
    let reference_pool_id = setup_reference_pool<SUI, DEEP>(
        ALICE,
        registry_id,
        balance_manager_id_alice,
        constants::deep_multiplier(),
        &mut test,
    );

    set_time(0, &mut test);

    // Setup pool 1: SUI/USDC
    let pool_id_1 = setup_pool_with_default_fees<SUI, USDC>(
        OWNER,
        registry_id,
        false,
        false,
        &mut test,
    );

    // Add deep price point for pool 1
    add_deep_price_point<SUI, USDC, SUI, DEEP>(
        ALICE,
        pool_id_1,
        reference_pool_id,
        &mut test,
    );

    // Place initial orders in pool 1
    let client_order_id = 1;
    let order_type = constants::no_restriction();
    let expire_timestamp = constants::max_u64();

    // Sell at $2
    place_limit_order<SUI, USDC>(
        ALICE,
        pool_id_1,
        balance_manager_id_alice,
        client_order_id,
        order_type,
        constants::self_matching_allowed(),
        2 * constants::float_scaling(),
        1000 * constants::float_scaling(),
        false,
        true,
        expire_timestamp,
        &mut test,
    );

    // Buy at $1
    place_limit_order<SUI, USDC>(
        ALICE,
        pool_id_1,
        balance_manager_id_alice,
        client_order_id,
        order_type,
        constants::self_matching_allowed(),
        1 * constants::float_scaling(),
        1000 * constants::float_scaling(),
        true,
        true,
        expire_timestamp,
        &mut test,
    );

    // Setup pool 2: SUI/USDT (shares SUI with reference pool SUI/DEEP)
    let pool_id_2 = setup_pool_with_default_fees<SUI, USDT>(
        OWNER,
        registry_id,
        false,
        false,
        &mut test,
    );

    // Add deep price point for pool 2 (reuse same reference pool)
    add_deep_price_point<SUI, USDT, SUI, DEEP>(
        ALICE,
        pool_id_2,
        reference_pool_id,
        &mut test,
    );

    // Place initial orders in pool 2
    // Alice places sell order at $2 in pool 2
    place_limit_order<SUI, USDT>(
        ALICE,
        pool_id_2,
        balance_manager_id_alice,
        client_order_id,
        order_type,
        constants::self_matching_allowed(),
        2 * constants::float_scaling(),
        1000 * constants::float_scaling(),
        false,
        true,
        expire_timestamp,
        &mut test,
    );

    // Alice places buy order at $1 in pool 2
    place_limit_order<SUI, USDT>(
        ALICE,
        pool_id_2,
        balance_manager_id_alice,
        client_order_id,
        order_type,
        constants::self_matching_allowed(),
        1 * constants::float_scaling(),
        1000 * constants::float_scaling(),
        true,
        true,
        expire_timestamp,
        &mut test,
    );

    // Bob mints referral for pool 1 with 0.5x multiplier (500_000_000)
    let referral_id_pool1;
    test.next_tx(BOB);
    {
        let mut pool = test.take_shared_by_id<Pool<SUI, USDC>>(pool_id_1);
        referral_id_pool1 = pool.mint_referral(500_000_000, test.ctx());
        return_shared(pool);
    };

    // Bob mints referral for pool 2 with 1x multiplier (1_000_000_000)
    let referral_id_pool2;
    test.next_tx(BOB);
    {
        let mut pool = test.take_shared_by_id<Pool<SUI, USDT>>(pool_id_2);
        referral_id_pool2 = pool.mint_referral(1_000_000_000, test.ctx());
        return_shared(pool);
    };

    // Alice sets Bob's referrals on her balance manager
    test.next_tx(ALICE);
    {
        let mut balance_manager = test.take_shared_by_id<BalanceManager>(balance_manager_id_alice);
        let referral1 = test.take_shared_by_id<DeepBookPoolReferral>(referral_id_pool1);
        let referral2 = test.take_shared_by_id<DeepBookPoolReferral>(referral_id_pool2);
        let trade_cap = test.take_from_sender<TradeCap>();

        balance_manager.set_balance_manager_referral(&referral1, &trade_cap);
        balance_manager.set_balance_manager_referral(&referral2, &trade_cap);

        // Verify referrals are set correctly
        assert!(
            balance_manager.get_balance_manager_referral_id(pool_id_1) ==
            option::some(referral_id_pool1),
        );
        assert!(
            balance_manager.get_balance_manager_referral_id(pool_id_2) ==
            option::some(referral_id_pool2),
        );

        return_shared(balance_manager);
        return_shared(referral1);
        return_shared(referral2);
        test.return_to_sender(trade_cap);
    };

    // Alice trades in pool 1 (buy 1.5 SUI at $2)
    test.next_tx(ALICE);
    {
        let order_info = place_market_order<SUI, USDC>(
            ALICE,
            pool_id_1,
            balance_manager_id_alice,
            1,
            constants::self_matching_allowed(),
            1_500_000_000, // 1.5 SUI
            true,
            true,
            &mut test,
        );
        // 10bps fee on 1.5 SUI = 150_000_000 DEEP
        assert_eq!(order_info.paid_fees(), 150_000_000);
    };

    // Alice trades in pool 2 (buy 2.0 SUI at $2)
    test.next_tx(ALICE);
    {
        let order_info = place_market_order<SUI, USDT>(
            ALICE,
            pool_id_2,
            balance_manager_id_alice,
            1,
            constants::self_matching_allowed(),
            2_000_000_000, // 2.0 SUI
            true,
            true,
            &mut test,
        );
        // 10bps fee on 2.0 SUI = 200_000_000 DEEP
        assert_eq!(order_info.paid_fees(), 200_000_000);
    };

    // Verify referral balances before claiming
    // Pool 1: 150_000_000 fees * 0.5 multiplier = 75_000_000 DEEP
    test.next_tx(BOB);
    {
        let pool = test.take_shared_by_id<Pool<SUI, USDC>>(pool_id_1);
        let referral = test.take_shared_by_id<DeepBookPoolReferral>(referral_id_pool1);
        let (base, quote, deep) = pool.get_pool_referral_balances(&referral);
        assert_eq!(base, 0);
        assert_eq!(quote, 0);
        assert_eq!(deep, 75_000_000); // 150_000_000 * 0.5 = 75_000_000
        return_shared(referral);
        return_shared(pool);
    };

    // Pool 2: 200_000_000 fees * 1.0 multiplier = 200_000_000 DEEP
    test.next_tx(BOB);
    {
        let pool = test.take_shared_by_id<Pool<SUI, USDT>>(pool_id_2);
        let referral = test.take_shared_by_id<DeepBookPoolReferral>(referral_id_pool2);
        let (base, quote, deep) = pool.get_pool_referral_balances(&referral);
        assert_eq!(base, 0);
        assert_eq!(quote, 0);
        assert_eq!(deep, 200_000_000); // 200_000_000 * 1.0 = 200_000_000
        return_shared(referral);
        return_shared(pool);
    };

    // Bob claims rewards from pool 1
    test.next_tx(BOB);
    {
        let mut pool = test.take_shared_by_id<Pool<SUI, USDC>>(pool_id_1);
        let referral = test.take_shared_by_id<DeepBookPoolReferral>(referral_id_pool1);
        let (base, quote, deep) = pool.claim_pool_referral_rewards(&referral, test.ctx());

        assert_eq!(base.value(), 0);
        assert_eq!(quote.value(), 0);
        assert_eq!(deep.value(), 75_000_000);

        destroy(base);
        destroy(quote);
        destroy(deep);
        return_shared(referral);
        return_shared(pool);
    };

    // Bob claims rewards from pool 2
    test.next_tx(BOB);
    {
        let mut pool = test.take_shared_by_id<Pool<SUI, USDT>>(pool_id_2);
        let referral = test.take_shared_by_id<DeepBookPoolReferral>(referral_id_pool2);
        let (base, quote, deep) = pool.claim_pool_referral_rewards(&referral, test.ctx());

        assert_eq!(base.value(), 0);
        assert_eq!(quote.value(), 0);
        assert_eq!(deep.value(), 200_000_000);

        destroy(base);
        destroy(quote);
        destroy(deep);
        return_shared(referral);
        return_shared(pool);
    };

    // Verify balances are (0,0,0) after claiming
    test.next_tx(BOB);
    {
        let pool = test.take_shared_by_id<Pool<SUI, USDC>>(pool_id_1);
        let referral = test.take_shared_by_id<DeepBookPoolReferral>(referral_id_pool1);
        let (base, quote, deep) = pool.get_pool_referral_balances(&referral);
        assert_eq!(base, 0);
        assert_eq!(quote, 0);
        assert_eq!(deep, 0);
        return_shared(referral);
        return_shared(pool);
    };

    test.next_tx(BOB);
    {
        let pool = test.take_shared_by_id<Pool<SUI, USDT>>(pool_id_2);
        let referral = test.take_shared_by_id<DeepBookPoolReferral>(referral_id_pool2);
        let (base, quote, deep) = pool.get_pool_referral_balances(&referral);
        assert_eq!(base, 0);
        assert_eq!(quote, 0);
        assert_eq!(deep, 0);
        return_shared(referral);
        return_shared(pool);
    };

    end(test);
}

#[test]
fun test_enable_ewma_params_ok() {
    let mut test = begin(OWNER);
    let pool_id = setup_everything<SUI, USDC, SUI, DEEP>(&mut test);
    let admin_cap = registry::get_admin_cap_for_testing(test.ctx());
    let clock = clock::create_for_testing(test.ctx());
    test.next_tx(ALICE);
    {
        let mut pool = test.take_shared_by_id<Pool<SUI, USDC>>(pool_id);
        pool.enable_ewma_state(&admin_cap, true, &clock, test.ctx());
        let ewma_state = pool.load_ewma_state();
        assert!(ewma_state.enabled(), 0);
        assert!(ewma_state.alpha() == constants::default_ewma_alpha(), 1);
        assert!(ewma_state.z_score_threshold() == constants::default_z_score_threshold(), 2);
        assert!(ewma_state.additional_taker_fee() == constants::default_additional_taker_fee(), 3);
        return_shared(pool);
    };

    test.next_tx(ALICE);
    {
        let mut pool = test.take_shared_by_id<Pool<SUI, USDC>>(pool_id);
        pool.set_ewma_params(&admin_cap, 10_000_000, 3_000_000_000, 1_000_000, &clock, test.ctx());
        let ewma_state = pool.load_ewma_state();
        assert!(ewma_state.enabled(), 0);
        assert!(ewma_state.alpha() == 10_000_000, 1);
        assert!(ewma_state.z_score_threshold() == 3_000_000_000, 2);
        assert!(ewma_state.additional_taker_fee() == 1_000_000, 3);
        return_shared(pool);
    };

    let balance_manager_id_alice;
    test.next_tx(ALICE);
    {
        balance_manager_id_alice =
            create_acct_and_share_with_funds_typed<SUI, USDC, SUI, DEEP>(
                ALICE,
                1000000 * constants::float_scaling(),
                &mut test,
            );
    };

    let gas_price = 1_000;
    advance_scenario_with_gas_price(&mut test, gas_price, 1000);
    test.next_tx(ALICE);
    {
        let order_info = place_market_order<SUI, USDC>(
            ALICE,
            pool_id,
            balance_manager_id_alice,
            1,
            constants::self_matching_allowed(),
            1_500_000_000,
            true,
            true,
            &mut test,
        );
        assert_eq!(order_info.paid_fees(), 150_000_000);
    };

    test.next_tx(ALICE);
    {
        let order_info = place_market_order<SUI, USDC>(
            ALICE,
            pool_id,
            balance_manager_id_alice,
            1,
            constants::self_matching_allowed(),
            1_500_000_000,
            true,
            true,
            &mut test,
        );
        assert_eq!(order_info.paid_fees(), 150_000_000);
    };

    // pay with high gas price
    advance_scenario_with_gas_price(&mut test, gas_price * 5, 1000);
    test.next_tx(ALICE);
    {
        let order_info = place_market_order<SUI, USDC>(
            ALICE,
            pool_id,
            balance_manager_id_alice,
            1,
            constants::self_matching_allowed(),
            1_500_000_000,
            true,
            true,
            &mut test,
        );
        assert_eq!(order_info.paid_fees(), 300_000_000);
    };

    test.next_tx(ALICE);
    {
        let mut pool = test.take_shared_by_id<Pool<SUI, USDC>>(pool_id);
        pool.enable_ewma_state(&admin_cap, false, &clock, test.ctx());
        let ewma_state = pool.load_ewma_state();
        assert!(!ewma_state.enabled(), 0);
        return_shared(pool);
    };

    // pay with high gas price, but disabled ewma
    advance_scenario_with_gas_price(&mut test, gas_price * 5, 1000);
    test.next_tx(ALICE);
    {
        let order_info = place_market_order<SUI, USDC>(
            ALICE,
            pool_id,
            balance_manager_id_alice,
            1,
            constants::self_matching_allowed(),
            1_500_000_000,
            true,
            true,
            &mut test,
        );
        assert_eq!(order_info.paid_fees(), 150_000_000);
    };

    destroy(clock);
    destroy(admin_cap);
    end(test);
}

#[test, expected_failure(abort_code = ::deepbook::order_info::EInvalidExpireTimestamp)]
/// Trying to place an order that's expiring should fail
fun place_order_expired_order_skipped() {
    let mut test = begin(OWNER);
    let registry_id = setup_test(OWNER, &mut test);
    let balance_manager_id_alice = create_acct_and_share_with_funds(
        ALICE,
        1000000 * constants::float_scaling(),
        &mut test,
    );
    let pool_id = setup_pool_with_default_fees_and_reference_pool<SUI, USDC, SUI, DEEP>(
        ALICE,
        registry_id,
        balance_manager_id_alice,
        &mut test,
    );
    set_time(100, &mut test);

    let client_order_id = 1;
    let order_type = constants::no_restriction();
    let price = 2 * constants::float_scaling();
    let quantity = 1 * constants::float_scaling();
    let expire_timestamp = 0;
    let is_bid = true;
    let pay_with_deep = true;

    place_limit_order<SUI, USDC>(
        ALICE,
        pool_id,
        balance_manager_id_alice,
        client_order_id,
        order_type,
        constants::self_matching_allowed(),
        price,
        quantity,
        is_bid,
        pay_with_deep,
        expire_timestamp,
        &mut test,
    );
    end(test);
}

fun test_cancel_all_orders(is_bid: bool, has_open_orders: bool) {
    let mut test = begin(OWNER);
    let registry_id = setup_test(OWNER, &mut test);
    let balance_manager_id_alice = create_acct_and_share_with_funds(
        ALICE,
        1000000 * constants::float_scaling(),
        &mut test,
    );
    let pool_id = setup_pool_with_default_fees_and_reference_pool<SUI, USDC, SUI, DEEP>(
        ALICE,
        registry_id,
        balance_manager_id_alice,
        &mut test,
    );

    let client_order_id = 1;
    let order_type = constants::no_restriction();
    let price = 2 * constants::float_scaling();
    let quantity = 1 * constants::float_scaling();
    let expire_timestamp = constants::max_u64();
    let pay_with_deep = true;
    let mut order_info_1_id = 0;

    if (has_open_orders) {
        order_info_1_id =
            place_limit_order<SUI, USDC>(
                ALICE,
                pool_id,
                balance_manager_id_alice,
                client_order_id,
                order_type,
                constants::self_matching_allowed(),
                price,
                quantity,
                is_bid,
                pay_with_deep,
                expire_timestamp,
                &mut test,
            ).order_id();

        let client_order_id = 2;

        let order_info_2_id = place_limit_order<SUI, USDC>(
            ALICE,
            pool_id,
            balance_manager_id_alice,
            client_order_id,
            order_type,
            constants::self_matching_allowed(),
            price,
            quantity,
            is_bid,
            pay_with_deep,
            expire_timestamp,
            &mut test,
        ).order_id();

        borrow_order_ok<SUI, USDC>(
            pool_id,
            order_info_1_id,
            &mut test,
        );

        borrow_order_ok<SUI, USDC>(
            pool_id,
            order_info_2_id,
            &mut test,
        );
    };

    cancel_all_orders<SUI, USDC>(
        pool_id,
        ALICE,
        balance_manager_id_alice,
        &mut test,
    );

    if (has_open_orders) {
        borrow_order_ok<SUI, USDC>(
            pool_id,
            order_info_1_id,
            &mut test,
        );
    };
    end(test);
}

/// Alice places a bid order, Bob places a swap_exact_amount order
/// Make sure the assets returned to Bob are correct
/// Make sure expired orders are skipped over
fun test_swap_exact_amount(is_bid: bool, with_manager: bool) {
    let mut test = begin(OWNER);
    let registry_id = setup_test(OWNER, &mut test);
    let balance_manager_id_alice = create_acct_and_share_with_funds(
        ALICE,
        1000000 * constants::float_scaling(),
        &mut test,
    );
    let pool_id = setup_pool_with_default_fees_and_reference_pool<SUI, USDC, SUI, DEEP>(
        ALICE,
        registry_id,
        balance_manager_id_alice,
        &mut test,
    );

    let alice_client_order_id = 1;
    let alice_price = 2 * constants::float_scaling();
    let alice_quantity = 2 * constants::float_scaling();
    let expired_price = if (is_bid) {
        3 * constants::float_scaling()
    } else {
        1 * constants::float_scaling()
    };
    let expire_timestamp = constants::max_u64();
    let expire_timestamp_e = get_time(&mut test) + 100;
    let pay_with_deep = true;
    let residual = constants::lot_size() - 1;

    place_limit_order<SUI, USDC>(
        ALICE,
        pool_id,
        balance_manager_id_alice,
        alice_client_order_id,
        constants::no_restriction(),
        constants::self_matching_allowed(),
        alice_price,
        alice_quantity,
        is_bid,
        pay_with_deep,
        expire_timestamp,
        &mut test,
    );

    place_limit_order<SUI, USDC>(
        ALICE,
        pool_id,
        balance_manager_id_alice,
        alice_client_order_id,
        constants::no_restriction(),
        constants::self_matching_allowed(),
        expired_price,
        alice_quantity,
        is_bid,
        pay_with_deep,
        expire_timestamp_e,
        &mut test,
    );

    set_time(200, &mut test);

    let base_in = if (is_bid) {
        1 * constants::float_scaling() + residual
    } else {
        0
    };
    let quote_in = if (is_bid) {
        0
    } else {
        2 * constants::float_scaling() + 2 * residual
    };
    let deep_in = math::mul(constants::deep_multiplier(), constants::taker_fee()) +
        residual;

    let (base, quote, deep_required) = get_quantity_out<SUI, USDC>(
        pool_id,
        base_in,
        quote_in,
        &mut test,
    );

    let (base_2, quote_2, deep_required_2) = if (is_bid) {
        get_quote_quantity_out<SUI, USDC>(
            pool_id,
            base_in,
            &mut test,
        )
    } else {
        get_base_quantity_out<SUI, USDC>(
            pool_id,
            quote_in,
            &mut test,
        )
    };

    let initial_bob_balances = 1000000 * constants::float_scaling();
    let bob_balance_manager_id = create_acct_and_share_with_funds(
        BOB,
        initial_bob_balances,
        &mut test,
    );
    create_caps(BOB, bob_balance_manager_id, &mut test);
    let bob_deep_balance_before = asset_balance<DEEP>(BOB, bob_balance_manager_id, &mut test);

    let (base_out, quote_out, deep_out) = if (is_bid) {
        if (with_manager) {
            let deep_out = coin::zero(test.ctx());
            let (base_out, quote_out) = place_exact_base_for_quote_with_manager<SUI, USDC>(
                pool_id,
                BOB,
                bob_balance_manager_id,
                base_in,
                0,
                &mut test,
            );

            (base_out, quote_out, deep_out)
        } else {
            place_swap_exact_base_for_quote<SUI, USDC>(
                pool_id,
                BOB,
                base_in,
                deep_in,
                0,
                &mut test,
            )
        }
    } else {
        if (with_manager) {
            let deep_out = coin::zero(test.ctx());
            let (base_out, quote_out) = place_exact_quote_for_base_with_manager<SUI, USDC>(
                pool_id,
                BOB,
                bob_balance_manager_id,
                quote_in,
                0,
                &mut test,
            );

            (base_out, quote_out, deep_out)
        } else {
            place_swap_exact_quote_for_base<SUI, USDC>(
                pool_id,
                BOB,
                quote_in,
                deep_in,
                0,
                &mut test,
            )
        }
    };
    let bob_deep_balance_after = asset_balance<DEEP>(BOB, bob_balance_manager_id, &mut test);

    if (is_bid) {
        assert!(base_out.value() == residual, constants::e_order_info_mismatch());
        assert!(
            quote_out.value() == 2 * constants::float_scaling(),
            constants::e_order_info_mismatch(),
        );
    } else {
        assert!(
            base_out.value() == 1 * constants::float_scaling(),
            constants::e_order_info_mismatch(),
        );
        assert!(quote_out.value() == 2 * residual, constants::e_order_info_mismatch());
    };

    if (with_manager) {
        assert!(
            deep_required == bob_deep_balance_before - bob_deep_balance_after,
            constants::e_order_info_mismatch(),
        );
        assert!(
            deep_required == deep_required_2 &&
            deep_required == bob_deep_balance_before - bob_deep_balance_after,
            constants::e_order_info_mismatch(),
        );
    } else {
        assert!(deep_out.value() == residual, constants::e_order_info_mismatch());
        assert!(
            deep_required == deep_required_2 &&
            deep_required == deep_in - deep_out.value(),
            constants::e_order_info_mismatch(),
        );
    };

    assert!(base == base_2 && base == base_out.value(), constants::e_order_info_mismatch());
    assert!(quote == quote_2 && quote == quote_out.value(), constants::e_order_info_mismatch());

    base_out.burn_for_testing();
    quote_out.burn_for_testing();
    deep_out.burn_for_testing();

    end(test);
}

/// Alice places a bid order, Bob places a swap_exact_amount order
/// Make sure the assets returned to Bob are correct
/// Make sure expired orders are skipped over
fun test_swap_exact_amount_with_input(is_bid: bool) {
    let mut test = begin(OWNER);
    let registry_id = setup_test(OWNER, &mut test);
    let balance_manager_id_alice = create_acct_and_share_with_funds(
        ALICE,
        1000000 * constants::float_scaling(),
        &mut test,
    );
    let pool_id = setup_pool_with_default_fees<SUI, USDC>(
        ALICE,
        registry_id,
        false,
        false,
        &mut test,
    );

    let alice_client_order_id = 1;
    let alice_price = 2 * constants::float_scaling();
    let alice_quantity = 2 * constants::float_scaling();
    let expired_price = if (is_bid) {
        3 * constants::float_scaling()
    } else {
        1 * constants::float_scaling()
    };
    let expire_timestamp = constants::max_u64();
    let expire_timestamp_e = get_time(&mut test) + 100;
    let pay_with_deep = false;
    let residual = constants::lot_size() - 1;
    let input_fee_rate = math::mul(
        constants::fee_penalty_multiplier(),
        constants::taker_fee(),
    );

    place_limit_order<SUI, USDC>(
        ALICE,
        pool_id,
        balance_manager_id_alice,
        alice_client_order_id,
        constants::no_restriction(),
        constants::self_matching_allowed(),
        alice_price,
        alice_quantity,
        is_bid,
        pay_with_deep,
        expire_timestamp,
        &mut test,
    );

    place_limit_order<SUI, USDC>(
        ALICE,
        pool_id,
        balance_manager_id_alice,
        alice_client_order_id,
        constants::no_restriction(),
        constants::self_matching_allowed(),
        expired_price,
        alice_quantity,
        is_bid,
        pay_with_deep,
        expire_timestamp_e,
        &mut test,
    );

    set_time(200, &mut test);

    let base_in = if (is_bid) {
        math::mul(1 * constants::float_scaling(), constants::float_scaling() + input_fee_rate) + residual
    } else {
        0
    };
    let quote_in = if (is_bid) {
        0
    } else {
        math::mul(2 * constants::float_scaling(),constants::float_scaling() + input_fee_rate) + 2 * residual
    };
    let deep_in = 0;

    let (base, quote, deep_required) = get_quantity_out_input_fee<SUI, USDC>(
        pool_id,
        base_in,
        quote_in,
        &mut test,
    );

    let (base_2, quote_2, deep_required_2) = if (is_bid) {
        get_quote_quantity_out_input_fee<SUI, USDC>(
            pool_id,
            base_in,
            &mut test,
        )
    } else {
        get_base_quantity_out_input_fee<SUI, USDC>(
            pool_id,
            quote_in,
            &mut test,
        )
    };

    let (base_out, quote_out, deep_out) = if (is_bid) {
        place_swap_exact_base_for_quote<SUI, USDC>(
            pool_id,
            BOB,
            base_in,
            deep_in,
            0,
            &mut test,
        )
    } else {
        place_swap_exact_quote_for_base<SUI, USDC>(
            pool_id,
            BOB,
            quote_in,
            deep_in,
            0,
            &mut test,
        )
    };

    if (is_bid) {
        assert!(base_out.value() == residual, constants::e_order_info_mismatch());
        assert!(
            quote_out.value() == 2 * constants::float_scaling(),
            constants::e_order_info_mismatch(),
        );
    } else {
        assert!(
            base_out.value() == 1 * constants::float_scaling(),
            constants::e_order_info_mismatch(),
        );
        assert!(quote_out.value() == 2 * residual, constants::e_order_info_mismatch());
    };

    assert!(deep_out.value() == 0, constants::e_order_info_mismatch());
    assert!(base == base_2 && base == base_out.value(), constants::e_order_info_mismatch());
    assert!(quote == quote_2 && quote == quote_out.value(), constants::e_order_info_mismatch());
    assert!(
        deep_required == deep_required_2 &&
        deep_required == deep_in - deep_out.value(),
        constants::e_order_info_mismatch(),
    );

    base_out.burn_for_testing();
    quote_out.burn_for_testing();
    deep_out.burn_for_testing();

    end(test);
}

fun test_get_quantity_out_zero(is_bid: bool) {
    let mut test = begin(OWNER);
    let registry_id = setup_test(OWNER, &mut test);
    let balance_manager_id_alice = create_acct_and_share_with_funds(
        ALICE,
        1000000 * constants::float_scaling(),
        &mut test,
    );
    let pool_id = setup_pool_with_default_fees_and_reference_pool<SUI, USDC, SUI, DEEP>(
        ALICE,
        registry_id,
        balance_manager_id_alice,
        &mut test,
    );

    let alice_client_order_id = 1;
    let alice_price = 2 * constants::float_scaling();
    let alice_quantity = 2 * constants::float_scaling();
    let expire_timestamp = constants::max_u64();
    let pay_with_deep = false;

    place_limit_order<SUI, USDC>(
        ALICE,
        pool_id,
        balance_manager_id_alice,
        alice_client_order_id,
        constants::no_restriction(),
        constants::self_matching_allowed(),
        alice_price,
        alice_quantity,
        is_bid,
        pay_with_deep,
        expire_timestamp,
        &mut test,
    );

    set_time(200, &mut test);

    let base_in = if (is_bid) {
        constants::min_size()
    } else {
        0
    };
    let quote_in = if (is_bid) {
        0
    } else {
        2 * constants::min_size()
    };

    let (base, quote, deep_required) = get_quantity_out_input_fee<SUI, USDC>(
        pool_id,
        base_in,
        quote_in,
        &mut test,
    );
    let expected_base = if (is_bid) {
        constants::min_size()
    } else {
        0
    };
    let expected_quote = if (is_bid) {
        0
    } else {
        2 * constants::min_size()
    };

    assert!(base == expected_base, constants::e_order_info_mismatch());
    assert!(quote == expected_quote, constants::e_order_info_mismatch());
    assert!(deep_required == 0, constants::e_order_info_mismatch());

    let (base, quote, _) = get_quantity_out<SUI, USDC>(
        pool_id,
        base_in,
        quote_in,
        &mut test,
    );

    let expected_base = if (is_bid) {
        0
    } else {
        constants::min_size()
    };
    let expected_quote = if (is_bid) {
        2 * constants::min_size()
    } else {
        0
    };

    assert!(base == expected_base, constants::e_order_info_mismatch());
    assert!(quote == expected_quote, constants::e_order_info_mismatch());

    end(test);
}

/// Alice places a bid/ask order
/// Alice then places an ask/bid order that crosses with that order with
/// cancel_taker option
/// Order should be rejected.
fun test_self_matching_cancel_taker(is_bid: bool) {
    let mut test = begin(OWNER);
    let registry_id = setup_test(OWNER, &mut test);
    let balance_manager_id_alice = create_acct_and_share_with_funds(
        ALICE,
        1000000 * constants::float_scaling(),
        &mut test,
    );
    let pool_id = setup_pool_with_default_fees_and_reference_pool<SUI, USDC, SUI, DEEP>(
        ALICE,
        registry_id,
        balance_manager_id_alice,
        &mut test,
    );

    let bid_client_order_id = 1;
    let ask_client_order_id = 2;
    let order_type = constants::no_restriction();
    let price_1 = 2 * constants::float_scaling();
    let price_2 = if (is_bid) {
        1 * constants::float_scaling()
    } else {
        3 * constants::float_scaling()
    };
    let quantity = 1 * constants::float_scaling();
    let expire_timestamp = constants::max_u64();
    let pay_with_deep = true;
    let fee_is_deep = true;

    let order_info_1 = place_limit_order<SUI, USDC>(
        ALICE,
        pool_id,
        balance_manager_id_alice,
        bid_client_order_id,
        order_type,
        constants::self_matching_allowed(),
        price_1,
        quantity,
        is_bid,
        pay_with_deep,
        expire_timestamp,
        &mut test,
    );

    verify_order_info(
        &order_info_1,
        bid_client_order_id,
        price_1,
        quantity,
        0,
        0,
        0,
        fee_is_deep,
        constants::live(),
        expire_timestamp,
    );

    place_limit_order<SUI, USDC>(
        ALICE,
        pool_id,
        balance_manager_id_alice,
        ask_client_order_id,
        order_type,
        constants::cancel_taker(),
        price_2,
        quantity,
        !is_bid,
        pay_with_deep,
        expire_timestamp,
        &mut test,
    );

    end(test);
}

/// Alice places a bid/ask order
/// Alice then places an ask/bid order that crosses with that order with
/// cancel_maker option
/// Maker order should be removed, with the new order placed successfully.
fun test_self_matching_cancel_maker(is_bid: bool) {
    let mut test = begin(OWNER);
    let registry_id = setup_test(OWNER, &mut test);
    let balance_manager_id_alice = create_acct_and_share_with_funds(
        ALICE,
        1000000 * constants::float_scaling(),
        &mut test,
    );
    let pool_id = setup_pool_with_default_fees_and_reference_pool<SUI, USDC, SUI, DEEP>(
        ALICE,
        registry_id,
        balance_manager_id_alice,
        &mut test,
    );

    let client_order_id_1 = 1;
    let client_order_id_2 = 2;
    let order_type = constants::no_restriction();
    let price_1 = 2 * constants::float_scaling();
    let price_2 = if (is_bid) {
        1 * constants::float_scaling()
    } else {
        3 * constants::float_scaling()
    };
    let quantity = 1 * constants::float_scaling();
    let expire_timestamp = constants::max_u64();
    let pay_with_deep = true;
    let fee_is_deep = true;

    let order_info_1 = place_limit_order<SUI, USDC>(
        ALICE,
        pool_id,
        balance_manager_id_alice,
        client_order_id_1,
        order_type,
        constants::self_matching_allowed(),
        price_1,
        quantity,
        is_bid,
        pay_with_deep,
        expire_timestamp,
        &mut test,
    );

    verify_order_info(
        &order_info_1,
        client_order_id_1,
        price_1,
        quantity,
        0,
        0,
        0,
        fee_is_deep,
        constants::live(),
        expire_timestamp,
    );

    let order_info_2 = place_limit_order<SUI, USDC>(
        ALICE,
        pool_id,
        balance_manager_id_alice,
        client_order_id_2,
        order_type,
        constants::cancel_maker(),
        price_2,
        quantity,
        !is_bid,
        pay_with_deep,
        expire_timestamp,
        &mut test,
    );

    verify_order_info(
        &order_info_2,
        client_order_id_2,
        price_2,
        quantity,
        0,
        0,
        0,
        fee_is_deep,
        constants::live(),
        expire_timestamp,
    );

    borrow_order_ok<SUI, USDC>(
        pool_id,
        order_info_1.order_id(),
        &mut test,
    );

    end(test);
}

fun place_with_price_quantity(price: u64, quantity: u64) {
    let mut test = begin(OWNER);
    let registry_id = setup_test(OWNER, &mut test);
    let balance_manager_id_alice = create_acct_and_share_with_funds(
        ALICE,
        1000000 * constants::float_scaling(),
        &mut test,
    );
    let pool_id = setup_pool_with_default_fees_and_reference_pool<SUI, USDC, SUI, DEEP>(
        ALICE,
        registry_id,
        balance_manager_id_alice,
        &mut test,
    );

    let client_order_id = 1;
    let order_type = constants::no_restriction();
    let expire_timestamp = constants::max_u64();
    let pay_with_deep = true;

    place_limit_order<SUI, USDC>(
        ALICE,
        pool_id,
        balance_manager_id_alice,
        client_order_id,
        order_type,
        constants::self_matching_allowed(),
        price,
        quantity,
        true,
        pay_with_deep,
        expire_timestamp,
        &mut test,
    );
    end(test);
}

fun partially_filled_order_taken(is_bid: bool) {
    let mut test = begin(OWNER);
    let registry_id = setup_test(OWNER, &mut test);
    let balance_manager_id_alice = create_acct_and_share_with_funds(
        ALICE,
        1000000 * constants::float_scaling(),
        &mut test,
    );
    let pool_id = setup_pool_with_default_fees_and_reference_pool<SUI, USDC, SUI, DEEP>(
        ALICE,
        registry_id,
        balance_manager_id_alice,
        &mut test,
    );
    let balance_manager_id_bob = create_acct_and_share_with_funds(
        BOB,
        1000000 * constants::float_scaling(),
        &mut test,
    );

    let alice_client_order_id = 1;
    let alice_price_1 = 3 * constants::float_scaling();
    let alice_price_2 = if (is_bid) {
        2 * constants::float_scaling()
    } else {
        4 * constants::float_scaling()
    };
    let alice_quantity_1 = 2 * constants::float_scaling();
    let alice_quantity_2 = 10 * constants::float_scaling();
    let expire_timestamp = constants::max_u64();
    let pay_with_deep = true;

    // Alice places an initial order with quantity 2
    place_limit_order<SUI, USDC>(
        ALICE,
        pool_id,
        balance_manager_id_alice,
        alice_client_order_id,
        constants::no_restriction(),
        constants::self_matching_allowed(),
        alice_price_1,
        alice_quantity_1,
        is_bid,
        pay_with_deep,
        expire_timestamp,
        &mut test,
    );

    // Alice places a crossing order of quantity 10, 2 is filled and 8 is placed
    // on book
    let alice_order_info_2 = place_limit_order<SUI, USDC>(
        ALICE,
        pool_id,
        balance_manager_id_alice,
        alice_client_order_id,
        constants::no_restriction(),
        constants::self_matching_allowed(),
        alice_price_2,
        alice_quantity_2,
        !is_bid,
        pay_with_deep,
        expire_timestamp,
        &mut test,
    );

    verify_order_info(
        &alice_order_info_2,
        alice_client_order_id,
        alice_price_2,
        alice_quantity_2,
        alice_quantity_1,
        math::mul(alice_quantity_1, alice_price_1),
        math::mul(
            alice_quantity_1,
            math::mul(constants::taker_fee(), constants::deep_multiplier()),
        ),
        pay_with_deep,
        constants::partially_filled(),
        expire_timestamp,
    );

    let bob_client_order_id = 2;
    let bob_price = 3 * constants::float_scaling();
    let bob_quantity = 10 * constants::float_scaling();

    // Bob places another crossing order of quantity 10, 8 is filled and 2 is
    // placed on book
    let bob_order_info = place_limit_order<SUI, USDC>(
        BOB,
        pool_id,
        balance_manager_id_bob,
        bob_client_order_id,
        constants::no_restriction(),
        constants::self_matching_allowed(),
        bob_price,
        bob_quantity,
        is_bid,
        pay_with_deep,
        expire_timestamp,
        &mut test,
    );

    // Bob should have quantity 8 executed by crossing Alice's order
    verify_order_info(
        &bob_order_info,
        bob_client_order_id,
        bob_price,
        bob_quantity,
        8 * constants::float_scaling(),
        8 * alice_price_2,
        math::mul(
            8 * constants::float_scaling(),
            math::mul(constants::taker_fee(), constants::deep_multiplier()),
        ),
        pay_with_deep,
        constants::partially_filled(),
        expire_timestamp,
    );

    end(test);
}

fun partial_fill_order(
    is_bid: bool,
    order_type: u8,
    alice_quantity: u64,
    expected_executed_quantity: u64,
    expected_cumulative_quote_quantity: u64,
    expected_paid_fees: u64,
    expected_status: u8,
) {
    let mut test = begin(OWNER);
    let registry_id = setup_test(OWNER, &mut test);
    let balance_manager_id_alice = create_acct_and_share_with_funds(
        ALICE,
        1000000 * constants::float_scaling(),
        &mut test,
    );
    let pool_id = setup_pool_with_default_fees_and_reference_pool<SUI, USDC, SUI, DEEP>(
        ALICE,
        registry_id,
        balance_manager_id_alice,
        &mut test,
    );
    let balance_manager_id_bob = create_acct_and_share_with_funds(
        BOB,
        1000000 * constants::float_scaling(),
        &mut test,
    );

    let alice_client_order_id = 1;
    let alice_price = 2 * constants::float_scaling();
    let expire_timestamp = constants::max_u64();
    let pay_with_deep = true;

    place_limit_order<SUI, USDC>(
        ALICE,
        pool_id,
        balance_manager_id_alice,
        alice_client_order_id,
        constants::no_restriction(),
        constants::self_matching_allowed(),
        alice_price,
        alice_quantity,
        is_bid,
        pay_with_deep,
        expire_timestamp,
        &mut test,
    );

    let bob_client_order_id = 2;
    let bob_price = 2 * constants::float_scaling();
    let bob_quantity = 2 * alice_quantity;

    let bob_order_info = place_limit_order<SUI, USDC>(
        BOB,
        pool_id,
        balance_manager_id_bob,
        bob_client_order_id,
        order_type,
        constants::self_matching_allowed(),
        bob_price,
        bob_quantity,
        !is_bid,
        pay_with_deep,
        expire_timestamp,
        &mut test,
    );

    let fee_is_deep = true;

    verify_order_info(
        &bob_order_info,
        bob_client_order_id,
        bob_price,
        bob_quantity,
        expected_executed_quantity,
        expected_cumulative_quote_quantity,
        expected_paid_fees,
        fee_is_deep,
        expected_status,
        expire_timestamp,
    );

    borrow_order_ok<SUI, USDC>(
        pool_id,
        bob_order_info.order_id(),
        &mut test,
    );

    end(test);
}

fun partial_fill_maker_order(
    is_bid: bool,
    order_type: u8,
    alice_quantity: u64,
    expected_executed_quantity: u64,
    expected_cumulative_quote_quantity: u64,
    expected_paid_fees: u64,
    expected_status: u8,
) {
    let mut test = begin(OWNER);
    let registry_id = setup_test(OWNER, &mut test);
    let balance_manager_id_alice = create_acct_and_share_with_funds(
        ALICE,
        1000000 * constants::float_scaling(),
        &mut test,
    );
    let pool_id = setup_pool_with_default_fees_and_reference_pool<SUI, USDC, SUI, DEEP>(
        ALICE,
        registry_id,
        balance_manager_id_alice,
        &mut test,
    );
    let balance_manager_id_bob = create_acct_and_share_with_funds(
        BOB,
        1000000 * constants::float_scaling(),
        &mut test,
    );

    let alice_client_order_id = 1;
    let alice_price = 2 * constants::float_scaling();
    let expire_timestamp = constants::max_u64();
    let pay_with_deep = true;

    place_limit_order<SUI, USDC>(
        ALICE,
        pool_id,
        balance_manager_id_alice,
        alice_client_order_id,
        constants::no_restriction(),
        constants::self_matching_allowed(),
        alice_price,
        alice_quantity,
        is_bid,
        pay_with_deep,
        expire_timestamp,
        &mut test,
    );

    // Half of Alice's maker order is filled
    place_limit_order<SUI, USDC>(
        ALICE,
        pool_id,
        balance_manager_id_alice,
        alice_client_order_id,
        constants::no_restriction(),
        constants::self_matching_allowed(),
        alice_price,
        alice_quantity / 2,
        !is_bid,
        pay_with_deep,
        expire_timestamp,
        &mut test,
    );

    let bob_client_order_id = 2;
    let bob_price = 2 * constants::float_scaling();
    let bob_quantity = 2 * alice_quantity;

    let bob_order_info = place_limit_order<SUI, USDC>(
        BOB,
        pool_id,
        balance_manager_id_bob,
        bob_client_order_id,
        order_type,
        constants::self_matching_allowed(),
        bob_price,
        bob_quantity,
        !is_bid,
        pay_with_deep,
        expire_timestamp,
        &mut test,
    );

    let fee_is_deep = true;

    verify_order_info(
        &bob_order_info,
        bob_client_order_id,
        bob_price,
        bob_quantity,
        expected_executed_quantity,
        expected_cumulative_quote_quantity,
        expected_paid_fees,
        fee_is_deep,
        expected_status,
        expire_timestamp,
    );

    borrow_order_ok<SUI, USDC>(
        pool_id,
        bob_order_info.order_id(),
        &mut test,
    );

    end(test);
}

/// Place normal ask order, then try to fill full order.
/// Alice places first order, Bob places second order.
fun place_then_fill(
    is_stable: bool,
    is_bid: bool,
    order_type: u8,
    alice_quantity: u64,
    expected_executed_quantity: u64,
    expected_cumulative_quote_quantity: u64,
    expected_paid_fees: u64,
    expected_status: u8,
) {
    let mut test = begin(OWNER);
    let registry_id = setup_test(OWNER, &mut test);
    let balance_manager_id_alice = create_acct_and_share_with_funds(
        ALICE,
        1000000 * constants::float_scaling(),
        &mut test,
    );
    let pool_id = if (is_stable) {
        setup_pool_with_stable_fees_and_reference_pool<SUI, USDC, SUI, DEEP>(
            ALICE,
            registry_id,
            balance_manager_id_alice,
            &mut test,
        )
    } else {
        setup_pool_with_default_fees_and_reference_pool<SUI, USDC, SUI, DEEP>(
            ALICE,
            registry_id,
            balance_manager_id_alice,
            &mut test,
        )
    };
    let balance_manager_id_bob = create_acct_and_share_with_funds(
        BOB,
        1000000 * constants::float_scaling(),
        &mut test,
    );

    let alice_client_order_id = 1;
    let alice_price = 2 * constants::float_scaling();
    let expire_timestamp = constants::max_u64();
    let pay_with_deep = true;

    place_limit_order<SUI, USDC>(
        ALICE,
        pool_id,
        balance_manager_id_alice,
        alice_client_order_id,
        constants::no_restriction(),
        constants::self_matching_allowed(),
        alice_price,
        alice_quantity,
        is_bid,
        pay_with_deep,
        expire_timestamp,
        &mut test,
    );

    let bob_client_order_id = 2;
    let bob_price = if (is_bid) {
        1 * constants::float_scaling()
    } else {
        3 * constants::float_scaling()
    };
    let bob_quantity = alice_quantity;

    let bob_order_info = place_limit_order<SUI, USDC>(
        BOB,
        pool_id,
        balance_manager_id_bob,
        bob_client_order_id,
        order_type,
        constants::self_matching_allowed(),
        bob_price,
        bob_quantity,
        !is_bid,
        pay_with_deep,
        expire_timestamp,
        &mut test,
    );

    let expire_timestamp = constants::max_u64();
    let fee_is_deep = true;

    verify_order_info(
        &bob_order_info,
        bob_client_order_id,
        bob_price,
        bob_quantity,
        expected_executed_quantity,
        expected_cumulative_quote_quantity,
        expected_paid_fees,
        fee_is_deep,
        expected_status,
        expire_timestamp,
    );
    end(test);
}

/// Place normal ask order, then try to fill full order.
/// Alice places first order, Bob places second order.
fun place_then_fill_correct(is_bid: bool, order_type: u8, alice_quantity: u64) {
    let mut test = begin(OWNER);
    let registry_id = setup_test(OWNER, &mut test);
    let balance_manager_id_alice = create_acct_and_share_with_funds(
        ALICE,
        1000000 * constants::float_scaling(),
        &mut test,
    );
    let pool_id = setup_pool_with_default_fees_and_reference_pool<SUI, USDC, SUI, DEEP>(
        ALICE,
        registry_id,
        balance_manager_id_alice,
        &mut test,
    );
    let balance_manager_id_bob = create_acct_and_share_with_funds(
        BOB,
        1000000 * constants::float_scaling(),
        &mut test,
    );

    let alice_client_order_id = 1;
    let alice_price = 2 * constants::float_scaling();
    let expire_timestamp = constants::max_u64();
    let pay_with_deep = true;

    place_limit_order<SUI, USDC>(
        ALICE,
        pool_id,
        balance_manager_id_alice,
        alice_client_order_id,
        constants::no_restriction(),
        constants::self_matching_allowed(),
        alice_price,
        alice_quantity / 2,
        is_bid,
        pay_with_deep,
        expire_timestamp,
        &mut test,
    );

    place_limit_order<SUI, USDC>(
        ALICE,
        pool_id,
        balance_manager_id_alice,
        alice_client_order_id,
        constants::no_restriction(),
        constants::self_matching_allowed(),
        alice_price,
        alice_quantity,
        is_bid,
        pay_with_deep,
        expire_timestamp,
        &mut test,
    );

    let bob_client_order_id = 2;
    let bob_price = if (is_bid) {
        1 * constants::float_scaling()
    } else {
        3 * constants::float_scaling()
    };
    let bob_quantity = alice_quantity * 2;

    let mut bob_order_info = place_limit_order<SUI, USDC>(
        BOB,
        pool_id,
        balance_manager_id_bob,
        bob_client_order_id,
        order_type,
        constants::self_matching_allowed(),
        bob_price,
        bob_quantity,
        !is_bid,
        pay_with_deep,
        expire_timestamp,
        &mut test,
    );

    let fills = bob_order_info.fills_ref();
    let fill_0 = &fills[0];
    verify_fill(
        fill_0,
        alice_quantity / 2,
        math::mul(alice_quantity / 2, alice_price),
        math::mul(
            constants::deep_multiplier(),
            math::mul(alice_quantity, constants::taker_fee()),
        ) /
        2,
        math::mul(
            constants::deep_multiplier(),
            math::mul(alice_quantity, constants::maker_fee()),
        ) /
        2,
    );
    let fill_1 = &fills[1];
    verify_fill(
        fill_1,
        alice_quantity,
        math::mul(alice_quantity, alice_price),
        math::mul(
            constants::deep_multiplier(),
            math::mul(alice_quantity, constants::taker_fee()),
        ),
        math::mul(
            constants::deep_multiplier(),
            math::mul(alice_quantity, constants::maker_fee()),
        ),
    );

    end(test);
}

/// Place normal ask order, then try to place without filling.
/// Alice places first order, Bob places second order.
fun place_then_no_fill(
    is_bid: bool,
    order_type: u8,
    expected_executed_quantity: u64,
    expected_cumulative_quote_quantity: u64,
    expected_paid_fees: u64,
    expected_status: u8,
) {
    let mut test = begin(OWNER);
    let registry_id = setup_test(OWNER, &mut test);
    let balance_manager_id_alice = create_acct_and_share_with_funds(
        ALICE,
        1000000 * constants::float_scaling(),
        &mut test,
    );
    let pool_id = setup_pool_with_default_fees_and_reference_pool<SUI, USDC, SUI, DEEP>(
        ALICE,
        registry_id,
        balance_manager_id_alice,
        &mut test,
    );
    let balance_manager_id_bob = create_acct_and_share_with_funds(
        BOB,
        1000000 * constants::float_scaling(),
        &mut test,
    );

    let client_order_id = 1;
    let price = 2 * constants::float_scaling();
    let quantity = 1 * constants::float_scaling();
    let expire_timestamp = constants::max_u64();
    let pay_with_deep = true;

    place_limit_order<SUI, USDC>(
        ALICE,
        pool_id,
        balance_manager_id_alice,
        client_order_id,
        constants::no_restriction(),
        constants::self_matching_allowed(),
        price,
        quantity,
        is_bid,
        pay_with_deep,
        expire_timestamp,
        &mut test,
    );

    let client_order_id = 2;
    let price = if (is_bid) {
        3 * constants::float_scaling()
    } else {
        1 * constants::float_scaling()
    };

    let order_info = place_limit_order<SUI, USDC>(
        BOB,
        pool_id,
        balance_manager_id_bob,
        client_order_id,
        order_type,
        constants::self_matching_allowed(),
        price,
        quantity,
        !is_bid,
        pay_with_deep,
        expire_timestamp,
        &mut test,
    );

    let quantity = 1 * constants::float_scaling();
    let expire_timestamp = constants::max_u64();
    let fee_is_deep = true;

    verify_order_info(
        &order_info,
        client_order_id,
        price,
        quantity,
        expected_executed_quantity,
        expected_cumulative_quote_quantity,
        expected_paid_fees,
        fee_is_deep,
        expected_status,
        expire_timestamp,
    );

    cancel_order<SUI, USDC>(
        BOB,
        pool_id,
        balance_manager_id_bob,
        order_info.order_id(),
        &mut test,
    );
    end(test);
}

/// Trying to fill an order that's expired on the book should remove order.
/// New order should be placed successfully.
/// Old order no longer exists.
fun place_order_expire_timestamp_e(
    is_bid: bool,
    order_type: u8,
    expected_executed_quantity: u64,
    expected_cumulative_quote_quantity: u64,
    expected_paid_fees: u64,
    expected_status: u8,
) {
    let mut test = begin(OWNER);
    let registry_id = setup_test(OWNER, &mut test);
    let balance_manager_id_alice = create_acct_and_share_with_funds(
        ALICE,
        1000000 * constants::float_scaling(),
        &mut test,
    );
    let pool_id = setup_pool_with_default_fees_and_reference_pool<SUI, USDC, SUI, DEEP>(
        ALICE,
        registry_id,
        balance_manager_id_alice,
        &mut test,
    );
    let balance_manager_id_bob = create_acct_and_share_with_funds(
        BOB,
        1000000 * constants::float_scaling(),
        &mut test,
    );

    let client_order_id = 1;
    let price = 2 * constants::float_scaling();
    let quantity = 1 * constants::float_scaling();
    let pay_with_deep = true;
    let fee_is_deep = true;
    let expire_timestamp = get_time(&mut test) + 100;

    let order_info_alice = place_limit_order<SUI, USDC>(
        ALICE,
        pool_id,
        balance_manager_id_alice,
        client_order_id,
        constants::no_restriction(),
        constants::self_matching_allowed(),
        price,
        quantity,
        is_bid,
        pay_with_deep,
        expire_timestamp,
        &mut test,
    );

    set_time(200, &mut test);
    verify_order_info(
        &order_info_alice,
        client_order_id,
        price,
        quantity,
        expected_executed_quantity,
        expected_cumulative_quote_quantity,
        expected_paid_fees,
        fee_is_deep,
        expected_status,
        expire_timestamp,
    );

    let client_order_id = 2;
    let price = if (is_bid) {
        1 * constants::float_scaling()
    } else {
        3 * constants::float_scaling()
    };
    let expire_timestamp = constants::max_u64();

    let order_info_bob = place_limit_order<SUI, USDC>(
        BOB,
        pool_id,
        balance_manager_id_bob,
        client_order_id,
        order_type,
        constants::self_matching_allowed(),
        price,
        quantity,
        !is_bid,
        pay_with_deep,
        expire_timestamp,
        &mut test,
    );

    let quantity = 1 * constants::float_scaling();
    let expire_timestamp = constants::max_u64();

    verify_order_info(
        &order_info_bob,
        client_order_id,
        price,
        quantity,
        expected_executed_quantity,
        expected_cumulative_quote_quantity,
        expected_paid_fees,
        fee_is_deep,
        expected_status,
        expire_timestamp,
    );

    borrow_and_verify_book_order<SUI, USDC>(
        pool_id,
        order_info_bob.order_id(),
        !is_bid,
        client_order_id,
        quantity,
        expected_executed_quantity,
        order_info_bob.order_deep_price().deep_per_asset(),
        test.ctx().epoch(),
        expected_status,
        expire_timestamp,
        &mut test,
    );

    borrow_order_ok<SUI, USDC>(
        pool_id,
        order_info_alice.order_id(),
        &mut test,
    );
    end(test);
}

/// Test to place a limit order, verify the order info and order in the book
fun place_order_ok(is_bid: bool) {
    let mut test = begin(OWNER);
    let registry_id = setup_test(OWNER, &mut test);
    let balance_manager_id_alice = create_acct_and_share_with_funds(
        ALICE,
        1000000 * constants::float_scaling(),
        &mut test,
    );
    let pool_id = setup_pool_with_default_fees_and_reference_pool<SUI, USDC, SUI, DEEP>(
        ALICE,
        registry_id,
        balance_manager_id_alice,
        &mut test,
    );

    validate_open_orders<SUI, USDC>(
        ALICE,
        pool_id,
        balance_manager_id_alice,
        0,
        &mut test,
    );
    // variables to input into order
    let client_order_id = 1;
    let order_type = constants::no_restriction();
    let price = 2 * constants::float_scaling();
    let quantity = 1 * constants::float_scaling();
    let expire_timestamp = constants::max_u64();

    // variables expected from OrderInfo and Order
    let status = constants::live();
    let executed_quantity = 0;
    let cumulative_quote_quantity = 0;
    let paid_fees = 0;
    let fee_is_deep = true;
    let pay_with_deep = true;

    let order_info =
        &place_limit_order<SUI, USDC>(
            ALICE,
            pool_id,
            balance_manager_id_alice,
            client_order_id,
            order_type,
            constants::self_matching_allowed(),
            price,
            quantity,
            is_bid,
            pay_with_deep,
            expire_timestamp,
            &mut test,
        );

    verify_order_info(
        order_info,
        client_order_id,
        price,
        quantity,
        executed_quantity,
        cumulative_quote_quantity,
        paid_fees,
        fee_is_deep,
        status,
        expire_timestamp,
    );

    borrow_and_verify_book_order<SUI, USDC>(
        pool_id,
        order_info.order_id(),
        is_bid,
        client_order_id,
        quantity,
        executed_quantity,
        order_info.order_deep_price().deep_per_asset(),
        test.ctx().epoch(),
        status,
        expire_timestamp,
        &mut test,
    );
    validate_open_orders<SUI, USDC>(
        ALICE,
        pool_id,
        balance_manager_id_alice,
        1,
        &mut test,
    );
    end(test);
}

/// Test placing and cancelling a limit order.
fun place_and_cancel_order_ok(is_bid: bool) {
    let mut test = begin(OWNER);
    let registry_id = setup_test(OWNER, &mut test);
    let balance_manager_id_alice = create_acct_and_share_with_funds(
        ALICE,
        1000000 * constants::float_scaling(),
        &mut test,
    );
    let pool_id = setup_pool_with_default_fees_and_reference_pool<SUI, USDC, SUI, DEEP>(
        ALICE,
        registry_id,
        balance_manager_id_alice,
        &mut test,
    );

    // variables to input into order
    let client_order_id = 1;
    let order_type = constants::no_restriction();
    let price = 2 * constants::float_scaling();
    let quantity = 1 * constants::float_scaling();
    let expire_timestamp = constants::max_u64();
    let pay_with_deep = true;
    let executed_quantity = 0;
    let cumulative_quote_quantity = 0;
    let paid_fees = 0;
    let fee_is_deep = true;
    let status = constants::live();

    let order_info = place_limit_order<SUI, USDC>(
        ALICE,
        pool_id,
        balance_manager_id_alice,
        client_order_id,
        order_type,
        constants::self_matching_allowed(),
        price,
        quantity,
        is_bid,
        pay_with_deep,
        expire_timestamp,
        &mut test,
    );

    verify_order_info(
        &order_info,
        client_order_id,
        price,
        quantity,
        executed_quantity,
        cumulative_quote_quantity,
        paid_fees,
        fee_is_deep,
        status,
        expire_timestamp,
    );

    cancel_order<SUI, USDC>(
        ALICE,
        pool_id,
        balance_manager_id_alice,
        order_info.order_id(),
        &mut test,
    );
    end(test);
}

/// Helper, verify OrderInfo fields
fun verify_order_info(
    order_info: &OrderInfo,
    client_order_id: u64,
    price: u64,
    original_quantity: u64,
    executed_quantity: u64,
    cumulative_quote_quantity: u64,
    paid_fees: u64,
    fee_is_deep: bool,
    status: u8,
    expire_timestamp: u64,
) {
    assert!(order_info.client_order_id() == client_order_id, constants::e_order_info_mismatch());
    assert!(order_info.price() == price, constants::e_order_info_mismatch());
    assert!(
        order_info.original_quantity() == original_quantity,
        constants::e_order_info_mismatch(),
    );
    assert!(
        order_info.executed_quantity() == executed_quantity,
        constants::e_order_info_mismatch(),
    );
    assert!(
        order_info.cumulative_quote_quantity() == cumulative_quote_quantity,
        constants::e_order_info_mismatch(),
    );
    assert!(order_info.paid_fees() == paid_fees, constants::e_order_info_mismatch());
    assert!(order_info.fee_is_deep() == fee_is_deep, constants::e_order_info_mismatch());
    assert!(order_info.status() == status, constants::e_order_info_mismatch());
    assert!(order_info.expire_timestamp() == expire_timestamp, constants::e_order_info_mismatch());
}

fun verify_fill(
    fill: &Fill,
    base_quantity: u64,
    quote_quantity: u64,
    taker_fee: u64,
    maker_fee: u64,
) {
    assert!(fill.base_quantity() == base_quantity, constants::e_fill_mismatch());
    assert!(fill.quote_quantity() == quote_quantity, constants::e_fill_mismatch());
    assert!(fill.taker_fee() == taker_fee, constants::e_fill_mismatch());
    assert!(fill.maker_fee() == maker_fee, constants::e_fill_mismatch());
}

/// Helper, borrow orderbook and verify an order.
fun borrow_and_verify_book_order<BaseAsset, QuoteAsset>(
    pool_id: ID,
    book_order_id: u128,
    is_bid: bool,
    client_order_id: u64,
    quantity: u64,
    filled_quantity: u64,
    deep_per_asset: u64,
    epoch: u64,
    status: u8,
    expire_timestamp: u64,
    test: &mut Scenario,
) {
    test.next_tx(@0x1);
    let pool = test.take_shared_by_id<Pool<BaseAsset, QuoteAsset>>(pool_id);
    let order = borrow_orderbook(&pool, is_bid).borrow(book_order_id);
    verify_book_order(
        order,
        book_order_id,
        client_order_id,
        quantity,
        filled_quantity,
        deep_per_asset,
        epoch,
        status,
        expire_timestamp,
    );
    return_shared(pool);
}

/// Internal function to borrow orderbook to ensure order exists
fun borrow_order_ok<BaseAsset, QuoteAsset>(pool_id: ID, book_order_id: u128, test: &mut Scenario) {
    test.next_tx(@0x1);
    let pool = test.take_shared_by_id<Pool<BaseAsset, QuoteAsset>>(pool_id);
    let (is_bid, _, _) = utils::decode_order_id(book_order_id);
    borrow_orderbook(&pool, is_bid).borrow(book_order_id);
    return_shared(pool);
}

/// Internal function to verifies an order in the book
fun verify_book_order(
    order: &Order,
    book_order_id: u128,
    client_order_id: u64,
    quantity: u64,
    filled_quantity: u64,
    deep_per_asset: u64,
    epoch: u64,
    status: u8,
    expire_timestamp: u64,
) {
    assert!(order.order_id() == book_order_id, constants::e_book_order_mismatch());
    assert!(order.client_order_id() == client_order_id, constants::e_book_order_mismatch());
    assert!(order.quantity() == quantity, constants::e_book_order_mismatch());
    assert!(order.filled_quantity() == filled_quantity, constants::e_book_order_mismatch());
    assert!(
        order.order_deep_price().deep_per_asset() == deep_per_asset,
        constants::e_book_order_mismatch(),
    );
    assert!(order.epoch() == epoch, constants::e_book_order_mismatch());
    assert!(order.status() == status, constants::e_book_order_mismatch());
    assert!(order.expire_timestamp() == expire_timestamp, constants::e_book_order_mismatch());
}

/// Internal function to borrow orderbook
fun borrow_orderbook<BaseAsset, QuoteAsset>(
    pool: &Pool<BaseAsset, QuoteAsset>,
    is_bid: bool,
): &BigVector<Order> {
    let orderbook = if (is_bid) {
        pool.load_inner().bids()
    } else {
        pool.load_inner().asks()
    };
    orderbook
}

/// Place swap exact amount order
fun place_swap_exact_base_for_quote<BaseAsset, QuoteAsset>(
    pool_id: ID,
    trader: address,
    base_in: u64,
    deep_in: u64,
    min_quote_out: u64,
    test: &mut Scenario,
): (Coin<BaseAsset>, Coin<QuoteAsset>, Coin<DEEP>) {
    test.next_tx(trader);
    {
        let mut pool = test.take_shared_by_id<Pool<BaseAsset, QuoteAsset>>(
            pool_id,
        );
        let clock = test.take_shared<Clock>();

        // Place order in pool
        let (base_out, quote_out, deep_out) = pool.swap_exact_base_for_quote<BaseAsset, QuoteAsset>(
            mint_for_testing<BaseAsset>(base_in, test.ctx()),
            mint_for_testing<DEEP>(deep_in, test.ctx()),
            min_quote_out,
            &clock,
            test.ctx(),
        );
        return_shared(pool);
        return_shared(clock);

        (base_out, quote_out, deep_out)
    }
}

fun place_exact_base_for_quote_with_manager<BaseAsset, QuoteAsset>(
    pool_id: ID,
    trader: address,
    balance_manager_id: ID,
    base_in: u64,
    min_quote_out: u64,
    test: &mut Scenario,
): (Coin<BaseAsset>, Coin<QuoteAsset>) {
    test.next_tx(trader);
    {
        let mut pool = test.take_shared_by_id<Pool<BaseAsset, QuoteAsset>>(
            pool_id,
        );
        let clock = test.take_shared<Clock>();
        let mut balance_manager = test.take_shared_by_id<BalanceManager>(
            balance_manager_id,
        );
        let trade_cap = test.take_from_sender<TradeCap>();
        let deposit_cap = test.take_from_sender<DepositCap>();
        let withdraw_cap = test.take_from_sender<WithdrawCap>();

        // Place order in pool
        let (base_out, quote_out) = pool.swap_exact_base_for_quote_with_manager<
            BaseAsset,
            QuoteAsset,
        >(
            &mut balance_manager,
            &trade_cap,
            &deposit_cap,
            &withdraw_cap,
            mint_for_testing<BaseAsset>(base_in, test.ctx()),
            min_quote_out,
            &clock,
            test.ctx(),
        );

        return_shared(pool);
        return_shared(clock);
        return_shared(balance_manager);
        test.return_to_sender(trade_cap);
        test.return_to_sender(deposit_cap);
        test.return_to_sender(withdraw_cap);

        (base_out, quote_out)
    }
}

fun place_swap_exact_quote_for_base<BaseAsset, QuoteAsset>(
    pool_id: ID,
    trader: address,
    quote_in: u64,
    deep_in: u64,
    min_base_out: u64,
    test: &mut Scenario,
): (Coin<BaseAsset>, Coin<QuoteAsset>, Coin<DEEP>) {
    test.next_tx(trader);
    {
        let mut pool = test.take_shared_by_id<Pool<BaseAsset, QuoteAsset>>(
            pool_id,
        );
        let clock = test.take_shared<Clock>();

        // Place order in pool
        let (base_out, quote_out, deep_out) = pool.swap_exact_quote_for_base<BaseAsset, QuoteAsset>(
            mint_for_testing<QuoteAsset>(quote_in, test.ctx()),
            mint_for_testing<DEEP>(deep_in, test.ctx()),
            min_base_out,
            &clock,
            test.ctx(),
        );
        return_shared(pool);
        return_shared(clock);

        (base_out, quote_out, deep_out)
    }
}

fun place_exact_quote_for_base_with_manager<BaseAsset, QuoteAsset>(
    pool_id: ID,
    trader: address,
    balance_manager_id: ID,
    quote_in: u64,
    min_base_out: u64,
    test: &mut Scenario,
): (Coin<BaseAsset>, Coin<QuoteAsset>) {
    test.next_tx(trader);
    {
        let mut pool = test.take_shared_by_id<Pool<BaseAsset, QuoteAsset>>(
            pool_id,
        );
        let clock = test.take_shared<Clock>();
        let mut balance_manager = test.take_shared_by_id<BalanceManager>(
            balance_manager_id,
        );
        let trade_cap = test.take_from_sender<TradeCap>();
        let deposit_cap = test.take_from_sender<DepositCap>();
        let withdraw_cap = test.take_from_sender<WithdrawCap>();

        // Place order in pool
        let (base_out, quote_out) = pool.swap_exact_quote_for_base_with_manager<
            BaseAsset,
            QuoteAsset,
        >(
            &mut balance_manager,
            &trade_cap,
            &deposit_cap,
            &withdraw_cap,
            mint_for_testing<QuoteAsset>(quote_in, test.ctx()),
            min_base_out,
            &clock,
            test.ctx(),
        );

        return_shared(pool);
        return_shared(clock);
        return_shared(balance_manager);
        test.return_to_sender(trade_cap);
        test.return_to_sender(deposit_cap);
        test.return_to_sender(withdraw_cap);

        (base_out, quote_out)
    }
}

fun cancel_orders<BaseAsset, QuoteAsset>(
    sender: address,
    pool_id: ID,
    balance_manager_id: ID,
    order_ids: vector<u128>,
    test: &mut Scenario,
) {
    test.next_tx(sender);
    {
        let mut pool = test.take_shared_by_id<Pool<BaseAsset, QuoteAsset>>(
            pool_id,
        );
        let clock = test.take_shared<Clock>();
        let mut balance_manager = test.take_shared_by_id<BalanceManager>(
            balance_manager_id,
        );
        let trade_proof = balance_manager.generate_proof_as_owner(test.ctx());

        pool.cancel_orders<BaseAsset, QuoteAsset>(
            &mut balance_manager,
            &trade_proof,
            order_ids,
            &clock,
            test.ctx(),
        );
        return_shared(pool);
        return_shared(clock);
        return_shared(balance_manager);
    }
}

fun cancel_all_orders<BaseAsset, QuoteAsset>(
    pool_id: ID,
    owner: address,
    balance_manager_id: ID,
    test: &mut Scenario,
) {
    test.next_tx(owner);
    {
        let mut pool = test.take_shared_by_id<Pool<BaseAsset, QuoteAsset>>(
            pool_id,
        );
        let clock = test.take_shared<Clock>();
        let mut balance_manager = test.take_shared_by_id<BalanceManager>(
            balance_manager_id,
        );
        let trade_proof = balance_manager.generate_proof_as_owner(test.ctx());

        pool.cancel_all_orders<BaseAsset, QuoteAsset>(
            &mut balance_manager,
            &trade_proof,
            &clock,
            test.ctx(),
        );
        return_shared(pool);
        return_shared(clock);
        return_shared(balance_manager);
    }
}

fun share_clock(test: &mut Scenario) {
    test.next_tx(OWNER);
    clock::create_for_testing(test.ctx()).share_for_testing();
}

fun share_registry_for_testing(test: &mut Scenario): ID {
    test.next_tx(OWNER);
    registry::test_registry(test.ctx())
}

fun setup_pool<BaseAsset, QuoteAsset>(
    sender: address,
    tick_size: u64,
    lot_size: u64,
    min_size: u64,
    registry_id: ID,
    whitelisted_pool: bool,
    stable_pool: bool,
    test: &mut Scenario,
): ID {
    test.next_tx(sender);
    let admin_cap = registry::get_admin_cap_for_testing(test.ctx());
    let mut registry = test.take_shared_by_id<Registry>(registry_id);
    let pool_id;
    {
        pool_id =
            pool::create_pool_admin<BaseAsset, QuoteAsset>(
                &mut registry,
                tick_size,
                lot_size,
                min_size,
                whitelisted_pool,
                stable_pool,
                &admin_cap,
                test.ctx(),
            );
    };
    return_shared(registry);
    destroy(admin_cap);

    pool_id
}

fun setup_permissionless_pool<BaseAsset, QuoteAsset>(
    sender: address,
    tick_size: u64,
    lot_size: u64,
    min_size: u64,
    registry_id: ID,
    test: &mut Scenario,
): ID {
    test.next_tx(sender);
    let admin_cap = registry::get_admin_cap_for_testing(test.ctx());
    let mut registry = test.take_shared_by_id<Registry>(registry_id);
    let pool_id;
    {
        pool_id =
            pool::create_permissionless_pool<BaseAsset, QuoteAsset>(
                &mut registry,
                tick_size,
                lot_size,
                min_size,
                mint_for_testing<DEEP>(
                    constants::pool_creation_fee(),
                    test.ctx(),
                ),
                test.ctx(),
            );
    };
    return_shared(registry);
    destroy(admin_cap);

    pool_id
}

fun get_mid_price<BaseAsset, QuoteAsset>(pool_id: ID, test: &mut Scenario): u64 {
    test.next_tx(OWNER);
    {
        let pool = test.take_shared_by_id<Pool<BaseAsset, QuoteAsset>>(pool_id);
        let clock = test.take_shared<Clock>();

        let mid_price = pool.mid_price<BaseAsset, QuoteAsset>(&clock);
        return_shared(pool);
        return_shared(clock);

        mid_price
    }
}

fun get_quantity_out<BaseAsset, QuoteAsset>(
    pool_id: ID,
    base_quantity: u64,
    quote_quantity: u64,
    test: &mut Scenario,
): (u64, u64, u64) {
    test.next_tx(OWNER);
    {
        let pool = test.take_shared_by_id<Pool<BaseAsset, QuoteAsset>>(pool_id);
        let clock = test.take_shared<Clock>();

        let (base_out, quote_out, deep_required) = pool.get_quantity_out<BaseAsset, QuoteAsset>(
            base_quantity,
            quote_quantity,
            &clock,
        );
        return_shared(pool);
        return_shared(clock);

        (base_out, quote_out, deep_required)
    }
}

fun get_quantity_out_input_fee<BaseAsset, QuoteAsset>(
    pool_id: ID,
    base_quantity: u64,
    quote_quantity: u64,
    test: &mut Scenario,
): (u64, u64, u64) {
    test.next_tx(OWNER);
    {
        let pool = test.take_shared_by_id<Pool<BaseAsset, QuoteAsset>>(pool_id);
        let clock = test.take_shared<Clock>();

        let (base_out, quote_out, deep_required) = pool.get_quantity_out_input_fee<
            BaseAsset,
            QuoteAsset,
        >(
            base_quantity,
            quote_quantity,
            &clock,
        );
        return_shared(pool);
        return_shared(clock);

        (base_out, quote_out, deep_required)
    }
}

fun get_base_quantity_out<BaseAsset, QuoteAsset>(
    pool_id: ID,
    quote_quantity: u64,
    test: &mut Scenario,
): (u64, u64, u64) {
    test.next_tx(OWNER);
    {
        let pool = test.take_shared_by_id<Pool<BaseAsset, QuoteAsset>>(pool_id);
        let clock = test.take_shared<Clock>();

        let (base_out, quote_out, deep_required) = pool.get_base_quantity_out<
            BaseAsset,
            QuoteAsset,
        >(
            quote_quantity,
            &clock,
        );
        return_shared(pool);
        return_shared(clock);

        (base_out, quote_out, deep_required)
    }
}

fun get_quote_quantity_out<BaseAsset, QuoteAsset>(
    pool_id: ID,
    base_quantity: u64,
    test: &mut Scenario,
): (u64, u64, u64) {
    test.next_tx(OWNER);
    {
        let pool = test.take_shared_by_id<Pool<BaseAsset, QuoteAsset>>(pool_id);
        let clock = test.take_shared<Clock>();

        let (base_out, quote_out, deep_required) = pool.get_quote_quantity_out<
            BaseAsset,
            QuoteAsset,
        >(
            base_quantity,
            &clock,
        );
        return_shared(pool);
        return_shared(clock);

        (base_out, quote_out, deep_required)
    }
}

fun get_base_quantity_out_input_fee<BaseAsset, QuoteAsset>(
    pool_id: ID,
    quote_quantity: u64,
    test: &mut Scenario,
): (u64, u64, u64) {
    test.next_tx(OWNER);
    {
        let pool = test.take_shared_by_id<Pool<BaseAsset, QuoteAsset>>(pool_id);
        let clock = test.take_shared<Clock>();

        let (base_out, quote_out, deep_required) = pool.get_base_quantity_out_input_fee<
            BaseAsset,
            QuoteAsset,
        >(
            quote_quantity,
            &clock,
        );
        return_shared(pool);
        return_shared(clock);

        (base_out, quote_out, deep_required)
    }
}

fun get_quote_quantity_out_input_fee<BaseAsset, QuoteAsset>(
    pool_id: ID,
    base_quantity: u64,
    test: &mut Scenario,
): (u64, u64, u64) {
    test.next_tx(OWNER);
    {
        let pool = test.take_shared_by_id<Pool<BaseAsset, QuoteAsset>>(pool_id);
        let clock = test.take_shared<Clock>();

        let (base_out, quote_out, deep_required) = pool.get_quote_quantity_out_input_fee<
            BaseAsset,
            QuoteAsset,
        >(
            base_quantity,
            &clock,
        );
        return_shared(pool);
        return_shared(clock);

        (base_out, quote_out, deep_required)
    }
}

fun test_cancel_orders(is_bid: bool) {
    let mut test = begin(OWNER);
    let registry_id = setup_test(OWNER, &mut test);
    let balance_manager_id_alice = create_acct_and_share_with_funds(
        ALICE,
        1000000 * constants::float_scaling(),
        &mut test,
    );
    let pool_id = setup_pool_with_default_fees_and_reference_pool<SUI, USDC, SUI, DEEP>(
        ALICE,
        registry_id,
        balance_manager_id_alice,
        &mut test,
    );

    let client_order_id = 1;
    let price = 2 * constants::float_scaling();
    let quantity = 1 * constants::float_scaling();
    let expire_timestamp = constants::max_u64();
    let pay_with_deep = true;

    let order_info_1 = place_limit_order<SUI, USDC>(
        ALICE,
        pool_id,
        balance_manager_id_alice,
        client_order_id,
        constants::no_restriction(),
        constants::self_matching_allowed(),
        price,
        quantity,
        is_bid,
        pay_with_deep,
        expire_timestamp,
        &mut test,
    );

    let order_info_2 = place_limit_order<SUI, USDC>(
        ALICE,
        pool_id,
        balance_manager_id_alice,
        client_order_id,
        constants::no_restriction(),
        constants::self_matching_allowed(),
        price,
        quantity,
        is_bid,
        pay_with_deep,
        expire_timestamp,
        &mut test,
    );

    let mut orders_to_cancel = vector[];
    orders_to_cancel.push_back(order_info_1.order_id());
    orders_to_cancel.push_back(order_info_2.order_id());

    cancel_orders<SUI, USDC>(
        ALICE,
        pool_id,
        balance_manager_id_alice,
        orders_to_cancel,
        &mut test,
    );

    borrow_and_verify_book_order<SUI, USDC>(
        pool_id,
        order_info_1.order_id(),
        is_bid,
        client_order_id,
        quantity,
        0,
        order_info_1.order_deep_price().deep_per_asset(),
        test.ctx().epoch(),
        constants::canceled(),
        expire_timestamp,
        &mut test,
    );

    end(test);
}

fun test_update_pool_book_params(error: u8) {
    let mut test = begin(OWNER);
    let registry_id = setup_test(OWNER, &mut test);
    let balance_manager_id_alice = create_acct_and_share_with_funds(
        ALICE,
        1000000 * constants::float_scaling(),
        &mut test,
    );
    let pool_id = setup_pool<SUI, USDC>(
        OWNER,
        constants::tick_size(), // tick size
        100_000,
        1_000_000,
        registry_id,
        true,
        false,
        &mut test,
    );

    let alice_client_order_id = 1;
    let alice_quantity_1 = 1_000_000;
    let alice_quantity_2 = 1_010_000;
    let alice_price = 2 * constants::float_scaling();
    let expire_timestamp = constants::max_u64();
    let pay_with_deep = true;

    place_limit_order<SUI, USDC>(
        ALICE,
        pool_id,
        balance_manager_id_alice,
        alice_client_order_id,
        constants::no_restriction(),
        constants::self_matching_allowed(),
        alice_price,
        alice_quantity_1,
        true,
        pay_with_deep,
        expire_timestamp,
        &mut test,
    );

    if (error == 0) {
        adjust_min_lot_size_admin<SUI, USDC>(
            OWNER,
            pool_id,
            1000,
            10000,
            &mut test,
        );
    };

    if (error == 2) {
        adjust_min_lot_size_admin<SUI, USDC>(
            OWNER,
            pool_id,
            6000,
            60000,
            &mut test,
        );
    };

    if (error == 3) {
        adjust_tick_size_admin<SUI, USDC>(
            OWNER,
            pool_id,
            50,
            &mut test,
        );
    };

    if (error == 4) {
        adjust_min_lot_size_admin<SUI, USDC>(
            OWNER,
            pool_id,
            0,
            500,
            &mut test,
        );
    };

    place_limit_order<SUI, USDC>(
        ALICE,
        pool_id,
        balance_manager_id_alice,
        alice_client_order_id,
        constants::no_restriction(),
        constants::self_matching_allowed(),
        alice_price,
        alice_quantity_2,
        true,
        pay_with_deep,
        expire_timestamp,
        &mut test,
    );
    adjust_tick_size_admin<SUI, USDC>(
        OWNER,
        pool_id,
        100,
        &mut test,
    );
    place_limit_order<SUI, USDC>(
        ALICE,
        pool_id,
        balance_manager_id_alice,
        alice_client_order_id,
        constants::no_restriction(),
        constants::self_matching_allowed(),
        alice_price + 100,
        alice_quantity_2,
        true,
        pay_with_deep,
        expire_timestamp,
        &mut test,
    );
    end(test);
}

fun adjust_min_lot_size_admin<BaseAsset, QuoteAsset>(
    sender: address,
    pool_id: ID,
    new_lot_size: u64,
    new_min_size: u64,
    test: &mut Scenario,
) {
    test.next_tx(sender);
    let mut pool = test.take_shared_by_id<Pool<BaseAsset, QuoteAsset>>(pool_id);
    let admin_cap = registry::get_admin_cap_for_testing(test.ctx());
    let clock = test.take_shared<Clock>();
    pool::adjust_min_lot_size_admin<BaseAsset, QuoteAsset>(
        &mut pool,
        new_lot_size,
        new_min_size,
        &admin_cap,
        &clock,
    );
    destroy(admin_cap);
    return_shared(pool);
    return_shared(clock);
}

fun adjust_tick_size_admin<BaseAsset, QuoteAsset>(
    sender: address,
    pool_id: ID,
    new_tick_size: u64,
    test: &mut Scenario,
) {
    test.next_tx(sender);
    let mut pool = test.take_shared_by_id<Pool<BaseAsset, QuoteAsset>>(pool_id);
    let admin_cap = registry::get_admin_cap_for_testing(test.ctx());
    let clock = test.take_shared<Clock>();
    pool::adjust_tick_size_admin<BaseAsset, QuoteAsset>(
        &mut pool,
        new_tick_size,
        &admin_cap,
        &clock,
    );
    destroy(admin_cap);
    return_shared(pool);
    return_shared(clock);
}

fun add_stablecoin<T>(sender: address, registry_id: ID, test: &mut Scenario) {
    test.next_tx(sender);
    let admin_cap = registry::get_admin_cap_for_testing(test.ctx());
    let mut registry = test.take_shared_by_id<Registry>(registry_id);
    {
        registry::add_stablecoin<T>(
            &mut registry,
            &admin_cap,
        );
    };
    return_shared(registry);
    destroy(admin_cap);
}

fun remove_stablecoin<T>(sender: address, registry_id: ID, test: &mut Scenario) {
    test.next_tx(sender);
    let admin_cap = registry::get_admin_cap_for_testing(test.ctx());
    let mut registry = test.take_shared_by_id<Registry>(registry_id);
    {
        registry::remove_stablecoin<T>(
            &mut registry,
            &admin_cap,
        );
    };
    return_shared(registry);
    destroy(admin_cap);
}

fun advance_scenario_with_gas_price(test: &mut Scenario, gas_price: u64, timestamp_advance: u64) {
    let ts = test.ctx().epoch_timestamp_ms() + timestamp_advance;
    let ctx = test.ctx_builder().set_gas_price(gas_price).set_epoch_timestamp(ts);
    test.next_with_context(ctx);
}

// ============== can_place_market_order tests ==============

/// Test bid market order with sufficient quote balance and DEEP for fees
#[test]
fun test_can_place_market_order_bid_with_deep_sufficient() {
    let mut test = begin(OWNER);
    let registry_id = setup_test(OWNER, &mut test);
    let balance_manager_id_alice = create_acct_and_share_with_funds(
        ALICE,
        1000000 * constants::float_scaling(),
        &mut test,
    );

    // Setup pool with reference pool (non-whitelisted) so DEEP fees are required
    let pool_id = setup_pool_with_default_fees_and_reference_pool<SUI, USDC, SUI, DEEP>(
        ALICE,
        registry_id,
        balance_manager_id_alice,
        &mut test,
    );

    // Place a sell order on the book (so we can buy)
    place_limit_order<SUI, USDC>(
        ALICE,
        pool_id,
        balance_manager_id_alice,
        1,
        constants::no_restriction(),
        constants::self_matching_allowed(),
        2 * constants::float_scaling(), // price: 2 USDC per SUI
        100 * constants::float_scaling(), // quantity: 100 SUI
        false, // is_bid = false (sell order)
        true, // pay_with_deep
        constants::max_u64(),
        &mut test,
    );

    test.next_tx(ALICE);
    {
        let pool = test.take_shared_by_id<Pool<SUI, USDC>>(pool_id);
        let balance_manager = test.take_shared_by_id<BalanceManager>(balance_manager_id_alice);
        let clock = test.take_shared<Clock>();

        // Test: bid for 10 SUI with pay_with_deep = true
        // Should succeed since we have enough USDC and DEEP
        let can_place = pool.can_place_market_order<SUI, USDC>(
            &balance_manager,
            10 * constants::float_scaling(), // quantity: 10 SUI
            true, // is_bid
            true, // pay_with_deep
            &clock,
        );
        assert!(can_place);

        return_shared(pool);
        return_shared(balance_manager);
        return_shared(clock);
    };

    end(test);
}

/// Test bid market order with insufficient quote balance
#[test]
fun test_can_place_market_order_bid_insufficient_quote() {
    let mut test = begin(OWNER);
    let registry_id = setup_test(OWNER, &mut test);

    // Create balance manager with minimal funds
    test.next_tx(ALICE);
    let balance_manager_id_alice;
    {
        let mut bm = balance_manager::new(test.ctx());
        // Only deposit 1 USDC (not enough to buy 10 SUI at price 2)
        bm.deposit(
            mint_for_testing<USDC>(1 * constants::float_scaling(), test.ctx()),
            test.ctx(),
        );
        bm.deposit(
            mint_for_testing<DEEP>(1000 * constants::float_scaling(), test.ctx()),
            test.ctx(),
        );
        balance_manager_id_alice = bm.id();
        transfer::public_share_object(bm);
    };

    // Create another balance manager with funds for liquidity
    let balance_manager_id_bob = create_acct_and_share_with_funds(
        BOB,
        1000000 * constants::float_scaling(),
        &mut test,
    );

    // Setup pool
    let pool_id = setup_pool_with_default_fees<SUI, USDC>(
        OWNER,
        registry_id,
        true,
        false,
        &mut test,
    );

    // Place a sell order on the book by Bob
    place_limit_order<SUI, USDC>(
        BOB,
        pool_id,
        balance_manager_id_bob,
        1,
        constants::no_restriction(),
        constants::self_matching_allowed(),
        2 * constants::float_scaling(), // price: 2 USDC per SUI
        100 * constants::float_scaling(), // quantity: 100 SUI
        false, // is_bid = false (sell order)
        true, // pay_with_deep
        constants::max_u64(),
        &mut test,
    );

    test.next_tx(ALICE);
    {
        let pool = test.take_shared_by_id<Pool<SUI, USDC>>(pool_id);
        let balance_manager = test.take_shared_by_id<BalanceManager>(balance_manager_id_alice);
        let clock = test.take_shared<Clock>();

        // Test: try to bid for 10 SUI but only have 1 USDC
        let can_place = pool.can_place_market_order<SUI, USDC>(
            &balance_manager,
            10 * constants::float_scaling(), // quantity: 10 SUI
            true, // is_bid
            true, // pay_with_deep
            &clock,
        );
        assert!(!can_place);

        return_shared(pool);
        return_shared(balance_manager);
        return_shared(clock);
    };

    end(test);
}

/// Test bid market order with insufficient DEEP for fees (using reference pool setup)
#[test]
fun test_can_place_market_order_bid_insufficient_deep() {
    let mut test = begin(OWNER);
    let registry_id = setup_test(OWNER, &mut test);

    // Create balance manager with USDC but no DEEP
    test.next_tx(ALICE);
    let balance_manager_id_alice;
    {
        let mut bm = balance_manager::new(test.ctx());
        bm.deposit(
            mint_for_testing<USDC>(1000 * constants::float_scaling(), test.ctx()),
            test.ctx(),
        );
        // No DEEP deposited
        balance_manager_id_alice = bm.id();
        transfer::public_share_object(bm);
    };

    // Create balance manager for Bob with funds for liquidity and reference pool setup
    let balance_manager_id_bob = create_acct_and_share_with_funds(
        BOB,
        1000000 * constants::float_scaling(),
        &mut test,
    );

    // Setup pool with reference pool (non-whitelisted) so DEEP is required for fees
    let pool_id = setup_pool_with_default_fees_and_reference_pool<SUI, USDC, SUI, DEEP>(
        BOB,
        registry_id,
        balance_manager_id_bob,
        &mut test,
    );

    // Place a sell order on the book by Bob
    place_limit_order<SUI, USDC>(
        BOB,
        pool_id,
        balance_manager_id_bob,
        1,
        constants::no_restriction(),
        constants::self_matching_allowed(),
        2 * constants::float_scaling(), // price: 2 USDC per SUI
        100 * constants::float_scaling(), // quantity: 100 SUI
        false, // is_bid = false (sell order)
        true, // pay_with_deep
        constants::max_u64(),
        &mut test,
    );

    test.next_tx(ALICE);
    {
        let pool = test.take_shared_by_id<Pool<SUI, USDC>>(pool_id);
        let balance_manager = test.take_shared_by_id<BalanceManager>(balance_manager_id_alice);
        let clock = test.take_shared<Clock>();

        // Test: try to bid for 10 SUI with pay_with_deep but no DEEP
        let can_place = pool.can_place_market_order<SUI, USDC>(
            &balance_manager,
            10 * constants::float_scaling(), // quantity: 10 SUI
            true, // is_bid
            true, // pay_with_deep
            &clock,
        );
        assert!(!can_place);

        return_shared(pool);
        return_shared(balance_manager);
        return_shared(clock);
    };

    end(test);
}

/// Test bid market order with exactly the quote and DEEP needed
#[test]
fun test_can_place_market_order_bid_exact_quote_and_deep() {
    let mut test = begin(OWNER);
    let registry_id = setup_test(OWNER, &mut test);

    // Create balance manager for Bob with funds for liquidity and reference pool setup
    let balance_manager_id_bob = create_acct_and_share_with_funds(
        BOB,
        1000000 * constants::float_scaling(),
        &mut test,
    );

    // Setup pool with reference pool (non-whitelisted) so DEEP is required for fees
    let pool_id = setup_pool_with_default_fees_and_reference_pool<SUI, USDC, SUI, DEEP>(
        BOB,
        registry_id,
        balance_manager_id_bob,
        &mut test,
    );

    // Place a sell order on the book by Bob
    place_limit_order<SUI, USDC>(
        BOB,
        pool_id,
        balance_manager_id_bob,
        1,
        constants::no_restriction(),
        constants::self_matching_allowed(),
        2 * constants::float_scaling(), // price: 2 USDC per SUI
        100 * constants::float_scaling(), // quantity: 100 SUI
        false, // is_bid = false (sell order)
        true, // pay_with_deep
        constants::max_u64(),
        &mut test,
    );

    // Get the exact quote and DEEP needed for a market bid of 10 SUI
    let quantity = 10 * constants::float_scaling();
    let quote_needed;
    let deep_needed;
    test.next_tx(ALICE);
    {
        let pool = test.take_shared_by_id<Pool<SUI, USDC>>(pool_id);
        let clock = test.take_shared<Clock>();

        let (_base_out, quote_in, deep_required) = pool.get_quote_quantity_in(
            quantity,
            true, // pay_with_deep
            &clock,
        );
        quote_needed = quote_in;
        deep_needed = deep_required;

        return_shared(pool);
        return_shared(clock);
    };

    // Create balance manager for Alice with exactly the needed amounts
    test.next_tx(ALICE);
    let balance_manager_id_alice;
    {
        let mut bm = balance_manager::new(test.ctx());
        bm.deposit(
            mint_for_testing<USDC>(quote_needed, test.ctx()),
            test.ctx(),
        );
        bm.deposit(
            mint_for_testing<DEEP>(deep_needed, test.ctx()),
            test.ctx(),
        );
        balance_manager_id_alice = bm.id();
        transfer::public_share_object(bm);
    };

    test.next_tx(ALICE);
    {
        let pool = test.take_shared_by_id<Pool<SUI, USDC>>(pool_id);
        let balance_manager = test.take_shared_by_id<BalanceManager>(balance_manager_id_alice);
        let clock = test.take_shared<Clock>();

        // Test: bid for 10 SUI with exactly the quote and DEEP needed
        let can_place = pool.can_place_market_order<SUI, USDC>(
            &balance_manager,
            quantity,
            true, // is_bid
            true, // pay_with_deep
            &clock,
        );
        assert!(can_place);

        return_shared(pool);
        return_shared(balance_manager);
        return_shared(clock);
    };

    end(test);
}

/// Test bid market order fails with one less unit of DEEP than needed
#[test]
fun test_can_place_market_order_bid_one_less_deep_than_needed() {
    let mut test = begin(OWNER);
    let registry_id = setup_test(OWNER, &mut test);

    // Create balance manager for Bob with funds for liquidity and reference pool setup
    let balance_manager_id_bob = create_acct_and_share_with_funds(
        BOB,
        1000000 * constants::float_scaling(),
        &mut test,
    );

    // Setup pool with reference pool (non-whitelisted) so DEEP is required for fees
    let pool_id = setup_pool_with_default_fees_and_reference_pool<SUI, USDC, SUI, DEEP>(
        BOB,
        registry_id,
        balance_manager_id_bob,
        &mut test,
    );

    // Place a sell order on the book by Bob
    place_limit_order<SUI, USDC>(
        BOB,
        pool_id,
        balance_manager_id_bob,
        1,
        constants::no_restriction(),
        constants::self_matching_allowed(),
        2 * constants::float_scaling(), // price: 2 USDC per SUI
        100 * constants::float_scaling(), // quantity: 100 SUI
        false, // is_bid = false (sell order)
        true, // pay_with_deep
        constants::max_u64(),
        &mut test,
    );

    // Get the exact quote and DEEP needed for a market bid of 10 SUI
    let quantity = 10 * constants::float_scaling();
    let quote_needed;
    let deep_needed;
    test.next_tx(ALICE);
    {
        let pool = test.take_shared_by_id<Pool<SUI, USDC>>(pool_id);
        let clock = test.take_shared<Clock>();

        let (_base_out, quote_in, deep_required) = pool.get_quote_quantity_in(
            quantity,
            true, // pay_with_deep
            &clock,
        );
        quote_needed = quote_in;
        deep_needed = deep_required;

        return_shared(pool);
        return_shared(clock);
    };

    // Create balance manager for Alice with exact quote but one less DEEP
    test.next_tx(ALICE);
    let balance_manager_id_alice;
    {
        let mut bm = balance_manager::new(test.ctx());
        bm.deposit(
            mint_for_testing<USDC>(quote_needed, test.ctx()),
            test.ctx(),
        );
        bm.deposit(
            mint_for_testing<DEEP>(deep_needed - 1, test.ctx()),
            test.ctx(),
        );
        balance_manager_id_alice = bm.id();
        transfer::public_share_object(bm);
    };

    test.next_tx(ALICE);
    {
        let pool = test.take_shared_by_id<Pool<SUI, USDC>>(pool_id);
        let balance_manager = test.take_shared_by_id<BalanceManager>(balance_manager_id_alice);
        let clock = test.take_shared<Clock>();

        // Test: bid for 10 SUI with one less DEEP than needed should fail
        let can_place = pool.can_place_market_order<SUI, USDC>(
            &balance_manager,
            quantity,
            true, // is_bid
            true, // pay_with_deep
            &clock,
        );
        assert!(!can_place);

        return_shared(pool);
        return_shared(balance_manager);
        return_shared(clock);
    };

    end(test);
}

/// Test ask market order with sufficient base balance and DEEP for fees
#[test]
fun test_can_place_market_order_ask_with_deep_sufficient() {
    let mut test = begin(OWNER);
    let registry_id = setup_test(OWNER, &mut test);
    let balance_manager_id_alice = create_acct_and_share_with_funds(
        ALICE,
        1000000 * constants::float_scaling(),
        &mut test,
    );

    // Setup pool with reference pool (non-whitelisted) so DEEP fees are required
    let pool_id = setup_pool_with_default_fees_and_reference_pool<SUI, USDC, SUI, DEEP>(
        ALICE,
        registry_id,
        balance_manager_id_alice,
        &mut test,
    );

    // Place a buy order on the book (so we can sell)
    place_limit_order<SUI, USDC>(
        ALICE,
        pool_id,
        balance_manager_id_alice,
        1,
        constants::no_restriction(),
        constants::self_matching_allowed(),
        1 * constants::float_scaling(), // price: 1 USDC per SUI
        100 * constants::float_scaling(), // quantity: 100 SUI
        true, // is_bid = true (buy order)
        true, // pay_with_deep
        constants::max_u64(),
        &mut test,
    );

    test.next_tx(ALICE);
    {
        let pool = test.take_shared_by_id<Pool<SUI, USDC>>(pool_id);
        let balance_manager = test.take_shared_by_id<BalanceManager>(balance_manager_id_alice);
        let clock = test.take_shared<Clock>();

        // Test: ask (sell) 10 SUI with pay_with_deep = true
        let can_place = pool.can_place_market_order<SUI, USDC>(
            &balance_manager,
            10 * constants::float_scaling(), // quantity: 10 SUI
            false, // is_bid = false (ask/sell)
            true, // pay_with_deep
            &clock,
        );
        assert!(can_place);

        return_shared(pool);
        return_shared(balance_manager);
        return_shared(clock);
    };

    end(test);
}

/// Test ask market order with insufficient base balance
#[test]
fun test_can_place_market_order_ask_insufficient_base() {
    let mut test = begin(OWNER);
    let registry_id = setup_test(OWNER, &mut test);

    // Create balance manager with minimal SUI
    test.next_tx(ALICE);
    let balance_manager_id_alice;
    {
        let mut bm = balance_manager::new(test.ctx());
        // Only deposit 1 SUI (not enough to sell 10 SUI)
        bm.deposit(
            mint_for_testing<SUI>(1 * constants::float_scaling(), test.ctx()),
            test.ctx(),
        );
        bm.deposit(
            mint_for_testing<DEEP>(1000 * constants::float_scaling(), test.ctx()),
            test.ctx(),
        );
        balance_manager_id_alice = bm.id();
        transfer::public_share_object(bm);
    };

    // Create another balance manager with funds for liquidity
    let balance_manager_id_bob = create_acct_and_share_with_funds(
        BOB,
        1000000 * constants::float_scaling(),
        &mut test,
    );

    // Setup pool
    let pool_id = setup_pool_with_default_fees<SUI, USDC>(
        OWNER,
        registry_id,
        true,
        false,
        &mut test,
    );

    // Place a buy order on the book by Bob
    place_limit_order<SUI, USDC>(
        BOB,
        pool_id,
        balance_manager_id_bob,
        1,
        constants::no_restriction(),
        constants::self_matching_allowed(),
        1 * constants::float_scaling(), // price: 1 USDC per SUI
        100 * constants::float_scaling(), // quantity: 100 SUI
        true, // is_bid = true (buy order)
        true, // pay_with_deep
        constants::max_u64(),
        &mut test,
    );

    test.next_tx(ALICE);
    {
        let pool = test.take_shared_by_id<Pool<SUI, USDC>>(pool_id);
        let balance_manager = test.take_shared_by_id<BalanceManager>(balance_manager_id_alice);
        let clock = test.take_shared<Clock>();

        // Test: try to ask (sell) 10 SUI but only have 1 SUI
        let can_place = pool.can_place_market_order<SUI, USDC>(
            &balance_manager,
            10 * constants::float_scaling(), // quantity: 10 SUI
            false, // is_bid = false (ask/sell)
            true, // pay_with_deep
            &clock,
        );
        assert!(!can_place);

        return_shared(pool);
        return_shared(balance_manager);
        return_shared(clock);
    };

    end(test);
}

/// Test ask market order with insufficient DEEP for fees (using reference pool setup)
#[test]
fun test_can_place_market_order_ask_insufficient_deep() {
    let mut test = begin(OWNER);
    let registry_id = setup_test(OWNER, &mut test);

    // Create balance manager with SUI but no DEEP
    test.next_tx(ALICE);
    let balance_manager_id_alice;
    {
        let mut bm = balance_manager::new(test.ctx());
        bm.deposit(
            mint_for_testing<SUI>(100 * constants::float_scaling(), test.ctx()),
            test.ctx(),
        );
        // No DEEP deposited
        balance_manager_id_alice = bm.id();
        transfer::public_share_object(bm);
    };

    // Create balance manager for Bob with funds for liquidity and reference pool setup
    let balance_manager_id_bob = create_acct_and_share_with_funds(
        BOB,
        1000000 * constants::float_scaling(),
        &mut test,
    );

    // Setup pool with reference pool (non-whitelisted) so DEEP is required for fees
    let pool_id = setup_pool_with_default_fees_and_reference_pool<SUI, USDC, SUI, DEEP>(
        BOB,
        registry_id,
        balance_manager_id_bob,
        &mut test,
    );

    // Place a buy order on the book by Bob
    place_limit_order<SUI, USDC>(
        BOB,
        pool_id,
        balance_manager_id_bob,
        1,
        constants::no_restriction(),
        constants::self_matching_allowed(),
        1 * constants::float_scaling(), // price: 1 USDC per SUI
        100 * constants::float_scaling(), // quantity: 100 SUI
        true, // is_bid = true (buy order)
        true, // pay_with_deep
        constants::max_u64(),
        &mut test,
    );

    test.next_tx(ALICE);
    {
        let pool = test.take_shared_by_id<Pool<SUI, USDC>>(pool_id);
        let balance_manager = test.take_shared_by_id<BalanceManager>(balance_manager_id_alice);
        let clock = test.take_shared<Clock>();

        // Test: try to ask (sell) 10 SUI with pay_with_deep but no DEEP
        let can_place = pool.can_place_market_order<SUI, USDC>(
            &balance_manager,
            10 * constants::float_scaling(), // quantity: 10 SUI
            false, // is_bid = false (ask/sell)
            true, // pay_with_deep
            &clock,
        );
        assert!(!can_place);

        return_shared(pool);
        return_shared(balance_manager);
        return_shared(clock);
    };

    end(test);
}

/// Test bid market order paying fees with input token (quote)
#[test]
fun test_can_place_market_order_bid_input_fee_sufficient() {
    let mut test = begin(OWNER);
    let registry_id = setup_test(OWNER, &mut test);
    let balance_manager_id_alice = create_acct_and_share_with_funds(
        ALICE,
        1000000 * constants::float_scaling(),
        &mut test,
    );

    // Setup pool with liquidity on the book
    let pool_id = setup_pool_with_default_fees<SUI, USDC>(
        OWNER,
        registry_id,
        true,
        false,
        &mut test,
    );

    // Place a sell order on the book
    place_limit_order<SUI, USDC>(
        ALICE,
        pool_id,
        balance_manager_id_alice,
        1,
        constants::no_restriction(),
        constants::self_matching_allowed(),
        2 * constants::float_scaling(), // price: 2 USDC per SUI
        100 * constants::float_scaling(), // quantity: 100 SUI
        false, // is_bid = false (sell order)
        true, // pay_with_deep
        constants::max_u64(),
        &mut test,
    );

    test.next_tx(ALICE);
    {
        let pool = test.take_shared_by_id<Pool<SUI, USDC>>(pool_id);
        let balance_manager = test.take_shared_by_id<BalanceManager>(balance_manager_id_alice);
        let clock = test.take_shared<Clock>();

        // Test: bid for 10 SUI with pay_with_deep = false (pay fees in USDC)
        let can_place = pool.can_place_market_order<SUI, USDC>(
            &balance_manager,
            10 * constants::float_scaling(), // quantity: 10 SUI
            true, // is_bid
            false, // pay_with_deep = false (fees in quote)
            &clock,
        );
        assert!(can_place);

        return_shared(pool);
        return_shared(balance_manager);
        return_shared(clock);
    };

    end(test);
}

/// Test ask market order paying fees with input token (base)
#[test]
fun test_can_place_market_order_ask_input_fee_sufficient() {
    let mut test = begin(OWNER);
    let registry_id = setup_test(OWNER, &mut test);
    let balance_manager_id_alice = create_acct_and_share_with_funds(
        ALICE,
        1000000 * constants::float_scaling(),
        &mut test,
    );

    // Setup pool with liquidity on the book
    let pool_id = setup_pool_with_default_fees<SUI, USDC>(
        OWNER,
        registry_id,
        true,
        false,
        &mut test,
    );

    // Place a buy order on the book
    place_limit_order<SUI, USDC>(
        ALICE,
        pool_id,
        balance_manager_id_alice,
        1,
        constants::no_restriction(),
        constants::self_matching_allowed(),
        1 * constants::float_scaling(), // price: 1 USDC per SUI
        100 * constants::float_scaling(), // quantity: 100 SUI
        true, // is_bid = true (buy order)
        true, // pay_with_deep
        constants::max_u64(),
        &mut test,
    );

    test.next_tx(ALICE);
    {
        let pool = test.take_shared_by_id<Pool<SUI, USDC>>(pool_id);
        let balance_manager = test.take_shared_by_id<BalanceManager>(balance_manager_id_alice);
        let clock = test.take_shared<Clock>();

        // Test: ask (sell) 10 SUI with pay_with_deep = false (pay fees in SUI)
        let can_place = pool.can_place_market_order<SUI, USDC>(
            &balance_manager,
            10 * constants::float_scaling(), // quantity: 10 SUI
            false, // is_bid = false (ask/sell)
            false, // pay_with_deep = false (fees in base)
            &clock,
        );
        assert!(can_place);

        return_shared(pool);
        return_shared(balance_manager);
        return_shared(clock);
    };

    end(test);
}

/// Test ask market order paying fees with input token but insufficient base (need extra for fees)
#[test]
fun test_can_place_market_order_ask_input_fee_insufficient() {
    let mut test = begin(OWNER);
    let registry_id = setup_test(OWNER, &mut test);

    // Create balance manager with only 9 SUI (clearly not enough to sell 10 SUI + fees)
    test.next_tx(ALICE);
    let balance_manager_id_alice;
    {
        let mut bm = balance_manager::new(test.ctx());
        // Deposit only 9 SUI - clearly not enough to sell 10 SUI when fees are in base
        bm.deposit(
            mint_for_testing<SUI>(9 * constants::float_scaling(), test.ctx()),
            test.ctx(),
        );
        balance_manager_id_alice = bm.id();
        transfer::public_share_object(bm);
    };

    // Create another balance manager with funds for liquidity
    let balance_manager_id_bob = create_acct_and_share_with_funds(
        BOB,
        1000000 * constants::float_scaling(),
        &mut test,
    );

    // Setup pool
    let pool_id = setup_pool_with_default_fees<SUI, USDC>(
        OWNER,
        registry_id,
        true,
        false,
        &mut test,
    );

    // Place a buy order on the book by Bob
    place_limit_order<SUI, USDC>(
        BOB,
        pool_id,
        balance_manager_id_bob,
        1,
        constants::no_restriction(),
        constants::self_matching_allowed(),
        1 * constants::float_scaling(), // price: 1 USDC per SUI
        100 * constants::float_scaling(), // quantity: 100 SUI
        true, // is_bid = true (buy order)
        true, // pay_with_deep
        constants::max_u64(),
        &mut test,
    );

    test.next_tx(ALICE);
    {
        let pool = test.take_shared_by_id<Pool<SUI, USDC>>(pool_id);
        let balance_manager = test.take_shared_by_id<BalanceManager>(balance_manager_id_alice);
        let clock = test.take_shared<Clock>();

        // Test: try to ask (sell) 10 SUI with pay_with_deep = false
        // Should fail because we need 10 SUI + fees, but only have 9 SUI
        let can_place = pool.can_place_market_order<SUI, USDC>(
            &balance_manager,
            10 * constants::float_scaling(), // quantity: 10 SUI
            false, // is_bid = false (ask/sell)
            false, // pay_with_deep = false (fees in base)
            &clock,
        );
        assert!(!can_place);

        return_shared(pool);
        return_shared(balance_manager);
        return_shared(clock);
    };

    end(test);
}

/// Test market order with no liquidity on the book
#[test]
fun test_can_place_market_order_no_liquidity() {
    let mut test = begin(OWNER);
    let registry_id = setup_test(OWNER, &mut test);
    let balance_manager_id_alice = create_acct_and_share_with_funds(
        ALICE,
        1000000 * constants::float_scaling(),
        &mut test,
    );

    // Setup pool WITHOUT any liquidity
    let pool_id = setup_pool_with_default_fees<SUI, USDC>(
        OWNER,
        registry_id,
        true,
        false,
        &mut test,
    );

    test.next_tx(ALICE);
    {
        let pool = test.take_shared_by_id<Pool<SUI, USDC>>(pool_id);
        let balance_manager = test.take_shared_by_id<BalanceManager>(balance_manager_id_alice);
        let clock = test.take_shared<Clock>();

        // Test: bid for 10 SUI but no sell orders on book
        // get_quantity_out will return 0 base_out since there's no liquidity
        let can_place = pool.can_place_market_order<SUI, USDC>(
            &balance_manager,
            10 * constants::float_scaling(), // quantity: 10 SUI
            true, // is_bid
            true, // pay_with_deep
            &clock,
        );
        assert!(!can_place);

        return_shared(pool);
        return_shared(balance_manager);
        return_shared(clock);
    };

    end(test);
}

/// Test market order for zero quantity (edge case)
#[test]
fun test_can_place_market_order_zero_quantity() {
    let mut test = begin(OWNER);
    let registry_id = setup_test(OWNER, &mut test);
    let balance_manager_id_alice = create_acct_and_share_with_funds(
        ALICE,
        1000000 * constants::float_scaling(),
        &mut test,
    );

    let pool_id = setup_pool_with_default_fees<SUI, USDC>(
        OWNER,
        registry_id,
        true,
        false,
        &mut test,
    );

    test.next_tx(ALICE);
    {
        let pool = test.take_shared_by_id<Pool<SUI, USDC>>(pool_id);
        let balance_manager = test.take_shared_by_id<BalanceManager>(balance_manager_id_alice);
        let clock = test.take_shared<Clock>();

        // Test: zero quantity should return false (fails min_size check)
        let can_place = pool.can_place_market_order<SUI, USDC>(
            &balance_manager,
            0, // quantity: 0
            true, // is_bid
            true, // pay_with_deep
            &clock,
        );
        assert!(!can_place);

        return_shared(pool);
        return_shared(balance_manager);
        return_shared(clock);
    };

    end(test);
}

/// Test market order exactly at the limit of available balance
#[test]
fun test_can_place_market_order_bid_exact_balance() {
    let mut test = begin(OWNER);
    let registry_id = setup_test(OWNER, &mut test);

    // Create balance manager with funds for liquidity
    let balance_manager_id_bob = create_acct_and_share_with_funds(
        BOB,
        1000000 * constants::float_scaling(),
        &mut test,
    );

    // Setup pool
    let pool_id = setup_pool_with_default_fees<SUI, USDC>(
        OWNER,
        registry_id,
        true,
        false,
        &mut test,
    );

    // Place a sell order on the book by Bob at price 1
    place_limit_order<SUI, USDC>(
        BOB,
        pool_id,
        balance_manager_id_bob,
        1,
        constants::no_restriction(),
        constants::self_matching_allowed(),
        1 * constants::float_scaling(), // price: 1 USDC per SUI
        100 * constants::float_scaling(), // quantity: 100 SUI
        false, // is_bid = false (sell order)
        true, // pay_with_deep
        constants::max_u64(),
        &mut test,
    );

    // Create Alice's balance manager with exactly enough USDC to buy 10 SUI at price 1
    test.next_tx(ALICE);
    let balance_manager_id_alice;
    {
        let mut bm = balance_manager::new(test.ctx());
        // 10 USDC to buy 10 SUI at price 1
        bm.deposit(
            mint_for_testing<USDC>(10 * constants::float_scaling(), test.ctx()),
            test.ctx(),
        );
        // Enough DEEP for fees
        bm.deposit(
            mint_for_testing<DEEP>(1000 * constants::float_scaling(), test.ctx()),
            test.ctx(),
        );
        balance_manager_id_alice = bm.id();
        transfer::public_share_object(bm);
    };

    test.next_tx(ALICE);
    {
        let pool = test.take_shared_by_id<Pool<SUI, USDC>>(pool_id);
        let balance_manager = test.take_shared_by_id<BalanceManager>(balance_manager_id_alice);
        let clock = test.take_shared<Clock>();

        // Test: bid for exactly 10 SUI with exactly 10 USDC at price 1
        let can_place = pool.can_place_market_order<SUI, USDC>(
            &balance_manager,
            10 * constants::float_scaling(), // quantity: 10 SUI
            true, // is_bid
            true, // pay_with_deep
            &clock,
        );
        assert!(can_place);

        // Test: try to bid for 11 SUI (should fail)
        let can_place_more = pool.can_place_market_order<SUI, USDC>(
            &balance_manager,
            11 * constants::float_scaling(), // quantity: 11 SUI
            true, // is_bid
            true, // pay_with_deep
            &clock,
        );
        assert!(!can_place_more);

        return_shared(pool);
        return_shared(balance_manager);
        return_shared(clock);
    };

    end(test);
}

// ============== can_place_limit_order tests ==============

/// Test bid limit order with sufficient quote balance and DEEP for fees
#[test]
fun test_can_place_limit_order_bid_with_deep_sufficient() {
    let mut test = begin(OWNER);
    let registry_id = setup_test(OWNER, &mut test);
    let balance_manager_id_alice = create_acct_and_share_with_funds(
        ALICE,
        1000000 * constants::float_scaling(),
        &mut test,
    );

    // Setup pool with reference pool (non-whitelisted) so DEEP fees are required
    let pool_id = setup_pool_with_default_fees_and_reference_pool<SUI, USDC, SUI, DEEP>(
        ALICE,
        registry_id,
        balance_manager_id_alice,
        &mut test,
    );

    test.next_tx(ALICE);
    {
        let pool = test.take_shared_by_id<Pool<SUI, USDC>>(pool_id);
        let balance_manager = test.take_shared_by_id<BalanceManager>(balance_manager_id_alice);
        let clock = clock::create_for_testing(test.ctx());

        // Test: bid for 10 SUI at price 2 with pay_with_deep = true
        // Required quote = 10 * 2 = 20 USDC + DEEP fees
        let can_place = pool.can_place_limit_order<SUI, USDC>(
            &balance_manager,
            2 * constants::float_scaling(), // price: 2 USDC per SUI
            10 * constants::float_scaling(), // quantity: 10 SUI
            true, // is_bid
            true, // pay_with_deep
            constants::max_u64(), // expire_timestamp
            &clock,
        );
        assert!(can_place);

        clock.destroy_for_testing();
        return_shared(pool);
        return_shared(balance_manager);
    };

    end(test);
}

/// Test bid limit order with insufficient quote balance
#[test]
fun test_can_place_limit_order_bid_insufficient_quote() {
    let mut test = begin(OWNER);
    let registry_id = setup_test(OWNER, &mut test);

    // Create balance manager with minimal funds
    test.next_tx(ALICE);
    let balance_manager_id_alice;
    {
        let mut bm = balance_manager::new(test.ctx());
        // Only deposit 10 USDC (not enough to buy 10 SUI at price 2 = 20 USDC)
        bm.deposit(
            mint_for_testing<USDC>(10 * constants::float_scaling(), test.ctx()),
            test.ctx(),
        );
        bm.deposit(
            mint_for_testing<DEEP>(1000 * constants::float_scaling(), test.ctx()),
            test.ctx(),
        );
        balance_manager_id_alice = bm.id();
        transfer::public_share_object(bm);
    };

    // Setup pool
    let pool_id = setup_pool_with_default_fees<SUI, USDC>(
        OWNER,
        registry_id,
        true,
        false,
        &mut test,
    );

    test.next_tx(ALICE);
    {
        let pool = test.take_shared_by_id<Pool<SUI, USDC>>(pool_id);
        let balance_manager = test.take_shared_by_id<BalanceManager>(balance_manager_id_alice);
        let clock = clock::create_for_testing(test.ctx());

        // Test: try to bid for 10 SUI at price 2 but only have 10 USDC (need 20)
        let can_place = pool.can_place_limit_order<SUI, USDC>(
            &balance_manager,
            2 * constants::float_scaling(), // price: 2 USDC per SUI
            10 * constants::float_scaling(), // quantity: 10 SUI
            true, // is_bid
            true, // pay_with_deep
            constants::max_u64(), // expire_timestamp
            &clock,
        );
        assert!(!can_place);

        clock.destroy_for_testing();
        return_shared(pool);
        return_shared(balance_manager);
    };

    end(test);
}

/// Test bid limit order with insufficient DEEP for fees (non-whitelisted pool)
#[test]
fun test_can_place_limit_order_bid_insufficient_deep() {
    let mut test = begin(OWNER);
    let registry_id = setup_test(OWNER, &mut test);

    // Create balance manager with USDC but no DEEP
    test.next_tx(ALICE);
    let balance_manager_id_alice;
    {
        let mut bm = balance_manager::new(test.ctx());
        bm.deposit(
            mint_for_testing<USDC>(1000 * constants::float_scaling(), test.ctx()),
            test.ctx(),
        );
        // No DEEP deposited
        balance_manager_id_alice = bm.id();
        transfer::public_share_object(bm);
    };

    // Create balance manager for Bob with funds for reference pool setup
    let balance_manager_id_bob = create_acct_and_share_with_funds(
        BOB,
        1000000 * constants::float_scaling(),
        &mut test,
    );

    // Setup pool with reference pool (non-whitelisted) so DEEP is required for fees
    let pool_id = setup_pool_with_default_fees_and_reference_pool<SUI, USDC, SUI, DEEP>(
        BOB,
        registry_id,
        balance_manager_id_bob,
        &mut test,
    );

    test.next_tx(ALICE);
    {
        let pool = test.take_shared_by_id<Pool<SUI, USDC>>(pool_id);
        let balance_manager = test.take_shared_by_id<BalanceManager>(balance_manager_id_alice);
        let clock = clock::create_for_testing(test.ctx());

        // Test: try to bid for 10 SUI with pay_with_deep but no DEEP
        let can_place = pool.can_place_limit_order<SUI, USDC>(
            &balance_manager,
            2 * constants::float_scaling(), // price: 2 USDC per SUI
            10 * constants::float_scaling(), // quantity: 10 SUI
            true, // is_bid
            true, // pay_with_deep
            constants::max_u64(), // expire_timestamp
            &clock,
        );
        assert!(!can_place);

        clock.destroy_for_testing();
        return_shared(pool);
        return_shared(balance_manager);
    };

    end(test);
}

/// Test bid limit order with exactly the DEEP needed for taker fees
#[test]
fun test_can_place_limit_order_bid_exact_deep_for_taker_fee() {
    let mut test = begin(OWNER);
    let registry_id = setup_test(OWNER, &mut test);

    // Calculate the exact DEEP fee needed for a bid of 10 SUI at price 2
    // The SUI/DEEP reference pool sets deep_per_base (asset_is_base = true)
    // So deep_quantity = math::mul(base_quantity, deep_per_asset)
    // actual_deep_fee = math::mul(taker_fee, deep_quantity)
    let price = 2 * constants::float_scaling();
    let quantity = 10 * constants::float_scaling();
    let quote_quantity = math::mul(quantity, price);
    let deep_quantity = math::mul(quantity, constants::deep_multiplier()); // Use base quantity
    let exact_deep_fee = math::mul(constants::taker_fee(), deep_quantity);

    // Create balance manager with exactly enough USDC and exactly the DEEP fee needed
    test.next_tx(ALICE);
    let balance_manager_id_alice;
    {
        let mut bm = balance_manager::new(test.ctx());
        bm.deposit(
            mint_for_testing<USDC>(quote_quantity, test.ctx()),
            test.ctx(),
        );
        bm.deposit(
            mint_for_testing<DEEP>(exact_deep_fee, test.ctx()),
            test.ctx(),
        );
        balance_manager_id_alice = bm.id();
        transfer::public_share_object(bm);
    };

    // Create balance manager for Bob with funds for reference pool setup
    let balance_manager_id_bob = create_acct_and_share_with_funds(
        BOB,
        1000000 * constants::float_scaling(),
        &mut test,
    );

    // Setup pool with reference pool (non-whitelisted) so DEEP is required for fees
    let pool_id = setup_pool_with_default_fees_and_reference_pool<SUI, USDC, SUI, DEEP>(
        BOB,
        registry_id,
        balance_manager_id_bob,
        &mut test,
    );

    test.next_tx(ALICE);
    {
        let pool = test.take_shared_by_id<Pool<SUI, USDC>>(pool_id);
        let balance_manager = test.take_shared_by_id<BalanceManager>(balance_manager_id_alice);
        let clock = clock::create_for_testing(test.ctx());

        // Test: bid for 10 SUI at price 2 with exactly the DEEP needed
        let can_place = pool.can_place_limit_order<SUI, USDC>(
            &balance_manager,
            price,
            quantity,
            true, // is_bid
            true, // pay_with_deep
            constants::max_u64(),
            &clock,
        );
        assert!(can_place);

        clock.destroy_for_testing();
        return_shared(pool);
        return_shared(balance_manager);
    };

    end(test);
}

/// Test bid limit order fails with one less unit of DEEP than needed
#[test]
fun test_can_place_limit_order_bid_one_less_deep_than_needed() {
    let mut test = begin(OWNER);
    let registry_id = setup_test(OWNER, &mut test);

    // Calculate the exact DEEP fee needed (using base quantity since asset_is_base = true)
    let price = 2 * constants::float_scaling();
    let quantity = 10 * constants::float_scaling();
    let quote_quantity = math::mul(quantity, price);
    let deep_quantity = math::mul(quantity, constants::deep_multiplier()); // Use base quantity
    let exact_deep_fee = math::mul(constants::taker_fee(), deep_quantity);

    // Create balance manager with exactly enough USDC but one less DEEP than needed
    test.next_tx(ALICE);
    let balance_manager_id_alice;
    {
        let mut bm = balance_manager::new(test.ctx());
        bm.deposit(
            mint_for_testing<USDC>(quote_quantity, test.ctx()),
            test.ctx(),
        );
        bm.deposit(
            mint_for_testing<DEEP>(exact_deep_fee - 1, test.ctx()),
            test.ctx(),
        );
        balance_manager_id_alice = bm.id();
        transfer::public_share_object(bm);
    };

    // Create balance manager for Bob with funds for reference pool setup
    let balance_manager_id_bob = create_acct_and_share_with_funds(
        BOB,
        1000000 * constants::float_scaling(),
        &mut test,
    );

    // Setup pool with reference pool (non-whitelisted) so DEEP is required for fees
    let pool_id = setup_pool_with_default_fees_and_reference_pool<SUI, USDC, SUI, DEEP>(
        BOB,
        registry_id,
        balance_manager_id_bob,
        &mut test,
    );

    test.next_tx(ALICE);
    {
        let pool = test.take_shared_by_id<Pool<SUI, USDC>>(pool_id);
        let balance_manager = test.take_shared_by_id<BalanceManager>(balance_manager_id_alice);
        let clock = clock::create_for_testing(test.ctx());

        // Test: bid for 10 SUI at price 2 with one less DEEP than needed should fail
        let can_place = pool.can_place_limit_order<SUI, USDC>(
            &balance_manager,
            price,
            quantity,
            true, // is_bid
            true, // pay_with_deep
            constants::max_u64(),
            &clock,
        );
        assert!(!can_place);

        clock.destroy_for_testing();
        return_shared(pool);
        return_shared(balance_manager);
    };

    end(test);
}

/// Test ask limit order with sufficient base balance and DEEP for fees
#[test]
fun test_can_place_limit_order_ask_with_deep_sufficient() {
    let mut test = begin(OWNER);
    let registry_id = setup_test(OWNER, &mut test);
    let balance_manager_id_alice = create_acct_and_share_with_funds(
        ALICE,
        1000000 * constants::float_scaling(),
        &mut test,
    );

    // Setup pool with reference pool (non-whitelisted) so DEEP fees are required
    let pool_id = setup_pool_with_default_fees_and_reference_pool<SUI, USDC, SUI, DEEP>(
        ALICE,
        registry_id,
        balance_manager_id_alice,
        &mut test,
    );

    test.next_tx(ALICE);
    {
        let pool = test.take_shared_by_id<Pool<SUI, USDC>>(pool_id);
        let balance_manager = test.take_shared_by_id<BalanceManager>(balance_manager_id_alice);
        let clock = clock::create_for_testing(test.ctx());

        // Test: ask (sell) 10 SUI at price 2 with pay_with_deep = true
        let can_place = pool.can_place_limit_order<SUI, USDC>(
            &balance_manager,
            2 * constants::float_scaling(), // price: 2 USDC per SUI
            10 * constants::float_scaling(), // quantity: 10 SUI
            false, // is_bid = false (ask/sell)
            true, // pay_with_deep
            constants::max_u64(), // expire_timestamp
            &clock,
        );
        assert!(can_place);

        clock.destroy_for_testing();
        return_shared(pool);
        return_shared(balance_manager);
    };

    end(test);
}

/// Test ask limit order with insufficient base balance
#[test]
fun test_can_place_limit_order_ask_insufficient_base() {
    let mut test = begin(OWNER);
    let registry_id = setup_test(OWNER, &mut test);

    // Create balance manager with minimal SUI
    test.next_tx(ALICE);
    let balance_manager_id_alice;
    {
        let mut bm = balance_manager::new(test.ctx());
        // Only deposit 5 SUI (not enough to sell 10 SUI)
        bm.deposit(
            mint_for_testing<SUI>(5 * constants::float_scaling(), test.ctx()),
            test.ctx(),
        );
        bm.deposit(
            mint_for_testing<DEEP>(1000 * constants::float_scaling(), test.ctx()),
            test.ctx(),
        );
        balance_manager_id_alice = bm.id();
        transfer::public_share_object(bm);
    };

    // Setup pool
    let pool_id = setup_pool_with_default_fees<SUI, USDC>(
        OWNER,
        registry_id,
        true,
        false,
        &mut test,
    );

    test.next_tx(ALICE);
    {
        let pool = test.take_shared_by_id<Pool<SUI, USDC>>(pool_id);
        let balance_manager = test.take_shared_by_id<BalanceManager>(balance_manager_id_alice);
        let clock = clock::create_for_testing(test.ctx());

        // Test: try to ask (sell) 10 SUI but only have 5 SUI
        let can_place = pool.can_place_limit_order<SUI, USDC>(
            &balance_manager,
            2 * constants::float_scaling(), // price: 2 USDC per SUI
            10 * constants::float_scaling(), // quantity: 10 SUI
            false, // is_bid = false (ask/sell)
            true, // pay_with_deep
            constants::max_u64(), // expire_timestamp
            &clock,
        );
        assert!(!can_place);

        clock.destroy_for_testing();
        return_shared(pool);
        return_shared(balance_manager);
    };

    end(test);
}

/// Test ask limit order with insufficient DEEP for fees (non-whitelisted pool)
#[test]
fun test_can_place_limit_order_ask_insufficient_deep() {
    let mut test = begin(OWNER);
    let registry_id = setup_test(OWNER, &mut test);

    // Create balance manager with SUI but no DEEP
    test.next_tx(ALICE);
    let balance_manager_id_alice;
    {
        let mut bm = balance_manager::new(test.ctx());
        bm.deposit(
            mint_for_testing<SUI>(100 * constants::float_scaling(), test.ctx()),
            test.ctx(),
        );
        // No DEEP deposited
        balance_manager_id_alice = bm.id();
        transfer::public_share_object(bm);
    };

    // Create balance manager for Bob with funds for reference pool setup
    let balance_manager_id_bob = create_acct_and_share_with_funds(
        BOB,
        1000000 * constants::float_scaling(),
        &mut test,
    );

    // Setup pool with reference pool (non-whitelisted) so DEEP is required for fees
    let pool_id = setup_pool_with_default_fees_and_reference_pool<SUI, USDC, SUI, DEEP>(
        BOB,
        registry_id,
        balance_manager_id_bob,
        &mut test,
    );

    test.next_tx(ALICE);
    {
        let pool = test.take_shared_by_id<Pool<SUI, USDC>>(pool_id);
        let balance_manager = test.take_shared_by_id<BalanceManager>(balance_manager_id_alice);
        let clock = clock::create_for_testing(test.ctx());

        // Test: try to ask (sell) 10 SUI with pay_with_deep but no DEEP
        let can_place = pool.can_place_limit_order<SUI, USDC>(
            &balance_manager,
            2 * constants::float_scaling(), // price: 2 USDC per SUI
            10 * constants::float_scaling(), // quantity: 10 SUI
            false, // is_bid = false (ask/sell)
            true, // pay_with_deep
            constants::max_u64(), // expire_timestamp
            &clock,
        );
        assert!(!can_place);

        clock.destroy_for_testing();
        return_shared(pool);
        return_shared(balance_manager);
    };

    end(test);
}

/// Test bid limit order paying fees with input token (quote)
#[test]
fun test_can_place_limit_order_bid_input_fee_sufficient() {
    let mut test = begin(OWNER);
    let registry_id = setup_test(OWNER, &mut test);
    let balance_manager_id_alice = create_acct_and_share_with_funds(
        ALICE,
        1000000 * constants::float_scaling(),
        &mut test,
    );

    // Setup pool
    let pool_id = setup_pool_with_default_fees<SUI, USDC>(
        OWNER,
        registry_id,
        true,
        false,
        &mut test,
    );

    test.next_tx(ALICE);
    {
        let pool = test.take_shared_by_id<Pool<SUI, USDC>>(pool_id);
        let balance_manager = test.take_shared_by_id<BalanceManager>(balance_manager_id_alice);
        let clock = clock::create_for_testing(test.ctx());

        // Test: bid for 10 SUI at price 2 with pay_with_deep = false (pay fees in USDC)
        let can_place = pool.can_place_limit_order<SUI, USDC>(
            &balance_manager,
            2 * constants::float_scaling(), // price: 2 USDC per SUI
            10 * constants::float_scaling(), // quantity: 10 SUI
            true, // is_bid
            false, // pay_with_deep = false (fees in quote)
            constants::max_u64(), // expire_timestamp
            &clock,
        );
        assert!(can_place);

        clock.destroy_for_testing();
        return_shared(pool);
        return_shared(balance_manager);
    };

    end(test);
}

/// Test ask limit order paying fees with input token (base)
#[test]
fun test_can_place_limit_order_ask_input_fee_sufficient() {
    let mut test = begin(OWNER);
    let registry_id = setup_test(OWNER, &mut test);
    let balance_manager_id_alice = create_acct_and_share_with_funds(
        ALICE,
        1000000 * constants::float_scaling(),
        &mut test,
    );

    // Setup pool
    let pool_id = setup_pool_with_default_fees<SUI, USDC>(
        OWNER,
        registry_id,
        true,
        false,
        &mut test,
    );

    test.next_tx(ALICE);
    {
        let pool = test.take_shared_by_id<Pool<SUI, USDC>>(pool_id);
        let balance_manager = test.take_shared_by_id<BalanceManager>(balance_manager_id_alice);
        let clock = clock::create_for_testing(test.ctx());

        // Test: ask (sell) 10 SUI at price 2 with pay_with_deep = false (pay fees in SUI)
        let can_place = pool.can_place_limit_order<SUI, USDC>(
            &balance_manager,
            2 * constants::float_scaling(), // price: 2 USDC per SUI
            10 * constants::float_scaling(), // quantity: 10 SUI
            false, // is_bid = false (ask/sell)
            false, // pay_with_deep = false (fees in base)
            constants::max_u64(), // expire_timestamp
            &clock,
        );
        assert!(can_place);

        clock.destroy_for_testing();
        return_shared(pool);
        return_shared(balance_manager);
    };

    end(test);
}

/// Test ask limit order paying fees with input token but insufficient base (need extra for fees)
#[test]
fun test_can_place_limit_order_ask_input_fee_insufficient() {
    let mut test = begin(OWNER);
    let registry_id = setup_test(OWNER, &mut test);

    // Create balance manager with only 9 SUI (not enough to sell 10 SUI + fees)
    test.next_tx(ALICE);
    let balance_manager_id_alice;
    {
        let mut bm = balance_manager::new(test.ctx());
        // Deposit only 9 SUI - not enough to sell 10 SUI when fees are in base
        bm.deposit(
            mint_for_testing<SUI>(9 * constants::float_scaling(), test.ctx()),
            test.ctx(),
        );
        balance_manager_id_alice = bm.id();
        transfer::public_share_object(bm);
    };

    // Setup pool
    let pool_id = setup_pool_with_default_fees<SUI, USDC>(
        OWNER,
        registry_id,
        true,
        false,
        &mut test,
    );

    test.next_tx(ALICE);
    {
        let pool = test.take_shared_by_id<Pool<SUI, USDC>>(pool_id);
        let balance_manager = test.take_shared_by_id<BalanceManager>(balance_manager_id_alice);
        let clock = clock::create_for_testing(test.ctx());

        // Test: try to ask (sell) 10 SUI with pay_with_deep = false
        // Should fail because we need 10 SUI + fees, but only have 9 SUI
        let can_place = pool.can_place_limit_order<SUI, USDC>(
            &balance_manager,
            2 * constants::float_scaling(), // price: 2 USDC per SUI
            10 * constants::float_scaling(), // quantity: 10 SUI
            false, // is_bid = false (ask/sell)
            false, // pay_with_deep = false (fees in base)
            constants::max_u64(), // expire_timestamp
            &clock,
        );
        assert!(!can_place);

        clock.destroy_for_testing();
        return_shared(pool);
        return_shared(balance_manager);
    };

    end(test);
}

/// Test limit order for zero quantity (edge case)
#[test]
fun test_can_place_limit_order_zero_quantity() {
    let mut test = begin(OWNER);
    let registry_id = setup_test(OWNER, &mut test);
    let balance_manager_id_alice = create_acct_and_share_with_funds(
        ALICE,
        1000000 * constants::float_scaling(),
        &mut test,
    );

    let pool_id = setup_pool_with_default_fees<SUI, USDC>(
        OWNER,
        registry_id,
        true,
        false,
        &mut test,
    );

    test.next_tx(ALICE);
    {
        let pool = test.take_shared_by_id<Pool<SUI, USDC>>(pool_id);
        let balance_manager = test.take_shared_by_id<BalanceManager>(balance_manager_id_alice);
        let clock = clock::create_for_testing(test.ctx());

        // Test: zero quantity should return false (fails min_size check)
        let can_place = pool.can_place_limit_order<SUI, USDC>(
            &balance_manager,
            2 * constants::float_scaling(), // price: 2 USDC per SUI
            0, // quantity: 0
            true, // is_bid
            true, // pay_with_deep
            constants::max_u64(), // expire_timestamp
            &clock,
        );
        assert!(!can_place);

        clock.destroy_for_testing();
        return_shared(pool);
        return_shared(balance_manager);
    };

    end(test);
}

/// Test limit order exactly at the limit of available balance
#[test]
fun test_can_place_limit_order_bid_exact_balance() {
    let mut test = begin(OWNER);
    let registry_id = setup_test(OWNER, &mut test);

    // Create Alice's balance manager with exactly enough USDC to bid for 10 SUI at price 2
    test.next_tx(ALICE);
    let balance_manager_id_alice;
    {
        let mut bm = balance_manager::new(test.ctx());
        // 20 USDC to buy 10 SUI at price 2
        bm.deposit(
            mint_for_testing<USDC>(20 * constants::float_scaling(), test.ctx()),
            test.ctx(),
        );
        // Enough DEEP for fees
        bm.deposit(
            mint_for_testing<DEEP>(1000 * constants::float_scaling(), test.ctx()),
            test.ctx(),
        );
        balance_manager_id_alice = bm.id();
        transfer::public_share_object(bm);
    };

    // Setup pool (whitelisted, so DEEP fees are 0)
    let pool_id = setup_pool_with_default_fees<SUI, USDC>(
        OWNER,
        registry_id,
        true,
        false,
        &mut test,
    );

    test.next_tx(ALICE);
    {
        let pool = test.take_shared_by_id<Pool<SUI, USDC>>(pool_id);
        let balance_manager = test.take_shared_by_id<BalanceManager>(balance_manager_id_alice);
        let clock = clock::create_for_testing(test.ctx());

        // Test: bid for exactly 10 SUI at price 2 with exactly 20 USDC
        let can_place = pool.can_place_limit_order<SUI, USDC>(
            &balance_manager,
            2 * constants::float_scaling(), // price: 2 USDC per SUI
            10 * constants::float_scaling(), // quantity: 10 SUI
            true, // is_bid
            true, // pay_with_deep
            constants::max_u64(), // expire_timestamp
            &clock,
        );
        assert!(can_place);

        // Test: try to bid for 11 SUI at price 2 (need 22 USDC, only have 20)
        let can_place_more = pool.can_place_limit_order<SUI, USDC>(
            &balance_manager,
            2 * constants::float_scaling(), // price: 2 USDC per SUI
            11 * constants::float_scaling(), // quantity: 11 SUI
            true, // is_bid
            true, // pay_with_deep
            constants::max_u64(), // expire_timestamp
            &clock,
        );
        assert!(!can_place_more);

        clock.destroy_for_testing();
        return_shared(pool);
        return_shared(balance_manager);
    };

    end(test);
}

/// Test limit order with different prices
#[test]
fun test_can_place_limit_order_price_variations() {
    let mut test = begin(OWNER);
    let registry_id = setup_test(OWNER, &mut test);

    // Create balance manager with 100 USDC
    test.next_tx(ALICE);
    let balance_manager_id_alice;
    {
        let mut bm = balance_manager::new(test.ctx());
        bm.deposit(
            mint_for_testing<USDC>(100 * constants::float_scaling(), test.ctx()),
            test.ctx(),
        );
        bm.deposit(
            mint_for_testing<DEEP>(1000 * constants::float_scaling(), test.ctx()),
            test.ctx(),
        );
        balance_manager_id_alice = bm.id();
        transfer::public_share_object(bm);
    };

    // Setup pool (whitelisted)
    let pool_id = setup_pool_with_default_fees<SUI, USDC>(
        OWNER,
        registry_id,
        true,
        false,
        &mut test,
    );

    test.next_tx(ALICE);
    {
        let pool = test.take_shared_by_id<Pool<SUI, USDC>>(pool_id);
        let balance_manager = test.take_shared_by_id<BalanceManager>(balance_manager_id_alice);
        let clock = clock::create_for_testing(test.ctx());

        // Test: bid for 10 SUI at price 5 (need 50 USDC, have 100)
        let can_place_low_price = pool.can_place_limit_order<SUI, USDC>(
            &balance_manager,
            5 * constants::float_scaling(), // price: 5 USDC per SUI
            10 * constants::float_scaling(), // quantity: 10 SUI
            true, // is_bid
            true, // pay_with_deep
            constants::max_u64(), // expire_timestamp
            &clock,
        );
        assert!(can_place_low_price);

        // Test: bid for 10 SUI at price 15 (need 150 USDC, only have 100)
        let can_place_high_price = pool.can_place_limit_order<SUI, USDC>(
            &balance_manager,
            15 * constants::float_scaling(), // price: 15 USDC per SUI
            10 * constants::float_scaling(), // quantity: 10 SUI
            true, // is_bid
            true, // pay_with_deep
            constants::max_u64(), // expire_timestamp
            &clock,
        );
        assert!(!can_place_high_price);

        clock.destroy_for_testing();
        return_shared(pool);
        return_shared(balance_manager);
    };

    end(test);
}

/// Test that fee_penalty_multiplier (1.25) is correctly applied only once
/// For a sell order of 1 SUI with input token fee:
/// required_base = quantity * (1 + fee_penalty_multiplier * taker_fee)
///               = 1 * (1 + 1.25 * 0.001) = 1.00125 SUI
#[test]
fun test_can_place_limit_order_fee_penalty_not_doubled() {
    let mut test = begin(OWNER);
    let registry_id = setup_test(OWNER, &mut test);

    // Calculate exact required amount:
    // taker_fee = 1_000_000 (0.001 or 0.1%)
    // fee_penalty_multiplier = 1_250_000_000 (1.25)
    // For 1 SUI (1_000_000_000 base units):
    // fee_balances.base() = 1_000_000_000 * 1.25 = 1_250_000_000
    // fee_base = 1_250_000_000 * 0.001 = 1_250_000
    // required_base = 1_000_000_000 + 1_250_000 = 1_001_250_000
    let quantity = constants::float_scaling(); // 1 SUI = 1_000_000_000
    let required_with_fee = 1_001_250_000u64; // 1.00125 SUI

    // Create balance manager for setup with lots of funds
    let balance_manager_id_setup = create_acct_and_share_with_funds(
        OWNER,
        1000000 * constants::float_scaling(),
        &mut test,
    );

    // Create balance manager with exactly enough (should pass)
    test.next_tx(ALICE);
    let balance_manager_id_exact;
    {
        let mut bm = balance_manager::new(test.ctx());
        bm.deposit(
            mint_for_testing<SUI>(required_with_fee, test.ctx()),
            test.ctx(),
        );
        balance_manager_id_exact = bm.id();
        transfer::public_share_object(bm);
    };

    // Create balance manager with 1 less (should fail)
    test.next_tx(BOB);
    let balance_manager_id_insufficient;
    {
        let mut bm = balance_manager::new(test.ctx());
        bm.deposit(
            mint_for_testing<SUI>(required_with_fee - 1, test.ctx()),
            test.ctx(),
        );
        balance_manager_id_insufficient = bm.id();
        transfer::public_share_object(bm);
    };

    // Setup pool with reference pool to get proper fees (non-whitelisted)
    let pool_id = setup_pool_with_default_fees_and_reference_pool<SUI, USDC, SUI, DEEP>(
        OWNER,
        registry_id,
        balance_manager_id_setup,
        &mut test,
    );

    test.next_tx(ALICE);
    {
        let pool = test.take_shared_by_id<Pool<SUI, USDC>>(pool_id);
        let balance_manager_exact = test.take_shared_by_id<BalanceManager>(
            balance_manager_id_exact,
        );
        let balance_manager_insufficient = test.take_shared_by_id<BalanceManager>(
            balance_manager_id_insufficient,
        );
        let clock = clock::create_for_testing(test.ctx());

        // Verify taker fee is set correctly
        let (taker_fee, _, _) = pool.pool_trade_params();
        assert!(taker_fee == constants::taker_fee());

        // Test with exactly enough balance - should pass
        let can_place_exact = pool.can_place_limit_order<SUI, USDC>(
            &balance_manager_exact,
            1 * constants::float_scaling(), // price: 1 USDC per SUI
            quantity, // quantity: 1 SUI
            false, // is_bid = false (ask/sell)
            false, // pay_with_deep = false (fees in base)
            constants::max_u64(), // expire_timestamp
            &clock,
        );
        assert!(can_place_exact);

        // Test with 1 unit less - should fail
        let can_place_insufficient = pool.can_place_limit_order<SUI, USDC>(
            &balance_manager_insufficient,
            1 * constants::float_scaling(), // price: 1 USDC per SUI
            quantity, // quantity: 1 SUI
            false, // is_bid = false (ask/sell)
            false, // pay_with_deep = false (fees in base)
            constants::max_u64(), // expire_timestamp
            &clock,
        );
        assert!(!can_place_insufficient);

        clock.destroy_for_testing();
        return_shared(pool);
        return_shared(balance_manager_exact);
        return_shared(balance_manager_insufficient);
    };

    end(test);
}

/// Test limit order with expired timestamp (should return false even with sufficient balance)
#[test]
fun test_can_place_limit_order_expired_timestamp() {
    let mut test = begin(OWNER);
    let registry_id = setup_test(OWNER, &mut test);
    let balance_manager_id_alice = create_acct_and_share_with_funds(
        ALICE,
        1000000 * constants::float_scaling(),
        &mut test,
    );

    // Setup pool
    let pool_id = setup_pool_with_default_fees<SUI, USDC>(
        OWNER,
        registry_id,
        true,
        false,
        &mut test,
    );

    test.next_tx(ALICE);
    {
        let pool = test.take_shared_by_id<Pool<SUI, USDC>>(pool_id);
        let balance_manager = test.take_shared_by_id<BalanceManager>(balance_manager_id_alice);
        let mut clock = clock::create_for_testing(test.ctx());

        // Set clock to 1000ms
        clock.set_for_testing(1000);

        // Test: sufficient balance but expire_timestamp is in the past (500ms < 1000ms)
        // Should return false because the order would be expired
        let can_place = pool.can_place_limit_order<SUI, USDC>(
            &balance_manager,
            2 * constants::float_scaling(), // price: 2 USDC per SUI
            10 * constants::float_scaling(), // quantity: 10 SUI
            true, // is_bid
            true, // pay_with_deep
            500, // expire_timestamp: 500ms (in the past)
            &clock,
        );
        assert!(!can_place);

        // Test: same order but with future expire_timestamp should succeed
        let can_place_future = pool.can_place_limit_order<SUI, USDC>(
            &balance_manager,
            2 * constants::float_scaling(), // price: 2 USDC per SUI
            10 * constants::float_scaling(), // quantity: 10 SUI
            true, // is_bid
            true, // pay_with_deep
            2000, // expire_timestamp: 2000ms (in the future)
            &clock,
        );
        assert!(can_place_future);

        // Test: expire_timestamp exactly at current time should return true
        // (order is valid at the moment of expiration)
        let can_place_exact = pool.can_place_limit_order<SUI, USDC>(
            &balance_manager,
            2 * constants::float_scaling(), // price: 2 USDC per SUI
            10 * constants::float_scaling(), // quantity: 10 SUI
            true, // is_bid
            true, // pay_with_deep
            1001, // expire_timestamp: 1001ms (just after current time)
            &clock,
        );
        assert!(can_place_exact);

        clock.destroy_for_testing();
        return_shared(pool);
        return_shared(balance_manager);
    };

    end(test);
}

/// Test that can_place_limit_order includes settled balances
/// Without settled balances, Alice wouldn't have enough USDC to place a bid.
/// With settled balances from a previous trade, she can place the order.
#[test]
fun test_can_place_limit_order_with_settled_balances() {
    let mut test = begin(OWNER);
    let registry_id = setup_test(OWNER, &mut test);

    // Create Alice's balance manager with only SUI (no USDC)
    test.next_tx(ALICE);
    let balance_manager_id_alice;
    {
        let mut bm = balance_manager::new(test.ctx());
        // Alice has 100 SUI but NO USDC
        bm.deposit(
            mint_for_testing<SUI>(100 * constants::float_scaling(), test.ctx()),
            test.ctx(),
        );
        bm.deposit(
            mint_for_testing<DEEP>(1000 * constants::float_scaling(), test.ctx()),
            test.ctx(),
        );
        balance_manager_id_alice = bm.id();
        transfer::public_share_object(bm);
    };

    // Create Bob's balance manager with USDC to buy Alice's SUI
    test.next_tx(BOB);
    let balance_manager_id_bob;
    {
        let mut bm = balance_manager::new(test.ctx());
        // Bob has USDC to buy SUI
        bm.deposit(
            mint_for_testing<USDC>(200 * constants::float_scaling(), test.ctx()),
            test.ctx(),
        );
        bm.deposit(
            mint_for_testing<DEEP>(1000 * constants::float_scaling(), test.ctx()),
            test.ctx(),
        );
        balance_manager_id_bob = bm.id();
        transfer::public_share_object(bm);
    };

    // Setup whitelisted pool (no DEEP fees required for simplicity)
    let pool_id = setup_pool_with_default_fees<SUI, USDC>(
        OWNER,
        registry_id,
        true,
        false,
        &mut test,
    );

    // Alice places a limit sell order: sell 10 SUI at price 2 USDC per SUI
    let client_order_id = 1;
    place_limit_order<SUI, USDC>(
        ALICE,
        pool_id,
        balance_manager_id_alice,
        client_order_id,
        constants::no_restriction(),
        constants::self_matching_allowed(),
        2 * constants::float_scaling(), // price: 2 USDC per SUI
        10 * constants::float_scaling(), // quantity: 10 SUI
        false, // is_bid = false (sell/ask)
        true, // pay_with_deep
        constants::max_u64(),
        &mut test,
    );

    // Bob places a market buy order: buy 10 SUI (pays 20 USDC)
    // This fills Alice's order, giving Alice 20 USDC in settled balances
    place_market_order<SUI, USDC>(
        BOB,
        pool_id,
        balance_manager_id_bob,
        2,
        constants::self_matching_allowed(),
        10 * constants::float_scaling(), // quantity: 10 SUI
        true, // is_bid = true (buy)
        true, // pay_with_deep
        &mut test,
    );

    // Now test: Alice has 0 direct USDC, but has 20 USDC settled from the trade
    // She should be able to place a bid order for 5 SUI at price 2 (needs 10 USDC)
    test.next_tx(ALICE);
    {
        let pool = test.take_shared_by_id<Pool<SUI, USDC>>(pool_id);
        let balance_manager_alice = test.take_shared_by_id<BalanceManager>(
            balance_manager_id_alice,
        );
        let clock = clock::create_for_testing(test.ctx());

        // Verify Alice has 0 direct USDC balance
        let direct_usdc_balance = balance_manager_alice.balance<USDC>();
        assert!(direct_usdc_balance == 0);

        // But can_place_limit_order should return true because of settled balances
        // Bid for 5 SUI at price 2 = 10 USDC required (she has 20 USDC settled)
        let can_place = pool.can_place_limit_order<SUI, USDC>(
            &balance_manager_alice,
            2 * constants::float_scaling(), // price: 2 USDC per SUI
            5 * constants::float_scaling(), // quantity: 5 SUI
            true, // is_bid = true (buy)
            true, // pay_with_deep
            constants::max_u64(),
            &clock,
        );
        assert!(can_place);

        // Also verify that without enough settled balance, it would fail
        // Bid for 15 SUI at price 2 = 30 USDC required (she only has 20 USDC settled)
        let can_place_too_much = pool.can_place_limit_order<SUI, USDC>(
            &balance_manager_alice,
            2 * constants::float_scaling(), // price: 2 USDC per SUI
            15 * constants::float_scaling(), // quantity: 15 SUI
            true, // is_bid = true (buy)
            true, // pay_with_deep
            constants::max_u64(),
            &clock,
        );
        assert!(!can_place_too_much);

        clock.destroy_for_testing();
        return_shared(pool);
        return_shared(balance_manager_alice);
    };

    end(test);
}

/// Test limit order with price = 0 (should fail min price check)
#[test]
fun test_can_place_limit_order_price_zero() {
    let mut test = begin(OWNER);
    let registry_id = setup_test(OWNER, &mut test);
    let balance_manager_id_alice = create_acct_and_share_with_funds(
        ALICE,
        1000000 * constants::float_scaling(),
        &mut test,
    );

    let pool_id = setup_pool_with_default_fees<SUI, USDC>(
        OWNER,
        registry_id,
        true,
        false,
        &mut test,
    );

    test.next_tx(ALICE);
    {
        let pool = test.take_shared_by_id<Pool<SUI, USDC>>(pool_id);
        let balance_manager = test.take_shared_by_id<BalanceManager>(balance_manager_id_alice);
        let clock = clock::create_for_testing(test.ctx());

        // Test: price = 0 should return false (fails min price check)
        let can_place = pool.can_place_limit_order<SUI, USDC>(
            &balance_manager,
            0, // price: 0 (below min_price)
            10 * constants::float_scaling(), // quantity: 10 SUI
            true, // is_bid
            true, // pay_with_deep
            constants::max_u64(), // expire_timestamp
            &clock,
        );
        assert!(!can_place);

        clock.destroy_for_testing();
        return_shared(pool);
        return_shared(balance_manager);
    };

    end(test);
}

/// Test limit order with price = max_u64 (should fail max price check)
#[test]
fun test_can_place_limit_order_price_max_u64() {
    let mut test = begin(OWNER);
    let registry_id = setup_test(OWNER, &mut test);
    let balance_manager_id_alice = create_acct_and_share_with_funds(
        ALICE,
        1000000 * constants::float_scaling(),
        &mut test,
    );

    let pool_id = setup_pool_with_default_fees<SUI, USDC>(
        OWNER,
        registry_id,
        true,
        false,
        &mut test,
    );

    test.next_tx(ALICE);
    {
        let pool = test.take_shared_by_id<Pool<SUI, USDC>>(pool_id);
        let balance_manager = test.take_shared_by_id<BalanceManager>(balance_manager_id_alice);
        let clock = clock::create_for_testing(test.ctx());

        // Test: price = max_u64 should return false (exceeds max_price)
        let can_place = pool.can_place_limit_order<SUI, USDC>(
            &balance_manager,
            constants::max_u64(), // price: max_u64 (above max_price)
            10 * constants::float_scaling(), // quantity: 10 SUI
            true, // is_bid
            true, // pay_with_deep
            constants::max_u64(), // expire_timestamp
            &clock,
        );
        assert!(!can_place);

        clock.destroy_for_testing();
        return_shared(pool);
        return_shared(balance_manager);
    };

    end(test);
}

/// Test that can_place_market_order includes settled balances
/// Without settled balances, Alice wouldn't have enough USDC to place a market bid.
/// With settled balances from a previous trade, she can place the order.
#[test]
fun test_can_place_market_order_with_settled_balances() {
    let mut test = begin(OWNER);
    let registry_id = setup_test(OWNER, &mut test);

    // Create Alice's balance manager with only SUI (no USDC)
    test.next_tx(ALICE);
    let balance_manager_id_alice;
    {
        let mut bm = balance_manager::new(test.ctx());
        // Alice has 100 SUI but NO USDC
        bm.deposit(
            mint_for_testing<SUI>(100 * constants::float_scaling(), test.ctx()),
            test.ctx(),
        );
        bm.deposit(
            mint_for_testing<DEEP>(1000 * constants::float_scaling(), test.ctx()),
            test.ctx(),
        );
        balance_manager_id_alice = bm.id();
        transfer::public_share_object(bm);
    };

    // Create Bob's balance manager with USDC to buy Alice's SUI
    test.next_tx(BOB);
    let balance_manager_id_bob;
    {
        let mut bm = balance_manager::new(test.ctx());
        // Bob has USDC to buy SUI
        bm.deposit(
            mint_for_testing<USDC>(200 * constants::float_scaling(), test.ctx()),
            test.ctx(),
        );
        bm.deposit(
            mint_for_testing<DEEP>(1000 * constants::float_scaling(), test.ctx()),
            test.ctx(),
        );
        balance_manager_id_bob = bm.id();
        transfer::public_share_object(bm);
    };

    // Create Carol's balance manager to provide liquidity (sell orders for Alice to buy)
    test.next_tx(@0xCCCC);
    let balance_manager_id_carol;
    {
        let mut bm = balance_manager::new(test.ctx());
        bm.deposit(
            mint_for_testing<SUI>(100 * constants::float_scaling(), test.ctx()),
            test.ctx(),
        );
        bm.deposit(
            mint_for_testing<DEEP>(1000 * constants::float_scaling(), test.ctx()),
            test.ctx(),
        );
        balance_manager_id_carol = bm.id();
        transfer::public_share_object(bm);
    };

    // Setup whitelisted pool
    let pool_id = setup_pool_with_default_fees<SUI, USDC>(
        OWNER,
        registry_id,
        true,
        false,
        &mut test,
    );

    // Alice places a limit sell order: sell 10 SUI at price 2 USDC per SUI
    place_limit_order<SUI, USDC>(
        ALICE,
        pool_id,
        balance_manager_id_alice,
        1,
        constants::no_restriction(),
        constants::self_matching_allowed(),
        2 * constants::float_scaling(),
        10 * constants::float_scaling(),
        false, // sell
        true,
        constants::max_u64(),
        &mut test,
    );

    // Bob places a market buy order: buy 10 SUI (pays 20 USDC)
    // This fills Alice's order, giving Alice 20 USDC in settled balances
    place_market_order<SUI, USDC>(
        BOB,
        pool_id,
        balance_manager_id_bob,
        2,
        constants::self_matching_allowed(),
        10 * constants::float_scaling(),
        true, // buy
        true,
        &mut test,
    );

    // Carol places sell orders so Alice has liquidity to buy against
    place_limit_order<SUI, USDC>(
        @0xCCCC,
        pool_id,
        balance_manager_id_carol,
        3,
        constants::no_restriction(),
        constants::self_matching_allowed(),
        2 * constants::float_scaling(),
        50 * constants::float_scaling(),
        false, // sell
        true,
        constants::max_u64(),
        &mut test,
    );

    // Now test: Alice has 0 direct USDC, but has 20 USDC settled
    // She should be able to place a market bid order
    test.next_tx(ALICE);
    {
        let pool = test.take_shared_by_id<Pool<SUI, USDC>>(pool_id);
        let balance_manager_alice = test.take_shared_by_id<BalanceManager>(
            balance_manager_id_alice,
        );
        let clock = clock::create_for_testing(test.ctx());

        // Verify Alice has 0 direct USDC balance
        let direct_usdc_balance = balance_manager_alice.balance<USDC>();
        assert!(direct_usdc_balance == 0);

        // can_place_market_order should return true because of settled balances
        // Market bid for 5 SUI (will need ~10 USDC, she has 20 settled)
        let can_place = pool.can_place_market_order<SUI, USDC>(
            &balance_manager_alice,
            5 * constants::float_scaling(), // quantity: 5 SUI
            true, // is_bid = true (buy)
            true, // pay_with_deep
            &clock,
        );
        assert!(can_place);

        // Also verify that without enough settled balance, it would fail
        // Market bid for 15 SUI (would need ~30 USDC, she only has 20 settled)
        let can_place_too_much = pool.can_place_market_order<SUI, USDC>(
            &balance_manager_alice,
            15 * constants::float_scaling(), // quantity: 15 SUI
            true, // is_bid = true (buy)
            true, // pay_with_deep
            &clock,
        );
        assert!(!can_place_too_much);

        clock.destroy_for_testing();
        return_shared(pool);
        return_shared(balance_manager_alice);
    };

    end(test);
}

/// Test get_base_quantity_in with multiple price levels
/// Setup: Orders at $3 (qty 10), $2 (qty 5), $1 (qty 25)
/// Target: 50 USDC
/// Expected: Sell 10 SUI at $3 (30 USDC), 5 SUI at $2 (10 USDC), 10 SUI at $1 (10 USDC)
/// Result: 25 base_quantity_in, 50 actual_quote_quantity_out
#[test]
fun test_get_base_quantity_in_multiple_levels() {
    let mut test = begin(OWNER);
    let registry_id = setup_test(OWNER, &mut test);
    let balance_manager_id_alice = create_acct_and_share_with_funds(
        ALICE,
        1000000 * constants::float_scaling(),
        &mut test,
    );

    // Setup pool with reference pool (non-whitelisted) so we can test DEEP fees
    let pool_id = setup_pool_with_default_fees_and_reference_pool<SUI, USDC, SUI, DEEP>(
        ALICE,
        registry_id,
        balance_manager_id_alice,
        &mut test,
    );

    // Place bid orders at different price levels
    // Order 1: Buy 10 SUI at $3 per SUI
    place_limit_order<SUI, USDC>(
        ALICE,
        pool_id,
        balance_manager_id_alice,
        1,
        constants::no_restriction(),
        constants::self_matching_allowed(),
        3 * constants::float_scaling(), // price: $3
        10 * constants::float_scaling(), // quantity: 10 SUI
        true, // is_bid (buy order)
        true, // pay_with_deep
        constants::max_u64(),
        &mut test,
    );

    // Order 2: Buy 5 SUI at $2 per SUI
    place_limit_order<SUI, USDC>(
        ALICE,
        pool_id,
        balance_manager_id_alice,
        2,
        constants::no_restriction(),
        constants::self_matching_allowed(),
        2 * constants::float_scaling(), // price: $2
        5 * constants::float_scaling(), // quantity: 5 SUI
        true, // is_bid
        true,
        constants::max_u64(),
        &mut test,
    );

    // Order 3: Buy 25 SUI at $1 per SUI
    place_limit_order<SUI, USDC>(
        ALICE,
        pool_id,
        balance_manager_id_alice,
        3,
        constants::no_restriction(),
        constants::self_matching_allowed(),
        1 * constants::float_scaling(), // price: $1
        25 * constants::float_scaling(), // quantity: 25 SUI
        true, // is_bid
        true,
        constants::max_u64(),
        &mut test,
    );

    test.next_tx(ALICE);
    {
        let pool = test.take_shared_by_id<Pool<SUI, USDC>>(pool_id);
        let clock = test.take_shared<Clock>();

        // Test 1: Get base quantity needed for 50 USDC with pay_with_deep = true
        let (base_in, quote_out, deep_required) = pool.get_base_quantity_in<SUI, USDC>(
            50 * constants::float_scaling(), // target: 50 USDC
            true, // pay_with_deep
            &clock,
        );

        // Expected: Sell 10 at $3 (30), 5 at $2 (10), 10 at $1 (10) = 25 SUI for 50 USDC
        assert!(base_in == 25 * constants::float_scaling(), 0);
        assert!(quote_out == 50 * constants::float_scaling(), 1);

        // DEEP fee calculation for sell order (is_bid = false):
        // fee_balances = deep_price.fee_quantity(25 SUI, 50 USDC, false)
        // Then multiply by taker_fee (0.001)
        let expected_deep = math::mul(
            constants::taker_fee(),
            math::mul(25 * constants::float_scaling(), constants::deep_multiplier()),
        );
        assert!(deep_required == expected_deep, 2);

        // Test 2: Get base quantity needed for 50 USDC with pay_with_deep = false
        let (base_in_no_deep, quote_out_no_deep, deep_required_no_deep) = pool.get_base_quantity_in<
            SUI,
            USDC,
        >(
            50 * constants::float_scaling(), // target: 50 USDC
            false, // pay_with_deep = false (fees in base)
            &clock,
        );

        // With fees in base, need extra base to cover fees
        // input_fee_rate = fee_penalty_multiplier (1.25) * taker_fee (0.001) = 0.00125
        // base_with_fee = base * (1 + 0.00125) = 25 * 1.00125 = 25.03125
        let input_fee_rate = math::mul(
            constants::fee_penalty_multiplier(),
            constants::taker_fee(),
        );
        let expected_base_with_fee = math::mul(
            25 * constants::float_scaling(),
            constants::float_scaling() + input_fee_rate,
        );

        assert!(base_in_no_deep == expected_base_with_fee, 3);
        assert!(quote_out_no_deep == 50 * constants::float_scaling(), 4);
        assert!(deep_required_no_deep == 0, 5);

        // Test 3: Target close to max liquidity
        // Available: 10 at $3 (30) + 5 at $2 (10) + 25 at $1 (25) = 65 USDC max
        let (base_in_partial, quote_out_partial, _) = pool.get_base_quantity_in<SUI, USDC>(
            60 * constants::float_scaling(), // target: 60 USDC
            true,
            &clock,
        );

        // Should use: 10 at $3 (30) + 5 at $2 (10) + 20 at $1 (20) = 35 SUI for 60 USDC
        assert!(base_in_partial == 35 * constants::float_scaling(), 6);
        assert!(quote_out_partial == 60 * constants::float_scaling(), 7);

        // Test 4: Target exceeding available liquidity
        // Max available: 10*3 + 5*2 + 25*1 = 65 USDC
        let (base_in_exceed, quote_out_exceed, deep_exceed) = pool.get_base_quantity_in<SUI, USDC>(
            100 * constants::float_scaling(), // target: 100 USDC (more than 65 available)
            true,
            &clock,
        );

        // Should return (0, 0, 0) since we can't meet the target
        assert!(base_in_exceed == 0, 8);
        assert!(quote_out_exceed == 0, 9);
        assert!(deep_exceed == 0, 10);

        // Test 5: Target exactly at max liquidity (65 USDC, exactly available)
        let (base_in_65, quote_out_65, deep_65) = pool.get_base_quantity_in<SUI, USDC>(
            65 * constants::float_scaling(), // target: 65 USDC (exact match)
            true,
            &clock,
        );

        // Should use all: 10 at $3 (30) + 5 at $2 (10) + 25 at $1 (25) = 40 SUI for 65 USDC
        assert!(base_in_65 == 40 * constants::float_scaling(), 11);
        assert!(quote_out_65 == 65 * constants::float_scaling(), 12);

        let expected_deep_65 = math::mul(
            constants::taker_fee(),
            math::mul(40 * constants::float_scaling(), constants::deep_multiplier()),
        );
        assert!(deep_65 == expected_deep_65, 13);

        return_shared(pool);
        return_shared(clock);
    };

    end(test);
}

/// Test get_quote_quantity_in with multiple price levels
/// Setup: Sell orders at $1 (qty 25), $2 (qty 5), $3 (qty 10)
/// Target: 30 SUI
/// Expected: Buy 25 SUI at $1 (25 USDC), 5 SUI at $2 (10 USDC) = 30 SUI for 35 USDC
/// Result: 30 base_quantity_out, 35 quote_quantity_in
#[test]
fun test_get_quote_quantity_in_multiple_levels() {
    let mut test = begin(OWNER);
    let registry_id = setup_test(OWNER, &mut test);
    let balance_manager_id_alice = create_acct_and_share_with_funds(
        ALICE,
        1000000 * constants::float_scaling(),
        &mut test,
    );

    // Setup pool with reference pool (non-whitelisted) so we can test DEEP fees
    let pool_id = setup_pool_with_default_fees_and_reference_pool<SUI, USDC, SUI, DEEP>(
        ALICE,
        registry_id,
        balance_manager_id_alice,
        &mut test,
    );

    // Place ask (sell) orders at different price levels
    // Order 1: Sell 25 SUI at $1 per SUI
    place_limit_order<SUI, USDC>(
        ALICE,
        pool_id,
        balance_manager_id_alice,
        1,
        constants::no_restriction(),
        constants::self_matching_allowed(),
        1 * constants::float_scaling(), // price: $1
        25 * constants::float_scaling(), // quantity: 25 SUI
        false, // is_bid = false (sell order)
        true, // pay_with_deep
        constants::max_u64(),
        &mut test,
    );

    // Order 2: Sell 5 SUI at $2 per SUI
    place_limit_order<SUI, USDC>(
        ALICE,
        pool_id,
        balance_manager_id_alice,
        2,
        constants::no_restriction(),
        constants::self_matching_allowed(),
        2 * constants::float_scaling(), // price: $2
        5 * constants::float_scaling(), // quantity: 5 SUI
        false, // is_bid = false
        true,
        constants::max_u64(),
        &mut test,
    );

    // Order 3: Sell 10 SUI at $3 per SUI
    place_limit_order<SUI, USDC>(
        ALICE,
        pool_id,
        balance_manager_id_alice,
        3,
        constants::no_restriction(),
        constants::self_matching_allowed(),
        3 * constants::float_scaling(), // price: $3
        10 * constants::float_scaling(), // quantity: 10 SUI
        false, // is_bid = false
        true,
        constants::max_u64(),
        &mut test,
    );

    test.next_tx(ALICE);
    {
        let pool = test.take_shared_by_id<Pool<SUI, USDC>>(pool_id);
        let clock = test.take_shared<Clock>();

        // Test 1: Get quote quantity needed for 30 SUI with pay_with_deep = true
        let (base_out, quote_in, deep_required) = pool.get_quote_quantity_in<SUI, USDC>(
            30 * constants::float_scaling(), // target: 30 SUI
            true, // pay_with_deep
            &clock,
        );

        // Expected: Buy 25 at $1 (25) + 5 at $2 (10) = 30 SUI for 35 USDC
        assert!(base_out == 30 * constants::float_scaling(), 0);
        assert!(quote_in == 35 * constants::float_scaling(), 1);

        // DEEP fee calculation for buy order (is_bid = true):
        // fee_balances = deep_price.fee_quantity(30 SUI, 35 USDC, true)
        // Then multiply by taker_fee (0.001)
        let expected_deep = math::mul(
            constants::taker_fee(),
            math::mul(30 * constants::float_scaling(), constants::deep_multiplier()),
        );
        assert!(deep_required == expected_deep, 2);

        // Test 2: Get quote quantity needed for 30 SUI with pay_with_deep = false
        let (
            base_out_no_deep,
            quote_in_no_deep,
            deep_required_no_deep,
        ) = pool.get_quote_quantity_in<SUI, USDC>(
            30 * constants::float_scaling(), // target: 30 SUI
            false, // pay_with_deep = false (fees in quote)
            &clock,
        );

        // With fees in quote, need extra quote to cover fees
        // input_fee_rate = fee_penalty_multiplier (1.25) * taker_fee (0.001) = 0.00125
        // quote_with_fee = quote * (1 + 0.00125) = 35 * 1.00125 = 35.04375
        let input_fee_rate = math::mul(
            constants::fee_penalty_multiplier(),
            constants::taker_fee(),
        );
        let expected_quote_with_fee = math::mul(
            35 * constants::float_scaling(),
            constants::float_scaling() + input_fee_rate,
        );

        assert!(base_out_no_deep == 30 * constants::float_scaling(), 3);
        assert!(quote_in_no_deep == expected_quote_with_fee, 4);
        assert!(deep_required_no_deep == 0, 5);

        // Test 3: Target that requires all liquidity (40 SUI total available)
        let (base_out_all, quote_in_all, deep_all) = pool.get_quote_quantity_in<SUI, USDC>(
            40 * constants::float_scaling(), // target: 40 SUI (exact match)
            true,
            &clock,
        );

        // Should use all: 25 at $1 (25) + 5 at $2 (10) + 10 at $3 (30) = 40 SUI for 65 USDC
        assert!(base_out_all == 40 * constants::float_scaling(), 6);
        assert!(quote_in_all == 65 * constants::float_scaling(), 7);

        let expected_deep_all = math::mul(
            constants::taker_fee(),
            math::mul(40 * constants::float_scaling(), constants::deep_multiplier()),
        );
        assert!(deep_all == expected_deep_all, 8);

        // Test 4: Target exceeding available liquidity (50 SUI, only 40 available)
        let (base_out_exceed, quote_in_exceed, deep_exceed) = pool.get_quote_quantity_in<SUI, USDC>(
            50 * constants::float_scaling(), // target: 50 SUI (more than 40 available)
            true,
            &clock,
        );

        // Should return (0, 0, 0) since we can't meet the target
        assert!(base_out_exceed == 0, 9);
        assert!(quote_in_exceed == 0, 10);
        assert!(deep_exceed == 0, 11);

        // Test 5: Small target (5 SUI)
        let (base_out_small, quote_in_small, _) = pool.get_quote_quantity_in<SUI, USDC>(
            5 * constants::float_scaling(), // target: 5 SUI
            true,
            &clock,
        );

        // Should buy 5 at $1 = 5 SUI for 5 USDC
        assert!(base_out_small == 5 * constants::float_scaling(), 12);
        assert!(quote_in_small == 5 * constants::float_scaling(), 13);

        return_shared(pool);
        return_shared(clock);
    };

    end(test);
}

// ============== Fractional target tests ==============

/// Test get_base_quantity_in with fractional target (slightly above round number)
/// Target: 10.0000...01 USDC (10 * float_scaling + 1)
/// This tests the rounding behavior when target is not exactly divisible
#[test]
fun test_get_base_quantity_in_fractional_target() {
    let mut test = begin(OWNER);
    let registry_id = setup_test(OWNER, &mut test);
    let balance_manager_id_alice = create_acct_and_share_with_funds(
        ALICE,
        1000000 * constants::float_scaling(),
        &mut test,
    );

    let pool_id = setup_pool_with_default_fees_and_reference_pool<SUI, USDC, SUI, DEEP>(
        ALICE,
        registry_id,
        balance_manager_id_alice,
        &mut test,
    );

    // Place a bid order at $1 per SUI with plenty of liquidity
    place_limit_order<SUI, USDC>(
        ALICE,
        pool_id,
        balance_manager_id_alice,
        1,
        constants::no_restriction(),
        constants::self_matching_allowed(),
        1 * constants::float_scaling(), // price: $1
        100 * constants::float_scaling(), // quantity: 100 SUI
        true, // is_bid
        true,
        constants::max_u64(),
        &mut test,
    );

    test.next_tx(ALICE);
    {
        let pool = test.take_shared_by_id<Pool<SUI, USDC>>(pool_id);
        let clock = test.take_shared<Clock>();

        // Target: 10 USDC + 1 unit (fractional)
        // At price $1, we need slightly more than 10 base to get 10.0000...01 quote
        // Due to lot_size rounding, we should get at least the target (possibly more)
        let fractional_target = 10 * constants::float_scaling() + 1;
        let (base_in, quote_out, _) = pool.get_base_quantity_in<SUI, USDC>(
            fractional_target,
            true,
            &clock,
        );

        // base_in should be rounded to lot_size and sufficient to cover target
        // quote_out should be >= fractional_target
        assert!(quote_out >= fractional_target, 0);
        // base_in should be a multiple of lot_size
        assert!(base_in % constants::lot_size() == 0, 1);
        // At $1, base_in * price = quote_out, so base_in should cover the target
        assert!(base_in >= 10 * constants::float_scaling(), 2);

        return_shared(pool);
        return_shared(clock);
    };

    end(test);
}

/// Test get_quote_quantity_in with fractional target (slightly above round number)
/// Target: 10.0000...01 SUI (10 * float_scaling + 1)
/// This tests the rounding behavior when target is not exactly divisible
#[test]
fun test_get_quote_quantity_in_fractional_target() {
    let mut test = begin(OWNER);
    let registry_id = setup_test(OWNER, &mut test);
    let balance_manager_id_alice = create_acct_and_share_with_funds(
        ALICE,
        1000000 * constants::float_scaling(),
        &mut test,
    );

    let pool_id = setup_pool_with_default_fees_and_reference_pool<SUI, USDC, SUI, DEEP>(
        ALICE,
        registry_id,
        balance_manager_id_alice,
        &mut test,
    );

    // Place an ask (sell) order at $1 per SUI with plenty of liquidity
    place_limit_order<SUI, USDC>(
        ALICE,
        pool_id,
        balance_manager_id_alice,
        1,
        constants::no_restriction(),
        constants::self_matching_allowed(),
        1 * constants::float_scaling(), // price: $1
        100 * constants::float_scaling(), // quantity: 100 SUI
        false, // is_bid = false (sell order)
        true,
        constants::max_u64(),
        &mut test,
    );

    test.next_tx(ALICE);
    {
        let pool = test.take_shared_by_id<Pool<SUI, USDC>>(pool_id);
        let clock = test.take_shared<Clock>();

        // Target: 10 SUI + 1 unit (fractional)
        // We want to buy slightly more than 10 SUI
        // Due to lot_size rounding, we should get at least the target (possibly more)
        let fractional_target = 10 * constants::float_scaling() + 1;
        let (base_out, quote_in, _) = pool.get_quote_quantity_in<SUI, USDC>(
            fractional_target,
            true,
            &clock,
        );

        // base_out should be >= fractional_target (we get at least what we asked for)
        assert!(base_out >= fractional_target, 0);
        // base_out should be a multiple of lot_size (rounded up from target)
        assert!(base_out % constants::lot_size() == 0, 1);
        // At $1, quote needed = base bought, so quote_in should match base_out
        assert!(quote_in == base_out, 2);

        return_shared(pool);
        return_shared(clock);
    };

    end(test);
}

#[test]
fun pool_referral_multiplier_ok() {
    let mut test = begin(OWNER);
    let pool_id = setup_everything<SUI, USDC, SUI, DEEP>(&mut test);
    let referral_id;
    test.next_tx(ALICE);
    {
        let mut pool = test.take_shared_by_id<Pool<SUI, USDC>>(pool_id);
        referral_id = pool.mint_referral(500_000_000, test.ctx());
        return_shared(pool);
    };

    test.next_tx(ALICE);
    {
        let pool = test.take_shared_by_id<Pool<SUI, USDC>>(pool_id);
        let referral = test.take_shared_by_id<DeepBookPoolReferral>(referral_id);
        let multiplier = pool.pool_referral_multiplier(&referral);
        assert_eq!(multiplier, 500_000_000);
        return_shared(referral);
        return_shared(pool);
    };

    end(test);
}

#[test]
fun pool_referral_multiplier_after_update() {
    let mut test = begin(OWNER);
    let pool_id = setup_everything<SUI, USDC, SUI, DEEP>(&mut test);
    let referral_id;
    test.next_tx(ALICE);
    {
        let mut pool = test.take_shared_by_id<Pool<SUI, USDC>>(pool_id);
        referral_id = pool.mint_referral(100_000_000, test.ctx());
        return_shared(pool);
    };

    test.next_tx(ALICE);
    {
        let pool = test.take_shared_by_id<Pool<SUI, USDC>>(pool_id);
        let referral = test.take_shared_by_id<DeepBookPoolReferral>(referral_id);
        let multiplier = pool.pool_referral_multiplier(&referral);
        assert_eq!(multiplier, 100_000_000);
        return_shared(referral);
        return_shared(pool);
    };

    test.next_tx(ALICE);
    {
        let mut pool = test.take_shared_by_id<Pool<SUI, USDC>>(pool_id);
        let referral = test.take_shared_by_id<DeepBookPoolReferral>(referral_id);
        pool.update_pool_referral_multiplier(&referral, 2_000_000_000, test.ctx());
        return_shared(referral);
        return_shared(pool);
    };

    test.next_tx(ALICE);
    {
        let pool = test.take_shared_by_id<Pool<SUI, USDC>>(pool_id);
        let referral = test.take_shared_by_id<DeepBookPoolReferral>(referral_id);
        let multiplier = pool.pool_referral_multiplier(&referral);
        assert_eq!(multiplier, 2_000_000_000);
        return_shared(referral);
        return_shared(pool);
    };

    end(test);
}

#[test, expected_failure(abort_code = ::deepbook::pool::EWrongPoolReferral)]
fun pool_referral_multiplier_wrong_pool() {
    let mut test = begin(OWNER);
    let pool_id_1 = setup_everything<SUI, USDC, SUI, DEEP>(&mut test);
    let referral_id;

    test.next_tx(ALICE);
    {
        let mut pool = test.take_shared_by_id<Pool<SUI, USDC>>(pool_id_1);
        referral_id = pool.mint_referral(100_000_000, test.ctx());
        return_shared(pool);
    };

    test.next_tx(OWNER);
    let pool_id_2;
    {
        let mut registry = test.take_shared<Registry>();
        pool_id_2 =
            pool::create_permissionless_pool<SPAM, USDC>(
                &mut registry,
                constants::tick_size(),
                constants::lot_size(),
                constants::min_size(),
                mint_for_testing<DEEP>(constants::pool_creation_fee(), test.ctx()),
                test.ctx(),
            );
        return_shared(registry);
    };

    test.next_tx(ALICE);
    {
        let pool = test.take_shared_by_id<Pool<SPAM, USDC>>(pool_id_2);
        let referral = test.take_shared_by_id<DeepBookPoolReferral>(referral_id);
        pool.pool_referral_multiplier(&referral);
    };

    abort
}

#[test, expected_failure(abort_code = ::deepbook::pool::EWrongPoolReferral)]
fun get_pool_referral_balances_wrong_pool() {
    let mut test = begin(OWNER);
    let pool_id_1 = setup_everything<SUI, USDC, SUI, DEEP>(&mut test);
    let referral_id;

    test.next_tx(ALICE);
    {
        let mut pool = test.take_shared_by_id<Pool<SUI, USDC>>(pool_id_1);
        referral_id = pool.mint_referral(100_000_000, test.ctx());
        return_shared(pool);
    };

    test.next_tx(OWNER);
    let pool_id_2;
    {
        let mut registry = test.take_shared<Registry>();
        pool_id_2 =
            pool::create_permissionless_pool<SPAM, USDC>(
                &mut registry,
                constants::tick_size(),
                constants::lot_size(),
                constants::min_size(),
                mint_for_testing<DEEP>(constants::pool_creation_fee(), test.ctx()),
                test.ctx(),
            );
        return_shared(registry);
    };

    test.next_tx(ALICE);
    {
        let pool = test.take_shared_by_id<Pool<SPAM, USDC>>(pool_id_2);
        let referral = test.take_shared_by_id<DeepBookPoolReferral>(referral_id);
        pool.get_pool_referral_balances(&referral);
    };

    abort (0)
}

/// Test that swap_exact_base_for_quote_with_manager and swap_exact_quote_for_base_with_manager
/// work correctly when the swap results in zero leftover (base_out = 0 or quote_out = 0).
/// This tests the fix for withdrawing 0 from balance manager.
fun test_swap_with_manager_zero_out(is_base_to_quote: bool) {
    let mut test = begin(OWNER);
    let registry_id = setup_test(OWNER, &mut test);
    let balance_manager_id_alice = create_acct_and_share_with_funds(
        ALICE,
        1000000 * constants::float_scaling(),
        &mut test,
    );
    let pool_id = setup_pool_with_default_fees_and_reference_pool<SUI, USDC, SUI, DEEP>(
        ALICE,
        registry_id,
        balance_manager_id_alice,
        &mut test,
    );

    let price = 2 * constants::float_scaling();
    let quantity = 10 * constants::float_scaling();
    let expire_timestamp = constants::max_u64();
    let pay_with_deep = true;

    // Place a maker order on the opposite side
    // If we're swapping base to quote, we need a bid order to match against
    // If we're swapping quote to base, we need an ask order to match against
    place_limit_order<SUI, USDC>(
        ALICE,
        pool_id,
        balance_manager_id_alice,
        1,
        constants::no_restriction(),
        constants::self_matching_allowed(),
        price,
        quantity,
        is_base_to_quote,
        pay_with_deep,
        expire_timestamp,
        &mut test,
    );

    // Create Bob's balance manager with caps
    let bob_balance_manager_id = create_acct_only_deep_and_share_with_funds(
        BOB,
        1000000 * constants::float_scaling(),
        &mut test,
    );
    create_caps(BOB, bob_balance_manager_id, &mut test);

    // Use an exact lot-size multiple so there's no leftover
    let swap_quantity = 5 * constants::float_scaling();

    if (is_base_to_quote) {
        // Swap exactly 5 SUI for USDC - should result in base_out = 0
        let (base_out, quote_out) = place_exact_base_for_quote_with_manager<SUI, USDC>(
            pool_id,
            BOB,
            bob_balance_manager_id,
            swap_quantity,
            0,
            &mut test,
        );

        // base_out should be 0 (all base was swapped)
        assert!(base_out.value() == 0);
        // quote_out should be swap_quantity * price = 5 * 2 = 10 USDC
        assert!(quote_out.value() == math::mul(swap_quantity, price));

        base_out.burn_for_testing();
        quote_out.burn_for_testing();
    } else {
        // Swap exactly 10 USDC for SUI - should result in quote_out = 0
        let quote_swap_quantity = 10 * constants::float_scaling();
        let (base_out, quote_out) = place_exact_quote_for_base_with_manager<SUI, USDC>(
            pool_id,
            BOB,
            bob_balance_manager_id,
            quote_swap_quantity,
            0,
            &mut test,
        );

        // quote_out should be 0 (all quote was swapped)
        assert!(quote_out.value() == 0);
        // base_out should be quote_swap_quantity / price = 10 / 2 = 5 SUI
        assert!(base_out.value() == math::div(quote_swap_quantity, price));

        base_out.burn_for_testing();
        quote_out.burn_for_testing();
    };

    end(test);
}
