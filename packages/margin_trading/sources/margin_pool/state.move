module margin_trading::margin_state;

use deepbook::math;
use sui::clock::Clock;

// === Constants ===
const DEFAULT_INTEREST_RATE: u64 = 1_000_000_000; // 100%
const YEAR_MS: u64 = 365 * 24 * 60 * 60 * 1000;

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
        supply_index: 1_000_000_000,
        borrow_index: 1_000_000_000,
        last_index_update_timestamp: clock.timestamp_ms(),
    }
}

// === Public-Package Functions ===
/// Updates the index for the margin pool.
public(package) fun update(self: &mut State, clock: &Clock) {
    let current_timestamp = clock.timestamp_ms();
    let ms_elapsed = current_timestamp - self.last_index_update_timestamp;
    let interest_rate = self.interest_rate();
    let time_adjusted_rate = math::div(
        math::mul(ms_elapsed, interest_rate),
        YEAR_MS,
    );
    let interest_accrued = math::mul(self.total_borrow, time_adjusted_rate);
    let new_supply = self.total_supply + interest_accrued;
    let new_borrow = self.total_borrow + interest_accrued;
    let new_supply_index = math::mul(
        self.supply_index,
        math::div(new_supply, self.total_supply),
    );
    let new_borrow_index = math::mul(
        self.borrow_index,
        math::div(new_borrow, self.total_borrow),
    );

    self.supply_index = new_supply_index;
    self.borrow_index = new_borrow_index;
    self.total_supply = new_supply;
    self.total_borrow = new_borrow;
    self.last_index_update_timestamp = current_timestamp;
}

/// Get current interest rate based on utilization and default rate.
public(package) fun interest_rate(self: &State): u64 {
    let utilization_rate = self.utilization_rate();
    math::mul(utilization_rate, DEFAULT_INTEREST_RATE)
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

public(package) fun increase_total_supply(self: &mut State, amount: u64) {
    self.total_supply = self.total_supply + amount;
}

public(package) fun decrease_total_supply(self: &mut State, amount: u64) {
    self.total_supply = self.total_supply - amount;
}

public(package) fun increase_total_borrow(self: &mut State, amount: u64) {
    self.total_borrow = self.total_borrow + amount;
}

public(package) fun total_supply(self: &State): u64 {
    self.total_supply
}

public(package) fun total_borrow(self: &State): u64 {
    self.total_borrow
}
