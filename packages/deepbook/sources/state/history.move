module deepbook::history {
    use sui::table::{Self, Table};

    use deepbook::{
        account_data::AccountData,
        trade_params::{Self, TradeParams},
    };

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
    ): History {
        let volumes = Volumes {
            total_volume: 0,
            total_staked_volume: 0,
            total_fees_collected: 0,
            trade_params: trade_params::new(0, 0, 0),
        };
        History {
            epoch: ctx.epoch(),
            volumes,
            historic_volumes: table::new(ctx),
            balance_to_burn: 0,
        }
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
        account_data: &AccountData,
    ) {
        let volumes = &mut self.volumes;
        volumes.total_volume = volumes.total_volume + maker_volume;
        if (account_data.active_stake() > volumes.trade_params.stake_required()) {
            volumes.total_fees_collected = volumes.total_fees_collected + maker_volume;
        }
    }

    public(package) fun historic_maker_fee(
        self: &History,
        epoch: u64,
    ): u64 {
        self.historic_volumes[epoch].trade_params().maker_fee()
    }

    #[test_only]
    public fun volumes(self: &History): &Volumes {
        &self.volumes
    }

    #[test_only]
    public fun historic_volumes(self: &History): &Table<u64, Volumes> {
        &self.historic_volumes
    }

    #[test_only]
    public fun balance_to_burn(self: &History): u64 {
        self.balance_to_burn
    }

    #[test_only]
    public fun total_volume(volumes: &Volumes): u64 {
        volumes.total_volume
    }

    #[test_only]
    public fun total_staked_volume(volumes: &Volumes): u64 {
        volumes.total_staked_volume
    }

    #[test_only]
    public fun total_fees_collected(volumes: &Volumes): u64 {
        volumes.total_fees_collected
    }

    #[test_only]
    public fun trade_params(volumes: &Volumes): TradeParams {
        volumes.trade_params
    }
}
