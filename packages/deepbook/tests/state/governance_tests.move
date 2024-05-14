#[test_only]
module deepbook::governance_tests {
    use std::debug::print;
    use sui::{
        address,
        test_scenario::{Self as test, Scenario, next_tx, begin, end},
        test_utils::{destroy, assert_eq},
    };
    use deepbook::governance;

    const OWNER: address = @0xF;
    const ALICE: address = @0xA;
    const BOB: address = @0xB;
    const CHARLIE: address = @0xC;
    const MAX_PROPOSALS: u256 = 100;

    #[test]
    fun add_proposal_volatile_ok() {
        let mut test = begin(OWNER);
        let alice = ALICE;
        
        test.next_tx(alice);
        let mut gov = governance::empty(test.ctx());
        gov.add_proposal(500000, 200000, 10000, 1000, alice);
        assert!(gov.proposals().size() == 1, 0);
        let (taker_fee, maker_fee, stake_required) = gov.proposals().get(&alice).params();
        assert!(taker_fee == 500000, 0);
        assert!(maker_fee == 200000, 0);
        assert!(stake_required == 10000, 0);

        destroy(gov);
        end(test);
    }

    #[test, expected_failure(abort_code = governance::EInvalidTakerFee)]
    fun add_proposal_volatile_low_taker_e() {
        let mut test = begin(OWNER);
        let alice = ALICE;
        
        test.next_tx(alice);
        let mut gov = governance::empty(test.ctx());
        gov.add_proposal(490000, 200000, 10000, 1000, alice);
        abort 0
    }

    #[test, expected_failure(abort_code = governance::EInvalidTakerFee)]
    fun add_proposal_volatile_high_taker_e() {
        let mut test = begin(OWNER);
        let alice = ALICE;
        
        test.next_tx(alice);
        let mut gov = governance::empty(test.ctx());
        gov.add_proposal(1010000, 200000, 10000, 1000, alice);
        abort 0
    }

    #[test, expected_failure(abort_code = governance::EInvalidMakerFee)]
    fun add_proposal_volatile_low_maker_e() {
        let mut test = begin(OWNER);
        let alice = ALICE;
        
        test.next_tx(alice);
        let mut gov = governance::empty(test.ctx());
        gov.add_proposal(500000, 190000, 10000, 1000, alice);
        abort 0
    }

    #[test, expected_failure(abort_code = governance::EInvalidMakerFee)]
    fun add_proposal_volatile_high_maker_e() {
        let mut test = begin(OWNER);
        let alice = ALICE;
        
        test.next_tx(alice);
        let mut gov = governance::empty(test.ctx());
        gov.add_proposal(500000, 510000, 10000, 1000, alice);
        abort 0
    }

    #[test]
    fun add_proposal_stable_ok() {
        let mut test = begin(OWNER);
        let alice = ALICE;

        test.next_tx(OWNER);
        let mut gov = governance::empty(test.ctx());
        gov.set_stable(true);
        
        test.next_tx(alice);
        gov.add_proposal(50000, 20000, 10000, 1000, alice);
        assert!(gov.proposals().size() == 1, 0);

        destroy(gov);
        end(test);
    }

    #[test, expected_failure(abort_code = governance::EInvalidTakerFee)]
    fun add_proposal_stable_taker_e() {
        let mut test = begin(OWNER);
        let alice = ALICE;
        
        test.next_tx(OWNER);
        let mut gov = governance::empty(test.ctx());
        gov.set_stable(true);

        test.next_tx(alice);
        gov.add_proposal(500000, 20000, 10000, 1000, alice);
        abort 0
    }

    #[test, expected_failure(abort_code = governance::EInvalidMakerFee)]
    fun add_proposal_stable_maker_e() {
        let mut test = begin(OWNER);
        let alice = ALICE;
        
        test.next_tx(OWNER);
        let mut gov = governance::empty(test.ctx());
        gov.set_stable(true);

        test.next_tx(alice);
        gov.add_proposal(50000, 200000, 10000, 1000, alice);
        abort 0
    }

    #[test, expected_failure(abort_code = governance::EAlreadyProposed)]
    fun add_proposal_already_proposed_e() {
        let mut test = begin(OWNER);
        let alice = ALICE;
        
        test.next_tx(alice);
        let mut gov = governance::empty(test.ctx());
        gov.add_proposal(500000, 200000, 10000, 1000, alice);
        
        test.next_tx(alice);
        gov.add_proposal(500000, 200000, 10000, 1000, alice);
        abort 0
    }

