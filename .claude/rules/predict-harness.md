---
paths:
  - "packages/predict/harness/**"
  - "packages/predict/devtools/**"
  - "packages/predict/simulations/**"
---

# Predict Localnet Harness

Read this before editing the Predict local development system under `packages/predict/{harness,devtools,simulations}/**`. The harness is a worktree-free, real-data Sui-localnet staging sim for Predict: Python owns orchestration, `harness/ts` owns live actors and strategies, and `devtools/ts` is the shared execution/wire substrate used by both the harness and simulations. `packages/predict/harness/README.md` is the user-facing overview; this file is the editing-critical knowledge.

## Build & verify
- TypeScript: `cd packages/predict && npm run build && npm test`.
- Python: `python3 -m py_compile harness/*.py` from `packages/predict/`.
- Python tests: `python3 -m unittest discover -s harness/tests -p 'test_*.py' -v` and `python3 -m unittest discover -s simulations/tests -p 'test_*.py' -v` from `packages/predict/`.
- Validate behavior with a real localnet run (`python3 -m harness live --traders N --seconds S`) or a scoped campaign, then `python3 -m harness analyze`. Run these in the **main loop or background, never a blocking subagent** (long runs trip watchdogs). Retention/teardown model: README.
- **On a PTB abort, read the real VM error, not the framework tag.** A `MovePrimitiveRuntimeError` in `0x2::dynamic_field::borrow_child_object` names only the framework fn; the true cause is the dry-run `executionErrorSource` in the saved `artifacts/failed_transactions/*.json` (now also printed live by `runtime.ts` and by the `analyze` bug oracle). The C-1 object-cache ceiling was chased for days off the truncated framework string while that field read `Object runtime cached objects limit (1000 entries) reached` all along — the trace's `errorTag` only kept its first 120 chars.
- **`sui move test` does NOT enforce Sui execution-layer limits.** The object-runtime cached-objects cap (1,000 dynamic-field children/tx), per-tx gas, and max object size are full-node checks — a unit test loads 1,100+ children without aborting. Reproduce these on localnet (a harness strategy), never in `sui move test`.
- **Never blind-`rm` `.localnets/instances/` while a run may be live.** A bare `rm -rf` deletes a *running* campaign's dir out from under it — its keeper/updater then `ENOENT` on every write and the trace is lost. Check `python3 -m harness status` first (non-empty slots = a live run), then use the **slot-aware** `cleanup --instances`, which skips any dir whose run-id is an active slot.

## Architecture invariants (don't break these)
- **One stream.** Only the updater (`oracleService.ts`) consumes provider WS data; the keeper and traders read the updater-maintained on-chain feed + `snapshot.json`. Do not add a second provider stream to the keeper or traders.
- **Keeper reconciles from chain.** `keeperService.ts` builds its flush/settlement set each tick from `readActiveMarketIds()` (devInspect `plp::active_expiry_markets`), never an in-memory authority. The flush values EVERY active market — an on-chain market the keeper fails to value bricks `finish_flush` permanently. Never reintroduce an in-memory market list as the source of truth.
- **Settlement = Pyth history endpoint.** Settle each expiry by fetching the exact-timestamp spot from the Pyth Lazer history endpoint (`fetchExactSpot1e9`, `POST /v1/price`), re-signing it locally, and `insert_at` at the expiry key — independent of the live stream. The contract requires an observation at EXACTLY the expiry ms (`ensure_settled` → `read_at(expiry)`); do not settle with a "latest"/streamed spot.
- **Live stream = `real_time`** Pyth channel (freshest push), clamped to `≤ Clock−1` and strictly monotonic (`clampedPythTimestampMs`) or the on-chain freshness gate aborts.
- **MarketSource seam** — DirectWs / Hub behind one interface; keep new data sources behind it.
- **Oracle grid mirrors the prod cadence set.** The keeper enables + rolls {1m, 5m, 1h} (cadences 0/1/2, `windowSize` 3 — testnet `deployment.testnet.json`); `GRID_SPEC` warms each cadence's `windowSize` boundaries, built from `CADENCES` via `meta.ts`. **Don't widen the grid past BS's surface availability** (e.g. the old `60000:6` = 6 consecutive 1m expiries): BS rejects `mark.px` for an unmodeled/expired entry and a single bad entry **poisons the whole replace-wholesale BS batch**, so the grid silently drains. The cadence partition (1h owns `:00:00`, 5m owns 5-min marks off the hour, 1m the rest) makes `keeperService.cadenceOf(expiry)` exact.

