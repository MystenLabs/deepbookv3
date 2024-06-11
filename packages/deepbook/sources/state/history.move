module deepbook::history {
    use sui::table::{Self, Table};
    use deepbook::{
        math,
        constants,
    };
    use deepbook::trade_params::TradeParams;

    /// Error codes
    const EHistoricVolumesNotFound: u64 = 0;

    /// Overall volume for the current epoch. Used to calculate rebates and burns.
    public struct Volumes has store, copy, drop {
        total_volume: u64,
        total_staked_volume: u64,
        total_fees_collected: u64,
        historic_median: u64,
        trade_params: TradeParams,
    }

    public struct History has store {
        epoch: u64,
        epoch_created: u64,
        volumes: Volumes,
        historic_volumes: Table<u64, Volumes>,
        balance_to_burn: u64,
    }

    public(package) fun empty(
        trade_params: TradeParams,
        epoch_created: u64,
        ctx: &mut TxContext,
    ): History {
        let volumes = Volumes {
            total_volume: 0,
            total_staked_volume: 0,
            total_fees_collected: 0,
            historic_median: 0,
            trade_params,
        };
        let mut history = History {
            epoch: ctx.epoch(),
            epoch_created,
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
        trade_params: TradeParams,
        ctx: &TxContext,
    ) {
        let epoch = ctx.epoch();
        if (self.epoch == epoch) return;
        if (self.historic_volumes.contains(self.epoch)) {
            self.historic_volumes.remove(self.epoch);
        };
        self.update_historic_median();
        self.historic_volumes.add(self.epoch, self.volumes);

        self.epoch = epoch;
        self.reset_volumes(trade_params);
        self.historic_volumes.add(self.epoch, self.volumes);
    }

    public(package) fun reset_volumes(
        self: &mut History,
        trade_params: TradeParams,
    ) {
        self.volumes = Volumes {
            total_volume: 0,
            total_staked_volume: 0,
            total_fees_collected: 0,
            historic_median: 0,
            trade_params,
        };
    }

    /// Given the epoch's volume data and the account's volume data,
    /// calculate and returns rebate amount, updates the burn amount
    public(package) fun calculate_rebate_amount(
        self: &mut History,
        prev_epoch: u64,
        maker_volume: u64,
        account_stake: u64,
    ): u64 {
        assert!(self.historic_volumes.contains(prev_epoch), EHistoricVolumesNotFound);
        let volumes = &mut self.historic_volumes[prev_epoch];
        if (volumes.trade_params.stake_required() > account_stake) return 0;

        let other_maker_liquidity = volumes.total_volume - maker_volume;
        let maker_rebate_percentage = if (volumes.historic_median > 0) {
            constants::float_scaling() - math::min(constants::float_scaling(), math::div(other_maker_liquidity, volumes.historic_median))
        } else {
            0
        };
        let maker_volume_proportion = if (volumes.total_staked_volume > 0) {
            math::div(maker_volume, volumes.total_staked_volume)
        } else {
            0
        };
        let maker_fee_proportion = math::mul(maker_volume_proportion, volumes.total_fees_collected);
        let maker_rebate = math::mul(maker_rebate_percentage, maker_fee_proportion);
        let maker_burn = maker_fee_proportion - maker_rebate;

        self.balance_to_burn = self.balance_to_burn + maker_burn;

        maker_rebate
    }

    /// Updates the historic_median for past 28 epochs
    public(package) fun update_historic_median(
        self: &mut History,
    ) {
        let epochs_since_creation = self.epoch - self.epoch_created;
        if (epochs_since_creation < constants::phase_out_epochs()) {
            self.volumes.historic_median = constants::max_u64();
            return
        };
        let mut median_vec = vector<u64>[];
        let mut i = self.epoch - constants::phase_out_epochs();
        while (i < self.epoch) {
            if (self.historic_volumes.contains(i)) {
                median_vec.push_back(self.historic_volumes[i].total_volume);
            } else {
                median_vec.push_back(0);
            };
            i = i + 1;
        };

        self.volumes.historic_median = math::median(median_vec);
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
        if (account_stake >= self.volumes.trade_params.stake_required()) {
            self.volumes.total_staked_volume = self.volumes.total_staked_volume + maker_volume;
        };
    }

    public(package) fun balance_to_burn(
        self: &History,
    ): u64 {
        self.balance_to_burn
    }

    public(package) fun reset_balance_to_burn(
        self: &mut History,
    ): u64 {
        let balance_to_burn = self.balance_to_burn;
        self.balance_to_burn = 0;

        balance_to_burn
    }

    public(package) fun historic_maker_fee(
        self: &History,
        epoch: u64,
    ): u64 {
        assert!(self.historic_volumes.contains(epoch), EHistoricVolumesNotFound);

        self.historic_volumes[epoch].trade_params.maker_fee()
    }

    public(package) fun historic_taker_fee(
        self: &History,
        epoch: u64,
    ): u64 {
        assert!(self.historic_volumes.contains(epoch), EHistoricVolumesNotFound);

        self.historic_volumes[epoch].trade_params.maker_fee()
    }

    public(package) fun add_total_fees_collected(
        self: &mut History,
        fees: u64,
    ) {
        self.volumes.total_fees_collected = self.volumes.total_fees_collected + fees;
    }

    #[test_only]
    public fun set_current_volumes(
        history: &mut History,
        total_volume: u64,
        total_staked_volume: u64,
        total_fees_collected: u64,
    ) {
        let volumes = &mut history.volumes;
        volumes.total_volume = total_volume;
        volumes.total_staked_volume = total_staked_volume;
        volumes.total_fees_collected = total_fees_collected;
    }
}
