use move_binding_derive::move_contract;

move_contract! {alias="sui", package="0x2", base_path = crate::models}
move_contract! {alias="token", package="0xdeeb7a4662eec9f2f3def03fb937a663dddaa2e215b8078a284d026b7946c270", base_path = crate::models}
move_contract! {alias="deepbook", package="@deepbook/core", base_path = crate::models}
