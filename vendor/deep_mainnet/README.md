# Mainnet DEEP dependency source

This is a bytecode-backed reconstruction of the existing Mainnet DEEP v1 package, not recovered original publication source. It is used only by Mainnet dependency replacements; `packages/token` remains the development and Testnet source. DEEP is not published or upgraded by the Predict deployment.

The baseline is [the repository token source](https://github.com/MystenLabs/deepbookv3/blob/510f49f65d28a30838318fbe5bef3c9cf0a907f3/packages/token/sources/deep.move). The reconstruction introduces named supply/decimal constants, restores declaration and local-slot ordering, and mints before freezing metadata and creating the protected treasury UID. These choices reproduce the complete serialized on-chain module, including instruction and constant-table ordering. The existing test-only helper is retained and is not in published bytecode.

`provenance.json` records the baseline source hash, reconstructed source hash, Mainnet package identity and digest, and the 1,308-byte module hash. `sui 1.32.2-a5eab1a75fa8` reproduces those bytes with the historical framework pin in `Move.toml`; this does not establish which compiler the original publisher used. The Apache-2.0 notice is retained; the repository [LICENSE](../../LICENSE) applies.

The [deployment verifier](../../packages/predict/deployment/verify_dependencies.py) builds this source in an isolated directory and compares every serialized module byte with the target-chain package, in addition to checking identity, version, and linkage. The recorded hash is provenance, not an allowlist or verification exception. Vendored files are excluded from repository-wide formatting.
