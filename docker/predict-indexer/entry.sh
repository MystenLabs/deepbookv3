#!/bin/bash

export RUST_BACKTRACE=1
export RUST_LOG=${RUST_LOG:-info}

# Build command arguments
args=(--database-url "$DATABASE_URL")
if [ -n "$PREDICT_PACKAGE_ID" ]; then
    args+=(--predict-package-id "$PREDICT_PACKAGE_ID")
fi
if [ -n "$FIRST_CHECKPOINT" ]; then
    args+=(--first-checkpoint "$FIRST_CHECKPOINT")
fi

exec /opt/mysten/bin/predict-indexer "${args[@]}"