    #[test]
    fun set_stable_ok() {
        let mut test = begin(OWNER);
        
        test.next_tx(OWNER);
        let mut gov = governance::empty(test.ctx());
        gov.set_stable(true);
        let trade_params = gov.trade_params();
        assert!(trade_params.taker_fee() == 100000, 0);
        assert!(trade_params.maker_fee() == 50000, 0);
        assert_eq(trade_params, gov.next_trade_params());
        assert!(gov.stable(), 0);

        gov.set_stable(false);
        let trade_params = gov.trade_params();
        assert!(trade_params.taker_fee() == 1000000, 0);
        assert!(trade_params.maker_fee() == 500000, 0);
        assert_eq(trade_params, gov.next_trade_params());
        assert!(!gov.stable(), 0);

        test.next_tx(ALICE);
        gov.add_proposal(500000, 200000, 10000, 1000, ALICE);
        assert!(gov.proposals().size() == 1, 0);

        test.next_tx(OWNER);
        gov.set_stable(true);
        assert!(gov.proposals().size() == 0, 0);

        destroy(gov);
        end(test);
    }

    #[test]
    fun set_whitelist_ok() {
        let mut test = begin(OWNER);
        
        test.next_tx(OWNER);
        let mut gov = governance::empty(test.ctx());
        gov.add_proposal(500000, 200000, 10000, 1000, OWNER);
        assert!(gov.proposals().size() == 1, 0);

        // Setting whitelist to true removes all proposals,
        // and sets all trade params to 0.
        gov.set_whitelist(true);
        assert!(gov.whitelisted(), 0);
        assert!(!gov.stable(), 0);
        assert!(gov.proposals().size() == 0, 0);
        let trade_params = gov.trade_params();
        assert!(trade_params.taker_fee() == 0, 0);
        assert!(trade_params.maker_fee() == 0, 0);
        assert!(trade_params.stake_required() == 0, 0);
        assert_eq(trade_params, gov.next_trade_params());

        // Setting whitelist to false resets params to default volatile values.
        test.next_tx(OWNER);
        gov.set_whitelist(false);
        assert!(!gov.whitelisted(), 0);
        assert!(!gov.stable(), 0);
        let trade_params = gov.trade_params();
        assert!(trade_params.taker_fee() == 1000000, 0);
        assert!(trade_params.maker_fee() == 500000, 0);
        assert!(trade_params.stake_required() == 0, 0);

        // Setting whitelist to true sets stable to false.
        test.next_tx(OWNER);
        gov.set_stable(true);
        gov.set_whitelist(true);
        assert!(!gov.stable(), 0);

        destroy(gov);
        end(test);
    }

    #[test, expected_failure(abort_code = governance::EWhitelistedPoolCannotChange)]
    fun set_stable_e() {
        let mut test = begin(OWNER);
        
        test.next_tx(OWNER);
        let mut gov = governance::empty(test.ctx());
        gov.set_whitelist(true);
        gov.set_stable(true);
        abort 0
    }

    #[test, expected_failure(abort_code = governance::EWhitelistedPoolCannotChange)]
    fun add_proposal_whitelisted_e() {
        let mut test = begin(OWNER);
        
        test.next_tx(OWNER);
        let mut gov = governance::empty(test.ctx());
        gov.set_whitelist(true);
        
        test.next_tx(ALICE);
        gov.add_proposal(500000, 200000, 10000, 1000, ALICE);
        abort 0
    }

    #[test]
    fun adjust_voting_power_ok() {
        let mut test = begin(OWNER);
        let alice = ALICE;
        let mut alice_stake = 0;
        
        test.next_tx(OWNER);
        let mut gov = governance::empty(test.ctx());
        
        // alice raises her stake by 1000 3 times. everything after 1000 counts as half.
        test.next_tx(alice);
        gov.adjust_voting_power(alice_stake, alice_stake + 1000);
        alice_stake = alice_stake + 1000;
        assert!(gov.voting_power() == 1000, 0);
        gov.adjust_voting_power(alice_stake, alice_stake + 1000);
        alice_stake = alice_stake + 1000;
        assert!(gov.voting_power() == 1500, 0);
        gov.adjust_voting_power(alice_stake, alice_stake + 1000);
        alice_stake = alice_stake + 1000;
        assert!(gov.voting_power() == 2000, 0);
        assert!(gov.quorum() == 0, 0);

        test.next_epoch(OWNER);
        test.next_tx(alice);
        gov.update(test.ctx());
        assert!(gov.quorum() == 1000, 0);

        // alice removes stake by 1000 3 times. reverses the effects.
        gov.adjust_voting_power(alice_stake, alice_stake - 1000);
        alice_stake = alice_stake - 1000;
        assert!(gov.voting_power() == 1500, 0);
        gov.adjust_voting_power(alice_stake, alice_stake - 1000);
        alice_stake = alice_stake - 1000;
        assert!(gov.voting_power() == 1000, 0);
        gov.adjust_voting_power(alice_stake, alice_stake - 1000);
        assert!(gov.voting_power() == 0, 0);

        destroy(gov);
        end(test);
    }

