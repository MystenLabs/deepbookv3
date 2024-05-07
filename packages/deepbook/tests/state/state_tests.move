#[test_only]
module deepbook::state_tests {
    use sui::{
        test_scenario::{Self as test, Scenario, next_tx, ctx, end},
        coin::mint_for_testing,
        sui::SUI,
    };
    use deepbook::{
        state::{Self, State},
        pool::{Pool, DEEP},
        pool_tests::{Self, USDC},
        deep_reference_price,
        account::Account,
    };

    const POOL_CREATION_FEE: u64 = 100 * 1_000_000_000; // 100 SUI, can be updated

    #[test]
    fun test_create_pool_ok() {
        let (mut test, alice) = setup();
        create_pool<DEEP, USDC>(alice, &mut test);

        next_tx(&mut test, alice);
        {
            let state = test.take_shared<State>();
            assert!(state.pools().length() == 1, 0);
            test::return_shared(state);
        };
        
        end(test);
    }

    #[test, expected_failure(abort_code = state::EPoolAlreadyExists)]
    fun test_create_pool_duplicate_e() {
        let (mut test, alice) = setup();
        create_pool<DEEP, USDC>(alice, &mut test);
        create_pool<DEEP, USDC>(alice, &mut test);

        abort 0
    }

    #[test, expected_failure(abort_code = state::EPoolAlreadyExists)]
    fun test_create_pool_reverse_e() {
        let (mut test, alice) = setup();
        create_pool<DEEP, USDC>(alice, &mut test);
        create_pool<USDC, DEEP>(alice, &mut test);

        abort 0
    }

    #[test]
    fun test_add_reference_pool_ok() {
        let (mut test, alice) = setup();
        create_pool<DEEP, USDC>(alice, &mut test);

        next_tx(&mut test, alice);
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
        let (mut test, alice) = setup();
        create_pool<SUI, USDC>(alice, &mut test);

        next_tx(&mut test, alice);
        {
            let mut state = test.take_shared<State>();
            let pool = test.take_shared<Pool<SUI, USDC>>();

            state.add_reference_pool(&pool);
        };
        
        abort 0
    }

    #[test]
    fun test_stake_ok() {
        let (mut test, alice) = setup();
        create_pool<SUI, USDC>(alice, &mut test);
        let acct_id = pool_tests::create_acct_and_share_with_funds(alice, &mut test);
        next_tx(&mut test, alice);
        {
            let mut state = test.take_shared<State>();
            let mut pool = test.take_shared<Pool<SUI, USDC>>();
            let mut account = test.take_shared_by_id<Account>(acct_id);
            let proof = account.generate_proof_as_owner(ctx(&mut test));
            let deep_acct_before = account.balance<DEEP>();

            state.stake(&mut pool, &mut account, &proof, 500, ctx(&mut test));

            let deep_acct_after = account.balance<DEEP>();
            assert!(deep_acct_before - deep_acct_after == 500, 0);

            // deep balance in account
            // deep balance in pool
            // voting power
            // stake

            test::return_shared(account);
            test::return_shared(pool);
            test::return_shared(state);
        };
        

        end(test);
    }

    fun create_pool<BaseAsset, QuoteAsset>(
        sender: address,
        test: &mut Scenario,
    ) {
        next_tx(test, sender);
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
    
    fun setup(): (Scenario, address) {
        let mut scenario = test::begin(@0x1);
        let alice = @0xA;
        next_tx(&mut scenario, @0xF);
        state::create_and_share(ctx(&mut scenario));

        (scenario, alice)
    }
}