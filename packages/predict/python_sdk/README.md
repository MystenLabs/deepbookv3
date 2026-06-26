# Predict SDK (Python)

A Python SDK + CLI for the DeepBook **Predict** protocol on Sui — binary range-digital
options markets. It covers the full lifecycle: **observe** the protocol, **trade**
(account custody, mint/redeem), and **monitor** an account's positions & PnL.

Read commands do not require a key. Trading is included in the default install and
uses PyNaCl for Ed25519 transaction signatures.

## Install

```bash
cd packages/predict/python_sdk
python3 -m venv .venv && source .venv/bin/activate
pip install -e .            # full SDK + CLI (observe, trade, portfolio)
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
predict-sdk account                                  # wallet/custody balances + PnL summary
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

## Live dashboard

```bash
predict-sdk dashboard            # Textual monitor: balances, PnL, positions, status
```

A read-only, auto-refreshing terminal monitor for one account — no trading inputs.

## Parallel execution

Concurrent Sui transactions must not share an owned object or they equivocate.
`GasPool` pre-splits SUI into distinct gas coins and hands one to each in-flight tx.
Because Predict custody/markets are shared objects, parallel **mint/redeem** touch no
owned object other than gas, so a distinct gas coin each is sufficient. `deposit` and
`withdraw` additionally consume an owned DUSDC coin, so running those concurrently
needs distinct input coins too — a distinct gas coin alone is not enough.

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
| `indexer` | data-plane clients: predict-server + oracle service, fail open |
| `observability` | `status()` → report: gates, oracle, pool, per-cadence timelines |
| `render` | boxed terminal dashboard + markets table |
| `signer` | bech32 key → address → Ed25519 sign (Sui intent + blake2b) |
| `bcs` | hand-rolled BCS encoder for Sui `TransactionData` + a PTB builder |
| `tx` | object/gas resolution, dry-run-first gas estimation, sign + execute |
| `actions` | trader actions: account / deposit / withdraw / mint / redeem |
| `portfolio` | open positions + realized PnL from on-chain order events |
| `gas` | parallel-execution gas pool (distinct gas coin per in-flight tx) |
| `dashboard` | Textual read-only account monitor |

**Design notes.** The indexer is the data plane — all observe/monitor reads (status,
positions, account) come from the predict-server + oracle service, which fail open. The
chain is the execution plane: dry-run, submit, refs, and the one live value the indexer
lacks (a market's `reference_tick`). The write path abstracts the owner `Auth` hot-potato,
the shared `AccountWrapper` custody lifecycle, DUSDC coin splitting, the
`AccumulatorRoot`/`Clock` plumbing, and the `load_live_pricer → mint` two-step. There
is no off-chain pricer — current entry probability/cost is discovered via a dry-run mint.

For deeper development context, read `AGENTS.md` and `docs/sdk-map.md`.

## Safety

- Write commands dry-run unless `--execute` is passed.
- Gas budget is estimated from the dry run; gas coins are kept distinct from tx inputs
  to avoid owned-object equivocation.
- The private key lives only in `.env` (gitignored); never commit it.

## Tests

```bash
PYTHONPATH=. python3 -m unittest discover -s tests
```
