module deepbook::v3user_manager {
    use sui::{
        table::{Self, Table},
        vec_set::{Self, VecSet},
    };

    use deepbook::{
        math,
        v3state::{Self, State},
        v3order::{OrderInfo, Order},
        v3governance::{Self, Governance},
        v3deep_price::{Self, DeepPrice},
    };

    const ENotEnoughStake: u64 = 2;

    const STAKE_REQUIRED_TO_PARTICIPATE: u64 = 100; // TODO

    /// User data that is updated every epoch.
    public struct User has store, copy, drop {
        epoch: u64,
        open_orders: VecSet<u128>,
        maker_volume: u64,
        old_stake: u64,
        new_stake: u64,
        voted_proposal: Option<address>,
        unclaimed_rebates: u64,
        settled_base_amount: u64,
        settled_quote_amount: u64,
        settled_deep_amount: u64,
        owed_base_amount: u64,
        owed_quote_amount: u64,
        owed_deep_amount: u64,
    }

    public struct UserManager has store {
        users: Table<address, User>,
        state: State,
        governance: Governance,
        deep_price: DeepPrice,
    }

    public(package) fun empty(taker_fee: u64, maker_fee: u64, stake_required: u64, ctx: &mut TxContext): UserManager {
        UserManager {
            state: v3state::empty(taker_fee, maker_fee, stake_required, ctx),
            governance: v3governance::empty(ctx.epoch()),
            users: table::new(ctx),
            deep_price: v3deep_price::empty(),
        }
    }

    public(package) fun process_create(
        self: &mut UserManager,
        order_info: &mut OrderInfo,
        ctx: &TxContext,
    ) {
        self.state.update(ctx);
        let fills = order_info.fills();
        let mut i = 0;
        while (i < fills.length()) {
            let fill = &fills[i];
            let (order_id, owner, expired, completed) = fill.fill_status();
            let (base, quote, deep) = fill.settled_quantities();
            self.update_user(owner, ctx.epoch());
            let user = &mut self.users[owner];
            user.settled_base_amount = user.settled_base_amount + base;
            user.settled_quote_amount = user.settled_quote_amount + quote;
            user.settled_deep_amount = user.settled_deep_amount + deep;
            if (expired || completed) {
                user.open_orders.remove(&order_id);
            };

            self.state.add_volume(base, self.users[owner].old_stake, self.users[owner].maker_volume == 0);

            i = i + 1;
        };

        self.update_user(order_info.owner(), ctx.epoch());
        self.calculate_trade_balances(order_info.owner(), order_info);
        self.users[order_info.owner()].open_orders.insert(order_info.order_id());
    }

    public(package) fun process_cancel(
        self: &mut UserManager,
        order: &mut Order,
        order_id: u128,
        owner: address,
        ctx: &TxContext,
    ) {
        self.state.update(ctx);
        order.set_canceled();

        let user = self.update_user(owner, ctx.epoch());
        let cancel_quantity = order.book_quantity();
        let (base_quantity, quote_quantity, deep_quantity) = order.cancel_amounts(
            cancel_quantity,
            false,
        );
        user.open_orders.remove(&order_id);
        user.settled_base_amount = user.settled_base_amount + base_quantity;
        user.settled_quote_amount = user.settled_quote_amount + quote_quantity;
        user.settled_deep_amount = user.settled_deep_amount + deep_quantity;
    }

    public(package) fun process_modify(
        self: &mut UserManager,
        owner: address,
        base_quantity: u64,
        quote_quantity: u64,
        deep_quantity: u64,
        ctx: &TxContext,
    ) {
        self.state.update(ctx);
        let user = self.update_user(owner, ctx.epoch());
        user.settled_base_amount = user.settled_base_amount + base_quantity;
        user.settled_quote_amount = user.settled_quote_amount + quote_quantity;
        user.settled_deep_amount = user.settled_deep_amount + deep_quantity;
    }