    #[test]
    fun update_ok() {
        let mut test = begin(OWNER);
        let alice = ALICE;
        
        test.next_tx(OWNER);
        let mut gov = governance::empty(test.ctx());
        assert!(gov.voting_power() == 0, 0);
        assert!(gov.quorum() == 0, 0);
        assert!(gov.proposals().size() == 0, 0);
        assert_eq(gov.trade_params(), gov.next_trade_params());
        gov.adjust_voting_power(0, 1000);
        assert!(gov.voting_power() == 1000, 0);
        
        test.next_epoch(OWNER);
        test.next_tx(alice);
        gov.update(test.ctx());
        assert!(gov.voting_power() == 1000, 0);
        assert!(gov.quorum() == 500, 0);

        test.next_tx(alice);
        gov.add_proposal(500000, 200000, 10000, 1000, alice);
        gov.adjust_vote(option::none(), option::some(alice), 1000);
        assert!(gov.proposals().size() == 1, 0);
        assert!(gov.quorum() == 500, 0);
        let trade_params = gov.trade_params();
        assert!(trade_params.taker_fee() == 1000000, 0);
        assert!(trade_params.maker_fee() == 500000, 0);
        assert!(trade_params.stake_required() == 0, 0);
        let next_trade_params = gov.next_trade_params();
        assert!(next_trade_params.taker_fee() == 500000, 0);
        assert!(next_trade_params.maker_fee() == 200000, 0);
        assert!(next_trade_params.stake_required() == 10000, 0);
        
        // update doesn't apply proposal yet since epoch hasn't changed
        gov.update(test.ctx());
        assert_eq(trade_params, gov.trade_params());
        assert_eq(next_trade_params, gov.next_trade_params());
        assert!(gov.proposals().size() == 1, 0);
        assert!(gov.voting_power() == 1000, 0);
        assert!(gov.quorum() == 500, 0);

        test.next_epoch(OWNER);
        test.next_tx(alice);
        gov.update(test.ctx());
        let trade_params = gov.trade_params();
        assert!(trade_params.taker_fee() == 500000, 0);
        assert!(trade_params.maker_fee() == 200000, 0);
        assert!(trade_params.stake_required() == 10000, 0);
        assert_eq(trade_params, gov.next_trade_params());
        assert!(gov.proposals().size() == 0, 0);
        assert!(gov.voting_power() == 1000, 0);
        assert!(gov.quorum() == 500, 0);

        destroy(gov);
        end(test);
    }

    #[test]
    fun adjust_vote_ok() {
        let mut test = begin(OWNER);
        let alice = ALICE;
        let bob = BOB;
        
        test.next_tx(OWNER);
        let mut gov = governance::empty(test.ctx());
        gov.adjust_voting_power(0, 1000);
        assert!(gov.voting_power() == 5000, 0);
        
        test.next_epoch(OWNER);
        test.next_tx(alice);
        gov.update(test.ctx());
        assert!(gov.quorum() == 2500, 0);

        // alice proposes proposal 0, votes with 2000 votes, not over quorum
        test.next_tx(alice);
        gov.add_proposal(500000, 200000, 10000, 2000, alice);
        gov.adjust_vote(option::none(), option::some(alice), 2000);
        assert!(gov.proposals().get(&alice).votes() == 2000, 0);
        assert!(gov.next_trade_params().taker_fee() == 1000000, 0);
        assert_eq(gov.trade_params(), gov.next_trade_params());

        // bob proposes proposal 1, votes with 3000 votes, over quorum
        test.next_tx(bob);
        gov.add_proposal(600000, 300000, 10000, 2000, bob);
        gov.adjust_vote(option::none(), option::some(bob), 3000);
        assert!(gov.proposals().get(&alice).votes() == 2000, 0);
        assert!(gov.proposals().get(&bob).votes() == 3000, 0);
        assert!(gov.next_trade_params().taker_fee() == 600000, 0);
        assert!(gov.next_trade_params().maker_fee() == 300000, 0);

        // alice moves her votes from proposal 0 to 1
        test.next_tx(alice);
        gov.adjust_vote(option::some(alice), option::some(bob), 2000);
        assert!(gov.proposals().get(&alice).votes() == 0, 0);
        assert!(gov.proposals().get(&bob).votes() == 5000, 0);
        assert!(gov.next_trade_params().taker_fee() == 600000, 0);
        assert!(gov.next_trade_params().maker_fee() == 300000, 0);

        // bob moves his votes from proposal 1 to 0, making it the next trade params
        test.next_tx(bob);
        gov.adjust_vote(option::some(bob), option::some(alice), 3000);
        assert!(gov.proposals().get(&alice).votes() == 3000, 0);
        assert!(gov.proposals().get(&bob).votes() == 2000, 0);
        assert!(gov.next_trade_params().taker_fee() == 500000, 0);
        assert!(gov.next_trade_params().maker_fee() == 200000, 0);

        // bob removes his votes completely, making the default trade params the next trade params
        test.next_tx(bob);
        gov.adjust_vote(option::some(bob), option::none(), 3000);
        assert!(gov.proposals().get(&alice).votes() == 0, 0);
        assert!(gov.proposals().get(&bob).votes() == 2000, 0);
        assert!(gov.next_trade_params().taker_fee() == 1000000, 0);
        assert!(gov.next_trade_params().maker_fee() == 500000, 0);

        destroy(gov);
        end(test);
    }
}