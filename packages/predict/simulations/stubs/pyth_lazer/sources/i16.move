// See note in i64.move — this module is a localnet-sim stub.
module pyth_lazer::i16;

public struct I16 has copy, drop, store {
    negative: bool,
    magnitude: u16,
}

public fun get_is_negative(i: &I16): bool {
    i.negative
}

public fun get_magnitude_if_positive(i: &I16): u16 {
    i.magnitude
}

public fun get_magnitude_if_negative(i: &I16): u16 {
    i.magnitude
}
