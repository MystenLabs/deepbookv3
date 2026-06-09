# Predict Unit-Test Framework — Session Handoff (2026-06-09)

> Written at a graceful pause (session limit). Branch `strike-exposure-rewrite-state`.
> Suite state at handoff: **predict 282/282 + 3 (protocol_config_tests) green, predict_math 104/104 green; 0 KNOWN-FAILING; BUGS_FOUND.md empty (consistent).**
> Coverage: **127/157 module-qualified error constants tested + 12 documented dispositions; 18 open** (all P3 config-bounds, in flight with an agent — see "In-flight" below).

## Commits this session (all on `strike-exposure-rewrite-state`)

| Commit | What |
|---|---|
| `1dcda1d2` | Phase 0 — COVERAGE_MATRIX regenerated for this repo (60/157 baseline), reconciled TEST_ARCHITECTURE.md, adapted gen_coverage_matrix.py, empty BUGS_FOUND.md scaffold |
| `5a38ab07` | Phase 1 — framework extensions: invariant layer (`assert_market_backed`, `check_market_cash`/`ExpectedMarketCash`, `check_pool`/`ExpectedPoolState`), flow wrappers (`liquidate`, `liquidate_order`, `compact_storage`, `claim_trading_loss_rebate`), toggles (`set_trading_paused`, `set_expiry_mint_paused`), `create_funded_manager_as` |
| `d622718e` | Phase 2 wave 1 — expiry_market gates + protocol_config locks (6), liquidation_book (4+1), strike_nav_matrix (5), strike_exposure guards (2), strike_grid EInvalidTickSize (2), pool_accounting (4). 237/237 |
| `148826fa` | Phase 2 wave 2 — market_oracle_guard_tests (14), pricing_guard_tests (9). 260/260 |
| `9e81a866` | Phase 2 wave 3 — registry_guard_tests (7), plp_guard_tests (9), incentive_tests (6); matrix dispositions section added (12 documented). 282/282 |
| `5f657bfe` | protocol_config per-expiry table guards (2 + happy path). |

## Key artifacts (all committed)

- `.redesign/COVERAGE_MATRIX.md` — regenerate with `python3 .redesign/gen_coverage_matrix.py`. ✅/📄-documented/❌ per constant; "documented" dispositions live in the `DISPOSITIONS` dict inside the generator (12 entries: defensive / needs-special Lazer / gas-bound / AccumulatorRoot-blocked).
- `.redesign/TEST_ARCHITECTURE.md` — the reconciled framework architecture (layered helpers, idioms, bug-finding discipline).
- `.redesign/BUGS_FOUND.md` — EMPTY ledger (no contract bugs found by the guard waves; every guard fired at the documented site with the right code).
- `.redesign/OPEN_ISSUES_TRIAGE.json` — **Phase-4 triage results (13 verdicts, fully cited)**: 4 TESTABLE-NOW/RED candidates, 7 TESTABLE-NOW/GREEN pins, 2 ACCEPTED-DOCUMENT. Each has scenario steps + file:line evidence. This cost ~1.2M tokens — do not regenerate, read it.
- `.redesign/workflows/phase3-invariant-derivations.js`, `phase4-open-issues-triage.js` — the workflow scripts (re-runnable via the Workflow tool with `scriptPath`).
- `.redesign/REACHABILITY.md` — stale-source hypothesis material (warning header prepended); largely superseded by the landed tests.

## In-flight at pause (check these FIRST on resume)

1. **Config-bounds author agent** — worktree `/tmp/predict-wt-config` (detached HEAD at `148826fa`). Owns the final 18 open constants. At pause it had written `packages/predict/tests/config/protocol_config_bounds_tests.move` (10 config_constants codes) and was still working on `strike_exposure_config_tests.move` (8 codes incl. mint-admission policy: EInvalidLeverage/EInvalidLeverageTier/EOrderPrincipalBelowMinimum/EAskPriceOutOfBounds via the real mint flow). **On resume:** check both files exist in that worktree, review them (rules 7/9/12), copy into the main repo, run the full suite, regenerate matrix, commit. If the agent died mid-file, finish `strike_exposure_config_tests.move` by hand (read strike_exposure_config.move to split setter-validation vs mint-admission codes).
2. **Phase-3 derivation workflow** (`phase3-invariant-derivations.js`) — 8 scenario derivers + 16 adversarial verifiers; was still running at pause, output likely lost. **On resume:** re-launch via `Workflow({scriptPath: ".redesign/workflows/phase3-invariant-derivations.js"})`, then author the 8 invariant test files in the main loop from the verified derivations. The 8 scenarios: settled-solvency-boundary (S3/L1), cash-backing-per-flow (S1/S2), multi-expiry-sync-nav (S4/A2), no-double-pay-liquidation (L2), rebate-claim-accounting (A2/A3), supply-withdraw-rounding (A1), liquidation-boundary (P0-7), compaction-parity (P0-8 metamorphic, independence-exempt).
3. **Stale Agent-tool worktrees** — `git worktree list` shows `.claude/worktrees/agent-*` (locked, stale base e276939f) and the manual `/tmp/predict-wt-*` ones. Clean up when done: `git worktree remove --force <path>` for the consumed ones (oracle, pricing, plp, registry, gates are fully integrated; config NOT yet).

