module margin_trading::interest;

use deepbook::math;
use margin_trading::margin_constants;

public struct InterestParams has store {
    base_rate: u64,
    base_slope: u64,
    optimal_utilization: u64,
    excess_slope: u64,
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

public(package) fun time_adjusted_rate(self: &InterestParams, utilization_rate: u64, time_elapsed: u64): u64 {
    let interest_rate = self.interest_rate(utilization_rate);
    math::div(
        math::mul(time_elapsed, interest_rate),
        margin_constants::year_ms(),
    )
}

/// Get current interest rate based on utilization and default rate.
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