#!/bin/bash

export RUST_BACKTRACE=1
export RUST_LOG=debug

# if FIRST_CHECKPOINT is set, include it, otherwise exclude it
if [ -n "$FIRST_CHECKPOINT" ]; then
    /opt/mysten/bin/deepbook-indexer --database-url "$DATABASE_URL" --env "$NETWORK" --first-checkpoint "$FIRST_CHECKPOINT"
else
    /opt/mysten/bin/deepbook-indexer --database-url "$DATABASE_URL" --env "$NETWORK"
fi
