// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Venue mints this cap at package init and transfers it to the publisher.
/// Possession proves an admin write. Predict's AdminCap stays on the range book.
module venue::admin;

public struct AdminCap has key, store {
    id: UID,
}

/// Returns the cap's object id.
public fun id(cap: &AdminCap): ID {
    cap.id.to_inner()
}

/// Mints a cap. Package init is the only production caller.
public(package) fun new(ctx: &mut TxContext): AdminCap {
    AdminCap { id: object::new(ctx) }
}
