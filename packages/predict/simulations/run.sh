#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PREDICT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
if [ -n "${SUI_BINARY:-}" ]; then
  SUI="$SUI_BINARY"
elif [ -x "$HOME/.local/bin/sui" ]; then
  SUI="$HOME/.local/bin/sui"
else
  SUI="$(command -v sui)"
fi

RUNS_DIR="$SCRIPT_DIR/runs"
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

# Per-instance localnet ports so multiple isolated localnets can run concurrently.
# `sui genesis` randomizes validator/consensus/metrics ports per run; only the fullnode
# JSON-RPC (9000) and faucet (9123) are fixed, so offsetting just those two isolates an
# instance. Default offset 0 = the original single-instance ports.
PORT_OFFSET="${SIM_PORT_OFFSET:-0}"
RPC_PORT=$((9000 + PORT_OFFSET))
FAUCET_PORT=$((9123 + PORT_OFFSET))

echo ""
echo "==> Instance: $INSTANCE_ID (rpc :$RPC_PORT, faucet :$FAUCET_PORT)"
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
  cleanup_generated
  if [ -n "${SUI_PID:-}" ]; then
    echo "Stopping localnet (pid $SUI_PID)..."
    kill "$SUI_PID" 2>/dev/null || true
    wait "$SUI_PID" 2>/dev/null || true
  fi
}
trap cleanup EXIT

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

json_field() {
  python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))[sys.argv[2]])' "$1" "$2"
}

deployment_field() {
  python3 -c '
import json, sys
value = json.load(open(sys.argv[1]))
for key in sys.argv[2:]:
    value = value[key]
print(value)
' "$DEPLOYMENT_JSON" "$@"
}

# --- 1. Genesis ---
echo "==> Generating fresh genesis..."
rm -rf "$CONFIG_DIR"
mkdir -p "$CONFIG_DIR"
$SUI genesis --force --working-dir "$CONFIG_DIR"

# Per-instance ports for concurrent localnets: set the fullnode RPC via --fullnode-rpc-port
# (overrides the config's 9000) and the faucet via --with-faucet. The swarm/validator/
# consensus ports are genesis-assigned and DISJOINT between runs, so nothing else needs
# offsetting. Only client.yaml's RPC url must follow so the sui CLI talks to this instance.
# (Confirmed: two localnets coexist this way; rewriting the swarm config / genesis .blob does NOT.)
if [ "$PORT_OFFSET" -ne 0 ]; then
  perl -i -pe "s/:9000/:${RPC_PORT}/g" "$CLIENT_CONFIG"
fi

# --- 2. Start localnet ---
echo "==> Starting localnet..."
$SUI start --network.config "$CONFIG_DIR" --fullnode-rpc-port $RPC_PORT --with-faucet=$FAUCET_PORT &
SUI_PID=$!

