#!/usr/bin/env bash
# upgrade-enclave.sh — Rebuild the enclave EIF, restart it, update on-chain
# PCRs, and re-register so the new enclave's signatures are accepted.
#
# Usage:
#   ./upgrade-enclave.sh --network testnet --host 3.12.241.119 --key ~/.ssh/enclave.pem
#   ./upgrade-enclave.sh --network testnet --host 3.12.241.119 --key ~/.ssh/enclave.pem --debug
#
# What it does:
#   1. SSH to EC2, terminate running enclave
#   2. rsync local Nautilus repo to EC2 (scoring code lives there)
#   3. Rebuild EIF (make ENCLAVE_APP=deepbook-incentives)
#   4. Extract PCRs from the build output
#   5. Start enclave (--debug-mode if --debug flag)
#   6. Set up socat for incoming traffic (TCP 3000 → VSOCK 3000)
#   7. Update on-chain PCRs (zeros if --debug, real PCRs otherwise)
#   8. Register the new enclave on-chain
#   9. Verify health check
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── Defaults ──────────────────────────────────────────────────
NETWORK="testnet"
EC2_HOST=""
SSH_KEY=""
DEBUG_MODE=false
ENCLAVE_APP="deepbook-incentives"
NAUTILUS_DIR="nautilus"
DEEPBOOK_SERVER_HOST="127.0.0.1"
DEEPBOOK_SERVER_PORT=9008

usage() {
  echo "Usage: $0 --host <ec2-ip> --key <ssh-key-path> [--network testnet|mainnet] [--debug] [--server-host <ip>]"
  exit 1
}

# ── Parse args ────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --network|-n) NETWORK="$2"; shift 2 ;;
    --host|-h)    EC2_HOST="$2"; shift 2 ;;
    --key|-k)     SSH_KEY="$2"; shift 2 ;;
    --debug)      DEBUG_MODE=true; shift ;;
    --server-host)    DEEPBOOK_SERVER_HOST="$2"; shift 2 ;;
    --server-port)    DEEPBOOK_SERVER_PORT="$2"; shift 2 ;;
    *) echo "Unknown option: $1"; usage ;;
  esac
done

[[ -z "$EC2_HOST" ]] && { echo "Error: --host is required"; usage; }
[[ -z "$SSH_KEY" ]]  && { echo "Error: --key is required"; usage; }

SSH="ssh -o StrictHostKeyChecking=no -i $SSH_KEY ec2-user@$EC2_HOST"

log() { echo "[$(date +%H:%M:%S)] $1"; }

