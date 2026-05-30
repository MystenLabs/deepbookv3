#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PREDICT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
PACKAGES_DIR="$(cd "$PREDICT_DIR/.." && pwd)"
REPO_DIR="$(cd "$PACKAGES_DIR/.." && pwd)"
if [ -n "${SUI_BINARY:-}" ]; then
  SUI="$SUI_BINARY"
elif [ -x "$HOME/.local/bin/sui" ]; then
  SUI="$HOME/.local/bin/sui"
else
  SUI="$(command -v sui)"
fi

DUSDC_DIR="$PACKAGES_DIR/dusdc"
RUNS_DIR="$SCRIPT_DIR/runs"
BUILD_ENV="sim"
SCENARIO_CONFIG="$SCRIPT_DIR/data/scenario_config.json"

# --- Flag defaults ---
PYTHON_ONLY=0
KEEP_DERIVED=0
SKIP_ANALYSIS=0
RUN_MAX_ROWS=""
RUN_MAX_ROWS_SET=0

usage() {
  cat <<EOF
Usage:
  bash run.sh
  bash run.sh --python-only
  bash run.sh --sim_max_rows=N
  bash run.sh --python-only --keep-derived
EOF
}

# --- Parse flags ---
while [[ $# -gt 0 ]]; do
  case "$1" in
    --sim_max_rows=*)
      RUN_MAX_ROWS="${1#*=}"
      RUN_MAX_ROWS_SET=1
      shift
      ;;
    --python-only)
      PYTHON_ONLY=1
      shift
      ;;
    --keep-derived)
      KEEP_DERIVED=1
      shift
      ;;
    --skip-analysis)
      SKIP_ANALYSIS=1
      shift
      ;;
    *)
      echo "Unknown argument: $1"
      usage
      exit 1
      ;;
  esac
done

if [ "$PYTHON_ONLY" -eq 0 ] && [ "$RUN_MAX_ROWS_SET" -eq 0 ] && [ -n "${SIM_MAX_ROWS:-}" ]; then
  RUN_MAX_ROWS="$SIM_MAX_ROWS"
  RUN_MAX_ROWS_SET=1
fi

if [ "$RUN_MAX_ROWS_SET" -eq 1 ] && ! [[ "$RUN_MAX_ROWS" =~ ^[1-9][0-9]*$ ]]; then
  echo "ERROR: --sim_max_rows must be a positive integer"
  usage
  exit 1
fi

if [ "$PYTHON_ONLY" -eq 1 ] && [ "$RUN_MAX_ROWS_SET" -eq 1 ]; then
  echo "ERROR: --sim_max_rows is only supported for the full localnet/Python flow"
  usage
  exit 1
fi

if [ "$PYTHON_ONLY" -eq 0 ] && [ "$KEEP_DERIVED" -eq 1 ]; then
  echo "ERROR: --keep-derived is only supported with --python-only"
  usage
  exit 1
fi

if [ "$PYTHON_ONLY" -eq 1 ] && [ "$SKIP_ANALYSIS" -eq 1 ]; then
  echo "ERROR: --skip-analysis is only supported for the localnet benchmark flow"
  usage
  exit 1
fi

# --- Determine instance ---
INSTANCE_ID="$(date +%b%d-%H%M | tr '[:upper:]' '[:lower:]')"
if [ -d "$RUNS_DIR/$INSTANCE_ID" ]; then
  suffix=2
  while [ -d "$RUNS_DIR/${INSTANCE_ID}-${suffix}" ]; do
    suffix=$((suffix + 1))
  done
  INSTANCE_ID="${INSTANCE_ID}-${suffix}"
fi
INSTANCE_DIR="$RUNS_DIR/$INSTANCE_ID"
mkdir -p "$INSTANCE_DIR"

CONFIG_DIR="$INSTANCE_DIR/localnet"
CLIENT_CONFIG="$CONFIG_DIR/client.yaml"
export INSTANCE_DIR

echo ""
echo "==> Instance: $INSTANCE_ID"
echo ""

cleanup_generated() {
  rm -rf "$SCRIPT_DIR/data/generated" 2>/dev/null || true
}

cleanup_long_outputs() {
  if [ "$KEEP_DERIVED" -eq 0 ]; then
    rm -f "$INSTANCE_DIR/artifacts/python_long_data.json" "$INSTANCE_DIR/artifacts/python_derived.json" 2>/dev/null || true
  fi
}

