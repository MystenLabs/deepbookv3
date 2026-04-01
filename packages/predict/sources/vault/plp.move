// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// LP token type for the DeepBook Predict vault.
/// Minted on supply, burned on withdraw.
module deepbook_predict::plp;

use sui::coin_registry;

public struct PLP has drop {}

fun init(witness: PLP, ctx: &mut TxContext) {
    let (initializer, treasury_cap) = coin_registry::new_currency_with_otw(
        witness,
        6,
        b"PLP".to_string(),
        b"Predict LP".to_string(),
        b"LP token representing shares in the DeepBook Predict vault".to_string(),
        b"".to_string(),
        ctx,
    );
    let metadata_cap = initializer.finalize(ctx);
    transfer::public_transfer(metadata_cap, ctx.sender());
    transfer::public_transfer(treasury_cap, ctx.sender());
}

#[test_only]
public fun init_for_testing(ctx: &mut TxContext) {
    init(PLP {}, ctx);
}
