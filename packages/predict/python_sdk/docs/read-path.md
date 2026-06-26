# Read Path

The read path builds a live Predict status view without a private key. It should keep
working even when the Predict indexer is unavailable.

## Entry Points

- CLI: `predict-sdk status`, `predict-sdk markets`.
- Python:
  - `SuiRpcObjectReader`
  - `ObservabilityClient.status()`
  - `PredictIndexerClient.markets()`
  - `render_dashboard()`

## Source Of Truth

- Sui JSON-RPC object reads are authoritative for live protocol state.
- The Predict indexer is best-effort. It supplies `/markets` history and `/status`
  health, but the live protocol dashboard should not fail when the indexer is down.

## Status Construction

`ObservabilityClient.status(asset, now_ms)`:

1. Load asset, protocol config ID, and pool vault ID from `DeploymentConfig`.
2. Read `ProtocolConfig` and add blockers for paused trading or in-progress valuation.
3. Read `PoolVault` and active expiry market IDs.
4. Read each active `ExpiryMarket`.
5. Resolve live expiries and check Propbook/Pyth/Block-Scholes feed freshness.
6. Build `PoolStatus`, `MarketStatus` entries, and per-cadence timelines.
7. Return `PredictStatusReport`.

The report is pure data. Rendering happens later in `render.py`.

## Oracle Freshness

Oracle feed freshness uses the on-chain pricing config:

- Pyth spot freshness: `pyth_spot_freshness_ms`.
- Block-Scholes spot/forward freshness: `block_scholes_price_freshness_ms`.
- Block-Scholes SVI freshness: `block_scholes_svi_freshness_ms`.

Forward and SVI feeds may store per-expiry values in dynamic fields. When direct latest
timestamps are absent, the read path checks the feed's expiry table for each live
expiry and uses the minimum source timestamp across required entries.

## Market Timeline

Cadence timelines are derived from `now_ms`, fixed cadence periods, and active markets:

- Prefer enabled cadences from the live Predict registry when available.
- Fall back to static deployment config cadences.
- Display the two past slots, live slot, and two upcoming slots.
- Shared timestamp boundaries belong to the coarsest cadence whose period divides the
  expiry, matching the protocol's higher-cadence-wins rule.

Slot states include `live`, `unfunded`, `scheduled`, `awaiting_settle`, `settled`,
`expired_gone`, `missing_live`, and `pending`.

## Indexer Behavior

`PredictIndexerClient` must fail open:

- `health()` returns `IndexerHealth(reachable=False, ...)` on transport errors or
  malformed responses.
- `markets()` returns `[]` on transport errors or non-list responses.

Do not let indexer outages crash `predict-sdk status`.

## Rendering

`render.py` takes data models and returns strings:

- `render_dashboard(report, now_ms, color, indexer)` prints protocol status, oracle
  rows, pool rows, indexer line, and cadence timelines.
- `render_markets_table(markets, now_ms, color)` prints indexer market history.

Render functions should remain deterministic and testable with fixtures.

## Testing Rules

- Use fake object readers and fake transports.
- Keep tests offline.
- Cover nested Sui object field shapes and dynamic-field oracle table lookups.
- Use `--fixture-live` for CLI smoke coverage without testnet RPC.
