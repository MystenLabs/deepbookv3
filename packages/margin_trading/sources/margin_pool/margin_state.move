module margin_trading::margin_state;

use deepbook::{constants, math};
use margin_trading::margin_constants;
use sui::clock::Clock;

// === Constants ===
public struct State has drop, store {
    total_supply: u64,
    total_borrow: u64,
    supply_index: u64,
    borrow_index: u64,
    protocol_profit: u64, // profit accumulated by the protocol, can be withdrawn by the admin
    interest_params: InterestParams,
    supply_cap: u64, // maximum amount of assets that can be supplied to the pool
    max_utilization_rate: u64, // maximum percentage of borrowable assets in the pool
    protocol_spread: u64, // protocol spread in 9 decimals
    last_index_update_timestamp: u64,
}

/// Represents all the interest parameters for the margin pool. Can be updated on-chain.
public struct InterestParams has drop, store {
    base_rate: u64, // 9 decimals. This is the minimum borrow interest rate.
    base_slope: u64, // 9 decimals. This is the multiplier applied based on the utilization rate, in the first part of the curve.
    optimal_utilization: u64, // 9 decimals. This is the utilization rate below which base slope is applied, above which the excess slope is applied.
    excess_slope: u64, // 9 decimals. This is the multiplier applied based on the utilization rate, in the second part of the curve.
}

public(package) fun default(
    interest_params: InterestParams,
    supply_cap: u64,
    max_utilization_rate: u64,
    protocol_spread: u64,
    clock: &Clock,
): State {
    State {
        total_supply: 0,
        total_borrow: 0,
        supply_index: constants::float_scaling(),
        borrow_index: constants::float_scaling(),
        protocol_profit: 0,
        interest_params,
        supply_cap,
        max_utilization_rate,
        protocol_spread,
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
        margin_constants::year_ms(),
    );
    let total_interest_accrued = math::mul(self.total_borrow, time_adjusted_rate);
    let protocol_profit_accrued = math::mul(
        total_interest_accrued,
        self.protocol_spread,
    );
    self.protocol_profit = self.protocol_profit + protocol_profit_accrued;

    let supply_interest_accrued = total_interest_accrued - protocol_profit_accrued;
    let new_supply = self.total_supply + supply_interest_accrued;
    let new_borrow = self.total_borrow + total_interest_accrued;
    let new_supply_index = if (self.total_supply == 0) {
        self.supply_index
    } else {
        math::mul(
            self.supply_index,
            math::div(new_supply, self.total_supply),
        )
    };
    let new_borrow_index = if (self.total_borrow == 0) {
        self.borrow_index
    } else {
        math::mul(
            self.borrow_index,
            math::div(new_borrow, self.total_borrow),
        )
    };

    self.supply_index = new_supply_index;
    self.borrow_index = new_borrow_index;
    self.total_supply = new_supply;
    self.total_borrow = new_borrow;
    self.last_index_update_timestamp = current_timestamp;
}

public(package) fun new_interest_params(
    base_rate: u64,
    base_slope: u64,
    optimal_utilization: u64,
    excess_slope: u64,
): InterestParams {
    InterestParams {
        base_rate,
        base_slope,
        optimal_utilization,
        excess_slope,
    }
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

public(package) fun set_supply_cap(self: &mut State, cap: u64) {
    self.supply_cap = cap;
}

public(package) fun set_max_utilization_rate(self: &mut State, rate: u64) {
    self.max_utilization_rate = rate;
}

public(package) fun update_margin_pool_spread(self: &mut State, spread: u64, clock: &Clock) {
    // Update the state before spread is updated
    self.update(clock);
    self.protocol_spread = spread;
}

public(package) fun update_interest_params(
    self: &mut State,
    interest_params: InterestParams,
    clock: &Clock,
) {
    // Update the state before interest params are updated
    self.update(clock);
    self.interest_params = interest_params;
}

public(package) fun reset_protocol_profit(self: &mut State): u64 {
    let profit = self.protocol_profit;
    self.protocol_profit = 0;

    profit
}

/// Get current interest rate based on utilization and default rate.
public(package) fun interest_rate(self: &State): u64 {
    let utilization_rate = self.utilization_rate();

    let base_rate = self.interest_params.base_rate;
    let base_slope = self.interest_params.base_slope;
    let optimal_utilization = self.interest_params.optimal_utilization;
    let excess_slope = self.interest_params.excess_slope;

    if (utilization_rate < optimal_utilization) {
        // Use base slope
        math::mul(utilization_rate, base_slope) + base_rate
    } else {
        // Use base slope and excess slope
        let excess_utilization = utilization_rate - optimal_utilization;
        let excess_rate = math::mul(excess_utilization, excess_slope);

        base_rate + math::mul(optimal_utilization, base_slope) + excess_rate
    }
}

public(package) fun to_supply_shares(self: &State, amount: u64): u64 {
    math::mul(amount, self.supply_index)
}

public(package) fun to_borrow_shares(self: &State, amount: u64): u64 {
    math::mul(amount, self.borrow_index)
}

public(package) fun to_supply_amount(self: &State, shares: u64): u64 {
    math::div(shares, self.supply_index)
}

public(package) fun to_borrow_amount(self: &State, shares: u64): u64 {
    math::div(shares, self.borrow_index)
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

public(package) fun supply_cap(self: &State): u64 {
    self.supply_cap
}

public(package) fun max_utilization_rate(self: &State): u64 {
    self.max_utilization_rate
}

public(package) fun interest_params(self: &State): &InterestParams {
    &self.interest_params
}

public(package) fun base_rate(self: &InterestParams): u64 {
    self.base_rate
}

public(package) fun base_slope(self: &InterestParams): u64 {
    self.base_slope
}

public(package) fun optimal_utilization(self: &InterestParams): u64 {
    self.optimal_utilization
}

public(package) fun excess_slope(self: &InterestParams): u64 {
    self.excess_slope
}
