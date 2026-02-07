use crate::traits::MoveStruct;
use serde::{Deserialize, Serialize};
use std::marker::PhantomData;
use sui_sdk_types::Address;
use sui_types::base_types::ObjectID;
use sui_types::collection_types::VecMap;

// DeepBook module
pub mod deepbook {
    use super::*;

    pub mod balance_manager {
        use super::*;

        #[derive(Debug, Clone, Serialize, Deserialize)]
        pub struct BalanceEvent {
            pub balance_manager_id: ObjectID,
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
            pub balance_manager_id: ObjectID,
            pub pool_id: ObjectID,
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
            pub balance_manager_id: ObjectID,
            pub pool_id: ObjectID,
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
            pub pool_id: ObjectID,
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
            pub maker_balance_manager_id: ObjectID,
            pub taker_balance_manager_id: ObjectID,
            pub timestamp: u64,
        }

        #[derive(Debug, Clone, Serialize, Deserialize)]
        pub struct OrderPlaced {
            pub balance_manager_id: ObjectID,
            pub pool_id: ObjectID,
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
            pub balance_manager_id: ObjectID,
            pub pool_id: ObjectID,
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
            pub pool_id: ObjectID,
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
            pub reference_pool: ObjectID,
            pub target_pool: ObjectID,
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
            pub pool_id: ObjectID,
            pub balance_manager_id: ObjectID,
            pub epoch: u64,
            pub from_proposal_id: Option<ObjectID>,
            pub to_proposal_id: ObjectID,
            pub stake: u64,
        }

        #[derive(Debug, Clone, Serialize, Deserialize)]
        pub struct StakeEvent {
            pub pool_id: ObjectID,
            pub balance_manager_id: ObjectID,
            pub epoch: u64,
            pub amount: u64,
            pub stake: bool,
        }

        #[derive(Debug, Clone, Serialize, Deserialize)]
        pub struct RebateEvent {
            pub pool_id: ObjectID,
            pub balance_manager_id: ObjectID,
            pub epoch: u64,
            pub claim_amount: u64,
        }

        #[derive(Debug, Clone, Serialize, Deserialize)]
        pub struct ProposalEvent {
            pub pool_id: ObjectID,
            pub balance_manager_id: ObjectID,
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
        pub struct PoolCreated<BaseAsset, QuoteAsset> {
            pub pool_id: ObjectID,
            pub taker_fee: u64,
            pub maker_fee: u64,
            pub tick_size: u64,
            pub lot_size: u64,
            pub min_size: u64,
            pub whitelisted_pool: bool,
            pub treasury_address: Address,
            #[serde(skip)]
            pub phantom_base: PhantomData<BaseAsset>,
            #[serde(skip)]
            pub phantom_quote: PhantomData<QuoteAsset>,
        }

        impl<BaseAsset, QuoteAsset> MoveStruct for PoolCreated<BaseAsset, QuoteAsset> {
            const MODULE: &'static str = "pool";
            const NAME: &'static str = "PoolCreated";
        }

        #[derive(Debug, Clone, Serialize, Deserialize)]
        pub struct DeepBurned<BaseAsset, QuoteAsset> {
            pub pool_id: ObjectID,
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

        #[derive(Debug, Clone, Serialize, Deserialize)]
        pub struct ReferralFeeEvent {
            pub pool_id: ObjectID,
            pub referral_id: ObjectID,
            pub base_fee: u64,
            pub quote_fee: u64,
            pub deep_fee: u64,
        }

        impl MoveStruct for ReferralFeeEvent {
            const MODULE: &'static str = "pool";
            const NAME: &'static str = "ReferralFeeEvent";
        }
    }
}

/// Represents a Sui TypeName (package::module::Type)
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TypeName {
    pub name: String,
}

// DeepBook Margin module
pub mod deepbook_margin {
    use super::*;
    use crate::models::TypeName;

    pub mod margin_manager {
        use super::*;

        #[derive(Debug, Clone, Serialize, Deserialize)]
        pub struct MarginManagerCreatedEvent {
            pub margin_manager_id: ObjectID,
            pub balance_manager_id: ObjectID,
            pub deepbook_pool_id: ObjectID,
            pub owner: Address,
            pub timestamp: u64,
        }

        #[derive(Debug, Clone, Serialize, Deserialize)]
        pub struct LoanBorrowedEvent {
            pub margin_manager_id: ObjectID,
            pub margin_pool_id: ObjectID,
            pub loan_amount: u64,
            pub loan_shares: u64,
            pub timestamp: u64,
        }

