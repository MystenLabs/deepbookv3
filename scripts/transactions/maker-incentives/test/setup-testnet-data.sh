#!/usr/bin/env bash
# setup-testnet-data.sh — Provision a local deepbook-indexer + deepbook-server for testnet.
#
# Creates a fresh PostgreSQL database, starts the indexer from ~24h ago on testnet,
# waits for it to catch up, then starts the server on port 9008.
#
# This gives the enclave a local data source to score against during testnet testing.
#
# Prerequisites:
#   - PostgreSQL running locally (docker or native)
#   - Rust toolchain installed (cargo)
#   - curl, jq
#
# Usage:
#   ./setup-testnet-data.sh
#   ./setup-testnet-data.sh --hours 48           # index last 48 hours instead of 24
#   ./setup-testnet-data.sh --db-url "postgres://user:pass@host:5432/mydb"
#   ./setup-testnet-data.sh --skip-build          # skip cargo build (already built)
#   ./setup-testnet-data.sh --indexer-only         # just start the indexer, no server
#   ./setup-testnet-data.sh --server-only          # just start the server (indexer already running)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$SCRIPT_DIR/../../.."

# ── Defaults ──────────────────────────────────────────────────
DB_URL="postgres://postgres:postgrespw@localhost:5432/deepbook_testnet"
DB_NAME="deepbook_testnet"
HOURS=24
SERVER_PORT=9008
SKIP_BUILD=false
INDEXER_ONLY=false
SERVER_ONLY=false
RPC_URL="https://fullnode.testnet.sui.io:443"
INDEXER_PID=""
SERVER_PID=""
FIRST_CP=""
LOOKBACK=0

# Latest testnet package IDs (from crates/indexer/src/lib.rs)
DEEPBOOK_PACKAGE="0x22be4cade64bf2d02412c7e8d0e8beea2f78828b948118d46735315409371a3c"
MARGIN_PACKAGE="0xd6a42f4df4db73d68cbeb52be66698d2fe6a9464f45ad113ca52b0c6ebd918b6"
DEEP_TOKEN_PACKAGE="0x36dbef866a1d62bf7328989a10fb2f07d769f4ee587c0de4a0a256e57e0a58a8"
DEEP_TREASURY="0x69fffdae0075f8f71f4fa793549c11079266910e8905169845af1f5d00e09dcb"

usage() {
  cat <<EOF
Usage: $0 [options]

Options:
  --hours N          Hours of history to index (default: 24)
  --db-url URL       PostgreSQL connection string
  --db-name NAME     Database name to create (default: deepbook_testnet)
  --server-port N    Server port (default: 9008)
  --skip-build       Skip cargo build step
  --indexer-only     Only start the indexer, not the server
  --server-only      Only start the server (assumes indexer is already running)
EOF
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --hours)        HOURS="$2"; shift 2 ;;
    --db-url)       DB_URL="$2"; shift 2 ;;
    --db-name)      DB_NAME="$2"; shift 2 ;;
    --server-port)  SERVER_PORT="$2"; shift 2 ;;
    --skip-build)   SKIP_BUILD=true; shift ;;
    --indexer-only) INDEXER_ONLY=true; shift ;;
    --server-only)  SERVER_ONLY=true; shift ;;
    --help|-h)      usage ;;
    *)              echo "Unknown option: $1"; usage ;;
  esac
done

log()  { echo "[$(date +%H:%M:%S)] $1"; }
fail() { echo "ERROR: $1" >&2; exit 1; }

echo ""
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║     TESTNET DATA SETUP — deepbook-indexer + deepbook-server ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""
echo "  Hours of history: $HOURS"
echo "  Database:         $DB_URL"
echo "  Server port:      $SERVER_PORT"
echo "  Skip build:       $SKIP_BUILD"
echo ""

