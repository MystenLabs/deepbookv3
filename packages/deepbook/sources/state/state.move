module deepbook::state {
    use sui::{
        table::{Self, Table},
    };

    use deepbook::{
        history::{Self, History},
        order::{Order},
        order_info::{OrderInfo},
        governance::{Self, Governance},
        deep_price::{Self, DeepPrice},
        user::{Self, User},
    };

    const ENotEnoughStake: u64 = 2;

    const STAKE_REQUIRED_TO_PARTICIPATE: u64 = 100; // TODO

    public struct State has store {
        users: Table<address, User>,
        history: History,
        governance: Governance,
        deep_price: DeepPrice,
        whitelisted: bool,
    }

    public(package) fun empty(ctx: &mut TxContext): State {
        State {
            history: history::empty(ctx),
            governance: governance::empty(ctx.epoch()),
            users: table::new(ctx),
            deep_price: deep_price::empty(),
            whitelisted: false,
        }
    }

    public(package) fun whitelisted(
        self: &State,
    ): bool {
        self.whitelisted
    }

    public(package) fun set_whitelist(
        self: &mut State,
        whitelisted: bool,
    ) {
        self.whitelisted = whitelisted;
    }

    public(package) fun process_create(
        self: &mut State,
        order_info: &OrderInfo,
        ctx: &TxContext,
    ) {
        self.history.update(ctx);
        let fills = order_info.fills();
        let mut i = 0;
        while (i < fills.length()) {
            let fill = &fills[i];
            let (order_id, owner, expired, completed) = fill.fill_status();
            let (base, quote, deep) = fill.settled_quantities();
            self.update_user(owner, ctx.epoch());
            let user = &mut self.users[owner];
            user.add_settled_amounts(base, quote, deep);
            user.increase_maker_volume(base);
            if (expired || completed) {
                user.remove_order(order_id);
            };

            self.history.add_volume(base, user.active_stake(), user.maker_volume() == base);

            i = i + 1;
        };

        self.update_user(order_info.owner(), ctx.epoch());
        let user = &mut self.users[order_info.owner()];
        user.add_order(order_info.order_id());
        user.increase_taker_volume(order_info.executed_quantity());
    }

    public(package) fun process_cancel(
        self: &mut State,
        order: &mut Order,
        order_id: u128,
        account_owner: address,
        ctx: &TxContext,
    ) {
        self.history.update(ctx);
        order.set_canceled();
        self.update_user(account_owner, ctx.epoch());

        let user = &mut self.users[account_owner];
        let cancel_quantity = order.quantity();
        let (base_quantity, quote_quantity, deep_quantity) = order.cancel_amounts(
            cancel_quantity,
            false,
        );
        user.remove_order(order_id);
        user.add_settled_amounts(base_quantity, quote_quantity, deep_quantity);
    }

    public(package) fun process_modify(
        self: &mut State,
        owner: address,
        base_quantity: u64,
        quote_quantity: u64,
        deep_quantity: u64,
        ctx: &TxContext,
    ) {
        self.history.update(ctx);
        self.update_user(owner, ctx.epoch());

        self.users[owner].add_settled_amounts(base_quantity, quote_quantity, deep_quantity);
    }

    public(package) fun process_stake(
        self: &mut State,
        owner: address,
        new_stake: u64,
        ctx: &TxContext,
    ) {
        self.history.update(ctx);
        self.governance.update(ctx);
        self.update_user(owner, ctx.epoch());

        let (stake_before, stake_after) = self.users[owner].add_stake(new_stake);
        self.governance.adjust_voting_power(stake_before, stake_after);
    }

    public(package) fun process_unstake(
        self: &mut State,
        owner: address,
        ctx: &TxContext,
    ) {
        self.history.update(ctx);
        self.governance.update(ctx);
        self.update_user(owner, ctx.epoch());

        let user = &mut self.users[owner];
        let (total_stake, voted_proposal) = user.remove_stake();
        self.governance.adjust_voting_power(total_stake, 0);
        self.governance.adjust_vote(voted_proposal, option::none(), total_stake);
    }

    public(package) fun process_proposal(
        self: &mut State,
        user: address,
        taker_fee: u64,
        maker_fee: u64,
        stake_required: u64,
        ctx: &TxContext,
    ) {
        self.history.update(ctx);
        self.governance.update(ctx);
        self.update_user(user, ctx.epoch());

        let stake = self.users[user].active_stake();
        assert!(stake >= STAKE_REQUIRED_TO_PARTICIPATE, ENotEnoughStake);

        self.governance.add_proposal(taker_fee, maker_fee, stake_required, stake, user);
        self.process_vote(user, user, ctx);
    }

    public(package) fun process_vote(
        self: &mut State,
        user: address,
        proposal_id: address,
        ctx: &TxContext,
    ) {
        self.history.update(ctx);
        self.governance.update(ctx);
        self.update_user(user, ctx.epoch());

        let user = &mut self.users[user];
        assert!(user.active_stake() >= STAKE_REQUIRED_TO_PARTICIPATE, ENotEnoughStake);

        let prev_proposal = user.set_voted_proposal(option::some(proposal_id));
        self.governance.adjust_vote(
            prev_proposal,
            option::some(proposal_id),
            user.active_stake(),
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

    public(package) fun governance_mut(
        self: &mut State,
        ctx: &TxContext,
    ): &mut Governance {
        self.governance.update(ctx);

        &mut self.governance
    }

    public(package) fun user(
        self: &State,
        user: address,
    ): &User {
        &self.users[user]
    }

    public(package) fun user_mut(
        self: &mut State,
        user: address,
        epoch: u64,
    ): &mut User {
        self.update_user(user, epoch);

        &mut self.users[user]
    }

    fun update_user(
        self: &mut State,
        user: address,
        epoch: u64,
    ) {
        add_new_user(self, user, epoch);
        let user = &mut self.users[user];
        let (prev_epoch, maker_volume, active_stake) = user.update(epoch);
        let rebates = self.history.calculate_rebate_amount(prev_epoch, maker_volume, active_stake);
        user.add_rebates(rebates);
    }

    fun add_new_user(
        self: &mut State,
        user: address,
        epoch: u64,
    ) {
        if (!self.users.contains(user)) {
            self.users.add(user, user::empty(epoch));
        };
    }
}
