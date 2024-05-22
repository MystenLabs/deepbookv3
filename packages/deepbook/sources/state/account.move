module deepbook::account {
    use sui::vec_set::{Self, VecSet};
    use deepbook::{
        fill::Fill,
        balances::{Self, Balances},
    };

    /// Account data that is updated every epoch.
    public struct Account has store, copy, drop {
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
    ): Account {
        Account {
            epoch,
            open_orders: vec_set::empty(),
            taker_volume: 0,
            maker_volume: 0,
            active_stake: 0,
            inactive_stake: 0,
            voted_proposal: option::none(),
            unclaimed_rebates: 0,
            settled_balances: balances::empty(),
            owed_balances: balances::empty(),
        }
    }

    public(package) fun active_stake(
        self: &Account,
    ): u64 {
        self.active_stake
    }

    public(package) fun process_maker_fill(
        self: &mut Account,
        fill: &Fill,
    ) {
        let settled_balances = fill.get_settled_maker_quantities();
        self.settled_balances.add_balances(settled_balances);
        if (!fill.expired()) {
            self.maker_volume = self.maker_volume + fill.volume();
        };
        if (fill.expired() || fill.completed()) {
            self.open_orders.remove(&fill.order_id());
        }
    }

    public(package) fun increase_maker_volume(
        self: &mut Account,
        volume: u64,
    ) {
        self.maker_volume = self.maker_volume + volume;
    }

    public(package) fun increase_taker_volume(
        self: &mut Account,
        volume: u64,
    ) {
        self.taker_volume = self.taker_volume + volume;
    }

    public(package) fun taker_volume(
        self: &Account,
    ): u64 {
        self.taker_volume
    }

    public(package) fun maker_volume(
        self: &Account,
    ): u64 {
        self.maker_volume
    }

    public(package) fun set_voted_proposal(
        self: &mut Account,
        proposal: Option<ID>
    ): Option<ID> {
        let prev_proposal = self.voted_proposal;
        self.voted_proposal = proposal;

        prev_proposal
    }

    public(package) fun add_settled_amounts(
        self: &mut Account,
        balances: Balances,
    ) {
        self.settled_balances.add_balances(balances);
    }

    public(package) fun add_owed_amounts(
        self: &mut Account,
        balances: Balances,
    ) {
        self.owed_balances.add_balances(balances);
    }

    /// Settle the account balances.
    /// Returns (base_out, quote_out, deep_out, base_in, quote_in, deep_in)
    public(package) fun settle(
        self: &mut Account,
    ): (Balances, Balances) {
        let settled = self.settled_balances.reset();
        let owed = self.owed_balances.reset();

        (settled, owed)
    }

    /// Update the account data for the new epoch.
    /// Returns the previous epoch, maker volume, and active stake.
    public(package) fun update(
        self: &mut Account,
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
        self: &mut Account,
        rebates: u64,
    ) {
        self.unclaimed_rebates = self.unclaimed_rebates + rebates;
    }

    public(package) fun claim_rebates(
        self: &mut Account,
    ): (Balances, Balances) {
        self.settled_balances.add_deep(self.unclaimed_rebates);
        self.unclaimed_rebates = 0;

        self.settle()
    }

    public(package) fun add_order(
        self: &mut Account,
        order_id: u128,
    ) {
        self.open_orders.insert(order_id);
    }

    public(package) fun remove_order(
        self: &mut Account,
        order_id: u128,
    ) {
        self.open_orders.remove(&order_id)
    }

    public(package) fun add_stake(
        self: &mut Account,
        stake: u64,
    ): (u64, u64) {
        let stake_before = self.active_stake + self.inactive_stake;
        self.inactive_stake = self.inactive_stake + stake;
        self.owed_balances.add_deep(stake);

        (stake_before, stake_before + self.inactive_stake)
    }

    public(package) fun remove_stake(
        self: &mut Account,
    ): (u64, Option<ID>) {
        let stake_before = self.active_stake + self.inactive_stake;
        let voted_proposal = self.voted_proposal;
        self.active_stake = 0;
        self.inactive_stake = 0;
        self.voted_proposal = option::none();
        self.settled_balances.add_deep(stake_before);

        (stake_before, voted_proposal)
    }

    public(package) fun open_orders(
        self: &Account,
    ): VecSet<u128> {
        self.open_orders
    }
}
