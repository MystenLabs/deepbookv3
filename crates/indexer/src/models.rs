use serde::{Deserialize, Serialize};
use std::marker::PhantomData;
use std::str::FromStr;
use sui_sdk_types::{Address, Identifier, StructTag};

// ObjectId is just an Address in sui-sdk-types
pub type ObjectId = Address;

// Define our own MoveStruct trait with event type matching capabilities
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

// Generic helper that reads package addresses from lib.rs at runtime
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

// Helper function to parse hex string addresses
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

// DeepBook module
pub mod deepbook {
    use super::*;

    pub mod balance_manager {
        use super::*;

        #[derive(Debug, Clone, Serialize, Deserialize)]
        pub struct BalanceEvent {
            pub balance_manager_id: ObjectId,
            pub asset: String,
            pub amount: u64,
            pub deposit: bool,
        }

        impl MoveStruct for BalanceEvent {
            const MODULE: &'static str = "balance_manager";
            const NAME: &'static str = "BalanceEvent";
        }
    }

    pub mod order {
        use super::*;

        #[derive(Debug, Clone, Serialize, Deserialize)]
        pub struct OrderCanceled {
            pub balance_manager_id: ObjectId,
            pub pool_id: ObjectId,
            pub order_id: u128,
            pub client_order_id: u64,
            pub trader: Address,
            pub price: u64,
            pub is_bid: bool,
            pub original_quantity: u64,
            pub base_asset_quantity_canceled: u64,
            pub timestamp: u64,
        }

        #[derive(Debug, Clone, Serialize, Deserialize)]
        pub struct OrderModified {
            pub balance_manager_id: ObjectId,
            pub pool_id: ObjectId,
            pub order_id: u128,
            pub client_order_id: u64,
            pub trader: Address,
            pub price: u64,
            pub is_bid: bool,
            pub previous_quantity: u64,
            pub filled_quantity: u64,
            pub new_quantity: u64,
            pub timestamp: u64,
        }

        impl MoveStruct for OrderCanceled {
            const MODULE: &'static str = "order";
            const NAME: &'static str = "OrderCanceled";
        }

        impl MoveStruct for OrderModified {
            const MODULE: &'static str = "order";
            const NAME: &'static str = "OrderModified";
        }
    }

    pub mod order_info {
        use super::*;

        #[derive(Debug, Clone, Serialize, Deserialize)]
        pub struct OrderFilled {
            pub pool_id: ObjectId,
            pub maker_order_id: u128,
            pub taker_order_id: u128,
            pub maker_client_order_id: u64,
            pub taker_client_order_id: u64,
            pub price: u64,
            pub taker_is_bid: bool,
            pub taker_fee: u64,
            pub taker_fee_is_deep: bool,
            pub maker_fee: u64,
            pub maker_fee_is_deep: bool,
            pub base_quantity: u64,
            pub quote_quantity: u64,
            pub maker_balance_manager_id: ObjectId,
            pub taker_balance_manager_id: ObjectId,
            pub timestamp: u64,
        }

        #[derive(Debug, Clone, Serialize, Deserialize)]
        pub struct OrderPlaced {
            pub balance_manager_id: ObjectId,
            pub pool_id: ObjectId,
            pub order_id: u128,
            pub client_order_id: u64,
            pub trader: Address,
            pub price: u64,
            pub is_bid: bool,
            pub placed_quantity: u64,
            pub expire_timestamp: u64,
            pub timestamp: u64,
        }

        #[derive(Debug, Clone, Serialize, Deserialize)]
        pub struct OrderExpired {
            pub balance_manager_id: ObjectId,
            pub pool_id: ObjectId,
            pub order_id: u128,
            pub client_order_id: u64,
            pub trader: Address,
            pub price: u64,
            pub is_bid: bool,
            pub original_quantity: u64,
            pub base_asset_quantity_canceled: u64,
            pub timestamp: u64,
        }

        impl MoveStruct for OrderFilled {
            const MODULE: &'static str = "order_info";
            const NAME: &'static str = "OrderFilled";
        }

