// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

module deepbook::pool_state {
    public struct PoolEpochState has copy, store, drop {
        total_maker_volume: u64,
        total_staked_maker_volume: u64,
        total_fees_collected: u64,
        stake_required: u64,
        taker_fee: u64,
        maker_fee: u64,
    }

    public struct PoolState has copy, store {
        epoch: u64,
        // TODO: Won't this get too filled? Is there something planned to delete the historic states?
        historic_states: vector<PoolEpochState>,
        current_state: PoolEpochState,
        next_state: PoolEpochState,
    }

    public(package) fun new_pool_epoch_state(
        total_maker_volume: u64,
        total_staked_maker_volume: u64,
        total_fees_collected: u64,
        stake_required: u64,
        taker_fee: u64,
        maker_fee: u64,
    ): PoolEpochState {
        PoolEpochState {
            total_maker_volume,
            total_staked_maker_volume,
            total_fees_collected,
            stake_required,
            taker_fee,
            maker_fee,
        }
    }

    public(package) fun new_pool_epoch_state_with_gov_params( //rename
        stake_required: u64,
        taker_fee: u64,
        maker_fee: u64,
    ): PoolEpochState {
        new_pool_epoch_state(0, 0, 0, stake_required, taker_fee, maker_fee)
    }

    /// Create an empty pool state
    public(package) fun new_pool_state(
        stake_required: u64,
        taker_fee: u64,
        maker_fee: u64,
        ctx: &TxContext,
    ): PoolState {
        PoolState {
            epoch: ctx.epoch(),
            historic_states: vector::empty(),
            current_state: new_pool_epoch_state_with_gov_params(stake_required, taker_fee, maker_fee),
            next_state: new_pool_epoch_state_with_gov_params(stake_required, taker_fee, maker_fee),
        }
    }

    /// Refresh the pool state if the epoch has changed
    public(package) fun refresh(
        state: &mut PoolState,
        ctx: &TxContext,
    ) {
        let current_epoch = ctx.epoch();
        if (state.epoch == current_epoch) return;

        state.epoch = current_epoch;
        state.historic_states.push_back(state.current_state);
        state.current_state = state.next_state;
    }

    /// Set the next epoch pool state
    public(package) fun set_next_epoch( // TODO: remove pool_state naming
        state: &mut PoolState,
        next_epoch_state: Option<PoolEpochState>,
    ) {
        if (next_epoch_state.is_some()) {
            state.next_state = *next_epoch_state.borrow();
        } else {
            state.next_state.taker_fee = state.current_state.taker_fee;
            state.next_state.maker_fee = state.current_state.maker_fee;
            state.next_state.stake_required = state.current_state.stake_required;
        }
    }

    public(package) fun maker_fee(state: &PoolState): u64 {
        state.current_state.maker_fee
    }

    public(package) fun taker_fee(state: &PoolState): u64 {
        state.current_state.taker_fee
    }

    public(package) fun stake_required(state: &PoolState): u64 {
        state.current_state.stake_required
    }
}
