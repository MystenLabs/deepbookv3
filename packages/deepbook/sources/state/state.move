// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

module deepbook::state { // Consider renaming this module
    use sui::{
        balance::{Self, Balance},
        bag::{Self, Bag},
        sui::SUI,
    };

    use deepbook::{
        account::{Account, TradeProof},
        pool::{Pool, DEEP, Self},
        state_manager,
        pool_metadata::{Self, PoolMetadata, Proposal},
    };

    const EPoolDoesNotExist: u64 = 1;
    const EPoolAlreadyExists: u64 = 2;
    const ENotEnoughStake: u64 = 3;

    const STAKE_REQUIRED_TO_PARTICIPATE: u64 = 100;
    const DEFAULT_TAKER_FEE: u64 = 1000;
    const DEFAULT_MAKER_FEE: u64 = 500;

    public struct State has key {
        id: UID,
        // TODO: upgrade-ability plan? do we need?
        pools: Bag,
        vault: Balance<DEEP>,
    }

    /// Number of DEEP tokens staked in the protocol.
    public fun vault_value(self: &State): u64 {
        self.vault.value()
    }

    /// Create a new State and share it. Called once during init.
    public(package) fun create_and_share(ctx: &mut TxContext) {
        let state = State {
            id: object::new(ctx),
            pools: bag::new(ctx),
            vault: balance::zero(),
        };
        transfer::share_object(state);
    }

    /// Create a new pool. Calls create_pool inside Pool then registers it in
    /// the state. `pool_key` is a sorted, concatenated string of the two asset
    /// names. If SUI/USDC exists, you can't create USDC/SUI.
    public(package) fun create_pool<BaseAsset, QuoteAsset>(
        self: &mut State,
        tick_size: u64,
        lot_size: u64,
        min_size: u64,
        creation_fee: Balance<SUI>,
        ctx: &mut TxContext,
    ) {
        let (pool_key, rev_key) = pool::create_pool<BaseAsset, QuoteAsset>(
            DEFAULT_TAKER_FEE,
            DEFAULT_MAKER_FEE,
            tick_size,
            lot_size,
            min_size,
            creation_fee,
            ctx
        );

        assert!(!self.pools.contains(pool_key) && !self.pools.contains(rev_key), EPoolAlreadyExists);

        let pool_metadata = pool_metadata::empty(ctx.epoch());
        self.pools.add(pool_key, pool_metadata);
    }

    /// Set the as stable or volatile. This changes the fee structure of the pool.
    /// New proposals will be asserted against the new fee structure.
    public(package) fun set_pool_as_stable<BaseAsset, QuoteAsset>(
        self: &mut State,
        pool: &Pool<BaseAsset, QuoteAsset>,
        stable: bool,
        ctx: &TxContext,
    ) {
        self.get_pool_metadata_mut(pool, ctx)
            .set_as_stable(stable);

        // TODO: set fees
    }

    /// Stake DEEP in the pool. This will increase the user's voting power next epoch
    /// Individual user stakes are stored inside of the pool.
    /// A user's stake is tracked as stake_amount, staked before current epoch, their "active" amount,
    /// and next_stake_amount, stake_amount + new stake during this epoch. Upon refresh, stake_amount = next_stake_amount.
    /// Total voting power is maintained in the pool metadata.
    public(package) fun stake<BaseAsset, QuoteAsset>(
        self: &mut State,
        pool: &mut Pool<BaseAsset, QuoteAsset>,
        account: &mut Account,
        proof: &TradeProof,
        amount: u64,
        ctx: &mut TxContext,
    ) {
        let user = account.owner();
        let total_stake = pool.increase_user_stake(user, amount, ctx);
        self.get_pool_metadata_mut(pool, ctx)
            .adjust_voting_power(total_stake - amount, total_stake);
        let balance = account.withdraw_with_proof<DEEP>(proof, amount, false, ctx).into_balance();
        self.vault.join(balance);
    }

