module margin_trading::interest_rate;

// === Constants ===
const DEFAULT_BASE_RATE: u64 = 1000000000; // 100%
const DEFAULT_MULTIPLIER: u64 = 1000000000; // 100%

/// TODO: update interest params as needed, like max interest rate, etc.
/// Represents all the interest parameters for the margin pool. Can be updated on chain.
public struct InterestRate has drop, store {
    base_rate: u64, // 9 decimals
    multiplier: u64, // 9 decimals
}

public(package) fun default(): InterestRate {
    InterestRate {
        base_rate: DEFAULT_BASE_RATE,
        multiplier: DEFAULT_MULTIPLIER,
    }
}

/// TODO: asserts
public(package) fun update_interest_rate(
    interest_rate: &mut InterestRate,
    base_rate: u64,
    multiplier: u64,
) {
    interest_rate.base_rate = base_rate;
    interest_rate.multiplier = multiplier;
}
