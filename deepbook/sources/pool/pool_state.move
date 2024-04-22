// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

module deepbook::pool_state {
    use sui::vec_map::{Self, VecMap};

    const EHistoricStateNotFound: u64 = 1;
    
    public struct PoolEpochState has copy, store, drop {
        total_maker_volume: u64,
        total_staked_maker_volume: u64,
        total_fees_collected: u64,
        stake_required: u64,
        taker_fee: u64,
        maker_fee: u64,
        // Number of users with uncalculated rebates. If 0, this state can be dropped.
        // TODO: this value must increment when a user with enough stakes generates first maker volume.
        users_with_rebates: u64,
    }

    public struct PoolState has copy, store {
        epoch: u64,
        // TODO: Won't this get too filled? Is there something planned to delete the historic states?
        historic_states: VecMap<u64, PoolEpochState>,
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
            users_with_rebates: 0,
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
    public(package) fun empty(
        stake_required: u64,
        taker_fee: u64,
        maker_fee: u64,
        ctx: &TxContext,
    ): PoolState {
        PoolState {
            epoch: ctx.epoch(),
            historic_states: vec_map::empty(),
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

        // Save this state if there are users who might need it to calculate rebates
        if (state.current_state.users_with_rebates != 0) {
            state.historic_states.insert(state.epoch, state.current_state);
        };
        
        state.epoch = current_epoch;
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

    /// Get a specific state. Used to calculate rebates.
    public(package) fun historic_state(
        state: &PoolState,
        epoch: &u64,
    ): &PoolEpochState {
        assert!(state.historic_states.contains(epoch), EHistoricStateNotFound);
        state.historic_states.get(epoch)
    }

    /// If a user with enough stake generates maker volume, then they will
    /// need this epoch state to calculate their rebates in the future.
    public(package) fun increment_users_with_rebates(
        state: &mut PoolState,
    ) {
        state.current_state.users_with_rebates = state.current_state.users_with_rebates + 1;
    }

    /// If a user has used this historic state to calculate their rebates,
    /// then they no longer need it.
    public(package) fun decrement_users_with_rebates(
        state: &mut PoolState,
        epoch: &u64,
    ) {
        assert!(state.historic_states.contains(epoch), EHistoricStateNotFound);
        let historic_state = state.historic_states.get_mut(epoch);
        historic_state.users_with_rebates = historic_state.users_with_rebates - 1;
        if (historic_state.users_with_rebates == 0) {
            state.historic_states.remove(epoch);
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
