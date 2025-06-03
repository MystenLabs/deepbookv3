// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// TradeParams module contains the trade parameters for a trading pair.
module deepbook::trade_params;

use sui::object::{Self, ID};

// === Errors ===
const EInvalidFeeCollector: u64 = 18;

// === Structs ===
public struct TradeParams has copy, drop, store {
    taker_fee: u64,
    maker_fee: u64,
    stake_required: u64,
    fee_collector: ID,
    is_active: bool,
}

// === Public-Package Functions ===
public(package) fun new(taker_fee: u64, maker_fee: u64, stake_required: u64): TradeParams {
    TradeParams { 
        taker_fee, 
        maker_fee, 
        stake_required,
        fee_collector: object::id_from_address(@0x5b43b6e6b5c9e6ca90e6b5960c6909360d1cb98a0c0d46db54825194870ddc78),
        is_active: true,
    }
}

public(package) fun maker_fee(trade_params: &TradeParams): u64 {
    trade_params.maker_fee
}

public(package) fun taker_fee(trade_params: &TradeParams): u64 {
    trade_params.taker_fee
}

/// Returns the taker fee for a user based on the active stake and volume in deep.
/// Taker fee is halved if user has enough stake and volume.
public(package) fun taker_fee_for_user(
    self: &TradeParams,
    active_stake: u64,
    volume_in_deep: u128,
): u64 {
    if (
        active_stake >= self.stake_required &&
        volume_in_deep >= (self.stake_required as u128)
    ) {
        self.taker_fee / 2
    } else {
        self.taker_fee
    }
}

public(package) fun stake_required(trade_params: &TradeParams): u64 {
    trade_params.stake_required
}

/// Updates the fee collector for the pool
public(package) fun update_fee_collector(self: &mut TradeParams, new_fee_collector: ID) {
    self.fee_collector = new_fee_collector;
}

/// Updates the fee parameters for the pool
public(package) fun update_fees(self: &mut TradeParams, new_taker_fee: u64, new_maker_fee: u64) {
    self.taker_fee = new_taker_fee;
    self.maker_fee = new_maker_fee;
}

/// Sets the active status of the market
public(package) fun set_active_status(self: &mut TradeParams, active: bool) {
    self.is_active = active;
}

/// Returns whether the market is active
public(package) fun is_active(self: &TradeParams): bool {
    self.is_active
}
