#[test_only]
module deepbook::governance_tests {
    use sui::test_scenario::{Self as test, Scenario, next_tx, ctx, end};
    use deepbook::governance;

    #[test]
    fun new_proposal() {
        let (mut scenario, alice, bob, owner) = setup();
        next_tx(&mut scenario, owner);
        let mut gov = governance::empty(ctx(&mut scenario));
        gov.increase_voting_power(300);
        gov.reset(ctx(&mut scenario)); // quorum = 150
        gov.create_new_proposal(alice, false, 200, 500, 10000);

        // Alice's votes don't push proposal 0 over quorum
        let winning_proposal = gov.vote(alice, 0, 100);
        assert!(winning_proposal.is_none(), 0);

        // Bob pushes proposal 0 over quorum
        let winning_proposal = gov.vote(bob, 0, 200);
        let (maker_fee, taker_fee, stake_required) = winning_proposal.borrow().proposal_params();
        assert!(maker_fee == 200, 0);
        assert!(taker_fee == 500, 0);
        assert!(stake_required == 10000, 0);

        gov.create_new_proposal(bob, false, 300, 600, 20000);

        // Alice removing votes still keeps proposal 0 over quorum
        let winning_proposal = gov.remove_vote(alice);
        let (maker_fee, taker_fee, stake_required) = winning_proposal.borrow().proposal_params();
        assert!(maker_fee == 200, 0);
        assert!(taker_fee == 500, 0);
        assert!(stake_required == 10000, 0);

        // Alice voting on proposal 1 is not enough to get it over quorum
        let winning_proposal = gov.vote(alice, 1, 100);
        let (maker_fee, taker_fee, stake_required) = winning_proposal.borrow().proposal_params();
        assert!(maker_fee == 200, 0);
        assert!(taker_fee == 500, 0);
        assert!(stake_required == 10000, 0);

        // Bob removes proposal 0 votes, no proposal is over quorum
        let winning_proposal = gov.remove_vote(bob);
        assert!(winning_proposal.is_none(), 0);

        // Bob voting on proposal 1 is enough to get it over quorum
        let winning_proposal = gov.vote(bob, 1, 200);
        let (maker_fee, taker_fee, stake_required) = winning_proposal.borrow().proposal_params();
        assert!(maker_fee == 300, 0);
        assert!(taker_fee == 600, 0);
        assert!(stake_required == 20000, 0);

        gov.delete();
        end(scenario);
    }

    #[test]
    fun voting_power() {
        let (mut scenario, alice, bob, owner) = setup();
        next_tx(&mut scenario, owner);
        {
            // New gov has 0 for all values
            let mut gov = governance::empty(ctx(&mut scenario));
            assert!(gov.voting_power() == 0, 0);
            assert!(gov.quorum() == 0, 0);
            assert!(gov.proposals().length() == 0, 0);
            assert!(gov.voters_size() == 0, 0);

            // Increase voting power to 300, but quorum isn't increased until next epoch reset
            gov.increase_voting_power(300);
            assert!(gov.voting_power() == 300, 0);
            assert!(gov.quorum() == 0, 0);

            // Resetting the epoch sets quorum to 150
            gov.reset(ctx(&mut scenario));
            assert!(gov.quorum() == 150, 0);
            assert!(gov.proposals().length() == 0, 0);
            assert!(gov.voters_size() == 0, 0);

            // Alice creates a new proposal and votes on it. Proposals = 1, voters = 1
            gov.create_new_proposal(alice, false, 200, 500, 10000);
            gov.vote(alice, 0, 100);
            assert!(gov.voters_size() == 1, 0);
            assert!(gov.proposals().length() == 1, 0);
            assert!(gov.proposal_votes(0) == 100, 0);

            // Bob votes, voters = 2
            gov.vote(bob, 0, 200);
            assert!(gov.voters_size() == 2, 0);
            assert!(gov.proposal_votes(0) == 300, 0);

            // Alice removes vote, voters = 2 still
            gov.remove_vote(alice);
            assert!(gov.voters_size() == 2, 0);
            assert!(gov.proposal_votes(0) == 200, 0);

            // New proposal, proposals = 2
            gov.create_new_proposal(bob, false, 300, 600, 20000);
            assert!(gov.proposals().length() == 2, 0);

            gov.vote(alice, 1, 100);
            assert!(gov.voters_size() == 2, 0);
            assert!(gov.proposal_votes(1) == 100, 0);

            // Decrease voting power, but quorum isn't decreased until next epoch reset
            gov.decrease_voting_power(100);
            assert!(gov.voting_power() == 200, 0);
            assert!(gov.quorum() == 150, 0);

            // Reset to get rid of all proposals and voters. Quorum updated
            gov.reset(ctx(&mut scenario));
            assert!(gov.voting_power() == 200, 0);
            assert!(gov.quorum() == 100, 0);
            assert!(gov.proposals().length() == 0, 0);
            assert!(gov.voters_size() == 0, 0);
            
            gov.delete();
        };

        end(scenario);
    }

