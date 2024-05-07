#[test_only]
module deepbook::pool_metadata_tests {
    use sui::test_scenario::{Self as test, Scenario, next_tx, end};
    use deepbook::pool_metadata;

    #[test]
    fun new_proposal() {
        let (mut scenario, owner) = setup();
        next_tx(&mut scenario, owner);
        let mut metadata = pool_metadata::empty(0);
        metadata.adjust_voting_power(0, 300);
        metadata.refresh(1); // quorum = 150
        metadata.add_proposal(500, 200, 10000);

        // Alice votes with 100 stake, not enough to push proposal 0 over quorum
        let winning_proposal = metadata.vote(option::none(), option::some(0), 100);
        assert!(winning_proposal.is_none(), 0);

        // Bob votes with 200 stake, enough to push proposal 0 over quorum
        let winning_proposal = metadata.vote(option::none(), option::some(0), 200);
        let (taker_fee, maker_fee, stake_required) = winning_proposal.borrow().proposal_params();
        assert!(maker_fee == 200, 0);
        assert!(taker_fee == 500, 0);
        assert!(stake_required == 10000, 0);

        metadata.add_proposal(600, 300, 20000);

        // Alice moves 100 stake from proposal 0 to 1, but not enough to push proposal 1 over quorum
        let winning_proposal = metadata.vote(option::some(0), option::some(1), 100);
        let (taker_fee, maker_fee, stake_required) = winning_proposal.borrow().proposal_params();
        assert!(maker_fee == 200, 0);
        assert!(taker_fee == 500, 0);
        assert!(stake_required == 10000, 0);

        // Bob removes 200 votes from proposal 0, no proposal is over quorum
        let winning_proposal = metadata.vote(option::some(0), option::none(), 200);
        assert!(winning_proposal.is_none(), 0);

        // Bob voting on proposal 1 is enough to get it over quorum
        let winning_proposal = metadata.vote(option::none(), option::some(1), 200);
        let (taker_fee, maker_fee, stake_required) = winning_proposal.borrow().proposal_params();
        assert!(maker_fee == 300, 0);
        assert!(taker_fee == 600, 0);
        assert!(stake_required == 20000, 0);

        metadata.delete();
        end(scenario);
    }

    #[test]
    fun new_proposal_stable() {
        let (mut scenario, owner) = setup();
        next_tx(&mut scenario, owner);
        let mut metadata = pool_metadata::empty(0);
        metadata.set_as_stable(true);

        metadata.add_proposal(50, 20, 10000);
        metadata.add_proposal(100, 50, 20000);

        assert!(metadata.proposals().length() == 2, 0);
        metadata.delete();
        end(scenario);
    }

    #[test]
    fun voting_power() {
        let (mut scenario, owner) = setup();
        next_tx(&mut scenario, owner);
        {
            // New gov has 0 for all values
            let mut metadata = pool_metadata::empty(0);
            assert!(metadata.voting_power() == 0, 0);
            assert!(metadata.quorum() == 0, 0);
            assert!(metadata.proposals().length() == 0, 0);

            // Increase voting power by 300 stake, but quorum isn't increased until next epoch reset
            metadata.adjust_voting_power(0, 300);
            assert!(metadata.voting_power() == 300, 0);
            assert!(metadata.quorum() == 0, 0);

            // Resetting the epoch sets quorum to 150
            metadata.refresh(1);
            assert!(metadata.quorum() == 150, 0);

            // Alice creates a new proposal and votes on it
            metadata.add_proposal(500, 200, 10000);
            metadata.vote(option::none(), option::some(0), 100);
            assert!(metadata.proposals().length() == 1, 0);
            assert!(metadata.proposal_votes(0) == 100, 0);

            // Bob votes
            metadata.vote(option::none(), option::some(0), 200);
            assert!(metadata.proposal_votes(0) == 300, 0);

            // Alice removes vote
            metadata.vote(option::some(0), option::none(), 100);
            assert!(metadata.proposal_votes(0) == 200, 0);

            // New proposal, proposals = 2
            metadata.add_proposal(600, 300, 20000);
            assert!(metadata.proposals().length() == 2, 0);

            // Decrease voting power, but quorum isn't decreased until next epoch reset
            metadata.adjust_voting_power(100, 0);
            assert!(metadata.voting_power() == 200, 0);
            assert!(metadata.quorum() == 150, 0);

            // Reset to get rid of all proposals and voters. Quorum updated
            metadata.refresh(2);
            assert!(metadata.voting_power() == 200, 0);
            assert!(metadata.quorum() == 100, 0);
            assert!(metadata.proposals().length() == 0, 0);

            // Stake of 2000, over threshold of 1000, gain 1500 voting power
            metadata.adjust_voting_power(0, 2000);
            assert!(metadata.voting_power() == 1700, 0);
            // Any more additions by this user increases voting power by half
            metadata.adjust_voting_power(2000, 3000);
            assert!(metadata.voting_power() == 2200, 0);
            // Stake added by someone else still counts as full voting power
            metadata.adjust_voting_power(0, 300);
            assert!(metadata.voting_power() == 2500, 0);
            // Whale removes his 3000 stake, reducing voting power by 2000
            metadata.adjust_voting_power(3000, 0);
            assert!(metadata.voting_power() == 500, 0);
            
            metadata.delete();
        };

        end(scenario);
    }