# ── Step 1: Build binaries ────────────────────────────────────
if ! $SKIP_BUILD && ! $SERVER_ONLY; then
  log "Building deepbook-indexer and deepbook-server (release mode)..."
  cd "$REPO_ROOT"
  cargo build --release --bin deepbook-indexer --bin deepbook-server 2>&1 | tail -5
  log "Build complete."
fi

TARGET_DIR="${CARGO_TARGET_DIR:-$REPO_ROOT/target}"

INDEXER_BIN="$TARGET_DIR/release/deepbook-indexer"
SERVER_BIN="$TARGET_DIR/release/deepbook-server"

[[ -x "$INDEXER_BIN" ]] || INDEXER_BIN="$TARGET_DIR/release/deepbook_indexer"
[[ -x "$SERVER_BIN" ]]  || SERVER_BIN="$TARGET_DIR/release/deepbook_server"

if ! $SERVER_ONLY; then
  [[ -x "$INDEXER_BIN" ]] || fail "Indexer binary not found at $INDEXER_BIN. Run without --skip-build."
fi
if ! $INDEXER_ONLY; then
  [[ -x "$SERVER_BIN" ]] || fail "Server binary not found at $SERVER_BIN. Run without --skip-build."
fi

# ── Step 2: Create database ──────────────────────────────────
if ! $SERVER_ONLY; then
  log "Ensuring database '$DB_NAME' exists..."

  # Derive the admin URL (connect to 'postgres' db) from the user-supplied DB_URL
  ADMIN_URL="${DB_URL%/*}/postgres"

  # Check if the target database already exists
  EXISTS=$(psql "$ADMIN_URL" -tAc "SELECT 1 FROM pg_database WHERE datname='$DB_NAME';" 2>/dev/null || true)
  if [[ "$EXISTS" == "1" ]]; then
    log "Database '$DB_NAME' already exists."
  else
    psql "$ADMIN_URL" -c "CREATE DATABASE $DB_NAME;" 2>&1 \
      && log "Database '$DB_NAME' created." \
      || fail "Could not create database '$DB_NAME'. Check your --db-url credentials."
  fi
fi

# ── Step 3: Calculate first checkpoint ────────────────────────
if ! $SERVER_ONLY; then
  log "Querying testnet for latest checkpoint..."
  LATEST=$(curl -sf -X POST "$RPC_URL" \
    -H 'Content-Type: application/json' \
    -d '{"jsonrpc":"2.0","id":1,"method":"sui_getLatestCheckpointSequenceNumber","params":[]}' \
    | jq -r '.result')

  if [[ -z "$LATEST" || "$LATEST" == "null" ]]; then
    fail "Could not fetch latest checkpoint from testnet RPC"
  fi

  # Testnet ~3-4 checkpoints per second → ~12600 per hour (using 3.5 avg)
  CHECKPOINTS_PER_HOUR=12600
  LOOKBACK=$((HOURS * CHECKPOINTS_PER_HOUR))
  FIRST_CP=$((LATEST - LOOKBACK))

  # Don't go below 0
  if [[ $FIRST_CP -lt 0 ]]; then
    FIRST_CP=0
  fi

  log "Latest testnet checkpoint: $LATEST"
  log "Starting from checkpoint:  $FIRST_CP (~${HOURS}h ago)"
fi

# ── Step 4: Start indexer ─────────────────────────────────────
if ! $SERVER_ONLY; then
  log "Starting deepbook-indexer..."
  echo ""
  echo "  Command:"
  echo "    $INDEXER_BIN \\"
  echo "      --env testnet \\"
  echo "      --database-url \"$DB_URL\" \\"
  echo "      --first-checkpoint $FIRST_CP \\"
  echo "      --metrics-address 0.0.0.0:9185 \\"
  echo "      --packages deepbook --packages deepbook-margin --packages maker-incentives"
  echo ""

  $INDEXER_BIN \
    --env testnet \
    --database-url "$DB_URL" \
    --first-checkpoint "$FIRST_CP" \
    --metrics-address "0.0.0.0:9185" \
    --packages deepbook --packages deepbook-margin --packages maker-incentives \
    &
  INDEXER_PID=$!
  log "Indexer started (PID: $INDEXER_PID)"

  if $INDEXER_ONLY; then
    log "Indexer-only mode. Press Ctrl+C to stop."
    wait $INDEXER_PID
    exit 0
  fi

  log "Indexer is catching up in the background."
