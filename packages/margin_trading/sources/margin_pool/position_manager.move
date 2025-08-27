// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Position manager is responsible for managing the positions of the users.
/// It is used to track the supply and loan shares of the users.
module margin_trading::position_manager;

use sui::table::{Self, Table};

public struct PositionManager has store {
    supplies: Table<address, Supply>,
}

public struct Supply has store {
    supply_shares: u64,
}

public(package) fun create_position_manager(ctx: &mut TxContext): PositionManager {
    PositionManager {
        supplies: table::new(ctx),
    }
}

/// Increase the supply shares of the user
public(package) fun increase_user_supply_shares(
    self: &mut PositionManager,
    user: address,
    supply_shares: u64,
): u64 {
    self.add_supply_entry(user);
    let supply = self.supplies.borrow_mut(user);
    supply.supply_shares = supply.supply_shares + supply_shares;

    supply.supply_shares
}

/// Decrease the supply shares of the user
public(package) fun decrease_user_supply_shares(
    self: &mut PositionManager,
    user: address,
    supply_shares: u64,
): u64 {
    let supply = self.supplies.borrow_mut(user);
    supply.supply_shares = supply.supply_shares - supply_shares;

    supply.supply_shares
}

/// Get the supply shares of the user.
public(package) fun user_supply_shares(self: &PositionManager, user: address): u64 {
    self.supplies.borrow(user).supply_shares
}

public(package) fun add_supply_entry(self: &mut PositionManager, user: address) {
    if (!self.supplies.contains(user)) {
        self
            .supplies
            .add(
                user,
                Supply {
                    supply_shares: 0,
                },
            );
    }
}
