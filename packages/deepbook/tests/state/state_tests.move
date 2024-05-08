#[test_only]
module deepbook::state_tests {
    use sui::{
        test_scenario::{Self as test, Scenario, next_tx, ctx, begin, end},
        coin::mint_for_testing,
        sui::SUI,
    };
    use deepbook::{
        state::{Self, State},
        pool::{Pool, DEEP},
        pool_tests::USDC,
        deep_reference_price,
        account::Account,
        account_tests,
    };

    const POOL_CREATION_FEE: u64 = 100 * 1_000_000_000; // 100 SUI, can be updated
    const FLOAT_SCALING: u64 = 1_000_000_000;

    #[test]
    fun test_create_pool_ok() {
        let mut test = begin(@0x1);
        let alice = @0xA;
        share_state(&mut test);
        create_pool<DEEP, USDC>(alice, &mut test);

        test.next_tx(alice);
        {
            let state = test.take_shared<State>();
            assert!(state.pools().length() == 1, 0);
            test::return_shared(state);
        };
        
        end(test);
    }

    #[test, expected_failure(abort_code = state::EPoolAlreadyExists)]
    fun test_create_pool_duplicate_e() {
        let mut test = begin(@0x1);
        let alice = @0xA;
        share_state(&mut test);
        create_pool<DEEP, USDC>(alice, &mut test);
        create_pool<DEEP, USDC>(alice, &mut test);

        abort 0
    }

    #[test, expected_failure(abort_code = state::EPoolAlreadyExists)]
    fun test_create_pool_reverse_e() {
        let mut test = begin(@0x1);
        let alice = @0xA;
        share_state(&mut test);
        create_pool<DEEP, USDC>(alice, &mut test);
        create_pool<USDC, DEEP>(alice, &mut test);

        abort 0
    }

    #[test]
    fun test_add_reference_pool_ok() {
        let mut test = begin(@0x1);
        let alice = @0xA;
        share_state(&mut test);
        create_pool<DEEP, USDC>(alice, &mut test);

        test.next_tx(alice);
        {
            let mut state = test.take_shared<State>();
            let pool = test.take_shared<Pool<DEEP, USDC>>();

            state.add_reference_pool(&pool);

            test::return_shared(pool);
            test::return_shared(state);
        };

        end(test);
    }

    #[test, expected_failure(abort_code = deep_reference_price::EIneligiblePool)]
    fun test_add_reference_pool_ineligible_e() {
        let mut test = begin(@0x1);
        let alice = @0xA;
        share_state(&mut test);
        create_pool<SUI, USDC>(alice, &mut test);

        test.next_tx(alice);
        {
            let mut state = test.take_shared<State>();
            let pool = test.take_shared<Pool<SUI, USDC>>();

            state.add_reference_pool(&pool);
        };
        
        abort 0
    }

    #[test]
    fun test_stake_ok() {
        let mut test = begin(@0x1);
        let alice = @0xA;
        share_state(&mut test);
        create_pool<SUI, USDC>(alice, &mut test);
        let amount_to_deposit = 1000000 * FLOAT_SCALING;
        let account_id = account_tests::create_acct_and_share_with_funds(alice, amount_to_deposit, &mut test);
        stake_with_account<SUI, USDC>(alice, account_id, 500, &mut test, );

        let bob = @0xB;
        let account_id = account_tests::create_acct_and_share_with_funds(bob, amount_to_deposit, &mut test);
        stake_with_account<SUI, USDC>(bob, account_id, 1500, &mut test);

        test.next_tx(bob);
        {
            let (state, pool, account) = take_state_pool_account<SUI, USDC>(&test, account_id);
            assert!(state.vault_value() == 2000, 0); // total stake
            return_state_pool_account(state, pool, account);
        };

        test.next_epoch(@0xF);

        stake_with_account<SUI, USDC>(bob, account_id, 2500, &mut test);

        test.next_tx(bob);
        {
            let (state, pool, account) = take_state_pool_account<SUI, USDC>(&test, account_id);
            let (current_stake, new_stake) = pool.get_user_stake(account.owner(), test.ctx());
            assert!(state.vault_value() == 4500, 0);
            assert!(current_stake == 1500, 0);
            assert!(new_stake == 2500, 0);
            return_state_pool_account(state, pool, account);
        };

        end(test);
    }

