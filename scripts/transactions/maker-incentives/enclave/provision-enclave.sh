#!/usr/bin/env bash
# provision-enclave.sh — Push code, build EIF, start enclave, set up networking.
#
# Prerequisite: Run setup-ec2.sh first on a fresh EC2 instance to install
# Docker, nitro-cli, vsock-proxy, socat, etc.
#
# What this script does (run from your local machine):
#   1. Rsync the local Nautilus repo to EC2 at ~/nautilus
#   2. Build the EIF on EC2 (make ENCLAVE_APP=deepbook-incentives)
#   3. Start the enclave (debug or production mode)
#   4. Set up VSOCK networking (socat + vsock-proxy pointing to --server-host)
#   5. Verify health check
#
# After this, run from the scripts/ directory:
#   - update-pcrs.ts   to write PCR hashes on-chain
#   - register-enclave.ts  to register the enclave's public key on-chain
#
# Usage:
#   # Co-located (deepbook-server on same EC2):
#   ./provision-enclave.sh --host 18.191.170.1 --key ~/.ssh/enclave.pem
#
#   # Separate instances (deepbook-server on a different EC2):
#   ./provision-enclave.sh --host 18.191.170.1 --key ~/.ssh/enclave.pem --server-host 10.0.1.50 --server-port 9008
#
#   # Debug mode:
#   ./provision-enclave.sh --host 18.191.170.1 --key ~/.ssh/enclave.pem --debug

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

EC2_HOST=""
SSH_KEY=""
DEBUG_MODE=false
ENCLAVE_APP="deepbook-incentives"
NAUTILUS_DIR="nautilus"
NAUTILUS_SRC="/home/ubuntu/projects/nautilus"
ENCLAVE_CPUS=2
ENCLAVE_MEMORY="512M"
DEEPBOOK_SERVER_HOST="127.0.0.1"
DEEPBOOK_SERVER_PORT=9008

usage() {
  cat <<EOF
Usage: $0 --host <ec2-ip> --key <ssh-key-path> [options]

Required:
  --host, -h      EC2 instance IP address
  --key, -k       Path to SSH private key

Options:
  --debug         Start enclave in debug mode (PCRs will be all zeros)
  --nautilus-src  Path to local Nautilus repo (default: /home/ubuntu/projects/nautilus)
  --cpus          Enclave CPU count (default: 2)
  --memory        Enclave memory (default: 512M)
  --server-host   IP of the deepbook-server instance (default: 127.0.0.1 for co-located)
  --server-port   Port of the deepbook-server instance (default: 9008)
EOF
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --host|-h)         EC2_HOST="$2"; shift 2 ;;
    --key|-k)          SSH_KEY="$2"; shift 2 ;;
    --debug)           DEBUG_MODE=true; shift ;;
    --nautilus-src)    NAUTILUS_SRC="$2"; shift 2 ;;
    --cpus)            ENCLAVE_CPUS="$2"; shift 2 ;;
    --memory)          ENCLAVE_MEMORY="$2"; shift 2 ;;
    --server-host)     DEEPBOOK_SERVER_HOST="$2"; shift 2 ;;
    --server-port)     DEEPBOOK_SERVER_PORT="$2"; shift 2 ;;
    *) echo "Unknown option: $1"; usage ;;
  esac
done

[[ -z "$EC2_HOST" ]] && { echo "Error: --host is required"; usage; }
[[ -z "$SSH_KEY" ]]  && { echo "Error: --key is required"; usage; }
[[ -d "$NAUTILUS_SRC" ]] || { echo "Error: Nautilus repo not found at $NAUTILUS_SRC"; exit 1; }

SSH="ssh -o StrictHostKeyChecking=no -i $SSH_KEY ec2-user@$EC2_HOST"

log()  { echo "[$(date +%H:%M:%S)] $1"; }
fail() { echo "ERROR: $1" >&2; exit 1; }