        #[derive(Debug, Clone, Serialize, Deserialize)]
        pub struct LoanRepaidEvent {
            pub margin_manager_id: ObjectID,
            pub margin_pool_id: ObjectID,
            pub repay_amount: u64,
            pub repay_shares: u64,
            pub timestamp: u64,
        }

        #[derive(Debug, Clone, Serialize, Deserialize)]
        pub struct LiquidationEvent {
            pub margin_manager_id: ObjectID,
            pub margin_pool_id: ObjectID,
            pub liquidation_amount: u64,
            pub pool_reward: u64,
            pub pool_default: u64,
            pub risk_ratio: u64,
            pub remaining_base_asset: u64,
            pub remaining_quote_asset: u64,
            pub remaining_base_debt: u64,
            pub remaining_quote_debt: u64,
            pub base_pyth_price: u64,
            pub base_pyth_decimals: u8,
            pub quote_pyth_price: u64,
            pub quote_pyth_decimals: u8,
            pub timestamp: u64,
        }

        impl MoveStruct for MarginManagerCreatedEvent {
            const MODULE: &'static str = "margin_manager";
            const NAME: &'static str = "MarginManagerCreatedEvent";
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

        #[derive(Debug, Clone, Serialize, Deserialize)]
        pub struct DepositCollateralEvent {
            pub margin_manager_id: ObjectID,
            pub amount: u64,
            pub asset: TypeName,
            pub pyth_price: u64,
            pub pyth_decimals: u8,
            pub timestamp: u64,
        }

        #[derive(Debug, Clone, Serialize, Deserialize)]
        pub struct WithdrawCollateralEvent {
            pub margin_manager_id: ObjectID,
            pub amount: u64,
            pub asset: TypeName,
            pub withdraw_base_asset: bool,
            pub remaining_base_asset: u64,
            pub remaining_quote_asset: u64,
            pub remaining_base_debt: u64,
            pub remaining_quote_debt: u64,
            pub base_pyth_price: u64,
            pub base_pyth_decimals: u8,
            pub quote_pyth_price: u64,
            pub quote_pyth_decimals: u8,
            pub timestamp: u64,
        }

        impl MoveStruct for DepositCollateralEvent {
            const MODULE: &'static str = "margin_manager";
            const NAME: &'static str = "DepositCollateralEvent";
        }

        impl MoveStruct for WithdrawCollateralEvent {
            const MODULE: &'static str = "margin_manager";
            const NAME: &'static str = "WithdrawCollateralEvent";
        }
    }

    pub mod margin_pool {
        use super::*;

        #[derive(Debug, Clone, Serialize, Deserialize)]
        pub struct MarginPoolConfig {
            pub supply_cap: u64,
            pub max_utilization_rate: u64,
            pub protocol_spread: u64,
            pub min_borrow: u64,
            pub rate_limit_capacity: u64,
            pub rate_limit_refill_rate_per_ms: u64,
            pub rate_limit_enabled: bool,
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
            pub extra_fields: VecMap<String, u64>,
        }

        #[derive(Debug, Clone, Serialize, Deserialize)]
        pub struct MarginPoolCreated {
            pub margin_pool_id: ObjectID,
            pub maintainer_cap_id: ObjectID,
            pub asset_type: String, // TypeName in Move
            pub config: ProtocolConfig,
            pub timestamp: u64,
        }

        #[derive(Debug, Clone, Serialize, Deserialize)]
        pub struct DeepbookPoolUpdated {
            pub margin_pool_id: ObjectID,
            pub deepbook_pool_id: ObjectID,
            pub pool_cap_id: ObjectID,
            pub enabled: bool,
            pub timestamp: u64,
        }

        #[derive(Debug, Clone, Serialize, Deserialize)]
        pub struct InterestParamsUpdated {
            pub margin_pool_id: ObjectID,
            pub pool_cap_id: ObjectID,
            pub interest_config: InterestConfig,
            pub timestamp: u64,
        }

        #[derive(Debug, Clone, Serialize, Deserialize)]
        pub struct MarginPoolConfigUpdated {
            pub margin_pool_id: ObjectID,
            pub pool_cap_id: ObjectID,
            pub margin_pool_config: MarginPoolConfig,
            pub timestamp: u64,
        }

