module margin_trading::margin_state;

use deepbook::{constants, math};
use margin_trading::protocol_config::ProtocolConfig;
use sui::clock::Clock;

// === Constants ===
public struct State has drop, store {
    supply: u64,
    borrow: u64,
    supply_shares: u64,
    borrow_shares: u64,
    last_update_timestamp: u64,
}

public(package) fun default(clock: &Clock): State {
    State {
        supply: 0,
        borrow: 0,
        supply_shares: 0,
        borrow_shares: 0,
        last_update_timestamp: clock.timestamp_ms(),
    }
}

// === Public-Package Functions ===
public(package) fun increase_supply(
    self: &mut State,
    config: &ProtocolConfig,
    amount: u64,
    clock: &Clock,
): u64 {
    self.update(config, clock);
    let ratio = self.supply_ratio();
    let shares = math::mul(amount, ratio);
    self.supply_shares = self.supply_shares + shares;
    self.supply = self.supply + amount;

    shares
}

public(package) fun decrease_supply_shares(
    self: &mut State,
    config: &ProtocolConfig,
    shares: u64,
    clock: &Clock,
): u64 {
    self.update(config, clock);
    let ratio = self.supply_ratio();
    let amount = math::div(shares, ratio);
    self.supply_shares = self.supply_shares - shares;
    self.supply = self.supply - amount;

    amount
}

public(package) fun decrease_supply_absolute(self: &mut State, amount: u64) {
    self.supply = self.supply - amount;
}

public(package) fun increase_supply_absolute(self: &mut State, amount: u64) {
    self.supply = self.supply + amount;
}

public(package) fun increase_borrow(
    self: &mut State,
    config: &ProtocolConfig,
    amount: u64,
    clock: &Clock,
): (u64, u64) {
    self.update(config, clock);
    let ratio = self.borrow_ratio();
    let shares = math::mul(amount, ratio);
    self.borrow_shares = self.borrow_shares + shares;
    self.borrow = self.borrow + amount;

    (self.borrow, self.borrow_shares)
}

public(package) fun decrease_borrow_shares(
    self: &mut State,
    config: &ProtocolConfig,
    shares: u64,
    clock: &Clock,
): u64 {
    self.update(config, clock);
    let ratio = self.borrow_ratio();
    let amount = math::div(shares, ratio);
    self.borrow_shares = self.borrow_shares - shares;
    self.borrow = self.borrow - amount;

    amount
}

public(package) fun utilization_rate(self: &State): u64 {
    if (self.supply == 0) {
        0
    } else {
        math::div(self.borrow, self.supply)
    }
}

public(package) fun supply(self: &State): u64 {
    self.supply
}

public(package) fun borrow_shares_to_amount(
    self: &State,
    shares: u64,
    config: &ProtocolConfig,
    clock: &Clock,
): u64 {
    let now = clock.timestamp_ms();
    let elapsed = now - self.last_update_timestamp;

    let time_adjusted_rate = config.time_adjusted_rate(self.utilization_rate(), elapsed);
    let borrow = self.borrow + math::mul(self.borrow, time_adjusted_rate);
    let ratio = if (self.borrow_shares == 0) {
        constants::float_scaling()
    } else {
        math::div(self.borrow_shares, borrow)
    };

    math::div(shares, ratio)
}

fun update(self: &mut State, config: &ProtocolConfig, clock: &Clock) {
    let now = clock.timestamp_ms();
    let elapsed = now - self.last_update_timestamp;

    let time_adjusted_rate = config.time_adjusted_rate(self.utilization_rate(), elapsed);
    self.supply = self.supply + math::mul(self.borrow, time_adjusted_rate);
    self.borrow = self.borrow + math::mul(self.borrow, time_adjusted_rate);
    self.last_update_timestamp = now;
}

fun supply_ratio(self: &State): u64 {
    if (self.supply_shares == 0) {
        constants::float_scaling()
    } else {
        math::div(self.supply_shares, self.supply)
    }
}

fun borrow_ratio(self: &State): u64 {
    if (self.borrow_shares == 0) {
        constants::float_scaling()
    } else {
        math::div(self.borrow_shares, self.borrow)
    }
}
