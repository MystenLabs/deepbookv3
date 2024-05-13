module deepbook::history {
    use sui::table::{Self, Table};

    const EHistoricVolumesNotFound: u64 = 1;

    /// Overall volume for the current epoch. Used to calculate rebates and burns.
    public struct Volumes has store, copy, drop {
        total_volume: u64,
        total_staked_volume: u64,
        total_fees_collected: u64,
        stake_required: u64,
        users_with_rebates: u64,
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
            users_with_rebates: 0,
        };
        History {
            epoch: ctx.epoch(),
            volumes,
            historic_volumes: table::new(ctx),
            balance_to_burn: 0,
        }
    }

    public(package) fun update(
        self: &mut History,
        ctx: &TxContext,
    ) {
        let epoch = ctx.epoch();
        if (self.epoch == epoch) return;
        if (self.volumes.users_with_rebates > 0) {
            self.historic_volumes.add(self.epoch, self.volumes);
        };
        self.epoch = epoch;
    }

    /// Given the epoch's volume data and the user's volume data,
    /// calculate the rebate and burn amounts.
    public(package) fun calculate_rebate_amount(
        self: &mut History,
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
        self: &mut History,
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
}