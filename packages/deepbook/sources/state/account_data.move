module deepbook::account_data {
    use sui::vec_set::{Self, VecSet};

    public struct Balances has store, copy, drop {
        base: u64,
        quote: u64,
        deep: u64,
    }

    /// Account data that is updated every epoch.
    public struct AccountData has store, copy, drop {
        epoch: u64,
        open_orders: VecSet<u128>,
        taker_volume: u64,
        maker_volume: u64,
        active_stake: u64,
        inactive_stake: u64,
        voted_proposal: Option<ID>,
        unclaimed_rebates: u64,
        settled_balances: Balances,
        owed_balances: Balances,
    }

    public(package) fun empty(
        epoch: u64,
    ): AccountData {
        AccountData {
            epoch,
            open_orders: vec_set::empty(),
            taker_volume: 0,
            maker_volume: 0,
            active_stake: 0,
            inactive_stake: 0,
            voted_proposal: option::none(),
            unclaimed_rebates: 0,
            settled_balances: Balances {
                base: 0,
                quote: 0,
                deep: 0,
            },
            owed_balances: Balances {
                base: 0,
                quote: 0,
                deep: 0,
            },
        }
    }

    public(package) fun active_stake(
        self: &AccountData,
    ): u64 {
        self.active_stake
    }

    public(package) fun increase_maker_volume(
        self: &mut AccountData,
        volume: u64,
    ) {
        self.maker_volume = self.maker_volume + volume;
    }

    public(package) fun increase_taker_volume(
        self: &mut AccountData,
        volume: u64,
    ) {
        self.taker_volume = self.taker_volume + volume;
    }

    public(package) fun taker_volume(
        self: &AccountData,
    ): u64 {
        self.taker_volume
    }

    public(package) fun maker_volume(
        self: &AccountData,
    ): u64 {
        self.maker_volume
    }

    public(package) fun set_voted_proposal(
        self: &mut AccountData,
        proposal: Option<ID>
    ): Option<ID> {
        let prev_proposal = self.voted_proposal;
        self.voted_proposal = proposal;

        prev_proposal
    }

    public(package) fun add_settled_amounts(
        self: &mut AccountData,
        base: u64,
        quote: u64,
        deep: u64,
    ) {
        self.settled_balances.base = self.settled_balances.base + base;
        self.settled_balances.quote = self.settled_balances.quote + quote;
        self.settled_balances.deep = self.settled_balances.deep + deep;
    }

    public(package) fun add_owed_amounts(
        self: &mut AccountData,
        base: u64,
        quote: u64,
        deep: u64,
    ) {
        self.owed_balances.base = self.owed_balances.base + base;
        self.owed_balances.quote = self.owed_balances.quote + quote;
        self.owed_balances.deep = self.owed_balances.deep + deep;
    }

    /// Settle the account balances.
    /// Returns (base_out, quote_out, deep_out, base_in, quote_in, deep_in)
    public(package) fun settle(
        self: &mut AccountData,
    ): (u64, u64, u64, u64, u64, u64) {
        let (base_out, quote_out, deep_out) = self.settled_balances.reset();
        let (base_in, quote_in, deep_in) = self.owed_balances.reset();

        (base_out, quote_out, deep_out, base_in, quote_in, deep_in)
    }

    /// Update the account data for the new epoch.
    /// Returns the previous epoch, maker volume, and active stake.
    public(package) fun update(
        self: &mut AccountData,
        epoch: u64,
    ): (u64, u64, u64) {
        if (self.epoch == epoch) return (0, 0, 0);

        let prev_epoch = self.epoch;
        let maker_volume = self.maker_volume;
        let active_stake = self.active_stake;

        self.epoch = epoch;
        self.maker_volume = 0;
        self.taker_volume = 0;
        self.active_stake = self.active_stake + self.inactive_stake;
        self.inactive_stake = 0;
        self.voted_proposal = option::none();

        (prev_epoch, maker_volume, active_stake)
    }

    public(package) fun add_rebates(
        self: &mut AccountData,
        rebates: u64,
    ) {
        self.unclaimed_rebates = self.unclaimed_rebates + rebates;
    }

    //
    public(package) fun claim_rebates(
        self: &mut AccountData,
    ) {
        self.settled_balances.deep = self.settled_balances.deep + self.unclaimed_rebates;
        self.unclaimed_rebates = 0;
    }

    public(package) fun add_order(
        self: &mut AccountData,
        order_id: u128,
    ) {
        self.open_orders.insert(order_id);
    }

    public(package) fun remove_order(
        self: &mut AccountData,
        order_id: u128,
    ) {
        self.open_orders.remove(&order_id)
    }

    public(package) fun add_stake(
        self: &mut AccountData,
        stake: u64,
    ): (u64, u64) {
        let stake_before = self.active_stake + self.inactive_stake;
        self.inactive_stake = self.inactive_stake + stake;
        self.owed_balances.deep = self.owed_balances.deep + stake;

        (stake_before, stake_before + self.inactive_stake)
    }

    public(package) fun remove_stake(
        self: &mut AccountData,
    ): (u64, Option<ID>) {
        let stake_before = self.active_stake + self.inactive_stake;
        let voted_proposal = self.voted_proposal;
        self.active_stake = 0;
        self.inactive_stake = 0;
        self.voted_proposal = option::none();
        self.settled_balances.deep = self.settled_balances.deep + stake_before;

        (stake_before, voted_proposal)
    }

    public(package) fun open_orders(
        self: &AccountData,
    ): VecSet<u128> {
        self.open_orders
    }

    fun reset(balances: &mut Balances): (u64, u64, u64) {
        let base = balances.base;
        let quote = balances.quote;
        let deep = balances.deep;
        balances.base = 0;
        balances.quote = 0;
        balances.deep = 0;

        (base, quote, deep)
    }
}
