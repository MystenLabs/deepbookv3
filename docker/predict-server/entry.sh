#!/bin/bash

/opt/mysten/bin/deepbook-predict-server \
    --db-url "${DATABASE_URL}" \
    --listen-address "${LISTEN_ADDRESS:-0.0.0.0:8080}"
