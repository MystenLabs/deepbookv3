// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

module deepbook::governance {
    // === Errors ===
    const EInvalidMakerFee: u64 = 1;
    const EInvalidTakerFee: u64 = 2;
    const EProposalDoesNotExist: u64 = 3;
    const EMaxProposalsReached: u64 = 4;

    // === Constants ===
    const MIN_TAKER_STABLE: u64 = 50000; // 0.5 basis points
    const MAX_TAKER_STABLE: u64 = 100000;
    const MIN_MAKER_STABLE: u64 = 20000;
    const MAX_MAKER_STABLE: u64 = 50000;
    const MIN_TAKER_VOLATILE: u64 = 500000;
    const MAX_TAKER_VOLATILE: u64 = 1000000;
    const MIN_MAKER_VOLATILE: u64 = 200000;
    const MAX_MAKER_VOLATILE: u64 = 500000;
    const MAX_PROPOSALS: u64 = 100; // TODO: figure out how to prevent spam
    const VOTING_POWER_CUTOFF: u64 = 1000; // TODO

    // === Structs ===
    /// `Proposal` struct that holds the parameters of a proposal and its current total votes.
    public struct Proposal has store, drop, copy {
        taker_fee: u64,
        maker_fee: u64,
        stake_required: u64,
        votes: u64,
    }

    /// Details of a pool. This is refreshed every epoch by the first 
    /// `State` action against this pool.
    public struct Governance has store {
        /// Tracks refreshes.
        epoch: u64,
        /// List of proposals for the current epoch.
        proposals: vector<Proposal>,
        /// The winning proposal for the current epoch.
        winning_proposal: Option<Proposal>,
        /// All voting power from the current stakes.
        voting_power: u64,
        /// Quorum for the current epoch.
        quorum: u64,
    }

    // === Public-Package Functions ===
    public(package) fun empty(
        epoch: u64,
    ): Governance {
        Governance {
            epoch,
            proposals: vector[],
            winning_proposal: option::none(),
            voting_power: 0,
            quorum: 0,
        }
    }

    public(package) fun default_fees(stable: bool): (u64, u64) {
        if (stable) {
            (MAX_TAKER_STABLE, MAX_MAKER_STABLE)
        } else {
            (MAX_TAKER_VOLATILE, MAX_MAKER_VOLATILE)
        }
    }

    /// Refresh the pool metadata. This is called by every `State` 
    /// action, but only processed once per epoch.
    public(package) fun refresh(self: &mut Governance, epoch: u64) {
        if (self.epoch == epoch) return;

        self.epoch = epoch;
        self.quorum = self.voting_power / 2;
        self.proposals = vector[];
    }

    /// Add a new proposal to governance.
    /// Validation of the user adding is done in `State`.
    public(package) fun add_proposal(
        self: &mut Governance,
        stable: bool,
        taker_fee: u64,
        maker_fee: u64,
        stake_required: u64
    ) {
        assert!(self.proposals.length() < MAX_PROPOSALS, EMaxProposalsReached);
        if (stable) {
            assert!(taker_fee >= MIN_TAKER_STABLE && taker_fee <= MAX_TAKER_STABLE, EInvalidTakerFee);
            assert!(maker_fee >= MIN_MAKER_STABLE && maker_fee <= MAX_MAKER_STABLE, EInvalidMakerFee);
        } else {
            assert!(taker_fee >= MIN_TAKER_VOLATILE && taker_fee <= MAX_TAKER_VOLATILE, EInvalidTakerFee);
            assert!(maker_fee >= MIN_MAKER_VOLATILE && maker_fee <= MAX_MAKER_VOLATILE, EInvalidMakerFee);
        };

        self.proposals.push_back(new_proposal(taker_fee, maker_fee, stake_required));
    }

    /// Vote on a proposal. Validation of the user and stake is done in `State`.
    /// If `from_proposal_id` is some, the user is removing their vote from that proposal.
    /// If `to_proposal_id` is some, the user is voting for that proposal.
    public(package) fun adjust_vote(
        self: &mut Governance,
        from_proposal_id: Option<u64>,
        to_proposal_id: Option<u64>,
        stake_amount: u64,
    ): Option<Proposal> {
        let voting_power = stake_to_voting_power(stake_amount);

        if (from_proposal_id.is_some()) {
            let id = *from_proposal_id.borrow();
            assert!(self.proposals.length() > id, EProposalDoesNotExist);
            self.proposals[id].votes = self.proposals[id].votes - voting_power;

            // This was the winning proposal, now it is not.
            if (self.proposals[id].votes + voting_power > self.quorum &&
                self.proposals[id].votes <= self.quorum) {
                self.winning_proposal = option::none();
            };
        };

        if (to_proposal_id.is_some()) {
            let id = *to_proposal_id.borrow();
            assert!(self.proposals.length() > id, EProposalDoesNotExist);
            self.proposals[id].votes = self.proposals[id].votes + voting_power;
            if (self.proposals[id].votes > self.quorum) {
                self.winning_proposal = option::some(self.proposals[id]);
            };
        };
        
        self.winning_proposal
    }

    /// Adjust the total voting power by adding and removing stake. If a user's
    /// stake goes from 2000 to 3000, then `stake_before` is 2000 and `stake_after` is 3000.
    /// Validation of inputs done in `State`.
    public(package) fun adjust_voting_power(
        self: &mut Governance,
        stake_before: u64,
        stake_after: u64,
    ) {
        self.voting_power =
            self.voting_power +
            stake_to_voting_power(stake_after) -
            stake_to_voting_power(stake_before);
    }

    public(package) fun params(proposal: &Proposal): (u64, u64, u64) {
        (proposal.taker_fee, proposal.maker_fee, proposal.stake_required)
    }

    // === Private Functions ===
    /// Convert stake to voting power. If the stake is above the cutoff, then the voting power is halved.
    fun stake_to_voting_power(stake: u64): u64 {
        if (stake >= VOTING_POWER_CUTOFF) {
            stake - (stake - VOTING_POWER_CUTOFF) / 2
        } else {
            stake
        }
    }

    fun new_proposal(taker_fee: u64, maker_fee: u64, stake_required: u64): Proposal {
        Proposal {
            taker_fee,
            maker_fee,
            stake_required,
            votes: 0,
        }
    }

    // === Test Functions ===
    #[test_only]
    public fun delete(self: Governance) {
        let Governance {
            epoch: _,
            proposals: _,
            winning_proposal: _,
            voting_power: _,
            quorum: _,
        } = self;
    }

    #[test_only]
    public fun voting_power(self: &Governance): u64 {
        self.voting_power
    }

    #[test_only]
    public fun quorum(self: &Governance): u64 {
        self.quorum
    }

    #[test_only]
    public fun proposals(self: &Governance): vector<Proposal> {
        self.proposals
    }

    #[test_only]
    public fun proposal_votes(self: &Governance, id: u64): u64 {
        self.proposals[id].votes
    }
}