early_cleanup() {
  cleanup_generated
}
trap early_cleanup EXIT

generate_scenario() {
  local mode="$1"
  local out="$2"
  local source="${3:-}"
  local args=(
    data/generate_scenario.py
    --mode "$mode"
    --config "$SCENARIO_CONFIG"
    --out "$out"
  )
  if [ -n "$source" ]; then
    args+=(--source "$source")
  fi
  (cd "$SCRIPT_DIR" && python3 "${args[@]}")
}

run_long_python_replay() {
  local scenario="$1"
  local out="$2"
  local args=(
    python_replay.py
    --scenario "$scenario"
    --out "$out"
    --derived-out "$INSTANCE_DIR/artifacts/python_derived.json"
    --config "$SCENARIO_CONFIG"
    --long-run
  )
  if [ -n "$RUN_MAX_ROWS" ]; then
    args+=(--max-rows "$RUN_MAX_ROWS")
  fi
  (cd "$SCRIPT_DIR" && python3 "${args[@]}")
}

if [ "$PYTHON_ONLY" -eq 1 ]; then
  mkdir -p "$INSTANCE_DIR/artifacts"
  cleanup_generated
  PYTHON_SCENARIO="$SCRIPT_DIR/data/generated/long_scenario.csv"
  PYTHON_LONG_DATA="$INSTANCE_DIR/artifacts/python_long_data.json"
  echo "==> Generating long Python scenario..."
  generate_scenario long "$PYTHON_SCENARIO"
  echo "==> Running Python replay only..."
  run_long_python_replay "$PYTHON_SCENARIO" "$PYTHON_LONG_DATA"
  echo "==> Writing economic summary..."
  (cd "$SCRIPT_DIR" && python3 summarize_economics.py "$INSTANCE_DIR/artifacts")
  echo ""
  echo "==> Rendering charts..."
  (cd "$SCRIPT_DIR" && python3 charts/chart_market_overview.py "$PYTHON_LONG_DATA" "$INSTANCE_DIR/artifacts/python_derived.json")
  (cd "$SCRIPT_DIR" && python3 charts/chart_vault_pnl_fee_coverage.py "$INSTANCE_DIR/artifacts/python_derived.json")
  (cd "$SCRIPT_DIR" && python3 charts/chart_vault_risk_profile.py "$INSTANCE_DIR/artifacts/python_derived.json")
  (cd "$SCRIPT_DIR" && python3 charts/chart_liquidation_coverage.py "$INSTANCE_DIR/artifacts/python_derived.json")
  (cd "$SCRIPT_DIR" && python3 charts/chart_liquidation_execution_quality.py "$PYTHON_LONG_DATA")
  echo "==> Updating economic summary..."
  (cd "$SCRIPT_DIR" && python3 summarize_economics.py "$INSTANCE_DIR/artifacts")
  cleanup_long_outputs
  echo "==> Finalizing economic summary..."
  (cd "$SCRIPT_DIR" && python3 summarize_economics.py "$INSTANCE_DIR/artifacts")
  echo ""
  echo "==> Done. Instance: $INSTANCE_ID"
  echo "    Summary: $INSTANCE_DIR/artifacts/economic_summary.json"
  exit 0
fi

# --- Helpers ---
sui_client() {
  "$SUI" client --client.config "$CLIENT_CONFIG" "$@"
}

cleanup() {
  for f in "$PACKAGES_DIR"/deepbook/Move.toml "$PACKAGES_DIR"/token/Move.toml "$PREDICT_DIR/Move.toml" "$PREDICT_DIR/Move.lock" "$DUSDC_DIR/Move.toml"; do
    [ -f "$f.bak" ] && mv "$f.bak" "$f"
  done
  for f in "$PACKAGES_DIR"/deepbook/Published.toml "$PACKAGES_DIR"/token/Published.toml "$PREDICT_DIR/Published.toml" "$DUSDC_DIR/Published.toml"; do
    if [ -f "$f.bak" ]; then
      mv "$f.bak" "$f"
    fi
  done
  find "$PACKAGES_DIR" -name "Pub.sim.toml" -delete 2>/dev/null || true
  find "$PACKAGES_DIR" -name "Pub.localnet.toml" -delete 2>/dev/null || true
  find "$SCRIPT_DIR" -maxdepth 1 -name "Pub.*.toml" -delete 2>/dev/null || true
  find "$REPO_DIR" -maxdepth 1 -name "Pub.*.toml" -delete 2>/dev/null || true
  cleanup_generated
  if [ -n "${SUI_PID:-}" ]; then
    echo "Stopping localnet (pid $SUI_PID)..."
    kill "$SUI_PID" 2>/dev/null || true
    wait "$SUI_PID" 2>/dev/null || true
  fi
}
trap cleanup EXIT

