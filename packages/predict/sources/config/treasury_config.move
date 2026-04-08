// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

module deepbook_predict::treasury_config;

use std::type_name::{Self, TypeName};
use deepbook_predict::constants;
use sui::{coin_registry::Currency, vec_set::{Self, VecSet}};

const ECoinAlreadyAccepted: u64 = 0;
const EQuoteAssetNotAccepted: u64 = 1;
const EInvalidQuoteDecimals: u64 = 2;

public struct TreasuryConfig has copy, drop, store {
    /// Whitelisted quote asset types accepted for treasury flows
    accepted_quotes: VecSet<TypeName>,
}

public fun accepted_quotes(config: &TreasuryConfig): &VecSet<TypeName> {
    &config.accepted_quotes
}

public fun is_quote_asset<Quote>(config: &TreasuryConfig): bool {
    let quote_type = type_name::with_defining_ids<Quote>();
    config.accepted_quotes.contains(&quote_type)
}

public(package) fun new(): TreasuryConfig {
    TreasuryConfig {
        accepted_quotes: vec_set::empty(),
    }
}

public(package) fun add_quote_asset<Quote>(
    config: &mut TreasuryConfig,
    currency: &Currency<Quote>,
) {
    let quote_type = type_name::with_defining_ids<Quote>();
    assert!(currency.decimals() == constants::required_quote_decimals!(), EInvalidQuoteDecimals);
    assert!(!config.accepted_quotes.contains(&quote_type), ECoinAlreadyAccepted);
    config.accepted_quotes.insert(quote_type);
}

public(package) fun remove_quote_asset<Quote>(config: &mut TreasuryConfig) {
    let quote_type = type_name::with_defining_ids<Quote>();
    assert!(config.accepted_quotes.contains(&quote_type), EQuoteAssetNotAccepted);
    config.accepted_quotes.remove(&quote_type);
}

public(package) fun assert_quote_asset<Quote>(config: &TreasuryConfig) {
    assert!(config.is_quote_asset<Quote>(), EQuoteAssetNotAccepted);
}
