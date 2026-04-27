// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Treasury configuration for accepted quote assets.
///
/// This module owns the whitelist of quote asset types that can be used for
/// new Predict treasury inflows and validates each asset's decimal precision
/// before it is enabled.
module deepbook_predict::treasury_config;

use deepbook_predict::constants;
use std::type_name::{Self, TypeName};
use sui::{coin_registry::Currency, vec_set::{Self, VecSet}};

const ECoinAlreadyAccepted: u64 = 0;
const EQuoteAssetNotAccepted: u64 = 1;
const EInvalidQuoteDecimals: u64 = 2;

/// Quote-asset whitelist state.
public struct TreasuryConfig has copy, drop, store {
    /// Quote asset types currently enabled for new treasury inflows
    accepted_quotes: VecSet<TypeName>,
}

// === Public Functions ===

/// Return the accepted quote asset type set.
public fun accepted_quotes(config: &TreasuryConfig): &VecSet<TypeName> {
    &config.accepted_quotes
}

/// Return whether `Quote` is accepted for new treasury inflows.
public fun is_quote_asset<Quote>(config: &TreasuryConfig): bool {
    let quote_type = type_name::with_defining_ids<Quote>();
    config.accepted_quotes.contains(&quote_type)
}

// === Public-Package Functions ===

/// Create an empty treasury config.
public(package) fun new(): TreasuryConfig {
    TreasuryConfig {
        accepted_quotes: vec_set::empty(),
    }
}

/// Add a quote asset after validating its decimal precision.
public(package) fun add_quote_asset<Quote>(
    config: &mut TreasuryConfig,
    currency: &Currency<Quote>,
) {
    let quote_type = type_name::with_defining_ids<Quote>();
    assert!(currency.decimals() == constants::required_quote_decimals!(), EInvalidQuoteDecimals);
    assert!(!config.accepted_quotes.contains(&quote_type), ECoinAlreadyAccepted);
    config.accepted_quotes.insert(quote_type);
}

/// Remove a quote asset from the accepted set.
public(package) fun remove_quote_asset<Quote>(config: &mut TreasuryConfig) {
    let quote_type = type_name::with_defining_ids<Quote>();
    assert!(config.accepted_quotes.contains(&quote_type), EQuoteAssetNotAccepted);
    config.accepted_quotes.remove(&quote_type);
}

/// Abort unless `Quote` is currently accepted.
public(package) fun assert_quote_asset<Quote>(config: &TreasuryConfig) {
    assert!(config.is_quote_asset<Quote>(), EQuoteAssetNotAccepted);
}
