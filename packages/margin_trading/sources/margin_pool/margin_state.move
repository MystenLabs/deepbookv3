module margin_trading::margin_state;

use deepbook::{constants, math};
use margin_trading::protocol_config::ProtocolConfig;
use sui::clock::Clock;

// === Constants ===
public struct State has drop, store {
    total_supply: u64,
    total_borrow: u64,
    supply_index: u64,
    borrow_index: u64,
    last_index_update_timestamp: u64,
}

public(package) fun default(clock: &Clock): State {
    State {
        total_supply: 0,
        total_borrow: 0,
        supply_index: constants::float_scaling(),
        borrow_index: constants::float_scaling(),
        last_index_update_timestamp: clock.timestamp_ms(),
    }
}

// === Public-Package Functions ===
/// Updates the index for the margin pool.
public(package) fun update(self: &mut State, config: &ProtocolConfig, clock: &Clock): u64 {
    let current_timestamp = clock.timestamp_ms();
    if (self.last_index_update_timestamp == current_timestamp) return 0;

    let time_adjusted_rate = config.time_adjusted_rate(
        self.utilization_rate(),
        current_timestamp - self.last_index_update_timestamp,
    );
    let total_interest_accrued = math::mul(self.total_borrow, time_adjusted_rate);

    let new_supply = self.total_supply + total_interest_accrued;
    let new_borrow = self.total_borrow + total_interest_accrued;
    self.update_supply_index(new_supply);
    self.update_borrow_index(new_borrow);
    self.last_index_update_timestamp = current_timestamp;

    total_interest_accrued
}

public(package) fun increase_total_supply(self: &mut State, amount: u64) {
    self.total_supply = self.total_supply + amount;
}

public(package) fun increase_total_supply_with_index(self: &mut State, amount: u64) {
    let current_supply = self.total_supply;
    let new_supply = current_supply + amount;
    let new_supply_index = math::mul(
        self.supply_index,
        math::div(new_supply, current_supply),
    );
    self.total_supply = new_supply;
    self.supply_index = new_supply_index;
}

public(package) fun decrease_total_supply(self: &mut State, amount: u64) {
    self.total_supply = self.total_supply - amount;
}

public(package) fun decrease_total_supply_with_index(self: &mut State, amount: u64) {
    let current_supply = self.total_supply;
    let new_supply = current_supply - amount;
    let new_supply_index = math::mul(
        self.supply_index,
        math::div(new_supply, current_supply),
    );
    self.total_supply = new_supply;
    self.supply_index = new_supply_index;
}

public(package) fun increase_total_borrow(self: &mut State, amount: u64) {
    self.total_borrow = self.total_borrow + amount;
}

public(package) fun decrease_total_borrow(self: &mut State, amount: u64) {
    self.total_borrow = self.total_borrow - amount;
}

public(package) fun to_supply_shares(self: &State, amount: u64): u64 {
    math::div(amount, self.supply_index)
}

public(package) fun to_borrow_shares(self: &State, amount: u64): u64 {
    math::div(amount, self.borrow_index)
}

public(package) fun to_supply_amount(self: &State, shares: u64): u64 {
    math::mul(shares, self.supply_index)
}

public(package) fun to_borrow_amount(self: &State, shares: u64): u64 {
    math::mul(shares, self.borrow_index)
}

public(package) fun supply_index(self: &State): u64 {
    self.supply_index
}

public(package) fun borrow_index(self: &State): u64 {
    self.borrow_index
}

public(package) fun utilization_rate(self: &State): u64 {
    if (self.total_supply == 0) {
        0
    } else {
        math::div(self.total_borrow, self.total_supply) // 9 decimals
    }
}

public(package) fun total_supply(self: &State): u64 {
    self.total_supply
}

public(package) fun total_supply_shares(self: &State): u64 {
    math::mul(self.total_supply, self.supply_index)
}

public(package) fun total_borrow(self: &State): u64 {
    self.total_borrow
}

fun update_supply_index(self: &mut State, new_supply: u64) {
    let new_supply_index = if (self.total_supply == 0) {
        self.supply_index
    } else {
        math::mul(
            self.supply_index,
            math::div(new_supply, self.total_supply),
        )
    };
    self.supply_index = new_supply_index;
    self.total_supply = new_supply;
}

fun update_borrow_index(self: &mut State, new_borrow: u64) {
    let new_borrow_index = if (self.total_borrow == 0) {
        self.borrow_index
    } else {
        math::mul(
            self.borrow_index,
            math::div(new_borrow, self.total_borrow),
        )
    };
    self.borrow_index = new_borrow_index;
    self.total_borrow = new_borrow;
}