inject_env() {
  local file="$1" chain_id="$2"
  cp "$file" "$file.bak"
  # Use temp file for sed compatibility across macOS and Linux.
  sed '/^sim = /d; /^localnet = /d' "$file" > "$file.tmp" && mv "$file.tmp" "$file"
  if grep -q '^\[environments\]' "$file"; then
    sed '/^\[environments\]/a\
'"${BUILD_ENV}"' = "'"$chain_id"'"
' "$file" > "$file.tmp" && mv "$file.tmp" "$file"
  else
    printf '\n[environments]\n%s = "%s"\n' "$BUILD_ENV" "$chain_id" >> "$file"
  fi
}

check_publish() {
  local output="$1" label="$2"
  if ! echo "$output" | python3 -c "import json,sys; d=json.load(sys.stdin); assert len(d.get('objectChanges',[])) > 0" 2>/dev/null; then
    echo "$label publish failed:"
    echo "$output" | tail -40
    exit 1
  fi
}

extract_published_package_id() {
  python3 -c '
import json, sys
data = json.load(sys.stdin)
published = [c for c in data.get("objectChanges", []) if c.get("type") == "published"]
print(published[-1]["packageId"])
'
}

extract_created_object_id() {
  python3 -c '
import json, sys
needles = sys.argv[1:]
data = json.load(sys.stdin)
for change in data.get("objectChanges", []):
    ot = change.get("objectType", "")
    if change.get("type") == "created" and all(n in ot for n in needles):
        print(change["objectId"])
        break
' "$@"
}

publish_package() {
  local package_path="$1"
  sui_client test-publish \
    --build-env "$BUILD_ENV" --with-unpublished-dependencies --gas-budget 2000000000 \
    --skip-dependency-verification --allow-dirty --force --json \
    --pubfile-path "$INSTANCE_DIR/Pub.$BUILD_ENV.toml" "$package_path" \
    2>/tmp/sui-publish.err || true
}

# --- 1. Genesis ---
echo "==> Generating fresh genesis..."
rm -rf "$CONFIG_DIR"
mkdir -p "$CONFIG_DIR"
$SUI genesis --force --working-dir "$CONFIG_DIR"

# --- 2. Start localnet ---
echo "==> Starting localnet..."
$SUI start --network.config "$CONFIG_DIR" --with-faucet &
SUI_PID=$!

echo -n "    Waiting for RPC"
for i in $(seq 1 30); do
  if curl -s http://127.0.0.1:9000 -X POST -H 'Content-Type: application/json' \
    -d '{"jsonrpc":"2.0","id":1,"method":"sui_getLatestCheckpointSequenceNumber","params":[]}' \
    2>/dev/null | grep -q result; then
    echo " ready!"
    break
  fi
  echo -n "."
  sleep 1
  [ "$i" -eq 30 ] && { echo " TIMEOUT"; exit 1; }
done

