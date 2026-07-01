#!/usr/bin/env bash
# Create N isolated git worktrees, each able to run ONE concurrent localnet stress sweep.
#
# Why worktrees: run.sh publishes by mutating packages/*/Move.toml in its OWN packages dir,
# so two concurrent localnets must NOT share a checkout. One worktree == one localnet.
# Ports are isolated via SIM_PORT_OFFSET (run.sh maps it to --fullnode-rpc-port / --with-faucet
# plus a client.yaml rewrite; the genesis swarm/validator ports are already disjoint per run,
# so never rewrite the genesis .blob — doing so desyncs the config from the baked committee).
#
# Usage:  bash stress/setup_pool.sh <N> [base_ref]
#   N         number of pool worktrees (size to ~cpu_cores-2; each localnet ~2-3 GB RAM)
#   base_ref  commit/branch to check out (default: current HEAD)
set -euo pipefail
N="${1:?usage: setup_pool.sh <N> [base_ref]}"
BASE="${2:-HEAD}"
REPO="$(git rev-parse --show-toplevel)"
SIM_REL="packages/predict/simulations"
SRC="$REPO/$SIM_REL"

[ -d "$SRC/node_modules" ] || { echo "ERROR: $SRC/node_modules missing — run the sim once (or npm/bun install) first"; exit 1; }
[ -f "$SRC/data/scenario_dataset.csv" ] \
  || echo "WARN: $SRC/data/scenario_dataset.csv (gitignored scenario source) missing — pool runs may fail to generate scenarios"

for i in $(seq 1 "$N"); do
  off=$((i * 100))
  WT="$REPO/.worktrees/sim-pool-$off"
  if [ ! -d "$WT" ]; then
    git -C "$REPO" worktree add --detach "$WT" "$BASE" >/dev/null
  fi
  SIM="$WT/$SIM_REL"
  # node_modules + the gitignored scenario dataset are absent from a fresh checkout — share them.
  [ -e "$SIM/node_modules" ] || ln -s "$SRC/node_modules" "$SIM/node_modules"
  [ -f "$SIM/data/scenario_dataset.csv" ] \
    || cp "$SRC/data/scenario_dataset.csv" "$SIM/data/scenario_dataset.csv" 2>/dev/null || true
  printf 'pool[%d]  %-52s  SIM_PORT_OFFSET=%-4s rpc :%s\n' "$i" "$WT" "$off" "$((9000+off))"
done

cat <<EOF

Pool of $N worktrees ready. Drive it (one sweep per worktree, in parallel):

  for off in \$(seq 100 100 $((N*100))); do
    WT="$REPO/.worktrees/sim-pool-\$off"
    bash "\$WT/$SIM_REL/stress/sweep.sh" "\$WT/$SIM_REL" "\$off" <config-chunk-file> "out-\$off.csv" &
  done; wait

Generate + round-robin partition configs with gen_configs.py (see README.md).
Tear down later with:  git worktree remove .worktrees/sim-pool-<off>
EOF
