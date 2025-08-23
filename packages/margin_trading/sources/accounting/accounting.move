module margin_trading::accounting;

use deepbook::math;
use margin_trading::interest::InterestParams;
use sui::clock::Clock;

public struct Accounting has store {
    interest_params: InterestParams,
    total_supply: u64,
    total_borrow: u64,
    supply_shares: u64,
    borrow_shares: u64,
    last_update_timestamp: u64,
}

public(package) fun default(interest_params: InterestParams, clock: &Clock): Accounting {
    Accounting {
        interest_params,
        total_supply: 0,
        total_borrow: 0,
        supply_shares: 0,
        borrow_shares: 0,
        last_update_timestamp: clock.timestamp_ms(),
    }
}

public(package) fun update(self: &mut Accounting, clock: &Clock): u64 {
    let current_timestamp = clock.timestamp_ms();
    if (self.last_update_timestamp == current_timestamp) return 0;

    let utilization_rate = self.utilization_rate();
    let time_adjusted_rate = self.interest_params.time_adjusted_rate(
        utilization_rate,
        current_timestamp - self.last_update_timestamp,
    );
    let total_interest_accrued = math::mul(self.total_borrow, time_adjusted_rate);

    self.total_supply = self.total_supply + total_interest_accrued;
    self.total_borrow = self.total_borrow + total_interest_accrued;
    self.last_update_timestamp = current_timestamp;

    total_interest_accrued
}

public(package) fun increase_total_supply_shares(self: &mut Accounting, amount: u64): u64 {
    let new_supply_shares = self.to_supply_shares(amount);
    self.supply_shares = self.supply_shares + new_supply_shares;
    self.total_supply = self.total_supply + amount;

    new_supply_shares
}

public(package) fun decrease_total_supply_shares(self: &mut Accounting, amount: u64): u64 {
    let new_supply_shares = self.to_supply_shares(amount);
    self.supply_shares = self.supply_shares - new_supply_shares;
    self.total_supply = self.total_supply - amount;

    new_supply_shares
}

public(package) fun increase_total_supply_absolute(self: &mut Accounting, amount: u64) {
    self.total_supply = self.total_supply + amount;
}

public(package) fun decrease_total_supply_absolute(self: &mut Accounting, amount: u64) {
    self.total_supply = self.total_supply - amount;
}

public(package) fun increase_total_borrow_shares(self: &mut Accounting, amount: u64) {
    let new_borrow_shares = self.to_borrow_shares(amount);
    self.borrow_shares = self.borrow_shares + new_borrow_shares;
    self.total_borrow = self.total_borrow + amount;
}

public(package) fun decrease_total_borrow_shares(self: &mut Accounting, amount: u64) {
    let new_borrow_shares = self.to_borrow_shares(amount);
    self.borrow_shares = self.borrow_shares - new_borrow_shares;
    self.total_borrow = self.total_borrow - amount;
}

public(package) fun supply_shares(self: &Accounting): u64 {
    self.supply_shares
}

public(package) fun borrow_shares(self: &Accounting): u64 {
    self.borrow_shares
}

public(package) fun utilization_rate(self: &Accounting): u64 {
    if (self.total_supply == 0) {
        0
    } else {
        math::div(self.total_borrow, self.total_supply) // 9 decimals
    }
}

public(package) fun to_supply_amount(self: &Accounting, shares: u64): u64 {
    math::mul(shares, math::div(self.total_supply, self.supply_shares))
}

public(package) fun to_borrow_amount(self: &Accounting, shares: u64): u64 {
    math::mul(shares, math::div(self.total_borrow, self.borrow_shares))
}

public(package) fun to_supply_shares(self: &Accounting, amount: u64): u64 {
    math::mul(amount, math::div(self.supply_shares, self.total_supply))
}

public(package) fun to_borrow_shares(self: &Accounting, amount: u64): u64 {
    math::mul(amount, math::div(self.borrow_shares, self.total_borrow))
}

public(package) fun supply_index(self: &Accounting): u64 {
    math::div(self.supply_shares, self.total_supply)
}