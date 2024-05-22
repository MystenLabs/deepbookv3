module deepbook::history {
    use sui::table::{Self, Table};
    use deepbook::math;

    /// Constants
    const EPOCHS_FOR_PHASE_OUT: u64 = 28;
    const FLOAT_SCALING: u64 = 1_000_000_000;
    const MAX_U64: u64 = ((1u128) << 64 - 1) as u64;
    const DEEP_LOT_SIZE: u64 = 1_000; // TODO: update, currently 0.000001

    /// Error codes
    const EHistoricVolumesNotFound: u64 = 0;

    /// Overall volume for the current epoch. Used to calculate rebates and burns.
    public struct Volumes has store, copy, drop {
        total_volume: u64,
        total_staked_volume: u64,
        total_fees_collected: u64,
        stake_required: u64,
        accounts_with_rebates: u64,
        historic_median: u64,
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
            stake_required: 0,
            accounts_with_rebates: 0,
            historic_median: MAX_U64,
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
    ) {
        let epoch = ctx.epoch();
        if (self.epoch == epoch) return;
        if (self.volumes.accounts_with_rebates > 0) {
            self.historic_volumes.add(self.epoch, self.volumes);
        };
        self.epoch = epoch;
        self.reset_volumes();
        self.update_historic_median();
    }

    public(package) fun reset_volumes(
        self: &mut History,
    ) {
        self.volumes = Volumes {
            total_volume: 0,
            total_staked_volume: 0,
            total_fees_collected: 0,
            stake_required: 0,
            accounts_with_rebates: 0,
            historic_median: MAX_U64,
        };
    }

    /// Given the epoch's volume data and the account's volume data,
    /// calculate and returns rebate amount and burn amount
    public(package) fun calculate_rebate_amount(
        self: &mut History,
        prev_epoch: u64,
        maker_volume: u64,
        account_stake: u64,
    ): u64 {
        assert!(self.historic_volumes.contains(prev_epoch), EHistoricVolumesNotFound);
        let volumes = &mut self.historic_volumes[prev_epoch];
        if (account_stake < volumes.stake_required) return 0;

        let other_maker_liquidity = volumes.total_volume - maker_volume;
        let maker_rebate_percentage = FLOAT_SCALING - math::min(FLOAT_SCALING, math::div(other_maker_liquidity, volumes.historic_median));
        let maker_volume_proportion = math::div(maker_volume, volumes.total_staked_volume);
        let maker_fee_proportion = math::mul(maker_volume_proportion, volumes.total_fees_collected);
        let mut maker_rebate = math::mul(maker_rebate_percentage, maker_fee_proportion);
        maker_rebate = maker_rebate - maker_rebate % DEEP_LOT_SIZE;
        let maker_burn = maker_fee_proportion - maker_rebate;

        self.balance_to_burn = self.balance_to_burn + maker_burn;
        volumes.accounts_with_rebates = volumes.accounts_with_rebates - 1;

        maker_rebate
    }

    /// Updates the historic_median for past 28 epochs
    public(package) fun update_historic_median(
        self: &mut History,
    ) {
        let mut median_vec = vector<u64>[];
        let mut i = if (self.epoch > EPOCHS_FOR_PHASE_OUT) {
            self.epoch - EPOCHS_FOR_PHASE_OUT
        } else {
            0
        };
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
        first_volume_by_account: bool,
    ) {
        if (maker_volume == 0) return;

        self.volumes.total_volume = self.volumes.total_volume + maker_volume;
        if (account_stake > self.volumes.stake_required) {
            self.volumes.total_staked_volume = self.volumes.total_staked_volume + maker_volume;
            if (first_volume_by_account) {
                self.volumes.accounts_with_rebates = self.volumes.accounts_with_rebates + 1;
            }
        };
    }

    public(package) fun balance_to_burn(
        self: &History,
    ): u64 {
        self.balance_to_burn
    }

    public(package) fun reset_balance_to_burn(
        self: &mut History,
    ) {
        self.balance_to_burn = 0
    }

    #[test_only]
    public fun set_current_volumes(
        history: &mut History,
        total_volume: u64,
        total_staked_volume: u64,
        total_fees_collected: u64,
        stake_required: u64,
        accounts_with_rebates: u64,
    ) {
        let volumes = &mut history.volumes;
        volumes.total_volume = total_volume;
        volumes.total_staked_volume = total_staked_volume;
        volumes.total_fees_collected = total_fees_collected;
        volumes.stake_required = stake_required;
        volumes.accounts_with_rebates = accounts_with_rebates;
    }
}
