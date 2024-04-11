module deepbookv3::pool_metadata {
    use std::string::{String, utf8};

    use deepbookv3::proposal::Proposal;
    use deepbookv3::pool::Pool;

    public struct PoolMetadata has store {
        pool_key: String,
        last_refresh_epoch: u64,
        total_voting_power: u64,
        new_voting_power: u64,
        is_stable: bool,
        proposals: vector<Proposal>
    }

    public(package) fun get_last_refresh_epoch(pool_metadata: &PoolMetadata): u64 {
        pool_metadata.last_refresh_epoch
    }

    public(package) fun clear_proposals(pool_metadata: &mut PoolMetadata) {
        pool_metadata.proposals = vector::empty();
    }

    public(package) fun set_as_stable(pool_metadata: &mut PoolMetadata) {
        pool_metadata.is_stable = true;
    }

    public(package) fun new<BaseAsset, QuoteAsset>(
        pool: &Pool<BaseAsset, QuoteAsset>,
        ctx: &TxContext,
    ): PoolMetadata {
        let pool_key = utf8(b""); // TODO: pool.get_key();
        
        PoolMetadata {
            pool_key: pool_key,
            last_refresh_epoch: ctx.epoch(),
            total_voting_power: 0,
            new_voting_power: 0,
            is_stable: false,
            proposals: vector::empty(),
        }
    }
}