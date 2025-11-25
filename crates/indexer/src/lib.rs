use url::Url;

pub mod handlers;
pub(crate) mod models;
pub mod traits;

pub const NOT_MAINNET_PACKAGE: &str = "<not on mainnet>";

pub const MAINNET_REMOTE_STORE_URL: &str = "https://checkpoints.mainnet.sui.io";
pub const TESTNET_REMOTE_STORE_URL: &str = "https://checkpoints.testnet.sui.io";

// Package addresses for different environments
const MAINNET_PACKAGES: &[&str] = &[
    "0xb29d83c26cdd2a64959263abbcfc4a6937f0c9fccaf98580ca56faded65be244",
    "0x2c8d603bc51326b8c13cef9dd07031a408a48dddb541963357661df5d3204809",
    "0xcaf6ba059d539a97646d47f0b9ddf843e138d215e2a12ca1f4585d386f7aec3a",
];

const TESTNET_PACKAGES: &[&str] = &[
    "0x467e34e75debeea8b89d03aea15755373afc39a7c96c9959549c7f5f689843cf",
    "0x5d520a3e3059b68530b2ef4080126dbb5d234e0afd66561d0d9bd48127a06044",
    "0xcd40faffa91c00ce019bfe4a4b46f8d623e20bf331eb28990ee0305e9b9f3e3c",
    "0x16c4e050b9b19b25ce1365b96861bc50eb7e58383348a39ea8a8e1d063cfef73",
    "0xc483dba510597205749f2e8410c23f19be31a710aef251f353bc1b97755efd4d",
    "0x5da5bbf6fb097d108eaf2c2306f88beae4014c90a44b95c7e76a6bfccec5f5ee",
    "0xa3886aaa8aa831572dd39549242ca004a438c3a55967af9f0387ad2b01595068",
    "0x9592ac923593f37f4fed15ee15f760ebd4c39729f53ee3e8c214de7a17157769",
    "0x984757fc7c0e6dd5f15c2c66e881dd6e5aca98b725f3dbd83c445e057ebb790a",
    "0xfb28c4cbc6865bd1c897d26aecbe1f8792d1509a20ffec692c800660cbec6982",
];

// Mainnet margin package is not yet deployed - using placeholder
// This will cause the indexer to fail fast if margin modules are requested on mainnet
// When the margin package is deployed on mainnet, replace this with the actual address
const MAINNET_MARGIN_PACKAGES: &[&str] = &[NOT_MAINNET_PACKAGE];
const TESTNET_MARGIN_PACKAGES: &[&str] = &[
    "0x3f44af8fcef3cd753a221a4f25a61d2d6c74b4ca0b6809f6e670764b9debf08a",
    "0x8fe69c287d99f8873d5080bf74aec39c4b79536cdbbe260bf43a1b46fd553be0",
    "0x442d21fd044b90274934614c3c41416c83582f42eaa8feb4fecea301aa6bdd54",
    "0xf74ec503c186327663e11b5b888bd8a654bb8afaba34342274d3172edf3abeef",
    "0xb388009b59b09cd5d219dae79dd3e5d08a5734884363e59a37f3cbe6ef613424",
];

// Module definitions
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
pub const MARGIN_MODULES: &[&str] = &[
    "margin_manager",
    "margin_pool",
    "margin_registry",
    "protocol_fees",
];

/// SUI system modules
pub const SUI_MODULES: &[&str] = &["sui"];

/// Enum representing different module types
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ModuleType {
    Core,
    Margin,
    Sui,
    Unknown,
}

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

/// Check if a margin package address is valid
pub fn is_valid_margin_package(package: &str) -> bool {
    package != NOT_MAINNET_PACKAGE
}

/// Check if any margin package addresses are valid for the given environment
pub fn is_valid_margin_packages(packages: &[&str]) -> bool {
    packages.iter().any(|&pkg| is_valid_margin_package(pkg))
}

/// Check if margin trading is supported in the given environment
pub fn is_margin_supported(env: DeepbookEnv) -> bool {
    match env {
        DeepbookEnv::Mainnet => is_valid_margin_packages(MAINNET_MARGIN_PACKAGES),
        DeepbookEnv::Testnet => is_valid_margin_packages(TESTNET_MARGIN_PACKAGES),
    }
}

/// Get the margin package addresses for the given environment
pub fn get_margin_package_addresses(env: DeepbookEnv) -> &'static [&'static str] {
    match env {
        DeepbookEnv::Mainnet => MAINNET_MARGIN_PACKAGES,
        DeepbookEnv::Testnet => TESTNET_MARGIN_PACKAGES,
    }
}

/// Get the first valid margin package address for the given environment with validation
pub fn get_margin_package_address(env: DeepbookEnv) -> Result<&'static str, String> {
    let packages = get_margin_package_addresses(env);

    // Find the first valid package
    for &package in packages {
        if is_valid_margin_package(package) {
            return Ok(package);
        }
    }

    Err(format!(
        "Margin trading is not supported on {:?}. \
        The margin package has not been deployed on this network.",
        env
    ))
}

/// Get all core package addresses for the given environment
pub fn get_core_package_addresses(env: DeepbookEnv) -> &'static [&'static str] {
    match env {
        DeepbookEnv::Mainnet => MAINNET_PACKAGES,
        DeepbookEnv::Testnet => TESTNET_PACKAGES,
    }
}

#[derive(Debug, Clone, Copy, clap::ValueEnum)]
pub enum DeepbookEnv {
    Mainnet,
    Testnet,
}

impl DeepbookEnv {
    pub fn remote_store_url(&self) -> Url {
        let url = match self {
            DeepbookEnv::Mainnet => MAINNET_REMOTE_STORE_URL,
            DeepbookEnv::Testnet => TESTNET_REMOTE_STORE_URL,
        };
        Url::parse(url).unwrap()
    }

    /// Get all package addresses (DeepBook + Margin) for this environment
    fn get_all_package_strings(&self) -> Vec<&str> {
        let (packages, margin_packages) = match self {
            DeepbookEnv::Mainnet => (MAINNET_PACKAGES, MAINNET_MARGIN_PACKAGES),
            DeepbookEnv::Testnet => (TESTNET_PACKAGES, TESTNET_MARGIN_PACKAGES),
        };

        let mut all_packages = packages.to_vec();

        // Add margin packages if they're not invalid
        for &margin_package in margin_packages {
            if margin_package != NOT_MAINNET_PACKAGE {
                all_packages.push(margin_package);
            }
        }

        all_packages
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
