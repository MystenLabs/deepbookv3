module deepbook::account_tests {
    use sui::{
        address,
        test_scenario::{next_tx, begin, end},
        test_utils::{destroy, assert_eq},
        object::id_from_address,
    };
    use deepbook::{
        account,
        balances,
        fill,
    };

    const OWNER: address = @0xF;
    const ALICE: address = @0xA;
    const BOB: address = @0xB;

    #[test]
    fun add_balances_ok() {
        let mut test = begin(OWNER);

        test.next_tx(ALICE);
        let mut account = account::empty(test.ctx());
        let (settled, owed) = account.settle();
        assert_eq(settled, balances::new(0, 0, 0));
        assert_eq(owed, balances::new(0, 0, 0));

        account.add_settled_balances(balances::new(1, 2, 3));
        account.add_owed_balances(balances::new(4, 5, 6));
        let (settled, owed) = account.settle();
        assert_eq(settled, balances::new(1, 2, 3));
        assert_eq(owed, balances::new(4, 5, 6));

        test.end();
    }

    #[test]
    fun process_maker_fill_ok() {
        let mut test = begin(OWNER);

        test.next_tx(ALICE);
        let mut account = account::empty(test.ctx());
        account.add_order(1);
        let fill = fill::new(1, id_from_address(@0xB), false, false, 100, 500, false);
        account.process_maker_fill(&fill);
        let (settled, owed) = account.settle();
        assert_eq(settled, balances::new(100, 0, 0));
        assert_eq(owed, balances::new(0, 0, 0));
        assert!(account.maker_volume() == 100, 0);
        assert!(account.open_orders().size() == 1, 0);
        assert!(account.open_orders().contains(&(1 as u128)), 0);

        account.add_order(2);
        let fill = fill::new(2, id_from_address(@0xC), false, true, 100, 500, true);
        account.process_maker_fill(&fill);
        let (settled, owed) = account.settle();
        assert_eq(settled, balances::new(0, 500, 0));
        assert_eq(owed, balances::new(0, 0, 0));
        assert!(account.maker_volume() == 200, 0);
        assert!(account.open_orders().size() == 1, 0);
        assert!(account.open_orders().contains(&(1 as u128)), 0);
        assert!(!account.open_orders().contains(&(2 as u128)), 0);

        account.add_order(3);
        let fill = fill::new(3, id_from_address(@0xC), true, false, 100, 500, true);
        account.process_maker_fill(&fill);
        let (settled, owed) = account.settle();
        assert_eq(settled, balances::new(100, 0, 0));
        assert_eq(owed, balances::new(0, 0, 0));
        assert!(account.maker_volume() == 200, 0);
        assert!(account.open_orders().size() == 1, 0);
        assert!(account.open_orders().contains(&(1 as u128)), 0);
        assert!(!account.open_orders().contains(&(2 as u128)), 0);
        assert!(!account.open_orders().contains(&(3 as u128)), 0);

        account.add_order(4);
        let fill = fill::new(4, id_from_address(@0xC), false, true, 100, 500, true);
        account.process_maker_fill(&fill);
        let (settled, owed) = account.settle();
        assert_eq(settled, balances::new(0, 500, 0));
        assert_eq(owed, balances::new(0, 0, 0));
        assert!(account.maker_volume() == 300, 0);
        assert!(account.open_orders().size() == 1, 0);
        assert!(account.open_orders().contains(&(1 as u128)), 0);
        assert!(!account.open_orders().contains(&(2 as u128)), 0);
        assert!(!account.open_orders().contains(&(3 as u128)), 0);
        assert!(!account.open_orders().contains(&(4 as u128)), 0);

        test.end();
    }

    #[test]
    fun add_remove_stake_ok() {
        let mut test = begin(OWNER);

        test.next_tx(ALICE);
        let mut account = account::empty(test.ctx());
        let (before, after) = account.add_stake(100);
        assert!(before == 0, 0);
        assert!(after == 100, 0);
        assert!(account.active_stake() == 0, 0);
        assert!(account.inactive_stake() == 100, 0);

        let (before, after) = account.add_stake(100);
        assert!(before == 100, 0);
        assert!(after == 200, 0);
        assert!(account.active_stake() == 0, 0);
        assert!(account.inactive_stake() == 200, 0);
        let (settled, owed) = account.settle();
        assert_eq(settled, balances::new(0, 0, 0));
        assert_eq(owed, balances::new(0, 0, 200));
        

        test.end();
    }
}