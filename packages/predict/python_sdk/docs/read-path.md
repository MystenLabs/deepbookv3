# Read Path

The read path builds a live Predict status view without a private key. It is sourced
entirely from the **indexer data plane** (predict-server + oracle service); the chain
is used only for execution. Observe commands degrade gracefully when a service is down.

## Entry Points

- CLI: `predict-sdk status`, `predict-sdk markets`.
- Python:
  - `ObservabilityClient.status()`
  - `PredictIndexerClient` (markets / market-state / vault-state / config / managers)
  - `OracleClient` (underlying binding + latest pyth / block-scholes)
  - `render_dashboard()`

## Source Of Truth

- The indexer is the data plane: market/vault/config state, positions, and oracle
  freshness all come from HTTP, not chain object reads.
- The chain backs only execution (dry-run, submit, refs) plus the one live value the
  indexer does not carry — a market's `reference_tick`, read on the trade path.
- Mintability is enforced by the chain dry-run, so a slightly-stale read can never
  cause a bad write. See decisions D001/D002.

## Status Construction

`ObservabilityClient.status(asset, now_ms)`:

1. `GET /config` — gates (trading paused) + oracle freshness thresholds.
2. Oracle freshness: `GET /underlyings/{id}/binding` → `propbook_oracle_id`, then the
   latest pyth + block-scholes observations (two feeds).
3. `GET /markets` — created markets; the windowed ones (±2 slots per cadence) get
   `GET /markets/{id}/state` for mint-paused / settled / settlement price.
4. `GET /vaults/{id}/state` — idle balance, protocol reserve, PLP supply.
5. Build `PoolStatus`, `MarketStatus` entries, and per-cadence timelines (pure).
6. Return `PredictStatusReport`.

The report is pure data. Rendering happens later in `render.py`.

## Oracle Freshness

Two feeds, matching the protocol config and the oracle service:

- Pyth spot: `pyth_spot_freshness_ms`.
- Block-Scholes surface (spot/forward/SVI in one observation):
  `block_scholes_surface_freshness_ms`.

## Market Timeline

Cadence timelines are derived from `now_ms` and the fixed cadence periods in
`DeploymentConfig`:

- Display the two past slots, the live slot, and two upcoming slots.
- Shared timestamp boundaries belong to the coarsest cadence whose period divides the
  expiry, matching the protocol's higher-cadence-wins rule.

Slot states: `live`, `scheduled`, `awaiting_settle`, `settled`, `expired_gone`,
`missing_live`, `pending`.

## Indexer Behavior

`PredictIndexerClient` and `OracleClient` fail open: a transport error or malformed
response degrades to empty (`health().reachable=False`, `markets() -> []`, state
reads `-> {}`), so observe commands surface "unavailable" rather than crashing. Trading
still works when the indexer is down (it only needs the chain).

## Rendering

`render.py` takes data models and returns strings:

- `render_dashboard(report, now_ms, color, indexer)` prints protocol status, oracle
  rows, pool rows, indexer line, and cadence timelines.
- `render_markets_table(markets, now_ms, color)` prints indexer market history.

Render functions should remain deterministic and testable with fixtures.

## Testing Rules

- Use fake transports returning indexer JSON; keep tests offline.
- Use `--fixture-live` for CLI smoke coverage without live services.
