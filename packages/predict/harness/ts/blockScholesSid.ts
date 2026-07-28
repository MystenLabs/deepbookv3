// Block Scholes series-id encoding, mirroring propbook::block_scholes_sid.
//
// A signed update carries its own series id; the propbook stores derive the id
// they expect from their own identity, so the sim must stamp updates with the
// exact same layout or every write is skipped as a foreign series. The layout is
// the shared client/package contract (see `block_scholes_sid.move` and the
// vectors in `packages/propbook/tests/block_scholes/block_scholes_sid_tests.move`,
// e.g. spot(1) = 0x0100000000010900000000000000000000000000000000000000000000000000).

const VERSION = 1n;
const KIND_SPOT = 0n;
const KIND_FORWARD = 1n;
const KIND_SVI = 2n;
// constants::float_scaling_decimals!() — the 1e9 fixed-point scale of every value.
const DECIMALS = 9n;

const VERSION_SHIFT = 248n;
const KIND_SHIFT = 240n;
const UNDERLYING_SHIFT = 208n;
const DECIMALS_SHIFT = 200n;

function encode(kind: bigint, underlyingId: number, expiryMs: bigint): bigint {
    return (
        (VERSION << VERSION_SHIFT) |
        (kind << KIND_SHIFT) |
        (BigInt(underlyingId) << UNDERLYING_SHIFT) |
        (DECIMALS << DECIMALS_SHIFT) |
        expiryMs
    );
}

export function spotSid(underlyingId: number): bigint {
    return encode(KIND_SPOT, underlyingId, 0n);
}

export function forwardSid(underlyingId: number, expiryMs: bigint): bigint {
    return encode(KIND_FORWARD, underlyingId, expiryMs);
}

export function sviSid(underlyingId: number, expiryMs: bigint): bigint {
    return encode(KIND_SVI, underlyingId, expiryMs);
}
