#!/bin/bash

export RUST_BACKTRACE=1
export RUST_LOG=${RUST_LOG:-info}

# Build command arguments — top-level flags first, then the sandbox subcommand
args=(--database-url "$DATABASE_URL" --db-connection-pool-size 250)
if [ -n "$FIRST_CHECKPOINT" ]; then
    args+=(--first-checkpoint "$FIRST_CHECKPOINT")
fi

# sandbox subcommand and its flags
args+=(sandbox --env "$NETWORK" --deepbook-package-id "$DEEPBOOK_PACKAGE_ID")
if [ -n "$MARGIN_PACKAGES" ]; then
    args+=(--margin-packages "$MARGIN_PACKAGES")
fi
if [ -n "$LOCAL_CHECKPOINTS_DIR" ]; then
    args+=(--local-ingestion-path "$LOCAL_CHECKPOINTS_DIR")
fi

exec /opt/mysten/bin/deepbook-indexer "${args[@]}"
