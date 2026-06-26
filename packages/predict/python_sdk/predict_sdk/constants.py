CLOCK_ID = "0x6"
# Sui's reserved AccumulatorRoot singleton (address/object balance settlement).
ACCUMULATOR_ROOT_ID = "0x0000000000000000000000000000000000000000000000000000000000000acc"
TICK_BITS = 30
POS_INF_TICK = (1 << TICK_BITS) - 1
U64_MAX = (1 << 64) - 1
# Decimals of the DUSDC settlement asset (pool denomination) and the PLP share token.
DUSDC_DECIMALS = 6
PLP_DECIMALS = 6
# Decimals of native SUI (gas / wallet balances).
SUI_DECIMALS = 9
# The protocol's 1e9 fixed-point scale (FLOAT_SCALING in Move): probabilities,
# leverage, reference/settlement prices, and tick values are all 1e9-scaled.
FLOAT_SCALING = 1_000_000_000

# Default testnet fullnode JSON-RPC endpoint. Single source for the read/write
# clients; override per call via --rpc-url or a client's rpc_url argument.
DEFAULT_TESTNET_RPC_URL = "https://fullnode.testnet.sui.io:443"

# Fixed cadence periods, keyed by the contract's cadence id (market_manager.move:
# cadence_period_ms). Periods are upgrade-required constants, not deploy params, so
# the schedule is fully derivable client-side from now + period.
CADENCE_PERIOD_MS = {
    0: 60_000,           # 1m
    1: 300_000,          # 5m
    2: 3_600_000,        # 1h
    3: 86_400_000,       # 1d
    4: 604_800_000,      # 1w
    5: 2_592_000_000,    # 1mo (30d)
}
# Cadence id -> short name (fixed by market_manager.move's cadence_* macros).
CADENCE_NAMES = {0: "1m", 1: "5m", 2: "1h", 3: "1d", 4: "1w", 5: "1mo"}
