// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

use std::collections::HashMap;

/// Configuration for the Slush DeFi Quickstart Provider API.
#[derive(Debug, Clone)]
pub struct SlushConfig {
    /// The object ID of the MarginRegistry shared object.
    pub margin_registry_id: String,
    /// The package ID of the margin module.
    pub margin_package_id: String,
    /// Maps margin_pool_id → Abyss vault address for APY lookups.
    pub vault_mapping: HashMap<String, String>,
}

impl SlushConfig {
    pub fn new(
        margin_registry_id: String,
        margin_package_id: String,
        vault_mapping_json: Option<String>,
    ) -> Self {
        let vault_mapping = vault_mapping_json
            .and_then(|json| serde_json::from_str::<HashMap<String, String>>(&json).ok())
            .unwrap_or_default();
        Self {
            margin_registry_id,
            margin_package_id,
            vault_mapping,
        }
    }
}
