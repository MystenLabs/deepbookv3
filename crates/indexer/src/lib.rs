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
                DeepbookEnv::Mainnet => {
                    use models::deepbook::$($path)::+ as Event;
                    convert_struct_tag(Event::struct_type())
                },
                DeepbookEnv::Testnet => {
                    use models::deepbook_testnet::$($path)::+ as Event;
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
                DeepbookEnv::Mainnet => {
                    use models::deepbook::$($path)::+ as Event;
                    convert_struct_tag(<Event<$($phantom_type),+>>::struct_type())
                },
                DeepbookEnv::Testnet => {
                    use models::deepbook_testnet::$($path)::+ as Event;
                    convert_struct_tag(<Event<$($phantom_type),+>>::struct_type())
                }
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
                AccountAddress::new(*models::deepbook_testnet::registry::PACKAGE_ID.inner()),
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

        let (previous_packages, current_package) = match self {
            DeepbookEnv::Mainnet => (
                MAINNET_PREVIOUS_PACKAGES,
                AccountAddress::new(*models::deepbook::registry::PACKAGE_ID.inner()),
            ),
            DeepbookEnv::Testnet => (
                TESTNET_PREVIOUS_PACKAGES,
                AccountAddress::new(*models::deepbook_testnet::registry::PACKAGE_ID.inner()),
            ),
        };

        let mut addresses: Vec<AccountAddress> = previous_packages
            .iter()
            .map(|pkg| AccountAddress::from_str(pkg).unwrap())
            .collect();
        addresses.push(current_package);
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
}
