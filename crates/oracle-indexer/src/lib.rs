use url::Url;

pub mod handlers;
pub mod materialized_view_refresh;
pub mod meta;
pub mod models;
pub mod traits;

pub const MAINNET_REMOTE_STORE_URL: &str = "https://checkpoints.mainnet.sui.io";
pub const TESTNET_REMOTE_STORE_URL: &str = "https://checkpoints.testnet.sui.io";

// Propbook package addresses for different environments. The oracle events live
// in the standalone `propbook` package, indexed by this separate process into
// the shared predict DB.
// TODO(testnet-deploy): set Propbook package address once Propbook is deployed.
const PROPBOOK_PACKAGES_TESTNET: &[&str] = &[];
const PROPBOOK_PACKAGES_MAINNET: &[&str] = &[];

/// The Propbook event modules recognized for address resolution. The oracle
/// lane emits the observation events (`oracle_lane`) and the registry emits the
/// source/binding events (`registry`).
pub const ORACLE_MODULES: &[&str] = &["registry", "oracle_lane"];

/// Enum representing different module types.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ModuleType {
    Oracle,
    Unknown,
}

/// Check if a module is a Propbook oracle module.
pub fn is_oracle_module(module: &str) -> bool {
    ORACLE_MODULES.contains(&module)
}

/// Get the module type (oracle or unknown).
pub fn get_module_type(module: &str) -> ModuleType {
    if is_oracle_module(module) {
        ModuleType::Oracle
    } else {
        ModuleType::Unknown
    }
}

#[derive(Debug, Clone, Copy, clap::ValueEnum)]
pub enum OracleEnv {
    Mainnet,
    Testnet,
}

impl OracleEnv {
    pub fn remote_store_url(&self) -> Url {
        let url = match self {
            OracleEnv::Mainnet => MAINNET_REMOTE_STORE_URL,
            OracleEnv::Testnet => TESTNET_REMOTE_STORE_URL,
        };
        Url::parse(url).unwrap()
    }

    /// Get all Propbook package address strings for this environment.
    ///
    /// Panics if the address is unset so we never boot a no-op indexer that
    /// silently indexes nothing.
    fn get_all_package_strings(&self) -> Vec<&'static str> {
        let raw = match self {
            OracleEnv::Mainnet => PROPBOOK_PACKAGES_MAINNET,
            OracleEnv::Testnet => PROPBOOK_PACKAGES_TESTNET,
        };
        assert!(
            !raw.is_empty(),
            "Propbook package address is unset for {self:?} — fill PROPBOOK_PACKAGES_* \
            (TODO(testnet-deploy): set Propbook package address)."
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
