# Mainnet Pyth Lazer source

This package reconstructs the Mainnet v2 source from the upstream revision and file hashes in `provenance.json`. The upstream `Published.toml` retains the original type identity and v2 storage address.

The declared source changes are Pyth’s generated `meta.move` version (`2`, receiver chain `21`) and the Wormhole dependency: the exact `sui/mainnet` commit `b71be5cbb9537c4aac8e23e74371affa3825efcd`, renamed from its legacy package name `Wormhole`. No upstream tests are vendored because their signed fixtures target version 1; consumer tests live in `packages/propbook` and `packages/predict`.

Pyth’s [publication commit](https://github.com/pyth-network/pyth-crosschain/commit/740673b01cf9b0d764fb4e6a2051534f2943e560) describes regeneration of `meta.move`. Its [contract manager](https://github.com/pyth-network/pyth-crosschain/blob/740673b01cf9b0d764fb4e6a2051534f2943e560/contract_manager/scripts/manage_sui_lazer_contract.ts) owns that generation. The selected [Wormhole Mainnet source](https://github.com/wormhole-foundation/wormhole/tree/b71be5cbb9537c4aac8e23e74371affa3825efcd/sui/wormhole) retains the published Mainnet identity and legacy framework pin.

`LICENSE` is the upstream license notice; the full Apache 2.0 license is in [the sibling vendored package](../pyth_lazer/LICENSE-APACHE). Vendored files are excluded from repository-wide formatting. `provenance.json` records hashes before the declared replacements; it does not claim a historical compiler version that upstream did not record.
