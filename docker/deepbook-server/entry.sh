#!/bin/bash

export RUST_BACKTRACE=1
export RUST_LOG=debug

# RPC_URL, DEEPBOOK_PACKAGE_ID and DEEPBOOK_ENV are read straight from the environment by the
# binary. Forwarding them here instead would pass an empty string when they are unset, which
# overrides the per-network default rather than leaving it in place.
/opt/mysten/bin/deepbook-server \
  --database-url "$DATABASE_URL" \
  --deep-token-package-id "$DEEP_TOKEN_PACKAGE_ID" \
  --deep-treasury-id "$DEEP_TREASURY_ID" \
  --margin-package-id "$MARGIN_PACKAGE_ID" \
  --db-statement-timeout-ms 60000
