/// Predict's settlement collateral type. The module path is `usdc::usdc::USDC` on every
/// network so one source resolves everywhere: testnet and localnet publish this package,
/// while mainnet links native USDC through `[dep-replacements.mainnet]` in the consuming
/// root manifest. Nothing here is ever published to mainnet — the mainnet identity belongs
/// to Circle, and republishing it would mint a second, worthless type of the same name.
module usdc::usdc;

use sui::coin_registry;

public struct USDC has drop {}

/// Test USDC token for testnet and localnet use only. The symbol stays `DUSDC` so the test
/// coin is distinguishable from native USDC in explorers and wallets; only the type name
/// has to match mainnet.
fun init(witness: USDC, ctx: &mut TxContext) {
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
