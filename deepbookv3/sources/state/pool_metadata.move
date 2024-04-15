module deepbookv3::pool_metadata {
    use deepbookv3::governance::{Governance, Proposal, Self};

    const VOTING_POWER_CUTOFF: u64 = 1000; // TODO

    /// Details of a pool. This is refreshed every epoch by the first State level action against this pool.
    public struct PoolMetadata has store {
        // Tracks refreshes.
        last_refresh_epoch: u64,
        // If the pool is stable or volatile. Determines the fee structure applied.
        is_stable: bool,
        // Governance details.
        governance: Governance,
        // Voting power generated from stakes during this epoch. 
        // During a refresh, this value is added to the governance and set to 0.
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

    /// Set the pool as stable. Called by State, validation done in State.
    public(package) fun set_as_stable(pool_metadata: &mut PoolMetadata, stable: bool) {
        pool_metadata.is_stable = stable;
    }

    /// Refresh the pool metadata. 
    /// This is called by every State level action, but only processed once per epoch.
    public(package) fun refresh(pool_metadata: &mut PoolMetadata, ctx: &TxContext) {
        let current_epoch = ctx.epoch();
        if (pool_metadata.last_refresh_epoch == current_epoch) return;

        pool_metadata.last_refresh_epoch = current_epoch;
        pool_metadata.governance.increase_voting_power(pool_metadata.new_voting_power);
        pool_metadata.governance.reset();
    }

    /// Add a new proposal to the governance. Called by State.
    /// Validation of the user adding is done in State.
    /// Validation of proposal parameters done in Goverance.
    public(package) fun add_proposal(
        pool_metadata: &mut PoolMetadata,
        user: address,
        maker_fee: u64,
        taker_fee: u64,
        stake_required: u64
    ) {
        pool_metadata.governance.create_new_proposal(
            user,
            pool_metadata.is_stable,
            maker_fee,
            taker_fee,
            stake_required
        );
    }

    /// Vote on a proposal. Called by State.
    /// Validation of the user and stake is done in State.
    /// Validation of proposal id is done in Governance.
    /// Remove any existing vote by this user and add new vote.
    public(package) fun vote(
        pool_metadata: &mut PoolMetadata,
        proposal_id: u64,
        voter: address,
        stake_amount: u64,
    ): Option<Proposal> {
        pool_metadata.governance.remove_vote(voter);
        let voting_power = stake_to_voting_power(stake_amount);
        pool_metadata.governance.vote(voter, proposal_id, voting_power)
    }

    /// Add stake to the pool. Called by State.
    /// Total user stake is the sum of the user's historic and current stake, including amount.
    /// This is needed to calculate the new voting power.
    /// Validation of the user, amount, and total_user_stake is done in State.
    public(package) fun add_voting_power(
        pool_metadata: &mut PoolMetadata,
        total_user_stake: u64,
        new_user_stake: u64,
    ) {
        let new_voting_power = calculate_new_voting_power(total_user_stake, new_user_stake);
        pool_metadata.new_voting_power = pool_metadata.new_voting_power + new_voting_power;
    }

    /// Remove stake from the pool. Called by State.
    /// old_epoch_stake is the user's stake before the current epoch.
    /// current_epoch_stake is the user's stake during the current epoch.
    /// These are needed to calculate the voting power to remove in Governance and are validated in State.
    public(package) fun remove_voting_power(
        pool_metadata: &mut PoolMetadata,
        old_epoch_stake: u64,
        current_epoch_stake: u64,
    ) {
        let (old_voting_power, new_voting_power) = calculate_voting_power_removed(old_epoch_stake, current_epoch_stake);
        pool_metadata.new_voting_power = pool_metadata.new_voting_power - new_voting_power;
        pool_metadata.governance.decrease_voting_power(old_voting_power);
    }

    fun stake_to_voting_power(
        stake: u64,
    ): u64 {
        if (stake >= VOTING_POWER_CUTOFF) {
            return stake - (stake - VOTING_POWER_CUTOFF) / 2
        };
        stake
    }   

    fun calculate_new_voting_power(
        total_stake: u64,
        new_stake: u64,
    ): u64 {
        let prev_stake = total_stake - new_stake;
        if (prev_stake >= VOTING_POWER_CUTOFF) {
            return new_stake / 2
        };
        let amount_till_cutoff = VOTING_POWER_CUTOFF - prev_stake;
        if (amount_till_cutoff >= new_stake) {
            return new_stake
        };
        
        amount_till_cutoff + (new_stake - amount_till_cutoff) / 2
    }

    fun calculate_voting_power_removed(
        old_stake: u64,
        new_stake: u64,
    ): (u64, u64) {
        if (old_stake + new_stake <= VOTING_POWER_CUTOFF) {
            return (old_stake, new_stake)
        };
        if (old_stake <= VOTING_POWER_CUTOFF) {
            let amount_till_cutoff = VOTING_POWER_CUTOFF - old_stake;
            return (old_stake + amount_till_cutoff, (new_stake - amount_till_cutoff) / 2)
        };
        
        let old_after_cutoff = old_stake - VOTING_POWER_CUTOFF;

        return (old_stake + old_after_cutoff, new_stake / 2)
    }
}