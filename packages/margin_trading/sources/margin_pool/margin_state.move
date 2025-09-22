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
): (u64, u64) {
    let protocol_fees = self.update(config, clock);
    let ratio = self.supply_ratio();
    let shares = math::div(amount, ratio);
    self.supply_shares = self.supply_shares + shares;
    self.supply = self.supply + amount;

    (shares, protocol_fees)
}

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
    self.supply = self.supply - amount;

    (amount, protocol_fees)
}

public(package) fun increase_supply_absolute(self: &mut State, amount: u64) {
    self.supply = self.supply + amount;
}

public(package) fun decrease_supply_absolute(self: &mut State, amount: u64) {
    self.supply = self.supply - amount;
}

public(package) fun increase_borrow(
    self: &mut State,
    config: &ProtocolConfig,
    amount: u64,
    clock: &Clock,
): (u64, u64, u64) {
    let protocol_fees = self.update(config, clock);
    let ratio = self.borrow_ratio();
    let shares = math::div(amount, ratio);
    self.borrow_shares = self.borrow_shares + shares;
    self.borrow = self.borrow + amount;

    (self.borrow, self.borrow_shares, protocol_fees)
}

/// Decrease borrowed shares and return the corresponding amount
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
    self.borrow = self.borrow - amount;

    (amount, protocol_fees)
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

public(package) fun supply_shares(self: &State): u64 {
    self.supply_shares
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
    let interest = math::mul(self.borrow, time_adjusted_rate);
    let borrow = self.borrow + interest;
    let ratio = if (self.borrow_shares == 0) {
        constants::float_scaling()
    } else {
        math::div(borrow, self.borrow_shares)
    };

    math::mul(shares, ratio)
}

public(package) fun supply_shares_to_amount(
    self: &State,
    shares: u64,
    config: &ProtocolConfig,
    clock: &Clock,
): u64 {
    let now = clock.timestamp_ms();
    let elapsed = now - self.last_update_timestamp;

    let time_adjusted_rate = config.time_adjusted_rate(self.utilization_rate(), elapsed);
    let interest = math::mul(self.borrow, time_adjusted_rate);
    let protocol_fees = math::mul(interest, config.protocol_spread());
    let supply = self.supply + interest - protocol_fees;
    let ratio = if (self.supply_shares == 0) {
        constants::float_scaling()
    } else {
        math::div(supply, self.supply_shares)
    };

    math::mul(shares, ratio)
}

fun update(self: &mut State, config: &ProtocolConfig, clock: &Clock): u64 {
    let now = clock.timestamp_ms();
    let elapsed = now - self.last_update_timestamp;

    let time_adjusted_rate = config.time_adjusted_rate(self.utilization_rate(), elapsed);
    let interest = math::mul(self.borrow, time_adjusted_rate);
    let protocol_fees = math::mul(interest, config.protocol_spread());
    self.supply = self.supply + interest - protocol_fees;
    self.borrow = self.borrow + interest;
    self.last_update_timestamp = now;

    protocol_fees
}

fun supply_ratio(self: &State): u64 {
    if (self.supply_shares == 0) {
        constants::float_scaling()
    } else {
        math::div(self.supply, self.supply_shares)
    }
}

fun borrow_ratio(self: &State): u64 {
    if (self.borrow_shares == 0) {
        constants::float_scaling()
    } else {
        math::div(self.borrow, self.borrow_shares)
    }
}
