// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Proves the holder may pause, end, and void markets for one deployer.
/// Admit transfers it to the deployer admin address. It has no `store`.
module venue::deployer_admin;

public struct DeployerAdminCap has key {
    id: UID,
    deployer_id: ID,
}

/// Returns the deployer this cap administers.
public fun deployer_id(cap: &DeployerAdminCap): ID {
    cap.deployer_id
}

public(package) fun mint(deployer_id: ID, ctx: &mut TxContext): DeployerAdminCap {
    DeployerAdminCap { id: object::new(ctx), deployer_id }
}

public(package) fun transfer_to(cap: DeployerAdminCap, recipient: address) {
    transfer::transfer(cap, recipient);
}
