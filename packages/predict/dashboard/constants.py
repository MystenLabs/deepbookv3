from __future__ import annotations

CLOCK_ID = "0x6"
DUSDC_DECIMALS = 6
FLOAT_SCALING = 1_000_000_000

DEFAULT_TESTNET_RPC_URL = "https://fullnode.testnet.sui.io:443"
DEFAULT_PREDICT_INDEXER_URL = "https://predict-server-beta.testnet.mystenlabs.com"

# Oracle feed is considered stale once its newest source timestamp is older than
# this (matches the protocol's staleness threshold). Used only for the glance verdict.
ORACLE_STALENESS_MS = 30_000

CADENCE_PERIOD_MS = {
    0: 60_000,
    1: 300_000,
    2: 3_600_000,
    3: 86_400_000,
    4: 604_800_000,
    5: 2_592_000_000,
}

CADENCE_NAMES = {
    0: "1m",
    1: "5m",
    2: "1h",
    3: "1d",
    4: "1w",
    5: "1mo",
}
