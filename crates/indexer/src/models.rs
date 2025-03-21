use move_binding_derive::move_contract;

move_contract! {alias="sui", package="0x2"}
move_contract! {alias="token", package="0xdeeb7a4662eec9f2f3def03fb937a663dddaa2e215b8078a284d026b7946c270", deps = [crate::models::sui]}
move_contract! {alias="deepbook", package="0x2c8d603bc51326b8c13cef9dd07031a408a48dddb541963357661df5d3204809", deps = [crate::models::sui, crate::models::token]}
