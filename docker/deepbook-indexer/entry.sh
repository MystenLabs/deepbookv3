#!/bin/bash

export RUST_BACKTRACE=1
export RUST_LOG=debug

/opt/mysten/bin/deepbook-indexer --database-url "$DATABASE_URL" --env "$NETWORK"
