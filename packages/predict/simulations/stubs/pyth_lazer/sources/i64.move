// Stub of pyth_lazer::i64 for localnet simulation builds only. The real
// pyth_lazer package transitively depends on wormhole, whose source cannot be
// compiled fresh against the 2024.beta edition. This stub exposes just the
// symbols `deepbook_predict::oracle` references so the sim can build without
// pulling pyth_lazer + wormhole.
module pyth_lazer::i64;

public struct I64 has copy, drop, store {
    negative: bool,
    magnitude: u64,
}

public fun get_is_negative(i: &I64): bool {
    i.negative
}

public fun get_magnitude_if_positive(i: &I64): u64 {
    i.magnitude
}
