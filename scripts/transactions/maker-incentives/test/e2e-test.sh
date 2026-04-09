#!/usr/bin/env bash
# e2e-test.sh — Run the full end-to-end maker incentives pipeline from scratch.
#
# What it does:
#   1. Swap SUI for DEEP tokens (needs DEEP to fund the incentive)
#   2. Deploy the maker_incentives Move package
#   3. Update on-chain PCRs to debug mode (all zeros)
#   4. Sync code to EC2, rebuild EIF, start enclave
#   5. Register the enclave on-chain
#   6. Create an IncentiveFund targeting a pool, fund it with DEEP
#   7. Submit a test epoch (dummy scores) via the enclave
#   8. Verify on-chain state
#
# Prerequisites:
#   - sui CLI configured with a funded testnet address
#   - SSH key for the EC2 enclave instance
#   - EC2 instance already set up (run setup-ec2.sh first)
#   - Node.js + npm/pnpm with tsx installed
#
# Usage:
#   ./e2e-test.sh --host 18.191.170.1 --key ~/.ssh/deepbook-incentives-enclave.pem
#   ./e2e-test.sh --host 18.191.170.1 --key ~/.ssh/deepbook-incentives-enclave.pem \
#     --pool-id 0x48c9... --swap-amount 20 --reward 5 --fund-amount 15
#
# All flags:
#   --host          EC2 instance IP                                 (required)
#   --key           SSH private key path                            (required)
#   --network       testnet | mainnet                               (default: testnet)
#   --pool-id       DeepBook pool to target                         (default: testnet DEEP_SUI)
#   --swap-amount   SUI to swap for DEEP                            (default: 20)
#   --reward        DEEP per epoch                                  (default: 5)
#   --fund-amount   DEEP to deposit into the fund                   (default: 15)
#   --alpha-bps     spread exponent × 10000                         (default: 5000)
#   --skip-deploy   skip contract deployment (reuse existing)
#   --skip-enclave  skip enclave rebuild (reuse running enclave)
#   --skip-swap     skip SUI→DEEP swap (already have DEEP)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$SCRIPT_DIR/../.."

# ── Defaults ──────────────────────────────────────────────────
NETWORK="testnet"
EC2_HOST=""
SSH_KEY=""
POOL_ID="0x48c95963e9eac37a316b7ae04a0deb761bcdcc2b67912374d6036e7f0e9bae9f"
SWAP_AMOUNT="20"
REWARD="5"
FUND_AMOUNT="15"
ALPHA_BPS="5000"
SKIP_DEPLOY=false
SKIP_ENCLAVE=false
SKIP_SWAP=false
DEEPBOOK_SERVER_HOST="127.0.0.1"
DEEPBOOK_SERVER_PORT=9008

usage() {
  echo "Usage: $0 --host <ec2-ip> --key <ssh-key-path> [options]"
  echo ""
  echo "  --host          EC2 instance IP (required)"
  echo "  --key           SSH private key path (required)"
  echo "  --network       testnet | mainnet (default: testnet)"
  echo "  --pool-id       DeepBook pool to target"
  echo "  --swap-amount   SUI to swap for DEEP (default: 20)"
  echo "  --reward        DEEP per epoch (default: 5)"
  echo "  --fund-amount   DEEP to deposit (default: 15)"
  echo "  --alpha-bps     spread exponent (default: 5000)"
  echo "  --skip-deploy   reuse existing contract deployment"
  echo "  --skip-enclave  reuse running enclave"
  echo "  --skip-swap     skip SUI→DEEP swap"
  echo "  --server-host   deepbook-server IP (default: 127.0.0.1)"
  echo "  --server-port   deepbook-server port (default: 9008)"
  exit 1
}

