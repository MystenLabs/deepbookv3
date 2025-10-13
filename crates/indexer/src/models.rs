use move_binding_derive::move_contract;

move_contract! {alias="sui", package="0x2", base_path = crate::models}
move_contract! {alias="token", package="0xdeeb7a4662eec9f2f3def03fb937a663dddaa2e215b8078a284d026b7946c270", base_path = crate::models}
move_contract! {alias="deepbook", package="@deepbook/core", base_path = crate::models}
move_contract! {alias="deepbook_margin",  network = "testnet", package="0x442d21fd044b90274934614c3c41416c83582f42eaa8feb4fecea301aa6bdd54", base_path = crate::models}

// Actual testnet contracts (to be enabled later):
// move_contract! {alias="token_testnet", package="0x36dbef866a1d62bf7328989a10fb2f07d769f4ee587c0de4a0a256e57e0a58a8", network = "testnet", base_path = crate::models}
// move_contract! {alias="deepbook_testnet", package="@deepbook/core", network = "testnet", base_path = crate::models}
// move_contract! {alias="deepbook_margin_testnet", package="@deepbook_margin/core", network = "testnet", base_path = crate::models}