# --- 3. Setup (publish packages) ---
  ACTIVE_ADDR=$(sui_client active-address)
  echo "==> Active address: $ACTIVE_ADDR"

  echo -n "    Waiting for faucet"
  for i in $(seq 1 30); do
    curl -s http://127.0.0.1:9123/ >/dev/null 2>&1 && { echo " ready!"; break; }
    echo -n "."
    sleep 1
    [ "$i" -eq 30 ] && echo " TIMEOUT"
  done

  echo "==> Requesting faucet (2x)..."
  for _ in 1 2; do
    curl -s -X POST http://127.0.0.1:9123/v1/gas \
      -H 'Content-Type: application/json' \
      -d "{\"FixedAmountRequest\":{\"recipient\":\"$ACTIVE_ADDR\"}}" || true
    echo ""
    sleep 1
  done
  sleep 1

  CHAIN_ID=$(curl -s http://127.0.0.1:9000 -X POST -H 'Content-Type: application/json' \
    -d '{"jsonrpc":"2.0","id":1,"method":"sui_getChainIdentifier","params":[]}' | \
    python3 -c "import json,sys; print(json.load(sys.stdin)['result'])")
  echo "    Chain ID: $CHAIN_ID"

  find "$PACKAGES_DIR" -name "Pub.*.toml" -delete 2>/dev/null || true
  find "$SCRIPT_DIR" -maxdepth 1 -name "Pub.*.toml" -delete 2>/dev/null || true
  find "$REPO_DIR" -maxdepth 1 -name "Pub.*.toml" -delete 2>/dev/null || true
  for f in "$PACKAGES_DIR"/deepbook/Published.toml "$PACKAGES_DIR"/token/Published.toml "$PREDICT_DIR/Published.toml" "$DUSDC_DIR"/Published.toml; do
    [ -f "$f" ] && cp "$f" "$f.bak"
  done

  # Publish deepbook
  echo "==> Phase 1: Publishing deepbook..."
  inject_env "$PACKAGES_DIR/deepbook/Move.toml" "$CHAIN_ID"
  inject_env "$PACKAGES_DIR/token/Move.toml" "$CHAIN_ID"

  DEEPBOOK_OUTPUT=$(publish_package "$PACKAGES_DIR/deepbook" "Deepbook")
  check_publish "$DEEPBOOK_OUTPUT" "Deepbook"

  DEEPBOOK_PKG=$(echo "$DEEPBOOK_OUTPUT" | extract_published_package_id)
  echo "    Deepbook: $DEEPBOOK_PKG"

  mv "$PACKAGES_DIR/deepbook/Move.toml.bak" "$PACKAGES_DIR/deepbook/Move.toml"
  mv "$PACKAGES_DIR/token/Move.toml.bak" "$PACKAGES_DIR/token/Move.toml"

  # Publish dusdc
  echo "==> Phase 2: Publishing dusdc..."
  inject_env "$DUSDC_DIR/Move.toml" "$CHAIN_ID"

  DUSDC_OUTPUT=$(publish_package "$DUSDC_DIR" "DUSDC")
  check_publish "$DUSDC_OUTPUT" "DUSDC"

  DUSDC_PACKAGE_ID=$(echo "$DUSDC_OUTPUT" | extract_published_package_id)
  DUSDC_CURRENCY_ID=$(echo "$DUSDC_OUTPUT" | extract_created_object_id "coin_registry::Currency" "dusdc::DUSDC")
  TREASURY_CAP_ID=$(echo "$DUSDC_OUTPUT" | extract_created_object_id "TreasuryCap")

  echo "    DUSDC: $DUSDC_PACKAGE_ID"
  echo "    DUSDC Currency: $DUSDC_CURRENCY_ID"
  echo "    TreasuryCap: $TREASURY_CAP_ID"

  mv "$DUSDC_DIR/Move.toml.bak" "$DUSDC_DIR/Move.toml"

  # predict's Move.toml depends on the real `pyth_lazer` package via git, which
  # transitively pulls in `wormhole`. Wormhole's source is designed to be
  # linked as pre-published bytecode via `dep-replacements.testnet/mainnet`
  # and cannot be compiled fresh against 2024.beta (old `struct` / `friend`
  # syntax). Localnet has no pre-published ids, so both deps
  # are unavailable here. Point predict at a local stub pyth_lazer for sim
  # builds — the stub exposes just the symbols `pyth_source::update_from_lazer`
  # references so the module typechecks without the real deps.
  #
  # We can't just drop it in as a `local` dep at 0x0 alongside predict: both
  # packages would compile into the same 0x0 namespace and predict's own
  # `deepbook_predict::i64` module collides with stub's `pyth_lazer::i64`. So
  # publish the stub first in its own tx, capture its real address, then
  # point predict at it via `dep-replacements.sim` with `published-at` set.
  # test-publish regenerates `[pinned.sim.*]` entries in predict/Move.lock with
  # instance-specific local paths. Snapshot so cleanup restores it to pristine.
  cp "$PREDICT_DIR/Move.lock" "$PREDICT_DIR/Move.lock.bak"

  echo "==> Phase 2b: Publishing pyth_lazer stub..."
  STUB_PYTH_LAZER_DIR="$SCRIPT_DIR/stubs/pyth_lazer"
  DEPS_DIR="$INSTANCE_DIR/deps"
  rm -rf "$DEPS_DIR"
  mkdir -p "$DEPS_DIR"
  cp -R "$STUB_PYTH_LAZER_DIR" "$DEPS_DIR/pyth_lazer"
  inject_env "$DEPS_DIR/pyth_lazer/Move.toml" "$CHAIN_ID"

  STUB_OUTPUT=$(publish_package "$DEPS_DIR/pyth_lazer" "pyth_lazer_stub")
  check_publish "$STUB_OUTPUT" "pyth_lazer stub"
  STUB_PKG_ID=$(echo "$STUB_OUTPUT" | extract_published_package_id)
  echo "    pyth_lazer stub: $STUB_PKG_ID"

  # Publish predict
  echo "==> Phase 3: Publishing predict..."

  inject_env "$PREDICT_DIR/Move.toml" "$CHAIN_ID"
  python3 - "$PREDICT_DIR/Move.toml" "$DEPS_DIR/pyth_lazer" "$STUB_PKG_ID" <<'PY'
