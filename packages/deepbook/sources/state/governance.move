// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Governance module that handles the creation and voting on proposals.
/// Voting power is increased or decreased by state depending on stakes being added or removed.
/// When an epoch advances, the governance state is reset and the quorum is updated.
module deepbook::governance {
    use sui::table::{Table, Self};

    // === Errors ===
    const EInvalidMakerFee: u64 = 1;
    const EInvalidTakerFee: u64 = 2;
    const EProposalDoesNotExist: u64 = 3;
    const EUserProposalCreationLimitReached: u64 = 4;
    const EUserVotesCastedLimitReached: u64 = 5;
    const EMaxProposalsReached: u64 = 6;

    // === Constants ===
    const MIN_TAKER_STABLE: u64 = 50; // 0.5 basis points
    const MAX_TAKER_STABLE: u64 = 100;
    const MIN_MAKER_STABLE: u64 = 20;
    const MAX_MAKER_STABLE: u64 = 50;
    const MIN_TAKER_VOLATILE: u64 = 500;
    const MAX_TAKER_VOLATILE: u64 = 1000;
    const MIN_MAKER_VOLATILE: u64 = 200;
    const MAX_MAKER_VOLATILE: u64 = 500;
    const MAX_PROPOSALS_CREATIONS_PER_USER: u64 = 1;
    const MAX_VOTES_CASTED_PER_USER: u64 = 3;
    const MAX_PROPOSALS: u64 = 100;

    // === Structs ===
    /// `Proposal` struct that holds the parameters of a proposal and its current total votes.
    public struct Proposal has store, drop, copy {
        maker_fee: u64,
        taker_fee: u64,
        stake_required: u64,
        votes: u64,
    }

    /// `Voter` represents a single voter and the actions they have taken in the current epoch.
    /// A user can create up to 1 proposal per epoch.
    /// A user can cast/recast votes up to 3 times per epoch.
    public struct Voter has store, drop {
        proposal_id: Option<u64>,
        voting_power: Option<u64>,
        proposals_created: u64,
        votes_casted: u64,
    }

    /// `Governance` struct holds all the governance related data. This will reset during
    /// every epoch change, except `voting_power`. Participation is
    /// limited to users with staked voting power.
    public struct Governance has store { // Can take out of Deepbook package (for treasury management)
        // Total eligible voting power available.
        voting_power: u64,
        // Calculated when the governance is reset. It is half of the total voting power.
        quorum: u64,
        // The winning proposal. None if no proposal has reached quorum.
        winning_proposal: Option<Proposal>,
        // All proposals that have been created in the current epoch.
        proposals: vector<Proposal>,
        // User -> Vote mapping. Used to retrieve the vote of a user.
        voters: Option<Table<address, Voter>>,
    }

    // === Public-Package Functions ===
    public(package) fun empty(ctx: &mut TxContext): Governance {
        Governance {
            voting_power: 0,
            quorum: 0,
            winning_proposal: option::none(),
            proposals: vector[],
            voters: option::some(table::new(ctx)),
        }
    }

    /// Reset the governance state. This will happen after an epoch change.
    public(package) fun reset(self: &mut Governance, ctx: &mut TxContext) {
        self.quorum = self.voting_power / 2;
        self.winning_proposal = option::none();
        self.proposals = vector[];
        let new_table: Table<address, Voter> = table::new(ctx);
        let old_table = self.voters.swap(new_table);
        old_table.drop();
    }

    public(package) fun proposal_params(proposal: &Proposal): (u64, u64, u64) {
        (proposal.maker_fee, proposal.taker_fee, proposal.stake_required)
    }

    /// Increase the voting power available. This is called by the state during an epoch change.
    /// The newly staked voting power from the previous epoch is added to the governance.
    /// Validation should be done before calling this funciton.
    public(package) fun increase_voting_power(self: &mut Governance, voting_power: u64) {
        self.voting_power = self.voting_power + voting_power;
    }

    /// Decrease the voting power available.This is called by the parent when a user unstakes.
    /// Only voting power that has been added previously can be removed. This will always be >= 0.
    /// Validation should be done before calling this funciton.
    public(package) fun decrease_voting_power(self: &mut Governance, voting_power: u64) {
        self.voting_power = self.voting_power - voting_power;
    }

