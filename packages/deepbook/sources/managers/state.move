module deepbook::v3state {
    use sui::{
        table::{Self, Table},

    };

    use deepbook::{
        v3governance::Proposal,
    };

    const EHistoricVolumesNotFound: u64 = 1;

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
        stake_required: u64,
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

    public(package) fun trade_params(
        self: &State,
    ): (u64, u64, u64) {
        (self.trade_params.taker_fee, self.trade_params.maker_fee, self.trade_params.stake_required)
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
            stake_required: 0,
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

    public(package) fun update(
        self: &mut State,
        ctx: &TxContext,
    ) {
        let epoch = ctx.epoch();
        if (self.epoch == epoch) return;
        if (self.volumes.users_with_rebates > 0) {
            self.historic_volumes.add(self.epoch, self.volumes);
        };
        self.trade_params = self.next_trade_params;
        self.epoch = epoch;
    }

    /// Given the epoch's volume data and the user's volume data,
    /// calculate the rebate and burn amounts.
    public(package) fun calculate_rebate_amount(
        self: &mut State,
        epoch: u64,
        _maker_volume: u64,
        user_stake: u64,
    ): u64 {
        assert!(self.historic_volumes.contains(epoch), EHistoricVolumesNotFound);
        let volumes = &mut self.historic_volumes[epoch];
        if (volumes.stake_required > user_stake) return 0;

        // TODO: calculate and add to burn balance

        volumes.users_with_rebates = volumes.users_with_rebates - 1;
        if (volumes.users_with_rebates == 0) {
            self.historic_volumes.remove(epoch);
        };

        0
    }

    public(package) fun add_volume(
        self: &mut State,
        maker_volume: u64,
        user_stake: u64,
        first_volume_by_user: bool,
    ) {
        self.volumes.total_volume = self.volumes.total_volume + maker_volume;
        if (user_stake > self.volumes.stake_required) {
            self.volumes.total_staked_volume = self.volumes.total_staked_volume + maker_volume;
            if (first_volume_by_user) {
                self.volumes.users_with_rebates = self.volumes.users_with_rebates + 1;
            }
        };
    }

    /// Set the fee parameters for the next epoch. Pushed by governance.
    public(package) fun set_next_trade_params(
        self: &mut State,
        proposal: Option<Proposal>,
    ) {
        if (proposal.is_none()) return;
        let (taker, maker, stake) = proposal.borrow().params();
        self.next_trade_params = new_trade_params(taker, maker, stake);
    }
}