    #[test]
    // Alice stakes 500, goes to next epoch, stakes 2000 more, then unstakes all.
    fun test_unstake_ok() {
        let mut test = begin(@0x1);
        let alice = @0xA;
        share_state(&mut test);
        create_pool<SUI, USDC>(alice, &mut test);
        let amount_to_deposit = 1000000 * FLOAT_SCALING;
        let account_id = account_tests::create_acct_and_share_with_funds(alice, amount_to_deposit, &mut test);
        stake_with_account<SUI, USDC>(alice, account_id, 500, &mut test);

        test.next_epoch(@0xF);

        stake_with_account<SUI, USDC>(alice, account_id, 2000, &mut test);
        unstake_with_account<SUI, USDC>(alice, account_id, &mut test, );

        end(test);
    }

    fun unstake_with_account<BaseAsset, QuoteAsset>(
        sender: address,
        account_id: ID,
        test: &mut Scenario,
    ) {
        test.next_tx(sender);
        let (mut state, mut pool, mut account) = take_state_pool_account<BaseAsset, QuoteAsset>(test, account_id);
        let proof = account.generate_proof_as_owner(test.ctx());
        let deep_before = account.balance<DEEP>();
        let vault_before = state.vault_value();
        let (cur_stake_before, new_stake_before) = pool.get_user_stake(account.owner(), test.ctx());
        let unstake_quantity = cur_stake_before + new_stake_before;

        state.unstake(&mut pool, &mut account, &proof, test.ctx());

        let deep_after = account.balance<DEEP>();
        let vault_after = state.vault_value();
        let (cur_stake_after, new_stake_after) = pool.get_user_stake(account.owner(), test.ctx());

        assert!(vault_before - vault_after == unstake_quantity, 0);
        assert!(cur_stake_after == 0, 0);
        assert!(new_stake_after == 0, 0);
        assert!(deep_after - deep_before == unstake_quantity, 0);
        return_state_pool_account(state, pool, account);
    }

    fun stake_with_account<BaseAsset, QuoteAsset>(
        sender: address,
        account_id: ID,
        amount: u64,
        test: &mut Scenario,
    ) {
        test.next_tx(sender);
        let (mut state, mut pool, mut account) = take_state_pool_account<BaseAsset, QuoteAsset>(test, account_id);
        let proof = account.generate_proof_as_owner(test.ctx());
        let deep_before = account.balance<DEEP>();
        let vault_before = state.vault_value();
        let (cur_stake_before, new_stake_before) = pool.get_user_stake(account.owner(), test.ctx());

        state.stake(&mut pool, &mut account, &proof, amount, test.ctx());

        let deep_after = account.balance<DEEP>();
        let vault_after = state.vault_value();
        let (cur_stake_after, new_stake_after) = pool.get_user_stake(account.owner(), test.ctx());

        assert!(vault_after - vault_before == amount, 0);
        assert!(cur_stake_after - cur_stake_before == 0, 0); // cur stake doesn't change until epoch advances
        assert!(new_stake_after - new_stake_before == amount, 0);
        assert!(deep_before - deep_after == amount, 0);
        return_state_pool_account(state, pool, account);
    }

    fun take_state_pool_account<BaseAsset, QuoteAsset>(
        test: &Scenario,
        account_id: ID
    ): (State, Pool<BaseAsset, QuoteAsset>, Account) {
        let state = test.take_shared<State>();
        let pool = test.take_shared<Pool<BaseAsset, QuoteAsset>>();
        let account = test.take_shared_by_id<Account>(account_id);

        (state, pool, account)
    }

    fun return_state_pool_account<BaseAsset, QuoteAsset>(
        state: State,
        pool: Pool<BaseAsset, QuoteAsset>,
        account: Account,
    ) {
        test::return_shared(account);
        test::return_shared(pool);
        test::return_shared(state);
    }

    fun create_pool<BaseAsset, QuoteAsset>(
        sender: address,
        test: &mut Scenario,
    ) {
        test.next_tx(sender);
        let mut state = test.take_shared<State>();
        let balance = mint_for_testing<SUI>(POOL_CREATION_FEE, ctx(test)).into_balance();
        state.create_pool<BaseAsset, QuoteAsset>(
            1000,
            1000,
            1000000,
            balance,
            ctx(test),
        );
        test::return_shared(state);
    }

    fun share_state(test: &mut Scenario) {
        test.next_tx(@0xF);
        state::create_and_share(test.ctx());
    }
}