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

public struct ConversionConfig has copy, drop {
    target_decimals: u8,
    base_decimals: u8,
    pyth_price: u64,
    pyth_decimals: u8,
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
    price_info_object: &PriceInfoObject,
    registry: &MarginRegistry,
    amount: u64,
    clock: &Clock,
): u64 {
    let config = price_config<T>(
        price_info_object,
        registry,
        true,
        clock,
    );

    config.calculate_usd_currency_amount(
        amount,
    )
}

public(package) fun calculate_usd_currency_amount(
    config: ConversionConfig,
    base_currency_amount: u64,
): u64 {
    assert!(config.pyth_price > 0, EInvalidPythPrice);
    let exponent_with_buffer = BUFFER + config.base_decimals - config.target_decimals;

    let target_currency_amount =
        (
            ((base_currency_amount as u128) * (config.pyth_price as u128)).divide_and_round_up(
                10u128.pow(
                    config.pyth_decimals,
                )) * (10u128.pow(BUFFER)),
        ).divide_and_round_up(10u128.pow(
            exponent_with_buffer,
        )) as u64;

    target_currency_amount
}

/// Calculates the amount in target currency based on usd amount
public(package) fun calculate_target_amount<T>(
    price_info_object: &PriceInfoObject,
    registry: &MarginRegistry,
    usd_amount: u64,
    clock: &Clock,
): u64 {
    let config = price_config<T>(
        price_info_object,
        registry,
        false,
        clock,
    );

    calculate_target_currency_amount(
        config,
        usd_amount,
    )
}

public(package) fun calculate_target_currency_amount(
    config: ConversionConfig,
    base_currency_amount: u64,
): u64 {
    assert!(config.pyth_price > 0, EInvalidPythPrice);

    // We use a buffer in the edge case where target_decimals + pyth_decimals <
    // base_decimals
    let exponent_with_buffer =
        BUFFER + config.target_decimals + config.pyth_decimals - config.base_decimals;

    // We cast to u128 to avoid overflow, which is very likely with the buffer
    let target_currency_amount =
        (base_currency_amount as u128 * 10u128.pow(exponent_with_buffer))
            .divide_and_round_up(config.pyth_price as u128)
            .divide_and_round_up(10u128.pow(BUFFER)) as u64;

    target_currency_amount
}

fun price_config<T>(
    price_info_object: &PriceInfoObject,
    registry: &MarginRegistry,
    is_usd_price_config: bool,
    clock: &Clock,
): ConversionConfig {
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

    let target_decimals = if (is_usd_price_config) {
        9
    } else {
        type_config.decimals
    }; // Our target decimals
    let base_decimals = if (is_usd_price_config) {
        type_config.decimals
    } else {
        9
    }; // Our starting decimals
    let pyth_price = price.get_price().get_magnitude_if_positive();
    let pyth_decimals = price.get_expo().get_magnitude_if_negative() as u8;

    ConversionConfig {
        target_decimals,
        base_decimals,
        pyth_price,
        pyth_decimals,
    }
}

/// Gets the configuration for a given currency type.
fun get_config_for_type<T>(registry: &MarginRegistry): CoinTypeData {
    let config = registry.get_config<PythConfig>();
    let payment_type = type_name::get<T>();
    assert!(config.currencies.contains(&payment_type), ECurrencyNotSupported);
    *config.currencies.get(&payment_type)
}

#[test_only]
public fun test_conversion_config(
    target_decimals: u8,
    base_decimals: u8,
    pyth_price: u64,
    pyth_decimals: u8,
): ConversionConfig {
    ConversionConfig {
        target_decimals,
        base_decimals,
        pyth_price,
        pyth_decimals,
    }
}

#[test_only]
/// Create a test CoinTypeData for testing without needing CoinMetadata
public fun test_coin_type_data<T>(decimals: u8, price_feed_id: vector<u8>): CoinTypeData {
    CoinTypeData {
        decimals,
        price_feed_id,
        type_name: type_name::get<T>(),
    }
}
