// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

module margin_trading::oracle;

use margin_trading::margin_registry::MarginRegistry;
use pyth::{price_info::PriceInfoObject, pyth};
use std::type_name::{Self, TypeName};
use sui::{clock::Clock, coin::CoinMetadata, vec_map::{Self, VecMap}};

use fun get_config_for_type as MarginRegistry.get_config_for_type;

const EInvalidPythPrice: u64 = 1;
const ECurrencyNotSupported: u64 = 2;
const EPriceFeedIdMismatch: u64 = 3;

/// A buffer added to the exponent when doing currency conversions.
const BUFFER: u8 = 10;

/// Holds a VecMap that determines the configuration for each currency.
public struct PythConfig has drop, store {
    currencies: VecMap<TypeName, CoinTypeData>,
    max_age_secs: u64, // max age tolerance for pyth prices in seconds
}

/// Find price feed IDs here https://www.pyth.network/developers/price-feed-ids
public struct CoinTypeData has copy, drop, store {
    decimals: u8,
    price_feed_id: vector<u8>, // Make sure to omit the `0x` prefix.
    type_name: TypeName,
}

/// Creates a new CoinTypeData struct of type T.
/// Uses CoinMetadata to avoid any errors in decimals.
public fun new_coin_type_data<T>(
    coin_metadata: &CoinMetadata<T>,
    price_feed_id: vector<u8>,
): CoinTypeData {
    let type_name = type_name::get<T>();
    CoinTypeData {
        decimals: coin_metadata.get_decimals(),
        price_feed_id,
        type_name,
    }
}

/// Creates a new PythConfig struct.
/// Can be attached by the Admin to MarginRegistry to allow oracle to work.
public fun new_pyth_config(setups: vector<CoinTypeData>, max_age_secs: u64): PythConfig {
    let mut currencies: VecMap<TypeName, CoinTypeData> = vec_map::empty();

    setups.do!(|coin_type| {
        currencies.insert(coin_type.type_name, coin_type);
    });

    PythConfig {
        currencies,
        max_age_secs,
    }
}

/// Calculates the USD price of a given asset or debt amount.
/// 9 decimals are used for USD representation.
public(package) fun calculate_usd_price<T>(
    registry: &MarginRegistry,
    base_debt: u64,
    base_asset: u64,
    clock: &Clock,
    price_info_object: &PriceInfoObject,
): (u64, u64) {
    let config = registry.get_config<PythConfig>();
    let type_config = registry.get_config_for_type<T>();

    let price = pyth::get_price_no_older_than(
        price_info_object,
        clock,
        config.max_age_secs,
    );
    let price_info = price_info_object.get_price_info_from_price_info_object();

    // verify that the price feed id matches the one we have in our config.
    assert!(
        price_info.get_price_identifier().get_bytes() == type_config.price_feed_id,
        EPriceFeedIdMismatch,
    );

    let target_decimals = 9; // We're representing USD in 9 decimals
    let base_decimals = type_config.decimals; // number of decimals for the asset we're converting from
    let pyth_decimals = price.get_expo().get_magnitude_if_negative() as u8;
    let pyth_price = price.get_price().get_magnitude_if_positive();

    (
        calculate_target_currency_amount(
            base_debt,
            target_decimals,
            base_decimals,
            pyth_price,
            pyth_decimals,
        ),
        calculate_target_currency_amount(
            base_asset,
            target_decimals,
            base_decimals,
            pyth_price,
            pyth_decimals,
        ),
    )
}

public(package) fun calculate_target_currency_amount(
    base_currency_amount: u64,
    target_decimals: u8,
    base_decimals: u8,
    pyth_price: u64,
    pyth_decimals: u8,
): u64 {
    assert!(pyth_price > 0, EInvalidPythPrice);
    let exponent_with_buffer = BUFFER + base_decimals - target_decimals;

    let target_currency_amount =
        (
            ((base_currency_amount as u128) * (pyth_price as u128)).divide_and_round_up(
                10u128.pow(
            pyth_decimals,
        )) * (10u128.pow(BUFFER)),
        ).divide_and_round_up(10u128.pow(
            exponent_with_buffer,
        )) as u64;

    target_currency_amount
}

/// Gets the configuration for a given currency type.
fun get_config_for_type<T>(registry: &MarginRegistry): CoinTypeData {
    let config = registry.get_config<PythConfig>();
    let payment_type = type_name::get<T>();
    assert!(config.currencies.contains(&payment_type), ECurrencyNotSupported);
    *config.currencies.get(&payment_type)
}
