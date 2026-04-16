use move_core_types::account_address::AccountAddress;
use serde::Serialize;

pub trait MoveStruct: Serialize {
    const MODULE: &'static str;
    const NAME: &'static str;

    fn matches_event_type(
        event_type: &move_core_types::language_storage::StructTag,
        packages: &[AccountAddress],
    ) -> bool {
        packages.iter().any(|addr| {
            event_type.address == *addr
                && event_type.module.as_str() == Self::MODULE
                && event_type.name.as_str() == Self::NAME
        })
    }
}
