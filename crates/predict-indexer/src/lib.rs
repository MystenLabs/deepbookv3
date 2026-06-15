use url::Url;

pub mod handlers;
pub mod materialized_view_refresh;
pub mod meta;
pub mod models;
pub mod order_id;
pub mod traits;

pub const MAINNET_REMOTE_STORE_URL: &str = "https://checkpoints.mainnet.sui.io";
pub const TESTNET_REMOTE_STORE_URL: &str = "https://checkpoints.testnet.sui.io";

// Predict package addresses for different environments.
// TODO(testnet-deploy): set Predict package address once Predict is deployed.
const PREDICT_PACKAGES_TESTNET: &[&str] = &[];
const PREDICT_PACKAGES_MAINNET: &[&str] = &[];

/// The Predict event modules recognized for address resolution. Oracle events
/// are emitted by the standalone `propbook` package and indexed by the separate
/// `oracle-indexer` crate, so they are intentionally not listed here.
pub const PREDICT_MODULES: &[&str] = &[
    "order_events",
    "account_events",
    "config_events",
    "vault_events",
];

/// Enum representing different module types.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ModuleType {
    Predict,
    Unknown,
}

/// Check if a module is a Predict module.
pub fn is_predict_module(module: &str) -> bool {
    PREDICT_MODULES.contains(&module)
}

/// Get the module type (predict or unknown).
pub fn get_module_type(module: &str) -> ModuleType {
    if is_predict_module(module) {
        ModuleType::Predict
    } else {
        ModuleType::Unknown
    }
}

#[derive(Debug, Clone, Copy, clap::ValueEnum)]
pub enum PredictEnv {
    Mainnet,
    Testnet,
}

impl PredictEnv {
    pub fn remote_store_url(&self) -> Url {
        let url = match self {
            PredictEnv::Mainnet => MAINNET_REMOTE_STORE_URL,
            PredictEnv::Testnet => TESTNET_REMOTE_STORE_URL,
        };
        Url::parse(url).unwrap()
    }

    /// Get all Predict package address strings for this environment.
    ///
    /// Panics if the address is unset so we never boot a no-op indexer that
    /// silently indexes nothing.
    fn get_all_package_strings(&self) -> Vec<&'static str> {
        let raw = match self {
            PredictEnv::Mainnet => PREDICT_PACKAGES_MAINNET,
            PredictEnv::Testnet => PREDICT_PACKAGES_TESTNET,
        };
        assert!(
            !raw.is_empty(),
            "Predict package address is unset for {self:?} — fill PREDICT_PACKAGES_* \
            (TODO(testnet-deploy): set Predict package address)."
        );
        raw.to_vec()
    }

    pub fn package_ids(&self) -> Vec<sui_types::base_types::ObjectID> {
        use std::str::FromStr;
        use sui_types::base_types::ObjectID;

        self.get_all_package_strings()
            .iter()
            .map(|pkg| ObjectID::from_str(pkg).unwrap())
            .collect()
    }

    pub fn package_addresses(&self) -> Vec<move_core_types::account_address::AccountAddress> {
        use move_core_types::account_address::AccountAddress;
        use std::str::FromStr;

        self.get_all_package_strings()
            .iter()
            .map(|pkg| AccountAddress::from_str(pkg).unwrap())
            .collect()
    }
}
