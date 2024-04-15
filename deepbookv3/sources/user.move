module deepbookv3::user {
    use sui::vec_map::{VecMap, Self};

    const EInvalidResetAddress: u64 = 1;

    public struct User has store {
        user: address,
        last_refresh_epoch: u64,
        open_orders: VecMap<u64, u64>,
        maker_volume: u64,
        stake_amount: u64,
        next_stake_amount: u64,
        unclaimed_rebates: u64,
        settled_base_amount: u64,
        settled_quote_amount: u64,
    }

    public(package) fun new_user(
        user: address,
    ): User {
        User {
            user: user,
            last_refresh_epoch: 0,
            open_orders: vec_map::empty(),
            maker_volume: 0,
            stake_amount: 0,
            next_stake_amount: 0,
            unclaimed_rebates: 0,
            settled_base_amount: 0,
            settled_quote_amount: 0,
        }
    }

    // refresh user and return burn amount for last epoch
    public(package) fun refresh(
        user: &mut User,
        ctx: &TxContext
    ): u64 {
        let current_epoch = ctx.epoch();
        if (user.last_refresh_epoch == current_epoch) return 0;

        let (rebates, burn) = calculate_rebates_and_burn(user);
        user.unclaimed_rebates = user.unclaimed_rebates + rebates;
        user.last_refresh_epoch = current_epoch;
        user.maker_volume = 0;
        user.stake_amount = user.next_stake_amount;
        user.next_stake_amount = 0;

        burn
    }

    // increase user stake
    public(package) fun increase_stake(
        user: &mut User,
        amount: u64,
    ): u64 {
        user.next_stake_amount = user.next_stake_amount + amount;

        user.stake_amount + user.next_stake_amount
    }

    // remove user stake
    public(package) fun remove_stake(
        user: &mut User,
    ): (u64, u64) {
        let old_stake = user.stake_amount;
        let new_stake = user.next_stake_amount;
        user.stake_amount = 0;
        user.next_stake_amount = 0;

        (old_stake, new_stake)
    }

    public(package) fun reset_rebates(
        user: &mut User,
    ): u64 {
        let rebates = user.unclaimed_rebates;
        user.unclaimed_rebates = 0;

        rebates
    }

    fun calculate_rebates_and_burn(
        _user: &User,
    ): (u64, u64) {
        // calculate reabtes from the current User data
        (0, 0)
    }

    public(package) fun get_settle_amounts(
        user: &User,
    ): (u64, u64) {
        (user.settled_base_amount, user.settled_quote_amount)
    }

    public(package) fun reset_settle_amounts(
        user: &mut User,
        ctx: &TxContext,
    ) {
        assert!(user.user == ctx.sender(), EInvalidResetAddress);
        user.settled_base_amount = 0;
        user.settled_quote_amount = 0;
    }
}