## Strategies & campaign
- **Strategy logic stays under `ts/strategies/`.** A standalone behavior can be one module; related named profiles may share one parameterized family module, as capacity and cleanup do. The model and add-procedure live in README § Strategies & campaigns (and the `harness-strategy` rule for building one). Keep `traderService.ts` a thin runner: no strategy logic in the runner.
- **Strategies only touch the `StrategyCtx`** — never call builders/`submit` directly. `ts/strategy.ts` is the authoritative ctx surface; the ctx wraps submission with bookkeeping and strategy-tagged tracing, which direct calls silently skip.
- **Supply is custody-only; withdraw must read first.** `supply()` uses `requestSupplyFromCustodyTx` (pulls from the trader's funded account balance) — NOT `requestSupplyTx`, which mints fresh USDC and needs the publisher's TreasuryCap (keeper-only; a trader signing it aborts "not signed by the correct sender"). `withdraw(shares)` needs `shares ≤` the on-chain PLP balance (`refreshPlp()` → `runtime.readPlpBalance`); an over-draw aborts in `lp_book` and the bug oracle would flag it as a false positive. Supply/withdraw are **queued** (realized only by the keeper flush), so a strategy supplies, then withdraws on a LATER tick.
- **One op per tick, `tickMs ≥ ~1s`** — the open+close same-`Clock`-ms guard (`EMintRedeemSameTimestamp`) aborts a mint+redeem of one order in the same ms; pacing avoids it.
- **`campaign S1 S2 …`** runs each strategy on its own localnet off one shared hub (model: README). `strategies/meta.ts` is the single source for per-strategy funding, gas budget, completion mode, and the prod cadence set every keeper runs — don't duplicate them in Python. A timeout is a successful bounded stop only for a duration-only strategy that emitted trader progress; zero-progress runs fail. A strategy with `maxOps` or semantic `done` that is still running at the deadline is incomplete and fails the campaign.
- **The campaign manifest is the run authority.** Write `campaigns/<id>/manifest.json` atomically before actors start, record every ready localnet immediately, and finalize it only after teardown, hub-metrics validation, and analysis of the instance paths it declares. `running` means incomplete and must fail closed. The hub snapshot is runtime transport under the campaign's `runtime/` directory and is deleted at teardown; do not restore loose campaign-level report, snapshot, or metrics files.

## Units & clock
- Tick size `$0.01` = `1e7` (NOT 1e9). Quantity / cash / payouts are **USDC-native `1e6`** (NOT 1e9). Probability is `1e9`-scaled. Mixing these is the #1 scaling bug.
- Real-time only: the localnet `Clock` is not warpable (README § Note). The contract freshness defaults match testnet's configured 10s (Pyth spot + BS price) and 60s (BS SVI). BS spot/forward freshness keys on provider `value_timestamp`, while SVI freshness and roll-down key on provider `svi_timestamp`; the updater preserves those source clocks independently, and `batch_timestamp_ms` is transport observability only.

## Resilience invariants
- Shared files (`snapshot/feeds/markets.json`, `hub-snapshot.json`) are written with `io.ts atomicWriteFile` (temp+rename). Use it for any new shared file, and guard every cross-process JSON parse (a torn read must not throw out of a loop).
- Python run manifests use `devtools/run_manifest.py::write_manifest` (temp+replace). Keep its top-level schema shared across campaign, parity, and benchmark; command-specific data stays in `arguments`, `inputs`, `artifacts`, and `outcome`.
- Keeper tick steps are individually isolated (a transient sub-step abort defers that step, not the whole tick).
- Restart-safe: `setupFeedsAndConfig` re-attaches an existing `feeds.json`, `bootstrapPool` skips when `plp_total_supply > 0`, and `live.py` supervises the keeper/updater (restart → re-attach). Keep setup idempotent.

## Secrets
- `harness/.env` (PYTH_PRO_API_KEY, BLOCK_SCHOLES_API_KEY) is gitignored via `.env`/`*.env`. Local signer configuration is generated onto captured stdout, held in Python memory, and written only to the mode-0600 per-instance `.env.localnet` while actors run. `deployment.json` is public metadata only, and teardown deletes `.env.localnet` before retaining evidence. The instance root is gitignored via `.localnets/` — note `*.env` does NOT match `.env.localnet`, so the `.localnets/` rule is what covers it. **Never commit or log any secret** — a pre-commit gate aborts on a staged `.env`; never print a private key or the `Bearer` header.

## Current-only interfaces
- Python's `harness` module is the only operator CLI. The TS keeper, updater, hub, and trader actors require the launcher-provided instance, address, grid, strategy, and duration environment instead of inventing standalone defaults.
- Run manifests, scenario configuration, hub snapshots, and actor traces are versioned current schemas. Reject missing, unknown, malformed, incomplete, or unsupported inputs; do not reconstruct historical fields or fall back from computation gas to net gas.

## Don't
- Don't modify the Predict Move contracts or `usdc.move` (deployed to testnet) to suit the harness — the harness re-signs oracle updates with a local trusted signer instead.
- Treat production Move source, `Move.toml`, `Published.toml`, and tracked deployment manifests as read-only inputs. If localnet needs different publication identity, dependency mapping, or configuration, materialize those changes only in the disposable staged harness environment.
- Build staged packages from the selected Git commit, not another worktree or a mutable cache working tree. A cache may store derived artifacts, but it is never source authority.

## Bug oracle caveat
- `analyze.py`'s bug oracle is **abort-only**: it flags transaction aborts, NOT a wrong-but-*successful* tx (a mis-settlement / NAV error that does not abort). Classification: an abort in an INVARIANT module, or ANY `module:code` abort from a non-GUARD module, is **flagged** (likely bug); GUARD-module aborts are expected preconditions; HTTP/RPC/consensus strings are transient. A `module:code` tag is matched BEFORE the transient substrings, so a numeric abort code (e.g. `dynamic_field:500`) is never mis-read as an HTTP status. Adversarial probes wrongly accepted are traced as `adversarial-accepted` (a guard gap).
- **The non-zero exit gates on more than flagged aborts**: also `adversarial-accepted`, `no-keeper-trace` and (campaign) `missing-trace:<name>` (an instance/strategy that never produced a trace), `keeper-stuck` (operational fails with zero successful flush — a bricked settlement/LP lifecycle), and `fatal-crash` (a top-level actor crash, a `{fatal:true}` trace).
- **`capacity-single` and `capacity-pool` measure the per-tx COMPUTATION cap, not the gas budget.** The keeper flush OOGs when its `computationCost` hits `max_gas_computation_bucket = 5M units × RGP` (localnet/testnet 5e9 MIST, mainnet 5e8 — a protocol constant, so the OOG book size is network-independent), NOT the 50,000-SUI `max_tx_gas` budget. The profiles emit `book` records; `analyze.py` joins those with keeper flushes and compares `compGas` (computation cost, not net `gasOf`) against the cap. A flush's `InsufficientGas` deferral at that book size is the measured breakpoint and is excluded from the oracle — don't reintroduce a gas-budget ceiling. The former `nav-stress` measurements remain as historical evidence in `packages/predict/predeploy/evidence/c1-nav-stress-2026-06-30.md`.
- **`capacity-tree` measures a different wall.** It emits `nodes` records and declares the semantic VM terminal `cached objects limit`; the analyzer accepts a framework abort only when the saved VM error source proves that cause. Never replace the semantic terminal with a generic framework tag.