    /// Unstake DEEP in the pool. This will decrease the user's voting power.
    /// All stake for this user will be removed.
    /// If the user has voted, their vote will be removed.
    /// If the user had accumulated rebates during this epoch, they will be forfeited.
    public(package) fun unstake<BaseAsset, QuoteAsset>(
        self: &mut State,
        pool: &mut Pool<BaseAsset, QuoteAsset>,
        account: &mut Account,
        proof: &TradeProof,
        ctx: &mut TxContext
    ) {
        let user = account.owner();
        let total_stake = pool.remove_user_stake(user, ctx);
        let prev_proposal_id = pool.set_user_voted_proposal(user, option::none(), ctx);
        if (prev_proposal_id.is_some()) {
            let pool_metadata = self.get_pool_metadata_mut(pool, ctx);
            pool_metadata.adjust_voting_power(0, total_stake);
            let winning_proposal = pool_metadata.vote(option::none(), prev_proposal_id, total_stake);
            self.apply_winning_proposal(pool, winning_proposal);
        };
        
        let balance = self.vault.split(total_stake).into_coin(ctx);
        account.deposit_with_proof<DEEP>(proof, balance);
    }

    /// Submit a proposal to change the fee structure of a pool.
    /// The user submitting this proposal must have vested stake in the pool.
    public(package) fun submit_proposal<BaseAsset, QuoteAsset>(
        self: &mut State,
        pool: &Pool<BaseAsset, QuoteAsset>,
        user: address,
        maker_fee: u64,
        taker_fee: u64,
        stake_required: u64,
        ctx: &TxContext,
    ) {
        let (stake, _) = pool.get_user_stake(user, ctx);
        assert!(stake >= STAKE_REQUIRED_TO_PARTICIPATE, ENotEnoughStake);

        let pool_metadata = self.get_pool_metadata_mut(pool, ctx);
        pool_metadata.add_proposal(maker_fee, taker_fee, stake_required);
    }

    /// Vote on a proposal using the user's full voting power.
    /// If the vote pushes proposal over quorum, PoolData is created.
    /// Set the Pool's next_pool_data with the created PoolData.
    public(package) fun vote<BaseAsset, QuoteAsset>(
        self: &mut State,
        pool: &mut Pool<BaseAsset, QuoteAsset>,
        user: address,
        proposal_id: u64,
        ctx: &TxContext,
    ) {
        let (stake, _) = pool.get_user_stake(user, ctx);
        assert!(stake >= STAKE_REQUIRED_TO_PARTICIPATE, ENotEnoughStake);
        let prev_proposal_id = pool.set_user_voted_proposal(user, option::some(proposal_id), ctx);

        let pool_metadata = self.get_pool_metadata_mut(pool, ctx);
        let winning_proposal = pool_metadata.vote(option::some(proposal_id), prev_proposal_id, stake);
        self.apply_winning_proposal(pool, winning_proposal);
    }

    /// Check whether pool exists, refresh and return its metadata.
    fun get_pool_metadata_mut<BaseAsset, QuoteAsset>(
        self: &mut State,
        pool: &Pool<BaseAsset, QuoteAsset>,
        ctx: &TxContext
    ): &mut PoolMetadata {
        let pool_key = pool.key();
        assert!(self.pools.contains(pool_key), EPoolDoesNotExist);

        let pool_metadata: &mut PoolMetadata = &mut self.pools[pool_key];
        pool_metadata.refresh(ctx.epoch());
        pool_metadata
    }

    fun apply_winning_proposal<BaseAsset, QuoteAsset>(
        _self: &State,
        pool: &mut Pool<BaseAsset, QuoteAsset>,
        winning_proposal: Option<Proposal>,
    ) {
        let next_trade_params = if (winning_proposal.is_none()) {
            option::none()
        } else {
            let (taker_fee, maker_fee, stake_required) = winning_proposal
                .borrow()
                .proposal_params();

            let fees = state_manager::new_trade_params(taker_fee, maker_fee, stake_required);
            option::some(fees)
        };
        pool.set_next_trade_params(next_trade_params);
    }

    #[test_only]
    public fun pools(self: &State): &Bag {
        &self.pools
    }
}
