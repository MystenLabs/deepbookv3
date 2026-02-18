#!/bin/bash

export RUST_BACKTRACE=1
export RUST_LOG=${RUST_LOG:-info}

# Build command arguments
args=( --database-url "$DATABASE_URL" --db-connection-pool-size 250 --sandbox --env "$NETWORK" --deepbook-package-id "$DEEPBOOK_PACKAGE_ID" --margin-packages "$MARGIN_PACKAGES" --local-ingestion-path "$LOCAL_CHECKPOINTS_DIR")
if [ -n "$FIRST_CHECKPOINT" ]; then
    args+=(--first-checkpoint "$FIRST_CHECKPOINT")
fi

exec /opt/mysten/bin/deepbook-indexer "${args[@]}"
