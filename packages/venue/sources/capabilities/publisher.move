// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Proves the holder may publish markets and create the vault for one deployer.
/// Admit transfers it to the deployer admin address. It has no `store`.
module venue::publisher;

public struct PublisherCap has key {
    id: UID,
    deployer_id: ID,
}

/// Returns the deployer this cap publishes for.
public fun deployer_id(cap: &PublisherCap): ID {
    cap.deployer_id
}

public(package) fun mint(deployer_id: ID, ctx: &mut TxContext): PublisherCap {
    PublisherCap { id: object::new(ctx), deployer_id }
}

public(package) fun transfer_to(cap: PublisherCap, recipient: address) {
    transfer::transfer(cap, recipient);
}
