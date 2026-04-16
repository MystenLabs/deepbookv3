#!/bin/bash

export RUST_BACKTRACE=1
export RUST_LOG=${RUST_LOG:-info}

/opt/mysten/bin/predict-server \
  --database-url "$DATABASE_URL"
