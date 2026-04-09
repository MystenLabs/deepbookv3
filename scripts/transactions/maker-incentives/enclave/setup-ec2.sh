#!/usr/bin/env bash
# prerequisit - run create-enclave-ec2.sh first to setup the enclave instance
# setup-ec2.sh — One-time setup for a fresh EC2 instance to run Nitro Enclaves.
#
# Run this ONCE on a brand-new Amazon Linux 2023 (or AL2) instance that has
# "Nitro Enclave" enabled in its launch configuration.
#
# What this installs:
#   - Docker            (builds the enclave image)
#   - aws-nitro-enclaves-cli   (nitro-cli for managing enclaves)
#   - aws-nitro-enclaves-cli-devel   (vsock-proxy for outbound networking)
#   - socat             (inbound VSOCK bridging)
#   - jq, make, git     (build tools)
#
# What this configures:
#   - Docker service enabled, ec2-user added to docker group
#   - Nitro Enclaves allocator (memory + hugepages)
#   - Verifies everything works
#
# After this, run provision-enclave.sh to push code, build EIF, and start the enclave.
#
# Usage (from your local machine):
#   ./setup-ec2.sh --host 18.191.170.1 --key ~/.ssh/enclave.pem
#   ./setup-ec2.sh --host 18.191.170.1 --key ~/.ssh/enclave.pem --memory 4096
set -euo pipefail

EC2_HOST=""
SSH_KEY=""
ALLOCATOR_MEMORY_MIB=3072
SSH_USER="ec2-user"

usage() {
  cat <<EOF
Usage: $0 --host <ec2-ip> --key <ssh-key-path> [options]

Required:
  --host          EC2 instance IP address
  --key           Path to SSH private key

Options:
  --memory        Enclave allocator memory in MiB (default: 3072)
  --user          SSH user (default: ec2-user)
EOF
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --host|-h)   EC2_HOST="$2"; shift 2 ;;
    --key|-k)    SSH_KEY="$2"; shift 2 ;;
    --memory)    ALLOCATOR_MEMORY_MIB="$2"; shift 2 ;;
    --user)      SSH_USER="$2"; shift 2 ;;
    --help)      usage ;;
    *) echo "Unknown option: $1"; usage ;;
  esac
done

[[ -z "$EC2_HOST" ]] && { echo "Error: --host is required"; usage; }
[[ -z "$SSH_KEY" ]]  && { echo "Error: --key is required"; usage; }

SSH="ssh -o StrictHostKeyChecking=no -i $SSH_KEY $SSH_USER@$EC2_HOST"

log()  { echo "[$(date +%H:%M:%S)] $1"; }
fail() { echo "ERROR: $1" >&2; exit 1; }

echo ""
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║       EC2 INSTANCE SETUP FOR NITRO ENCLAVES                ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""
echo "  Host:             $EC2_HOST"
echo "  SSH user:         $SSH_USER"
echo "  Allocator memory: ${ALLOCATOR_MEMORY_MIB} MiB"
echo ""

# ── Step 1: Verify connectivity ─────────────────────────────
log "Verifying SSH connectivity..."
$SSH "echo 'SSH connection OK'" || fail "Cannot SSH to $EC2_HOST"

# ── Step 2: Install system packages ──────────────────────────
log "Installing system packages..."
$SSH "
  set -e

  # Detect package manager
  if command -v dnf &>/dev/null; then
    PKG='sudo dnf'
  else
    PKG='sudo yum'
  fi

  \$PKG update -y

  # Core tools
  \$PKG install -y git make jq socat

  # Docker
  if ! command -v docker &>/dev/null; then
    \$PKG install -y docker
    echo 'Docker installed.'
  else
    echo 'Docker already installed.'
  fi

  # Nitro Enclaves CLI + devel (provides nitro-cli and vsock-proxy)
  if ! command -v nitro-cli &>/dev/null; then
    sudo amazon-linux-extras install aws-nitro-enclaves-cli -y 2>/dev/null || \
      \$PKG install -y aws-nitro-enclaves-cli aws-nitro-enclaves-cli-devel
    echo 'Nitro Enclaves CLI installed.'
  else
    echo 'nitro-cli already installed.'
  fi

  # Make sure devel package is there (provides vsock-proxy)
  if ! command -v vsock-proxy &>/dev/null; then
    \$PKG install -y aws-nitro-enclaves-cli-devel
    echo 'vsock-proxy installed.'
  else
    echo 'vsock-proxy already installed.'
  fi

  echo 'All packages installed.'
