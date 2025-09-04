// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Position manager is responsible for managing the positions of the users.
/// It is used to track the supply and loan shares of the users.
module margin_trading::position_manager;

use sui::table::{Self, Table};

public struct PositionManager has store {
    supply_shares: Table<address, u64>,
}

public(package) fun create_position_manager(ctx: &mut TxContext): PositionManager {
    PositionManager {
        supply_shares: table::new(ctx),
    }
}

/// Increase the supply shares of the user
public(package) fun increase_user_supply_shares(
    self: &mut PositionManager,
    user: address,
    supply_shares: u64,
): u64 {
    self.add_supply_entry(user);
    let supply = self.supply_shares.borrow_mut(user);
    *supply = *supply + supply_shares;

    *supply
}

/// Decrease the supply shares of the user
public(package) fun decrease_user_supply_shares(
    self: &mut PositionManager,
    user: address,
    supply_shares: u64,
): u64 {
    let supply = self.supply_shares.borrow_mut(user);
    *supply = *supply - supply_shares;

    *supply
}

/// Get the supply shares of the user.
public(package) fun user_supply_shares(self: &PositionManager, user: address): u64 {
    *self.supply_shares.borrow(user)
}

public(package) fun add_supply_entry(self: &mut PositionManager, user: address) {
    if (!self.supply_shares.contains(user)) {
        self
            .supply_shares
            .add(
                user,
                0,
            );
    }
}