echo -n "    Waiting for RPC"
for i in $(seq 1 30); do
  if curl -s http://127.0.0.1:$RPC_PORT -X POST -H 'Content-Type: application/json' \
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
    curl -s http://127.0.0.1:$FAUCET_PORT/ >/dev/null 2>&1 && { echo " ready!"; break; }
    echo -n "."
    sleep 1
    [ "$i" -eq 30 ] && echo " TIMEOUT"
  done

  echo "==> Requesting faucet (2x)..."
  for _ in 1 2; do
    curl -s -X POST http://127.0.0.1:$FAUCET_PORT/v1/gas \
      -H 'Content-Type: application/json' \
      -d "{\"FixedAmountRequest\":{\"recipient\":\"$ACTIVE_ADDR\"}}" || true
    echo ""
    sleep 1
  done
  sleep 1

  CHAIN_ID=$(curl -s http://127.0.0.1:$RPC_PORT -X POST -H 'Content-Type: application/json' \
    -d '{"jsonrpc":"2.0","id":1,"method":"sui_getChainIdentifier","params":[]}' | \
    python3 -c "import json,sys; print(json.load(sys.stdin)['result'])")
  echo "    Chain ID: $CHAIN_ID"

  LOCAL_PYTH_CONFIG="$INSTANCE_DIR/local_pyth.json"
  (cd "$SCRIPT_DIR" && npx tsx src/localPythCli.ts "$LOCAL_PYTH_CONFIG")
  LOCAL_PYTH_GOVERNANCE_CHAIN=$(json_field "$LOCAL_PYTH_CONFIG" governanceChain)
  LOCAL_PYTH_GOVERNANCE_CONTRACT=$(json_field "$LOCAL_PYTH_CONFIG" governanceContract)
  LOCAL_PYTH_RECEIVER_CHAIN=$(json_field "$LOCAL_PYTH_CONFIG" receiverChain)
  LOCAL_PYTH_GUARDIAN_PRIVATE_KEY=$(json_field "$LOCAL_PYTH_CONFIG" guardianPrivateKey)
  LOCAL_PYTH_GUARDIAN_ADDRESS=$(json_field "$LOCAL_PYTH_CONFIG" guardianAddress)
  LOCAL_PYTH_SIGNER_PRIVATE_KEY=$(json_field "$LOCAL_PYTH_CONFIG" signerPrivateKey)
  LOCAL_PYTH_SIGNER_PUBLIC_KEY=$(json_field "$LOCAL_PYTH_CONFIG" signerPublicKey)
  LOCAL_PYTH_SIGNER_EXPIRES_AT_SECONDS=$(json_field "$LOCAL_PYTH_CONFIG" signerExpiresAtSeconds)
  LOCAL_BS_SIGNER_PRIVATE_KEY=$(json_field "$LOCAL_PYTH_CONFIG" bsSignerPrivateKey)
  LOCAL_BS_SIGNER_PUBLIC_KEY=$(json_field "$LOCAL_PYTH_CONFIG" bsSignerPublicKey)
  echo "    Local Pyth guardian: $LOCAL_PYTH_GUARDIAN_ADDRESS"

  DEPLOYMENT_JSON="$INSTANCE_DIR/deployment.json"
  echo "==> Staging and publishing the isolated Predict package closure..."
  (
    cd "$PREDICT_DIR"
    SUI_BINARY="$SUI" python3 -m harness.publish \
      --client-config "$CLIENT_CONFIG" \
      --workspace "$INSTANCE_DIR/workspace" \
      --pubfile "$INSTANCE_DIR/Pub.sim.toml" \
      --output "$DEPLOYMENT_JSON"
  )

  PACKAGE_ID=$(deployment_field packages predict)
  REGISTRY_ID=$(deployment_field objects registry)
  ADMIN_CAP_ID=$(deployment_field objects admin_cap)
  PROTOCOL_CONFIG_ID=$(deployment_field objects protocol_config)
  POOL_VAULT_ID=$(deployment_field objects pool_vault)
  ACCOUNT_PACKAGE_ID=$(deployment_field packages account)
  ACCOUNT_REGISTRY_ID=$(deployment_field objects account_registry)
  ACCOUNT_ADMIN_CAP_ID=$(deployment_field objects account_admin_cap)
  FIXED_MATH_PACKAGE_ID=$(deployment_field packages fixed_math)
  BLOCK_SCHOLES_ORACLE_PACKAGE_ID=$(deployment_field packages block_scholes_oracle)
  BS_SIGNER_REGISTRY_ID=$(deployment_field objects bs_signer_registry)
  BS_ADMIN_CAP_ID=$(deployment_field objects bs_admin_cap)
  PROPBOOK_PACKAGE_ID=$(deployment_field packages propbook)
  ORACLE_REGISTRY_ID=$(deployment_field objects oracle_registry)
  ORACLE_REGISTRY_ADMIN_CAP_ID=$(deployment_field objects oracle_registry_admin_cap)
  DUSDC_PACKAGE_ID=$(deployment_field packages dusdc)
  DUSDC_CURRENCY_ID=$(deployment_field objects dusdc_currency)
  TREASURY_CAP_ID=$(deployment_field objects treasury_cap)
  WORMHOLE_PACKAGE_ID=$(deployment_field packages wormhole)
  WORMHOLE_DEPLOYER_CAP_ID=$(deployment_field objects wormhole_deployer_cap)
  WORMHOLE_UPGRADE_CAP_ID=$(deployment_field objects wormhole_upgrade_cap)
  PYTH_LAZER_PACKAGE_ID=$(deployment_field packages pyth_lazer)
  PYTH_LAZER_UPGRADE_CAP_ID=$(deployment_field objects pyth_lazer_upgrade_cap)
  WORMHOLE_INIT_OUTPUT=$(sui_client call \
    --package "$WORMHOLE_PACKAGE_ID" \
    --module setup \
    --function complete \
    --args \
      "$WORMHOLE_DEPLOYER_CAP_ID" \
      "$WORMHOLE_UPGRADE_CAP_ID" \
      "$LOCAL_PYTH_GOVERNANCE_CHAIN" \
      "$LOCAL_PYTH_GOVERNANCE_CONTRACT" \
      0 \
      "[$LOCAL_PYTH_GUARDIAN_ADDRESS]" \
      86400 \
      0 \
    --gas-budget 1000000000 \
    --json)
  WORMHOLE_STATE_ID=$(echo "$WORMHOLE_INIT_OUTPUT" | extract_created_object_id "state::State")
  echo "    Wormhole: $WORMHOLE_PACKAGE_ID"
  echo "    Wormhole State: $WORMHOLE_STATE_ID"

  PYTH_LAZER_INIT_OUTPUT=$(sui_client call \
    --package "$PYTH_LAZER_PACKAGE_ID" \
    --module actions \
    --function init_lazer \
    --args \
      "$PYTH_LAZER_UPGRADE_CAP_ID" \
      "$LOCAL_PYTH_GOVERNANCE_CHAIN" \
      "$LOCAL_PYTH_GOVERNANCE_CONTRACT" \
    --gas-budget 1000000000 \
    --json)
  PYTH_LAZER_STATE_ID=$(echo "$PYTH_LAZER_INIT_OUTPUT" | extract_created_object_id "state::State")
  echo "    Pyth Lazer: $PYTH_LAZER_PACKAGE_ID"
  echo "    Pyth Lazer State: $PYTH_LAZER_STATE_ID"

  echo "    DUSDC: $DUSDC_PACKAGE_ID"
  echo "    Fixed Math: $FIXED_MATH_PACKAGE_ID"
  echo "    Account: $ACCOUNT_PACKAGE_ID"
  echo "    Block Scholes verifier: $BLOCK_SCHOLES_ORACLE_PACKAGE_ID"
  echo "    Propbook: $PROPBOOK_PACKAGE_ID"
  echo "    Predict: $PACKAGE_ID"
  echo "    Registry: $REGISTRY_ID"
  echo "    AdminCap: $ADMIN_CAP_ID"
  echo "    ProtocolConfig: $PROTOCOL_CONFIG_ID"
  echo "    PoolVault: $POOL_VAULT_ID"

  # Whitelist predict's `PredictApp` so its account-authorized flows can mint app auth
  # (mirrors flow_test_helpers' setup_market). AccountRegistry is shared; the admin cap
  # is owned by the publisher.
  sui_client call \
    --package "$ACCOUNT_PACKAGE_ID" \
    --module account_registry \
    --function authorize_app \
    --type-args "${PACKAGE_ID}::predict_account::PredictApp" \
    --args "$ACCOUNT_REGISTRY_ID" "$ACCOUNT_ADMIN_CAP_ID" \
    --gas-budget 1000000000 \
    --json >/dev/null
  echo "    PredictApp authorized on AccountRegistry"

  # Write env file
  cat > "$INSTANCE_DIR/.env.localnet" <<EOF
