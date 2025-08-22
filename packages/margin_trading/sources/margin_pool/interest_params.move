module margin_trading::interest_params;

use deepbook::math;
use margin_trading::margin_constants;

/// Represents all the interest parameters for the margin pool. Can be updated on-chain.
public struct InterestParams has drop, store {
    base_rate: u64, // 9 decimals. This is the minimum borrow interest rate.
    base_slope: u64, // 9 decimals. This is the multiplier applied based on the utilization rate, in the first part of the curve.
    optimal_utilization: u64, // 9 decimals. This is the utilization rate below which base slope is applied, above which the excess slope is applied.
    excess_slope: u64, // 9 decimals. This is the multiplier applied based on the utilization rate, in the second part of the curve.
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

public(package) fun time_adjusted_rate(
    self: &InterestParams,
    utilization_rate: u64,
    time_elapsed: u64,
): u64 {
    let interest_rate = self.interest_rate(utilization_rate);
    math::div(
        math::mul(time_elapsed, interest_rate),
        margin_constants::year_ms(),
    )
}

public(package) fun interest_rate(self: &InterestParams, utilization_rate: u64): u64 {
    let base_rate = self.base_rate;
    let base_slope = self.base_slope;
    let optimal_utilization = self.optimal_utilization;
    let excess_slope = self.excess_slope;

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
