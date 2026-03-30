module dusdc::dusdc;

use sui::coin_registry;

public struct DUSDC has drop {}

/// Test USDC token for testnet use only.
fun init(witness: DUSDC, ctx: &mut TxContext) {
    let (builder, treasury_cap) = coin_registry::new_currency_with_otw(
        witness,
        6, // USDC decimals
        b"DUSDC".to_string(),
        b"DeepBook USDC".to_string(),
        b"DeepBook Test USDC".to_string(),
        b"https://cryptologos.cc/logos/usd-coin-usdc-logo.svg".to_string(),
        ctx,
    );

    let metadata_cap = builder.finalize(ctx);

    transfer::public_transfer(treasury_cap, ctx.sender());
    transfer::public_transfer(metadata_cap, ctx.sender());
}
