// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Transaction-local bundle for Predict tests that need one underlying's Block Scholes stores as a
/// single pricing surface. Spot and forward share the value store; SVI has its own.
#[test_only]
module deepbook_predict::block_scholes_feed;

use propbook::block_scholes_store::{BlockScholesSVIStore, BlockScholesValueStore};
use sui::test_scenario::return_shared;

public struct BlockScholesFeed {
    values: BlockScholesValueStore,
    svi: BlockScholesSVIStore,
}

public fun new(values: BlockScholesValueStore, svi: BlockScholesSVIStore): BlockScholesFeed {
    BlockScholesFeed { values, svi }
}

public fun values(self: &BlockScholesFeed): &BlockScholesValueStore { &self.values }

public fun svi(self: &BlockScholesFeed): &BlockScholesSVIStore { &self.svi }

public fun values_mut(self: &mut BlockScholesFeed): &mut BlockScholesValueStore { &mut self.values }

public fun svi_mut(self: &mut BlockScholesFeed): &mut BlockScholesSVIStore { &mut self.svi }

public fun return_feed(self: BlockScholesFeed) {
    let BlockScholesFeed { values, svi } = self;
    return_shared(svi);
    return_shared(values);
}
