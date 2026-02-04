// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Oracle module for margin trading.
module deepbook_margin::oracle;

use deepbook::{constants, math};
use deepbook_margin::{margin_constants, margin_registry::MarginRegistry};
use pyth::{price_info::PriceInfoObject, pyth};
use std::type_name::{Self, TypeName};
use sui::{clock::Clock, coin_registry::Currency, vec_map::{Self, VecMap}};

use fun get_config_for_type as MarginRegistry.get_config_for_type;

const EInvalidPythPrice: u64 = 1;
const ECurrencyNotSupported: u64 = 2;
const EPriceFeedIdMismatch: u64 = 3;
const EInvalidPythPriceConf: u64 = 4;
const EInvalidOracleConfig: u64 = 5;
const EInvalidPrice: u64 = 6;

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
    max_conf_bps: u64, // max confidence interval tolerance
    max_ewma_difference_bps: u64, // max difference between pyth price and ema price in bps
}

public struct ConversionConfig has copy, drop {
    target_decimals: u8,
    base_decimals: u8,
    pyth_price: u64,
    pyth_decimals: u8,
}

/// Creates a new CoinTypeData struct of type T.
/// Uses Currency to avoid any errors in decimals.
public fun new_coin_type_data_from_currency<T>(
    currency: &Currency<T>,
    price_feed_id: vector<u8>,
    max_conf_bps: u64,
    max_ewma_difference_bps: u64,
): CoinTypeData {
    // Validate oracle configuration parameters
    assert!(max_conf_bps <= margin_constants::max_conf_bps(), EInvalidOracleConfig);
    assert!(
        max_ewma_difference_bps <= margin_constants::max_ewma_difference_bps(),
        EInvalidOracleConfig,
    );

    let type_name = type_name::with_defining_ids<T>();
    CoinTypeData {
        decimals: currency.decimals(),
        price_feed_id,
        type_name,
        max_conf_bps,
        max_ewma_difference_bps,
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

/// Calculates the price of BaseAsset in QuoteAsset.
/// Returns the price accounting for the decimal difference between the two assets.
public(package) fun calculate_price<BaseAsset, QuoteAsset>(
    registry: &MarginRegistry,
    base_price_info_object: &PriceInfoObject,
    quote_price_info_object: &PriceInfoObject,
    clock: &Clock,
): u64 {
    let base_decimals = get_decimals<BaseAsset>(registry);
    let quote_decimals = get_decimals<QuoteAsset>(registry);

    let base_amount = 10u64.pow(base_decimals);
    let base_usd_price = calculate_usd_price<BaseAsset>(
        base_price_info_object,
        registry,
        base_amount,
        clock,
    );

    let quote_amount = 10u64.pow(quote_decimals);
    let quote_usd_price = calculate_usd_price<QuoteAsset>(
        quote_price_info_object,
        registry,
        quote_amount,
        clock,
    );
    let price_ratio = math::div(base_usd_price, quote_usd_price);

    if (base_decimals > quote_decimals) {
        let decimal_diff = base_decimals - quote_decimals;
        let divisor = 10u128.pow(decimal_diff);
        let price = (price_ratio as u128) / divisor;
        assert!(price <= constants::max_price() as u128, EInvalidPrice);

        price as u64
    } else if (quote_decimals > base_decimals) {
        let decimal_diff = quote_decimals - base_decimals;
        let multiplier = 10u128.pow(decimal_diff);
        let price = (price_ratio as u128) * multiplier;
        assert!(price <= constants::max_price() as u128, EInvalidPrice);

        price as u64
    } else {
        price_ratio
    }
}

/// Calculates the amount in target currency based on amount in asset A.
public(package) fun calculate_target_currency<AssetA, AssetB>(
    registry: &MarginRegistry,
    price_info_object_a: &PriceInfoObject,
    price_info_object_b: &PriceInfoObject,
    amount: u64,
    clock: &Clock,
): u64 {
    let usd_value = calculate_usd_price<AssetA>(
        price_info_object_a,
        registry,
        amount,
        clock,
    );
    let target_value = calculate_target_amount<AssetB>(
        price_info_object_b,
        registry,
        usd_value,
        clock,
    );

    target_value
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

public(package) fun calculate_usd_price_unsafe<T>(
    price_info_object: &PriceInfoObject,
    registry: &MarginRegistry,
    amount: u64,
): u64 {
    let config = price_config_unsafe<T>(price_info_object, registry, true);
    config.calculate_usd_currency_amount(amount)
}

public(package) fun calculate_price_unsafe<BaseAsset, QuoteAsset>(
    registry: &MarginRegistry,
    base_price_info_object: &PriceInfoObject,
    quote_price_info_object: &PriceInfoObject,
): u64 {
    let base_decimals = get_decimals<BaseAsset>(registry);
    let quote_decimals = get_decimals<QuoteAsset>(registry);

    let base_amount = 10u64.pow(base_decimals);
    let base_usd_price = calculate_usd_price_unsafe<BaseAsset>(
        base_price_info_object,
        registry,
        base_amount,
    );

    let quote_amount = 10u64.pow(quote_decimals);
    let quote_usd_price = calculate_usd_price_unsafe<QuoteAsset>(
        quote_price_info_object,
        registry,
        quote_amount,
    );
    let price_ratio = math::div(base_usd_price, quote_usd_price);

    if (base_decimals > quote_decimals) {
        let decimal_diff = base_decimals - quote_decimals;
        let divisor = 10u128.pow(decimal_diff);
        let price = (price_ratio as u128) / divisor;
        assert!(price <= constants::max_price() as u128, EInvalidPrice);
        price as u64
    } else if (quote_decimals > base_decimals) {
        let decimal_diff = quote_decimals - base_decimals;
        let multiplier = 10u128.pow(decimal_diff);
        let price = (price_ratio as u128) * multiplier;
        assert!(price <= constants::max_price() as u128, EInvalidPrice);
        price as u64
    } else {
        price_ratio
    }
}

public(package) fun calculate_target_currency_unsafe<AssetA, AssetB>(
    registry: &MarginRegistry,
    price_info_object_a: &PriceInfoObject,
    price_info_object_b: &PriceInfoObject,
    amount: u64,
): u64 {
    let usd_value = calculate_usd_price_unsafe<AssetA>(price_info_object_a, registry, amount);
    let target_value = calculate_target_amount_unsafe<AssetB>(
        price_info_object_b,
        registry,
        usd_value,
    );
    target_value
}

public(package) fun calculate_target_amount_unsafe<T>(
    price_info_object: &PriceInfoObject,
    registry: &MarginRegistry,
    usd_amount: u64,
): u64 {
    let config = price_config_unsafe<T>(price_info_object, registry, false);
    calculate_target_currency_amount(config, usd_amount)
}

fun price_config<T>(
    price_info_object: &PriceInfoObject,
    registry: &MarginRegistry,
    is_usd_price_config: bool,
    clock: &Clock,
): ConversionConfig {
    let (pyth_price, pyth_decimals, pyth_conf, type_config) = get_validated_pyth_price<T>(
        price_info_object,
        registry,
        clock,
    );

    assert!(
        (pyth_conf as u128) * 10_000 <= (type_config.max_conf_bps as u128) * (pyth_price as u128),
        EInvalidPythPriceConf,
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

    ConversionConfig {
        target_decimals,
        base_decimals,
        pyth_price,
        pyth_decimals,
    }
}

fun price_config_unsafe<T>(
    price_info_object: &PriceInfoObject,
    registry: &MarginRegistry,
    is_usd_price_config: bool,
): ConversionConfig {
    let (pyth_price, pyth_decimals) = get_pyth_price_unsafe<T>(
        price_info_object,
        registry,
    );
    let type_config = registry.get_config_for_type<T>();

    let target_decimals = if (is_usd_price_config) {
        9
    } else {
        type_config.decimals
    };
    let base_decimals = if (is_usd_price_config) {
        type_config.decimals
    } else {
        9
    };

    ConversionConfig {
        target_decimals,
        base_decimals,
        pyth_price,
        pyth_decimals,
    }
}

/// Gets the raw Pyth price for a given asset
/// Returns (pyth_price, pyth_decimals)
public(package) fun get_pyth_price<T>(
    price_info_object: &PriceInfoObject,
    registry: &MarginRegistry,
    clock: &Clock,
): (u64, u8) {
    let (pyth_price, pyth_decimals, _, _) = get_validated_pyth_price<T>(
        price_info_object,
        registry,
        clock,
    );

    (pyth_price, pyth_decimals)
}

/// Helper function to get and validate Pyth price data
/// Returns (pyth_price, pyth_decimals, pyth_conf, type_config)
fun get_validated_pyth_price<T>(
    price_info_object: &PriceInfoObject,
    registry: &MarginRegistry,
    clock: &Clock,
): (u64, u8, u64, CoinTypeData) {
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

    let pyth_price = price.get_price().get_magnitude_if_positive();
    let pyth_decimals = price.get_expo().get_magnitude_if_negative() as u8;
    let pyth_conf = price.get_conf();

    // verify that the ewma price is not too different from the pyth price
    let ewma_price_object = price_info.get_price_feed().get_ema_price();
    let ewma_price = ewma_price_object.get_price().get_magnitude_if_positive();
    assert!(
        (pyth_price as u128) * 10_000 <= (ewma_price as u128) * ((10_000 + type_config.max_ewma_difference_bps) as u128) &&
        (pyth_price as u128) * 10_000 >= (ewma_price as u128) * ((10_000 - type_config.max_ewma_difference_bps) as u128),
        EInvalidPythPrice,
    );

    (pyth_price, pyth_decimals, pyth_conf, type_config)
}

/// Gets Pyth price data without staleness or confidence validation.
/// Only validates price feed ID. Returns (pyth_price, pyth_decimals)
public(package) fun get_pyth_price_unsafe<T>(
    price_info_object: &PriceInfoObject,
    registry: &MarginRegistry,
): (u64, u8) {
    let type_config = registry.get_config_for_type<T>();

    let price = pyth::get_price_unsafe(price_info_object);
    let price_info = price_info_object.get_price_info_from_price_info_object();

    assert!(
        price_info.get_price_identifier().get_bytes() == type_config.price_feed_id,
        EPriceFeedIdMismatch,
    );

    let pyth_price = price.get_price().get_magnitude_if_positive();
    let pyth_decimals = price.get_expo().get_magnitude_if_negative() as u8;

    (pyth_price, pyth_decimals)
}

/// Gets the configuration for a given currency type.
fun get_config_for_type<T>(registry: &MarginRegistry): CoinTypeData {
    let config = registry.get_config<PythConfig>();
    let payment_type = type_name::with_defining_ids<T>();
    assert!(config.currencies.contains(&payment_type), ECurrencyNotSupported);
    *config.currencies.get(&payment_type)
}

fun get_decimals<T>(registry: &MarginRegistry): u8 {
    registry.get_config_for_type<T>().decimals
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
        type_name: type_name::with_defining_ids<T>(),
        max_conf_bps: 1000, // 10%
        max_ewma_difference_bps: 1500, // 15%
    }
}
