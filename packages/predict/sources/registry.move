// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Registry module for the Predict protocol.
///
/// Manages:
/// - `Registry` shared object that tracks all markets
/// - `AdminCap` capability for admin operations
/// - Market registration and lookup
/// - Global pause flags for trading and withdrawals
///
/// The Registry is created once during package initialization.
/// AdminCap is transferred to the deployer (expected to be a multisig).
module deepbook_predict::registry;

// === Imports ===

// === Errors ===
const ENotAuthorized: u64 = 0;
const EMarketAlreadyExists: u64 = 1;
const EMarketNotFound: u64 = 2;

// === Structs ===

/// Capability for admin operations.
/// Created during package init, transferred to deployer (multisig).
public struct AdminCap has key, store {
    id: UID,
}

/// Shared object tracking all markets and global state.
public struct Registry has key {
    id: UID,
    /// Whether trading is globally paused
    trading_paused: bool,
    /// Whether LP withdrawals are globally paused
    withdrawals_paused: bool,
}

// === Public Functions ===

// === Public-Package Functions ===

/// Check if trading is paused.
public(package) fun is_trading_paused(registry: &Registry): bool {
    registry.trading_paused
}

/// Check if withdrawals are paused.
public(package) fun is_withdrawals_paused(registry: &Registry): bool {
    registry.withdrawals_paused
}

// === Private Functions ===

/// Package initializer - creates Registry and AdminCap.
fun init(ctx: &mut TxContext) {
    let registry = Registry {
        id: object::new(ctx),
        trading_paused: false,
        withdrawals_paused: false,
    };
    transfer::share_object(registry);

    let admin_cap = AdminCap {
        id: object::new(ctx),
    };
    transfer::transfer(admin_cap, ctx.sender());
}

// === Test Functions ===
#[test_only]
public fun init_for_testing(ctx: &mut TxContext) {
    init(ctx);
}

#[test_only]
public fun create_admin_cap_for_testing(ctx: &mut TxContext): AdminCap {
    AdminCap { id: object::new(ctx) }
}
