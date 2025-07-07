module margin_trading::state;

use deepbook::math;
use sui::clock::Clock;

// === Constants ===
const DEFAULT_INTEREST_RATE: u64 = 1_000_000_000; // 100%
const YEAR_MS: u64 = 365 * 24 * 60 * 60 * 1000;

public struct State has drop, store {
    total_supply: u64,
    total_loan: u64,
    index: u64,
    last_index_update_timestamp: u64,
}

public(package) fun default(clock: &Clock): State {
    State {
        total_supply: 0,
        total_loan: 0,
        index: 1_000_000_000,
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
    let interest_accrued = math::mul(self.total_loan, time_adjusted_rate);
    let additional_index = math::div(interest_accrued, self.total_supply);

    self.index = self.index + additional_index;
    self.total_supply = self.total_supply + interest_accrued;
    self.total_loan = self.total_loan - interest_accrued;
    self.last_index_update_timestamp = current_timestamp;
}

/// Get current interest rate based on utilization and default rate.
public(package) fun interest_rate(self: &State): u64 {
    let utilization_rate = self.utilization_rate();
    math::mul(utilization_rate, DEFAULT_INTEREST_RATE)
}

public(package) fun index(self: &State): u64 {
    self.index
}

public(package) fun utilization_rate(self: &State): u64 {
    if (self.total_supply == 0) {
        0
    } else {
        math::div(self.total_loan, self.total_supply) // 9 decimals
    }
}

public(package) fun increase_total_supply(self: &mut State, amount: u64) {
    self.total_supply = self.total_supply + amount;
}

public(package) fun decrease_total_supply(self: &mut State, amount: u64) {
    self.total_supply = self.total_supply - amount;
}

public(package) fun increase_total_loan(self: &mut State, amount: u64) {
    self.total_loan = self.total_loan + amount;
}

public(package) fun total_supply(self: &State): u64 {
    self.total_supply
}

public(package) fun total_loan(self: &State): u64 {
    self.total_loan
}
