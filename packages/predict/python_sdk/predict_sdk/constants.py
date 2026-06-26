CLOCK_ID = "0x6"
ACCUMULATOR_ROOT_ID = "0xacc"
TICK_BITS = 30
POS_INF_TICK = (1 << TICK_BITS) - 1
U64_MAX = (1 << 64) - 1
# Decimals of the DUSDC settlement asset (pool denomination) and the PLP share token.
DUSDC_DECIMALS = 6
PLP_DECIMALS = 6

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
