//! MoveStruct trait for the oracle indexer
//!
//! Mirrors the predict indexer's `crates/predict-indexer/src/traits.rs`,
//! parameterized on `OracleEnv` and routed through `ModuleType::Oracle`. Module
//! definitions live in `lib.rs` for centralized configuration.
//!
//! The observation events are cross-package generics
//! (`ObservationRecorded<OracleRead<Payload>>`), so this trait does NOT fabricate
//! `type_params` the way the predict trait does. Matching is head-only — by
//! `(address, module, name)` — which is correct: the concrete payload is
//! discriminated by inspecting `ev.type_.type_params` in the handler, not here.

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

    /// Get the list of acceptable package addresses for this event type based on environment
    fn acceptable_package_addresses(env: crate::OracleEnv) -> Result<Vec<Address>, String> {
        get_package_addresses_for_module(Self::MODULE, env)
    }

    /// Check if a struct tag matches this event type from any supported package version
    fn matches_event_type(
        event_type: &move_core_types::language_storage::StructTag,
        env: crate::OracleEnv,
    ) -> bool {
        use move_core_types::account_address::AccountAddress;

        // Get all possible struct types for this event
        let all_struct_types = Self::get_all_struct_types(env);

        // Head-only match on (address, module, name). The observation events are
        // cross-package generics, so their type_params are intentionally not part
        // of this comparison; the handler inspects them to split RawSpot vs
        // RawSurface.
        all_struct_types.iter().any(|struct_type| {
            event_type.address == AccountAddress::new(*struct_type.address.inner())
                && event_type.module.as_str() == struct_type.module.as_str()
                && event_type.name.as_str() == struct_type.name.as_str()
        })
    }

    /// Generate all possible struct types for this event across all supported package versions
    fn get_all_struct_types(env: crate::OracleEnv) -> Vec<StructTag> {
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
                type_params: Vec::new(),
            };
            struct_types.push(struct_tag);
        }

        struct_types
    }
}

/// Generic helper that reads package addresses from lib.rs at runtime.
///
/// Goes through `OracleEnv::package_addresses()` — the same non-empty-asserting
/// accessor `is_propbook_tx` uses — so there is a single "addresses must be
/// non-empty" check shared by event-type matching and tx-filtering.
pub fn get_package_addresses_for_module(
    module: &str,
    env: crate::OracleEnv,
) -> Result<Vec<Address>, String> {
    match get_module_type(module) {
        ModuleType::Oracle => Ok(env
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