"

# ── Step 3: Configure Docker ─────────────────────────────────
log "Configuring Docker..."
$SSH "
  set -e

  # Add ec2-user to docker group
  sudo usermod -aG ne $SSH_USER 2>/dev/null || true
  sudo usermod -aG docker $SSH_USER 2>/dev/null || true

  # Enable and start Docker
  sudo systemctl enable docker
  sudo systemctl start docker

  echo 'Docker configured.'
"

# ── Step 4: Configure Nitro Enclaves allocator ───────────────
log "Configuring Nitro Enclaves allocator (${ALLOCATOR_MEMORY_MIB} MiB)..."
$SSH "
  set -e

  ALLOCATOR_YAML=/etc/nitro_enclaves/allocator.yaml

  if [ ! -f \"\$ALLOCATOR_YAML\" ]; then
    echo 'ERROR: allocator.yaml not found — is this instance Nitro Enclave enabled?'
    exit 1
  fi

  # Set memory allocation for enclaves
  sudo sed -r 's/^(\s*memory_mib\s*:\s*).*/\1$ALLOCATOR_MEMORY_MIB/' -i \"\$ALLOCATOR_YAML\"

  # Enable and restart the allocator
  sudo systemctl enable nitro-enclaves-allocator.service
  sudo systemctl restart nitro-enclaves-allocator.service

  echo 'Allocator configured.'
  echo '--- Current allocator config ---'
  cat \"\$ALLOCATOR_YAML\"
"

# ── Step 5: Verify everything ─────────────────────────────────
log "Verifying installation..."
VERIFY_OUTPUT=$($SSH "
  echo '--- Versions ---'
  echo \"docker:      \$(docker --version 2>/dev/null || echo 'NOT FOUND')\"
  echo \"nitro-cli:   \$(nitro-cli --version 2>/dev/null || echo 'NOT FOUND')\"
  echo \"vsock-proxy: \$(vsock-proxy --version 2>/dev/null || echo 'NOT FOUND')\"
  echo \"socat:       \$(socat -V 2>/dev/null | head -2 | tail -1 || echo 'NOT FOUND')\"
  echo \"jq:          \$(jq --version 2>/dev/null || echo 'NOT FOUND')\"
  echo \"make:        \$(make --version 2>/dev/null | head -1 || echo 'NOT FOUND')\"
  echo \"git:         \$(git --version 2>/dev/null || echo 'NOT FOUND')\"
  echo ''

  # Check Docker is running
  if docker info &>/dev/null; then
    echo 'Docker: RUNNING'
  else
    echo 'Docker: NOT RUNNING (you may need to reconnect for group changes)'
  fi

  # Check allocator is running
  if systemctl is-active --quiet nitro-enclaves-allocator.service; then
    echo 'Nitro allocator: RUNNING'
  else
    echo 'Nitro allocator: NOT RUNNING'
  fi

  # Check hugepages are allocated (needed by enclaves)
  HUGE_TOTAL=\$(grep HugePages_Total /proc/meminfo | awk '{print \$2}')
  echo \"HugePages_Total: \$HUGE_TOTAL\"
")

echo "$VERIFY_OUTPUT"

# ── Check for issues ──────────────────────────────────────────
if echo "$VERIFY_OUTPUT" | grep -q "NOT FOUND"; then
  echo ""
  echo "WARNING: Some tools were not found. Check the output above."
  echo "You may need to install missing packages manually."
fi

if echo "$VERIFY_OUTPUT" | grep -q "NOT RUNNING"; then
  echo ""
  echo "WARNING: Some services are not running."
  echo "If Docker says 'NOT RUNNING', try disconnecting and reconnecting SSH"
  echo "(the docker group change requires a new session)."
fi

# ── Done ──────────────────────────────────────────────────────
echo ""
echo "============================================================"
echo "  EC2 INSTANCE SETUP COMPLETE"
echo "============================================================"
echo ""
echo "  Host: $EC2_HOST"
echo ""
echo "  IMPORTANT: If this is the first time adding ec2-user to the"
echo "  docker group, you must disconnect and reconnect SSH before"
echo "  running the next step."
echo ""
echo "  Next step — push code, build EIF, start enclave:"
echo ""
echo "    ./provision-enclave.sh \\"
echo "      --host $EC2_HOST \\"
echo "      --key $SSH_KEY"
echo ""
echo "  (Add --server-host <ip> if deepbook-server is on a different instance)"
echo ""
