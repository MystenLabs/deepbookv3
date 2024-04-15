module deepbookv3::governance {
    use sui::vec_map::{VecMap, Self};

    const MIN_TAKER_STABLE: u64 = 50; // 0.5 basis points
    const MAX_TAKER_STABLE: u64 = 100; // 1 basis point
    const MIN_MAKER_STABLE: u64 = 20;
    const MAX_MAKER_STABLE: u64 = 50;
    const MIN_TAKER_VOLATILE: u64 = 500;
    const MAX_TAKER_VOLATILE: u64 = 1000;
    const MIN_MAKER_VOLATILE: u64 = 200;
    const MAX_MAKER_VOLATILE: u64 = 500;

    const MAX_PROPOSALS_CREATIONS_PER_USER: u64 = 1;
    const MAX_VOTES_CASTED_PER_USER: u64 = 3;

    const EInvalidMakerFee: u64 = 1;
    const EInvalidTakerFee: u64 = 2;
    const EProposalDoesNotExist: u64 = 3;
    const EUserProposalCreationLimitReached: u64 = 4;
    const EUserVotesCastedLimitReached: u64 = 5;

    public struct Proposal has store, drop, copy {
        maker_fee: u64,
        taker_fee: u64,
        stake_required: u64,
        // Total votes for this proposal.
        votes: u64,
    }

    public struct Voter has store, drop {
        proposal_id: Option<u64>,
        voting_power: Option<u64>,
        proposals_created: u64,
        votes_casted: u64,
    }

    /// Governance struct that holds all the governance related data.
    /// This will reset during every epoch change, except voting_power which will be as needed.
    /// Participation is limited to users with staked voting power. vector and VecMap will not overflow.
    public struct Governance has store {
        // Total eligible voting power available.
        voting_power: u64,
        // Calculated when the governance is reset. It is half of the total voting power.
        quorum: u64,
        // The winning proposal. None if no proposal has reached quorum.
        winning_proposal: Option<Proposal>,
        // All proposals that have been created in the current epoch.
        proposals: vector<Proposal>,
        // User -> Vote mapping. Used to retrieve the vote of a user.
        voters: VecMap<address, Voter>,
    }

    public(package) fun new(): Governance {
        Governance {
            voting_power: 0,
            quorum: 0,
            winning_proposal: option::none(),
            proposals: vector::empty(),
            voters: vec_map::empty(),
        }
    }

    fun new_proposal(maker_fee: u64, taker_fee: u64, stake_required: u64): Proposal {
        Proposal {
            maker_fee: maker_fee,
            taker_fee: taker_fee,
            stake_required: stake_required,
            votes: 0,
        }
    }

    public(package) fun get_proposal_params(proposal: &Proposal): (u64, u64, u64) {
        (proposal.maker_fee, proposal.taker_fee, proposal.stake_required)
    }

    fun new_voter(): Voter {
        Voter {
            proposal_id: option::none(),
            voting_power: option::none(),
            proposals_created: 0,
            votes_casted: 0,
        }
    }

    /// Reset the governance state. This will happen after an epoch change.
    /// Epoch validation done by the parent.
    public(package) fun reset(governance: &mut Governance) {
        governance.proposals = vector::empty();
        governance.voters = vec_map::empty();
        governance.quorum = governance.voting_power / 2;
        governance.winning_proposal = option::none();
    }

    /// Increase the voting power available.
    /// This is called by the parent during an epoch change.
    /// The newly staked voting power from the previous epoch is added to the governance.
    /// Validation should be done before calling this funciton.
    public(package) fun increase_voting_power(governance: &mut Governance, voting_power: u64) {
        governance.voting_power = governance.voting_power + voting_power;
    }

    /// Decrease the voting power available.
    /// This is called by the parent when a user unstakes.
    /// Only voting power that has been added previously can be removed. This will always be >= 0.
    /// Validation should be done before calling this funciton.
    public(package) fun decrease_voting_power(governance: &mut Governance, voting_power: u64) {
        governance.voting_power = governance.voting_power - voting_power;
    }

    /// Create a new proposal with the given parameters.
    /// Perform validation depending on the type of pool.
    /// A user can only create 1 proposal per epoch.
    public(package) fun create_new_proposal(
        governance: &mut Governance,
        user: address,
        stable: bool,
        maker_fee: u64,
        taker_fee: u64,
        stake_required: u64,
    ) {
        governance.add_voter_if_does_not_exist(user);
        governance.increment_proposals_created(user);

        if (stable) {
            assert!(maker_fee >= MIN_MAKER_STABLE && maker_fee <= MAX_MAKER_STABLE, EInvalidMakerFee);
            assert!(taker_fee >= MIN_TAKER_STABLE && taker_fee <= MAX_TAKER_STABLE, EInvalidTakerFee);
        } else {
            assert!(maker_fee >= MIN_MAKER_VOLATILE && maker_fee <= MAX_MAKER_VOLATILE, EInvalidMakerFee);
            assert!(taker_fee >= MIN_TAKER_VOLATILE && taker_fee <= MAX_TAKER_VOLATILE, EInvalidTakerFee);
        };

        let proposal = new_proposal(maker_fee, taker_fee, stake_required);
        governance.proposals.push_back(proposal);
    }

    /// Vote on a proposal.
    /// Validation of user and voting power should be done before calling this function.
    public(package) fun vote(
        governance: &mut Governance,
        user: address,
        proposal_id: u64,
        voting_power: u64,
    ): Option<Proposal> {
        // we can't validate user, voting_power. they must be validated before calling this function.
        assert!(proposal_id < governance.proposals.length(), EProposalDoesNotExist);
        governance.add_voter_if_does_not_exist(user);
        governance.update_voter(user, proposal_id, voting_power);

        let proposal = &mut governance.proposals[proposal_id];
        proposal.votes = proposal.votes + voting_power;

        if (proposal.votes >= governance.quorum) {
            governance.winning_proposal = option::some(*proposal);
        };

        governance.winning_proposal
    }

    /// Remove a vote from a proposal.
    /// If user hasn't not exist, do nothing.
    /// This is called in two scenarios: a voted user changes his vote, or a user unstakes.
    public(package) fun remove_vote(
        governance: &mut Governance,
        user: address
    ): Option<Proposal> {
        if (!governance.voters.contains(&user)) return governance.winning_proposal;
        let voter = governance.voters.get_mut(&user);
        if (voter.proposal_id.is_none()) return governance.winning_proposal;

        let votes = voter.voting_power.extract();

        let proposal = &mut governance.proposals[voter.proposal_id.extract()];
        proposal.votes = proposal.votes - votes;

        // this was over quorum before, now it is not
        // it was the winning proposal before, now it is not
        if (proposal.votes + votes >= governance.quorum
            && proposal.votes < governance.quorum) {
            governance.winning_proposal = option::none();
        };

        governance.winning_proposal
    }

    fun add_voter_if_does_not_exist(governance: &mut Governance, user: address) {
        if (!governance.voters.contains(&user)) {
            let voter = new_voter();
            governance.voters.insert(user, voter);
        };
    }

    fun increment_proposals_created(governance: &mut Governance, user: address) {
        let voter = governance.voters.get_mut(&user);
        assert!(voter.proposals_created < MAX_PROPOSALS_CREATIONS_PER_USER, EUserProposalCreationLimitReached);

        voter.proposals_created = voter.proposals_created + 1;
    }

    fun update_voter(
        governance: &mut Governance, 
        user: address,
        proposal_id: u64,
        voting_power: u64,
    ) {
        let voter = governance.voters.get_mut(&user);
        assert!(voter.votes_casted < MAX_VOTES_CASTED_PER_USER, EUserVotesCastedLimitReached);

        voter.votes_casted = voter.votes_casted + 1;
        voter.proposal_id = option::some(proposal_id);
        voter.voting_power = option::some(voting_power);
    }
}