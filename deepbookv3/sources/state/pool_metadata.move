module deepbookv3::pool_metadata {
    use std::string::{String, utf8};
    use sui::vec_map::{VecMap, Self};

    use deepbookv3::pool::Pool;
    use deepbookv3::governance::{Governance, Proposal, Self};

    const EProposalDoesNotExist: u64 = 0;

    public struct PoolMetadata has store {
        last_refresh_epoch: u64,
        is_stable: bool,
        governance: Governance,
        new_voting_power: u64,
    }

    public(package) fun new(
        ctx: &TxContext,
    ): PoolMetadata {
        PoolMetadata {
            last_refresh_epoch: ctx.epoch(),
            is_stable: false,
            governance: governance::new(),
            new_voting_power: 0,
        }
    }

    // SETTERS

    public(package) fun set_as_stable(pool_metadata: &mut PoolMetadata) {
        pool_metadata.is_stable = true;
    }

    public(package) fun refresh(pool_metadata: &mut PoolMetadata, ctx: &TxContext) {
        let current_epoch = ctx.epoch();
        if (pool_metadata.last_refresh_epoch == current_epoch) return;

        pool_metadata.last_refresh_epoch = current_epoch;
        pool_metadata.governance.increase_voting_power(pool_metadata.new_voting_power);
        pool_metadata.governance.reset();
    }

    public(package) fun add_proposal(
        pool_metadata: &mut PoolMetadata,
        maker_fee: u64,
        taker_fee: u64,
        stake_required: u64
    ) {
        pool_metadata.governance.create_new_proposal(
            pool_metadata.is_stable,
            maker_fee,
            taker_fee,
            stake_required
        );
    }

    public(package) fun vote(
        pool_metadata: &mut PoolMetadata,
        proposal_id: u64,
        voter: address,
        voting_power: u64,
    ): Option<Proposal> {
        // first remove any existing vote
        pool_metadata.governance.remove_vote(voter);

        pool_metadata.governance.vote(proposal_id, voter, voting_power)
    }
}