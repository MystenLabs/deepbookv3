use move_binding_derive::move_contract;

move_contract! {alias="sui", package="0x2", base_path = crate::models}
move_contract! {alias="token", package="0xdeeb7a4662eec9f2f3def03fb937a663dddaa2e215b8078a284d026b7946c270", base_path = crate::models}
move_contract! {alias="deepbook", package="@deepbook/core", base_path = crate::models}

// Actual testnet contracts (to be enabled later):
// https://github.com/wormhole-foundation/wormhole/blob/main/sui/wormhole/Move.testnet.toml
move_contract! {alias="wormhole_testnet", package="0x21473617f3565d704aa67be73ea41243e9e34a42d434c31f8182c67ba01ccf49", network = "testnet", base_path = crate::models}
// https://github.com/pyth-network/pyth-crosschain/blob/main/target_chains/sui/contracts/Move.testnet.toml
move_contract! {alias="pyth_testnet", package="0xabf837e98c26087cba0883c0a7a28326b1fa3c5e1e2c5abdb486f9e8f594c837", network = "testnet", base_path = crate::models}
move_contract! {alias="token_testnet", package="0x36dbef866a1d62bf7328989a10fb2f07d769f4ee587c0de4a0a256e57e0a58a8", network = "testnet", base_path = crate::models}
move_contract! {alias="deepbook_testnet", package="@deepbook/core", network = "testnet", base_path = crate::models}
move_contract! {alias="deepbook_margin", package="0x442d21fd044b90274934614c3c41416c83582f42eaa8feb4fecea301aa6bdd54", network = "testnet", base_path = crate::models}
