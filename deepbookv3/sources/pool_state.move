module deepbook::pool_state {
    public struct PoolEpochState has copy, store, drop {
        total_maker_volume: u64,
        total_staked_maker_volume: u64,
        total_fees_collected: u64,
        stake_required: u64,
        taker_fee: u64,
        maker_fee: u64,
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

    public(package) fun new_pool_epoch_state_with_gov_params(
        stake_required: u64,
        taker_fee: u64,
        maker_fee: u64,
    ): PoolEpochState {
        new_pool_epoch_state(0, 0, 0, stake_required, taker_fee, maker_fee)
    }

    public struct PoolState has copy, store {
        epoch: u64,
        historic_states: vector<PoolEpochState>,
        current_state: PoolEpochState,
        next_state: PoolEpochState,
    }

    public(package) fun new_pool_state(
        ctx: &TxContext,
        stake_required: u64,
        taker_fee: u64,
        maker_fee: u64,
    ): PoolState {
        PoolState {
            epoch: ctx.epoch(),
            historic_states: vector::empty(),
            current_state: new_pool_epoch_state_with_gov_params(stake_required, taker_fee, maker_fee),
            next_state: new_pool_epoch_state_with_gov_params(stake_required, taker_fee, maker_fee),
        }
    }

    public(package) fun refresh_state(
        state: &mut PoolState,
        ctx: &TxContext,
    ) {
        let current_epoch = ctx.epoch();
        if (state.epoch == current_epoch) return;

        state.epoch = current_epoch;
        state.historic_states.push_back(state.current_state);
        state.current_state = state.next_state;
    }

    public(package) fun set_next_epoch_pool_state(
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

    public(package) fun get_maker_fee(state: &PoolState): u64 {
        state.current_state.maker_fee
    }

    public(package) fun get_taker_fee(state: &PoolState): u64 {
        state.current_state.taker_fee
    }

    public(package) fun get_stake_required(state: &PoolState): u64 {
        state.current_state.stake_required
    }
}