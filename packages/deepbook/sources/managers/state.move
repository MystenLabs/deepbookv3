module deepbook::v3state {
    use sui::{
        table::{Self, Table},
        vec_set::{Self, VecSet},
    };

    /// Parameters that can be updated by governance.
    public struct TradeParams has store, copy, drop {
        taker_fee: u64,
        maker_fee: u64,
        stake_required: u64,
    }

    /// Overall volume for the current epoch. Used to calculate rebates and burns.
    public struct Volumes has store, copy, drop {
        total_volume: u64,
        total_staked_volume: u64,
        total_fees_collected: u64,
        users_with_rebates: u64,
    }

    public struct State has store {
        epoch: u64,
        trade_params: TradeParams,
        next_trade_params: TradeParams,
        volumes: Volumes,
        historic_volumes: Table<u64, Volumes>,
        balance_to_burn: u64,
    }

    public(package) fun new_trade_params(
        taker_fee: u64,
        maker_fee: u64,
        stake_required: u64,
    ): TradeParams {
        TradeParams {
            taker_fee,
            maker_fee,
            stake_required,
        }
    }

    public(package) fun empty(
        taker_fee: u64,
        maker_fee: u64,
        stake_required: u64,
        ctx: &mut TxContext,
    ): State {
        let trade_params = new_trade_params(taker_fee, maker_fee, stake_required);
        let next_trade_params = new_trade_params(taker_fee, maker_fee, stake_required);
        let volumes = Volumes {
            total_volume: 0,
            total_staked_volume: 0,
            total_fees_collected: 0,
            users_with_rebates: 0,
        };
        State {
            epoch: ctx.epoch(),
            trade_params,
            next_trade_params,
            volumes,
            historic_volumes: table::new(ctx),
            balance_to_burn: 0,
        }
    }
}