import pathlib, re, sys
toml_path = pathlib.Path(sys.argv[1])
pyth_lazer_path = sys.argv[2]
stub_pkg_id = sys.argv[3]
text = toml_path.read_text()
# Rewrite main git dep to point at the local stub (for source-level typecheck).
text = re.sub(
    r"pyth_lazer = \{ git[^}]*\}",
    f'pyth_lazer = {{ local = "{pyth_lazer_path}" }}',
    text,
)
# Drop the testnet dep-replacements block (its published-at points at testnet,
# not our sim-local stub).
text = re.sub(r"\[dep-replacements\.testnet\][^\[]*", "", text)
# Add a sim dep-replacements block pinning pyth_lazer to the just-published
# stub address. Without this, sui would try to link pyth_lazer as unpublished
# (address 0x0), colliding with deepbook_predict's own 0x0 i64 module.
text = text.rstrip() + (
    f'\n\n[dep-replacements.sim]\n'
    f'pyth_lazer = {{ local = "{pyth_lazer_path}", '
    f'published-at = "{stub_pkg_id}", original-id = "{stub_pkg_id}" }}\n'
)
toml_path.write_text(text)
PY

  PREDICT_OUTPUT=$(publish_package "$PREDICT_DIR" "Predict")
  check_publish "$PREDICT_OUTPUT" "Predict"

  PACKAGE_ID=$(echo "$PREDICT_OUTPUT" | extract_published_package_id)
  REGISTRY_ID=$(echo "$PREDICT_OUTPUT" | extract_created_object_id "registry::Registry")
  ADMIN_CAP_ID=$(echo "$PREDICT_OUTPUT" | extract_created_object_id "registry::AdminCap")
  PROTOCOL_CONFIG_ID=$(echo "$PREDICT_OUTPUT" | extract_created_object_id "protocol_config::ProtocolConfig")
  POOL_VAULT_ID=$(echo "$PREDICT_OUTPUT" | extract_created_object_id "plp::PoolVault")

  echo "    Predict: $PACKAGE_ID"
  echo "    Registry: $REGISTRY_ID"
  echo "    AdminCap: $ADMIN_CAP_ID"
  echo "    ProtocolConfig: $PROTOCOL_CONFIG_ID"
  echo "    PoolVault: $POOL_VAULT_ID"

  mv "$PREDICT_DIR/Move.toml.bak" "$PREDICT_DIR/Move.toml"

  # Write env file
  cat > "$INSTANCE_DIR/.env.localnet" <<EOF
PACKAGE_ID=$PACKAGE_ID
REGISTRY_ID=$REGISTRY_ID
ADMIN_CAP_ID=$ADMIN_CAP_ID
PROTOCOL_CONFIG_ID=$PROTOCOL_CONFIG_ID
POOL_VAULT_ID=$POOL_VAULT_ID
DUSDC_PACKAGE_ID=$DUSDC_PACKAGE_ID
DUSDC_CURRENCY_ID=$DUSDC_CURRENCY_ID
TREASURY_CAP_ID=$TREASURY_CAP_ID
ACTIVE_ADDRESS=$ACTIVE_ADDR
RPC_URL=http://127.0.0.1:9000
KEYSTORE_PATH=$CONFIG_DIR/sui.keystore
EOF
  echo "==> Wrote .env.localnet"

# --- 4. Run simulation ---
cd "$SCRIPT_DIR"
cleanup_generated

NORMAL_SCENARIO="$SCRIPT_DIR/data/generated/normal_scenario.csv"