    public(package) fun process_stake(
        self: &mut UserManager,
        owner: address,
        new_stake: u64,
        ctx: &TxContext,
    ) {
        self.state.update(ctx);
        self.governance.update(ctx);
        let user = self.update_user(owner, ctx.epoch());
        let stake_before = user.old_stake + user.new_stake;
        user.new_stake = user.new_stake + new_stake;
        self.governance.adjust_voting_power(stake_before, stake_before + new_stake);
    }

    public(package) fun process_unstake(
        self: &mut UserManager,
        owner: address,
        ctx: &TxContext,
    ) {
        self.state.update(ctx);
        self.governance.update(ctx);
        self.update_user(owner, ctx.epoch());

        let user = &mut self.users[owner];
        let total_stake = user.old_stake + user.new_stake;
        let voted_proposal = user.voted_proposal;
        self.governance.adjust_voting_power(total_stake, 0);
        let winning_proposal = self.governance.adjust_vote(voted_proposal, option::none(), total_stake);
        self.state.set_next_trade_params(winning_proposal);

        user.settled_deep_amount = user.settled_deep_amount + total_stake;
    }

    public(package) fun process_proposal(
        self: &mut UserManager,
        user: address,
        taker_fee: u64,
        maker_fee: u64,
        stake_required: u64,
        ctx: &TxContext,
    ) {
        self.state.update(ctx);
        self.governance.update(ctx);
        self.update_user(user, ctx.epoch());
        let stake = self.users[user].old_stake;
        assert!(stake >= STAKE_REQUIRED_TO_PARTICIPATE, ENotEnoughStake);

        self.governance.add_proposal(taker_fee, maker_fee, stake_required, stake, user);
        self.process_vote(user, user, ctx);
    }

    public(package) fun process_vote(
        self: &mut UserManager,
        user: address,
        proposal_id: address,
        ctx: &TxContext,
    ) {
        self.state.update(ctx);
        self.governance.update(ctx);
        self.update_user(user, ctx.epoch());

        let stake = self.users[user].old_stake;
        assert!(stake >= STAKE_REQUIRED_TO_PARTICIPATE, ENotEnoughStake);

        let winning_proposal = self.governance.adjust_vote(
            self.users[user].voted_proposal,
            option::some(proposal_id),
            stake,
        );
        self.users[user].voted_proposal = option::some(proposal_id);
        self.state.set_next_trade_params(winning_proposal);
    }

    public(package) fun settle_user(
        self: &mut UserManager,
        user: address,
    ): (u64, u64, u64, u64, u64, u64) {
        let user = &mut self.users[user];
        let base_out = user.settled_base_amount;
        let quote_out = user.settled_quote_amount;
        let deep_out = user.settled_deep_amount;
        let base_in = user.owed_base_amount;
        let quote_in = user.owed_quote_amount;
        let deep_in = user.owed_deep_amount;
        user.settled_base_amount = 0;
        user.settled_quote_amount = 0;
        user.settled_deep_amount = 0;
        user.owed_base_amount = 0;
        user.owed_quote_amount = 0;
        user.owed_deep_amount = 0;

        (base_out, quote_out, deep_out, base_in, quote_in, deep_in)
    }

    public(package) fun calculate_fees(
        self: &UserManager,
        user: address,
        base_quantity: u64,
        quote_quantity: u64
    ): (u64, u64, u64) {
        let (taker_fee, _) = self.fees_for_user(user);
        self.deep_price.calculate_fees(taker_fee, base_quantity, quote_quantity)
    }

    fun update_user(
        self: &mut UserManager,
        user: address,
        epoch: u64,
    ): &mut User {
        add_new_user(self, user, epoch);
        let user = &mut self.users[user];
        if (user.epoch == epoch) return user;

        let rebates = self.state.calculate_rebate_amount(user.epoch, user.maker_volume, user.old_stake);
        user.epoch = epoch;
        user.maker_volume = 0;
        user.old_stake = user.old_stake + user.new_stake;
        user.new_stake = 0;
        user.unclaimed_rebates = user.unclaimed_rebates + rebates;
        user.voted_proposal = option::none();

        user
    }

