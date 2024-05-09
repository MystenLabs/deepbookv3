// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

module deepbook::state { // Consider renaming this module
    use sui::{
        balance::Balance,
        bag::{Self, Bag},
        sui::SUI,
    };

    use deepbook::{
        pool,
        pool_metadata,
    };

    const EPoolAlreadyExists: u64 = 2;

    const DEFAULT_TAKER_FEE: u64 = 1000;
    const DEFAULT_MAKER_FEE: u64 = 500;

    public struct State has key {
        id: UID,
        // TODO: upgrade-ability plan? do we need?
        pools: Bag,
    }

    /// Create a new State and share it. Called once during init.
    public(package) fun create_and_share(ctx: &mut TxContext) {
        let state = State {
            id: object::new(ctx),
            pools: bag::new(ctx),
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

    #[test_only]
    public fun pools(self: &State): &Bag {
        &self.pools
    }
}
