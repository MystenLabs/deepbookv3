module dbtc::dbtc;

use sui::coin_registry;

// The type identifier of coin. The coin will have a type
// tag of kind: `Coin<package_object::mycoin::MYCOIN>`
// Make sure that the name of the type matches the module's name.
public struct DBTC has drop {}

// Module initializer is called once on module publish. A `TreasuryCap` is sent
// to the publisher, who then controls minting and burning. `MetadataCap` is also
// sent to the Publisher.
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

    // Freezing this object makes the metadata immutable, including the title, name, and icon image.
    // If you want to allow mutability, share it with public_share_object instead.
    transfer::public_transfer(treasury_cap, ctx.sender());
    transfer::public_transfer(metadata_cap, ctx.sender());
}
