module deepbookv3::proposal {
    use sui::vec_map::VecMap;
    
    public struct Proposal has store, drop {
        id: ID,
        maker_fee: u64,
        taker_fee: u64,
        stake_required: u64,
        votes: u64,
        quorum: u64,
        voters: VecMap<address, u64>
    }
}