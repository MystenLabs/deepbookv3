// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// History module tracks the volume data for the current epoch and past epochs.
/// It also tracks past trade params. Past maker fees are used to calculate
/// fills for old orders. The historic median is used to calculate rebates and
/// burns.
module deepbook::history;

use deepbook::{balances::{Self, Balances}, constants, math, trade_params::TradeParams};
use sui::{event, table::{Self, Table}};

// === Errors ===
const EHistoricVolumesNotFound: u64 = 0;

// === Structs ===
/// `Volumes` represents volume data for a single epoch.
/// Using flashloans on a whitelisted pool, assuming 1_000_000 * 1_000_000_000
/// in volume per trade, at 1 trade per millisecond, the total volume can reach
/// 1_000_000 * 1_000_000_000 * 1000 * 60 * 60 * 24 * 365 = 8.64e22 in one
/// epoch.
public struct Volumes has copy, drop, store {
    total_volume: u128,
    total_staked_volume: u128,
    total_fees_collected: Balances,
    historic_median: u128,
    trade_params: TradeParams,
}

/// `History` represents the volume data for the current epoch and past epochs.
public struct History has store {
    epoch: u64,
    epoch_created: u64,
    volumes: Volumes,
    historic_volumes: Table<u64, Volumes>,
    balance_to_burn: u64,
}

public struct EpochData has copy, drop, store {
    epoch: u64,
    pool_id: ID,
    total_volume: u128,
    total_staked_volume: u128,
    base_fees_collected: u64,
    quote_fees_collected: u64,
    deep_fees_collected: u64,
    historic_median: u128,
    taker_fee: u64,
    maker_fee: u64,
    stake_required: u64,
}

// === Public-Package Functions ===
/// Create a new `History` instance. Called once upon pool creation. A single
/// blank `Volumes` instance is created and added to the historic_volumes table.
public(package) fun empty(
    trade_params: TradeParams,
    epoch_created: u64,
    ctx: &mut TxContext,
): History {
    let volumes = Volumes {
        total_volume: 0,
        total_staked_volume: 0,
        total_fees_collected: balances::empty(),
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

/// Update the epoch if it has changed. If there are accounts with rebates,
/// add the current epoch's volume data to the historic volumes.
public(package) fun update(
    self: &mut History,
    trade_params: TradeParams,
    pool_id: ID,
    ctx: &TxContext,
) {
    let epoch = ctx.epoch();
    if (self.epoch == epoch) return;
    if (self.historic_volumes.contains(self.epoch)) {
        self.historic_volumes.remove(self.epoch);
    };
    self.update_historic_median();
    self.historic_volumes.add(self.epoch, self.volumes);

    event::emit(EpochData {
        epoch: self.epoch,
        pool_id,
        total_volume: self.volumes.total_volume,
        total_staked_volume: self.volumes.total_staked_volume,
        base_fees_collected: self.volumes.total_fees_collected.base(),
        quote_fees_collected: self.volumes.total_fees_collected.quote(),
        deep_fees_collected: self.volumes.total_fees_collected.deep(),
        historic_median: self.volumes.historic_median,
        taker_fee: trade_params.taker_fee(),
        maker_fee: trade_params.maker_fee(),
        stake_required: trade_params.stake_required(),
    });

    self.epoch = epoch;
    self.reset_volumes(trade_params);
    self.historic_volumes.add(self.epoch, self.volumes);
}

/// Reset the current epoch's volume data.
public(package) fun reset_volumes(self: &mut History, trade_params: TradeParams) {
    event::emit(self.volumes);
    self.volumes =
        Volumes {
            total_volume: 0,
            total_staked_volume: 0,
            total_fees_collected: balances::empty(),
            historic_median: 0,
            trade_params,
        };
}

/// Given the epoch's volume data and the account's volume data,
/// calculate and returns rebate amount, updates the burn amount.
public(package) fun calculate_rebate_amount(
    self: &mut History,
    prev_epoch: u64,
    maker_volume: u128,
    account_stake: u64,
): Balances {
    assert!(self.historic_volumes.contains(prev_epoch), EHistoricVolumesNotFound);
    let volumes = &mut self.historic_volumes[prev_epoch];
    if (volumes.trade_params.stake_required() > account_stake) {
        return balances::empty()
    };

    let maker_volume = maker_volume as u128;
    let other_maker_liquidity = volumes.total_volume - maker_volume;
    let maker_rebate_percentage = if (volumes.historic_median > 0) {
        constants::float_scaling_u128() - constants::float_scaling_u128().min(
            math::div_u128(other_maker_liquidity, volumes.historic_median),
        )
    } else {
        0
    };
    let maker_rebate_percentage = maker_rebate_percentage as u64;
    let maker_volume_proportion = if (volumes.total_staked_volume > 0) {
        (math::div_u128(maker_volume, volumes.total_staked_volume)) as u64
    } else {
        0
    };
    let mut max_rebates = volumes.total_fees_collected;
    max_rebates.mul(maker_volume_proportion); // Maximum rebates possible
    let mut rebates = max_rebates;
    rebates.mul(maker_rebate_percentage); // Actual rebates

    let maker_burn = max_rebates.deep() - rebates.deep();

    self.balance_to_burn = self.balance_to_burn + maker_burn;

    rebates
}

/// Updates the historic_median for past 28 epochs.
public(package) fun update_historic_median(self: &mut History) {
    let epochs_since_creation = self.epoch - self.epoch_created;
    if (epochs_since_creation < constants::phase_out_epochs()) {
        self.volumes.historic_median = constants::max_u128();
        return
    };
    let mut median_vec = vector<u128>[];
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
public(package) fun add_volume(self: &mut History, maker_volume: u64, account_stake: u64) {
    if (maker_volume == 0) return;

    let maker_volume = maker_volume as u128;
    self.volumes.total_volume = self.volumes.total_volume + maker_volume;
    if (account_stake >= self.volumes.trade_params.stake_required()) {
        self.volumes.total_staked_volume = self.volumes.total_staked_volume + maker_volume;
    };
}

public(package) fun balance_to_burn(self: &History): u64 {
    self.balance_to_burn
}

public(package) fun reset_balance_to_burn(self: &mut History): u64 {
    let balance_to_burn = self.balance_to_burn;
    self.balance_to_burn = 0;

    balance_to_burn
}

public(package) fun historic_maker_fee(self: &History, epoch: u64): u64 {
    assert!(self.historic_volumes.contains(epoch), EHistoricVolumesNotFound);

    self.historic_volumes[epoch].trade_params.maker_fee()
}

public(package) fun add_total_fees_collected(self: &mut History, fees: Balances) {
    self.volumes.total_fees_collected.add_balances(fees);
}

// === Test Functions ===
#[test_only]
public fun set_current_volumes(
    history: &mut History,
    total_volume: u64,
    total_staked_volume: u64,
    total_fees_collected: Balances,
) {
    let total_volume = total_volume as u128;
    let total_staked_volume = total_staked_volume as u128;

    let volumes = &mut history.volumes;
    volumes.total_volume = total_volume;
    volumes.total_staked_volume = total_staked_volume;
    volumes.total_fees_collected = total_fees_collected;
}
