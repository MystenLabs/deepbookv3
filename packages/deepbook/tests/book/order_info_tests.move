// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module deepbook::order_info_tests {
    use std::debug::print;
    use sui::{
        test_scenario::{next_tx, begin, end},
        test_utils::assert_eq,
        object::id_from_address,
    };
    use deepbook::{
        order_info::{Self, OrderInfo},
        math,
        utils,
        account,
        balances,
        fill,
        constants,
    };

    const OWNER: address = @0xF;
    const ALICE: address = @0xA;
    const BOB: address = @0xB;

    #[test]
    // Placing a bid order with quantity 1 at price $1. No fill.
    // No taker fees, so maker fees should apply to entire quantity.
    // Since its a bid, we should be required to transfer 1 USDC into the pool.
    fun calculate_partial_fill_balances_ok() {
        let mut test = begin(OWNER);

        test.next_tx(ALICE);
        let price = 1 * constants::usdc_unit();
        let quantity = 1 * constants::sui_unit();
        let mut order_info = create_order_info_base(ALICE, price, quantity, true, test.ctx().epoch());
        let (settled, owed) = order_info.calculate_partial_fill_balances(constants::taker_fee(), constants::maker_fee());

        assert_eq(settled, balances::new(0, 0, 0));
        assert_eq(owed, balances::new(0, 1 * constants::usdc_unit(), 500_000)); // 5 bps of 1 SUI paid in DEEP

        end(test);
    }

    #[test]
    // Placing a bid order with quantity 10 at price $1.2345. No fill.
    // No taker fees, so maker fees should apply to entire quantity.
    // Since its a bid, we should be required to transfer 1 USDC into the pool.
    fun calculate_partial_fill_balances_precision_ok() {
        let mut test = begin(OWNER);

        test.next_tx(ALICE);
        let price = 1_234_500;
        let quantity = 10 * constants::sui_unit();
        let mut order_info = create_order_info_base(ALICE, price, quantity, true, test.ctx().epoch());
        let (settled, owed) = order_info.calculate_partial_fill_balances(constants::taker_fee(), constants::maker_fee());

        assert_eq(settled, balances::new(0, 0, 0));
        assert_eq(owed, balances::new(0, 12_345_000, 5_000_000)); // 5 bps of 10 SUI paid in DEEP

        end(test);
    }

    #[test]
    // Placing a bid order with quantity 10.86 at price $1.2345. No fill.
    fun calculate_partial_fill_balances_precision2_ok() {
        let mut test = begin(OWNER);

        test.next_tx(ALICE);
        let price = 1_234_500;
        let quantity = 10_860_000_000;
        let mut order_info = create_order_info_base(ALICE, price, quantity, true, test.ctx().epoch());
        let (settled, owed) = order_info.calculate_partial_fill_balances(constants::taker_fee(), constants::maker_fee());

        assert_eq(settled, balances::new(0, 0, 0));
        // USDC owed = 1.2345 * 10.86 = 13.40667 = 13406670
        // DEEP owed = 10.86 * 0.0005 = 0.00543 = 5430000 (9 decimals in DEEP)
        assert_eq(owed, balances::new(0, 13406670, 5430000));

        end(test);
    }

    #[test]
    // Place an ask order with quantity 655.36 at price $19.32. No fill.
    fun calculate_partial_fill_balances_ask_no_fill_ok() {
        let mut test = begin(OWNER);

        test.next_tx(ALICE);
        let price = 19_320_000;
        let quantity = 655_360_000_000;
        let mut order_info = create_order_info_base(ALICE, price, quantity, false, test.ctx().epoch());
        let (settled, owed) = order_info.calculate_partial_fill_balances(constants::taker_fee(), constants::maker_fee());

        assert_eq(settled, balances::new(0, 0, 0));
        // Since its an ask, transfer quantity amount worth of base token.
        // DEEP owed = 655.36 * 0.0005 = 0.32768 = 327680000 (9 decimals in DEEP)
        assert_eq(owed, balances::new(655_360_000_000, 0, 327_680_000));

        end(test);
    }

    #[test]
    // Taker: bid order with quantity 10 at price $5
    // Maker: ask order with quantity 5 at price $5
    fun match_maker_partial_fill_bid_ok() {
        let mut test = begin(OWNER);
            
        test.next_tx(ALICE);
        let price = 5 * constants::usdc_unit();
        let taker_quantity = 10 * constants::sui_unit();
        let maker_quantity = 5 * constants::sui_unit();
        let mut order_info = create_order_info_base(ALICE, price, taker_quantity, true, test.ctx().epoch());
        let mut maker_order = create_order_info_base(BOB, price, maker_quantity, false, test.ctx().epoch()).to_order();
        let has_next = order_info.match_maker(&mut maker_order, 0);
        assert!(has_next, 0);
        assert!(order_info.fills().length() == 1, 0);
        assert!(order_info.executed_quantity() == 5 * constants::sui_unit(), 0);
        assert!(order_info.cumulative_quote_quantity() == 25 * constants::usdc_unit(), 0);
        assert!(order_info.status() == constants::partially_filled(), 0);
        assert!(order_info.remaining_quantity() == 5 * constants::sui_unit(), 0);

        end(test);
    }

    #[test]
    // Taker: bid order with quantity 111 at price $4
    // Maker: ask order with quantity 38.13 at price $3.89
    fun match_maker_partial_fill_ask_ok() {
        let mut test = begin(OWNER);
            
        test.next_tx(ALICE);
        let price = 4 * constants::usdc_unit();
        let taker_quantity = 111 * constants::sui_unit();
        let maker_quantity = 38_130_000_000;
        let mut order_info = create_order_info_base(ALICE, price, taker_quantity, true, test.ctx().epoch());
        let mut maker_order = create_order_info_base(BOB, 3_890_000, maker_quantity, false, test.ctx().epoch()).to_order();
        let has_next = order_info.match_maker(&mut maker_order, 0);
        assert!(has_next, 0);
        assert!(order_info.fills().length() == 1, 0);
        assert!(order_info.executed_quantity() == 38_130_000_000, 0);
        // 38.13 * 3.89 = 148.3257 = 148325700
        assert!(order_info.cumulative_quote_quantity() == 148_325_700, 0);
        assert!(order_info.status() == constants::partially_filled(), 0);
        assert!(order_info.remaining_quantity() == 72_870_000_000, 0);

        end(test);
    }

    #[test]
    // Taker: bid order with quantity 10 at price $5
    // Maker: ask order with quantity 50 at price $5
    fun match_maker_full_fill_ok() {
        let mut test = begin(OWNER);
        
        test.next_tx(ALICE);
        let price = 5 * constants::usdc_unit();
        let taker_quantity = 10 * constants::sui_unit();
        let maker_quantity = 50 * constants::sui_unit();
        let mut order_info = create_order_info_base(ALICE, price, taker_quantity, true, test.ctx().epoch());
        let mut maker_order = create_order_info_base(BOB, price, maker_quantity, false, test.ctx().epoch()).to_order();
        let has_next = order_info.match_maker(&mut maker_order, 0);
        assert!(has_next, 0);
        assert!(order_info.fills().length() == 1, 0);
        assert!(order_info.executed_quantity() == 10 * constants::sui_unit(), 0);
        assert!(order_info.cumulative_quote_quantity() == 50 * constants::usdc_unit(), 0);
        assert!(order_info.status() == constants::filled(), 0);
        assert!(order_info.remaining_quantity() == 0, 0);

        end(test);
    }

    #[test]
    // Place a bid order with quantity 131.11 at price $1813.05. Partial fill of 100.
    fun calculate_partial_fill_balances_bid_partial_fill_ok() {}

    #[test]
    // Place an ask order with quantity 0.005 at price $68,191.55. Partial fill of 0.001.
    fun calculate_partial_fill_balances_ask_partial_fill_ok() {}

    #[test]
    // Place a bid order with quantity 999.99 at price $111.11. Full fill.
    fun calculate_partial_fill_balances_bid_full_fill_ok() {}

    #[test]
    // Place an ask order with quantity 0.0001 at price $1,000,000. Full fill.
    fun calculate_partial_fill_balances_ask_full_fill_ok() {}

    public fun create_order_info_base(
        trader: address,
        price: u64,
        quantity: u64,
        is_bid: bool,
        epoch: u64,
    ): OrderInfo {
        let balance_manager_id = id_from_address(@0x1);
        let order_type = 0;
        let fee_is_deep = true;
        let deep_per_base = 1 * constants::float_scaling();
        let market_order = false;
        let expire_timestamp = constants::max_u64();

        create_order_info(
            balance_manager_id,
            trader,
            order_type,
            price,
            quantity,
            is_bid,
            fee_is_deep,
            epoch,
            expire_timestamp,
            deep_per_base,
            market_order
        )
    }

    public fun create_order_info(
        balance_manager_id: ID,
        trader: address,
        order_type: u8,
        price: u64,
        quantity: u64,
        is_bid: bool,
        fee_is_deep: bool,
        epoch: u64,
        expire_timestamp: u64,
        deep_per_base: u64,
        market_order: bool,
    ): OrderInfo {
        let pool_id = id_from_address(@0x2);
        let client_order_id = 1;
        let mut order_info = order_info::new(
            pool_id,
            balance_manager_id,
            client_order_id,
            trader,
            order_type,
            price,
            quantity,
            is_bid,
            fee_is_deep,
            epoch,
            expire_timestamp,
            deep_per_base,
            market_order,
        );

        order_info.set_order_id(utils::encode_order_id(is_bid, price, 1));

        order_info
    }
}