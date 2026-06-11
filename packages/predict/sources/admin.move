// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Administrative authority for Predict governance operations.
///
/// The package initializer creates one `AdminCap` and transfers it to the
/// deployer. Modules that own admin-controlled state accept this capability
/// directly instead of routing unrelated mutations through the registry.
module deepbook_predict::admin;

/// Capability for admin operations.
/// Created during package init, transferred to deployer (multisig).
public struct AdminCap has key, store {
    id: UID,
}

/// Return the admin cap object ID.
public fun id(cap: &AdminCap): ID {
    cap.id.to_inner()
}

// === Public-Package Functions ===

public(package) fun new(ctx: &mut TxContext): AdminCap {
    AdminCap { id: object::new(ctx) }
}
