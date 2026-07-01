# Predict parallel localnet stress / fuzz infra

Drive many full-localnet stress runs **concurrently** to map the protocol's gas/capacity
and OOG/abort boundaries. Built during the 2026-06 localnet capacity audit; the durable findings live in
`packages/predict/predeploy/stress/` and `packages/predict/predeploy/open-items.md`.

## Why this exists / what it is NOT
`run.sh` is a single-localnet parity harness. A full run does `sui genesis` + publishes all
9 packages + executes a scenario (~3 min setup + sim). To stress at scale you run **N
localnets in parallel**, one per git worktree. This dir adds the orchestration; the heavy
lifting is still `run.sh` + the env-gated stress knobs in `src/sim.ts`.

**Scope:** these knobs vary the **mint + flush** surface only. They map capacity/abort
boundaries and catch *unexpected* aborts — they do NOT exercise redeem/supply/withdraw/
settlement/multi-market adversarial sequences (that needs new scenario code, not new knobs).

## Pieces
| file | role |
|---|---|
| `../run.sh` (`SIM_PORT_OFFSET`) | one isolated localnet on `9000+offset` / faucet `9123+offset` |
| `../src/sim.ts` (stress knobs) | controlled committed-state shapes (see knob table) |
| `setup_pool.sh` | create + provision N worktrees (one localnet each) |
| `sweep.sh` | queue worker: run a config list serially on one worktree, classify each outcome |
| `gen_configs.py` | example generator (the 100-config audit set) + round-robin partition |

## Workflow
```bash
# from packages/predict/simulations
bash stress/setup_pool.sh 6              # → .worktrees/sim-pool-100 .. sim-pool-600
python3 stress/gen_configs.py            # → stress/cfg_pool_w*.txt (+ configs_all.txt)
# one sweep per worktree, in parallel:
for off in 100 200 300 400 500 600; do
  WT="$(git rev-parse --show-toplevel)/.worktrees/sim-pool-$off"
  bash "$WT/packages/predict/simulations/stress/sweep.sh" \
       "$WT/packages/predict/simulations" "$off" \
       stress/cfg_pool_w$off.txt stress/out_$off.csv &
done; wait
cat stress/out_*.csv     # aggregate: status ∈ OK|OOG|ABORT_levpolicy|ABORT_levcap|ABORT_other|FAIL
```
`ABORT_other` = a MoveAbort outside the known guard set = a candidate bug to verify by hand.

## Stress knobs (env; all default to current parity behavior when unset)
| env | meaning |
|---|---|
| `SIM_STRESS_MINT_DUPLICATES=<N>` | enable stress mode; target N total mints |
| `SIM_STRESS_MINT_BATCH_SIZE=<1..100>` | mints per PTB (default 100). =1 builds large committed state via single-mint PTBs |
| `SIM_STRESS_LEVERAGE=<≥1>` | force every stress mint to this leverage (grows the leveraged book / `correction_value` NAV walk) |
| `SIM_STRESS_SINGLE_STRIKE=1` | reuse the first strike (tree stays ~2 nodes → isolates `correction_value` from `walk_linear`) |
| `SIM_FLUSH_AFTER="a,b"` | flush after these rows (override the default checkpoints) |
| `SIM_PORT_OFFSET=<N>` | localnet port offset (set per worktree for parallelism) |
| `--skip-analysis` (flag) | required for stress runs (skips the Python parity step) |

## Gotchas (learned the hard way)
- **One localnet per worktree.** `run.sh` mutates `Move.toml` in its packages dir during
  publish; two concurrent runs in the same checkout corrupt each other.
- **Never rewrite the genesis `.blob` or swarm ports.** Only `client.yaml`'s RPC url is
  rewritten; the fullnode RPC + faucet move via `--fullnode-rpc-port` / `--with-faucet`.
  Swarm/validator/consensus ports are genesis-assigned and already disjoint between runs.
- **`SIM_STRESS_LEVERAGE>1` on a random strike aborts ~25-100%** of the time via
  `assert_mint_probability_and_leverage_policy` (leverage is capped by moneyness) — this is
  correct protocol behaviour, not a harness bug. Use `SIM_STRESS_SINGLE_STRIKE=1` and retry,
  or accept the aborts as part of the fuzz.
- **The wall is computation, not gas budget.** A tx over ~5,000,000 computation units fails
  with `InsufficientGas` regardless of `--gas-budget` (the `max_gas_computation_bucket`).
- **Sizing:** each localnet is ~2-3 GB RAM + a CPU-bound build. N ≈ cpu_cores − 2.
- **Per-config setup (~3 min) dominates;** the sim itself is fast for low PTB counts. Bias
  config batch sizes so `ceil(dup/batch)` stays ≲ 250 (gen_configs.py guards this).