        #[derive(Debug, Clone, Serialize, Deserialize)]
        pub struct AssetSupplied {
            pub margin_pool_id: ObjectID,
            pub asset_type: String, // TypeName in Move
            pub supplier: Address,
            pub supply_amount: u64,
            pub supply_shares: u64,
            pub timestamp: u64,
        }

        #[derive(Debug, Clone, Serialize, Deserialize)]
        pub struct AssetWithdrawn {
            pub margin_pool_id: ObjectID,
            pub asset_type: String, // TypeName in Move
            pub supplier: Address,
            pub withdraw_amount: u64,
            pub withdraw_shares: u64,
            pub timestamp: u64,
        }

        #[derive(Debug, Clone, Serialize, Deserialize)]
        pub struct MaintainerFeesWithdrawn {
            pub margin_pool_id: ObjectID,
            pub margin_pool_cap_id: ObjectID,
            pub maintainer_fees: u64,
            pub timestamp: u64,
        }

        #[derive(Debug, Clone, Serialize, Deserialize)]
        pub struct ProtocolFeesWithdrawn {
            pub margin_pool_id: ObjectID,
            pub protocol_fees: u64,
            pub timestamp: u64,
        }

        #[derive(Debug, Clone, Serialize, Deserialize)]
        pub struct SupplierCapMinted {
            pub supplier_cap_id: ObjectID,
            pub timestamp: u64,
        }

        #[derive(Debug, Clone, Serialize, Deserialize)]
        pub struct SupplyReferralMinted {
            pub margin_pool_id: ObjectID,
            pub supply_referral_id: ObjectID,
            pub owner: Address,
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

        impl MoveStruct for MaintainerFeesWithdrawn {
            const MODULE: &'static str = "margin_pool";
            const NAME: &'static str = "MaintainerFeesWithdrawn";
        }

        impl MoveStruct for ProtocolFeesWithdrawn {
            const MODULE: &'static str = "margin_pool";
            const NAME: &'static str = "ProtocolFeesWithdrawn";
        }

        impl MoveStruct for SupplierCapMinted {
            const MODULE: &'static str = "margin_pool";
            const NAME: &'static str = "SupplierCapMinted";
        }

        impl MoveStruct for SupplyReferralMinted {
            const MODULE: &'static str = "margin_pool";
            const NAME: &'static str = "SupplyReferralMinted";
        }
    }

    pub mod margin_registry {
        use super::*;

        #[derive(Debug, Clone, Serialize, Deserialize)]
        pub struct RiskRatios {
            pub min_withdraw_risk_ratio: u64,
            pub min_borrow_risk_ratio: u64,
            pub liquidation_risk_ratio: u64,
            pub target_liquidation_risk_ratio: u64,
        }

        #[derive(Debug, Clone, Serialize, Deserialize)]
        pub struct PoolConfig {
            pub base_margin_pool_id: ObjectID,
            pub quote_margin_pool_id: ObjectID,
            pub risk_ratios: RiskRatios,
            pub user_liquidation_reward: u64,
            pub pool_liquidation_reward: u64,
            pub enabled: bool,
            pub extra_fields: VecMap<String, u64>,
        }

        #[derive(Debug, Clone, Serialize, Deserialize)]
        pub struct MaintainerCapUpdated {
            pub maintainer_cap_id: ObjectID,
            pub allowed: bool,
            pub timestamp: u64,
        }

        #[derive(Debug, Clone, Serialize, Deserialize)]
        pub struct DeepbookPoolRegistered {
            pub pool_id: ObjectID,
            pub config: PoolConfig,
            pub timestamp: u64,
        }

        #[derive(Debug, Clone, Serialize, Deserialize)]
        pub struct DeepbookPoolUpdated {
            pub pool_id: ObjectID,
            pub enabled: bool,
            pub timestamp: u64,
        }

        #[derive(Debug, Clone, Serialize, Deserialize)]
        pub struct DeepbookPoolConfigUpdated {
            pub pool_id: ObjectID,
            pub config: PoolConfig,
            pub timestamp: u64,
        }

        #[derive(Debug, Clone, Serialize, Deserialize)]
        pub struct PauseCapUpdated {
            pub pause_cap_id: ObjectID,
            pub allowed: bool,
            pub timestamp: u64,
        }

        impl MoveStruct for RiskRatios {
            const MODULE: &'static str = "margin_registry";
            const NAME: &'static str = "RiskRatios";
        }

