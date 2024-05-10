module deepbook::history {
    use sui::{
        table::{Self, Table},
        vec_set::{Self, VecSet},
    };

    const EHistoricVolumeNotFound: u64 = 1;

    /// Overall volumes for the current epoch. Used to calculate rebates and burns.
    public struct Volume has store, copy, drop {
        total_volume: u64,
        total_staked_volume: u64,
        total_fees_collected: u64,
        users_with_rebates: u64,
    }

    public struct History has store {
        volumes: Table<u64, Volume>
    }

    public(package) fun volumes(self: &History, epoch: u64): &Volume {
        assert!(self.volumes.contains(epoch), EHistoricVolumeNotFound);

        &self.volumes[epoch]
    }

    public(package) fun add_to_history(self: &mut History, epoch: u64, volume: Volume) {
        self.volumes.add(epoch, volume);
    }

    fun decrement_users_with_rebates(self: &mut History, epoch: u64) {
        assert!(self.volumes.contains(epoch), EHistoricVolumeNotFound);
        let volumes = &mut self.volumes[epoch];
        volumes.users_with_rebates = volumes.users_with_rebates - 1;
        if (volumes.users_with_rebates == 0) {
            self.volumes.remove(epoch);
        }
    }
}