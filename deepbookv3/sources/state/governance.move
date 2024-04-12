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

    const EInvalidMakerFee: u64 = 1;
    const EInvalidTakerFee: u64 = 2;
    const EProposalDoesNotExist: u64 = 3;

    public struct Proposal has store, drop, copy {
        maker_fee: u64,
        taker_fee: u64,
        stake_required: u64,
        votes: u64,
    }

    public struct Vote has store, drop {
        proposal_id: u64,
        voting_power: u64,
    }

    public struct Governance has store {
        voting_power: u64,
        quorum: u64,
        winning_proposal: Option<Proposal>,
        proposals: vector<Proposal>,
        votes: VecMap<address, Vote>,
    }

    public(package) fun new(): Governance {
        Governance {
            voting_power: 0,
            quorum: 0,
            winning_proposal: option::none(),
            proposals: vector::empty(),
            votes: vec_map::empty(),
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

    fun new_vote(proposal_id: u64, voting_power: u64): Vote {
        Vote {
            proposal_id: proposal_id,
            voting_power: voting_power,
        }
    }
    
    public(package) fun reset(governance: &mut Governance) {
        governance.proposals = vector::empty();
        governance.votes = vec_map::empty();
        governance.quorum = governance.voting_power / 2;
    }

    public(package) fun increase_voting_power(governance: &mut Governance, voting_power: u64) {
        governance.voting_power = governance.voting_power + voting_power;
    }

    public(package) fun decrease_voting_power(governance: &mut Governance, voting_power: u64) {
        governance.voting_power = governance.voting_power - voting_power;
    }

    public(package) fun create_new_proposal(
        governance: &mut Governance,
        stable: bool,
        maker_fee: u64,
        taker_fee: u64,
        stake_required: u64,
    ) {
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

    // cast a vote
    // return the winning proposal
    public(package) fun vote(
        governance: &mut Governance,
        proposal_id: u64,
        user: address,
        voting_power: u64,
    ): Option<Proposal> {
        // we can't validate user, voting_power. they must be validated before calling this function.
        assert!(proposal_id < governance.proposals.length(), EProposalDoesNotExist);

        let proposal = governance.proposals.borrow_mut(proposal_id);
        proposal.votes = proposal.votes + voting_power;

        let vote = new_vote(proposal_id, voting_power);
        governance.votes.insert(user, vote);

        if (proposal.votes >= governance.quorum) {
            governance.winning_proposal = option::some(*proposal);
        };

        governance.winning_proposal
    }

    // remove a vote
    // return the winning proposal
    public(package) fun remove_vote(
        governance: &mut Governance,
        user: address
    ): Option<Proposal> {
        if (!governance.votes.contains(&user)) return governance.winning_proposal;

        let (_, vote) = governance.votes.remove(&user);
        let proposal = governance.proposals.borrow_mut(vote.proposal_id);
        proposal.votes = proposal.votes - vote.voting_power;

        // this was over quorum before, now it is not
        // it was the winning proposal before, now it is not
        if (proposal.votes + vote.voting_power >= governance.quorum
            && proposal.votes < governance.quorum) {
            governance.winning_proposal = option::none();
        };

        governance.winning_proposal
    }
}