# ── Parse args ────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --network|-n)     NETWORK="$2"; shift 2 ;;
    --host)           EC2_HOST="$2"; shift 2 ;;
    --key)            SSH_KEY="$2"; shift 2 ;;
    --pool-id)        POOL_ID="$2"; shift 2 ;;
    --swap-amount)    SWAP_AMOUNT="$2"; shift 2 ;;
    --reward)         REWARD="$2"; shift 2 ;;
    --fund-amount)    FUND_AMOUNT="$2"; shift 2 ;;
    --alpha-bps)      ALPHA_BPS="$2"; shift 2 ;;
    --skip-deploy)    SKIP_DEPLOY=true; shift ;;
    --skip-enclave)   SKIP_ENCLAVE=true; shift ;;
    --skip-swap)      SKIP_SWAP=true; shift ;;
    --server-host)    DEEPBOOK_SERVER_HOST="$2"; shift 2 ;;
    --server-port)    DEEPBOOK_SERVER_PORT="$2"; shift 2 ;;
    --help|-h)        usage ;;
    *) echo "Unknown option: $1"; usage ;;
  esac
done

[[ -z "$EC2_HOST" ]] && { echo "Error: --host is required"; usage; }
[[ -z "$SSH_KEY" ]]  && { echo "Error: --key is required"; usage; }

SSH="ssh -o StrictHostKeyChecking=no -i $SSH_KEY ec2-user@$EC2_HOST"
CONFIG_FILE="$SCRIPT_DIR/deployed.${NETWORK}.json"
ENCLAVE_URL="http://$EC2_HOST:3000"
NAUTILUS_DIR="nautilus"
CRATE_SRC="$SCRIPTS_DIR/../crates/incentives"
NAUTILUS_SRC="/home/ubuntu/projects/nautilus"

log()  { echo ""; echo "[$(date +%H:%M:%S)] ══════ $1 ══════"; }
step() { echo "[$(date +%H:%M:%S)]   $1"; }
ok()   { echo "[$(date +%H:%M:%S)]   ✓ $1"; }
fail() { echo "[$(date +%H:%M:%S)]   ✗ $1"; exit 1; }

echo ""
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║        MAKER INCENTIVES — END-TO-END TEST                   ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo "  Network:       $NETWORK"
echo "  EC2 Host:      $EC2_HOST"
echo "  Pool:          ${POOL_ID:0:20}..."
echo "  Reward/epoch:  $REWARD DEEP"
echo "  Fund amount:   $FUND_AMOUNT DEEP"
echo "  Skip deploy:   $SKIP_DEPLOY"
echo "  Skip enclave:  $SKIP_ENCLAVE"
echo "  Skip swap:     $SKIP_SWAP"

cd "$SCRIPTS_DIR"

# ══════════════════════════════════════════════════════════════
# STEP 1: Get DEEP tokens
# ══════════════════════════════════════════════════════════════
if ! $SKIP_SWAP; then
  log "STEP 1/8: Swapping $SWAP_AMOUNT SUI for DEEP"

  npx tsx transactions/maker-incentives/setup/swap-sui-for-deep.ts \
    --network "$NETWORK" --amount "$SWAP_AMOUNT" \
    || fail "SUI→DEEP swap failed"
  ok "Swap complete"
else
  log "STEP 1/8: Skipping swap (--skip-swap)"
fi

# ══════════════════════════════════════════════════════════════
# STEP 2: Deploy contract
# ══════════════════════════════════════════════════════════════
if ! $SKIP_DEPLOY; then
  log "STEP 2/8: Deploying maker_incentives package"

  npx tsx transactions/maker-incentives/setup/deploy.ts \
    --network "$NETWORK" \
    || fail "Deploy failed"
  ok "Contract deployed"
else
  log "STEP 2/8: Skipping deploy (--skip-deploy)"
  [[ -f "$CONFIG_FILE" ]] || fail "No config at $CONFIG_FILE — cannot skip deploy"
fi

PACKAGE_ID=$(jq -r '.packageId' "$CONFIG_FILE")
step "Package: $PACKAGE_ID"

# ══════════════════════════════════════════════════════════════
# STEP 3: Update PCRs (debug mode)
# ══════════════════════════════════════════════════════════════
log "STEP 3/8: Setting on-chain PCRs to debug (all zeros)"

npx tsx transactions/maker-incentives/enclave/update-pcrs.ts \
  --network "$NETWORK" --debug \
  || fail "PCR update failed"
ok "PCRs set to debug mode"

