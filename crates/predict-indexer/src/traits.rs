use move_core_types::account_address::AccountAddress;
use serde::Serialize;

/// Simplified MoveStruct trait for the predict indexer.
/// Matches Move event types against a flat list of package addresses.
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
