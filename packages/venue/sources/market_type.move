// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Names a market type the admin has created.
/// Publish can store only a type id that still exists here and on the deployer row.
module venue::market_type;

use venue::{admin::AdminCap, deployer_registry::DeployerRegistry};

/// Creates a type id and stores `name` on the registry.
public fun create(
    registry: &mut DeployerRegistry,
    _cap: &AdminCap,
    name: vector<u8>,
    ctx: &mut TxContext,
): ID {
    registry.add_type(name, ctx)
}

/// Removes a type id. A live market keeps the id it already stored.
public fun delete(registry: &mut DeployerRegistry, _cap: &AdminCap, type_id: ID): vector<u8> {
    registry.delete_type(type_id)
}
