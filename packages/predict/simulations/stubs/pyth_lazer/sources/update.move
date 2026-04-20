// See note in i64.move — this module is a localnet-sim stub.
module pyth_lazer::update;

use pyth_lazer::feed::Feed;

public struct Update has copy, drop {
    timestamp: u64,
    feeds: vector<Feed>,
}

public fun timestamp(update: &Update): u64 {
    update.timestamp
}

public fun feeds_ref(update: &Update): &vector<Feed> {
    &update.feeds
}
