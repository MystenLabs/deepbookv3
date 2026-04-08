// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module deepbook_predict::currency_helper;

use std::unit_test::destroy;
use sui::{coin::TreasuryCap, coin_registry::{Currency, MetadataCap}};

public(package) fun destroy_currency_bundle<T>(
    currency: Currency<T>,
    treasury_cap: TreasuryCap<T>,
    metadata_cap: MetadataCap<T>,
) {
    destroy(currency);
    destroy(treasury_cap);
    destroy(metadata_cap);
}
