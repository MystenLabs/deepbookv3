//! MoveStruct trait for the Predict indexer
//!
//! Mirrors core's `crates/indexer/src/traits.rs`, parameterized on `PredictEnv`
//! and routed through `ModuleType::Predict`. Module definitions live in `lib.rs`
//! for centralized configuration.

use serde::Serialize;
use std::str::FromStr;
use sui_sdk_types::{Address, Identifier, StructTag};

// Import types and functions from lib.rs
use crate::{get_module_type, ModuleType};

/// Trait for Move structs that can be matched against event types
pub trait MoveStruct: Serialize {
    // Event type matching constants
    const MODULE: &'static str;
    const NAME: &'static str;
    const TYPE_PARAMS: &'static [&'static str] = &[];

    /// Get the list of acceptable package addresses for this event type based on environment
    fn acceptable_package_addresses(env: crate::PredictEnv) -> Result<Vec<Address>, String> {
        get_package_addresses_for_module(Self::MODULE, env)
    }

    /// Check if a struct tag matches this event type from any supported package version
    fn matches_event_type(
        event_type: &move_core_types::language_storage::StructTag,
        env: crate::PredictEnv,
    ) -> bool {
        use move_core_types::account_address::AccountAddress;

        // Get all possible struct types for this event
        let all_struct_types = Self::get_all_struct_types(env);

        // Check if the event type matches any of the generated struct types
        // NOTE: We intentionally ignore type_params.len() because events may have phantom/generic type parameters
        // that don't affect the actual event structure.
        all_struct_types.iter().any(|struct_type| {
            event_type.address == AccountAddress::new(*struct_type.address.inner())
                && event_type.module.as_str() == struct_type.module.as_str()
                && event_type.name.as_str() == struct_type.name.as_str()
        })
    }

    /// Generate all possible struct types for this event across all supported package versions
    fn get_all_struct_types(env: crate::PredictEnv) -> Vec<StructTag> {
        let acceptable_addresses = match Self::acceptable_package_addresses(env) {
            Ok(addresses) => addresses,
            Err(_) => return Vec::new(), // Return empty vec if module is unknown
        };
        let mut struct_types = Vec::new();

        for address in acceptable_addresses {
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

/// Generic helper that reads package addresses from lib.rs at runtime.
///
/// Goes through `PredictEnv::package_addresses()` — the same non-empty-asserting
/// accessor `is_predict_tx` uses — so there is a single "addresses must be
/// non-empty" check shared by event-type matching and tx-filtering.
pub fn get_package_addresses_for_module(
    module: &str,
    env: crate::PredictEnv,
) -> Result<Vec<Address>, String> {
    match get_module_type(module) {
        ModuleType::Predict => Ok(env
            .package_addresses()
            .into_iter()
            .map(|addr| Address::new(addr.into_bytes()))
            .collect()),
        ModuleType::Unknown => {
            // Raise exception for unknown modules
            Err(format!("Unknown module: {}", module))
        }
    }
}
