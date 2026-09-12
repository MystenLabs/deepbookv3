# Legacy Testnet Pyth Lazer

This is the Move package from [Pyth revision `f80ff8b1aa2aa9ca17530a9b6294d254f938a5bf`](https://github.com/pyth-network/pyth-crosschain/tree/f80ff8b1aa2aa9ca17530a9b6294d254f938a5bf/lazer/contracts/sui). Predict, Propbook, and Sessions use it on Testnet; their Mainnet dependency replacements select [Pyth v2](../pyth_lazer_mainnet/README.md) separately.

All Move source, the source template, upstream tests, and the upstream copyright/license notice are byte-identical to that revision. `provenance.json` records their upstream SHA-256 hashes. The deployment test suite verifies the file inventory and hashes. The only upstream-file change is in `Move.toml`: the Wormhole branch is replaced by its exact revision, `a596dc27243e6b6dab95539c98b0af9836af2bc2`. No upstream lockfile, SDK, or generated build output is copied. `LICENSE` preserves Pyth's notice; `LICENSE-APACHE` contains the full license.

## Publication identity

`Published.toml` reconstructs the missing upstream Testnet publication record from [GyAu21H3qyuEnbUtrfpZ1AWuxXkbB8R8qyAvreG2wLTb](https://testnet.suivision.xyz/txblock/GyAu21H3qyuEnbUtrfpZ1AWuxXkbB8R8qyAvreG2wLTb). The archived transaction succeeded at checkpoint 298092937 and created the version-1 package and its `UpgradeCap`. The package's type origins retain that same original package ID. The exact historical compiler version is unavailable and is recorded as `unknown`, not inferred from the current build toolchain. This metadata restores linkage; it does not assert historical bytecode reproducibility.

Wormhole remains a pinned Git dependency. Its [upstream publication record](https://github.com/pyth-network/wormhole/blob/a596dc27243e6b6dab95539c98b0af9836af2bc2/sui/wormhole/Published.toml) already names the correct Testnet package and requires no local cache patch.

The deployment workflow consumes these existing packages; it does not republish them. Sui 1.78.1 reproduces all 12 Pyth modules and all 24 Testnet Wormhole modules after lossless historical serialization: Pyth's `channel` uses format 7; the other modules use format 6. The verifier uses the official Move serializer pinned to the deployment CLI, requires exact equality with the published bytes, and requires an exact round-trip back to the compiled bytes. No source, metadata, instructions, constants, or declarations are discarded. Mainnet retains its separate Pyth v2 source and generated version metadata. See [deployment verification gates](../../packages/predict/deployment/README.md#execution-gates).
