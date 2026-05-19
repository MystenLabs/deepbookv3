use serde::Serialize;
use std::str::FromStr;
use sui_sdk_types::{Address, Identifier, StructTag};

pub trait MoveStruct: Serialize {
    const MODULE: &'static str;
    const NAME: &'static str;
    const TYPE_PARAMS: &'static [&'static str] = &[];

    fn matches_event_type(
        event_type: &move_core_types::language_storage::StructTag,
        env: crate::DeepbookEnv,
    ) -> bool {
        use move_core_types::account_address::AccountAddress;

        let all_struct_types = Self::get_all_struct_types(env);

        all_struct_types.iter().any(|struct_type| {
            event_type.address == AccountAddress::new(*struct_type.address.inner())
                && event_type.module.as_str() == struct_type.module.as_str()
                && event_type.name.as_str() == struct_type.name.as_str()
        })
    }

    fn get_all_struct_types(env: crate::DeepbookEnv) -> Vec<StructTag> {
        let package_addresses = env.package_addresses();
        let mut struct_types = Vec::new();

        for address in package_addresses {
            let struct_tag = StructTag {
                address: (*address.inner()).into(),
                module: Identifier::from_str(Self::MODULE).unwrap(),
                name: Identifier::from_str(Self::NAME).unwrap(),
                type_params: Self::TYPE_PARAMS
                    .iter()
                    .map(|param| {
                        sui_sdk_types::TypeTag::Struct(Box::new(StructTag {
                            address: (*address.inner()).into(),
                            module: Identifier::from_str(Self::MODULE).unwrap(),
                            name: Identifier::from_str(param).unwrap(),
                            type_params: Vec::new(),
                        }))
                    })
                    .collect(),
            };
            struct_types.push(struct_tag);
        }

        struct_types
    }
}
