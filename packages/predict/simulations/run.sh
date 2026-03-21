#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PREDICT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
PACKAGES_DIR="$(cd "$PREDICT_DIR/.." && pwd)"
REPO_DIR="$(cd "$PACKAGES_DIR/.." && pwd)"
CONFIG_DIR="$SCRIPT_DIR/.localnet"
CLIENT_CONFIG="$CONFIG_DIR/client.yaml"
SUI="${SUI_BINARY:-sui}"

DUSDC_DIR="$PACKAGES_DIR/dusdc"
SETUP_ONLY=0
RUN_ANALYSIS=1

usage() {
  echo "Usage: $0 [--setup-only] [--skip-analysis]"
}

sui_client() {
  "$SUI" client --client.config "$CLIENT_CONFIG" "$@"
}

for arg in "$@"; do
  case "$arg" in
    --setup-only)
      SETUP_ONLY=1
      ;;
    --skip-analysis)
      RUN_ANALYSIS=0
      ;;
    *)
      echo "Unknown argument: $arg"
      usage
      exit 1
      ;;
  esac
done

cleanup() {
  for f in "$PACKAGES_DIR"/deepbook/Move.toml "$PACKAGES_DIR"/token/Move.toml "$PREDICT_DIR/Move.toml" "$DUSDC_DIR/Move.toml"; do
    [ -f "$f.bak" ] && mv "$f.bak" "$f"
  done
  # Clean ephemeral publication files
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
  # Remove any existing sim entry first
  sed -i '' '/^sim = /d' "$file"
  if grep -q '^\[environments\]' "$file"; then
    sed -i '' "/^\[environments\]/a\\
sim = \"$chain_id\"
" "$file"
  else
    printf '\n[environments]\nsim = "%s"\n' "$chain_id" >> "$file"
  fi
}

# Check publish succeeded by looking for objectChanges in JSON output
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
  local object_type_substring="$1"
  python3 -c '
import json, sys
needle = sys.argv[1]
data = json.load(sys.stdin)
for change in data.get("objectChanges", []):
    if change.get("type") == "created" and needle in change.get("objectType", ""):
        print(change["objectId"])
        break
' "$object_type_substring"
}

publish_package() {
  local package_path="$1"

  sui_client test-publish "$package_path" \
    --build-env sim --with-unpublished-dependencies --gas-budget 2000000000 \
    --skip-dependency-verification --json 2>/dev/null || true
}

# --- 1. Fresh genesis ---
echo "==> Generating fresh genesis..."
rm -rf "$CONFIG_DIR"
mkdir -p "$CONFIG_DIR"
$SUI genesis --force --working-dir "$CONFIG_DIR" -q

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

# --- 3. Use local client config + faucet ---
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

# --- 4. Get chain ID ---
CHAIN_ID=$(curl -s http://127.0.0.1:9000 -X POST -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","id":1,"method":"sui_getChainIdentifier","params":[]}' | \
  python3 -c "import json,sys; print(json.load(sys.stdin)['result'])")
echo "    Chain ID: $CHAIN_ID"

find "$PACKAGES_DIR" -name "Pub.*.toml" -delete 2>/dev/null || true
find "$SCRIPT_DIR" -maxdepth 1 -name "Pub.*.toml" -delete 2>/dev/null || true
find "$REPO_DIR" -maxdepth 1 -name "Pub.*.toml" -delete 2>/dev/null || true

# --- 5. Publish deepbook ---
echo "==> Phase 1: Publishing deepbook..."
inject_env "$PACKAGES_DIR/deepbook/Move.toml" "$CHAIN_ID"
inject_env "$PACKAGES_DIR/token/Move.toml" "$CHAIN_ID"

DEEPBOOK_OUTPUT=$(publish_package "$PACKAGES_DIR/deepbook" "Deepbook")
check_publish "$DEEPBOOK_OUTPUT" "Deepbook"

DEEPBOOK_PKG=$(echo "$DEEPBOOK_OUTPUT" | extract_published_package_id)
echo "    Deepbook: $DEEPBOOK_PKG"

mv "$PACKAGES_DIR/deepbook/Move.toml.bak" "$PACKAGES_DIR/deepbook/Move.toml"
mv "$PACKAGES_DIR/token/Move.toml.bak" "$PACKAGES_DIR/token/Move.toml"
# Keep Pub.sim.toml files so predict can resolve the deepbook dependency

# --- 6. Publish dusdc ---
echo "==> Phase 2: Publishing dusdc..."
inject_env "$DUSDC_DIR/Move.toml" "$CHAIN_ID"

DUSDC_OUTPUT=$(publish_package "$DUSDC_DIR" "DUSDC")
check_publish "$DUSDC_OUTPUT" "DUSDC"

DUSDC_PACKAGE_ID=$(echo "$DUSDC_OUTPUT" | extract_published_package_id)
TREASURY_CAP_ID=$(echo "$DUSDC_OUTPUT" | extract_created_object_id "TreasuryCap")

echo "    DUSDC: $DUSDC_PACKAGE_ID"
echo "    TreasuryCap: $TREASURY_CAP_ID"

mv "$DUSDC_DIR/Move.toml.bak" "$DUSDC_DIR/Move.toml"

# --- 7. Publish predict ---
echo "==> Phase 3: Publishing predict..."
inject_env "$PREDICT_DIR/Move.toml" "$CHAIN_ID"

PREDICT_OUTPUT=$(publish_package "$PREDICT_DIR" "Predict")
check_publish "$PREDICT_OUTPUT" "Predict"

PACKAGE_ID=$(echo "$PREDICT_OUTPUT" | extract_published_package_id)
REGISTRY_ID=$(echo "$PREDICT_OUTPUT" | extract_created_object_id "registry::Registry")
ADMIN_CAP_ID=$(echo "$PREDICT_OUTPUT" | extract_created_object_id "registry::AdminCap")

echo "    Predict: $PACKAGE_ID"
echo "    Registry: $REGISTRY_ID"
echo "    AdminCap: $ADMIN_CAP_ID"

mv "$PREDICT_DIR/Move.toml.bak" "$PREDICT_DIR/Move.toml"

# --- 8. Write env file ---
cat > "$SCRIPT_DIR/.env.localnet" <<EOF
PACKAGE_ID=$PACKAGE_ID
REGISTRY_ID=$REGISTRY_ID
ADMIN_CAP_ID=$ADMIN_CAP_ID
DUSDC_PACKAGE_ID=$DUSDC_PACKAGE_ID
TREASURY_CAP_ID=$TREASURY_CAP_ID
ACTIVE_ADDRESS=$ACTIVE_ADDR
RPC_URL=http://127.0.0.1:9000
KEYSTORE_PATH=$CONFIG_DIR/sui.keystore
EOF
echo "==> Wrote .env.localnet"

# --- 9. Run simulation ---
cd "$SCRIPT_DIR"

if [ "$SETUP_ONLY" -eq 1 ]; then
  echo "==> Running setup only..."
  npx tsx src/sim.ts --setup-only
  exit 0
fi

echo "==> Running simulation..."
npx tsx src/sim.ts

if [ "$RUN_ANALYSIS" -eq 1 ]; then
  echo "==> Running analysis..."
  npx tsx src/analyze.ts
else
  echo "==> Simulation complete. Analysis skipped."
fi
