module margin_trading::state;

use sui::clock::Clock;

public struct State has drop, store {
    borrow_index: u64, // 9 decimals
    supply_index: u64, // 9 decimals
    last_index_update_timestamp: u64,
}

public(package) fun default(clock: &Clock): State {
    State {
        borrow_index: 1_000_000_000,
        supply_index: 1_000_000_000,
        last_index_update_timestamp: clock.timestamp_ms(),
    }
}

public(package) fun update_indices(self: &mut State, clock: &Clock) {}
