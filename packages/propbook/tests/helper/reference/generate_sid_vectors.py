#!/usr/bin/env python3
"""Generates the Block Scholes series-id vectors pinned by block_scholes_sid_tests.move.

Run: python3 generate_sid_vectors.py

The layout is shared with Block Scholes, who assign series ids using it, so this file doubles as
the reference their client is checked against. Committed for provenance and reproducibility; not in
the CI path, which runs only the Move tests against the committed literals.

Each id is a 256-bit big-endian packing, readable byte-by-byte in the hex output:

    byte  0      version
    byte  1      kind (0 spot, 1 forward, 2 SVI)
    bytes 2-5    propbook underlying id
    byte  6      value scale, as decimal places
    bytes 7-23   unused, always zero
    bytes 24-31  expiry in unix milliseconds (zero for spot, which is not expiry-scoped)
"""

VERSION = 1
KIND_SPOT, KIND_FORWARD, KIND_SVI = 0, 1, 2
DECIMALS = 9  # propbook::constants::float_scaling_decimals

BTC_USD = 1
EXPIRY_MS = 1_785_888_000_000

MAX_UNDERLYING = 0xFFFFFFFF
MAX_EXPIRY_MS = 0xFFFFFFFFFFFFFFFF


def sid(kind: int, underlying: int, expiry_ms: int) -> int:
    return (
        (VERSION << 248)
        | (kind << 240)
        | (underlying << 208)
        | (DECIMALS << 200)
        | expiry_ms
    )


VECTORS = [
    ("SPOT_BTC_ID", KIND_SPOT, BTC_USD, 0),
    ("FORWARD_BTC_ID", KIND_FORWARD, BTC_USD, EXPIRY_MS),
    ("SVI_BTC_ID", KIND_SVI, BTC_USD, EXPIRY_MS),
    ("FORWARD_BTC_ZERO_EXPIRY_ID", KIND_FORWARD, BTC_USD, 0),
    ("SATURATED_SVI_ID", KIND_SVI, MAX_UNDERLYING, MAX_EXPIRY_MS),
]

if __name__ == "__main__":
    for name, kind, underlying, expiry_ms in VECTORS:
        print(f"const {name}: u256 =\n    0x{sid(kind, underlying, expiry_ms):064x};")
    print(f"\nRESERVED_MASK 0x{((1 << 136) - 1) << 64:064x}")
    print(f"EXPIRY_MASK   0x{(1 << 64) - 1:064x}")
