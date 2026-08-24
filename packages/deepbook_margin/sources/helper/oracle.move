// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Oracle module for margin trading.
module deepbook_margin::oracle;

use deepbook::{constants, math};
use deepbook_margin::{margin_constants, margin_registry::MarginRegistry};
use pyth_upgraded::{
    price_info::PriceInfoObject as PriceInfoObjectUpgraded,
    pyth as pyth_upgraded_api
};
use std::type_name::{Self, TypeName};
use sui::{clock::Clock, coin::CoinMetadata, coin_registry::Currency, vec_map::{Self, VecMap}};

use fun get_config_for_type as MarginRegistry.get_config_for_type;

const EInvalidPythPrice: u64 = 1;
const ECurrencyNotSupported: u64 = 2;
const EPriceFeedIdMismatch: u64 = 3;
const EInvalidPythPriceConf: u64 = 4;
const EInvalidOracleConfig: u64 = 5;
const EInvalidPrice: u64 = 6;
const EReadingAssetMismatch: u64 = 7;

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

/// A normalized price read from an upgraded-Core `PriceInfoObject`. Carrying the value
/// rather than the object keeps the pricing path independent of the reader, which is why
/// the entrypoint families could be migrated one at a time. Safe readers enforce
/// staleness, feed id, and EWMA deviation; pricing later enforces the asset binding and
/// confidence interval before performing arithmetic.
public struct PythReading has copy, drop {
    price: u64,
    decimals: u8,
    /// `some` only for validated reads. The confidence bound is a *pricing* guard,
    /// not a read guard: it is asserted in `price_config`, so a reading taken purely
    /// for telemetry (the deposit event) is never rejected for a wide interval.
    /// Unvalidated reads carry `none` and skip the check, as they always have.
    conf: Option<u64>,
    /// The asset this price is *for*, stamped by the reader from the same config row
    /// the feed id was checked against. `price_config` asserts it matches the type it
    /// is being consumed as, so a reading routed to the wrong leg aborts instead of
    /// silently mis-pricing. Without it, transposing the base and quote readings at a
    /// call site is invisible: both are well-formed, both pass every other guard.
    coin_type: TypeName,
}

public(package) fun price(self: &PythReading): u64 {
    self.price
}

public(package) fun decimals(self: &PythReading): u8 {
    self.decimals
}