fi

# ── Step 5: Start server ──────────────────────────────────────
if ! $INDEXER_ONLY; then
  log "Starting deepbook-server on port $SERVER_PORT..."
  echo ""
  echo "  Command:"
  echo "    $SERVER_BIN \\"
  echo "      --database-url \"$DB_URL\" \\"
  echo "      --rpc-url $RPC_URL \\"
  echo "      --server-port $SERVER_PORT \\"
  echo "      --deepbook-package-id $DEEPBOOK_PACKAGE \\"
  echo "      --deep-token-package-id $DEEP_TOKEN_PACKAGE \\"
  echo "      --deep-treasury-id $DEEP_TREASURY \\"
  echo "      --margin-package-id $MARGIN_PACKAGE"
  echo ""

  $SERVER_BIN \
    --database-url "$DB_URL" \
    --rpc-url "$RPC_URL" \
    --server-port "$SERVER_PORT" \
    --deepbook-package-id "$DEEPBOOK_PACKAGE" \
    --deep-token-package-id "$DEEP_TOKEN_PACKAGE" \
    --deep-treasury-id "$DEEP_TREASURY" \
    --margin-package-id "$MARGIN_PACKAGE" \
    &
  SERVER_PID=$!
  log "Server started (PID: $SERVER_PID)"

  # Wait for server to be ready
  log "Waiting for server to be ready..."
  for i in $(seq 1 10); do
    if curl -sf "http://localhost:$SERVER_PORT/health" > /dev/null 2>&1; then
      break
    fi
    sleep 2
  done

  if curl -sf "http://localhost:$SERVER_PORT/health" > /dev/null 2>&1; then
    log "Server is ready at http://localhost:$SERVER_PORT"
  else
    log "WARNING: Server health check didn't respond yet — it may still be starting up."
  fi
fi

# ── Done ──────────────────────────────────────────────────────
echo ""
echo "============================================================"
echo "  TESTNET DATA SERVICES RUNNING"
echo "============================================================"
echo ""
if ! $SERVER_ONLY; then
  echo "  Indexer PID:  $INDEXER_PID"
fi
if ! $INDEXER_ONLY; then
  echo "  Server PID:   $SERVER_PID"
  echo "  Server URL:   http://localhost:$SERVER_PORT"
fi
echo ""
if [[ -n "$FIRST_CP" ]]; then
  echo "  The indexer is catching up from checkpoint $FIRST_CP."
  echo "  It will take some time to process ~$LOOKBACK checkpoints."
  echo "  Data becomes available to the server as it's indexed."
  echo ""
fi
echo "  Useful endpoints:"
echo "    curl http://localhost:$SERVER_PORT/pools"
echo "    curl 'http://localhost:$SERVER_PORT/incentives/pool_data/<pool_id>?start_ms=...&end_ms=...'"
echo ""
  echo "  To stop:"
  echo "    kill ${INDEXER_PID:+$INDEXER_PID }${SERVER_PID:+$SERVER_PID }2>/dev/null"
echo ""

# Trap to clean up on Ctrl+C
cleanup() {
  echo ""
  log "Shutting down..."
  [[ -n "$INDEXER_PID" ]] && kill "$INDEXER_PID" 2>/dev/null || true
  [[ -n "$SERVER_PID" ]] && kill "$SERVER_PID" 2>/dev/null || true
  log "Done."
}
trap cleanup EXIT INT TERM

# Wait for both processes
wait
