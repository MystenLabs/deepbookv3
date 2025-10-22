use serde::{Deserialize, Serialize};
use std::marker::PhantomData;
use sui_sdk_types::Address;
use crate::traits::MoveStruct;

// ObjectId is just an Address in sui-sdk-types
pub type ObjectId = Address;




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