## Next steps (priority order)

1. **Finish Phase 2** — integrate `/tmp/predict-wt-config` files (see above). After that the matrix should read ~145/157 + 12 documented + 0 open. Two constants whose disposition is settled but worth re-checking once config lands: none remaining.
2. **Phase 3** — re-run the derivation workflow, then author invariant tests (single coherent author in main loop, file per scenario under `tests/flows/`). Use the Phase-1 helpers (`check_market_cash`, `check_pool`, `assert_market_backed`). Compaction-parity is metamorphic (assert path A == path B, exempt from independent-expected rule).
3. **Phase 4** — encode the triage verdicts from `.redesign/OPEN_ISSUES_TRIAGE.json`:
   - **RED ledger candidates (re-verify cited file:lines first, then encode + ledger as BUG-001..004 cross-referencing OPEN_ISSUES):**
     - `loss-netting-one-directional` — protocol take depends on settlement order; strongest minimal test: run both orderings, assert equal final `protocol_reserve_balance` (fails iff one-directional). plp.move:819/823, pool_accounting.move:245-273.
     - `re-bootstrap-incentive-capture` — full LP exit mid-stream orphans locked incentive; re-bootstrap supplier captures it (contradicts plp.move:550-551 doc + risks.md:91). Exact scenario in the JSON.
     - `strike-quantity-u64-overflow` — 3 max-size deep-ITM BTC orders overflow the strike_quantity u64 accumulator (native abort on pool_nav hot path → bricks supply/withdraw protocol-wide). Unit-demonstrable in strike_nav_matrix_tests.
     - `rebate-claim-griefing` — permissionless claim wrapper + stake-scaled one-shot rebate: griefer claims at active_stake=0, victim's rebate → 0, residual to pool. plp.move:288-314 lacks assert_owner (contrast stake_deep).
   - **GREEN pins (write as normal tests):** stranded-rebate-reserve, large-lp-withdraw-starvation, pyth-staleness-forward-discontinuity, incentive-compound-zero-release, ewma-first-trade-poisoning, value-in-dusdc-overflow (envelope), svi-no-arbitrage-validation (pin what assert_valid_svi does/doesn't check).
   - **ACCEPTED-DOCUMENT:** circuit-breaker-envelope-loose, ewma-gas-accumulator-overflow → record in COVERAGE_MATRIX or OPEN_ISSUES, no test.
4. **Wrap-up** — final report format: "N pass, M known-failing (== ledger size)"; manifest check (`grep -rho 'KNOWN-FAILING: BUG-[0-9]\+' packages/predict/tests | sort -u` vs ledger); prettier-format everything touched; both suites run.

## Operational learnings (also in memory)

- **Agent-tool `isolation: worktree` provisions from a STALE base** (e276939f, not branch HEAD). Always create worktrees manually (`git worktree add --detach /tmp/x HEAD`) and point agents at them. The mandatory staleness gate (`grep floor_shares order.move` + `grep assert_market_backed flow_test_helpers.move`) caught it — keep it in every agent prompt.
- Concurrent `sui move test` in one package dir is unsafe (shared build dir) — one build per worktree.
- `gen_coverage_matrix.py` regex must allow fully-qualified `pkg::module::EConst` abort codes (fixed).
- `bunx` is not on PATH in this shell; use `npx --yes -p @mysten/prettier-plugin-move prettier-move`.
- Leveraged orders must be semi-infinite (order.move `assert_valid_order_shape`: lower index 0 OR higher == max) — fixture orders for liquidation_book tests need lower=0.
- `EMaxCapsReached` is gas-bound (1000-cap linear VecSet ≈ >100B gas at ~750 mints); `builder_code::ENotOwner` blocked on system-only `sui::accumulator::AccumulatorRoot`.
