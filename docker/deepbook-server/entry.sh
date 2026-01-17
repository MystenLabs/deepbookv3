#!/bin/bash

export RUST_BACKTRACE=1
export RUST_LOG=debug

/opt/mysten/bin/deepbook-server \
  --database-url "$DATABASE_URL" \
  --rpc-url "$RPC_URL" \
  --deepbook-package-id "$DEEPBOOK_PACKAGE_ID" \
  --deep-token-package-id "$DEEP_TOKEN_PACKAGE_ID" \
  --deep-treasury-id "$DEEP_TREASURY_ID" \
  --margin-package-id "$MARGIN_PACKAGE_ID"