echo ""
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║       DEEPBOOK INCENTIVES — ENCLAVE PROVISIONING           ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""
echo "  EC2 Host:       $EC2_HOST"
echo "  Debug mode:     $DEBUG_MODE"
echo "  Nautilus src:   $NAUTILUS_SRC"
echo "  Enclave CPUs:   $ENCLAVE_CPUS"
echo "  Enclave memory: $ENCLAVE_MEMORY"
echo "  DeepBook server: $DEEPBOOK_SERVER_HOST:$DEEPBOOK_SERVER_PORT"
echo ""

# ── Step 1: Terminate any running enclave ────────────────────
log "Checking for running enclaves..."
$SSH "
  ENCLAVE_ID=\$(sudo nitro-cli describe-enclaves 2>/dev/null | jq -r '.[0].EnclaveID // empty' 2>/dev/null) || true
  if [ -n \"\$ENCLAVE_ID\" ] && [ \"\$ENCLAVE_ID\" != 'null' ]; then
    echo \"Terminating existing enclave: \$ENCLAVE_ID\"
    sudo nitro-cli terminate-enclave --enclave-id \$ENCLAVE_ID 2>&1 || true
  else
    echo 'No running enclave found.'
  fi

  # Clean up old networking
  pkill -f 'socat.*VSOCK' 2>/dev/null || true
  pkill -f vsock-proxy 2>/dev/null || true
  echo 'Cleanup done.'
" || log "WARNING: SSH check command returned non-zero (continuing anyway)"

# ── Step 2: Rsync Nautilus repo to EC2 ───────────────────────
log "Syncing Nautilus repo to EC2 at ~/$NAUTILUS_DIR/..."
rsync -avz --delete \
  -e "ssh -o StrictHostKeyChecking=no -i $SSH_KEY" \
  "$NAUTILUS_SRC/" \
  "ec2-user@$EC2_HOST:~/$NAUTILUS_DIR/" \
  || fail "Rsync failed. Check SSH key and connectivity to $EC2_HOST."
log "Nautilus repo synced."

# ── Step 3: Inject outbound bridge into run.sh ─────────────────
# The enclave has no network access except through VSOCK. Nautilus's run.sh
# has placeholder comments for app-specific outbound traffic forwarders.
# We inject a socat bridge so the enclave can reach the deepbook-server:
#   enclave localhost:PORT → VSOCK CID 3:PORT → vsock-proxy on host → deepbook-server
if [ "$DEEPBOOK_SERVER_HOST" != "127.0.0.1" ] || true; then
  log "Injecting outbound bridge for deepbook-server ($DEEPBOOK_SERVER_HOST:$DEEPBOOK_SERVER_PORT)..."
  $SSH "
    RUN_SH=~/$NAUTILUS_DIR/src/nautilus-server/run.sh
    BRIDGE_LINE='socat TCP-LISTEN:$DEEPBOOK_SERVER_PORT,reuseaddr,fork VSOCK-CONNECT:3:$DEEPBOOK_SERVER_PORT &'

    if grep -qF 'VSOCK-CONNECT:3:$DEEPBOOK_SERVER_PORT' \"\$RUN_SH\"; then
      echo 'Outbound bridge already present in run.sh'
    else
      sed -i '/# Traffic-forwarder-block/a \$BRIDGE_LINE' \"\$RUN_SH\"
      echo 'Injected outbound bridge into run.sh'
    fi

    # Ensure vsock-proxy allowlist includes the server host
    ALLOWLIST=/etc/nitro_enclaves/vsock-proxy.yaml
    if grep -q '$DEEPBOOK_SERVER_HOST.*$DEEPBOOK_SERVER_PORT' \"\$ALLOWLIST\" 2>/dev/null; then
      echo 'vsock-proxy allowlist already has $DEEPBOOK_SERVER_HOST:$DEEPBOOK_SERVER_PORT'
    else
      echo '- {address: $DEEPBOOK_SERVER_HOST, port: $DEEPBOOK_SERVER_PORT}' | sudo tee -a \"\$ALLOWLIST\"
      echo 'Added $DEEPBOOK_SERVER_HOST:$DEEPBOOK_SERVER_PORT to vsock-proxy allowlist'
    fi
  "
fi

# ── Step 4: Build the EIF ────────────────────────────────────
log "Building EIF on EC2 (this takes several minutes on first run)..."
$SSH "
  cd ~/$NAUTILUS_DIR
  rm -rf out && mkdir out
  make ENCLAVE_APP=$ENCLAVE_APP 2>&1 | tail -20
  echo ''
  echo '--- PCR hashes ---'
  cat out/nitro.pcrs
"

# ── Step 5: Extract PCRs ─────────────────────────────────────
log "Extracting PCRs..."
PCRS_RAW=$($SSH "cat ~/$NAUTILUS_DIR/out/nitro.pcrs")

# nitro.pcrs can be either JSON ({"PCR0":"...",...}) or space-separated text (<hash> PCR0\n...)
if echo "$PCRS_RAW" | jq -r '.PCR0' &>/dev/null; then
  PCR0=$(echo "$PCRS_RAW" | jq -r '.PCR0')
  PCR1=$(echo "$PCRS_RAW" | jq -r '.PCR1')
  PCR2=$(echo "$PCRS_RAW" | jq -r '.PCR2')
else
  PCR0=$(echo "$PCRS_RAW" | grep 'PCR0' | awk '{print $1}')
  PCR1=$(echo "$PCRS_RAW" | grep 'PCR1' | awk '{print $1}')
  PCR2=$(echo "$PCRS_RAW" | grep 'PCR2' | awk '{print $1}')
fi

log "  PCR0: $PCR0"
log "  PCR1: $PCR1"
log "  PCR2: $PCR2"

# ── Step 6: Start the enclave ────────────────────────────────
if $DEBUG_MODE; then
  log "Starting enclave in DEBUG mode..."
  $SSH "
    cd ~/$NAUTILUS_DIR
    sudo nitro-cli run-enclave \
      --cpu-count $ENCLAVE_CPUS --memory $ENCLAVE_MEMORY \
      --eif-path out/nitro.eif --debug-mode 2>&1
  "
else
  log "Starting enclave in PRODUCTION mode..."
  $SSH "
    cd ~/$NAUTILUS_DIR
    sudo nitro-cli run-enclave \
      --cpu-count $ENCLAVE_CPUS --memory $ENCLAVE_MEMORY \
      --eif-path out/nitro.eif 2>&1
  "
fi

log "Waiting for enclave to boot..."
sleep 10

# ── Step 7: Set up VSOCK networking ──────────────────────────
log "Setting up VSOCK networking..."
$SSH "
  ENCLAVE_CID=\$(nitro-cli describe-enclaves | jq -r '.[0].EnclaveCID')
  echo \"Enclave CID: \$ENCLAVE_CID\"

  if [ -z \"\$ENCLAVE_CID\" ] || [ \"\$ENCLAVE_CID\" = 'null' ]; then
    echo 'ERROR: No enclave CID found. Enclave may have failed to start.'
    nitro-cli describe-enclaves
    exit 1
  fi

  # Send secrets to enclave via VSOCK port 7777
  # Our app doesn't use secrets, so we send an empty JSON object.
  # The enclave's run.sh waits on this before starting the server.
  echo '{}' | socat - VSOCK-CONNECT:\$ENCLAVE_CID:7777
  echo 'Secrets sent (empty — our app reads DEEPBOOK_SERVER_URL from env instead).'

  sleep 2

  # Inbound traffic: TCP port 3000 on the host → VSOCK port 3000 in the enclave.
  # This is how external callers (submit-epoch.ts) reach the enclave's HTTP server.
  nohup socat TCP4-LISTEN:3000,reuseaddr,fork \
    VSOCK-CONNECT:\$ENCLAVE_CID:3000 < /dev/null > /tmp/socat-inbound.log 2>&1 &
  disown
  echo 'Inbound bridge started: TCP :3000 → VSOCK :3000'

  # Outbound traffic: the enclave needs to reach deepbook-server.
  # vsock-proxy listens on VSOCK port $DEEPBOOK_SERVER_PORT and forwards to $DEEPBOOK_SERVER_HOST:$DEEPBOOK_SERVER_PORT.
  # If deepbook-server is on the same host, DEEPBOOK_SERVER_HOST=127.0.0.1.
  # If it's on a separate EC2, DEEPBOOK_SERVER_HOST=<that-instance-private-ip>.
  nohup vsock-proxy $DEEPBOOK_SERVER_PORT $DEEPBOOK_SERVER_HOST $DEEPBOOK_SERVER_PORT \
    --config /etc/nitro_enclaves/vsock-proxy.yaml < /dev/null > /tmp/vsock-proxy.log 2>&1 &
  disown
  echo 'Outbound bridge started: VSOCK :$DEEPBOOK_SERVER_PORT → $DEEPBOOK_SERVER_HOST:$DEEPBOOK_SERVER_PORT (deepbook-server)'
"

log "Waiting for enclave server to be ready..."
sleep 5

# ── Step 8: Health check ─────────────────────────────────────
log "Running health check..."
HEALTH=""
for i in 1 2 3 4 5; do
  HEALTH=$(curl -sf "http://$EC2_HOST:3000/health_check" 2>/dev/null || echo "")
  if echo "$HEALTH" | jq -e '.pk' > /dev/null 2>&1; then
    break
  fi
  log "  Attempt $i failed, retrying in 5s..."
  sleep 5
done

if echo "$HEALTH" | jq -e '.pk' > /dev/null 2>&1; then
  PK=$(echo "$HEALTH" | jq -r '.pk')
  log "Enclave is healthy!"
  log "  Public key: $PK"
else
  echo ""
  echo "ERROR: Health check failed after 5 attempts."
  echo "  Response: $HEALTH"
  echo ""
  echo "Debug tips:"
  echo "  - SSH to EC2 and check: nitro-cli describe-enclaves"
  echo "  - Check socat: cat /tmp/socat-inbound.log"
  echo "  - Check vsock-proxy: cat /tmp/vsock-proxy.log"
  if $DEBUG_MODE; then
    echo "  - View enclave console: nitro-cli console --enclave-id \$(nitro-cli describe-enclaves | jq -r '.[0].EnclaveID')"
  fi
  exit 1
fi

# ── Done ─────────────────────────────────────────────────────
echo ""
echo "============================================================"
echo "  ENCLAVE PROVISIONED SUCCESSFULLY"
echo "============================================================"
echo ""
echo "  Host:        $EC2_HOST"
echo "  Debug:       $DEBUG_MODE"
echo "  Public key:  $PK"
echo "  PCR0:        $PCR0"
echo "  PCR1:        $PCR1"
echo "  PCR2:        $PCR2"
echo ""
echo "  Next steps (run from the scripts/ directory):"
echo ""
if $DEBUG_MODE; then
  echo "  1. Update on-chain PCRs (debug mode = all zeros):"
  echo "     npx tsx enclave/update-pcrs.ts \\"
  echo "       --network testnet --debug"
else
  echo "  1. Update on-chain PCRs:"
  echo "     npx tsx enclave/update-pcrs.ts \\"
  echo "       --network mainnet \\"
  echo "       --pcr0 $PCR0 \\"
  echo "       --pcr1 $PCR1 \\"
  echo "       --pcr2 $PCR2"
fi
echo ""
echo "  2. Register enclave on-chain:"
echo "     npx tsx enclave/register-enclave.ts \\"
echo "       --network mainnet --enclave-url http://$EC2_HOST:3000"
echo ""
echo "  3. Create a fund:"
echo "     npx tsx setup/create-fund.ts \\"
echo "       --network mainnet --pool-id 0x... --reward 1000 \\"
echo "       --fund 30000 --alpha-bps 5000"
echo ""
