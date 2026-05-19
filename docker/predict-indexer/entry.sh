#!/bin/bash

/opt/mysten/bin/deepbook-predict-indexer \
    --remote-store-url "${REMOTE_STORE_URL:-https://checkpoints.testnet.sui.io}" \
    --db-url "${DATABASE_URL}" \
    --env "${ENV:-testnet}" \
    --metrics-address "${METRICS_ADDRESS:-0.0.0.0:9184}"