    /// Create a new proposal with the given parameters. Perform validation depending 
    /// on the type of pool. A user can create up to 1 proposal per epoch.
    public(package) fun create_new_proposal(
        self: &mut Governance,
        user: address,
        stable: bool,
        maker_fee: u64,
        taker_fee: u64,
        stake_required: u64,
    ) {
        self.add_voter_if_does_not_exist(user);
        self.increment_proposals_created(user);

        if (stable) {
            assert!(maker_fee >= MIN_MAKER_STABLE && maker_fee <= MAX_MAKER_STABLE, EInvalidMakerFee);
            assert!(taker_fee >= MIN_TAKER_STABLE && taker_fee <= MAX_TAKER_STABLE, EInvalidTakerFee);
        } else {
            assert!(maker_fee >= MIN_MAKER_VOLATILE && maker_fee <= MAX_MAKER_VOLATILE, EInvalidMakerFee);
            assert!(taker_fee >= MIN_TAKER_VOLATILE && taker_fee <= MAX_TAKER_VOLATILE, EInvalidTakerFee);
        };

        let proposal = new_proposal(maker_fee, taker_fee, stake_required);
        self.proposals.push_back(proposal);
    }

    /// Vote on a proposal. Validation of user and voting power is done before calling this function.
    public(package) fun vote(
        self: &mut Governance,
        user: address,
        proposal_id: u64,
        voting_power: u64,
    ): Option<Proposal> {
        assert!(proposal_id < self.proposals.length(), EProposalDoesNotExist);
        self.add_voter_if_does_not_exist(user);
        self.update_voter(user, proposal_id, voting_power);

        let proposal = &mut self.proposals[proposal_id];
        proposal.votes = proposal.votes + voting_power;

        if (proposal.votes > self.quorum) {
            self.winning_proposal.swap_or_fill(*proposal);
        };

        self.winning_proposal
    }

    /// Remove a vote from a proposal. If user doesn't exist, do nothing.
    /// This is called in two scenarios: a voted user changes his vote, or a user unstakes.
    public(package) fun remove_vote(
        self: &mut Governance,
        user: address
    ): Option<Proposal> {
        if (!self.voters.borrow().contains(user)) return self.winning_proposal;
        let voter = &mut self.voters.borrow_mut()[user];
        if (voter.proposal_id.is_none()) return self.winning_proposal;

        let votes = voter.voting_power.extract();

        let proposal = &mut self.proposals[voter.proposal_id.extract()];
        proposal.votes = proposal.votes - votes;

        // this was over quorum before, now it is not
        // it was the winning proposal before, now it is not
        if (proposal.votes + votes >= self.quorum
            && proposal.votes < self.quorum) {
            self.winning_proposal = option::none(); // .extract() ? 
        };

        self.winning_proposal
    }

    // === Private Functions ===
    fun new_proposal(maker_fee: u64, taker_fee: u64, stake_required: u64): Proposal {
        Proposal {
            maker_fee,
            taker_fee,
            stake_required,
            votes: 0,
        }
    }

    fun new_voter(): Voter {
        Voter {
            proposal_id: option::none(),
            voting_power: option::none(),
            proposals_created: 0,
            votes_casted: 0,
        }
    }

    fun add_voter_if_does_not_exist(self: &mut Governance, user: address) {
        if (!self.voters.borrow().contains(user)) {
            self.voters.borrow_mut().add(user, new_voter());
        };
    }

    fun increment_proposals_created(self: &mut Governance, user: address) {
        let voter = &mut self.voters.borrow_mut()[user];
        assert!(voter.proposals_created < MAX_PROPOSALS_CREATIONS_PER_USER, EUserProposalCreationLimitReached);
        assert!(self.proposals.length() < MAX_PROPOSALS, EMaxProposalsReached);

        voter.proposals_created = voter.proposals_created + 1;
    }

    fun update_voter(
        self: &mut Governance,
        user: address,
        proposal_id: u64,
        voting_power: u64,
    ) {
        let voter = &mut self.voters.borrow_mut()[user];
        assert!(voter.votes_casted < MAX_VOTES_CASTED_PER_USER, EUserVotesCastedLimitReached);

        voter.votes_casted = voter.votes_casted + 1;
        voter.proposal_id.swap_or_fill(proposal_id);
        voter.voting_power.swap_or_fill(voting_power);
    }

    // === Test Functions ===
    #[test_only]
    public(package) fun voting_power(self: &Governance): u64 {
        self.voting_power
    }

    #[test_only]
    public(package) fun quorum(self: &Governance): u64 {
        self.quorum
    }

    #[test_only]
    public(package) fun proposals(self: &Governance): vector<Proposal> {
        self.proposals
    }

    #[test_only]
    public(package) fun voters_size(self: &Governance): u64 {
        self.voters.borrow().length()
    }

    #[test_only]
    public(package) fun proposal_votes(self: &Governance, proposal_id: u64): u64 {
        self.proposals[proposal_id].votes
    }

    #[test_only]
    public(package) fun delete(self: Governance) {
        let Governance {
            voting_power: _,
            quorum: _,
            winning_proposal: _,
            proposals: _,
            voters: mut voters,
        } = self;

        let table = voters.extract();
        voters.destroy_none();
        table.drop();
    }
}
