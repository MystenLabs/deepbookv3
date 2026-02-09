#!/bin/bash

export RUST_BACKTRACE=1
export RUST_LOG=${RUST_LOG:-info}

# Build command arguments
args=(--database-url "$DATABASE_URL" --env "$NETWORK" --db-connection-pool-size 250)
if [ -n "$FIRST_CHECKPOINT" ]; then
    args+=(--first-checkpoint "$FIRST_CHECKPOINT")
fi

exec /opt/mysten/bin/deepbook-indexer "${args[@]}"
