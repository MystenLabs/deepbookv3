// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Margin state manages the total supply and borrow of the margin pool.
/// Whenever supply and borrow increases or decreases,
/// the interest and protocol fees are updated.
/// Shares represent the constant amount and are used to calculate
/// amounts after interest and protocol fees are applied.
module deepbook_margin::margin_state;

use deepbook::{constants, math};
use deepbook_margin::protocol_config::ProtocolConfig;
use std::string::String;
use sui::{clock::Clock, vec_map::{Self, VecMap}};

public struct State has drop, store {
    total_supply: u64,
    total_borrow: u64,
    supply_shares: u64,
    borrow_shares: u64,
    last_update_timestamp: u64,
    extra_fields: VecMap<String, u64>,
}

// === Public-Package Functions ===
/// Initialize the margin state with the default values.
public(package) fun default(clock: &Clock): State {
    State {
        total_supply: 0,
        total_borrow: 0,
        supply_shares: 0,
        borrow_shares: 0,
        last_update_timestamp: clock.timestamp_ms(),
        extra_fields: vec_map::empty(),
    }
}

/// Increase the supply given an amount. Return the corresponding shares
/// and protocol fees accrued since last update.
public(package) fun increase_supply(
    self: &mut State,
    config: &ProtocolConfig,
    amount: u64,
    clock: &Clock,
): (u64, u64) {
    let protocol_fees = self.update(config, clock);
    let ratio = self.supply_ratio();
    let shares = math::div(amount, ratio);
    self.supply_shares = self.supply_shares + shares;
    self.total_supply = self.total_supply + amount;

    (shares, protocol_fees)
}

/// Decrease the supply given some shares. Return the corresponding amount
/// and protocol fees accrued since last update.
public(package) fun decrease_supply_shares(
    self: &mut State,
    config: &ProtocolConfig,
    shares: u64,
    clock: &Clock,
): (u64, u64) {
    let protocol_fees = self.update(config, clock);
    let ratio = self.supply_ratio();
    let amount = math::mul(shares, ratio);
    self.supply_shares = self.supply_shares - shares;
    self.total_supply = self.total_supply - amount;

    (amount, protocol_fees)
}

/// Increase the supply given an absolute amount. Used when the supply needs to be
/// increased without increasing shares.
public(package) fun increase_supply_absolute(self: &mut State, amount: u64) {
    self.total_supply = self.total_supply + amount;
}

/// Decrease the supply given an absolute amount. Used when the supply needs to be
/// decreased without decreasing shares.
public(package) fun decrease_supply_absolute(self: &mut State, amount: u64) {
    self.total_supply = self.total_supply - amount;
}

/// Increase the borrow given an amount. Return the individual borrow shares
/// and protocol fees accrued since last update.
public(package) fun increase_borrow(
    self: &mut State,
    config: &ProtocolConfig,
    amount: u64,
    clock: &Clock,
): (u64, u64) {
    let protocol_fees = self.update(config, clock);
    let ratio = self.borrow_ratio();
    let shares = math::div_round_up(amount, ratio);
    self.borrow_shares = self.borrow_shares + shares;
    self.total_borrow = self.total_borrow + amount;

    (shares, protocol_fees)
}

/// Decrease the borrow given some shares. Return the corresponding amount
/// and protocol fees accrued since last update.
public(package) fun decrease_borrow_shares(
    self: &mut State,
    config: &ProtocolConfig,
    shares: u64,
    clock: &Clock,
): (u64, u64) {
    let protocol_fees = self.update(config, clock);
    let ratio = self.borrow_ratio();
    let amount = math::mul(shares, ratio);
    self.borrow_shares = self.borrow_shares - shares;
    self.total_borrow = self.total_borrow - amount;

    (amount, protocol_fees)
}