PACKAGE_ID=$PACKAGE_ID
REGISTRY_ID=$REGISTRY_ID
ADMIN_CAP_ID=$ADMIN_CAP_ID
PROTOCOL_CONFIG_ID=$PROTOCOL_CONFIG_ID
POOL_VAULT_ID=$POOL_VAULT_ID
ACCOUNT_PACKAGE_ID=$ACCOUNT_PACKAGE_ID
ACCOUNT_REGISTRY_ID=$ACCOUNT_REGISTRY_ID
ACCOUNT_ADMIN_CAP_ID=$ACCOUNT_ADMIN_CAP_ID
FIXED_MATH_PACKAGE_ID=$FIXED_MATH_PACKAGE_ID
BLOCK_SCHOLES_ORACLE_PACKAGE_ID=$BLOCK_SCHOLES_ORACLE_PACKAGE_ID
BS_SIGNER_REGISTRY_ID=$BS_SIGNER_REGISTRY_ID
BS_ADMIN_CAP_ID=$BS_ADMIN_CAP_ID
LOCAL_BS_SIGNER_PRIVATE_KEY=$LOCAL_BS_SIGNER_PRIVATE_KEY
LOCAL_BS_SIGNER_PUBLIC_KEY=$LOCAL_BS_SIGNER_PUBLIC_KEY
PROPBOOK_PACKAGE_ID=$PROPBOOK_PACKAGE_ID
ORACLE_REGISTRY_ID=$ORACLE_REGISTRY_ID
ORACLE_REGISTRY_ADMIN_CAP_ID=$ORACLE_REGISTRY_ADMIN_CAP_ID
DUSDC_PACKAGE_ID=$DUSDC_PACKAGE_ID
DUSDC_CURRENCY_ID=$DUSDC_CURRENCY_ID
TREASURY_CAP_ID=$TREASURY_CAP_ID
WORMHOLE_PACKAGE_ID=$WORMHOLE_PACKAGE_ID
WORMHOLE_STATE_ID=$WORMHOLE_STATE_ID
PYTH_LAZER_PACKAGE_ID=$PYTH_LAZER_PACKAGE_ID
PYTH_LAZER_STATE_ID=$PYTH_LAZER_STATE_ID
LOCAL_PYTH_GOVERNANCE_CHAIN=$LOCAL_PYTH_GOVERNANCE_CHAIN
LOCAL_PYTH_GOVERNANCE_CONTRACT=$LOCAL_PYTH_GOVERNANCE_CONTRACT
LOCAL_PYTH_RECEIVER_CHAIN=$LOCAL_PYTH_RECEIVER_CHAIN
LOCAL_PYTH_GUARDIAN_PRIVATE_KEY=$LOCAL_PYTH_GUARDIAN_PRIVATE_KEY
LOCAL_PYTH_SIGNER_PRIVATE_KEY=$LOCAL_PYTH_SIGNER_PRIVATE_KEY
LOCAL_PYTH_SIGNER_PUBLIC_KEY=$LOCAL_PYTH_SIGNER_PUBLIC_KEY
LOCAL_PYTH_SIGNER_EXPIRES_AT_SECONDS=$LOCAL_PYTH_SIGNER_EXPIRES_AT_SECONDS
ACTIVE_ADDRESS=$ACTIVE_ADDR
RPC_URL=http://127.0.0.1:$RPC_PORT
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
if python3 compare_parity.py \
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
