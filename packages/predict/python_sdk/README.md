# Predict SDK (Python)

A Python SDK + CLI for the DeepBook **Predict** protocol on Sui — binary range-digital
options markets. It covers the full lifecycle: **observe** the protocol, **trade**
(account custody, mint/redeem), and **monitor** an account's positions & PnL.

The read/observability path is **pure standard library**. Signing transactions needs
Ed25519, so the write path requires the optional `tx` extra (PyNaCl).

## Install

```bash
cd packages/predict/python_sdk
python3 -m venv .venv && source .venv/bin/activate
pip install -e .            # read-only (status, markets) — pure stdlib
pip install -e ".[tx]"      # + trading (account, deposit, trade, redeem)
pip install -e ".[tui]"     # + live dashboard
```

The signer reads `SUI_PRIVATE_KEY` (a bech32 `suiprivkey1…`, Ed25519) from the
environment or a local `.env` (gitignored). Generate one with `sui keytool generate ed25519`.

## Observe (no key needed)

```bash
predict-sdk status          # boxed dashboard: gates, oracle freshness, pool,
                            # per-cadence market timelines, indexer health
predict-sdk markets         # created-market history (from the indexer)
predict-sdk status --json   # machine-readable
```

## Trade

Every write command is **dry-run by default**; add `--execute` to submit. Amounts are
human DUSDC.

```bash
predict-sdk account                                  # account + balances + PnL summary
predict-sdk deposit 5000 --execute                   # fund account custody from wallet
predict-sdk trade --notional 100 --width 1000        # dry-run a range mint around spot
predict-sdk trade --notional 100 --width 1000 --execute
predict-sdk positions                                # open positions + realized PnL
predict-sdk redeem <order_id> --market <id> --execute
predict-sdk withdraw 1000 --execute
```

`trade` abstracts the protocol nuances: it auto-picks the longest-dated live market,
snaps a ±`width`-tick range to the admission grid around the market's reference tick,
sizes the position to `--notional`, sets slippage caps, and prints the dry-run entry
probability + premium before you commit.

## Run a strategy

```bash
predict-sdk bot --notional 50 --half-width 60          # dry-run: propose trades
predict-sdk bot --notional 50 --loop 30 --execute      # run every 30s, live
```

`RangeAroundSpotStrategy` prices each candidate range via a dry-run mint and only
trades when the entry probability lands inside a band (default 0.15–0.85), skipping
near-certain and near-impossible bets. The engine applies risk caps (max open
positions, max total premium) before submitting.

## Live dashboard

```bash
predict-sdk dashboard            # Textual monitor: balances, PnL, positions, status
```

A read-only, auto-refreshing terminal monitor for one account — no trading inputs.

## Parallel execution

Concurrent Sui transactions must not share an owned object (the gas coin) or they
equivocate. `GasPool` pre-splits SUI into distinct gas coins and hands one to each
in-flight tx; because Predict custody/markets are shared objects, parallel trades
only need a distinct gas coin each:

```python
from predict_sdk.gas import GasPool
pool = GasPool(actions.client)
pool.split(4, 120_000_000)                       # 4 gas coins of 0.12 SUI
pool.parallel([lambda c: actions.mint(..., gas_coin=c) for _ in range(4)])
```

## Architecture

| Module | Role |
|---|---|
| `config` / `deployments/` | deployment manifest (packages, objects, assets, cadences, servers) |
| `constants` | decimals, cadence periods, reserved object ids |
| `rpc` | read-only Sui object reader |
| `indexer` | public indexer client (`/status`, `/markets`), fails open |
| `observability` | `status()` → report: gates, oracle, pool, per-cadence timelines |
| `render` | boxed terminal dashboard + markets table |
| `signer` | bech32 key → address → Ed25519 sign (Sui intent + blake2b) |
| `bcs` | hand-rolled BCS encoder for Sui `TransactionData` + a PTB builder |
| `tx` | object/gas resolution, dry-run-first gas estimation, sign + execute |
| `actions` | trader actions: account / deposit / withdraw / mint / redeem |
| `portfolio` | open positions + realized PnL from on-chain order events |
| `gas` | parallel-execution gas pool (distinct gas coin per in-flight tx) |
| `strategy` | pluggable strategy + engine (prices candidates via dry-run mint) |
| `dashboard` | Textual read-only account monitor |

**Design notes.** RPC is the source of truth for live state; the indexer only layers
history/health and fails open. The write path abstracts the owner `Auth` hot-potato,
the shared `AccountWrapper` custody lifecycle, DUSDC coin splitting, the
`AccumulatorRoot`/`Clock` plumbing, and the `load_live_pricer → mint` two-step. There
is no off-chain pricer — current entry probability/cost is discovered via a dry-run mint.

## Safety

- Write commands dry-run unless `--execute` is passed.
- Gas budget is estimated from the dry run; gas coins are kept distinct from tx inputs
  to avoid owned-object equivocation.
- The private key lives only in `.env` (gitignored); never commit it.

## Tests

```bash
PYTHONPATH=. python3 -m unittest discover -s tests
```
