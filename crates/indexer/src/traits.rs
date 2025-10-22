use serde::Serialize;
use std::str::FromStr;
use sui_sdk_types::{Address, Identifier, StructTag};

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
                            module: Identifier::from_str("").unwrap(), // Placeholder
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
    use crate::{
        MAINNET_MARGIN_PACKAGE, MAINNET_PACKAGES, TESTNET_MARGIN_PACKAGE, TESTNET_PACKAGES,
    };

    match module {
        // deepbook module
        "balance_manager" | "order" | "order_info" | "vault" | "deep_price" | "state"
        | "governance" | "pool" => {
            // Convert string addresses to Address types based on environment
            let mut addresses = Vec::new();

            match env {
                crate::DeepbookEnv::Mainnet => {
                    // Add all mainnet packages (previous + current)
                    for addr_str in MAINNET_PACKAGES {
                        if let Ok(addr) = parse_address_from_hex(addr_str) {
                            addresses.push(addr);
                        }
                    }
                }
                crate::DeepbookEnv::Testnet => {
                    // Add testnet packages
                    for addr_str in TESTNET_PACKAGES {
                        if let Ok(addr) = parse_address_from_hex(addr_str) {
                            addresses.push(addr);
                        }
                    }
                }
            }

            Ok(addresses)
        }
        // margin module
        "margin_manager" | "margin_pool" | "margin_registry" => {
            let mut addresses = Vec::new();

            match env {
                crate::DeepbookEnv::Mainnet => {
                    // Add mainnet margin package
                    if let Ok(addr) = parse_address_from_hex(MAINNET_MARGIN_PACKAGE) {
                        addresses.push(addr);
                    }
                }
                crate::DeepbookEnv::Testnet => {
                    // Add testnet margin package
                    if let Ok(addr) = parse_address_from_hex(TESTNET_MARGIN_PACKAGE) {
                        addresses.push(addr);
                    }
                }
            }

            Ok(addresses)
        }
        // sui modules
        "sui" => Ok(vec![Address::new([
            0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8,
            0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 2u8,
        ])]),
        _ => {
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
