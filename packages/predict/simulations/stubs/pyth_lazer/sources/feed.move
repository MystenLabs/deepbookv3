// See note in i64.move — this module is a localnet-sim stub.
module pyth_lazer::feed;

use pyth_lazer::i16::I16;
use pyth_lazer::i64::I64;

public struct Feed has copy, drop, store {
    feed_id: u32,
    price: Option<Option<I64>>,
    exponent: Option<I16>,
}

public fun feed_id(feed: &Feed): u32 {
    feed.feed_id
}

public fun price(feed: &Feed): Option<Option<I64>> {
    feed.price
}

public fun exponent(feed: &Feed): Option<I16> {
    feed.exponent
}