/// Update the supply and borrow with the interest and protocol fees.
/// Returns the protocol fees accrued since last update.
public(package) fun update(self: &mut State, config: &ProtocolConfig, clock: &Clock): u64 {
    let now = clock.timestamp_ms();
    let elapsed = now - self.last_update_timestamp;

    let interest = config.calculate_interest_with_borrow(
        self.utilization_rate(),
        elapsed,
        self.total_borrow,
    );
    let protocol_fees = math::mul(interest, config.protocol_spread());
    self.total_supply = self.total_supply + interest - protocol_fees;
    self.total_borrow = self.total_borrow + interest;
    self.last_update_timestamp = now;

    protocol_fees
}

/// Return the utilization rate of the margin pool.
public(package) fun utilization_rate(self: &State): u64 {
    if (self.total_supply == 0) {
        0
    } else {
        math::div(self.total_borrow, self.total_supply)
    }
}

/// Convert the supply shares to the corresponding amount.
public(package) fun supply_shares_to_amount(
    self: &State,
    shares: u64,
    config: &ProtocolConfig,
    clock: &Clock,
): u64 {
    let now = clock.timestamp_ms();
    let elapsed = now - self.last_update_timestamp;

    let interest = config.calculate_interest_with_borrow(
        self.utilization_rate(),
        elapsed,
        self.total_borrow,
    );
    let protocol_fees = math::mul(interest, config.protocol_spread());
    let supply = self.total_supply + interest - protocol_fees;
    let ratio = if (self.supply_shares == 0) {
        constants::float_scaling()
    } else {
        math::div(supply, self.supply_shares)
    };

    math::mul(shares, ratio)
}

/// Convert the borrow shares to the corresponding amount.
public(package) fun borrow_shares_to_amount(
    self: &State,
    shares: u64,
    config: &ProtocolConfig,
    clock: &Clock,
): u64 {
    let now = clock.timestamp_ms();
    let elapsed = now - self.last_update_timestamp;

    let interest = config.calculate_interest_with_borrow(
        self.utilization_rate(),
        elapsed,
        self.total_borrow,
    );
    let borrow = self.total_borrow + interest;
    let ratio = if (self.borrow_shares == 0) {
        constants::float_scaling()
    } else {
        math::div(borrow, self.borrow_shares)
    };

    math::mul_round_up(shares, ratio)
}

/// Return the supply ratio of the margin pool.
public(package) fun supply_ratio(self: &State): u64 {
    if (self.supply_shares == 0) {
        constants::float_scaling()
    } else {
        math::div(self.total_supply, self.supply_shares)
    }
}

/// Return the borrow ratio of the margin pool.
public(package) fun borrow_ratio(self: &State): u64 {
    if (self.borrow_shares == 0) {
        constants::float_scaling()
    } else {
        math::div(self.total_borrow, self.borrow_shares)
    }
}

/// Return the total supply of the margin pool.
public(package) fun total_supply(self: &State): u64 {
    self.total_supply
}

/// Return the total supply including accrued interest without updating state.
public(package) fun total_supply_with_interest(
    self: &State,
    config: &ProtocolConfig,
    clock: &Clock,
): u64 {
    let now = clock.timestamp_ms();
    let elapsed = now - self.last_update_timestamp;

    let interest = config.calculate_interest_with_borrow(
        self.utilization_rate(),
        elapsed,
        self.total_borrow,
    );
    let protocol_fees = math::mul(interest, config.protocol_spread());

    self.total_supply + interest - protocol_fees
}

/// Return the total supply shares of the margin pool.
public(package) fun supply_shares(self: &State): u64 {
    self.supply_shares
}

/// Return the total borrow of the margin pool.
public(package) fun total_borrow(self: &State): u64 {
    self.total_borrow
}

/// Return the total borrow shares of the margin pool.
public(package) fun borrow_shares(self: &State): u64 {
    self.borrow_shares
}

/// Return the last update timestamp of the margin pool.
public(package) fun last_update_timestamp(self: &State): u64 {
    self.last_update_timestamp
}