        impl MoveStruct for OrderPlaced {
            const MODULE: &'static str = "order_info";
            const NAME: &'static str = "OrderPlaced";
        }

        impl MoveStruct for OrderExpired {
            const MODULE: &'static str = "order_info";
            const NAME: &'static str = "OrderExpired";
        }
    }

    pub mod vault {
        use super::*;

        #[derive(Debug, Clone, Serialize, Deserialize)]
        pub struct FlashLoanBorrowed {
            pub pool_id: ObjectId,
            pub borrow_quantity: u64,
            pub type_name: String,
        }

        impl MoveStruct for FlashLoanBorrowed {
            const MODULE: &'static str = "vault";
            const NAME: &'static str = "FlashLoanBorrowed";
        }
    }

    pub mod deep_price {
        use super::*;

        #[derive(Debug, Clone, Serialize, Deserialize)]
        pub struct PriceAdded {
            pub conversion_rate: u64,
            pub timestamp: u64,
            pub is_base_conversion: bool,
            pub reference_pool: ObjectId,
            pub target_pool: ObjectId,
        }

        impl MoveStruct for PriceAdded {
            const MODULE: &'static str = "deep_price";
            const NAME: &'static str = "PriceAdded";
        }
    }

    pub mod state {
        use super::*;

        #[derive(Debug, Clone, Serialize, Deserialize)]
        pub struct VoteEvent {
            pub pool_id: ObjectId,
            pub balance_manager_id: ObjectId,
            pub epoch: u64,
            pub from_proposal_id: Option<ObjectId>,
            pub to_proposal_id: ObjectId,
            pub stake: u64,
        }

        #[derive(Debug, Clone, Serialize, Deserialize)]
        pub struct StakeEvent {
            pub pool_id: ObjectId,
            pub balance_manager_id: ObjectId,
            pub epoch: u64,
            pub amount: u64,
            pub stake: bool,
        }

        #[derive(Debug, Clone, Serialize, Deserialize)]
        pub struct RebateEvent {
            pub pool_id: ObjectId,
            pub balance_manager_id: ObjectId,
            pub epoch: u64,
            pub claim_amount: u64,
        }

        #[derive(Debug, Clone, Serialize, Deserialize)]
        pub struct ProposalEvent {
            pub pool_id: ObjectId,
            pub balance_manager_id: ObjectId,
            pub epoch: u64,
            pub taker_fee: u64,
            pub maker_fee: u64,
            pub stake_required: u64,
        }

        impl MoveStruct for VoteEvent {
            const MODULE: &'static str = "state";
            const NAME: &'static str = "VoteEvent";
        }

        impl MoveStruct for StakeEvent {
            const MODULE: &'static str = "state";
            const NAME: &'static str = "StakeEvent";
        }

        impl MoveStruct for RebateEvent {
            const MODULE: &'static str = "state";
            const NAME: &'static str = "RebateEvent";
        }

        impl MoveStruct for ProposalEvent {
            const MODULE: &'static str = "state";
            const NAME: &'static str = "ProposalEvent";
        }
    }

    pub mod governance {
        use super::*;

        #[derive(Debug, Clone, Serialize, Deserialize)]
        pub struct TradeParamsUpdateEvent {
            pub taker_fee: u64,
            pub maker_fee: u64,
            pub stake_required: u64,
        }

        impl MoveStruct for TradeParamsUpdateEvent {
            const MODULE: &'static str = "governance";

            const NAME: &'static str = "TradeParamsUpdateEvent";
        }
    }

    pub mod pool {
        use super::*;

        #[derive(Debug, Clone, Serialize, Deserialize)]
        pub struct DeepBurned<BaseAsset, QuoteAsset> {
            pub pool_id: ObjectId,
            pub deep_burned: u64,
            #[serde(skip)]
            pub phantom_base: PhantomData<BaseAsset>,
            #[serde(skip)]
            pub phantom_quote: PhantomData<QuoteAsset>,
        }

        impl<BaseAsset, QuoteAsset> MoveStruct for DeepBurned<BaseAsset, QuoteAsset> {
            const MODULE: &'static str = "pool";
            const NAME: &'static str = "DeepBurned";
        }
    }
}

