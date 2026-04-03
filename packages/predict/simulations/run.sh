#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PREDICT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
PACKAGES_DIR="$(cd "$PREDICT_DIR/.." && pwd)"
REPO_DIR="$(cd "$PACKAGES_DIR/.." && pwd)"
SUI="${SUI_BINARY:-sui}"

DUSDC_DIR="$PACKAGES_DIR/dusdc"
RUNS_DIR="$SCRIPT_DIR/runs"

# --- Flag defaults ---
RESUME=""
RUN_SETUP=0
RUN_SIM=0
EXPLICIT_PHASES=0
LIST=0
SKIP_ANALYSIS=0

usage() {
  cat <<EOF
Usage: $0 [OPTIONS]

Options:
  --resume <id>    Resume an existing instance
  --setup          Only run setup phase (publish + create objects)
  --sim            Only run sim phase (execute mints + analyze)
  --skip-analysis  Skip the post-run visualization step
  --list           List existing instances
  -h, --help       Show this help

Examples:
  $0                              # new instance, full flow
  $0 --setup                      # new instance, stop after setup
  $0 --resume mar30-1422          # resume, auto-detect missing phases
  $0 --resume mar30-1422 --sim    # resume, only run sim + analyze
  $0 --resume mar30-1422 --sim --skip-analysis
EOF
}

# --- Parse flags ---
while [[ $# -gt 0 ]]; do
  case "$1" in
    --resume)
      RESUME="$2"
      shift 2
      ;;
    --setup)
      RUN_SETUP=1
      EXPLICIT_PHASES=1
      shift
      ;;
    --sim)
      RUN_SIM=1
      EXPLICIT_PHASES=1
      shift
      ;;
    --list)
      LIST=1
      shift
      ;;
    --skip-analysis)
      SKIP_ANALYSIS=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1"
      usage
      exit 1
      ;;
  esac
done

