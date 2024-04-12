module deepbookv3::pool_metadata {
    use sui::balance::{Balance, Self};

    use deepbookv3::governance::{Governance, Proposal, Self};
    use deepbookv3::pool::{DEEP};

    const VOTING_POWER_CUTOFF: u64 = 1000; // TODO: decide this

    public struct PoolMetadata has store {
        last_refresh_epoch: u64,
        is_stable: bool,
        governance: Governance,
        vault: Balance<DEEP>,
        new_voting_power: u64,
    }

    public(package) fun new(
        ctx: &TxContext,
    ): PoolMetadata {
        PoolMetadata {
            last_refresh_epoch: ctx.epoch(),
            is_stable: false,
            governance: governance::new(),
            vault: balance::zero(),
            new_voting_power: 0,
        }
    }

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
        pool_metadata.governance.remove_vote(voter);
        pool_metadata.governance.vote(proposal_id, voter, voting_power)
    }

    public(package) fun increase_new_voting_power(
        pool_metadata: &mut PoolMetadata,
        voting_power: u64,
    ) {
        pool_metadata.new_voting_power = pool_metadata.new_voting_power + voting_power;
    }

    public(package) fun add_stake(
        pool_metadata: &mut PoolMetadata,
        total_user_stake: u64,
        amount: Balance<DEEP>
    ) {
        let new_voting_power = calculate_new_voting_power(total_user_stake, amount.value());
        pool_metadata.new_voting_power = pool_metadata.new_voting_power + new_voting_power;
        pool_metadata.vault.join(amount);
    }

    public(package) fun remove_stake(
        pool_metadata: &mut PoolMetadata,
        old_epoch_stake: u64,
        current_epoch_stake: u64,
    ): Balance<DEEP> {
        let (old_voting_power, new_voting_power) = calculate_voting_power_removed(old_epoch_stake, current_epoch_stake);
        pool_metadata.new_voting_power = pool_metadata.new_voting_power - new_voting_power;
        pool_metadata.governance.decrease_voting_power(old_voting_power);

        pool_metadata.vault.split(old_epoch_stake + current_epoch_stake)
    }

    public(package) fun decrease_voting_power(
        pool_metadata: &mut PoolMetadata,
        voting_power: u64,
    ) {
        pool_metadata.governance.decrease_voting_power(voting_power);
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