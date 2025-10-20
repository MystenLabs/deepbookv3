// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Position manager is responsible for managing users' positions.
/// It is used to track the supply and loan shares of the users.
module deepbook_margin::position_manager;

use std::string::String;
use sui::{table::{Self, Table}, vec_map::{Self, VecMap}};

public struct PositionManager has store {
    positions: Table<ID, Position>,
    extra_fields: VecMap<String, u64>,
}

public struct Position has store {
    shares: u64,
    referral: Option<ID>,
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
/// Returns the new total supply shares and the previous referral.
public(package) fun increase_user_supply(
    self: &mut PositionManager,
    supplier_cap_id: ID,
    referral: Option<ID>,
    supply_shares: u64,
): (u64, Option<ID>) {
    self.add_supply_entry(supplier_cap_id, referral);
    let user_position = self.positions.borrow_mut(supplier_cap_id);
    let previous_referral = user_position.referral;
    user_position.shares = user_position.shares + supply_shares;
    user_position.referral = referral;

    (user_position.shares, previous_referral)
}

/// Decrease the supply shares of the user and return outstanding supply shares.
public(package) fun decrease_user_supply(
    self: &mut PositionManager,
    supplier_cap_id: ID,
    supply_shares: u64,
): (u64, Option<ID>) {
    let user_position = self.positions.borrow_mut(supplier_cap_id);
    user_position.shares = user_position.shares - supply_shares;

    (user_position.shares, user_position.referral)
}

public(package) fun add_supply_entry(
    self: &mut PositionManager,
    supplier_cap_id: ID,
    referral: Option<ID>,
) {
    if (!self.positions.contains(supplier_cap_id)) {
        self
            .positions
            .add(
                supplier_cap_id,
                Position {
                    shares: 0,
                    referral,
                },
            );
    }
}

public(package) fun user_supply_shares(self: &PositionManager, supplier_cap_id: ID): u64 {
    if (self.positions.contains(supplier_cap_id)) {
        self.positions.borrow(supplier_cap_id).shares
    } else {
        0
    }
}
