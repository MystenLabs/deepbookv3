module deepbookv3::pool_metadata {
    use deepbookv3::proposal::Proposal;

    public struct PoolMetadata has store {
        pool_id: ID,
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
}