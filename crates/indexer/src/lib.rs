use crate::handlers::convert_struct_tag;
use move_core_types::language_storage::StructTag;
use move_types::MoveStruct;
use url::Url;

pub mod handlers;
pub(crate) mod models;

pub const MAINNET_REMOTE_STORE_URL: &str = "https://checkpoints.mainnet.sui.io";
pub const TESTNET_REMOTE_STORE_URL: &str = "https://checkpoints.testnet.sui.io";

// Previous package IDs for mainnet
const MAINNET_PREVIOUS_PACKAGES: &[&str] = &[
    "0x2c8d603bc51326b8c13cef9dd07031a408a48dddb541963357661df5d3204809",
    "0xcaf6ba059d539a97646d47f0b9ddf843e138d215e2a12ca1f4585d386f7aec3a",
];

// Previous package IDs for testnet (add when available)
const TESTNET_PREVIOUS_PACKAGES: &[&str] = &[];
const TESTNET_CURRENT_PACKAGE: &str =
    "0x16c4e050b9b19b25ce1365b96861bc50eb7e58383348a39ea8a8e1d063cfef73";

// Margin package IDs
const MAINNET_MARGIN_PACKAGE: &str =
    "0x0000000000000000000000000000000000000000000000000000000000000000"; // Not deployed yet
const TESTNET_MARGIN_PACKAGE: &str =
    "0x442d21fd044b90274934614c3c41416c83582f42eaa8feb4fecea301aa6bdd54";

#[derive(Debug, Clone, Copy, clap::ValueEnum)]
pub enum DeepbookEnv {
    Mainnet,
    Testnet,
}

