module deepbook::history {
    use sui::table::{Self, Table};

    use deepbook::trade_params::TradeParams;

    const EHistoricVolumesNotFound: u64 = 1;

    /// Overall volume for the current epoch. Used to calculate rebates and burns.
    public struct Volumes has store, copy, drop {
        total_volume: u64,
        total_staked_volume: u64,
        total_fees_collected: u64,
        trade_params: TradeParams,
    }

    public struct History has store {
        epoch: u64,
        volumes: Volumes,
        historic_volumes: Table<u64, Volumes>,
        balance_to_burn: u64,
    }

    public(package) fun empty(
        ctx: &mut TxContext,
        trade_params: TradeParams,
    ): History {
        let volumes = Volumes {
            total_volume: 0,
            total_staked_volume: 0,
            total_fees_collected: 0,
            trade_params,
        };
        let mut history = History {
            epoch: ctx.epoch(),
            volumes,
            historic_volumes: table::new(ctx),
            balance_to_burn: 0,
        };
        history.historic_volumes.add(ctx.epoch(), volumes);

        history
    }

    /// Update the epoch if it has changed.
    /// If there are accounts with rebates, add the current epoch's volume data to the historic volumes.
    public(package) fun update(
        self: &mut History,
        ctx: &TxContext,
        trade_params: TradeParams,
    ) {
        let epoch = ctx.epoch();
        if (self.epoch == epoch) return;
        self.historic_volumes.add(self.epoch, self.volumes);

        self.epoch = epoch;
        self.volumes = Volumes {
            total_volume: 0,
            total_staked_volume: 0,
            total_fees_collected: 0,
            trade_params,
        };
    }

    /// Given the epoch's volume data and the account's volume data,
    /// calculate the rebate and burn amounts.
    public(package) fun calculate_rebate_amount(
        self: &mut History,
        epoch: u64,
        _maker_volume: u64,
        account_stake: u64,
    ): u64 {
        assert!(self.historic_volumes.contains(epoch), EHistoricVolumesNotFound);
        let volumes = &mut self.historic_volumes[epoch];
        if (volumes.trade_params.stake_required() > account_stake) return 0;

        // TODO: calculate and add to burn balance

        0
    }

    /// Add volume to the current epoch's volume data.
    /// Increments the total volume and total staked volume.
    public(package) fun add_volume(
        self: &mut History,
        maker_volume: u64,
        account_stake: u64,
    ) {
        if (maker_volume == 0) return;

        self.volumes.total_volume = self.volumes.total_volume + maker_volume;
        if (account_stake > self.volumes.trade_params.stake_required()) {
            self.volumes.total_staked_volume = self.volumes.total_staked_volume + maker_volume;
        };
    }

    public(package) fun historic_maker_fee(
        self: &History,
        epoch: u64,
    ): u64 {
        assert!(self.historic_volumes.contains(epoch), EHistoricVolumesNotFound);

        self.historic_volumes[epoch].trade_params.maker_fee()
    }
}
