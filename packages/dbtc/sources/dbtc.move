module dbtc::dbtc;

use sui::coin_registry;

public struct DBTC has drop {}

/// This is a token for testing purposes, used only on testnet.
fun init(witness: DBTC, ctx: &mut TxContext) {
    let (builder, treasury_cap) = coin_registry::new_currency_with_otw(
        witness,
        8, // Decimals
        b"DBTC".to_string(),
        b"DeepBook BTC".to_string(),
        b"DeepBook Test BTC".to_string(),
        b"https://upload.wikimedia.org/wikipedia/commons/4/46/Bitcoin.svg".to_string(),
        ctx,
    );

    let metadata_cap = builder.finalize(ctx);

    transfer::public_transfer(treasury_cap, ctx.sender());
    transfer::public_transfer(metadata_cap, ctx.sender());
}
