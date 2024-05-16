module deepbook::state {
    use sui::{
        table::{Self, Table},
    };

    use deepbook::{
        history::{Self, History},
        order_info::OrderInfo,
        governance::{Self, Governance},
        deep_price::{Self, DeepPrice},
        account_data::{Self, AccountData},
    };

    const ENotEnoughStake: u64 = 2;

    const STAKE_REQUIRED_TO_PARTICIPATE: u64 = 100; // TODO

    public struct State has store {
        accounts: Table<ID, AccountData>,
        history: History,
        governance: Governance,
        deep_price: DeepPrice,
    }

    public(package) fun empty(ctx: &mut TxContext): State {
        State {
            history: history::empty(ctx),
            governance: governance::empty(ctx),
            accounts: table::new(ctx),
            deep_price: deep_price::empty(),
        }
    }

    /// Process order fills.
    /// Update all maker settled balances and volumes.
    /// Update taker settled balances and volumes.
    public(package) fun process_create(
        self: &mut State,
        order_info: &OrderInfo,
        ctx: &TxContext,
    ) {
        self.governance.update(ctx);
        self.history.update(ctx, self.governance.trade_params());
        let taker = order_info.account_id();
        self.update_account(taker, ctx.epoch());

        let stake_required = self.governance.trade_params().stake_required();
        let taker_fee = self.governance.trade_params().taker_fee();
        let deep_per_base = order_info.deep_per_base();

        let fills = order_info.fills();
        let mut i = 0;
        while (i < fills.length()) {
            let fill = &fills[i];
            let maker = fill.maker_account_id();
            self.update_account(maker, ctx.epoch());

            let maker_fee = fill.maker_epoch();
            self.accounts[maker].process_maker_fill(fill, maker_fee);
            self.accounts[taker].process_taker_fill(fill, taker_fee, deep_per_base, stake_required);

            if (!fill.expired()) {
                self.history.add_volume(fill.base_quantity(), &self.accounts[maker]);
            };

            i = i + 1;
        };

        if (order_info.remaining_quantity() > 0) {
            self.accounts[taker].add_order(order_info.order_id());
        };
    }

    public(package) fun process_stake(
        self: &mut State,
        account_id: ID,
        new_stake: u64,
        ctx: &TxContext,
    ) {
        self.governance.update(ctx);
        self.history.update(ctx, self.governance.trade_params());
        self.update_account(account_id, ctx.epoch());

        let (stake_before, stake_after) = self.accounts[account_id].add_stake(new_stake);
        self.governance.adjust_voting_power(stake_before, stake_after);
    }

    public(package) fun process_unstake(
        self: &mut State,
        account_id: ID,
        ctx: &TxContext,
    ) {
        self.governance.update(ctx);
        self.history.update(ctx, self.governance.trade_params());
        self.governance.update(ctx);
        self.update_account(account_id, ctx.epoch());

        let account_data = &mut self.accounts[account_id];
        let (total_stake, voted_proposal) = account_data.remove_stake();
        self.governance.adjust_voting_power(total_stake, 0);
        self.governance.adjust_vote(voted_proposal, option::none(), total_stake);
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
        self.history.update(ctx, self.governance.trade_params());
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
        self.governance.update(ctx);
        self.history.update(ctx, self.governance.trade_params());
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

    public(package) fun deep_price(
        self: &State,
    ): &DeepPrice {
        &self.deep_price
    }

    public(package) fun governance(
        self: &State,
    ): &Governance {
        &self.governance
    }

    public(package) fun history(
        self: &State,
    ): &History {
        &self.history
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
        ctx: &TxContext,
    ): &mut AccountData {
        self.governance.update(ctx);
        self.history.update(ctx, self.governance.trade_params());
        self.update_account(account_id, ctx.epoch());

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