run_sim() {
  mkdir -p "$INSTANCE_DIR/artifacts"

  if [ -n "${SCENARIO_PATH:-}" ]; then
    echo "==> Generating normal localnet/Python scenario from SCENARIO_PATH..."
    if [ ! -f "$SCENARIO_PATH" ]; then
      echo "ERROR: SCENARIO_PATH does not exist: $SCENARIO_PATH"
      exit 1
    fi
    generate_scenario normal "$NORMAL_SCENARIO" "$SCENARIO_PATH"
  else
    echo "==> Generating normal localnet/Python scenario..."
    generate_scenario normal "$NORMAL_SCENARIO"
  fi
  cp "$NORMAL_SCENARIO" "$INSTANCE_DIR/artifacts/normal_scenario.csv"

  if [ -n "$RUN_MAX_ROWS" ]; then
    set -- "$@" --max-rows "$RUN_MAX_ROWS"
  fi
  if [ "$SKIP_ANALYSIS" -eq 1 ]; then
    set -- "$@" --skip-python
  fi
  SCENARIO_PATH="$NORMAL_SCENARIO" npx tsx src/sim.ts "$@"
}

echo "==> Running simulation (setup + execute)..."
run_sim

for required_artifact in \
  "$INSTANCE_DIR/artifacts/local_trace.json" \
  "$INSTANCE_DIR/artifacts/local_data.json"; do
  if [ ! -f "$required_artifact" ]; then
    echo "ERROR: expected simulation artifact was not written: $required_artifact"
    exit 1
  fi
done

if [ "$SKIP_ANALYSIS" -eq 1 ]; then
  echo "==> Writing benchmark results..."
  python3 write_benchmark_results.py "$INSTANCE_DIR/artifacts/local_trace.json" "$INSTANCE_DIR/artifacts/results.json"
  echo ""
  echo "==> Done. Instance: $INSTANCE_ID"
  echo "    Results: $INSTANCE_DIR/artifacts/results.json"
  exit 0
fi

if [ ! -f "$INSTANCE_DIR/artifacts/python_data.json" ]; then
  echo "ERROR: expected simulation artifact was not written: $INSTANCE_DIR/artifacts/python_data.json"
  exit 1
fi

echo "==> Rendering gas chart..."
python3 charts/chart_gas.py "$INSTANCE_DIR/artifacts/local_trace.json"

echo "==> Updating economic summary..."
python3 summarize_economics.py "$INSTANCE_DIR/artifacts"

echo ""
echo "==> Checking localnet/Python parity..."
if python3 -c 'import json,sys; a=json.load(open(sys.argv[1])); b=json.load(open(sys.argv[2])); sys.exit(0 if a==b else 1)' \
     "$INSTANCE_DIR/artifacts/local_data.json" "$INSTANCE_DIR/artifacts/python_data.json"; then
  LONG_SCENARIO="$SCRIPT_DIR/data/generated/long_scenario.csv"
  PYTHON_LONG_DATA="$INSTANCE_DIR/artifacts/python_long_data.json"
  echo "    Parity OK. Generating long Python scenario..."
  generate_scenario long "$LONG_SCENARIO"
  echo "==> Running long Python economic replay..."
  run_long_python_replay "$LONG_SCENARIO" "$PYTHON_LONG_DATA"
  echo "==> Writing economic summary..."
  python3 summarize_economics.py "$INSTANCE_DIR/artifacts"
  echo "==> Rendering charts..."
  python3 charts/chart_market_overview.py "$PYTHON_LONG_DATA" "$INSTANCE_DIR/artifacts/python_derived.json"
  python3 charts/chart_vault_pnl_fee_coverage.py "$INSTANCE_DIR/artifacts/python_derived.json"
  python3 charts/chart_vault_risk_profile.py "$INSTANCE_DIR/artifacts/python_derived.json"
  python3 charts/chart_liquidation_coverage.py "$INSTANCE_DIR/artifacts/python_derived.json"
  python3 charts/chart_liquidation_execution_quality.py "$PYTHON_LONG_DATA"
  echo "==> Updating economic summary..."
  python3 summarize_economics.py "$INSTANCE_DIR/artifacts"
  cleanup_long_outputs
  echo "==> Finalizing economic summary..."
  python3 summarize_economics.py "$INSTANCE_DIR/artifacts"
else
  echo "    Parity MISMATCH: skipping long replay and charts."
  echo "    Compare local_data.json vs python_data.json to debug."
  exit 1
fi

echo ""
echo "==> Done. Instance: $INSTANCE_ID"
