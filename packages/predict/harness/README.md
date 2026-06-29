# Predict localnet harness

Worktree-free, parallel Sui localnet harness for stress-testing / fuzzing /
bug-finding the Predict contracts. See `DESIGN.md` for the full design.

**Phase 0 (current): the parallel localnet substrate.** Stages the Predict
package closure into a disposable scratch workspace, spins up a fresh localnet on
isolated ports, publishes the full stack, and tears down — all without mutating
the checkout, so many runs go in parallel from a single clone (no git worktrees).

## Usage

Run as a module from `packages/predict/`:

```bash
cd packages/predict

python3 -m harness run                 # one full lifecycle
python3 -m harness run-many 3          # 3 concurrent runs (parallel validation)
python3 -m harness status              # show the slot registry
python3 -m harness cleanup --instances # reclaim stale slots + orphan dirs
```

Ports are auto-allocated (no port flags): each run reserves a free slot from a
locked registry. Retention is automatic — a clean success self-deletes its
instance dir; a **failed** run is kept so you can inspect it. Use `run --keep`
only to retain a successful run too.

Requires the `sui` CLI (resolved via `$SUI_BINARY`, `~/.local/bin/sui`, or
`PATH`) and the `~/.move` cache populated with the Pyth Lazer / Wormhole
`sui-testnet` branches (a normal `sui move build` of predict primes it).

Instance state lives under `.localnets/` (gitignored).
