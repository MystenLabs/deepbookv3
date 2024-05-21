module deepbook::state {
    use sui::{
        table::{Self, Table},
    };

    use deepbook::{
        history::{Self, History},
        order::Order,
        order_info::OrderInfo,
        governance::{Self, Governance},
        account_data::{Self, AccountData},
        balances::Balances,
    };

    const ENotEnoughStake: u64 = 2;

    const STAKE_REQUIRED_TO_PARTICIPATE: u64 = 100; // TODO

    public struct State has store {
        accounts: Table<ID, AccountData>,
        history: History,
        governance: Governance,
    }

    public(package) fun empty(ctx: &mut TxContext): State {
        State {
            history: history::empty(ctx),
            governance: governance::empty(ctx),
            accounts: table::new(ctx),
        }
    }

    /// Process order fills.
    /// Update all maker settled balances and volumes.
    /// Update taker settled balances and volumes.
    public(package) fun process_create(
        self: &mut State,
        order_info: &mut OrderInfo,
        ctx: &TxContext,
    ): (Balances, Balances) {
        self.history.update(ctx);
        let fills = order_info.fills();
        let mut i = 0;
        while (i < fills.length()) {
            let fill = &fills[i];
            let maker = fill.account_id();
            self.update_account(maker, ctx.epoch());
            let account_data = &mut self.accounts[maker];
            account_data.process_maker_fill(fill);

            let volume = fill.volume();
            self.history.add_volume(volume, account_data.active_stake(), account_data.maker_volume() == volume);

            i = i + 1;
        };

        self.update_account(order_info.account_id(), ctx.epoch());
        let account_data = &mut self.accounts[order_info.account_id()];
        account_data.add_order(order_info.order_id());
        account_data.increase_taker_volume(order_info.executed_quantity());

        let account_volume = account_data.taker_volume() + account_data.maker_volume();
        let account_stake = account_data.active_stake();
        let (mut settled, mut owed) = order_info.calculate_taker_maker_fees(account_volume, account_stake);
        let (old_settled, old_owed) = account_data.settle();
        settled.add_balances(old_settled);
        owed.add_balances(old_owed);

        (settled, owed)
    }

    /// Update account settled balances and volumes.
    /// Remove order from account orders.
    public(package) fun process_cancel(
        self: &mut State,
        order: &mut Order,
        order_id: u128,
        account_id: ID,
        ctx: &TxContext,
    ): (Balances, Balances) {
        self.history.update(ctx);
        order.set_canceled();
        self.update_account(account_id, ctx.epoch());

        let account_data = &mut self.accounts[account_id];
        let cancel_quantity = order.quantity();
        let balances = order.cancel_amounts(
            cancel_quantity,
            false,
        );
        account_data.remove_order(order_id);
        account_data.add_settled_amounts(balances);

        account_data.settle()
    }

    public(package) fun process_modify(
        self: &mut State,
        account_id: ID,
        balances: &Balances,
        ctx: &TxContext,
    ): (Balances, Balances) {
        self.history.update(ctx);
        self.update_account(account_id, ctx.epoch());
        self.accounts[account_id].add_settled_amounts(*balances);

        self.accounts[account_id].settle()
    }

    public(package) fun process_stake(
        self: &mut State,
        account_id: ID,
        new_stake: u64,
        ctx: &TxContext,
    ): (Balances, Balances) {
        self.history.update(ctx);
        self.governance.update(ctx);
        self.update_account(account_id, ctx.epoch());

        let (stake_before, stake_after) = self.accounts[account_id].add_stake(new_stake);
        self.governance.adjust_voting_power(stake_before, stake_after);

        self.accounts[account_id].settle()
    }

    public(package) fun process_unstake(
        self: &mut State,
        account_id: ID,
        ctx: &TxContext,
    ): (Balances, Balances) {
        self.history.update(ctx);
        self.governance.update(ctx);
        self.update_account(account_id, ctx.epoch());

        let account_data = &mut self.accounts[account_id];
        let (total_stake, voted_proposal) = account_data.remove_stake();
        self.governance.adjust_voting_power(total_stake, 0);
        self.governance.adjust_vote(voted_proposal, option::none(), total_stake);

        account_data.settle()
    }

    public(package) fun process_proposal(
        self: &mut State,
        account_id: ID,
        taker_fee: u64,
        maker_fee: u64,
        stake_required: u64,
        ctx: &TxContext,
    ) {
        self.history.update(ctx);
        self.governance.update(ctx);
        self.update_account(account_id, ctx.epoch());

        let stake = self.accounts[account_id].active_stake();
        assert!(stake >= STAKE_REQUIRED_TO_PARTICIPATE, ENotEnoughStake);

        self.governance.add_proposal(taker_fee, maker_fee, stake_required, stake, account_id);
        self.process_vote(account_id, account_id, ctx);
    }

    public(package) fun process_vote(
        self: &mut State,
        account_id: ID,
        proposal_id: ID,
        ctx: &TxContext,
    ) {
        self.history.update(ctx);
        self.governance.update(ctx);
        self.update_account(account_id, ctx.epoch());

        let account_data = &mut self.accounts[account_id];
        assert!(account_data.active_stake() >= STAKE_REQUIRED_TO_PARTICIPATE, ENotEnoughStake);

        let prev_proposal = account_data.set_voted_proposal(option::some(proposal_id));
        self.governance.adjust_vote(
            prev_proposal,
            option::some(proposal_id),
            account_data.active_stake(),
        );
    }

    public(package) fun governance(
        self: &State,
    ): &Governance {
        &self.governance
    }

    public(package) fun governance_mut(
        self: &mut State,
        ctx: &TxContext,
    ): &mut Governance {
        self.governance.update(ctx);

        &mut self.governance
    }

    public(package) fun account(
        self: &State,
        account_id: ID,
    ): &AccountData {
        &self.accounts[account_id]
    }

    public(package) fun account_mut(
        self: &mut State,
        account_id: ID,
        epoch: u64,
    ): &mut AccountData {
        self.update_account(account_id, epoch);

        &mut self.accounts[account_id]
    }

    fun update_account(
        self: &mut State,
        account_id: ID,
        epoch: u64,
    ) {
        add_new_account(self, account_id, epoch);
        let account_id = &mut self.accounts[account_id];
        let (prev_epoch, maker_volume, active_stake) = account_id.update(epoch);
        if (prev_epoch > 0 && maker_volume > 0 && active_stake > 0) {
            let rebates = self.history.calculate_rebate_amount(prev_epoch, maker_volume, active_stake);
            account_id.add_rebates(rebates);
        }
    }

    fun add_new_account(
        self: &mut State,
        account_id: ID,
        epoch: u64,
    ) {
        if (!self.accounts.contains(account_id)) {
            self.accounts.add(account_id, account_data::empty(epoch));
        };
    }
}