// DeepBook Margin module
pub mod deepbook_margin {
    use super::*;

    pub mod margin_manager {
        use super::*;

        #[derive(Debug, Clone, Serialize, Deserialize)]
        pub struct MarginManagerEvent {
            pub margin_manager_id: ObjectId,
            pub balance_manager_id: ObjectId,
            pub owner: Address,
            pub timestamp: u64,
        }

        #[derive(Debug, Clone, Serialize, Deserialize)]
        pub struct LoanBorrowedEvent {
            pub margin_manager_id: ObjectId,
            pub margin_pool_id: ObjectId,
            pub loan_amount: u64,
            pub total_borrow: u64,
            pub total_shares: u64,
            pub timestamp: u64,
        }

        #[derive(Debug, Clone, Serialize, Deserialize)]
        pub struct LoanRepaidEvent {
            pub margin_manager_id: ObjectId,
            pub margin_pool_id: ObjectId,
            pub repay_amount: u64,
            pub repay_shares: u64,
            pub timestamp: u64,
        }

        #[derive(Debug, Clone, Serialize, Deserialize)]
        pub struct LiquidationEvent {
            pub margin_manager_id: ObjectId,
            pub margin_pool_id: ObjectId,
            pub liquidation_amount: u64,
            pub pool_reward: u64,
            pub pool_default: u64,
            pub risk_ratio: u64,
            pub timestamp: u64,
        }

        impl MoveStruct for MarginManagerEvent {
            const MODULE: &'static str = "margin_manager";
            const NAME: &'static str = "MarginManagerEvent";
        }

        impl MoveStruct for LoanBorrowedEvent {
            const MODULE: &'static str = "margin_manager";
            const NAME: &'static str = "LoanBorrowedEvent";
        }

        impl MoveStruct for LoanRepaidEvent {
            const MODULE: &'static str = "margin_manager";
            const NAME: &'static str = "LoanRepaidEvent";
        }

        impl MoveStruct for LiquidationEvent {
            const MODULE: &'static str = "margin_manager";
            const NAME: &'static str = "LiquidationEvent";
        }
    }

    pub mod margin_pool {
        use super::*;
        use std::collections::HashMap;

        #[derive(Debug, Clone, Serialize, Deserialize)]
        pub struct MarginPoolConfig {
            pub supply_cap: u64,
            pub max_utilization_rate: u64,
            pub referral_spread: u64,
            pub min_borrow: u64,
        }

        #[derive(Debug, Clone, Serialize, Deserialize)]
        pub struct InterestConfig {
            pub base_rate: u64,
            pub base_slope: u64,
            pub optimal_utilization: u64,
            pub excess_slope: u64,
        }

        #[derive(Debug, Clone, Serialize, Deserialize)]
        pub struct ProtocolConfig {
            pub margin_pool_config: MarginPoolConfig,
            pub interest_config: InterestConfig,
            pub extra_fields: HashMap<String, u64>,
        }

        #[derive(Debug, Clone, Serialize, Deserialize)]
        pub struct MarginPoolCreated {
            pub margin_pool_id: ObjectId,
            pub maintainer_cap_id: ObjectId,
            pub asset_type: String, // TypeName in Move
            pub config: ProtocolConfig,
            pub timestamp: u64,
        }

        #[derive(Debug, Clone, Serialize, Deserialize)]
        pub struct DeepbookPoolUpdated {
            pub margin_pool_id: ObjectId,
            pub deepbook_pool_id: ObjectId,
            pub pool_cap_id: ObjectId,
            pub enabled: bool,
            pub timestamp: u64,
        }

        #[derive(Debug, Clone, Serialize, Deserialize)]
        pub struct InterestParamsUpdated {
            pub margin_pool_id: ObjectId,
            pub pool_cap_id: ObjectId,
            pub interest_config: serde_json::Value,
            pub timestamp: u64,
        }

