//! Module classification and package address management for DeepBook indexer
//!
//! This module provides a clear separation between core DeepBook modules (trading, orders, pools)
//! and margin trading modules (lending, borrowing). It maintains lists of modules and provides
//! helper functions to check module types and retrieve appropriate package addresses.
//!
//! # Module Types
//! - **Core**: Trading, orders, pools, governance (`balance_manager`, `order`, `pool`, etc.)
//! - **Margin**: Lending and borrowing (`margin_manager`, `margin_pool`, `margin_registry`)
//! - **SUI**: System modules (`sui`)
//!
//! # Usage
//! ```rust
//! use deepbook_indexer::traits::{is_core_module, is_margin_module, get_module_type, ModuleType};
//!
//! // Check if a module is core or margin
//! assert!(is_core_module("pool"));
//! assert!(is_margin_module("margin_pool"));
//!
//! // Get module type
//! let module_type = get_module_type("order");
//! assert_eq!(module_type, ModuleType::Core);
//! ```

use serde::Serialize;
use std::str::FromStr;
use sui_sdk_types::{Address, Identifier, StructTag};

/// Core DeepBook modules that handle trading, orders, and pool management
pub const CORE_MODULES: &[&str] = &[
    "balance_manager",
    "order",
    "order_info",
    "vault",
    "deep_price",
    "state",
    "governance",
    "pool",
];

/// Margin trading modules that handle lending and borrowing
pub const MARGIN_MODULES: &[&str] = &["margin_manager", "margin_pool", "margin_registry"];

/// SUI system modules
pub const SUI_MODULES: &[&str] = &["sui"];

/// Check if a module is a core DeepBook module
pub fn is_core_module(module: &str) -> bool {
    CORE_MODULES.contains(&module)
}

/// Check if a module is a margin trading module
pub fn is_margin_module(module: &str) -> bool {
    MARGIN_MODULES.contains(&module)
}

/// Check if a module is a SUI system module
pub fn is_sui_module(module: &str) -> bool {
    SUI_MODULES.contains(&module)
}

/// Get the module type (core, margin, sui, or unknown)
pub fn get_module_type(module: &str) -> ModuleType {
    if is_core_module(module) {
        ModuleType::Core
    } else if is_margin_module(module) {
        ModuleType::Margin
    } else if is_sui_module(module) {
        ModuleType::Sui
    } else {
        ModuleType::Unknown
    }
}

/// Get all known module names
pub fn get_all_known_modules() -> Vec<&'static str> {
    let mut modules = Vec::new();
    modules.extend_from_slice(CORE_MODULES);
    modules.extend_from_slice(MARGIN_MODULES);
    modules.extend_from_slice(SUI_MODULES);
    modules
}

/// Get all core module names
pub fn get_core_modules() -> &'static [&'static str] {
    CORE_MODULES
}

/// Get all margin module names
pub fn get_margin_modules() -> &'static [&'static str] {
    MARGIN_MODULES
}

/// Get all SUI module names
pub fn get_sui_modules() -> &'static [&'static str] {
    SUI_MODULES
}

/// Enum representing different module types
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ModuleType {
    Core,
    Margin,
    Sui,
    Unknown,
}

/// Trait for Move structs that can be matched against event types
pub trait MoveStruct: Serialize {
    // Event type matching constants
    const MODULE: &'static str;
    const NAME: &'static str;
    const TYPE_PARAMS: &'static [&'static str] = &[];

    /// Get the list of acceptable package addresses for this event type based on environment
    fn acceptable_package_addresses(env: crate::DeepbookEnv) -> Result<Vec<Address>, String> {
        get_package_addresses_for_module(Self::MODULE, env)
    }

    /// Check if a struct tag matches this event type from any supported package version
    fn matches_event_type(
        event_type: &move_core_types::language_storage::StructTag,
        env: crate::DeepbookEnv,
    ) -> bool {
        use move_core_types::account_address::AccountAddress;

        // Get all possible struct types for this event
        let all_struct_types = Self::get_all_struct_types(env);

        // Check if the event type matches any of the generated struct types
        all_struct_types.iter().any(|struct_type| {
            event_type.address == AccountAddress::new(*struct_type.address.inner())
                && event_type.module.as_str() == struct_type.module.as_str()
                && event_type.name.as_str() == struct_type.name.as_str()
                && event_type.type_params.len() == struct_type.type_params.len()
        })
    }

    /// Generate all possible struct types for this event across all supported package versions
    fn get_all_struct_types(env: crate::DeepbookEnv) -> Vec<StructTag> {
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

/// Generic helper that reads package addresses from lib.rs at runtime
pub fn get_package_addresses_for_module(
    module: &str,
    env: crate::DeepbookEnv,
) -> Result<Vec<Address>, String> {
    match get_module_type(module) {
        ModuleType::Core => {
            // Get core package addresses using helper function
            let core_packages = crate::get_core_package_addresses(env);
            let mut addresses = Vec::new();

            // Convert string addresses to Address types
            for addr_str in core_packages {
                if let Ok(addr) = parse_address_from_hex(addr_str) {
                    addresses.push(addr);
                }
            }

            Ok(addresses)
        }
        ModuleType::Margin => {
            // Get margin package address with validation
            // This will fail fast if margin trading is not supported on the current environment
            let margin_package = match crate::get_margin_package_address(env) {
                Ok(package) => package,
                Err(e) => {
                    return Err(format!(
                        "{} Requested module: '{}'",
                        e, module
                    ));
                }
            };
            
            // Parse the margin package address
            match parse_address_from_hex(margin_package) {
                Ok(addr) => Ok(vec![addr]),
                Err(e) => Err(format!(
                    "Failed to parse margin package address '{}': {}",
                    margin_package, e
                ))
            }
        }
        ModuleType::Sui => {
            const SUI_SYSTEM_ADDRESS: &str =
                "0000000000000000000000000000000000000000000000000000000000000002";
            if let Ok(addr) = parse_address_from_hex(SUI_SYSTEM_ADDRESS) {
                Ok(vec![addr])
            } else {
                Err("Failed to parse SUI system address".to_string())
            }
        }
        ModuleType::Unknown => {
            // Raise exception for unknown modules
            Err(format!("Unknown module: {}", module))
        }
    }
}

/// Helper function to parse hex string addresses
fn parse_address_from_hex(hex_str: &str) -> Result<Address, String> {
    // Remove 0x prefix if present
    let hex_str = if hex_str.starts_with("0x") {
        &hex_str[2..]
    } else {
        hex_str
    };

    // Parse hex string to bytes
    let bytes = hex::decode(hex_str).map_err(|e| format!("Failed to decode hex: {}", e))?;

    if bytes.len() != 32 {
        return Err(format!("Expected 32 bytes, got {}", bytes.len()));
    }

    let mut addr_bytes = [0u8; 32];
    addr_bytes.copy_from_slice(&bytes);

    Ok(Address::new(addr_bytes))
}
