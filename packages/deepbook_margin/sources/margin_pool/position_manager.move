// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Position manager is responsible for managing users' positions.
/// It is used to track the supply and loan shares of the users.
module deepbook_margin::position_manager;

use std::string::String;
use sui::{table::{Self, Table}, vec_map::{Self, VecMap}};

public struct PositionManager has store {
    positions: Table<address, Position>,
    extra_fields: VecMap<String, u64>,
}

public struct Position has store {
    shares: u64,
    referral: Option<address>,
}

// === Public-Package Functions ===
/// Initialize the position manager.
public(package) fun create_position_manager(ctx: &mut TxContext): PositionManager {
    PositionManager {
        positions: table::new(ctx),
        extra_fields: vec_map::empty(),
    }
}

/// Increase the supply shares of the user and return outstanding supply shares.
public(package) fun increase_user_supply(
    self: &mut PositionManager,
    referral: Option<address>,
    supply_shares: u64,
    user: address,
): (u64, Option<address>) {
    self.add_supply_entry(referral, user);
    let user_position = self.positions.borrow_mut(user);
    let current_referral = user_position.referral;
    user_position.shares = user_position.shares + supply_shares;
    user_position.referral = referral;

    (user_position.shares, current_referral)
}

/// Decrease the supply shares of the user and return outstanding supply shares.
public(package) fun decrease_user_supply(
    self: &mut PositionManager,
    supply_shares: u64,
    user: address,
): (u64, Option<address>) {
    let user_position = self.positions.borrow_mut(user);
    user_position.shares = user_position.shares - supply_shares;

    (user_position.shares, user_position.referral)
}

public(package) fun add_supply_entry(
    self: &mut PositionManager,
    referral: Option<address>,
    user: address,
) {
    if (!self.positions.contains(user)) {
        self
            .positions
            .add(
                user,
                Position {
                    shares: 0,
                    referral,
                },
            );
    }
}

public(package) fun user_supply_shares(self: &PositionManager, user: address): u64 {
    if (self.positions.contains(user)) {
        self.positions.borrow(user).shares
    } else {
        0
    }
}