# ── Step 1: Terminate old enclave ─────────────────────────────
log "Terminating existing enclave..."
$SSH "
  ENCLAVE_ID=\$(nitro-cli describe-enclaves | jq -r '.[0].EnclaveID // empty')
  if [ -n \"\$ENCLAVE_ID\" ]; then
    sudo nitro-cli terminate-enclave --enclave-id \$ENCLAVE_ID 2>&1
  else
    echo 'No running enclave found.'
  fi
"

# ── Step 2: Rsync local Nautilus repo to EC2 ─────────────────
NAUTILUS_SRC="/home/ubuntu/projects/nautilus"

if [[ -d "$NAUTILUS_SRC" ]]; then
  log "Syncing Nautilus repo to EC2..."
  rsync -avz --delete \
    -e "ssh -o StrictHostKeyChecking=no -i $SSH_KEY" \
    "$NAUTILUS_SRC/" \
    "ec2-user@$EC2_HOST:~/$NAUTILUS_DIR/"
  log "Nautilus repo synced."
else
  log "WARNING: Nautilus repo not found at $NAUTILUS_SRC — skipping sync."
fi

# ── Step 3: Rebuild EIF ───────────────────────────────────────
log "Rebuilding EIF (this takes a few minutes)..."
$SSH "
  cd ~/$NAUTILUS_DIR
  rm -rf out && mkdir out
  make ENCLAVE_APP=$ENCLAVE_APP 2>&1 | tail -5
  echo '--- PCRs ---'
  cat out/nitro.pcrs
"

# ── Step 4: Extract PCRs ─────────────────────────────────────
log "Extracting PCRs from build..."
PCRS_JSON=$($SSH "cat ~/$NAUTILUS_DIR/out/nitro.pcrs")
PCR0=$(echo "$PCRS_JSON" | jq -r '.PCR0')
PCR1=$(echo "$PCRS_JSON" | jq -r '.PCR1')
PCR2=$(echo "$PCRS_JSON" | jq -r '.PCR2')

log "  PCR0: $PCR0"
log "  PCR1: $PCR1"
log "  PCR2: $PCR2"

# ── Step 5: Start enclave ────────────────────────────────────
if $DEBUG_MODE; then
  log "Starting enclave in DEBUG mode..."
  $SSH "
    cd ~/$NAUTILUS_DIR
    sudo nitro-cli run-enclave --cpu-count 2 --memory 512M \
      --eif-path out/nitro.eif --debug-mode 2>&1
  "
else
  log "Starting enclave in PRODUCTION mode..."
  $SSH "
    cd ~/$NAUTILUS_DIR
    sudo nitro-cli run-enclave --cpu-count 2 --memory 512M \
      --eif-path out/nitro.eif 2>&1
  "
fi

log "Waiting for enclave to boot..."
sleep 8

# ── Step 6: Set up networking ─────────────────────────────────
log "Setting up VSOCK networking..."
$SSH "
  ENCLAVE_CID=\$(nitro-cli describe-enclaves | jq -r '.[0].EnclaveCID')
  echo \"Enclave CID: \$ENCLAVE_CID\"

  # Send empty secrets (our app doesn't use secrets)
  echo '{}' | socat - VSOCK-CONNECT:\$ENCLAVE_CID:7777

  # Kill old socat/vsock-proxy
  pkill -f 'socat.*VSOCK' 2>/dev/null || true
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

log "Waiting for server to be ready..."
sleep 5

# Verify health
HEALTH=$(curl -sf "http://$EC2_HOST:3000/health_check" 2>/dev/null || echo "FAILED")
if echo "$HEALTH" | grep -q '"pk"'; then
  PK=$(echo "$HEALTH" | jq -r '.pk')
  log "Enclave healthy — PK: $PK"
else
  echo "ERROR: Enclave health check failed: $HEALTH"
  exit 1
fi

# ── Step 7: Update on-chain PCRs ─────────────────────────────
log "Updating on-chain PCRs..."
cd "$SCRIPT_DIR/../../.."

if $DEBUG_MODE; then
  npx tsx transactions/maker-incentives/enclave/update-pcrs.ts \
    --network "$NETWORK" --debug
else
  npx tsx transactions/maker-incentives/enclave/update-pcrs.ts \
    --network "$NETWORK" \
    --pcr0 "$PCR0" --pcr1 "$PCR1" --pcr2 "$PCR2"
fi

# ── Step 8: Register new enclave ──────────────────────────────
log "Registering enclave on-chain..."
npx tsx transactions/maker-incentives/enclave/register-enclave.ts \
  --network "$NETWORK" \
  --enclave-url "http://$EC2_HOST:3000"

# ── Done ──────────────────────────────────────────────────────
echo ""
echo "============================================================"
echo "  ENCLAVE UPGRADE COMPLETE"
echo "============================================================"
echo "  Network:  $NETWORK"
echo "  Host:     $EC2_HOST"
echo "  Debug:    $DEBUG_MODE"
echo "  PCR0:     $PCR0"
echo ""
echo "  The new enclave is registered and ready to sign epochs."
echo "  Submit all fund epochs with:"
echo "    npx tsx transactions/maker-incentives/submit-all-epochs.ts \\"
echo "      --network $NETWORK --enclave-url http://$EC2_HOST:3000"
echo ""