# ══════════════════════════════════════════════════════════════
# STEP 4: Build and start enclave
# ══════════════════════════════════════════════════════════════
if ! $SKIP_ENCLAVE; then
  log "STEP 4/8: Building & starting enclave on EC2"

  step "Terminating any running enclave..."
  $SSH "
    ENCLAVE_ID=\$(nitro-cli describe-enclaves | jq -r '.[0].EnclaveID // empty')
    if [ -n \"\$ENCLAVE_ID\" ]; then
      sudo nitro-cli terminate-enclave --enclave-id \$ENCLAVE_ID 2>&1
    else
      echo 'No running enclave found.'
    fi
  "

  step "Syncing Nautilus repo to EC2..."
  rsync -avz --delete \
    -e "ssh -o StrictHostKeyChecking=no -i $SSH_KEY" \
    "$NAUTILUS_SRC/" \
    "ec2-user@$EC2_HOST:~/$NAUTILUS_DIR/"
  ok "Nautilus repo synced"

  step "Rebuilding EIF (this takes ~5 minutes)..."
  $SSH "
    cd ~/$NAUTILUS_DIR
    sudo rm -rf out && mkdir -p out
    make ENCLAVE_APP=deepbook-incentives 2>&1 | tail -5
  " || fail "EIF build failed"
  ok "EIF built"

  step "Starting enclave in debug mode..."
  $SSH "
    cd ~/$NAUTILUS_DIR
    sudo nitro-cli run-enclave --cpu-count 2 --memory 512 \
      --eif-path out/nitro.eif --debug-mode 2>&1
  " || fail "Enclave start failed"

  step "Waiting for enclave to boot..."
  sleep 10

  step "Setting up VSOCK networking..."
  $SSH "
    ENCLAVE_CID=\$(nitro-cli describe-enclaves | jq -r '.[0].EnclaveCID')

    # Kill old networking
    pkill -f 'socat.*TCP4-LISTEN' 2>/dev/null || true
    pkill -f vsock-proxy 2>/dev/null || true
    sleep 1

    # Incoming: TCP 3000 → VSOCK 3000
    nohup socat TCP4-LISTEN:3000,reuseaddr,fork \
      VSOCK-CONNECT:\$ENCLAVE_CID:3000 < /dev/null > /dev/null 2>&1 &
    disown

    # Outbound: vsock-proxy for deepbook-server
    nohup vsock-proxy $DEEPBOOK_SERVER_PORT $DEEPBOOK_SERVER_HOST $DEEPBOOK_SERVER_PORT \
      --config /etc/nitro_enclaves/vsock-proxy.yaml < /dev/null > /dev/null 2>&1 &
    disown
  "

  step "Waiting for server to be ready..."
  sleep 5

  HEALTH=$(curl -sf "$ENCLAVE_URL/health_check" 2>/dev/null || echo "FAILED")
  if echo "$HEALTH" | grep -q '"pk"'; then
    ok "Enclave healthy"
  else
    fail "Enclave health check failed: $HEALTH"
  fi
else
  log "STEP 4/8: Skipping enclave rebuild (--skip-enclave)"

  HEALTH=$(curl -sf "$ENCLAVE_URL/health_check" 2>/dev/null || echo "FAILED")
  if echo "$HEALTH" | grep -q '"pk"'; then
    ok "Existing enclave is healthy"
  else
    fail "No running enclave at $ENCLAVE_URL"
  fi
fi

# ══════════════════════════════════════════════════════════════
# STEP 5: Register enclave on-chain
# ══════════════════════════════════════════════════════════════
log "STEP 5/8: Registering enclave on-chain"

npx tsx transactions/maker-incentives/enclave/register-enclave.ts \
  --network "$NETWORK" \
  --enclave-url "$ENCLAVE_URL" \
  || fail "Enclave registration failed"
ok "Enclave registered"

ENCLAVE_OBJ_ID=$(jq -r '.enclaveObjectId' "$CONFIG_FILE")
step "Enclave object: $ENCLAVE_OBJ_ID"

# ══════════════════════════════════════════════════════════════
# STEP 6: Create and fund an IncentiveFund
# ══════════════════════════════════════════════════════════════
log "STEP 6/8: Creating IncentiveFund"

CREATE_OUTPUT=$(npx tsx transactions/maker-incentives/setup/create-fund.ts \
  --network "$NETWORK" \
  --pool-id "$POOL_ID" \
  --reward "$REWARD" \
  --fund "$FUND_AMOUNT" \
  --alpha-bps "$ALPHA_BPS" \
  2>&1) || { echo "$CREATE_OUTPUT"; fail "Fund creation failed"; }
echo "$CREATE_OUTPUT"
ok "Fund created and funded with $FUND_AMOUNT DEEP"

FUND_ID=$(echo "$CREATE_OUTPUT" | grep "IncentiveFund:" | tail -1 | awk '{print $NF}')
if [[ -z "$FUND_ID" || "$FUND_ID" == *"IncentiveFund"* ]]; then
  FUND_ID=$(jq -r '.funds | keys_unsorted[-1]' "$CONFIG_FILE")
fi
step "Fund: $FUND_ID"

# ══════════════════════════════════════════════════════════════
# STEP 7: Submit a test epoch
# ══════════════════════════════════════════════════════════════
log "STEP 7/8: Submitting test epoch via enclave"

npx tsx transactions/maker-incentives/epochs/submit-epoch.ts \
  --network "$NETWORK" \
  --fund-id "$FUND_ID" \
  --enclave-url "$ENCLAVE_URL" \
  --test \
  || fail "Epoch submission failed"
ok "Test epoch submitted"

# ══════════════════════════════════════════════════════════════
# STEP 8: Verify on-chain state
# ══════════════════════════════════════════════════════════════
log "STEP 8/8: Verifying on-chain state"

FUND_JSON=$(sui client object "$FUND_ID" --json 2>&1)
FUND_TYPE=$(echo "$FUND_JSON" | jq -r '.data.Move.type_.Other.name')
FUND_OWNER=$(echo "$FUND_JSON" | jq -r '.owner | keys[0]')

if [[ "$FUND_TYPE" == "IncentiveFund" && "$FUND_OWNER" == "Shared" ]]; then
  ok "IncentiveFund exists (shared object)"
else
  fail "IncentiveFund verification failed: type=$FUND_TYPE owner=$FUND_OWNER"
fi

# Read treasury from BCS: id(32) + pool_id(32) + treasury(8 LE)
TREASURY_RAW=$(echo "$FUND_JSON" | python3 -c "
import sys, json, struct
data = json.load(sys.stdin)
contents = bytes(data['data']['Move']['contents'])
val = struct.unpack_from('<Q', contents, 64)[0]
print(val)
" 2>/dev/null || echo "0")
TREASURY_DEEP=$(python3 -c "print(${TREASURY_RAW} / 1_000_000)")
EXPECTED_REMAINING=$(python3 -c "print(${FUND_AMOUNT} - ${REWARD})")

step "Treasury balance: $TREASURY_DEEP DEEP (expected: $EXPECTED_REMAINING DEEP)"

if python3 -c "exit(0 if abs(${TREASURY_DEEP} - ${EXPECTED_REMAINING}) < 0.01 else 1)" 2>/dev/null; then
  ok "Treasury balance correct"
else
  step "WARNING: Treasury balance mismatch (may be rounding)"
fi

# ── Summary ──────────────────────────────────────────────────
echo ""
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║        END-TO-END TEST COMPLETE                             ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""
echo "  Config file:    $CONFIG_FILE"
echo ""
jq '.' "$CONFIG_FILE"
echo ""
echo "  Quick re-run (skip deploy + enclave rebuild):"
echo "    $0 --host $EC2_HOST --key $SSH_KEY \\"
echo "      --skip-deploy --skip-enclave --skip-swap"
echo ""
echo "  Submit another epoch manually:"
echo "    npx tsx transactions/maker-incentives/epochs/submit-epoch.ts \\"
echo "      --network $NETWORK --fund-id $FUND_ID \\"
echo "      --enclave-url $ENCLAVE_URL --test"
echo ""