/// Generates a function that returns the `StructTag` for a given event type,
/// switching between Mainnet and Testnet packages based on the `DeepbookEnv`.
///
/// # Arguments
///
/// * `fn_name` - The name of the function to generate.
/// * `path` - The path to the event type, relative to `models::deepbook` or `models::deepbook_testnet`.
///
/// # Example
///
/// ```rust
/// //impl DeepbookEnv {
/// //    event_type_fn!(balance_event_type, balance_manager::BalanceEvent);
/// //}
///
/// // Expands to:
/// //
/// // fn balance_event_type(&self) -> StructTag {
/// //     match self {
/// //         DeepbookEnv::Mainnet => {
/// //             use models::deepbook::balance_manager::BalanceEvent as Event;
/// //             convert_struct_tag(Event::struct_type())
/// //         },
/// //         DeepbookEnv::Testnet => {
/// //             use models::deepbook_testnet::balance_manager::BalanceEvent as Event;
/// //             convert_struct_tag(Event::struct_type())
/// //         }
/// //     }
/// // }
/// ```
///
macro_rules! event_type_fn {
    (
        $(#[$meta:meta])*
        $fn_name:ident, $($path:ident)::+
    ) => {
        $(#[$meta])*
        fn $fn_name(&self) -> StructTag {
            match self {
                _ => {
                    use models::deepbook::$($path)::+ as Event;
                    convert_struct_tag(Event::struct_type())
                }
            }
        }
    };
}

/// Generates a function that returns the `StructTag` for an event type with phantom type parameters.
/// This macro handles events with phantom types like DeepBurned<phantom BaseAsset, phantom QuoteAsset>.
/// Since phantom types don't affect BCS deserialization, any concrete type will work.
macro_rules! phantom_event_type_fn {
    (
        $(#[$meta:meta])*
        $fn_name:ident, $($path:ident)::+, $($phantom_type:ty),+
    ) => {
        $(#[$meta])*
        fn $fn_name(&self) -> StructTag {
            match self {
                _ => {
                    use models::deepbook::$($path)::+ as Event;
                    convert_struct_tag(<Event<$($phantom_type),+>>::struct_type())
                },
            }
        }
    };
}

// Default to <SUI, SUI> for the type parameters since they don't affect BCS deserialization
macro_rules! phantom_event_type_fn_2 {
    (
        $(#[$meta:meta])*
        $fn_name:ident, $($path:ident)::+
    ) => {
        phantom_event_type_fn!(
            $(#[$meta])*
            $fn_name, $($path)::+, models::sui::sui::SUI, models::sui::sui::SUI
        );
    };
}

impl DeepbookEnv {
    pub fn remote_store_url(&self) -> Url {
        let remote_store_url = match self {
            DeepbookEnv::Mainnet => MAINNET_REMOTE_STORE_URL,
            DeepbookEnv::Testnet => TESTNET_REMOTE_STORE_URL,
        };
        // Safe to unwrap on verified static URLs
        Url::parse(remote_store_url).unwrap()
    }

    pub fn package_ids(&self) -> Vec<sui_types::base_types::ObjectID> {
        use move_core_types::account_address::AccountAddress;
        use std::str::FromStr;
        use sui_types::base_types::ObjectID;

        let (previous_packages, current_package) = match self {
            DeepbookEnv::Mainnet => (
                MAINNET_PREVIOUS_PACKAGES,
                AccountAddress::new(*models::deepbook::registry::PACKAGE_ID.inner()),
            ),
            DeepbookEnv::Testnet => (
                TESTNET_PREVIOUS_PACKAGES,
                AccountAddress::from_str(TESTNET_CURRENT_PACKAGE).unwrap(),
            ),
        };

        let mut ids: Vec<ObjectID> = previous_packages
            .iter()
            .map(|pkg| ObjectID::from_str(pkg).unwrap())
            .collect();
        ids.push(ObjectID::from(current_package));
        ids
    }

    pub fn package_addresses(&self) -> Vec<move_core_types::account_address::AccountAddress> {
        use move_core_types::account_address::AccountAddress;
        use std::str::FromStr;

        let (previous_packages, current_package, margin_package) = match self {
            DeepbookEnv::Mainnet => (
                MAINNET_PREVIOUS_PACKAGES,
                AccountAddress::new(*models::deepbook::registry::PACKAGE_ID.inner()),
                AccountAddress::from_str(MAINNET_MARGIN_PACKAGE).unwrap(),
            ),
            DeepbookEnv::Testnet => (
                TESTNET_PREVIOUS_PACKAGES,
                AccountAddress::from_str(TESTNET_CURRENT_PACKAGE).unwrap(),
                AccountAddress::from_str(TESTNET_MARGIN_PACKAGE).unwrap(),
            ),
        };

        let mut addresses: Vec<AccountAddress> = previous_packages
            .iter()
            .map(|pkg| AccountAddress::from_str(pkg).unwrap())
            .collect();
        addresses.push(current_package);
        addresses.push(margin_package);
        addresses
    }

    event_type_fn!(balance_event_type, balance_manager::BalanceEvent);
    event_type_fn!(flash_loan_borrowed_event_type, vault::FlashLoanBorrowed);
    event_type_fn!(order_filled_event_type, order_info::OrderFilled);
    event_type_fn!(order_placed_event_type, order_info::OrderPlaced);
    event_type_fn!(order_modified_event_type, order::OrderModified);
    event_type_fn!(order_canceled_event_type, order::OrderCanceled);
    event_type_fn!(order_expired_event_type, order_info::OrderExpired);
    event_type_fn!(vote_event_type, state::VoteEvent);
    event_type_fn!(
        trade_params_update_event_type,
        governance::TradeParamsUpdateEvent
    );
    event_type_fn!(stake_event_type, state::StakeEvent);
    event_type_fn!(rebate_event_type, state::RebateEvent);
    event_type_fn!(proposal_event_type, state::ProposalEvent);
    event_type_fn!(price_added_event_type, deep_price::PriceAdded);
    phantom_event_type_fn_2!(deep_burned_event_type, pool::DeepBurned);

    // Margin Pool Operations Events
    event_type_fn!(asset_supplied_event_type, margin_pool::AssetSupplied);
    event_type_fn!(asset_withdrawn_event_type, margin_pool::AssetWithdrawn);

    // Margin Manager Operations Events
    event_type_fn!(
        margin_manager_event_type,
        margin_manager::MarginManagerEvent
    );
    event_type_fn!(loan_borrowed_event_type, margin_manager::LoanBorrowedEvent);
    event_type_fn!(loan_repaid_event_type, margin_manager::LoanRepaidEvent);
    event_type_fn!(liquidation_event_type, margin_manager::LiquidationEvent);

    // Margin Pool Admin Events
    event_type_fn!(
        margin_pool_created_event_type,
        margin_pool::MarginPoolCreated
    );
    event_type_fn!(
        deepbook_pool_updated_event_type,
        margin_pool::DeepbookPoolUpdated
    );
    event_type_fn!(
        interest_params_updated_event_type,
        margin_pool::InterestParamsUpdated
    );
    event_type_fn!(
        margin_pool_config_updated_event_type,
        margin_pool::MarginPoolConfigUpdated
    );

    // Margin Fee Events
    event_type_fn!(
        maintainer_fees_withdrawn_event_type,
        margin_pool::MaintainerFeesWithdrawn
    );
    event_type_fn!(
        protocol_fees_withdrawn_event_type,
        margin_pool::ProtocolFeesWithdrawn
    );
    event_type_fn!(
        referral_fees_claimed_event_type,
        referral_fees::ReferralFeesClaimedEvent
    );
    event_type_fn!(
        protocol_fees_increased_event_type,
        referral_fees::ProtocolFeesIncreasedEvent
    );

    // Margin Registry Events
    event_type_fn!(
        maintainer_cap_updated_event_type,
        margin_registry::MaintainerCapUpdated
    );
    event_type_fn!(
        deepbook_pool_registered_event_type,
        margin_registry::DeepbookPoolRegistered
    );
    event_type_fn!(
        deepbook_pool_updated_event_type,
        margin_registry::DeepbookPoolUpdated
    );
    event_type_fn!(
        deepbook_pool_config_updated_event_type,
        margin_registry::DeepbookPoolConfigUpdated
    );
}
