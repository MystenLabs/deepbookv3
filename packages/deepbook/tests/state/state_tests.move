module deepbook::state_tests {
    use sui::{
        test_scenario::{next_tx, begin, end},
        test_utils::{assert_eq, destroy},
        object::id_from_address,
    };
    use deepbook::{
        state::Self,
        account,
        balances,
        fill,
        constants,
        order_info_tests::{create_order_info_base},
    };

    const OWNER: address = @0xF;
    const ALICE: address = @0xA;
    const BOB: address = @0xB;

    #[test]
    fun process_create_ok() {
        let mut test = begin(OWNER);

        test.next_tx(ALICE);
        let taker_price = 1 * constants::usdc_unit();
        let taker_quantity = 10 * constants::sui_unit();
        let mut taker_order = create_order_info_base(BOB, taker_price, taker_quantity, false, test.ctx().epoch());

        let mut state = state::empty(test.ctx());
        let price = 1 * constants::usdc_unit();
        let quantity = 1 * constants::sui_unit();
        let mut order_info1 = create_order_info_base(ALICE, price, quantity, true, test.ctx().epoch());
        let (settled, owed) = state.process_create(&mut order_info1, test.ctx());
        assert_eq(settled, balances::new(0, 0, 0));
        assert_eq(owed, balances::new(0, 1 * constants::usdc_unit(), 500_000));
        taker_order.match_maker(&mut order_info1.to_order(), 0);

        test.next_tx(ALICE);
        let price = 1_001_000; // 1.001
        let quantity = 1_001_001_000; // 1.001001
        let mut order_info2 = create_order_info_base(ALICE, price, quantity, true, test.ctx().epoch());
        let (settled, owed) = state.process_create(&mut order_info2, test.ctx());
        assert_eq(settled, balances::new(0, 0, 0));
        assert_eq(owed, balances::new(0, 1_002_002, 500_500)); // rounds down
        taker_order.match_maker(&mut order_info2.to_order(), 0);

        test.next_tx(ALICE);
        let price = 9_999_999_999_000; // $9,999,999.999
        let quantity = 1_999_000_000; // 1.999
        let mut order_info3 = create_order_info_base(ALICE, price, quantity, false, test.ctx().epoch());
        let (settled, owed) = state.process_create(&mut order_info3, test.ctx());
        assert_eq(settled, balances::new(0, 0, 0));
        assert_eq(owed, balances::new(1_999_000_000, 0, 999_500));

        // the taker order has filled the first two maker orders and has some quantities remaining.
        // filled quantity = 1 + 1.001001 = 2.001001
        // quote quantity = 1 * 1 + 1.001001 * 1.001 = 2.002002001 rounds down to 2.002002
        // remaining quantity = 10 - 2.001001 = 7.998999
        // taker gets reduced taker fees (no stake required)
        // taker fees = 2.001001 * 0.0005 = 0.0010005005 rounds down to 0.001000500
        // maker fees = 7.998999 * 0.0005 = 0.0039994995 rounds down to 0.003999499
        // total fees = 0.001000500 + 0.003999499 = 0.004999999 = 4999999
        let (settled, owed) = state.process_create(&mut taker_order, test.ctx());
        assert_eq(settled, balances::new(0, 2_002_002, 0));
        assert_eq(owed, balances::new(10 * constants::sui_unit(), 0, 499_9999));

        // Alice has 1 open order remaining. The first two orders have been filled.
        let alice = state.account(id_from_address(ALICE));
        assert!(alice.total_volume() == 2_001_001_000, 0);
        assert!(alice.open_orders().size() == 1, 0);
        assert!(alice.open_orders().contains(&order_info3.order_id()), 0);
        // she traded BOB for 2.001001 SUI
        assert_eq(alice.settled_balances(), balances::new(2_001_001_000, 0, 0));
        assert_eq(alice.owed_balances(), balances::new(0, 0, 0));

        // Bob has 1 open order after the partial fill.
        let bob = state.account(id_from_address(BOB));
        assert!(bob.total_volume() == 2_001_001_000, 0);
        assert!(bob.open_orders().size() == 1, 0);
        assert!(bob.open_orders().contains(&taker_order.order_id()), 0);
        // Bob's balances have been settled already
        assert_eq(bob.settled_balances(), balances::new(0, 0, 0));
        assert_eq(bob.owed_balances(), balances::new(0, 0, 0));
    
        destroy(state);
        test.end();
    }

    // process create after governance to raise stake required

    // process create after gov, then after stake

    #[test]
    fun process_cancel_ok() {
        let mut test = begin(OWNER);

        test.next_tx(ALICE);
        let price = 11831 * constants::usdc_unit();
        let quantity = 91932 * constants::sui_unit();
        let mut order_info1 = create_order_info_base(ALICE, price, quantity, true, test.ctx().epoch());
        let mut state = state::empty(test.ctx());
        let (settled, owed) = state.process_create(&mut order_info1, test.ctx());
        assert_eq(settled, balances::new(0, 0, 0));
        assert_eq(owed, balances::new(0, 1 * constants::usdc_unit(), 500_000));

        destroy(state);
        test.end();
    }

    // process cancel after partial fill

    // process cancel after modify

    // process create with different deep_per_base
}