    fun add_new_user(
        self: &mut UserManager,
        user: address,
        epoch: u64,
    ) {
        if (!self.users.contains(user)) {
            self.users.add(user, User {
                epoch,
                open_orders: vec_set::empty(),
                maker_volume: 0,
                old_stake: 0,
                new_stake: 0,
                voted_proposal: option::none(),
                unclaimed_rebates: 0,
                settled_base_amount: 0,
                settled_quote_amount: 0,
                settled_deep_amount: 0,
                owed_base_amount: 0,
                owed_quote_amount: 0,
                owed_deep_amount: 0,
            });
        };
    }

    /// Given an order, transfer the appropriate balances. Up until this point, any partial fills have been executed
    /// and the remaining quantity is the only quantity left to be injected into the order book.
    /// 1. Transfer the taker balances while applying taker fees.
    /// 2. Transfer the maker balances while applying maker fees.
    /// 3. Update the total fees for the order.
    fun calculate_trade_balances(
        self: &mut UserManager,
        user: address,
        order_info: &mut OrderInfo,
    ) {
        let (mut base_in, mut base_out) = (0, 0);
        let (mut quote_in, mut quote_out) = (0, 0);
        let mut deep_in = 0;
        let (taker_fee, maker_fee) = self.fees_for_user(user);
        let executed_quantity = order_info.executed_quantity();
        let remaining_quantity = order_info.remaining_quantity();
        let cumulative_quote_quantity = order_info.cumulative_quote_quantity();

        // Calculate the taker balances. These are derived from executed quantity.
        let (base_fee, quote_fee, deep_fee) = if (order_info.is_bid()) {
            self.deep_price.calculate_fees(taker_fee, 0, cumulative_quote_quantity)
        } else {
            self.deep_price.calculate_fees(taker_fee, executed_quantity, 0)
        };
        let mut total_fees = base_fee + quote_fee + deep_fee;
        deep_in = deep_in + deep_fee;
        if (order_info.is_bid()) {
            quote_in = quote_in + cumulative_quote_quantity + quote_fee;
            base_out = base_out + executed_quantity;
        } else {
            base_in = base_in + executed_quantity + base_fee;
            quote_out = quote_out + cumulative_quote_quantity;
        };

        // Calculate the maker balances. These are derived from the remaining quantity.
        let (base_fee, quote_fee, deep_fee) = if (order_info.is_bid()) {
            self.deep_price.calculate_fees(maker_fee, 0, math::mul(remaining_quantity, order_info.price()))
        } else {
            self.deep_price.calculate_fees(maker_fee, remaining_quantity, 0)
        };
        total_fees = total_fees + base_fee + quote_fee + deep_fee;
        deep_in = deep_in + deep_fee;
        if (order_info.is_bid()) {
            quote_in = quote_in + math::mul(remaining_quantity, order_info.price()) + quote_fee;
        } else {
            base_in = base_in + remaining_quantity + base_fee;
        };

        order_info.set_total_fees(total_fees);

        let user = &mut self.users[user];
        user.owed_base_amount = user.owed_base_amount + base_in;
        user.owed_quote_amount = user.owed_quote_amount + quote_in;
        user.owed_deep_amount = user.owed_deep_amount + deep_in;
        user.settled_base_amount = user.settled_base_amount + base_out;
        user.settled_quote_amount = user.settled_quote_amount + quote_out;
    }

    fun fees_for_user(
        self: &UserManager,
        user: address,
    ): (u64, u64)  {
        // TODO: user has to trade a certain amount of volume first
        let stake = if (self.users.contains(user)) {
            self.users[user].old_stake
        } else {
            0
        };
        let (taker_fee, maker_fee, stake_required) = self.state.trade_params();
        let taker_fee = if (stake >= stake_required) {
            taker_fee / 2
        } else {
            taker_fee
        };

        (taker_fee, maker_fee)
    }
}