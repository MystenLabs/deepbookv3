// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// LP token for the DeepBook Predict vault.
/// Minted on supply, burned on withdraw.
module deepbook_predict::plp;

use sui::coin;

public struct PLP has drop {}

#[allow(deprecated_usage)]
fun init(witness: PLP, ctx: &mut TxContext) {
    let (treasury_cap, metadata) = coin::create_currency(
        witness,
        6,
        b"PLP",
        b"Predict LP",
        b"LP token representing shares in the DeepBook Predict vault",
        option::none(),
        ctx,
    );
    transfer::public_transfer(metadata, ctx.sender());
    transfer::public_transfer(treasury_cap, ctx.sender());
}

#[test_only]
public fun init_for_testing(ctx: &mut TxContext) {
    init(PLP {}, ctx);
}