        #[derive(Debug, Clone, Serialize, Deserialize)]
        pub struct MarginPoolConfigUpdated {
            pub margin_pool_id: ObjectId,
            pub pool_cap_id: ObjectId,
            pub margin_pool_config: serde_json::Value,
            pub timestamp: u64,
        }

        #[derive(Debug, Clone, Serialize, Deserialize)]
        pub struct AssetSupplied {
            pub margin_pool_id: ObjectId,
            pub asset_type: String, // TypeName in Move
            pub supplier: Address,
            pub supply_amount: u64,
            pub supply_shares: u64,
            pub timestamp: u64,
        }

        #[derive(Debug, Clone, Serialize, Deserialize)]
        pub struct AssetWithdrawn {
            pub margin_pool_id: ObjectId,
            pub asset_type: String, // TypeName in Move
            pub supplier: Address,
            pub withdraw_amount: u64,
            pub withdraw_shares: u64,
            pub timestamp: u64,
        }

        impl MoveStruct for MarginPoolCreated {
            const MODULE: &'static str = "margin_pool";
            const NAME: &'static str = "MarginPoolCreated";
        }

        impl MoveStruct for DeepbookPoolUpdated {
            const MODULE: &'static str = "margin_pool";
            const NAME: &'static str = "DeepbookPoolUpdated";
        }

        impl MoveStruct for InterestParamsUpdated {
            const MODULE: &'static str = "margin_pool";
            const NAME: &'static str = "InterestParamsUpdated";
        }

        impl MoveStruct for MarginPoolConfigUpdated {
            const MODULE: &'static str = "margin_pool";
            const NAME: &'static str = "MarginPoolConfigUpdated";
        }

        impl MoveStruct for AssetSupplied {
            const MODULE: &'static str = "margin_pool";
            const NAME: &'static str = "AssetSupplied";
        }

        impl MoveStruct for AssetWithdrawn {
            const MODULE: &'static str = "margin_pool";
            const NAME: &'static str = "AssetWithdrawn";
        }
    }

    pub mod margin_registry {
        use super::*;

        #[derive(Debug, Clone, Serialize, Deserialize)]
        pub struct MaintainerCapUpdated {
            pub maintainer_cap_id: ObjectId,
            pub allowed: bool,
            pub timestamp: u64,
        }

        #[derive(Debug, Clone, Serialize, Deserialize)]
        pub struct DeepbookPoolRegistered {
            pub pool_id: ObjectId,
            pub timestamp: u64,
        }

        #[derive(Debug, Clone, Serialize, Deserialize)]
        pub struct DeepbookPoolUpdated {
            pub pool_id: ObjectId,
            pub enabled: bool,
            pub timestamp: u64,
        }

        #[derive(Debug, Clone, Serialize, Deserialize)]
        pub struct DeepbookPoolConfigUpdated {
            pub pool_id: ObjectId,
            pub config: serde_json::Value,
            pub timestamp: u64,
        }

        impl MoveStruct for MaintainerCapUpdated {
            const MODULE: &'static str = "margin_registry";
            const NAME: &'static str = "MaintainerCapUpdated";
        }

        impl MoveStruct for DeepbookPoolRegistered {
            const MODULE: &'static str = "margin_registry";
            const NAME: &'static str = "DeepbookPoolRegistered";
        }

        impl MoveStruct for DeepbookPoolUpdated {
            const MODULE: &'static str = "margin_registry";
            const NAME: &'static str = "DeepbookPoolUpdated";
        }

        impl MoveStruct for DeepbookPoolConfigUpdated {
            const MODULE: &'static str = "margin_registry";
            const NAME: &'static str = "DeepbookPoolConfigUpdated";
        }
    }
}

// SUI module
pub mod sui {
    pub mod sui {
        use crate::models::MoveStruct;
        use serde::{Deserialize, Serialize};
        use sui_sdk_types::Address;

        #[derive(Debug, Clone, Serialize, Deserialize)]
        pub struct SUI {
            pub id: Address,
        }

        impl MoveStruct for SUI {
            const MODULE: &'static str = "sui";
            const NAME: &'static str = "SUI";
        }
    }
}
