module deepbook::state {
    use sui::{
        table::{Self, Table},
    };

    use deepbook::{
        math,
        history::{Self, History},
        order::Order,
        order_info::OrderInfo,
        governance::{Self, Governance},
        account::{Self, Account},
        balances::{Self, Balances},
    };

    const ENoStake: u64 = 1;

    public struct State has store {
        accounts: Table<ID, Account>,
        history: History,
        governance: Governance,
    }

    public(package) fun empty(ctx: &mut TxContext): State {
        let governance = governance::empty(ctx);
        let trade_params = governance.trade_params();
        let history = history::empty(trade_params, ctx.epoch(), ctx);

        State {
            history,
            governance,
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
        self.governance.update(ctx);
        self.history.update(self.governance.trade_params(), ctx);
        let fills = order_info.fills();
        let mut i = 0;

        while (i < fills.length()) {
            let fill = &fills[i];
            let maker = fill.balance_manager_id();
            self.update_account(maker, ctx);
            let account = &mut self.accounts[maker];
            account.process_maker_fill(fill);

            let volume = fill.base_quantity();
            self.history.add_volume(volume, account.active_stake());
            let historic_maker_fee = self.history.historic_maker_fee(fill.maker_epoch());
            let order_maker_fee = math::mul(
                math::mul(volume, historic_maker_fee),
                fill.maker_deep_per_base()
            );
            self.history.add_total_fees_collected(balances::new(0, 0, order_maker_fee));

            i = i + 1;
        };

        self.update_account(order_info.balance_manager_id(), ctx);
        let account = &mut self.accounts[order_info.balance_manager_id()];
        account.add_order(order_info.order_id());
        account.add_taker_volume(order_info.executed_quantity());

        let account_volume = account.total_volume();
        let account_stake = account.active_stake();
        let taker_fee = self.governance.trade_params().taker_fee_for_user(account_stake, math::mul(account_volume, order_info.deep_per_base()));
        let maker_fee = self.governance.trade_params().maker_fee();

        let (mut settled, mut owed) = order_info.calculate_partial_fill_balances(taker_fee, maker_fee);
        let (old_settled, old_owed) = account.settle();
        self.history.add_total_fees_collected(balances::new(0, 0, order_info.paid_fees()));
        settled.add_balances(old_settled);
        owed.add_balances(old_owed);

        (settled, owed)
    }

    public(package) fun withdraw_settled_amounts(
        self: &mut State,
        balance_manager_id: ID,
    ): (Balances, Balances) {
        let account = &mut self.accounts[balance_manager_id];

        account.settle()
    }

    /// Update account settled balances and volumes.
    /// Remove order from account orders.
    public(package) fun process_cancel(
        self: &mut State,
        order: &mut Order,
        account_id: ID,
        ctx: &TxContext,
    ): (Balances, Balances) {
        self.governance.update(ctx);
        self.history.update(self.governance.trade_params(), ctx);
        self.update_account(account_id, ctx);
        order.set_canceled();

        let epoch = order.epoch();
        let maker_fee = self.history.historic_maker_fee(epoch);
        let balances = order.calculate_cancel_refund(maker_fee, option::none());

        let account = &mut self.accounts[account_id];
        account.remove_order(order.order_id());
        account.add_settled_balances(balances);

        account.settle()
    }

    public(package) fun process_modify(
        self: &mut State,
        account_id: ID,
        cancel_quantity: u64,
        order: &Order,
        ctx: &TxContext,
    ): (Balances, Balances) {
        self.governance.update(ctx);
        self.history.update(self.governance.trade_params(), ctx);
        self.update_account(account_id, ctx);

        let epoch = order.epoch();
        let maker_fee = self.history.historic_maker_fee(epoch);
        let balances = order.calculate_cancel_refund(maker_fee, option::some(cancel_quantity));

        self.accounts[account_id].add_settled_balances(balances);

        self.accounts[account_id].settle()
    }

    public(package) fun process_stake(
        self: &mut State,
        account_id: ID,
        new_stake: u64,
        ctx: &TxContext,
    ): (Balances, Balances) {
        self.governance.update(ctx);
        self.history.update(self.governance.trade_params(), ctx);
        self.update_account(account_id, ctx);

        let (stake_before, stake_after) = self.accounts[account_id].add_stake(new_stake);
        self.governance.adjust_voting_power(stake_before, stake_after);

        self.accounts[account_id].settle()
    }

    public(package) fun process_unstake(
        self: &mut State,
        account_id: ID,
        ctx: &TxContext,
    ): (Balances, Balances) {
        self.governance.update(ctx);
        self.history.update(self.governance.trade_params(), ctx);
        self.update_account(account_id, ctx);

        let account = &mut self.accounts[account_id];
        let active_stake = account.active_stake();
        let inactive_stake = account.inactive_stake();
        let voted_proposal = account.voted_proposal();
        account.remove_stake();
        self.governance.adjust_voting_power(active_stake + inactive_stake, 0);
        self.governance.adjust_vote(voted_proposal, option::none(), active_stake);

        account.settle()
    }

    public(package) fun process_proposal(
        self: &mut State,
        account_id: ID,
        taker_fee: u64,
        maker_fee: u64,
        stake_required: u64,
        ctx: &TxContext,
    ) {
        self.governance.update(ctx);
        self.history.update(self.governance.trade_params(), ctx);
        self.update_account(account_id, ctx);

        let stake = self.accounts[account_id].active_stake();
        assert!(stake > 0, ENoStake);

        self.governance.add_proposal(taker_fee, maker_fee, stake_required, stake, account_id);
        self.process_vote(account_id, account_id, ctx);
    }

    public(package) fun process_vote(
        self: &mut State,
        account_id: ID,
        proposal_id: ID,
        ctx: &TxContext,
    ) {
        self.governance.update(ctx);
        self.history.update(self.governance.trade_params(), ctx);
        self.update_account(account_id, ctx);

        let account = &mut self.accounts[account_id];
        assert!(account.active_stake() > 0, ENoStake);

        let prev_proposal = account.set_voted_proposal(option::some(proposal_id));
        self.governance.adjust_vote(
            prev_proposal,
            option::some(proposal_id),
            account.active_stake(),
        );
    }

    public(package) fun process_claim_rebates(
        self: &mut State,
        account_id: ID,
        ctx: &TxContext,
    ): (Balances, Balances) {
        self.governance.update(ctx);
        self.history.update(self.governance.trade_params(), ctx);
        self.update_account(account_id, ctx);

        let account = &mut self.accounts[account_id];
        account.claim_rebates();

        account.settle()
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
    ): &Account {
        &self.accounts[account_id]
    }

    public(package) fun history_mut(
        self: &mut State,
    ): &mut History {
        &mut self.history
    }

    fun update_account(
        self: &mut State,
        account_id: ID,
        ctx: &TxContext,
    ) {
        if (!self.accounts.contains(account_id)) {
            self.accounts.add(account_id, account::empty(ctx));
        };

        let account = &mut self.accounts[account_id];
        let (prev_epoch, maker_volume, active_stake) = account.update(ctx);
        if (prev_epoch > 0 && maker_volume > 0 && active_stake > 0) {
            let rebates = self.history.calculate_rebate_amount(prev_epoch, maker_volume, active_stake);
            account.add_rebates(rebates);
        }
    }
}