        impl MoveStruct for PoolConfig {
            const MODULE: &'static str = "margin_registry";
            const NAME: &'static str = "PoolConfig";
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

        impl MoveStruct for PauseCapUpdated {
            const MODULE: &'static str = "margin_registry";
            const NAME: &'static str = "PauseCapUpdated";
        }
    }

    pub mod protocol_fees {
        use super::*;

        #[derive(Debug, Clone, Serialize, Deserialize)]
        pub struct ProtocolFeesIncreasedEvent {
            pub margin_pool_id: ObjectID,
            pub total_shares: u64,
            pub referral_fees: u64,
            pub maintainer_fees: u64,
            pub protocol_fees: u64,
        }

        #[derive(Debug, Clone, Serialize, Deserialize)]
        pub struct ReferralFeesClaimedEvent {
            pub referral_id: ObjectID,
            pub owner: Address,
            pub fees: u64,
        }

        impl MoveStruct for ProtocolFeesIncreasedEvent {
            const MODULE: &'static str = "protocol_fees";
            const NAME: &'static str = "ProtocolFeesIncreasedEvent";
        }

        impl MoveStruct for ReferralFeesClaimedEvent {
            const MODULE: &'static str = "protocol_fees";
            const NAME: &'static str = "ReferralFeesClaimedEvent";
        }
    }

    pub mod tpsl {
        use super::*;

        /// Condition for triggering a conditional order (take profit or stop loss)
        #[derive(Debug, Clone, Serialize, Deserialize)]
        pub struct Condition {
            pub trigger_below_price: bool,
            pub trigger_price: u64,
        }

        /// Pending order details that will be placed when the condition is met
        #[derive(Debug, Clone, Serialize, Deserialize)]
        pub struct PendingOrder {
            pub is_limit_order: bool,
            pub client_order_id: u64,
            pub order_type: Option<u8>,
            pub self_matching_option: u8,
            pub price: Option<u64>,
            pub quantity: u64,
            pub is_bid: bool,
            pub pay_with_deep: bool,
            pub expire_timestamp: Option<u64>,
        }

        /// Complete conditional order containing both condition and pending order
        #[derive(Debug, Clone, Serialize, Deserialize)]
        pub struct ConditionalOrder {
            pub conditional_order_id: u64,
            pub condition: Condition,
            pub pending_order: PendingOrder,
        }

        /// Emitted when a new conditional order (TPSL) is created
        #[derive(Debug, Clone, Serialize, Deserialize)]
        pub struct ConditionalOrderAdded {
            pub manager_id: ObjectID,
            pub conditional_order_id: u64,
            pub conditional_order: ConditionalOrder,
            pub timestamp: u64,
        }

        /// Emitted when a conditional order is cancelled
        #[derive(Debug, Clone, Serialize, Deserialize)]
        pub struct ConditionalOrderCancelled {
            pub manager_id: ObjectID,
            pub conditional_order_id: u64,
            pub conditional_order: ConditionalOrder,
            pub timestamp: u64,
        }

        /// Emitted when a conditional order is triggered and executed
        #[derive(Debug, Clone, Serialize, Deserialize)]
        pub struct ConditionalOrderExecuted {
            pub manager_id: ObjectID,
            pub pool_id: ObjectID,
            pub conditional_order_id: u64,
            pub conditional_order: ConditionalOrder,
            pub timestamp: u64,
        }

        /// Emitted when a conditional order fails due to insufficient funds
        #[derive(Debug, Clone, Serialize, Deserialize)]
        pub struct ConditionalOrderInsufficientFunds {
            pub manager_id: ObjectID,
            pub conditional_order_id: u64,
            pub conditional_order: ConditionalOrder,
            pub timestamp: u64,
        }

        impl MoveStruct for ConditionalOrderAdded {
            const MODULE: &'static str = "tpsl";
            const NAME: &'static str = "ConditionalOrderAdded";
        }

        impl MoveStruct for ConditionalOrderCancelled {
            const MODULE: &'static str = "tpsl";
            const NAME: &'static str = "ConditionalOrderCancelled";
        }

        impl MoveStruct for ConditionalOrderExecuted {
            const MODULE: &'static str = "tpsl";
            const NAME: &'static str = "ConditionalOrderExecuted";
        }

        impl MoveStruct for ConditionalOrderInsufficientFunds {
            const MODULE: &'static str = "tpsl";
            const NAME: &'static str = "ConditionalOrderInsufficientFunds";
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