# --- List instances ---
if [ "$LIST" -eq 1 ]; then
  if [ ! -d "$RUNS_DIR" ] || [ -z "$(ls -A "$RUNS_DIR" 2>/dev/null)" ]; then
    echo "No instances found."
    exit 0
  fi
  printf "%-20s %-8s %-8s\n" "INSTANCE" "SETUP" "SIM"
  printf "%-20s %-8s %-8s\n" "--------" "-----" "---"
  for dir in "$RUNS_DIR"/*/; do
    id=$(basename "$dir")
    has_setup=$( [ -f "$dir/.env.localnet" ] && echo "done" || echo "-" )
    has_sim=$( [ -f "$dir/artifacts/results.json" ] && echo "done" || echo "-" )
    printf "%-20s %-8s %-8s\n" "$id" "$has_setup" "$has_sim"
  done
  exit 0
fi

# --- Determine instance ---
if [ -n "$RESUME" ]; then
  INSTANCE_ID="$RESUME"
  INSTANCE_DIR="$RUNS_DIR/$INSTANCE_ID"
  if [ ! -d "$INSTANCE_DIR" ]; then
    echo "ERROR: Instance '$INSTANCE_ID' not found at $INSTANCE_DIR"
    exit 1
  fi
else
  # Generate timestamp-based ID
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
fi

CONFIG_DIR="$INSTANCE_DIR/localnet"
CLIENT_CONFIG="$CONFIG_DIR/client.yaml"
export INSTANCE_DIR

echo ""
echo "==> Instance: $INSTANCE_ID"
echo "    Resume:   bash run.sh --resume $INSTANCE_ID"
echo ""

# --- Phase selection ---
if [ -n "$RESUME" ] && [ "$EXPLICIT_PHASES" -eq 0 ]; then
  # Auto-detect missing phases
  [ ! -f "$INSTANCE_DIR/.env.localnet" ] && RUN_SETUP=1
  [ ! -f "$INSTANCE_DIR/artifacts/results.json" ] && RUN_SIM=1

  if [ "$RUN_SETUP" -eq 0 ] && [ "$RUN_SIM" -eq 0 ]; then
    echo "All phases already complete. Nothing to do."
    echo "Use --sim to force a re-run."
    exit 0
  fi
elif [ -z "$RESUME" ] && [ "$EXPLICIT_PHASES" -eq 0 ]; then
  # New instance, full flow
  RUN_SETUP=1
  RUN_SIM=1
elif [ -z "$RESUME" ] && [ "$EXPLICIT_PHASES" -eq 1 ]; then
  # New instance with explicit phase
  if [ "$RUN_SIM" -eq 1 ]; then
    echo "ERROR: --sim requires --resume (need existing instance state)"
    exit 1
  fi
fi

# --- Validate phase preconditions ---
if [ "$RUN_SIM" -eq 1 ] && [ "$RUN_SETUP" -eq 0 ] && [ ! -f "$INSTANCE_DIR/artifacts/state.json" ]; then
  echo "ERROR: --sim requires setup to be completed first (no state.json found)"
  exit 1
fi

# --- Helpers ---
sui_client() {
  "$SUI" client --client.config "$CLIENT_CONFIG" "$@"
}

cleanup() {
  for f in "$PACKAGES_DIR"/deepbook/Move.toml "$PACKAGES_DIR"/token/Move.toml "$PREDICT_DIR/Move.toml" "$DUSDC_DIR/Move.toml"; do
    [ -f "$f.bak" ] && mv "$f.bak" "$f"
  done
  find "$PACKAGES_DIR" -name "Pub.sim.toml" -delete 2>/dev/null || true
  find "$SCRIPT_DIR" -maxdepth 1 -name "Pub.*.toml" -delete 2>/dev/null || true
  find "$REPO_DIR" -maxdepth 1 -name "Pub.*.toml" -delete 2>/dev/null || true
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
  sed '/^sim = /d' "$file" > "$file.tmp" && mv "$file.tmp" "$file"
  if grep -q '^\[environments\]' "$file"; then
    sed '/^\[environments\]/a\
sim = "'"$chain_id"'"
' "$file" > "$file.tmp" && mv "$file.tmp" "$file"
  else
    printf '\n[environments]\nsim = "%s"\n' "$chain_id" >> "$file"
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
  sui_client test-publish "$package_path" \
    --build-env sim --with-unpublished-dependencies --gas-budget 2000000000 \
    --skip-dependency-verification --json 2>/dev/null || true
}

# --- 1. Genesis ---
if [ -z "$RESUME" ]; then
  echo "==> Generating fresh genesis..."
  rm -rf "$CONFIG_DIR"
  mkdir -p "$CONFIG_DIR"
  $SUI genesis --force --working-dir "$CONFIG_DIR" -q
else
  echo "==> Resuming instance $INSTANCE_ID (using existing chain state)"
  if [ ! -d "$CONFIG_DIR" ]; then
    echo "ERROR: localnet dir missing for instance $INSTANCE_ID"
    exit 1
  fi
fi

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
if [ "$RUN_SETUP" -eq 1 ]; then
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
  TREASURY_CAP_ID=$(echo "$DUSDC_OUTPUT" | extract_created_object_id "TreasuryCap")

  echo "    DUSDC: $DUSDC_PACKAGE_ID"
  echo "    TreasuryCap: $TREASURY_CAP_ID"

  mv "$DUSDC_DIR/Move.toml.bak" "$DUSDC_DIR/Move.toml"

  # Publish predict
  echo "==> Phase 3: Publishing predict..."
  inject_env "$PREDICT_DIR/Move.toml" "$CHAIN_ID"

  PREDICT_OUTPUT=$(publish_package "$PREDICT_DIR" "Predict")
  check_publish "$PREDICT_OUTPUT" "Predict"

  PACKAGE_ID=$(echo "$PREDICT_OUTPUT" | extract_published_package_id)
  REGISTRY_ID=$(echo "$PREDICT_OUTPUT" | extract_created_object_id "registry::Registry")
  ADMIN_CAP_ID=$(echo "$PREDICT_OUTPUT" | extract_created_object_id "registry::AdminCap")
  PLP_TREASURY_CAP_ID=$(echo "$PREDICT_OUTPUT" | extract_created_object_id "TreasuryCap" "plp::PLP")

  echo "    Predict: $PACKAGE_ID"
  echo "    Registry: $REGISTRY_ID"
  echo "    AdminCap: $ADMIN_CAP_ID"
  echo "    PLP TreasuryCap: $PLP_TREASURY_CAP_ID"

  mv "$PREDICT_DIR/Move.toml.bak" "$PREDICT_DIR/Move.toml"

  # Write env file
  cat > "$INSTANCE_DIR/.env.localnet" <<EOF
PACKAGE_ID=$PACKAGE_ID
REGISTRY_ID=$REGISTRY_ID
ADMIN_CAP_ID=$ADMIN_CAP_ID
PLP_TREASURY_CAP_ID=$PLP_TREASURY_CAP_ID
DUSDC_PACKAGE_ID=$DUSDC_PACKAGE_ID
TREASURY_CAP_ID=$TREASURY_CAP_ID
ACTIVE_ADDRESS=$ACTIVE_ADDR
RPC_URL=http://127.0.0.1:9000
KEYSTORE_PATH=$CONFIG_DIR/sui.keystore
EOF
  echo "==> Wrote .env.localnet"
fi

# --- 4. Run simulation ---
cd "$SCRIPT_DIR"

MAX_ROWS_ARG=""
if [ -n "${SIM_MAX_ROWS:-}" ]; then
  MAX_ROWS_ARG="--max-rows $SIM_MAX_ROWS"
fi

if [ "$RUN_SETUP" -eq 1 ] && [ "$RUN_SIM" -eq 0 ]; then
  echo "==> Running setup only..."
  npx tsx src/sim.ts --setup-only
elif [ "$RUN_SETUP" -eq 1 ] && [ "$RUN_SIM" -eq 1 ]; then
  echo "==> Running simulation (setup + execute)..."
  npx tsx src/sim.ts $MAX_ROWS_ARG
elif [ "$RUN_SIM" -eq 1 ]; then
  echo "==> Running simulation (execute only)..."
  npx tsx src/sim.ts --execute-only $MAX_ROWS_ARG
fi

if [ "$RUN_SIM" -eq 1 ] && [ "$SKIP_ANALYSIS" -eq 0 ] && [ -f "$INSTANCE_DIR/artifacts/results.json" ]; then
  echo ""
  echo "==> Analyzing results..."
  python3 visualize.py "$INSTANCE_DIR/artifacts/results.json"
fi

echo ""
echo "==> Done. Instance: $INSTANCE_ID"
echo "    Resume: bash run.sh --resume $INSTANCE_ID"
