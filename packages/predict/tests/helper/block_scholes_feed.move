// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Transaction-local bundle for Predict tests that need the split Block Scholes
/// Propbook feeds as one pricing surface.
#[test_only]
module deepbook_predict::block_scholes_feed;

use propbook::{
    block_scholes_forward_feed::BlockScholesForwardFeed,
    block_scholes_spot_feed::BlockScholesSpotFeed,
    block_scholes_svi_feed::BlockScholesSVIFeed
};
use sui::test_scenario::return_shared;

public struct BlockScholesFeed {
    spot: BlockScholesSpotFeed,
    forward: BlockScholesForwardFeed,
    svi: BlockScholesSVIFeed,
}

public fun new(
    spot: BlockScholesSpotFeed,
    forward: BlockScholesForwardFeed,
    svi: BlockScholesSVIFeed,
): BlockScholesFeed {
    BlockScholesFeed { spot, forward, svi }
}

public fun spot(self: &BlockScholesFeed): &BlockScholesSpotFeed { &self.spot }

public fun forward(self: &BlockScholesFeed): &BlockScholesForwardFeed { &self.forward }

public fun svi(self: &BlockScholesFeed): &BlockScholesSVIFeed { &self.svi }

public fun spot_mut(self: &mut BlockScholesFeed): &mut BlockScholesSpotFeed { &mut self.spot }

public fun forward_mut(self: &mut BlockScholesFeed): &mut BlockScholesForwardFeed {
    &mut self.forward
}

public fun svi_mut(self: &mut BlockScholesFeed): &mut BlockScholesSVIFeed { &mut self.svi }

public fun return_feed(self: BlockScholesFeed) {
    let BlockScholesFeed { spot, forward, svi } = self;
    return_shared(svi);
    return_shared(forward);
    return_shared(spot);
}
