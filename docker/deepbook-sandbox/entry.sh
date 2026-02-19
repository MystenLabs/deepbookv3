#!/bin/bash

export RUST_BACKTRACE=1
export RUST_LOG=${RUST_LOG:-info}

# Build command arguments — top-level flags first, then the sandbox subcommand
args=(--database-url "$DATABASE_URL" --db-connection-pool-size 250)
if [ -n "$FIRST_CHECKPOINT" ]; then
    args+=(--first-checkpoint "$FIRST_CHECKPOINT")
fi

# Validate required env vars
if [ -z "$DEEPBOOK_PACKAGE_ID" ]; then
    echo "ERROR: DEEPBOOK_PACKAGE_ID is required" >&2
    exit 1
fi

# sandbox subcommand and its flags
args+=(sandbox --env "$NETWORK" --deepbook-package-id "$DEEPBOOK_PACKAGE_ID")
# Single margin package ID only. For multiple, split on a delimiter or repeat the flag.
if [ -n "$MARGIN_PACKAGES" ]; then
    args+=(--margin-packages "$MARGIN_PACKAGES")
fi
if [ -n "$LOCAL_CHECKPOINTS_DIR" ]; then
    args+=(--local-ingestion-path "$LOCAL_CHECKPOINTS_DIR")
fi

exec /opt/mysten/bin/deepbook-indexer "${args[@]}"