    #[test, expected_failure(abort_code = pool_metadata::EProposalDoesNotExist)]
    fun proposal_does_not_exist_e() {
        let (mut scenario, owner) = setup();
        next_tx(&mut scenario, owner);
        {
            let mut metadata = pool_metadata::empty(0);
            metadata.add_proposal(500, 200, 10000);
            metadata.vote(option::none(), option::some(1), 100);
            abort 0
        }
    }

    #[test, expected_failure(abort_code = pool_metadata::EInvalidTakerFee)]
    fun new_proposal_taker_too_high_e() {
        let (mut scenario, owner) = setup();
        next_tx(&mut scenario, owner);
        {
            let mut metadata = pool_metadata::empty(0);
            metadata.add_proposal(1001, 200, 10000);
            abort 0
        }
    }

    #[test, expected_failure(abort_code = pool_metadata::EInvalidTakerFee)]
    fun new_proposal_taker_too_low_e() {
        let (mut scenario, owner) = setup();
        next_tx(&mut scenario, owner);
        {
            let mut metadata = pool_metadata::empty(0);
            metadata.add_proposal(499, 200, 10000);
            abort 0
        }
    }

    #[test, expected_failure(abort_code = pool_metadata::EInvalidTakerFee)]
    fun new_proposal_taker_too_high_stable_e() {
        let (mut scenario, owner) = setup();
        next_tx(&mut scenario, owner);
        {
            let mut metadata = pool_metadata::empty(0);
            metadata.set_as_stable(true);
            metadata.add_proposal(200, 50, 10000);
            abort 0
        }
    }

    #[test, expected_failure(abort_code = pool_metadata::EInvalidMakerFee)]
    fun new_proposal_maker_too_high_e() {
        let (mut scenario, owner) = setup();
        next_tx(&mut scenario, owner);
        {
            let mut metadata = pool_metadata::empty(0);
            metadata.add_proposal(500, 501, 10000);
            abort 0
        }
    }

    #[test, expected_failure(abort_code = pool_metadata::EInvalidMakerFee)]
    fun new_proposal_maker_too_low_e() {
        let (mut scenario, owner) = setup();
        next_tx(&mut scenario, owner);
        {
            let mut metadata = pool_metadata::empty(0);
            metadata.add_proposal(500, 199, 10000);
            abort 0
        }
    }

    #[test, expected_failure(abort_code = pool_metadata::EInvalidMakerFee)]
    fun new_proposal_maker_too_high_stable_e() {
        let (mut scenario, owner) = setup();
        next_tx(&mut scenario, owner);
        {
            let mut metadata = pool_metadata::empty(0);
            metadata.set_as_stable(true);
            metadata.add_proposal(100, 100, 10000);
            abort 0
        }
    }

    fun setup(): (Scenario, address) {
        let scenario = test::begin(@0x1);
        let owner = @0xF;

        (scenario, owner)
    }
}