    #[test, expected_failure(abort_code = governance::EProposalDoesNotExist)]
    fun proposal_does_not_exist_e() {
        let (mut scenario, alice, _, owner) = setup();
        next_tx(&mut scenario, owner);
        {
            let mut gov = governance::empty(ctx(&mut scenario));
            gov.create_new_proposal(alice, false, 200, 500, 10000);
            gov.vote(alice, 1, 100);
            abort 0
        }
    }

    #[test, expected_failure(abort_code = governance::EInvalidTakerFee)]
    fun new_proposal_taker_too_high_e() {
        let (mut scenario, alice, _, owner) = setup();
        next_tx(&mut scenario, owner);
        {
            let mut gov = governance::empty(ctx(&mut scenario));
            gov.create_new_proposal(alice, false, 200, 1001, 10000);
            abort 0
        }
    }

    #[test, expected_failure(abort_code = governance::EInvalidTakerFee)]
    fun new_proposal_taker_too_low_e() {
        let (mut scenario, alice, _, owner) = setup();
        next_tx(&mut scenario, owner);
        {
            let mut gov = governance::empty(ctx(&mut scenario));
            gov.create_new_proposal(alice, false, 200, 499, 10000);
            abort 0
        }
    }

    #[test, expected_failure(abort_code = governance::EInvalidMakerFee)]
    fun new_proposal_maker_too_high_e() {
        let (mut scenario, alice, _, owner) = setup();
        next_tx(&mut scenario, owner);
        {
            let mut gov = governance::empty(ctx(&mut scenario));
            gov.create_new_proposal(alice, false, 501, 500, 10000);
            abort 0
        }
    }

    #[test, expected_failure(abort_code = governance::EInvalidMakerFee)]
    fun new_proposal_maker_too_low_e() {
        let (mut scenario, alice, _, owner) = setup();
        next_tx(&mut scenario, owner);
        {
            let mut gov = governance::empty(ctx(&mut scenario));
            gov.create_new_proposal(alice, false, 199, 500, 10000);
            abort 0
        }
    }

    #[test, expected_failure(abort_code = governance::EUserProposalCreationLimitReached)]
    fun new_proposal_limit_reached_e() {
        let (mut scenario, alice, _, owner) = setup();
        next_tx(&mut scenario, owner);
        {
            let mut gov = governance::empty(ctx(&mut scenario));
            gov.create_new_proposal(alice, false, 200, 500, 10000);
            gov.create_new_proposal(alice, false, 200, 500, 10000);
            abort 0
        }
    }

    #[test, expected_failure(abort_code = governance::EUserVotesCastedLimitReached)]
    fun vote_limit_reached_e() {
        let (mut scenario, alice, bob, owner) = setup();
        next_tx(&mut scenario, owner);
        {
            let mut gov = governance::empty(ctx(&mut scenario));
            gov.create_new_proposal(alice, false, 200, 500, 10000);
            gov.vote(bob, 0, 100);
            gov.remove_vote(bob);
            gov.vote(bob, 0, 100);
            gov.remove_vote(bob);
            gov.vote(bob, 0, 100);
            gov.remove_vote(bob);
            gov.vote(bob, 0, 100);
            abort 0
        }
    }

    fun setup(): (Scenario, address, address, address) {
        let scenario = test::begin(@0x1);
        let alice = @0xA;
        let bob = @0xB;
        let owner = @0xF;
        (scenario, alice, bob, owner)
    }
}