/// Superseded by `new_coin_type_data_from_currency`, which reads decimals from
/// `Currency` instead of trusting the caller-supplied `CoinMetadata`. Retained as an
/// aborting stub because it is public in the deployed package: a `compatible` upgrade
/// cannot drop a public function.
public fun new_coin_type_data<T>(
    _coin_metadata: &CoinMetadata<T>,
    _price_feed_id: vector<u8>,
    _max_conf_bps: u64,
    _max_ewma_difference_bps: u64,
): CoinTypeData {
    abort 1337
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
    reading: PythReading,
    registry: &MarginRegistry,
    amount: u64,
): u64 {
    let config = price_config<T>(
        reading,
        registry,
        true,
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
    base_reading: PythReading,
    quote_reading: PythReading,
): u64 {
    let base_decimals = get_decimals<BaseAsset>(registry);
    let quote_decimals = get_decimals<QuoteAsset>(registry);

    let base_amount = 10u64.pow(base_decimals);
    let base_usd_price = calculate_usd_price<BaseAsset>(
        base_reading,
        registry,
        base_amount,
    );

    let quote_amount = 10u64.pow(quote_decimals);
    let quote_usd_price = calculate_usd_price<QuoteAsset>(
        quote_reading,
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

/// Calculates the amount in target currency based on amount in asset A.
public(package) fun calculate_target_currency<AssetA, AssetB>(
    registry: &MarginRegistry,
    reading_a: PythReading,
    reading_b: PythReading,
    amount: u64,
): u64 {
    let usd_value = calculate_usd_price<AssetA>(
        reading_a,
        registry,
        amount,
    );
    let target_value = calculate_target_amount<AssetB>(
        reading_b,
        registry,
        usd_value,
    );

    target_value
}

/// Calculates the amount in target currency based on usd amount
public(package) fun calculate_target_amount<T>(
    reading: PythReading,
    registry: &MarginRegistry,
    usd_amount: u64,
): u64 {
    let config = price_config<T>(
        reading,
        registry,
        false,
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
    reading: PythReading,
    registry: &MarginRegistry,
    is_usd_price_config: bool,
): ConversionConfig {
    let type_config = registry.get_config_for_type<T>();

    // The reading must be for the asset it is being priced as. Every pricing path
    // funnels through here, so this is the one place that has to hold.
    assert!(reading.coin_type == type_config.type_name, EReadingAssetMismatch);

    // Validated readings carry a confidence bound; unvalidated ones never did.
    reading
        .conf
        .do_ref!(
            |conf| assert!(
                (*conf as u128) * 10_000 <= (type_config.max_conf_bps as u128) * (reading.price as u128),
                EInvalidPythPriceConf,
            ),
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
        pyth_price: reading.price,
        pyth_decimals: reading.decimals,
    }
}

/// Reads Pyth's upgraded Core with staleness, feed-id, and EWMA checks, carrying its
/// confidence interval for validation when the reading is converted to a price.
///
/// There is no legacy-Core counterpart: the readers that took a legacy `PriceInfoObject`
/// were removed when the legacy entrypoints were retired, so no code path in this package
/// can price a position off a feed Pyth no longer maintains for us.
public(package) fun read_price_upgraded<T>(
    price_info_object: &PriceInfoObjectUpgraded,
    registry: &MarginRegistry,
    clock: &Clock,
): PythReading {
    let config = registry.get_config<PythConfig>();
    let type_config = registry.get_config_for_type<T>();

    let price = pyth_upgraded_api::get_price_no_older_than(
        price_info_object,
        clock,
        config.max_age_secs,
    );
    let price_info = price_info_object.get_price_info_from_price_info_object();
    let ewma_price_object = price_info.get_price_feed().get_ema_price();

    validate_reading(
        price_info.get_price_identifier().get_bytes(),
        price.get_price().get_magnitude_if_positive(),
        price.get_expo().get_magnitude_if_negative() as u8,
        price.get_conf(),
        ewma_price_object.get_price().get_magnitude_if_positive(),
        type_config,
    )
}

/// Pyth's upgraded Core without staleness, confidence, or EWMA validation.
/// Only the price feed id is checked.
public(package) fun read_price_upgraded_unsafe<T>(
    price_info_object: &PriceInfoObjectUpgraded,
    registry: &MarginRegistry,
): PythReading {
    let type_config = registry.get_config_for_type<T>();
    let price = pyth_upgraded_api::get_price_unsafe(price_info_object);
    let price_info = price_info_object.get_price_info_from_price_info_object();

    validate_feed_id(price_info.get_price_identifier().get_bytes(), type_config);

    PythReading {
        price: price.get_price().get_magnitude_if_positive(),
        decimals: price.get_expo().get_magnitude_if_negative() as u8,
        conf: option::none(),
        coin_type: type_config.type_name,
    }
}

/// Guards applied to every validated reading.
fun validate_reading(
    price_feed_id: vector<u8>,
    pyth_price: u64,
    pyth_decimals: u8,
    pyth_conf: u64,
    ewma_price: u64,
    type_config: CoinTypeData,
): PythReading {
    validate_feed_id(price_feed_id, type_config);

    assert!(
        (pyth_price as u128) * 10_000 <= (ewma_price as u128) * ((10_000 + type_config.max_ewma_difference_bps) as u128) &&
        (pyth_price as u128) * 10_000 >= (ewma_price as u128) * ((10_000 - type_config.max_ewma_difference_bps) as u128),
        EInvalidPythPrice,
    );

    PythReading {
        price: pyth_price,
        decimals: pyth_decimals,
        conf: option::some(pyth_conf),
        coin_type: type_config.type_name,
    }
}

fun validate_feed_id(price_feed_id: vector<u8>, type_config: CoinTypeData) {
    assert!(price_feed_id == type_config.price_feed_id, EPriceFeedIdMismatch);
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
